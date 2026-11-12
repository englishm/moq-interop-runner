//! Reassembly and the reference oracle: what arrived becomes `received.ts` and the object
//! log (docs/tests/media/mpeg-ts.md, Reassembly), which lib/media/mpeg-ts/check-ts.py grades.

use std::path::Path;
use std::time::Duration;

use anyhow::Context;
use serde_json::{json, Map, Value};

use crate::fixture::split_legacy;
use crate::subscriber::Received;
use crate::tap::Check;

/// The checks and diagnostics `check-ts.py` reported.
pub struct Report {
    pub checks: Vec<Check>,
    pub diag: Map<String, Value>,
}

/// Write `received.ts` (payloads, Legacy header removed, in (group, object) order) and
/// `objects.txt` (`<group> <object> <bytes>` in arrival order) into `dir`. Returns the number
/// of objects whose header did not decode; those are kept whole, so the bytes check fails.
pub fn reassemble(objects: &[Received], dir: &Path) -> anyhow::Result<usize> {
    let mut bad = 0;
    let packets = |r: &Received| -> Vec<u8> {
        match split_legacy(&r.payload) {
            Some((_, packets)) => packets.to_vec(),
            None => r.payload.to_vec(),
        }
    };
    let mut log = String::new();
    for r in objects {
        if split_legacy(&r.payload).is_none() {
            bad += 1;
        }
        log.push_str(&format!("{} {} {}\n", r.group, r.object, packets(r).len()));
    }
    let mut sorted: Vec<&Received> = objects.iter().collect();
    sorted.sort_by_key(|r| (r.group, r.object));
    sorted.dedup_by_key(|r| (r.group, r.object));
    let stream: Vec<u8> = sorted.iter().flat_map(|r| packets(r)).collect();
    std::fs::write(dir.join("received.ts"), stream).context("writing received.ts")?;
    std::fs::write(dir.join("objects.txt"), log).context("writing objects.txt")?;
    Ok(bad)
}

/// How long `check-ts.py` may take; it normally finishes in a few seconds.
const CHECKER_DEADLINE: Duration = Duration::from_secs(60);

/// Run `check-ts.py` over what [`reassemble`] wrote in `dir`, with `catalogs` (the catalog
/// object published, then as received) for its `catalog` check.
pub async fn check(
    checker: &Path,
    fixture: &Path,
    dir: &Path,
    late_join: bool,
    catalogs: Option<(&[u8], &[u8])>,
) -> anyhow::Result<Report> {
    run(checker, fixture, dir, late_join, catalogs, CHECKER_DEADLINE).await
}

async fn run(
    checker: &Path,
    fixture: &Path,
    dir: &Path,
    late_join: bool,
    catalogs: Option<(&[u8], &[u8])>,
    deadline: Duration,
) -> anyhow::Result<Report> {
    let mut cmd = tokio::process::Command::new("python3");
    cmd.arg(checker)
        .arg("--fixture")
        .arg(fixture)
        .arg("--received")
        .arg(dir.join("received.ts"))
        .arg("--objects")
        .arg(dir.join("objects.txt"));
    if late_join {
        cmd.arg("--late-join");
    }
    if let Some((published, received)) = catalogs {
        std::fs::write(dir.join("catalog-published.json"), published)
            .context("writing catalog-published.json")?;
        std::fs::write(dir.join("catalog-received.json"), received)
            .context("writing catalog-received.json")?;
        cmd.arg("--catalog-expected")
            .arg(dir.join("catalog-published.json"))
            .arg("--catalog-received")
            .arg(dir.join("catalog-received.json"));
    }
    // A checker cut off by the deadline is killed when its future is dropped.
    cmd.kill_on_drop(true);
    let out = tokio::time::timeout(deadline, cmd.output())
        .await
        .map_err(|_| {
            anyhow::anyhow!(
                "check-ts.py did not finish within {} ms",
                deadline.as_millis()
            )
        })?
        .with_context(|| format!("running {}", checker.display()))?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    if let Some(reason) = stdout.lines().find_map(|l| l.strip_prefix("Bail out! ")) {
        anyhow::bail!("check-ts.py: {}", reason);
    }
    if !matches!(out.status.code(), Some(0) | Some(1)) {
        anyhow::bail!(
            "check-ts.py exited {:?}: {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr)
                .lines()
                .last()
                .unwrap_or("")
        );
    }
    let report = parse(&stdout);
    if report.checks.is_empty() {
        anyhow::bail!("check-ts.py reported no checks");
    }
    // Exit 1 means a check failed, but a crash after some passing points exits 1 too.
    if out.status.code() == Some(1) && !report.checks.iter().any(Check::failed) {
        anyhow::bail!(
            "check-ts.py exited 1 with no failed check: {}",
            String::from_utf8_lossy(&out.stderr)
                .lines()
                .last()
                .unwrap_or("")
        );
    }
    Ok(report)
}

