//! The checker: subscriber sessions that read the catalog and the media tracks through the
//! relay, record every object with its hash and arrival time, and the four oracle checks of
//! docs/tests/media/cmsf.md over what arrived.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Context;
use bytes::Bytes;
use moq_net::Error;
use moq_tokio::moq_net;
use serde_json::{json, Value};

use crate::fixture::{first_difference, sha256_hex, Fixture, Track};
use crate::tap::Check;
use crate::Session;

/// A subscriber session: the scoped origin, the routed broadcast and the connection.
pub struct Subscriber {
    /// Keeps the scoped origin alive.
    _root: moq_net::origin::Producer,
    broadcast: moq_net::broadcast::Consumer,
    pub connection: moq_tokio::Connection,
    pub session: Session,
    /// Kept so a scenario can hold a subscription open for the rest of the test.
    pub held: Vec<moq_net::track::Subscriber>,
}

impl Subscriber {
    /// Dial the relay as a subscriber of `namespace` and wait until the relay routes the
    /// publisher's announcement to us.
    pub async fn connect(
        client: &moq_tokio::Client,
        relay_url: &url::Url,
        namespace: &str,
        route_within: Duration,
    ) -> anyhow::Result<Self> {
        let root = moq_tokio::origin::spawn();
        let origin = scoped(&root, namespace)?;
        let consumer = origin.consume();
        let connection = client
            .clone()
            .with_subscriber(origin)
            .connect(relay_url.clone())
            .established()
            .await
            .context("subscriber failed to connect")?;
        let session = Session::from_connection(&connection, relay_url);

        let broadcast = tokio::time::timeout(route_within, consumer.routed_broadcast(namespace))
            .await
            .with_context(|| {
                format!(
                    "the relay did not route the namespace to the subscriber within {} ms",
                    route_within.as_millis()
                )
            })?
            .context("broadcast never became routable")?;

        Ok(Self {
            _root: root,
            broadcast,
            connection,
            session,
            held: Vec::new(),
        })
    }

    /// Subscribe to `catalog` and read Object 0 of its first group. Returns the payload,
    /// the subscriber (so a scenario can keep it open) and how long the object took.
    pub async fn read_catalog(
        &self,
        deadline: Duration,
    ) -> anyhow::Result<(Bytes, moq_net::track::Subscriber, Duration)> {
        let started = Instant::now();
        let track = self
            .broadcast
            .track("catalog")
            .context("failed to request the catalog track")?;
        let mut subscriber = track
            .subscribe(None)
            .await
            .context("catalog subscription rejected")?;

        let group = match tokio::time::timeout(deadline, subscriber.recv_group()).await {
            Ok(Ok(Some(group))) => group,
            Ok(Ok(None)) => anyhow::bail!("the catalog track ended before delivering a group"),
            Ok(Err(e)) if is_request_error(&e) => {
                anyhow::bail!(
                    "the relay answered the catalog SUBSCRIBE with REQUEST_ERROR ({})",
                    e
                )
            }
            Ok(Err(e)) => anyhow::bail!("the catalog subscription failed locally ({})", e),
            Err(_) => anyhow::bail!(
                "no catalog object arrived within {} ms of the SUBSCRIBE (and no REQUEST_ERROR)",
                deadline.as_millis()
            ),
        };
        let mut group = group;
        let remaining = deadline.saturating_sub(started.elapsed());
        let frame = match tokio::time::timeout(remaining, group.read_frame()).await {
            Ok(Ok(Some(frame))) => frame,
            Ok(Ok(None)) => anyhow::bail!("catalog group {} arrived empty", group.sequence),
            Ok(Err(e)) => anyhow::bail!("reading the catalog object failed ({})", e),
            Err(_) => anyhow::bail!(
                "catalog group {} opened but its object did not arrive in time",
                group.sequence
            ),
        };
        Ok((frame.payload, subscriber, started.elapsed()))
    }

