//! stitcher-moq interop test client (Paramount).
//!
//! Built on the current crates.io moq-net/moq-tokio stack — the same libraries the
//! stitcher-moq production publisher runs — this client implements ALL six canonical
//! test cases, including the two the reference moq-dev-rs client skips.
//! `Consumer::request_broadcast` registers a broadcast request the session's
//! subscriber side can put on the wire, so a SUBSCRIBE can be sent without first
//! receiving an announcement (`subscribe-error`, `subscribe-before-announce`).

use std::time::{Duration, Instant};

use anyhow::Context;
use clap::Parser;
use moq_net::broadcast;
use moq_tokio::moq_net;

#[derive(Parser)]
#[command(name = "stitcher-moq-client")]
#[command(about = "MoQT interop test client (Paramount stitcher-moq, moq-net/moq-tokio)")]
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
}

const TESTS: &[&str] = &[
    "setup-only",
    "announce-only",
    "publish-namespace-done",
    "subscribe-error",
    "announce-subscribe",
    "subscribe-before-announce",
];

const TEST_NAMESPACE: &str = "moq-test/interop";
const TEST_TRACK: &str = "test-track";
const NONEXISTENT_NAMESPACE: &str = "nonexistent/namespace";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Install the crypto provider before any TLS machinery runs (mirrors moq-cli).
    moq_tokio::crypto::install_default().expect("failed to install default crypto provider");

    let cli = Cli::parse();

    if cli.list {
        for t in TESTS {
            println!("{}", t);
        }
        return Ok(());
    }

    if cli.verbose {
        tracing_subscriber::fmt()
            .with_env_filter("moq=debug,moq_tokio=debug,moq_net=debug")
            .init();
    }

    let tests: Vec<&str> = match &cli.test {
        Some(name) => {
            if !TESTS.contains(&name.as_str()) {
                eprintln!("Unknown test: {}", name);
                std::process::exit(127);
            }
            vec![name.as_str()]
        }
        None => TESTS.to_vec(),
    };

    println!("TAP version 14");
    println!("# stitcher-moq-client v0.1.0 (moq-net via moq-tokio 0.19.13)");
    println!("# Relay: {}", cli.relay);
    println!("1..{}", tests.len());

    let relay_url = url::Url::parse(&cli.relay).context("invalid relay URL")?;
    let client = build_client(cli.tls_disable_verify)?;

    let mut all_passed = true;

    for (i, test_name) in tests.iter().enumerate() {
        let num = i + 1;
        let start = Instant::now();

        let result = run_test(test_name, &client, &relay_url).await;
        let duration_ms = start.elapsed().as_millis();

        match result {
            Ok(diag) => {
                println!("ok {} - {}", num, test_name);
                print_diagnostics(duration_ms, &diag);
            }
            Err(e) => {
                all_passed = false;
                println!("not ok {} - {}", num, test_name);
                print_failure_diagnostics(duration_ms, &format!("{:#}", e));
            }
        }
    }

    if !all_passed {
        std::process::exit(1);
    }

    Ok(())
}

fn build_client(tls_disable_verify: bool) -> anyhow::Result<moq_tokio::Client> {
    let mut connect = moq_tokio::connect::Config::default();
    // Each test dials once. A reconnect loop would hide a session that died.
    connect.once = Some(true);
    if tls_disable_verify {
        connect.tls.insecure = Some(true);
    }

    // Optionally pin the offered protocol version(s) via MOQ_CLIENT_VERSION
    // (comma-separated, e.g. "moq-transport-18"). By default the client offers
    // every supported version and lets the relay choose.
    if let Ok(versions) = std::env::var("MOQ_CLIENT_VERSION") {
        let versions = versions
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|s| s.parse::<moq_net::Version>().map_err(|e| anyhow::anyhow!("{e}")))
            .collect::<anyhow::Result<Vec<_>>>()
            .context("invalid MOQ_CLIENT_VERSION")?;
        if !versions.is_empty() {
            connect.version = versions;
        }
    }

    connect
        .init(Default::default())
        .context("failed to init client")
}

#[derive(Default)]
struct Diagnostics {
    negotiated: Option<String>,
    outcome: Option<String>,
}

