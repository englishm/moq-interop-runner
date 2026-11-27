//! `ts-publisher-restart` (docs/tests/media/ts-publisher-restart.md): the first publisher's
//! session ends at T0 + 8 s with no closing message of any kind, a new publisher session
//! publishes the namespace again at T0 + 9 s, and the subscriber resubscribes until the track
//! ends.
//!
//! moq-tokio sends CONNECTION_CLOSE when a connection is aborted or dropped, so the first
//! publisher runs in a child process of this binary (`--publish-child`) that is killed: its
//! QUIC connection just goes silent, as a crashed publisher's would.

use std::process::Stdio;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::Context;
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::fixture::Fixture;
use crate::publisher::Publisher;
use crate::subscriber::{self, Collected, Subscriber};
use crate::tap::Check;
use crate::{Cli, TestContext, SETUP_DEADLINE};

/// When the first publisher's session ends, after T0; `check-ts.py --restart-at` takes it.
pub const KILL_AT: Duration = Duration::from_secs(8);
/// When the new publisher dials, after T0; it publishes from the first group starting then.
const RESTART_AT: Duration = Duration::from_secs(9);
/// The subscriber resubscribes until the track ends or this, after T0.
pub const DEADLINE: Duration = Duration::from_secs(40);
/// The first object of the second part must arrive this soon after the new publisher's
/// PUBLISH_NAMESPACE.
const RECOVERY: Duration = Duration::from_secs(5);
/// The pause between a subscription ending and the next SUBSCRIBE.
const RESUBSCRIBE_PAUSE: Duration = Duration::from_millis(100);

/// The child's side: publish the fixture's catalog, print `ready <session>`, then publish
/// from the moment `go` arrives on stdin until killed.
pub async fn run_child(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
    namespace: &str,
    fixture: &Fixture,
) -> anyhow::Result<()> {
    let mut publisher = tokio::time::timeout(
        SETUP_DEADLINE,
        Publisher::connect(client, relay_url, namespace),
    )
    .await
    .context("publisher SETUP timed out")??;
    publisher.settle(Duration::from_millis(300)).await?;
    publisher.publish_catalog(fixture)?;
    println!("ready {}", publisher.session.diag());

    let mut stdin = BufReader::new(tokio::io::stdin()).lines();
    match stdin.next_line().await? {
        Some(line) if line == "go" => {}
        _ => return Ok(()),
    }
    let t0 = Instant::now();
    // A parent gone without killing us must not leave a publisher running.
    tokio::spawn(async move {
        while let Ok(Some(_)) = stdin.next_line().await {}
        std::process::exit(0);
    });
    publisher.publish(fixture, t0).await?;
    std::future::pending().await
}