    /// Subscribe to the named media tracks.
    pub async fn subscribe_media(
        &self,
        names: &[String],
    ) -> anyhow::Result<Vec<(String, moq_net::track::Subscriber)>> {
        let mut out = Vec::new();
        for name in names {
            let track = self
                .broadcast
                .track(name.as_str())
                .with_context(|| format!("failed to request track {}", name))?;
            // A tolerant max age: a late object of group g must not be abandoned because
            // group g + 1 started on another stream. Clamped to the publisher's max age.
            let subscription =
                moq_net::track::Subscription::default().with_max_age(Duration::from_secs(10));
            out.push((name.clone(), track.subscribe(subscription)));
        }
        // Resolve the subscriptions after sending every SUBSCRIBE.
        let mut resolved = Vec::new();
        for (name, pending) in out {
            let subscriber = pending
                .await
                .with_context(|| format!("subscription to {} rejected", name))?;
            resolved.push((name, subscriber));
        }
        Ok(resolved)
    }

    /// Close the session, subscriber first, letting CONNECTION_CLOSE go out.
    pub async fn close(self) {
        drop(self.held);
        self.connection.abort(Error::Cancel);
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// The catalog check over a received catalog.
pub fn check_catalog(fixture: &Fixture, received: &[u8]) -> Result<(), String> {
    let parsed: Value = serde_json::from_slice(received)
        .map_err(|e| format!("received catalog does not parse as JSON: {}", e))?;
    match first_difference(&fixture.catalog_json, &parsed, "$") {
        None => Ok(()),
        Some(path) => Err(format!(
            "received catalog differs from the expected one at {}",
            path
        )),
    }
}

/// One received media object.
#[derive(Debug, Clone)]
pub struct Received {
    pub track: String,
    pub group: u64,
    pub object: u64,
    pub payload: Bytes,
    pub sha256: String,
    pub at: Instant,
}

/// Why a track's delivery stopped, when it did not stop by completing.
#[derive(Debug, Clone)]
pub enum TrackEnd {
    /// The relay ended the track (PUBLISH_DONE forwarded).
    Finished,
    /// The subscription was aborted; `request_error` says whether with REQUEST_ERROR.
    Aborted { error: String, request_error: bool },
}

enum Event {
    GroupStart {
        track: String,
        group: u64,
    },
    Object(Received),
    GroupEnd {
        track: String,
        group: u64,
        old: bool,
    },
    TrackEnd {
        track: String,
        end: TrackEnd,
    },
}

/// Everything a collection run observed.
#[derive(Debug, Default)]
pub struct Collected {
    pub objects: Vec<Received>,
    /// Groups in the order the relay opened them, per track: the wire-level group order.
    pub group_starts: Vec<(String, u64)>,
    pub ends: BTreeMap<String, TrackEnd>,
    pub old_groups: Vec<(String, u64)>,
    pub timed_out: bool,
}

impl Collected {
    /// The Group IDs of `track` in the order they were opened.
    pub fn starts(&self, track: &str) -> Vec<u64> {
        self.group_starts
            .iter()
            .filter(|(t, _)| t == track)
            .map(|(_, g)| *g)
            .collect()
    }
}

/// Read every object from `subscribers` until each track has delivered the last object of
/// `until_group` (per the manifest), every track has ended, or `deadline` passes.
pub async fn collect(
    subscribers: Vec<(String, moq_net::track::Subscriber)>,
    fixture: Arc<Fixture>,
    until_group: u64,
    deadline: Instant,
) -> Collected {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Event>();
    let mut tasks = Vec::new();
    let mut pending: BTreeSet<String> = subscribers.iter().map(|(n, _)| n.clone()).collect();

    for (name, mut subscriber) in subscribers {
        let tx = tx.clone();
        tasks.push(tokio::spawn(async move {
            loop {
                match subscriber.recv_group().await {
                    Ok(Some(mut group)) => {
                        let _ = tx.send(Event::GroupStart { track: name.clone(), group: group.sequence });
                        let tx = tx.clone();
                        let name = name.clone();
                        tokio::spawn(async move {
                            let sequence = group.sequence;
                            loop {
                                let index = group.index();
                                match group.read_frame().await {
                                    Ok(Some(frame)) => {
                                        let sha256 = sha256_hex(&frame.payload);
                                        let _ = tx.send(Event::Object(Received {
                                            track: name.clone(),
                                            group: sequence,
                                            object: index,
                                            payload: frame.payload,
                                            sha256,
                                            at: Instant::now(),
                                        }));
                                    }
                                    Ok(None) => {
                                        let _ = tx.send(Event::GroupEnd { track: name, group: sequence, old: false });
                                        break;
                                    }
                                    Err(Error::Old) => {
                                        let _ = tx.send(Event::GroupEnd { track: name, group: sequence, old: true });
                                        break;
                                    }
                                    Err(e) => {
                                        tracing::debug!(track = %name, group = sequence, error = %e, "group read ended");
                                        let _ = tx.send(Event::GroupEnd { track: name, group: sequence, old: false });
                                        break;
                                    }
                                }
                            }
                        });
                    }
                    Ok(None) => {
                        let _ = tx.send(Event::TrackEnd { track: name, end: TrackEnd::Finished });
                        break;
                    }
                    Err(e) => {
                        let _ = tx.send(Event::TrackEnd {
                            track: name,
                            end: TrackEnd::Aborted {
                                error: e.to_string(),
                                request_error: is_request_error(&e),
                            },
                        });
                        break;
                    }
                }
            }
        }));
    }
    drop(tx);

    let mut collected = Collected::default();
    let mut done: BTreeSet<String> = BTreeSet::new();
    loop {
        if pending.is_empty() {
            break;
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            collected.timed_out = true;
            break;
        }
        match tokio::time::timeout(remaining, rx.recv()).await {
            Ok(Some(Event::GroupStart { track, group })) => {
                collected.group_starts.push((track, group));
            }
            Ok(Some(Event::Object(received))) => {
                let track = fixture.tracks.get(&received.track);
                let last = track.and_then(|t| t.last_object(until_group));
                if received.group == until_group && Some(received.object) == last {
                    done.insert(received.track.clone());
                    pending.remove(&received.track);
                }
                collected.objects.push(received);
            }
            Ok(Some(Event::GroupEnd { track, group, old })) => {
                if old {
                    collected.old_groups.push((track, group));
                }
            }
            Ok(Some(Event::TrackEnd { track, end })) => {
                pending.remove(&track);
                collected.ends.insert(track, end);
            }
            Ok(None) => break,
            Err(_) => {
                collected.timed_out = true;
                break;
            }
        }
    }
    for task in tasks {
        task.abort();
    }
    let _ = done;
    collected
}

/// Per-track verification results and diagnostics.
#[derive(Debug, Default, Clone)]
pub struct TrackReport {
    pub groups: usize,
    pub objects: usize,
    pub bytes: usize,
    pub first_group: Option<u64>,
    pub first_object: Option<u64>,
    pub last_group: Option<u64>,
    pub complete_groups: Vec<u64>,
    pub decoded_frames: Option<u64>,
    pub expected_frames: u64,
    pub first_mismatch: Option<Value>,
    pub ordering_error: Option<String>,
    pub decode_error: Option<String>,
    pub first_at: Option<Instant>,
    pub last_at: Option<Instant>,
}

/// The byte-identical and ordering checks over one track's received objects (in the order
/// they were read) and its groups (in the order the relay opened them).
pub fn verify_track(track: &Track, received: &[&Received], starts: &[u64]) -> TrackReport {
    let mut report = TrackReport {
        objects: received.len(),
        ..Default::default()
    };
    if received.is_empty() {
        report.ordering_error = Some("no object received".into());
        return report;
    }
    report.bytes = received.iter().map(|r| r.payload.len()).sum();
    report.first_at = received.first().map(|r| r.at);
    report.last_at = received.last().map(|r| r.at);

    // byte-identical: every object matches the manifest's hash for its (group, object).
    for r in received {
        match track.object(r.group, r.object) {
            Some(expected) if expected.sha256 == r.sha256 => {}
            Some(expected) => {
                report.first_mismatch = Some(json!({
                    "track": track.name, "group": r.group, "object": r.object,
                    "expected": expected.sha256, "got": r.sha256, "bytes": r.payload.len(),
                }));
                break;
            }
            None => {
                report.first_mismatch = Some(json!({
                    "track": track.name, "group": r.group, "object": r.object,
                    "expected": Value::Null, "got": r.sha256, "bytes": r.payload.len(),
                }));
                break;
            }
        }
    }

    // ordering: groups opened with strictly increasing Group ID; within a group, objects
    // consecutive in the order read; no (group, object) twice; every group between the
    // first and last received present, complete except for the head of the first. Objects
    // of adjacent groups may interleave in time (independent streams, a late head fill).
    let mut seen: BTreeSet<(u64, u64)> = BTreeSet::new();
    let mut per_group: BTreeMap<u64, Vec<u64>> = BTreeMap::new();
    let mut error: Option<String> = None;
    for pair in starts.windows(2) {
        if pair[1] <= pair[0] {
            error.get_or_insert(if pair[1] == pair[0] {
                format!("group {} opened twice", pair[1])
            } else {
                format!("group {} opened after group {}", pair[1], pair[0])
            });
            break;
        }
    }
    for r in received {
        if !seen.insert((r.group, r.object)) {
            error.get_or_insert(format!(
                "group {} object {} arrived twice",
                r.group, r.object
            ));
        }
        per_group.entry(r.group).or_default().push(r.object);
    }
    let first_group = *per_group.keys().next().unwrap();
    report.first_group = Some(first_group);
    report.first_object = per_group[&first_group].first().copied();
    report.last_group = per_group.keys().next_back().copied();
    report.groups = per_group.len();
    let last_group = report.last_group.unwrap();

    for g in first_group..=last_group {
        let Some(objects) = per_group.get(&g) else {
            error.get_or_insert(format!("group {} is missing", g));
            continue;
        };
        let Some(last) = track.last_object(g) else {
            error.get_or_insert(format!("group {} is not in the manifest", g));
            continue;
        };
        let start = if g == first_group { objects[0] } else { 0 };
        let expected: Vec<u64> = (start..=last).collect();
        if objects != &expected {
            if g != first_group && objects[0] != 0 {
                error.get_or_insert(format!("group {} started at object {}", g, objects[0]));
            } else if objects.iter().any(|o| *o > last) {
                error.get_or_insert(format!(
                    "group {} has an object beyond the manifest's last ({})",
                    g, last
                ));
            } else if objects.last() != Some(&last) {
                error.get_or_insert(format!(
                    "group {} ended at object {}, before the manifest's last ({})",
                    g,
                    objects.last().unwrap(),
                    last
                ));
            } else {
                error.get_or_insert(format!("group {} objects out of order or with a gap", g));
            }
            continue;
        }
        if start == 0 {
            report.complete_groups.push(g);
        }
    }
    report.ordering_error = error;
    report
}

/// The decode check: write init + the complete groups' objects in order, run ffprobe,
/// compare the decoded frame count with the manifest's sample counts.
pub async fn decode_track(
    track: &Track,
    received: &[&Received],
    report: &mut TrackReport,
    work: &Path,
) {
    let complete: BTreeSet<u64> = report.complete_groups.iter().copied().collect();
    let mut objects: Vec<&Received> = received
        .iter()
        .copied()
        .filter(|r| complete.contains(&r.group))
        .collect();
    objects.sort_by_key(|r| (r.group, r.object));
    report.expected_frames = objects
        .iter()
        .filter_map(|r| track.object(r.group, r.object))
        .map(|o| o.samples)
        .sum();
    if objects.is_empty() {
        report.decode_error = Some("no complete group to decode".into());
        return;
    }
    let path = work.join(format!("{}.mp4", track.name));
    let mut data = Vec::with_capacity(track.init.len() + report.bytes);
    data.extend_from_slice(&track.init);
    for r in &objects {
        data.extend_from_slice(&r.payload);
    }
    if let Err(e) = tokio::fs::write(&path, &data).await {
        report.decode_error = Some(format!("writing {}: {}", path.display(), e));
        return;
    }
    let stream = if track.is_video() { "v:0" } else { "a:0" };
    let output = tokio::process::Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-count_frames",
            "-select_streams",
            stream,
            "-show_entries",
            "stream=nb_read_frames",
            "-of",
            "csv=p=0",
        ])
        .arg(&path)
        .output()
        .await;
    let output = match output {
        Ok(output) => output,
        Err(e) => {
            report.decode_error = Some(format!("running ffprobe: {}", e));
            return;
        }
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let frames = stdout.trim().trim_end_matches(',').parse::<u64>().ok();
    report.decoded_frames = frames;
    if !stderr.trim().is_empty() {
        report.decode_error = Some(format!(
            "ffprobe: {}",
            stderr.lines().next().unwrap_or("error").trim()
        ));
    } else if frames != Some(report.expected_frames) {
        report.decode_error = Some(format!(
            "{} frames decoded, {} expected",
            frames.map(|f| f.to_string()).unwrap_or_else(|| "no".into()),
            report.expected_frames
        ));
    }
}

/// The per-track `tracks` diagnostics mapping.
pub fn track_diag(report: &TrackReport) -> Value {
    let mut m = serde_json::Map::new();
    m.insert("groups".into(), json!(report.groups));
    m.insert("objects".into(), json!(report.objects));
    m.insert("bytes".into(), json!(report.bytes));
    if let Some(g) = report.first_group {
        m.insert("first_group".into(), json!(g));
    }
    if let Some(o) = report.first_object {
        m.insert("first_object".into(), json!(o));
    }
    if let Some(g) = report.last_group {
        m.insert("last_group".into(), json!(g));
    }
    m.insert(
        "complete_groups".into(),
        json!(report.complete_groups.len()),
    );
    if let Some(f) = report.decoded_frames {
        m.insert("decoded_frames".into(), json!(f));
    }
    m.insert("expected_frames".into(), json!(report.expected_frames));
    Value::Object(m)
}

/// Summarize the four checks across tracks into TAP subtests. `required` says which
/// groups every track must have delivered completely; `catalog` is the catalog result.
pub fn summarize(
    catalog: Result<String, String>,
    reports: &BTreeMap<String, TrackReport>,
    required: std::ops::RangeInclusive<u64>,
    collected: &Collected,
) -> Vec<Check> {
    let mut checks = Vec::new();
    match catalog {
        Ok(detail) => checks.push(Check::new("catalog", true, detail)),
        Err(e) => checks.push(Check::new("catalog", false, e)),
    }

    let mismatch = reports.values().find_map(|r| r.first_mismatch.clone());
    let total_objects: usize = reports.values().map(|r| r.objects).sum();
    match mismatch {
        None if total_objects > 0 => checks.push(Check::new(
            "byte-identical",
            true,
            format!("{} objects match the manifest", total_objects),
        )),
        None => checks.push(Check::new(
            "byte-identical",
            false,
            "no media object received",
        )),
        Some(m) => checks.push(Check::new(
            "byte-identical",
            false,
            format!(
                "{} group {} object {} differs",
                m["track"].as_str().unwrap_or("?"),
                m["group"],
                m["object"]
            ),
        )),
    }

    let mut ordering_errors: Vec<String> = Vec::new();
    for (name, r) in reports {
        if let Some(e) = &r.ordering_error {
            ordering_errors.push(format!("{}: {}", name, e));
        }
        for g in required.clone() {
            if r.ordering_error.is_none() && !r.complete_groups.contains(&g) {
                ordering_errors.push(format!("{}: group {} not delivered completely", name, g));
                break;
            }
        }
    }
    for (track, group) in &collected.old_groups {
        ordering_errors.push(format!("{}: group {} abandoned as too old", track, group));
    }
    for (track, end) in &collected.ends {
        if let TrackEnd::Aborted {
            error,
            request_error,
        } = end
        {
            ordering_errors.push(format!(
                "{}: subscription aborted {} ({})",
                track,
                if *request_error {
                    "with REQUEST_ERROR"
                } else {
                    "locally"
                },
                error
            ));
        }
    }
    if collected.timed_out {
        ordering_errors.push("delivery did not complete before the deadline".into());
    }
    if ordering_errors.is_empty() {
        let groups: usize = reports.values().map(|r| r.groups).sum();
        checks.push(Check::new(
            "ordering",
            true,
            format!(
                "{} groups in order, groups {}-{} complete on every track",
                groups,
                required.start(),
                required.end()
            ),
        ));
    } else {
        checks.push(Check::new("ordering", false, ordering_errors.join("; ")));
    }

    let decode_errors: Vec<String> = reports
        .iter()
        .filter_map(|(n, r)| r.decode_error.as_ref().map(|e| format!("{}: {}", n, e)))
        .collect();
    if decode_errors.is_empty() {
        let frames: Vec<String> = reports
            .iter()
            .map(|(n, r)| format!("{} {} frames", n, r.decoded_frames.unwrap_or(0)))
            .collect();
        checks.push(Check::new("decode", true, frames.join(", ")));
    } else {
        checks.push(Check::new("decode", false, decode_errors.join("; ")));
    }
    checks
}

/// Whether a subscription's abort error is what moq-net makes of a REQUEST_ERROR code, as
/// opposed to a local failure (an answer that did not decode, a dead session, …).
pub fn is_request_error(err: &Error) -> bool {
    matches!(
        err,
        Error::Unauthorized
            | Error::Timeout
            | Error::Unsupported
            | Error::NotFound
            | Error::Unroutable
            | Error::MalformedTrack
            | Error::GoingAway
            | Error::Remote(_)
    )
}

/// A subscriber origin scoped to `namespace`, so moq-net's namespace discovery asks the
/// relay for that prefix (SUBSCRIBE_NAMESPACE `namespace`) rather than the empty prefix,
/// which draft-14 forbids and which several relays reject. Keep `root` alive for as long
/// as the scoped origin.
fn scoped(
    root: &moq_net::origin::Producer,
    namespace: &str,
) -> anyhow::Result<moq_net::origin::Producer> {
    let patterns = moq_net::Patterns::from(
        moq_net::Pattern::subtree(namespace).context("invalid namespace pattern")?,
    );
    root.scope("", &patterns)
        .context("failed to scope the subscriber origin")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixture::{ByteRange, Object, TrackManifest};

    fn track(objects_per_group: &[usize]) -> Track {
        let mut objects = Vec::new();
        for (g, n) in objects_per_group.iter().enumerate() {
            for o in 0..*n {
                let payload = Bytes::from(format!("g{}o{}", g, o));
                objects.push(Object {
                    group: g as u64,
                    object: o as u64,
                    tfdt: (g * 1000 + o * 200) as u64,
                    samples: 6,
                    sha256: sha256_hex(&payload),
                    payload,
                });
            }
        }
        Track {
            name: "video".into(),
            manifest: TrackManifest {
                file: "video.mp4".into(),
                sha256: String::new(),
                codec: "avc1.4d401e".into(),
                timescale: 1000,
                frames: 6 * objects.len() as u64,
                init: ByteRange {
                    offset: 0,
                    bytes: 0,
                    sha256: String::new(),
                },
                groups: Vec::new(),
            },
            init: Bytes::new(),
            objects,
        }
    }

    fn received(track: &Track, items: &[(u64, u64)]) -> Vec<Received> {
        let base = Instant::now();
        items
            .iter()
            .enumerate()
            .map(|(i, (g, o))| {
                let payload = track
                    .object(*g, *o)
                    .map(|x| x.payload.clone())
                    .unwrap_or_else(|| Bytes::from_static(b"bogus"));
                Received {
                    track: "video".into(),
                    group: *g,
                    object: *o,
                    sha256: sha256_hex(&payload),
                    payload,
                    at: base + Duration::from_millis(i as u64),
                }
            })
            .collect()
    }

    fn starts(items: &[(u64, u64)]) -> Vec<u64> {
        let mut out: Vec<u64> = Vec::new();
        for (g, _) in items {
            if !out.contains(g) {
                out.push(*g);
            }
        }
        out
    }

    fn report(track: &Track, items: &[(u64, u64)]) -> TrackReport {
        let rx = received(track, items);
        let refs: Vec<&Received> = rx.iter().collect();
        verify_track(track, &refs, &starts(items))
    }

    #[test]
    fn complete_delivery_passes() {
        let t = track(&[2, 2, 2]);
        let r = report(&t, &[(0, 0), (0, 1), (1, 0), (1, 1), (2, 0), (2, 1)]);
        assert!(r.ordering_error.is_none(), "{:?}", r.ordering_error);
        assert!(r.first_mismatch.is_none());
        assert_eq!(r.complete_groups, vec![0, 1, 2]);
        assert_eq!(
            (r.first_group, r.first_object, r.last_group),
            (Some(0), Some(0), Some(2))
        );
    }

    #[test]
    fn a_join_mid_group_is_permitted_and_excluded_from_complete_groups() {
        let t = track(&[2, 2, 2]);
        let r = report(&t, &[(1, 1), (2, 0), (2, 1)]);
        assert!(r.ordering_error.is_none(), "{:?}", r.ordering_error);
        assert_eq!(r.complete_groups, vec![2]);
        assert_eq!(r.first_object, Some(1));
    }

    #[test]
    fn a_missing_group_fails_ordering() {
        let t = track(&[2, 2, 2]);
        let r = report(&t, &[(0, 0), (0, 1), (2, 0), (2, 1)]);
        assert_eq!(r.ordering_error.as_deref(), Some("group 1 is missing"));
    }

    #[test]
    fn a_duplicate_object_fails_ordering() {
        let t = track(&[2, 2]);
        let r = report(&t, &[(0, 0), (0, 1), (0, 1), (1, 0), (1, 1)]);
        assert_eq!(
            r.ordering_error.as_deref(),
            Some("group 0 object 1 arrived twice")
        );
    }

    #[test]
    fn a_later_group_opened_before_an_earlier_one_fails_ordering() {
        let t = track(&[2, 2]);
        let r = report(&t, &[(1, 0), (1, 1), (0, 0), (0, 1)]);
        assert_eq!(
            r.ordering_error.as_deref(),
            Some("group 0 opened after group 1")
        );
    }

    #[test]
    fn objects_of_adjacent_groups_may_interleave_in_time() {
        // Group 1's objects are read (a late fill of its head) after group 2 has started;
        // the groups were opened in order, so this is permitted variation.
        let t = track(&[2, 2, 2]);
        let rx = received(&t, &[(2, 0), (1, 0), (1, 1), (2, 1)]);
        let refs: Vec<&Received> = rx.iter().collect();
        let r = verify_track(&t, &refs, &[1, 2]);
        assert!(r.ordering_error.is_none(), "{:?}", r.ordering_error);
        assert_eq!(r.complete_groups, vec![1, 2]);
    }

    #[test]
    fn a_truncated_last_group_fails_ordering() {
        let t = track(&[2, 2]);
        let r = report(&t, &[(0, 0), (0, 1), (1, 0)]);
        assert_eq!(
            r.ordering_error.as_deref(),
            Some("group 1 ended at object 0, before the manifest's last (1)")
        );
    }

    #[test]
    fn a_corrupted_payload_fails_byte_identity() {
        let t = track(&[2]);
        let mut rx = received(&t, &[(0, 0), (0, 1)]);
        rx[1].payload = Bytes::from_static(b"corrupt");
        rx[1].sha256 = sha256_hex(&rx[1].payload);
        let refs: Vec<&Received> = rx.iter().collect();
        let r = verify_track(&t, &refs, &[0]);
        let m = r.first_mismatch.expect("a mismatch");
        assert_eq!(
            (m["group"].as_u64(), m["object"].as_u64()),
            (Some(0), Some(1))
        );
        assert!(r.ordering_error.is_none());
    }

    #[test]
    fn an_object_the_manifest_lacks_fails_byte_identity() {
        let t = track(&[2]);
        let r = report(&t, &[(0, 0), (0, 1), (0, 2)]);
        let m = r.first_mismatch.expect("a mismatch");
        assert!(m["expected"].is_null());
        assert!(r.ordering_error.is_some());
    }

    #[test]
    fn summarize_requires_the_required_groups() {
        let t = track(&[2, 2, 2]);
        let mut reports = BTreeMap::new();
        reports.insert(
            "video".to_string(),
            report(&t, &[(0, 0), (0, 1), (1, 0), (1, 1)]),
        );
        let checks = summarize(Ok("equal".into()), &reports, 1..=2, &Collected::default());
        let ordering = checks.iter().find(|c| c.name == "ordering").unwrap();
        assert!(!ordering.ok);
        assert!(
            ordering.detail.contains("group 2 not delivered completely"),
            "{}",
            ordering.detail
        );
        let checks = summarize(Ok("equal".into()), &reports, 0..=1, &Collected::default());
        assert!(checks.iter().find(|c| c.name == "ordering").unwrap().ok);
    }
}
