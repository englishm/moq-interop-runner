//! moq-net-media-ts interop test client.
//!
//! The MPEG-TS client of docs/tests/media/: one process drives the reference publisher and the
//! checker subscriber through the relay under test, the way `announce-subscribe` does, and
//! exposes the MPEG-TS scenarios through the standard TAP interface:
//!
//! - `ts-carriage-integrity` (docs/tests/media/ts-carriage-integrity.md)
//! - `ts-late-subscriber` (docs/tests/media/ts-late-subscriber.md)
//!
//! Built on moq-dev's `moq-tokio` 0.19 / `moq-net` 0.3 crates from crates.io, at the pair the
//! moq-dev-rs runner client pins. Offers MoQT drafts 22 down to 18 by default; `MOQ_CLIENT_VERSION`
//! (comma-separated, e.g. `moq-transport-18`) overrides the offer. The WebSocket fallback moq-tokio
//! would otherwise race after 200 ms is off, so a cell reports the transport its URL selects.
//!
//! The publisher packages the fixture as moq-dev's `import ts --passthrough` does
//! (`moq-dev-m2ts`, see fixture.rs), and the checker grades what arrived with
//! lib/media/mpeg-ts/check-ts.py. Both read the fixture from `MEDIA_FIXTURE_DIR` (default
//! `/app/fixture`, generated at image build), so no fixture travels over the network.

mod fixture;
mod oracle;
mod publisher;
mod subscriber;
mod tap;

use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Context;
use clap::Parser;
use moq_tokio::moq_net;
use serde_json::{json, Value};

use fixture::Fixture;
use publisher::Publisher;
use subscriber::Subscriber;
use tap::Check;

const VERSION: &str = env!("CARGO_PKG_VERSION");
const TEST_SPEC_REVISION: u64 = 1;
const MEDIA_FORMAT: &str = "mpeg-ts";

#[derive(Parser)]
#[command(name = "moq-net-media-ts-client")]
#[command(about = "MoQT media interop test client (MPEG-TS over moq-net/moq-tokio)")]
struct Cli {
    /// Relay URL (https:// for WebTransport, moqt:// for raw QUIC)
    #[arg(
        short,
        long,
        env = "RELAY_URL",
        default_value = "https://localhost:4443"
    )]
    relay: String,

    /// Run a specific test case
    #[arg(short, long, env = "TESTCASE")]
    test: Option<String>,

    /// List available test cases
    #[arg(short, long)]
    list: bool,

    /// Disable TLS certificate verification.
    ///
    /// The TLS_DISABLE_VERIFY env var is translated to this flag by the container
    /// entrypoint rather than read here: the interface spec allows 0/1 values,
    /// which clap's env-bool parsing would reject.
    #[arg(long)]
    tls_disable_verify: bool,

    /// Verbose output (VERBOSE env handled by the entrypoint, as above)
    #[arg(short, long)]
    verbose: bool,

    /// Directory holding fixture.ts
    #[arg(long, env = "MEDIA_FIXTURE_DIR", default_value = "/app/fixture")]
    fixture_dir: PathBuf,

    /// The reference oracle, lib/media/mpeg-ts/check-ts.py
    #[arg(long, env = "MEDIA_TS_CHECKER", default_value = "/app/check-ts.py")]
    checker: PathBuf,

    /// Override the random run identifier (lowercase hex) for debugging
    #[arg(long, env = "MEDIA_RUN_ID")]
    run_id: Option<String>,
}

const TESTS: &[&str] = &["ts-carriage-integrity", "ts-late-subscriber"];

/// The default offer, newest first: the drafts implementations.json lists for this client.
/// moq-net 0.3 also speaks drafts 14-17; MOQ_CLIENT_VERSION can still ask for them.
const IETF_VERSIONS: &[&str] = &[
    "moq-transport-22",
    "moq-transport-21",
    "moq-transport-20",
    "moq-transport-19",
    "moq-transport-18",
];

