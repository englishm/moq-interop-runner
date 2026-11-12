//! The fixture and its packaging: the transport stream lib/media/mpeg-ts/make-fixture.sh
//! generates at image build, cut into groups and objects as moq-dev's `import ts --passthrough`
//! lays a multiplex out (the `moq-dev-m2ts` packaging), each object timed by the PCR.
//!
//! A group starts at each packet with `random_access_indicator` on the video PID; an object
//! runs from one PCR packet on the clock PID to the next, and is also cut where a group starts.
//! Packets before the first group are not published, null packets are kept. On the wire every
//! object is the hang Legacy container: a QUIC varint timestamp in microseconds, the PCR time of
//! its first byte counted from the first object's, then the packets.

use std::path::{Path, PathBuf};

use anyhow::{bail, Context};
use bytes::{BufMut, Bytes, BytesMut};

pub const PACKET: usize = 188;
const SYNC: u8 = 0x47;
const NULL_PID: u16 = 0x1FFF;
const PCR_HZ: f64 = 27_000_000.0;
/// Stream types a PMT declares video with: MPEG-1, MPEG-2, MPEG-4 part 2, H.264, H.264 SVC,
/// HEVC.
const VIDEO_STREAM_TYPES: [u8; 6] = [0x01, 0x02, 0x10, 0x1B, 0x20, 0x24];

/// The packaging's name, reported as `ts_packaging`.
pub const PACKAGING: &str = "moq-dev-m2ts";
/// The track the catalog names, as moq-dev's importer names its first track.
pub const TRACK: &str = "0.m2ts";
/// moq-dev's hang catalog track.
pub const CATALOG: &str = "catalog.json";

pub struct Object {
    pub group: u64,
    pub object: u64,
    /// When a live importer would have the object whole: the arrival, relative to the
    /// fixture's first packet, of the packet after its last.
    pub ready_secs: f64,
    /// The PCR time of its first byte, in microseconds from the first object's.
    pub timestamp_us: u64,
    /// The object as published: the Legacy timestamp, then the packets.
    pub payload: Bytes,
}

pub struct Fixture {
    pub path: PathBuf,
    pub packets: usize,
    pub nulls: usize,
    pub mux_rate: u64,
    pub duration_secs: f64,
    pub groups: u64,
    pub objects: Vec<Object>,
    pub catalog: Bytes,
}

impl Fixture {
    pub fn load(dir: &Path) -> anyhow::Result<Self> {
        let path = dir.join("fixture.ts");
        let data = std::fs::read(&path).with_context(|| format!("reading {}", path.display()))?;
        if data.is_empty() || data.len() % PACKET != 0 {
            bail!("{} is not whole 188-byte packets", path.display());
        }
        let pkts: Vec<&[u8]> = data.chunks(PACKET).collect();
        if let Some(i) = pkts.iter().position(|p| p[0] != SYNC) {
            bail!("packet {} has no sync byte", i);
        }

        let (video_pid, pcr_pid) = program(&pkts)?;
        let pcrs: Vec<(usize, u64)> = pkts
            .iter()
            .enumerate()
            .filter(|(_, p)| pid(p) == pcr_pid)
            .filter_map(|(i, p)| pcr(p).map(|v| (i, v)))
            .collect();
        if pcrs.len() < 2 {
            bail!("fewer than two PCRs on PID {:#x}", pcr_pid);
        }
        if pcrs.windows(2).any(|w| w[1].1 <= w[0].1) {
            bail!("the PCR does not increase; the fixture must not wrap or restart its clock");
        }
        let times = packet_times(pkts.len(), &pcrs);
        let (first, last) = (pcrs[0], pcrs[pcrs.len() - 1]);
        let mux_rate = (((last.0 - first.0) * PACKET * 8) as f64
            / ((last.1 - first.1) as f64 / PCR_HZ))
            .round() as u64;
        let packet_secs = (PACKET * 8) as f64 / mux_rate as f64;
        let arrival = |i: usize| {
            if i < pkts.len() {
                times[i]
            } else {
                times[pkts.len() - 1] + packet_secs
            }
        };

        let is_start = |i: usize| pid(pkts[i]) == video_pid && random_access(pkts[i]);
        let first_start = (0..pkts.len())
            .find(|&i| is_start(i))
            .context("no random access point on the video PID")?;
        // Object boundaries: every group start and every PCR packet from the first group on.
        let mut cuts: Vec<(usize, bool)> = (first_start..pkts.len())
            .filter(|&i| is_start(i) || (pid(pkts[i]) == pcr_pid && pcr(pkts[i]).is_some()))
            .map(|i| (i, is_start(i)))
            .collect();
        cuts.push((pkts.len(), false));

        let base = times[first_start];
        let mut objects = Vec::new();
        let mut groups = 0u64;
        let mut group: Option<u64> = None;
        let mut object = 0u64;
        for w in cuts.windows(2) {
            let ((from, starts), (to, _)) = (w[0], w[1]);
            if starts {
                let next = group.map_or(0, |g| g + 1);
                group = Some(next);
                groups += 1;
                object = 0;
            }
            let stamp = ((times[from] - base) * 1e6).floor().max(0.0) as u64;
            let mut payload = BytesMut::with_capacity(8 + (to - from) * PACKET);
            put_varint(&mut payload, stamp);
            for p in &pkts[from..to] {
                payload.put_slice(p);
            }
            objects.push(Object {
                group: group.expect("cuts begin at a group start"),
                object,
                ready_secs: arrival(to),
                timestamp_us: stamp,
                payload: payload.freeze(),
            });
            object += 1;
        }

        let catalog = serde_json::to_vec(&serde_json::json!({
            "m2ts": { "track": TRACK, "randomAccess": true, "muxRate": mux_rate }
        }))?;
        Ok(Self {
            path,
            packets: pkts.len(),
            nulls: pkts.iter().filter(|p| pid(p) == NULL_PID).count(),
            mux_rate,
            duration_secs: arrival(pkts.len()),
            groups,
            objects,
            catalog: Bytes::from(catalog),
        })
    }