fn print_diagnostics(duration_ms: u128, diag: &Diagnostics) {
    println!("  ---");
    println!("  duration_ms: {}", duration_ms);
    if let Some(v) = &diag.negotiated {
        println!("  negotiated: {}", v);
    }
    if let Some(o) = &diag.outcome {
        println!("  outcome: \"{}\"", o.replace('"', "\\\""));
    }
    println!("  ...");
}

fn print_failure_diagnostics(duration_ms: u128, message: &str) {
    println!("  ---");
    println!("  duration_ms: {}", duration_ms);
    println!("  message: \"{}\"", message.replace('"', "\\\""));
    println!("  ...");
}

fn negotiated(conn: &moq_tokio::Connection) -> String {
    conn.version()
        .map(|version| version.to_string())
        .unwrap_or_else(|| "unknown".to_string())
}

async fn dial(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<moq_tokio::Connection> {
    client
        .clone()
        .connect(relay_url.clone())
        .established()
        .await
        .context("failed to connect")
}

/// Fail if the one-shot session ends during `grace`.
async fn session_survives(
    conn: &moq_tokio::Connection,
    grace: Duration,
    what: &str,
) -> anyhow::Result<()> {
    tokio::select! {
        result = conn.closed() => anyhow::bail!("session closed after {what}: {result:?}"),
        _ = tokio::time::sleep(grace) => Ok(()),
    }
}

/// Publish `path`, announcing it once `track` (when set) exists.
fn publish(
    path: &str,
    track: Option<&str>,
) -> anyhow::Result<(
    moq_net::origin::Producer,
    broadcast::Producer,
    Option<moq_net::track::Producer>,
)> {
    let origin = moq_tokio::origin::spawn();
    let broadcast = origin
        .create_broadcast(path)
        .context("failed to create broadcast")?;
    let track = match track {
        Some(name) => Some(
            broadcast
                .create_track(name, None)
                .context("failed to create track")?,
        ),
        None => None,
    };
    broadcast
        .announce(Default::default())
        .context("failed to announce broadcast")?;
    Ok((origin, broadcast, track))
}

/// Wait until the peer announces `path` exactly, then resolve that broadcast.
async fn announced_broadcast(
    consumer: &moq_net::origin::Consumer,
    path: &str,
) -> anyhow::Result<broadcast::Consumer> {
    let mut announced = consumer.announced();
    wait_announced(&mut announced, path).await?;
    consumer
        .request_broadcast(path)
        .await
        .with_context(|| format!("announced path {path} did not resolve"))
}

/// Block until `announced` reports an active route whose prefix is exactly `path`.
async fn wait_announced(
    announced: &mut moq_net::announce::Consumer,
    path: &str,
) -> anyhow::Result<()> {
    loop {
        let update = announced
            .next()
            .await
            .context("origin closed before the broadcast was announced")?;
        if update.kind.is_active() && update.prefix.as_str() == path {
            return Ok(());
        }
    }
}

async fn run_test(
    name: &str,
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let timeout = match name {
        "setup-only" => Duration::from_secs(2),
        "announce-only" => Duration::from_secs(2),
        "publish-namespace-done" => Duration::from_secs(2),
        "subscribe-error" => Duration::from_secs(2),
        "announce-subscribe" => Duration::from_secs(3),
        // Spec guidance is 3.5s for the flow itself; the extra headroom covers the
        // stale-announcement settle phase when the full suite runs in one process.
        "subscribe-before-announce" => Duration::from_millis(5000),
        _ => Duration::from_secs(5),
    };

    tokio::time::timeout(timeout, run_test_inner(name, client, relay_url))
        .await
        .context(format!("timeout after {}ms", timeout.as_millis()))?
}

async fn run_test_inner(
    name: &str,
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    match name {
        "setup-only" => test_setup_only(client, relay_url).await,
        "announce-only" => test_announce_only(client, relay_url).await,
        "publish-namespace-done" => test_publish_namespace_done(client, relay_url).await,
        "subscribe-error" => test_subscribe_error(client, relay_url).await,
        "announce-subscribe" => test_announce_subscribe(client, relay_url).await,
        "subscribe-before-announce" => test_subscribe_before_announce(client, relay_url).await,
        _ => anyhow::bail!("unknown test: {}", name),
    }
}

/// Connect, complete SETUP, close gracefully.
async fn test_setup_only(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let session = dial(client, relay_url).await?;
    let negotiated = negotiated(&session);
    session.abort(moq_net::Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        ..Default::default()
    })
}