/// The parent's side: start the first publisher, subscribe, then kill and replace it.
pub async fn test(
    ctx: &mut TestContext,
    cli: &Cli,
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Collected> {
    let fixture = ctx.fixture.clone();
    let mut child =
        tokio::process::Command::new(std::env::current_exe().context("locating this executable")?);
    child
        .arg("--relay")
        .arg(relay_url.as_str())
        .arg("--fixture-dir")
        .arg(&cli.fixture_dir)
        .arg("--child-fixture")
        .arg(fixture.path.file_name().context("fixture file name")?)
        .arg("--publish-child")
        .arg(&ctx.namespace)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .kill_on_drop(true);
    if cli.tls_disable_verify {
        child.arg("--tls-disable-verify");
    }
    if cli.verbose {
        child.arg("--verbose");
    }
    let mut child = child.spawn().context("starting the first publisher")?;
    let mut stdout = BufReader::new(child.stdout.take().context("child stdout")?).lines();
    let ready = tokio::time::timeout(SETUP_DEADLINE * 2, stdout.next_line())
        .await
        .context("the first publisher did not come up in time")??;
    let session = ready
        .as_deref()
        .and_then(|l| l.strip_prefix("ready "))
        .context("the first publisher failed to come up")?;
    ctx.session_value("publisher", serde_json::from_str(session)?);

    let mut sub = Subscriber::connect(client, relay_url, &ctx.namespace, SETUP_DEADLINE).await?;
    ctx.session("subscriber", &sub.session);
    let catalog = sub.read_catalog(crate::CATALOG_DEADLINE).await?;
    ctx.set("catalog_ms", json!(catalog.elapsed.as_millis() as u64));
    let media = sub
        .subscribe(&catalog.track, crate::SUBSCRIBE_DEADLINE)
        .await?;
    ctx.catalog = Some(catalog.payload);
    tokio::time::sleep(crate::SUBSCRIBE_SETTLE).await;
    if let Some(status) = child.try_wait()? {
        anyhow::bail!("the first publisher exited before T0 ({})", status);
    }

    let mut stdin = child.stdin.take().context("child stdin")?;
    stdin.write_all(b"go\n").await?;
    stdin.flush().await?;
    let t0 = Instant::now();
    let at = |d: Duration| tokio::time::Instant::from_std(t0 + d);

    let namespace = ctx.namespace.clone();
    let restarted: Mutex<Option<(Instant, crate::Session)>> = Mutex::new(None);
    let restarting = async {
        tokio::time::sleep_until(at(KILL_AT)).await;
        child.start_kill().context("killing the first publisher")?;
        child.wait().await?;
        tokio::time::sleep_until(at(RESTART_AT)).await;
        let mut publisher = tokio::time::timeout(
            SETUP_DEADLINE,
            Publisher::connect(client, relay_url, &namespace),
        )
        .await
        .context("the new publisher's SETUP timed out")?
        .context("the new publisher")?;
        *restarted.lock().unwrap() = Some((Instant::now(), publisher.session.clone()));
        publisher.publish_catalog(&fixture)?;
        publisher
            .publish_from(&fixture, t0, RESTART_AT.as_secs_f64())
            .await
            .context("the new publisher")?;
        Ok::<_, anyhow::Error>(publisher)
    };
    let last_group = fixture.groups.saturating_sub(1);
    let mut publisher = None;
    let (collected, subscriptions) = {
        tokio::pin!(restarting);
        let collecting = resubscribing(&mut sub, media, &catalog.track, last_group, t0);
        tokio::pin!(collecting);
        loop {
            tokio::select! {
                res = &mut restarting, if publisher.is_none() => publisher = Some(res?),
                done = &mut collecting => break done,
            }
        }
    };

    let restarted = restarted.into_inner().unwrap();
    if let Some((_, session)) = &restarted {
        ctx.session("publisher_restarted", session);
    }
    ctx.set("subscriptions", json!(subscriptions.count));
    ctx.set("subscription_ends", Value::from(subscriptions.ends()));
    let second = fixture
        .objects
        .iter()
        .find(|o| o.group_secs >= RESTART_AT.as_secs_f64())
        .map(|o| o.group)
        .context("the fixture has no group after the restart")?;
    let first = collected
        .objects
        .iter()
        .filter(|o| o.group >= second)
        .map(|o| o.arrived)
        .min();
    let check = recovery(restarted.map(|(announced, _)| announced), first);
    if let Some(ms) = check.1 {
        ctx.set("recovery_ms", json!(ms));
    }
    ctx.extra.push(check.0);

    sub.close().await;
    if let Some(publisher) = publisher {
        publisher.close().await;
    }
    Ok(collected)
}

/// The subscriptions one run made, and how and when (seconds after T0) each ended,
/// consecutive repeats counted once.
struct Subscriptions {
    t0: Instant,
    count: usize,
    ends: Vec<(String, usize, f64, f64)>,
}

impl Subscriptions {
    fn new(t0: Instant) -> Self {
        Self {
            t0,
            count: 0,
            ends: Vec::new(),
        }
    }

    fn ended(&mut self, how: String) {
        let at = self.t0.elapsed().as_secs_f64();
        match self.ends.last_mut() {
            Some((last, n, _, to)) if *last == how => {
                *n += 1;
                *to = at;
            }
            _ => self.ends.push((how, 1, at, at)),
        }
    }

    fn ends(&self) -> Vec<String> {
        self.ends
            .iter()
            .map(|(how, n, from, to)| match n {
                1 => format!("{} at T0 + {:.1} s", how, from),
                n => format!("{} (×{}, T0 + {:.1} to {:.1} s)", how, n, from, to),
            })
            .collect()
    }
}

/// Collect from `media`, and whenever the subscription ends before `last_group` has arrived,
/// subscribe again, until T0 plus [`DEADLINE`]. The result's `end` is the last subscription's.
async fn resubscribing(
    sub: &mut Subscriber,
    mut media: moq_tokio::moq_net::track::Subscriber,
    track: &str,
    last_group: u64,
    t0: Instant,
) -> (Collected, Subscriptions) {
    let deadline = t0 + DEADLINE;
    let mut all = Collected::default();
    let mut subs = Subscriptions::new(t0);
    subs.count = 1;
    loop {
        let got = subscriber::collect(media, deadline).await;
        all.objects.extend(got.objects);
        all.end = got.end.clone();
        let complete = all.objects.iter().any(|o| o.group == last_group);
        match got.end {
            None => {
                subs.ended("open at the deadline".into());
                break;
            }
            Some(Ok(())) => subs.ended("finished".into()),
            Some(Err(e)) => subs.ended(e),
        }
        if complete {
            break;
        }
        media = loop {
            tokio::time::sleep(RESUBSCRIBE_PAUSE).await;
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return (all, subs);
            }
            subs.count += 1;
            match sub
                .resubscribe(track, left.min(crate::SUBSCRIBE_DEADLINE))
                .await
            {
                Ok(media) => break media,
                Err(e) => subs.ended(format!("{:#}", e)),
            }
        };
    }
    (all, subs)
}