/// Shared deadlines (docs/tests/media/README.md, data-plane timeouts).
const SETUP_DEADLINE: Duration = Duration::from_secs(5);
const CATALOG_DEADLINE: Duration = Duration::from_secs(5);
const SUBSCRIBE_DEADLINE: Duration = Duration::from_secs(5);
/// Delivery must complete by the fixture's end plus this.
const DRAIN_DEADLINE: Duration = Duration::from_secs(10);
/// ts-carriage-integrity: how long the subscription has to land before publishing starts.
const SUBSCRIBE_SETTLE: Duration = Duration::from_millis(500);
/// ts-late-subscriber: when the subscriber sends SUBSCRIBE for the TS track, halfway through a
/// group.
const LATE_JOIN_OFFSET: Duration = Duration::from_millis(8500);
/// ts-late-subscriber: how long before the join the subscriber dials, for its SETUP and the
/// catalog to complete first.
const LATE_DIAL_LEAD: Duration = Duration::from_secs(2);

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Install the crypto provider before any TLS machinery runs (mirrors moq-cli). Ignore
    // the error if a provider is already installed.
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

    let cli = Cli::parse();

    if cli.list {
        for t in TESTS {
            println!("{}", t);
        }
        return Ok(());
    }

    if cli.verbose {
        tracing_subscriber::fmt()
            .with_env_filter("moq_net=debug,moq_tokio=debug,moq_net_media_ts_client=debug")
            .with_writer(std::io::stderr)
            .init();
    }

    // An empty TESTCASE means "no specific test": the runner's Makefile passes
    // `-e TESTCASE=` on full-suite runs, and clap reads that as Some("").
    let tests: Vec<&str> = match cli.test.as_deref().filter(|name| !name.is_empty()) {
        Some(name) => {
            if !TESTS.contains(&name) {
                eprintln!("Unknown test: {}", name);
                std::process::exit(127);
            }
            vec![name]
        }
        None => TESTS.to_vec(),
    };

    let relay_url = url::Url::parse(&cli.relay).context("invalid relay URL")?;

    let offered: Vec<String> = match std::env::var("MOQ_CLIENT_VERSION") {
        Ok(v) if !v.trim().is_empty() => v
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(String::from)
            .collect(),
        _ => IETF_VERSIONS.iter().map(|s| s.to_string()).collect(),
    };
    let versions = offered
        .iter()
        .map(|s| {
            s.parse::<moq_net::Version>()
                .map_err(|e| anyhow::anyhow!("{}: {}", s, e))
        })
        .collect::<anyhow::Result<Vec<_>>>()
        .context("invalid MOQ_CLIENT_VERSION")?;

    println!("TAP version 14");
    println!(
        "# moq-net-media-ts-client v{} (moq-net {} via moq-tokio {})",
        VERSION,
        env!("MOQ_NET_VERSION"),
        env!("MOQ_TOKIO_VERSION")
    );
    println!("# Relay: {}", cli.relay);
    println!("# Offered: {}", offered.join(", "));

    let fixture = match Fixture::load(&cli.fixture_dir) {
        Ok(f) => Arc::new(f),
        Err(e) => {
            println!(
                "Bail out! fixture at {}: {:#}",
                cli.fixture_dir.display(),
                e
            );
            std::process::exit(1);
        }
    };
    if !cli.checker.is_file() {
        println!("Bail out! no checker at {}", cli.checker.display());
        std::process::exit(1);
    }
    println!("# Fixture: {}", fixture.summary());
    println!("1..{}", tests.len());

    // `connect::Config` is `#[non_exhaustive]`: take the defaults and set what we own.
    let mut config = moq_tokio::connect::Config::default();
    config.version = versions;
    if cli.tls_disable_verify {
        config.tls.insecure = Some(true);
    }
    // One dial per session: a failed connect must fail the test, not be retried.
    config.once = Some(true);
    // No WebSocket fallback: the cell must exercise the transport the URL selects.
    config.websocket.enabled = Some(false);
    let client = config
        .init(moq_tokio::quic::Config::default())
        .context("failed to init client")?;

    let mut all_passed = true;
    for (i, test_name) in tests.iter().enumerate() {
        let num = i + 1;
        let start = Instant::now();
        let mut ctx = TestContext::new(test_name, fixture.clone(), cli.run_id.as_deref());
        // Hard cap: the scenario's deadline plus headroom for setup and session teardown.
        let cap = scenario_cap(fixture_span(&fixture));
        let result = tokio::time::timeout(cap, async {
            match *test_name {
                "ts-carriage-integrity" => test_carriage(&mut ctx, &client, &relay_url).await,
                "ts-late-subscriber" => test_late_subscriber(&mut ctx, &client, &relay_url).await,
                _ => anyhow::bail!("unknown test: {}", test_name),
            }
        })
        .await;
        let error = match result {
            Ok(Ok(collected)) => grade(&mut ctx, &cli, collected)
                .await
                .err()
                .map(|e| format!("{:#}", e)),
            Ok(Err(e)) => Some(format!("{:#}", e)),
            Err(_) => Some(format!("timeout after {} ms", cap.as_millis())),
        };
        let duration_ms = start.elapsed().as_millis();

        tap::print_subtests(test_name, &ctx.checks);
        let passed =
            error.is_none() && !ctx.checks.is_empty() && !ctx.checks.iter().any(Check::failed);
        if passed {
            println!("ok {} - {}", num, test_name);
        } else {
            all_passed = false;
            println!("not ok {} - {}", num, test_name);
        }
        let mut diag = ctx.diag;
        diag.insert("duration_ms".into(), json!(duration_ms));
        diag.insert("implementation_version".into(), json!(VERSION));
        diag.insert("test_spec_revision".into(), json!(TEST_SPEC_REVISION));
        diag.insert("media_format".into(), json!(MEDIA_FORMAT));
        diag.insert("ts_packaging".into(), json!(fixture::PACKAGING));
        if let Some(message) = error.or_else(|| {
            ctx.checks
                .iter()
                .find(|c| c.failed())
                .map(|c| format!("{}: {}", c.name, c.detail))
        }) {
            diag.insert("message".into(), json!(message));
        }
        tap::print_yaml(&Value::Object(ordered(diag)));
    }

    // Let the last sessions' QUIC CONNECTION_CLOSE go out before the process exits, so
    // the relay isn't left holding them until its idle timeout.
    tokio::time::sleep(Duration::from_millis(200)).await;

    if !all_passed {
        std::process::exit(1);
    }
    Ok(())
}