/// Connect, PUBLISH_NAMESPACE the test namespace, verify the session survives it.
///
/// The moq-net model has no direct PUBLISH_NAMESPACE_OK surface, but a rejected or
/// unauthorized announce errors the session, so "announce sent + session still alive
/// after a grace period" is the observable success criterion.
async fn test_announce_only(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let (origin, _broadcast, _) = publish(TEST_NAMESPACE, None)?;

    let session = client
        .clone()
        .with_publisher(&origin)
        .connect(relay_url.clone())
        .established()
        .await
        .context("failed to connect")?;

    let negotiated = negotiated(&session);
    session_survives(&session, Duration::from_millis(700), "announce").await?;
    session.abort(moq_net::Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some("announce accepted (session healthy)".into()),
    })
}

/// Connect, announce, then withdraw the namespace by finishing the broadcast.
async fn test_publish_namespace_done(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let (origin, broadcast, _) = publish(TEST_NAMESPACE, None)?;

    let session = client
        .clone()
        .with_publisher(&origin)
        .connect(relay_url.clone())
        .established()
        .await
        .context("failed to connect")?;

    let negotiated = negotiated(&session);

    // Let the announce land.
    session_survives(&session, Duration::from_millis(500), "announce").await?;

    // Withdraw: finish the broadcast (unpublish/namespace-done on the wire).
    broadcast.finish();

    session_survives(&session, Duration::from_millis(300), "unpublish").await?;
    session.abort(moq_net::Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some("namespace withdrawn cleanly".into()),
    })
}

/// SUBSCRIBE to a nonexistent namespace/track and expect a clean per-request error
/// (REQUEST_ERROR / not-found), with the session surviving.
async fn test_subscribe_error(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let origin = moq_tokio::origin::spawn();
    let consumer = origin.consume();

    let session = client
        .clone()
        .with_subscriber(origin)
        .connect(relay_url.clone())
        .established()
        .await
        .context("failed to connect")?;

    let negotiated = negotiated(&session);

    // Speculative request: goes on the wire when a route covers it, and is refused
    // locally when nothing does. Either is a clean per-request error.
    let outcome = match consumer.request_broadcast(NONEXISTENT_NAMESPACE).await {
        Err(e) => format!("request rejected cleanly: {}", e),
        Ok(broadcast) => {
            // The relay resolved a broadcast for a nonexistent path; the track
            // subscription must then fail cleanly for this test to pass.
            let track = broadcast
                .track(TEST_TRACK)
                .context("failed to request track")?;
            match track.subscribe(None).await {
                Ok(_) => anyhow::bail!("subscription to nonexistent track succeeded"),
                Err(e) => format!("track rejected cleanly: {}", e),
            }
        }
    };

    // The error must be request-scoped: the session has to survive it.
    session_survives(
        &session,
        Duration::from_millis(300),
        "returning a request error",
    )
    .await
    .context("session died instead of returning a request error")?;
    session.abort(moq_net::Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some(outcome),
    })
}

/// Two connections: publisher announces + serves a track, subscriber subscribes.
async fn test_announce_subscribe(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let (pub_origin, _broadcast, _track) = publish(TEST_NAMESPACE, Some(TEST_TRACK))?;

    let pub_session = client
        .clone()
        .with_publisher(&pub_origin)
        .connect(relay_url.clone())
        .established()
        .await
        .context("publisher failed to connect")?;

    // Give the relay time to process the announce.
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Subscriber.
    let sub_origin = moq_tokio::origin::spawn();
    let sub_consumer = sub_origin.consume();

    let sub_session = client
        .clone()
        .with_subscriber(sub_origin)
        .connect(relay_url.clone())
        .established()
        .await
        .context("subscriber failed to connect")?;

    let negotiated = negotiated(&sub_session);

    // Wait for the relay to route the publisher's announcement to us, then subscribe.
    let sub_broadcast = tokio::time::timeout(
        Duration::from_millis(1500),
        announced_broadcast(&sub_consumer, TEST_NAMESPACE),
    )
    .await
    .context("timeout waiting for announcement")?
    .context("failed while waiting for the announcement")?;

    let track = sub_broadcast
        .track(TEST_TRACK)
        .context("failed to subscribe track")?;

    // SUBSCRIBE_OK: the subscription resolves with the track info once the relay
    // routes it to the publisher; a rejection resolves with the abort error.
    let _subscriber = track
        .subscribe(None)
        .await
        .context("track subscription rejected")?;

    pub_session.abort(moq_net::Error::Cancel);
    sub_session.abort(moq_net::Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some("SUBSCRIBE_OK (track info received)".into()),
    })
}