/// `recovery`: the second part's first object arrived within 5 s of the new publisher's
/// session, which sends its PUBLISH_NAMESPACE as SETUP completes. Returns the check and the
/// interval in milliseconds.
fn recovery(announced: Option<Instant>, first: Option<Instant>) -> (Check, Option<u64>) {
    match (announced, first) {
        (None, _) => (
            Check::new("recovery", false, "the new publisher never connected"),
            None,
        ),
        (Some(_), None) => (
            Check::new("recovery", false, "no object of the second part arrived"),
            None,
        ),
        (Some(announced), Some(first)) => {
            let after = first.saturating_duration_since(announced);
            let ms = after.as_millis() as u64;
            let ok = after <= RECOVERY;
            let detail = format!(
                "the second part's first object {} ms after the new PUBLISH_NAMESPACE (limit {} ms)",
                ms,
                RECOVERY.as_millis()
            );
            (Check::new("recovery", ok, detail), Some(ms))
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn recovery_is_bounded_from_the_new_announce() {
        let t = Instant::now();
        assert_eq!(
            recovery(Some(t), Some(t + Duration::from_millis(300))).0.ok,
            Some(true)
        );
        assert_eq!(recovery(Some(t), Some(t + RECOVERY)).0.ok, Some(true));
        let (late, ms) = recovery(Some(t), Some(t + RECOVERY + Duration::from_millis(1)));
        assert_eq!(late.ok, Some(false));
        assert_eq!(ms, Some(5001));
        assert_eq!(recovery(Some(t), None).0.ok, Some(false));
        assert_eq!(recovery(None, Some(t)).0.ok, Some(false));
    }

    #[test]
    fn repeated_ends_are_counted_once() {
        let mut subs = Subscriptions::new(Instant::now());
        subs.ended("finished".into());
        subs.ended("not routed".into());
        subs.ended("not routed".into());
        subs.ended("finished".into());
        let ends = subs.ends();
        assert_eq!(ends.len(), 3);
        assert!(ends[0].starts_with("finished at T0 + 0.0 s"), "{}", ends[0]);
        assert!(
            ends[1].starts_with("not routed (×2, T0 + 0.0 to"),
            "{}",
            ends[1]
        );
    }

    #[test]
    fn the_checker_is_told_the_kill_time() {
        let case = crate::case("ts-publisher-restart").unwrap();
        assert_eq!(case.args, ["--restart-at", "8"]);
        assert_eq!(KILL_AT, Duration::from_secs(8));
    }
}