fn fixture_span(fixture: &Fixture) -> Duration {
    Duration::from_secs_f64(fixture.duration_secs)
}

/// Session metadata for the YAML block.
#[derive(Debug, Clone, Default)]
pub struct Session {
    pub moqt_version: Option<String>,
    pub alpn: Option<String>,
    pub transport: Option<String>,
}

impl Session {
    pub fn from_connection(connection: &moq_tokio::Connection, relay_url: &url::Url) -> Self {
        let version = connection.version();
        // With the WebSocket fallback off, the URL scheme selects the transport.
        let transport = match relay_url.scheme() {
            "moqt" | "moql" => Some("quic".to_string()),
            "https" | "http" => Some("webtransport-h3".to_string()),
            _ => None,
        };
        Self {
            moqt_version: version.map(|v| normalize_version(v.as_str())),
            alpn: version.map(|v| v.alpn().to_string()),
            transport,
        }
    }

    fn diag(&self) -> Value {
        let mut m = serde_json::Map::new();
        if let Some(v) = &self.moqt_version {
            m.insert("moqt_version".into(), json!(v));
        }
        if let Some(t) = &self.transport {
            m.insert("transport".into(), json!(t));
        }
        if let Some(a) = &self.alpn {
            m.insert("alpn".into(), json!(a));
        }
        Value::Object(m)
    }
}

/// `moq-transport-22` → `moqt-22` (TAP-YAML-METADATA.md); moq-lite names pass through.
fn normalize_version(name: &str) -> String {
    match name.strip_prefix("moq-transport-") {
        Some(draft) => format!("moqt-{}", draft),
        None => name.to_string(),
    }
}

