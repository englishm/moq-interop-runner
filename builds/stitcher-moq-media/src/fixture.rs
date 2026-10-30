//! The CMSF fixture as the image carries it: the manifest (docs/tests/media/cmsf.md), the
//! expected catalog, and the track files sliced into init segments and objects.
//!
//! The manifest is the oracle's reference; the track files are what the publisher sends.
//! Loading verifies that the two agree (every object's SHA-256), so a fixture that drifted
//! from its manifest is a bail-out, not a test failure blamed on the relay.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::Context;
use bytes::Bytes;
use serde::Deserialize;
use sha2::{Digest, Sha256};

/// `manifest.json`.
#[derive(Debug, Clone, Deserialize)]
pub struct Manifest {
    pub format: String,
    pub duration_ms: u64,
    pub group_ms: u64,
    pub tracks: BTreeMap<String, TrackManifest>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TrackManifest {
    pub file: String,
    pub sha256: String,
    pub codec: String,
    pub timescale: u64,
    pub frames: u64,
    pub init: ByteRange,
    pub groups: Vec<GroupManifest>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ByteRange {
    pub offset: u64,
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct GroupManifest {
    pub group: u64,
    pub objects: Vec<ObjectManifest>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ObjectManifest {
    pub object: u64,
    pub offset: u64,
    pub bytes: u64,
    pub tfdt: u64,
    pub samples: u64,
    pub sha256: String,
}

/// One object of a media track: its manifest entry and its bytes.
#[derive(Debug, Clone)]
pub struct Object {
    pub group: u64,
    pub object: u64,
    pub tfdt: u64,
    pub samples: u64,
    pub sha256: String,
    pub payload: Bytes,
}

/// One media track, ready to publish and to check against.
#[derive(Debug, Clone)]
pub struct Track {
    pub name: String,
    pub manifest: TrackManifest,
    pub init: Bytes,
    /// In (group, object) order.
    pub objects: Vec<Object>,
}

impl Track {
    /// The manifest entry for `(group, object)`, if the track has one.
    pub fn object(&self, group: u64, object: u64) -> Option<&Object> {
        self.objects
            .iter()
            .find(|o| o.group == group && o.object == object)
    }

    /// The last Object ID of `group`, if the track has that group.
    pub fn last_object(&self, group: u64) -> Option<u64> {
        self.objects
            .iter()
            .filter(|o| o.group == group)
            .map(|o| o.object)
            .max()
    }

    /// The highest Group ID.
    pub fn last_group(&self) -> u64 {
        self.objects.iter().map(|o| o.group).max().unwrap_or(0)
    }

    /// Whether the track is video (decides the ffprobe stream selector).
    pub fn is_video(&self) -> bool {
        ["avc1", "avc3", "hvc1", "hev1", "av01", "vp09"]
            .iter()
            .any(|p| self.manifest.codec.starts_with(p))
    }

    /// Seconds from the start of the fixture to the start of `tfdt`.
    pub fn seconds(&self, tfdt: u64) -> f64 {
        tfdt as f64 / self.manifest.timescale as f64
    }
}

/// The loaded fixture.
#[derive(Debug, Clone)]
pub struct Fixture {
    pub manifest: Manifest,
    /// `catalog.json` exactly as published.
    pub catalog: Bytes,
    /// `catalog.json` parsed, for comparison.
    pub catalog_json: serde_json::Value,
    pub tracks: BTreeMap<String, Track>,
}

impl Fixture {
    pub fn load(dir: &Path) -> anyhow::Result<Self> {
        let manifest_path = dir.join("manifest.json");
        let manifest: Manifest = serde_json::from_slice(
            &std::fs::read(&manifest_path)
                .with_context(|| format!("reading {}", manifest_path.display()))?,
        )
        .context("parsing manifest.json")?;
        anyhow::ensure!(
            manifest.format == "cmsf",
            "manifest format is {:?}, expected cmsf",
            manifest.format
        );

        let catalog_path = dir.join("catalog.json");
        let catalog = std::fs::read(&catalog_path)
            .with_context(|| format!("reading {}", catalog_path.display()))?;
        let catalog_json: serde_json::Value =
            serde_json::from_slice(&catalog).context("parsing catalog.json")?;

        let mut tracks = BTreeMap::new();
        for (name, tm) in &manifest.tracks {
            let path = dir.join(&tm.file);
            let data =
                std::fs::read(&path).with_context(|| format!("reading {}", path.display()))?;
            anyhow::ensure!(
                sha256_hex(&data) == tm.sha256,
                "{} does not match the manifest's file hash",
                tm.file
            );
            let data = Bytes::from(data);
            let init = slice(&data, tm.init.offset, tm.init.bytes)
                .with_context(|| format!("{} init segment", tm.file))?;
            anyhow::ensure!(
                sha256_hex(&init) == tm.init.sha256,
                "{} init segment does not match the manifest",
                tm.file
            );
            let mut objects = Vec::new();
            for g in &tm.groups {
                for o in &g.objects {
                    let payload = slice(&data, o.offset, o.bytes).with_context(|| {
                        format!("{} group {} object {}", tm.file, g.group, o.object)
                    })?;
                    anyhow::ensure!(
                        sha256_hex(&payload) == o.sha256,
                        "{} group {} object {} does not match the manifest",
                        tm.file,
                        g.group,
                        o.object
                    );
                    objects.push(Object {
                        group: g.group,
                        object: o.object,
                        tfdt: o.tfdt,
                        samples: o.samples,
                        sha256: o.sha256.clone(),
                        payload,
                    });
                }
            }
            objects.sort_by_key(|o| (o.group, o.object));
            tracks.insert(
                name.clone(),
                Track {
                    name: name.clone(),
                    manifest: tm.clone(),
                    init,
                    objects,
                },
            );
        }

        Ok(Self {
            manifest,
            catalog: Bytes::from(catalog),
            catalog_json,
            tracks,
        })
    }

    /// The media track names in the order the expected catalog lists them.
    pub fn catalog_track_names(&self) -> Vec<String> {
        catalog_track_names(&self.catalog_json)
    }

    /// One line for the TAP header.
    pub fn summary(&self) -> String {
        let tracks: Vec<String> = self
            .tracks
            .values()
            .map(|t| {
                format!(
                    "{} {} groups/{} objects/{} frames",
                    t.name,
                    t.manifest.groups.len(),
                    t.objects.len(),
                    t.manifest.frames
                )
            })
            .collect();
        format!(
            "{} {} ms, {} ms groups: {}",
            self.manifest.format,
            self.manifest.duration_ms,
            self.manifest.group_ms,
            tracks.join(", ")
        )
    }
}

/// The `tracks[].name` entries of an MSF catalog, in order.
pub fn catalog_track_names(catalog: &serde_json::Value) -> Vec<String> {
    catalog
        .get("tracks")
        .and_then(|t| t.as_array())
        .map(|tracks| {
            tracks
                .iter()
                .filter_map(|t| t.get("name").and_then(|n| n.as_str()).map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

fn slice(data: &Bytes, offset: u64, len: u64) -> anyhow::Result<Bytes> {
    let start = usize::try_from(offset)?;
    let end = start
        .checked_add(usize::try_from(len)?)
        .context("byte range overflows")?;
    anyhow::ensure!(
        end <= data.len(),
        "byte range {}..{} exceeds the file",
        start,
        end
    );
    Ok(data.slice(start..end))
}

pub fn sha256_hex(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

/// JSON path of the first difference between two parsed documents, or `None` when equal.
/// Key order never counts; `serde_json::Value` maps compare as sets of entries.
pub fn first_difference(
    a: &serde_json::Value,
    b: &serde_json::Value,
    path: &str,
) -> Option<String> {
    use serde_json::Value;
    match (a, b) {
        (Value::Object(x), Value::Object(y)) => {
            let mut keys: Vec<&String> = x.keys().chain(y.keys()).collect();
            keys.sort();
            keys.dedup();
            for key in keys {
                let sub = format!("{}.{}", path, key);
                match (x.get(key), y.get(key)) {
                    (Some(xv), Some(yv)) => {
                        if let Some(d) = first_difference(xv, yv, &sub) {
                            return Some(d);
                        }
                    }
                    _ => return Some(sub),
                }
            }
            None
        }
        (Value::Array(x), Value::Array(y)) => {
            if x.len() != y.len() {
                return Some(format!("{}.length", path));
            }
            for (i, (xv, yv)) in x.iter().zip(y.iter()).enumerate() {
                if let Some(d) = first_difference(xv, yv, &format!("{}[{}]", path, i)) {
                    return Some(d);
                }
            }
            None
        }
        (x, y) if x == y => None,
        _ => Some(path.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn catalog_difference_ignores_key_order_and_finds_the_first_change() {
        let a =
            json!({"version": "draft-01", "tracks": [{"name": "video", "codec": "avc1.4d401e"}]});
        let b =
            json!({"tracks": [{"codec": "avc1.4d401e", "name": "video"}], "version": "draft-01"});
        assert_eq!(first_difference(&a, &b, "$"), None);
        let c =
            json!({"version": "draft-01", "tracks": [{"name": "video", "codec": "avc1.640028"}]});
        assert_eq!(
            first_difference(&a, &c, "$").as_deref(),
            Some("$.tracks[0].codec")
        );
        let d = json!({"version": "draft-01", "tracks": []});
        assert_eq!(
            first_difference(&a, &d, "$").as_deref(),
            Some("$.tracks.length")
        );
        let e = json!({"version": "draft-01", "tracks": [{"name": "video"}]});
        assert_eq!(
            first_difference(&a, &e, "$").as_deref(),
            Some("$.tracks[0].codec")
        );
    }

    #[test]
    fn catalog_track_names_follow_the_catalog_order() {
        let c = json!({"tracks": [{"name": "video"}, {"name": "audio"}]});
        assert_eq!(catalog_track_names(&c), vec!["video", "audio"]);
        assert!(catalog_track_names(&json!({})).is_empty());
    }

    #[test]
    fn sha256_hex_is_lowercase_hex() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }
}