    pub fn summary(&self) -> String {
        format!(
            "mpeg-ts {} ms, {} b/s, {} packets ({} null); {} {} groups, {} objects",
            (self.duration_secs * 1000.0).round(),
            self.mux_rate,
            self.packets,
            self.nulls,
            PACKAGING,
            self.groups,
            self.objects.len()
        )
    }
}

fn pid(p: &[u8]) -> u16 {
    (((p[1] & 0x1F) as u16) << 8) | p[2] as u16
}

/// The adaptation field's flags byte, when the packet has a non-empty adaptation field.
fn af_flags(p: &[u8]) -> Option<u8> {
    let control = (p[3] >> 4) & 0x3;
    (control & 0x2 != 0 && p[4] > 0).then(|| p[5])
}

fn random_access(p: &[u8]) -> bool {
    af_flags(p).is_some_and(|f| f & 0x40 != 0)
}

/// The packet's PCR in 27 MHz ticks.
fn pcr(p: &[u8]) -> Option<u64> {
    let flags = af_flags(p)?;
    if flags & 0x10 == 0 || p[4] < 7 {
        return None;
    }
    let base = ((p[6] as u64) << 25)
        | ((p[7] as u64) << 17)
        | ((p[8] as u64) << 9)
        | ((p[9] as u64) << 1)
        | ((p[10] as u64) >> 7);
    let ext = (((p[10] & 0x1) as u64) << 8) | p[11] as u64;
    Some(base * 300 + ext)
}

/// The first section a packet starts, when it carries one whole.
fn section(p: &[u8]) -> Option<&[u8]> {
    if p[1] & 0x40 == 0 {
        return None;
    }
    let control = (p[3] >> 4) & 0x3;
    if control & 0x1 == 0 {
        return None;
    }
    let mut off = 4;
    if control & 0x2 != 0 {
        off += 1 + p[4] as usize;
    }
    let pointer = *p.get(off)? as usize;
    let s = p.get(off + 1 + pointer..)?;
    let len = ((((*s.get(1)? & 0x0F) as usize) << 8) | *s.get(2)? as usize) + 3;
    s.get(..len)
}

/// The shortest PAT and PMT sections: their fixed header and the CRC.
const PAT_MIN: usize = 8 + 4;
const PMT_MIN: usize = 12 + 4;