/// Put the common fields first, then the rest in insertion order.
fn ordered(diag: serde_json::Map<String, Value>) -> serde_json::Map<String, Value> {
    let first = [
        "duration_ms",
        "implementation_version",
        "test_spec_revision",
        "media_format",
        "ts_packaging",
        "sessions",
    ];
    let mut out = serde_json::Map::new();
    for key in first {
        if let Some(v) = diag.get(key) {
            out.insert(key.to_string(), v.clone());
        }
    }
    for (k, v) in diag {
        if !first.contains(&k.as_str()) {
            out.insert(k, v);
        }
    }
    out
}

/// Per-scenario state: the namespace, and the diagnostics and checks accumulated so far.
struct TestContext {
    namespace: String,
    fixture: Arc<Fixture>,
    checks: Vec<Check>,
    diag: serde_json::Map<String, Value>,
    sessions: serde_json::Map<String, Value>,
    /// ts-late-subscriber: G and G′, the highest group open at the TS SUBSCRIBE and when its
    /// SUBSCRIBE_OK arrived.
    join_group: Option<(u64, u64)>,
    late_join: bool,
    /// The catalog object as received.
    catalog: Option<bytes::Bytes>,
}

impl TestContext {
    fn new(test: &str, fixture: Arc<Fixture>, run_id: Option<&str>) -> Self {
        let run_id = match run_id {
            Some(id) if !id.is_empty() => id.to_string(),
            _ => format!("{:032x}", rand::random::<u128>()),
        };
        let namespace = format!("moq-test/{}/{}", test, run_id);
        let mut diag = serde_json::Map::new();
        diag.insert("run_id".into(), json!(run_id));
        diag.insert("namespace".into(), json!(namespace));
        Self {
            namespace,
            fixture,
            checks: Vec::new(),
            diag,
            sessions: serde_json::Map::new(),
            join_group: None,
            late_join: test == "ts-late-subscriber",
            catalog: None,
        }
    }

    fn session(&mut self, role: &str, session: &Session) {
        self.sessions.insert(role.to_string(), session.diag());
        self.diag
            .insert("sessions".into(), Value::Object(self.sessions.clone()));
    }

    fn set(&mut self, key: &str, value: Value) {
        self.diag.insert(key.to_string(), value);
    }
}

/// Reassemble what arrived, run the oracle, and add `join-point` for the late join.
async fn grade(
    ctx: &mut TestContext,
    cli: &Cli,
    collected: subscriber::Collected,
) -> anyhow::Result<()> {
    match &collected.end {
        None => ctx.set("track_end", json!("not ended by the deadline")),
        Some(Ok(())) => ctx.set("track_end", json!("finished")),
        Some(Err(e)) => ctx.set("track_end", json!(e)),
    }
    let work = tempfile::tempdir().context("a temporary directory")?;
    let bad = oracle::reassemble(&collected.objects, work.path())?;
    if bad > 0 {
        ctx.set("ts_bad_headers", json!(bad));
    }
    let catalogs = ctx
        .catalog
        .as_ref()
        .map(|received| (&ctx.fixture.catalog[..], &received[..]));
    let report = oracle::check(
        &cli.checker,
        &ctx.fixture.path,
        work.path(),
        ctx.late_join,
        catalogs,
    )
    .await?;
    for (k, v) in report.diag {
        ctx.diag.insert(k, v);
    }
    ctx.checks.extend(report.checks);
    if let Some((open, established)) = ctx.join_group {
        let lowest = collected.objects.iter().map(|o| o.group).min();
        ctx.checks.push(join_point(lowest, open, established));
    }
    if let Some(Err(e)) = collected.end {
        anyhow::bail!("{}", e);
    }
    Ok(())
}

/// The longest a scenario may take before grading: every step before T0 at its deadline, then
/// the fixture and the drain, then teardown.
fn scenario_cap(span: Duration) -> Duration {
    let setup = 3 * SETUP_DEADLINE + CATALOG_DEADLINE + SUBSCRIBE_DEADLINE + Duration::from_secs(1);
    setup + span + DRAIN_DEADLINE + Duration::from_secs(5)
}

