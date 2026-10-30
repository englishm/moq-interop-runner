//! stitcher-moq-media interop test client (Paramount).
//!
//! The media-area client of docs/tests/media/: one process drives the reference publisher
//! and the checker subscriber(s) through the relay under test, the way `announce-subscribe`
//! does, and exposes the CMSF scenarios through the standard TAP interface:
//!
//! - `cmsf-live-join` (docs/tests/media/cmsf-live-join.md)
//! - `cmsf-late-join-idle-catalog` (docs/tests/media/cmsf-late-join-idle-catalog.md)
//!
//! Built on moq-dev's `moq-tokio` 0.19 / `moq-net` 0.3 crates from crates.io, at the pair the
//! moq-dev-rs runner client pins. Offers MoQT drafts 22 down to 18 by default; `MOQ_CLIENT_VERSION`
//! (comma-separated, e.g. `moq-transport-18`) overrides the offer. The WebSocket fallback moq-tokio
//! would otherwise race after 200 ms is off, so a cell reports the transport its URL selects.
//!
//! The fixture, manifest and expected catalog come from `MEDIA_FIXTURE_DIR` (default
//! `/app/fixture`, generated at image build by lib/media/cmsf/). Publisher and checker share
//! them and the run identifier, so no manifest travels over the network.
//!
//! What moq-net lets this client observe: it accepts an IETF subscription locally before
//! SUBSCRIBE_OK and surfaces a REQUEST_ERROR as the track aborting, so "nothing arrived" and
//! "the relay refused" are distinguished in the message, not by the subscribe call. Sessions
//! close subscriber first, and the process lets its last CONNECTION_CLOSE go out before it
//! exits.

mod checker;
mod fixture;
mod publisher;
mod tap;

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Context;
use clap::Parser;
use moq_tokio::moq_net;
use serde_json::{json, Value};

use checker::{Subscriber, TrackReport};
use fixture::Fixture;
use publisher::Publisher;
use tap::Check;

const VERSION: &str = env!("CARGO_PKG_VERSION");
const TEST_SPEC_REVISION: u64 = 1;
const MEDIA_FORMAT: &str = "cmsf";

#[derive(Parser)]
#[command(name = "stitcher-moq-media-client")]
#[command(
    about = "MoQT media interop test client (Paramount stitcher-moq, CMSF over moq-net/moq-tokio)"
)]
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

    /// Directory holding video.mp4, audio.mp4, manifest.json and catalog.json
    #[arg(long, env = "MEDIA_FIXTURE_DIR", default_value = "/app/fixture")]
    fixture_dir: PathBuf,

    /// Idle period of cmsf-late-join-idle-catalog, in seconds (must exceed the relay's cache window)
    #[arg(long, env = "MEDIA_IDLE_SECS", default_value_t = 70)]
    idle_secs: u64,

    /// Override the random run identifier (lowercase hex) for debugging
    #[arg(long, env = "MEDIA_RUN_ID")]
    run_id: Option<String>,
}