/// The video PID and the clock PID of the PAT's first program.
fn program(pkts: &[&[u8]]) -> anyhow::Result<(u16, u16)> {
    let pat = pkts
        .iter()
        .filter(|p| pid(p) == 0)
        .find_map(|p| section(p).filter(|s| s[0] == 0x00 && s.len() >= PAT_MIN))
        .context("no PAT")?;
    let pmt_pid = pat[8..pat.len() - 4]
        .chunks(4)
        .find(|e| e.len() == 4 && ((e[0] as u16) << 8 | e[1] as u16) != 0)
        .map(|e| (((e[2] & 0x1F) as u16) << 8) | e[3] as u16)
        .context("the PAT lists no program")?;
    let pmt = pkts
        .iter()
        .filter(|p| pid(p) == pmt_pid)
        .find_map(|p| section(p).filter(|s| s[0] == 0x02 && s.len() >= PMT_MIN))
        .context("no PMT in one packet")?;
    let pcr_pid = (((pmt[8] & 0x1F) as u16) << 8) | pmt[9] as u16;
    let mut i = 12 + ((((pmt[10] & 0x0F) as usize) << 8) | pmt[11] as usize);
    let end = pmt.len() - 4;
    while i + 5 <= end {
        let stream_type = pmt[i];
        let es_pid = (((pmt[i + 1] & 0x1F) as u16) << 8) | pmt[i + 2] as u16;
        if VIDEO_STREAM_TYPES.contains(&stream_type) {
            return Ok((es_pid, pcr_pid));
        }
        i += 5 + ((((pmt[i + 3] & 0x0F) as usize) << 8) | pmt[i + 4] as usize);
    }
    bail!("the PMT declares no video stream")
}

/// Each packet's arrival in seconds from the first packet, interpolated between the PCRs
/// either side of it and extrapolated at the nearest rate before the first and after the last.
fn packet_times(count: usize, pcrs: &[(usize, u64)]) -> Vec<f64> {
    let mut times = vec![0.0; count];
    let mut segment = 0;
    for (i, t) in times.iter_mut().enumerate() {
        while segment + 2 < pcrs.len() && i >= pcrs[segment + 1].0 {
            segment += 1;
        }
        let ((a, pa), (b, pb)) = (pcrs[segment], pcrs[segment + 1]);
        let per_packet = (pb - pa) as f64 / (b - a) as f64;
        *t = (pa as f64 + (i as f64 - a as f64) * per_packet) / PCR_HZ;
    }
    let zero = times[0];
    times.iter_mut().for_each(|t| *t -= zero);
    times
}

/// A QUIC variable-length integer (RFC 9000 §16).
fn put_varint(buf: &mut BytesMut, v: u64) {
    if v < 1 << 6 {
        buf.put_u8(v as u8);
    } else if v < 1 << 14 {
        buf.put_u16(0x4000 | v as u16);
    } else if v < 1 << 30 {
        buf.put_u32(0x8000_0000 | v as u32);
    } else {
        buf.put_u64(0xC000_0000_0000_0000 | v);
    }
}

/// Split a Legacy object into its timestamp and its packets; `None` if the varint is cut short.
pub fn split_legacy(payload: &[u8]) -> Option<(u64, &[u8])> {
    let first = *payload.first()?;
    let len = 1usize << (first >> 6);
    let head = payload.get(..len)?;
    let mut v = (first & 0x3F) as u64;
    for b in &head[1..] {
        v = (v << 8) | *b as u64;
    }
    Some((v, &payload[len..]))
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn a_short_pat_is_an_error_not_a_panic() {
        // A PAT whose section_length of 0 leaves only the 3-byte section header.
        let mut p = [0xFF; 188];
        p[..8].copy_from_slice(&[0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0, 0x00]);
        assert!(program(&[&p[..]]).is_err());
    }

    #[test]
    fn a_short_pmt_is_an_error_not_a_panic() {
        // A PAT listing program 1 on PID 0x1000, then a PMT there 8 bytes long.
        let mut pat = [0xFF; 188];
        pat[..21].copy_from_slice(&[
            0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00,
            0x01, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]);
        let mut pmt = [0xFF; 188];
        pmt[..13].copy_from_slice(&[
            0x47, 0x50, 0x00, 0x10, 0x00, 0x02, 0xB0, 0x05, 0x00, 0x01, 0xC1, 0x00, 0x00,
        ]);
        let err = program(&[&pat[..], &pmt[..]]).unwrap_err();
        assert!(err.to_string().contains("no PMT"), "{err}");
    }

    #[test]
    fn varint_round_trips() {
        for v in [
            0,
            63,
            64,
            16_383,
            16_384,
            1_073_741_823,
            1_073_741_824,
            20_000_000,
        ] {
            let mut buf = BytesMut::new();
            put_varint(&mut buf, v);
            buf.put_slice(b"ts");
            let (got, rest) = split_legacy(&buf).unwrap();
            assert_eq!((got, rest), (v, &b"ts"[..]));
        }
    }

    #[test]
    fn a_cut_varint_does_not_split() {
        assert_eq!(split_legacy(&[0x80, 0x01]), None);
        assert_eq!(split_legacy(&[]), None);
    }
}