/// `join-point`: the lowest group received is at least G, the group open at the SUBSCRIBE, and
/// at most G′ + 1, the group after the one open when its SUBSCRIBE_OK arrived.
fn join_point(lowest: Option<u64>, open: u64, established: u64) -> Check {
    let at = if established > open {
        format!(
            "group {} open at the SUBSCRIBE, {} at SUBSCRIBE_OK",
            open, established
        )
    } else {
        format!("group {} open at the SUBSCRIBE", open)
    };
    match lowest {
        Some(low) if (open..=established + 1).contains(&low) => Check::new(
            "join-point",
            true,
            format!("lowest group {}, with {}", low, at),
        ),
        Some(low) => Check::new(
            "join-point",
            false,
            format!(
                "lowest group {}, expected {} to {}, with {}",
                low,
                open,
                established + 1,
                at
            ),
        ),
        None => Check::new("join-point", false, "no object received"),
    }
}

/// `ts-carriage-integrity`: a subscriber present from the start must receive the whole
/// fixture, byte for byte and in order.
async fn test_carriage(
    ctx: &mut TestContext,
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<subscriber::Collected> {
    let fixture = ctx.fixture.clone();
    let mut publisher = tokio::time::timeout(
        SETUP_DEADLINE,
        Publisher::connect(client, relay_url, &ctx.namespace),
    )
    .await
    .context("publisher SETUP timed out")??;
    ctx.session("publisher", &publisher.session);
    publisher.settle(Duration::from_millis(300)).await?;
    publisher.publish_catalog(&fixture)?;

    let mut subscriber =
        Subscriber::connect(client, relay_url, &ctx.namespace, SETUP_DEADLINE).await?;
    ctx.session("subscriber", &subscriber.session);
    let catalog = subscriber.read_catalog(CATALOG_DEADLINE).await?;
    ctx.set("catalog_ms", json!(catalog.elapsed.as_millis() as u64));
    let subscribed_at = Instant::now();
    let media = subscriber
        .subscribe(&catalog.track, SUBSCRIBE_DEADLINE)
        .await?;
    ctx.catalog = Some(catalog.payload);
    publisher.settle(SUBSCRIBE_SETTLE).await?;

    let t0 = Instant::now();
    ctx.set(
        "join_offset_ms",
        json!(-(t0.duration_since(subscribed_at).as_millis() as i64)),
    );
    let deadline = t0 + fixture_span(&fixture) + DRAIN_DEADLINE;
    let collected = {
        let publishing = publisher.publish(&fixture, t0);
        tokio::pin!(publishing);
        let collecting = subscriber::collect(media, deadline);
        tokio::pin!(collecting);
        let mut published = false;
        loop {
            tokio::select! {
                res = &mut publishing, if !published => {
                    res?;
                    published = true;
                }
                collected = &mut collecting => break collected,
            }
        }
    };

    subscriber.close().await;
    publisher.close().await;
    Ok(collected)
}

/// `ts-late-subscriber`: a subscriber joining at T0 + 8.5 s must receive, from the group in
/// progress or the next, an unbroken tail of the fixture.
async fn test_late_subscriber(
    ctx: &mut TestContext,
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<subscriber::Collected> {
    let fixture = ctx.fixture.clone();
    let mut publisher = tokio::time::timeout(
        SETUP_DEADLINE,
        Publisher::connect(client, relay_url, &ctx.namespace),
    )
    .await
    .context("publisher SETUP timed out")??;
    ctx.session("publisher", &publisher.session);
    publisher.settle(Duration::from_millis(300)).await?;
    publisher.publish_catalog(&fixture)?;

    let late = late_join(&publisher, &fixture, client, relay_url, &ctx.namespace).await?;
    ctx.session("subscriber", &late.session);
    ctx.set("catalog_ms", json!(late.catalog.elapsed.as_millis() as u64));
    ctx.set("join_offset_ms", json!(late.joined.as_millis() as u64));
    let open = late.open.context("no group was open at the SUBSCRIBE")?;
    let established = late.established.unwrap_or(open);
    ctx.join_group = Some((open, established));
    ctx.set("join_group", json!(open));
    ctx.set("join_group_ok", json!(established));
    ctx.catalog = Some(late.catalog.payload);
    publisher.close().await;
    Ok(late.collected)
}

/// What the late subscriber saw, and when it joined.
struct Late {
    session: Session,
    collected: subscriber::Collected,
    /// The highest group the publisher had open when the subscriber sent the TS SUBSCRIBE, and
    /// when its SUBSCRIBE_OK arrived.
    open: Option<u64>,
    established: Option<u64>,
    joined: Duration,
    catalog: subscriber::Catalog,
}

/// Publish from T0 and join with a new subscriber whose TS SUBSCRIBE goes out at T0 + 8.5 s,
/// then collect until the track ends or the deadline.
async fn late_join(
    publisher: &Publisher,
    fixture: &Fixture,
    client: &moq_tokio::Client,
    relay_url: &url::Url,
    namespace: &str,
) -> anyhow::Result<Late> {
    let t0 = Instant::now();
    let deadline = t0 + fixture_span(fixture) + DRAIN_DEADLINE;
    let publishing = publisher.publish(fixture, t0);
    tokio::pin!(publishing);
    let mut published = false;

    let join = async {
        let dial = t0 + LATE_JOIN_OFFSET.saturating_sub(LATE_DIAL_LEAD);
        tokio::time::sleep_until(tokio::time::Instant::from_std(dial)).await;
        let mut subscriber =
            Subscriber::connect(client, relay_url, namespace, SETUP_DEADLINE).await?;
        let catalog = subscriber.read_catalog(CATALOG_DEADLINE).await?;
        tokio::time::sleep_until(tokio::time::Instant::from_std(t0 + LATE_JOIN_OFFSET)).await;
        let open = publisher.opened.load(Ordering::SeqCst).checked_sub(1);
        let joined = t0.elapsed();
        let media = subscriber
            .subscribe(&catalog.track, SUBSCRIBE_DEADLINE)
            .await?;
        let established = publisher.opened.load(Ordering::SeqCst).checked_sub(1);
        Ok::<_, anyhow::Error>((subscriber, media, open, established, joined, catalog))
    };
    tokio::pin!(join);
    let (subscriber, media, open, established, joined, catalog) = loop {
        tokio::select! {
            res = &mut publishing, if !published => {
                res?;
                published = true;
            }
            res = &mut join => break res?,
        }
    };

    let collecting = subscriber::collect(media, deadline);
    tokio::pin!(collecting);
    let collected = loop {
        tokio::select! {
            res = &mut publishing, if !published => {
                res?;
                published = true;
            }
            collected = &mut collecting => break collected,
        }
    };

    let session = subscriber.session.clone();
    subscriber.close().await;
    if !published {
        publishing.await?;
    }
    Ok(Late {
        session,
        collected,
        open,
        established,
        joined,
        catalog,
    })
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn the_cap_outlasts_every_step_at_its_deadline() {
        let span = Duration::from_secs(20);
        let steps = SETUP_DEADLINE // publisher SETUP
            + Duration::from_millis(300) // its settle
            + 2 * SETUP_DEADLINE // subscriber SETUP, then the namespace routed
            + CATALOG_DEADLINE
            + SUBSCRIBE_DEADLINE
            + SUBSCRIBE_SETTLE;
        assert!(scenario_cap(span) > steps + span + DRAIN_DEADLINE);
    }

    #[test]
    fn join_point_accepts_the_group_open_at_subscribe_or_the_next() {
        assert_eq!(join_point(Some(8), 8, 8).ok, Some(true));
        assert_eq!(join_point(Some(9), 8, 8).ok, Some(true));
        assert_eq!(join_point(Some(7), 8, 8).ok, Some(false));
        assert_eq!(join_point(Some(10), 8, 8).ok, Some(false));
        assert_eq!(join_point(None, 8, 8).ok, Some(false));
    }

    #[test]
    fn join_point_follows_a_subscription_established_after_a_boundary() {
        assert_eq!(join_point(Some(10), 8, 9).ok, Some(true));
        assert_eq!(join_point(Some(11), 8, 9).ok, Some(false));
    }
}