const TESTS: &[&str] = &["cmsf-live-join", "cmsf-late-join-idle-catalog"];

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
const DRAIN_DEADLINE: Duration = Duration::from_secs(10);
/// cmsf-live-join: when the subscriber joins, and how long media must keep arriving.
const LIVE_JOIN_OFFSET: Duration = Duration::from_millis(1500);
const LIVE_MIN_SPAN: Duration = Duration::from_secs(3);
/// cmsf-late-join-idle-catalog: publisher resumes this long after subscriber_3's media subscribe.
const RESUME_AFTER: Duration = Duration::from_secs(1);

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
            .with_env_filter("moq_net=debug,moq_tokio=debug,stitcher_moq_media_client=debug")
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
        "# stitcher-moq-media-client v{} (moq-net {} via moq-tokio {})",
        VERSION,
        moq_net_version(),
        moq_tokio_version()
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

    let settings = Settings {
        idle: Duration::from_secs(cli.idle_secs),
        run_id: cli.run_id.clone(),
    };

    let mut all_passed = true;
    for (i, test_name) in tests.iter().enumerate() {
        let num = i + 1;
        let start = Instant::now();
        let outcome = run_test(test_name, &client, &relay_url, fixture.clone(), &settings).await;
        let duration_ms = start.elapsed().as_millis();

        tap::print_subtests(test_name, &outcome.checks);
        let passed = outcome.checks.iter().all(|c| c.ok) && outcome.error.is_none();
        if passed {
            println!("ok {} - {}", num, test_name);
        } else {
            all_passed = false;
            println!("not ok {} - {}", num, test_name);
        }
        let mut diag = outcome.diag;
        diag.insert("duration_ms".into(), json!(duration_ms));
        diag.insert("implementation_version".into(), json!(VERSION));
        diag.insert("test_spec_revision".into(), json!(TEST_SPEC_REVISION));
        diag.insert("media_format".into(), json!(MEDIA_FORMAT));
        if let Some(message) = outcome.error.or_else(|| {
            outcome
                .checks
                .iter()
                .find(|c| !c.ok)
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

struct Settings {
    idle: Duration,
    run_id: Option<String>,
}

/// What a scenario reports: its checks, the YAML diagnostics, and a failure that
/// prevented the checks from running (a dead session, a connect that failed).
struct Outcome {
    checks: Vec<Check>,
    diag: serde_json::Map<String, Value>,
    error: Option<String>,
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

/// The moq-net version Cargo.lock resolved (set by build.rs).
fn moq_net_version() -> &'static str {
    env!("MOQ_NET_VERSION")
}

/// The moq-tokio version Cargo.lock resolved (set by build.rs).
fn moq_tokio_version() -> &'static str {
    env!("MOQ_TOKIO_VERSION")
}

/// Put the common fields first, then the rest in insertion order.
fn ordered(diag: serde_json::Map<String, Value>) -> serde_json::Map<String, Value> {
    let first = [
        "duration_ms",
        "implementation_version",
        "test_spec_revision",
        "media_format",
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

fn run_id(settings: &Settings) -> String {
    match &settings.run_id {
        Some(id) if !id.is_empty() => id.clone(),
        _ => format!("{:032x}", rand::random::<u128>()),
    }
}

async fn run_test(
    name: &str,
    client: &moq_tokio::Client,
    relay_url: &url::Url,
    fixture: Arc<Fixture>,
    settings: &Settings,
) -> Outcome {
    let fixture_secs = Duration::from_millis(fixture.manifest.duration_ms);
    // Hard caps: the scenario's own deadlines plus headroom for session teardown.
    let cap = match name {
        "cmsf-live-join" => {
            LIVE_JOIN_OFFSET + fixture_secs + DRAIN_DEADLINE + Duration::from_secs(10)
        }
        "cmsf-late-join-idle-catalog" => {
            settings.idle + fixture_secs + DRAIN_DEADLINE + Duration::from_secs(20)
        }
        _ => Duration::from_secs(30),
    };
    let mut ctx = TestContext::new(name, fixture, settings);
    let result = tokio::time::timeout(cap, async {
        match name {
            "cmsf-live-join" => test_live_join(&mut ctx, client, relay_url).await,
            "cmsf-late-join-idle-catalog" => {
                test_late_join_idle_catalog(&mut ctx, client, relay_url).await
            }
            _ => anyhow::bail!("unknown test: {}", name),
        }
    })
    .await;
    let error = match result {
        Ok(Ok(())) => None,
        Ok(Err(e)) => Some(format!("{:#}", e)),
        Err(_) => Some(format!("timeout after {} ms", cap.as_millis())),
    };
    Outcome {
        checks: ctx.checks,
        diag: ctx.diag,
        error,
    }
}

/// Per-scenario state: the namespace, the diagnostics and checks accumulated so far, and
/// a scratch directory for the reassembled tracks.
struct TestContext {
    namespace: String,
    fixture: Arc<Fixture>,
    idle: Duration,
    checks: Vec<Check>,
    diag: serde_json::Map<String, Value>,
    sessions: serde_json::Map<String, Value>,
    reports: Option<BTreeMap<String, TrackReport>>,
    work: tempfile::TempDir,
}

impl TestContext {
    fn new(test: &str, fixture: Arc<Fixture>, settings: &Settings) -> Self {
        let run_id = run_id(settings);
        let namespace = format!("moq-test/{}/{}", test, run_id);
        let mut diag = serde_json::Map::new();
        diag.insert("run_id".into(), json!(run_id));
        diag.insert("namespace".into(), json!(namespace));
        Self {
            namespace,
            fixture,
            idle: settings.idle,
            checks: Vec::new(),
            diag,
            sessions: serde_json::Map::new(),
            reports: None,
            work: tempfile::tempdir().expect("a temporary directory"),
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

    /// Run the byte, ordering and decode checks over `collected`, fill the diagnostics,
    /// and append the four checks (with `catalog`) to the report.
    async fn finish_checks(
        &mut self,
        catalog: Result<String, String>,
        collected: &checker::Collected,
        required: std::ops::RangeInclusive<u64>,
    ) {
        let mut reports: BTreeMap<String, TrackReport> = BTreeMap::new();
        for (name, track) in &self.fixture.tracks {
            let received: Vec<&checker::Received> = collected
                .objects
                .iter()
                .filter(|r| &r.track == name)
                .collect();
            let mut report = checker::verify_track(track, &received, &collected.starts(name));
            if report.ordering_error.is_none() || !report.complete_groups.is_empty() {
                checker::decode_track(track, &received, &mut report, self.work.path()).await;
            } else {
                report.decode_error = Some("nothing to decode".into());
            }
            reports.insert(name.clone(), report);
        }

        let groups: usize = reports.values().map(|r| r.groups).sum();
        let objects: usize = reports.values().map(|r| r.objects).sum();
        let bytes: usize = reports.values().map(|r| r.bytes).sum();
        self.set("groups_received", json!(groups));
        self.set("objects_received", json!(objects));
        self.set("bytes_received", json!(bytes));
        if let Some(g) = reports.values().filter_map(|r| r.first_group).min() {
            self.set("first_group", json!(g));
        }
        if let Some(g) = reports.values().filter_map(|r| r.last_group).max() {
            self.set("last_group", json!(g));
        }
        let tracks: serde_json::Map<String, Value> = reports
            .iter()
            .map(|(n, r)| (n.clone(), checker::track_diag(r)))
            .collect();
        self.set("tracks", Value::Object(tracks));
        if let Some(m) = reports.values().find_map(|r| r.first_mismatch.clone()) {
            self.set("first_mismatch", m);
        }
        let checks = checker::summarize(catalog, &reports, required, collected);
        self.checks.extend(checks);
        self.reports = Some(reports);
    }
}

// The reports are kept for the liveness clause of cmsf-live-join.
impl TestContext {
    fn span(&self) -> Option<Duration> {
        let reports = self.reports.as_ref()?;
        let first = reports.values().filter_map(|r| r.first_at).min()?;
        let last = reports.values().filter_map(|r| r.last_at).max()?;
        Some(last.duration_since(first))
    }
}

/// `cmsf-live-join`: publish the fixture live; a subscriber joins at 1.5 s and must get the
/// catalog, then intact, ordered, still-arriving, decodable media through group 9.
async fn test_live_join(
    ctx: &mut TestContext,
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<()> {
    let fixture = ctx.fixture.clone();
    let namespace = ctx.namespace.clone();
    let last_group = fixture
        .tracks
        .values()
        .map(|t| t.last_group())
        .max()
        .unwrap_or(0);

    let mut publisher = tokio::time::timeout(
        SETUP_DEADLINE,
        Publisher::connect(client, relay_url, fixture.clone(), &namespace),
    )
    .await
    .context("publisher SETUP timed out")??;
    ctx.session("publisher", &publisher.session);
    publisher.settle(Duration::from_millis(300)).await?;
    publisher.publish_catalog()?;

    let t0 = Instant::now();
    let publishing = {
        let start = t0;
        async move {
            publisher.publish_groups(0, last_group, start).await?;
            publisher.finish_media()?;
            Ok::<Publisher, anyhow::Error>(publisher)
        }
    };
    tokio::pin!(publishing);

    // The subscriber joins at T0 + 1.5 s while the publisher keeps pacing.
    let join = async {
        tokio::time::sleep_until(tokio::time::Instant::from_std(t0 + LIVE_JOIN_OFFSET)).await;
        let subscriber = tokio::time::timeout(
            SETUP_DEADLINE,
            Subscriber::connect(client, relay_url, &namespace, SETUP_DEADLINE),
        )
        .await
        .context("subscriber SETUP timed out")??;
        let joined = t0.elapsed();
        let catalog = subscriber.read_catalog(CATALOG_DEADLINE).await;
        Ok::<_, anyhow::Error>((subscriber, joined, catalog))
    };
    tokio::pin!(join);

    let mut publisher_done: Option<Publisher> = None;
    let (subscriber, joined, catalog) = loop {
        tokio::select! {
            res = &mut publishing, if publisher_done.is_none() => {
                publisher_done = Some(res?);
            }
            res = &mut join => break res?,
        }
    };
    ctx.session("subscriber", &subscriber.session);
    ctx.set("join_offset_ms", json!(joined.as_millis() as u64));

    let catalog_result = match catalog {
        Ok((payload, held, took)) => {
            ctx.set("catalog_ms", json!(took.as_millis() as u64));
            let mut subscriber_holding = subscriber;
            subscriber_holding.held.push(held);
            match checker::check_catalog(&fixture, &payload) {
                Ok(()) => (
                    Ok(format!(
                        "received in {} ms, equal to the expected catalog",
                        took.as_millis()
                    )),
                    subscriber_holding,
                    Some(payload),
                ),
                Err(e) => (Err(e), subscriber_holding, Some(payload)),
            }
        }
        Err(e) => (Err(format!("{:#}", e)), subscriber, None),
    };
    let (catalog_check, subscriber, payload) = catalog_result;

    // Subscribe to the tracks the received catalog names (or, if it did not arrive, the
    // expected ones, so the media checks still say what the relay delivered).
    let names = payload
        .as_ref()
        .and_then(|p| serde_json::from_slice::<Value>(p).ok())
        .map(|c| fixture::catalog_track_names(&c))
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| fixture.catalog_track_names());
    let names: Vec<String> = names
        .into_iter()
        .filter(|n| fixture.tracks.contains_key(n))
        .collect();
    let subscribers = subscriber.subscribe_media(&names).await?;

    let deadline = t0 + Duration::from_millis(fixture.manifest.duration_ms) + DRAIN_DEADLINE;
    let collecting = checker::collect(subscribers, fixture.clone(), last_group, deadline);
    tokio::pin!(collecting);
    let collected = loop {
        tokio::select! {
            res = &mut publishing, if publisher_done.is_none() => {
                publisher_done = Some(res?);
            }
            collected = &mut collecting => break collected,
        }
    };

    // Teardown: subscriber first, then the publisher.
    subscriber.close().await;
    let publisher = match publisher_done {
        Some(p) => p,
        None => publishing.await?,
    };
    publisher.close().await;

    // The join decides the first group; what is required is the last one, complete.
    ctx.finish_checks(catalog_check, &collected, last_group..=last_group)
        .await;
    if let Some(span) = ctx.span() {
        ctx.set("media_span_ms", json!(span.as_millis() as u64));
        let ok = span >= LIVE_MIN_SPAN;
        ctx.checks.push(Check::new(
            "live",
            ok,
            if ok {
                format!(
                    "media kept arriving for {} ms after the first object",
                    span.as_millis()
                )
            } else {
                format!(
                    "media stopped {} ms after the first object (expected at least {} ms)",
                    span.as_millis(),
                    LIVE_MIN_SPAN.as_millis()
                )
            },
        ));
    } else {
        ctx.checks
            .push(Check::new("live", false, "no media object arrived"));
    }
    Ok(())
}

/// `cmsf-late-join-idle-catalog`: catalog and group 0 once, a reader that leaves, a reader
/// that stays, an idle longer than the relay's cache window, then a new reader must get the
/// catalog within 5 s and groups 1-9 as the publisher resumes.
async fn test_late_join_idle_catalog(
    ctx: &mut TestContext,
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<()> {
    let fixture = ctx.fixture.clone();
    let last_group = fixture
        .tracks
        .values()
        .map(|t| t.last_group())
        .max()
        .unwrap_or(0);
    let idle = ctx.idle;
    ctx.set("idle_ms", json!(idle.as_millis() as u64));

    let mut publisher = tokio::time::timeout(
        SETUP_DEADLINE,
        Publisher::connect(client, relay_url, fixture.clone(), &ctx.namespace),
    )
    .await
    .context("publisher SETUP timed out")??;
    ctx.session("publisher", &publisher.session);
    publisher.settle(Duration::from_millis(300)).await?;
    publisher.publish_catalog()?;
    // Group 0 only, paced within its second, then quiet.
    publisher.publish_groups(0, 0, Instant::now()).await?;

    let mut catalog_results: Vec<String> = Vec::new();
    let mut catalog_error: Option<String> = None;

    // subscriber_1: reads the catalog and leaves.
    let s1 = tokio::time::timeout(
        SETUP_DEADLINE,
        Subscriber::connect(client, relay_url, &ctx.namespace, SETUP_DEADLINE),
    )
    .await
    .context("subscriber_1 SETUP timed out")?
    .context("subscriber_1")?;
    ctx.session("subscriber_1", &s1.session);
    match s1.read_catalog(CATALOG_DEADLINE).await {
        Ok((payload, _held, took)) => {
            ctx.set("catalog_ms_subscriber_1", json!(took.as_millis() as u64));
            match checker::check_catalog(&fixture, &payload) {
                Ok(()) => catalog_results.push(format!("subscriber_1 {} ms", took.as_millis())),
                Err(e) => {
                    catalog_error.get_or_insert(format!("subscriber_1: {}", e));
                }
            }
        }
        Err(e) => {
            catalog_error.get_or_insert(format!("subscriber_1: {:#}", e));
        }
    }
    s1.close().await;

    // subscriber_2: reads the catalog and stays subscribed.
    let mut s2 = tokio::time::timeout(
        SETUP_DEADLINE,
        Subscriber::connect(client, relay_url, &ctx.namespace, SETUP_DEADLINE),
    )
    .await
    .context("subscriber_2 SETUP timed out")?
    .context("subscriber_2")?;
    ctx.session("subscriber_2", &s2.session);
    match s2.read_catalog(CATALOG_DEADLINE).await {
        Ok((payload, held, took)) => {
            s2.held.push(held);
            ctx.set("catalog_ms_subscriber_2", json!(took.as_millis() as u64));
            match checker::check_catalog(&fixture, &payload) {
                Ok(()) => catalog_results.push(format!("subscriber_2 {} ms", took.as_millis())),
                Err(e) => {
                    catalog_error.get_or_insert(format!("subscriber_2: {}", e));
                }
            }
        }
        Err(e) => {
            catalog_error.get_or_insert(format!("subscriber_2: {:#}", e));
        }
    }

    // Idle: nothing published on any track. Both sessions must survive it.
    let idle_until = tokio::time::Instant::now() + idle;
    tokio::select! {
        res = publisher.connection.closed() => anyhow::bail!("publisher session closed during the idle period: {:?}", res),
        res = s2.connection.closed() => anyhow::bail!("subscriber_2 session closed during the idle period: {:?}", res),
        _ = tokio::time::sleep_until(idle_until) => {}
    }

    // subscriber_3: the property under test.
    let mut s3 = tokio::time::timeout(
        SETUP_DEADLINE,
        Subscriber::connect(client, relay_url, &ctx.namespace, SETUP_DEADLINE),
    )
    .await
    .context("subscriber_3 SETUP timed out")?
    .context("subscriber_3")?;
    ctx.session("subscriber_3", &s3.session);
    let s3_catalog = s3.read_catalog(CATALOG_DEADLINE).await;
    let payload = match s3_catalog {
        Ok((payload, held, took)) => {
            s3.held.push(held);
            ctx.set("catalog_ms_subscriber_3", json!(took.as_millis() as u64));
            match checker::check_catalog(&fixture, &payload) {
                Ok(()) => catalog_results.push(format!(
                    "subscriber_3 {} ms after {} ms idle",
                    took.as_millis(),
                    idle.as_millis()
                )),
                Err(e) => {
                    catalog_error.get_or_insert(format!("subscriber_3: {}", e));
                }
            }
            Some(payload)
        }
        Err(e) => {
            catalog_error.get_or_insert(format!(
                "subscriber_3 (after {} ms idle): {:#}",
                idle.as_millis(),
                e
            ));
            None
        }
    };
    let catalog_check = match catalog_error {
        None => Ok(format!(
            "equal to the expected catalog for {}",
            catalog_results.join(", ")
        )),
        Some(e) => Err(e),
    };

    let names = payload
        .as_ref()
        .and_then(|p| serde_json::from_slice::<Value>(p).ok())
        .map(|c| fixture::catalog_track_names(&c))
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| fixture.catalog_track_names());
    let names: Vec<String> = names
        .into_iter()
        .filter(|n| fixture.tracks.contains_key(n))
        .collect();
    let subscribers = s3.subscribe_media(&names).await?;
    let subscribed_at = Instant::now();

    // Resume one second later with groups 1..=last, paced.
    let resume_at = subscribed_at + RESUME_AFTER;
    let remainder = Duration::from_millis(
        fixture
            .manifest
            .duration_ms
            .saturating_sub(fixture.manifest.group_ms),
    );
    let deadline = resume_at + remainder + DRAIN_DEADLINE;
    let publishing = async {
        tokio::time::sleep_until(tokio::time::Instant::from_std(resume_at)).await;
        publisher.publish_groups(1, last_group, resume_at).await?;
        publisher.finish_media()?;
        Ok::<Publisher, anyhow::Error>(publisher)
    };
    tokio::pin!(publishing);
    let collecting = checker::collect(subscribers, fixture.clone(), last_group, deadline);
    tokio::pin!(collecting);

    let mut publisher_done: Option<Publisher> = None;
    let collected = loop {
        tokio::select! {
            res = &mut publishing, if publisher_done.is_none() => {
                publisher_done = Some(res?);
            }
            collected = &mut collecting => break collected,
        }
    };

    s3.close().await;
    s2.close().await;
    let publisher = match publisher_done {
        Some(p) => p,
        None => publishing.await?,
    };
    publisher.close().await;

    ctx.finish_checks(catalog_check, &collected, 1..=last_group)
        .await;
    Ok(())
}