/// The test points and `# key: value` diagnostics of `check-ts.py`'s TAP output.
fn parse(tap: &str) -> Report {
    let mut checks = Vec::new();
    let mut diag = Map::new();
    for line in tap.lines() {
        let (ok, rest) = if let Some(rest) = line.strip_prefix("not ok ") {
            (false, rest)
        } else if let Some(rest) = line.strip_prefix("ok ") {
            (true, rest)
        } else if let Some((key, value)) = line.strip_prefix("# ").and_then(|l| l.split_once(": "))
        {
            diag.insert(key.to_string(), value_of(value));
            continue;
        } else {
            continue;
        };
        let Some((_, point)) = rest.split_once(" - ") else {
            continue;
        };
        if let Some((name, reason)) = point.split_once(" # SKIP ") {
            checks.push(Check::skip(name, reason));
        } else if let Some((name, detail)) = point.split_once(" (") {
            checks.push(Check::new(
                name,
                ok,
                detail.strip_suffix(')').unwrap_or(detail),
            ));
        } else {
            checks.push(Check::new(point, ok, ""));
        }
    }
    Report { checks, diag }
}

/// A diagnostic value: an integer, a JSON object, or the string as printed.
fn value_of(text: &str) -> Value {
    if let Ok(n) = text.parse::<i64>() {
        return json!(n);
    }
    if text.starts_with('{') {
        if let Ok(v) = serde_json::from_str::<Value>(text) {
            return v;
        }
    }
    json!(text)
}

#[cfg(test)]
mod test {
    use super::*;

    #[tokio::test]
    async fn a_hung_checker_is_cut_off_at_the_deadline() {
        let dir = tempfile::tempdir().unwrap();
        let checker = dir.path().join("hang.py");
        std::fs::write(&checker, "import time\ntime.sleep(30)\n").unwrap();
        let started = std::time::Instant::now();
        let err = run(
            &checker,
            &dir.path().join("fixture.ts"),
            dir.path(),
            false,
            None,
            Duration::from_millis(300),
        )
        .await
        .err()
        .expect("a hung checker must fail the run");
        assert!(started.elapsed() < Duration::from_secs(5));
        assert!(
            err.to_string().contains("did not finish within 300 ms"),
            "{err}"
        );
    }

    #[tokio::test]
    async fn a_checker_that_crashes_after_passing_points_fails_the_run() {
        let dir = tempfile::tempdir().unwrap();
        let checker = dir.path().join("crash.py");
        std::fs::write(
            &checker,
            "print('ok 1 - catalog')\nraise SystemExit('boom')\n",
        )
        .unwrap();
        let err = run(
            &checker,
            &dir.path().join("fixture.ts"),
            dir.path(),
            false,
            None,
            Duration::from_secs(10),
        )
        .await
        .err()
        .expect("a crashed checker must fail the run");
        assert!(
            err.to_string()
                .contains("exited 1 with no failed check: boom"),
            "{err}"
        );
    }

    #[test]
    fn parses_points_skips_and_diagnostics() {
        let report = parse(
            "TAP version 14\n1..3\nok 1 - catalog # SKIP no description track\n\
             not ok 2 - byte-identical (received packet 5 differs)\nok 3 - decode (video 500)\n\
             # media_format: mpeg-ts\n# groups_received: 20\n\
             # first_mismatch: {\"packet\": 5}\n",
        );
        let names: Vec<_> = report
            .checks
            .iter()
            .map(|c| (c.name.as_str(), c.ok))
            .collect();
        assert_eq!(
            names,
            [
                ("catalog", None),
                ("byte-identical", Some(false)),
                ("decode", Some(true))
            ]
        );
        assert_eq!(report.checks[1].detail, "received packet 5 differs");
        assert_eq!(report.diag["groups_received"], json!(20));
        assert_eq!(report.diag["media_format"], json!("mpeg-ts"));
        assert_eq!(report.diag["first_mismatch"], json!({"packet": 5}));
    }

    #[test]
    fn reassembles_in_group_order_and_logs_in_arrival_order() {
        let dir = tempfile::tempdir().unwrap();
        let obj = |group, object, body: &[u8]| Received {
            group,
            object,
            payload: [&[0x05][..], body].concat().into(),
        };
        let bad = reassemble(
            &[obj(1, 0, b"B"), obj(0, 0, b"A"), obj(1, 1, b"C")],
            dir.path(),
        )
        .unwrap();
        assert_eq!(bad, 0);
        assert_eq!(
            std::fs::read(dir.path().join("received.ts")).unwrap(),
            b"ABC"
        );
        assert_eq!(
            std::fs::read_to_string(dir.path().join("objects.txt")).unwrap(),
            "1 0 1\n0 0 1\n1 1 1\n"
        );
    }
}