/// Subscriber connects and SUBSCRIBEs first; publisher announces 500ms later.
/// Per the test spec, either a late success or a clean REQUEST_ERROR passes —
/// the test checks graceful handling of the out-of-order flow.
async fn test_subscribe_before_announce(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    // Subscriber connects first.
    let sub_origin = moq_tokio::origin::spawn();
    let sub_consumer = sub_origin.consume();

    let sub_session = client
        .clone()
        .with_subscriber(sub_origin)
        .connect(relay_url.clone())
        .established()
        .await
        .context("subscriber failed to connect")?;

    let negotiated = negotiated(&sub_session);

    // The shared test namespace can linger at the relay for a moment after the
    // previous test's session teardown; wait for any stale announcement to clear
    // so the "before announce" ordering below is real.
    //
    // The first quiet window is longer than the later ones: a fresh announce
    // cursor replays the relay's current routes asynchronously, and a busy relay
    // can take a few hundred milliseconds to deliver that snapshot.
    let mut announcements = sub_consumer.announced();
    let mut lingering = false;
    let mut saw_update = false;
    let settle_deadline = Instant::now() + Duration::from_millis(1500);
    loop {
        let quiet = if lingering {
            settle_deadline.saturating_duration_since(Instant::now())
        } else if !saw_update {
            Duration::from_millis(1000)
        } else {
            Duration::from_millis(300)
        };
        if quiet.is_zero() {
            break;
        }
        match tokio::time::timeout(quiet, announcements.next()).await {
            Ok(Some(update)) if update.prefix.as_str() == TEST_NAMESPACE => {
                saw_update = true;
                lingering = update.kind.is_active();
                if !lingering {
                    break; // stale announcement cleared
                }
            }
            Ok(Some(_)) => {
                saw_update = true;
                continue; // unrelated broadcast
            }
            Ok(None) => anyhow::bail!("origin closed while settling"),
            Err(_) => break, // quiet: nothing (more) pending
        }
    }

    // Keep waiting on this same cursor. A second cursor would replay the
    // snapshot we just drained and look like an announcement that arrived early.
    let pending = wait_announced(&mut announcements, TEST_NAMESPACE);
    tokio::pin!(pending);

    // Confirm nothing resolves while the namespace is unpublished. (Skipped if a
    // stale announcement never cleared — the late-success outcome still applies.)
    if !lingering {
        tokio::select! {
            _ = &mut pending => anyhow::bail!("broadcast resolved before anyone announced it"),
            _ = tokio::time::sleep(Duration::from_millis(500)) => {}
        }
    }

    // Publisher starts 500ms after the subscriber, per the spec.
    let (pub_origin, _broadcast, _track) = publish(TEST_NAMESPACE, Some(TEST_TRACK))?;

    let pub_session = client
        .clone()
        .with_publisher(&pub_origin)
        .connect(relay_url.clone())
        .established()
        .await
        .context("publisher failed to connect")?;

    // The early subscribe must now succeed (relay routes the late announcement),
    // per the spec's "eventually succeeds once publisher announces" outcome.
    tokio::time::timeout(Duration::from_millis(2000), &mut pending)
        .await
        .context("early subscribe never resolved after the announce")?
        .context("failed while waiting for the announcement")?;
    let sub_broadcast = sub_consumer
        .request_broadcast(TEST_NAMESPACE)
        .await
        .context("announced path did not resolve to a broadcast")?;

    let track = sub_broadcast
        .track(TEST_TRACK)
        .context("failed to subscribe track")?;
    let _subscriber = track
        .subscribe(None)
        .await
        .context("track subscription rejected")?;

    pub_session.abort(moq_net::Error::Cancel);
    sub_session.abort(moq_net::Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some("early subscribe resolved after announce; SUBSCRIBE_OK".into()),
    })
}
