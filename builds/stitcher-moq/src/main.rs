//! stitcher-moq interop test client (Paramount).
//!
//! Built on moq-dev's `moq-tokio` 0.19 / `moq-net` 0.3 crates from crates.io (pinned to the
//! moq-relay 0.17.3 release train) — the stack Paramount's stitcher-moq publisher and relay
//! run since 2026-10-11 — so it can
//! offer MoQT draft-22, the Seattle interop target, and implements all six canonical test
//! cases.
//!
//! By default it offers only the MoQT (IETF) drafts the crates implement, `moqt-22` down to
//! `moqt-14`: this is an MoQT interop client, and against a moq-dev relay an offer that also
//! listed moq-lite would negotiate moq-lite and exercise nothing IETF. `MOQ_CLIENT_VERSION`
//! (comma-separated, e.g. `moq-transport-18` or `moq-lite-05`) overrides the offer.
//!
//! Honest about what moq-net can put on the wire, and about what it can observe:
//!
//! - Its consumer API resolves a path only through a route someone announced, so a
//!   SUBSCRIBE for an unannounced path is answered *locally* (`unroutable`) and never
//!   reaches the relay. When that happens `subscribe-error` reports `# SKIP` (as moq-dev's
//!   own runner client does) instead of claiming a relay REQUEST_ERROR it never saw, and
//!   `subscribe-before-announce` sends its SUBSCRIBE only after the late announcement.
//! - It accepts an IETF subscription locally, before SUBSCRIBE_OK (objects may outrun the
//!   reply), so a resolved subscribe proves nothing about the relay. `announce-subscribe`
//!   and `subscribe-before-announce` pass only once the relay has routed the SUBSCRIBE to
//!   this client's own publisher and no REQUEST_ERROR followed; an abort that is not a
//!   REQUEST_ERROR (say, an answer that did not decode) is reported as such.
//! - It surfaces no PUBLISH_NAMESPACE_OK, so `announce-only` and `publish-namespace-done`
//!   report what they can see: the announce was not rejected and the session stayed up.
//!
//! Subscribers discover the namespace under test (SUBSCRIBE_NAMESPACE `moq-test/interop`),
//! not the empty prefix, which draft-14 forbids and several relays reject. Sessions close
//! subscriber first, and the process lets its last CONNECTION_CLOSE go out before it
//! exits: a relay that still holds a dead session routes the next run's SUBSCRIBE to it.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use anyhow::Context;
use clap::Parser;
use moq_net::origin::Route;
use moq_net::Error;
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
    "rendezvous-timeout",
    "announce-subscribe",
    "subscribe-before-announce",
];

const TEST_NAMESPACE: &str = "moq-test/interop";
const TEST_TRACK: &str = "test-track";
const NONEXISTENT_NAMESPACE: &str = "nonexistent/namespace";

/// The default offer: every MoQT draft moq-net 0.3 implements, newest first.
const IETF_VERSIONS: &[&str] = &[
    "moq-transport-22",
    "moq-transport-21",
    "moq-transport-20",
    "moq-transport-19",
    "moq-transport-18",
    "moq-transport-17",
    "moq-transport-16",
    "moq-transport-15",
    "moq-transport-14",
];

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
            .with_env_filter("moq_net=debug,moq_tokio=debug")
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

    // The offered protocol versions: MOQ_CLIENT_VERSION (comma-separated, e.g.
    // "moq-transport-18") when set, otherwise every MoQT draft (see IETF_VERSIONS).
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
    println!("# stitcher-moq-client v0.2.0 (moq-net 0.3.11 via moq-tokio 0.19.24)");
    println!("# Relay: {}", cli.relay);
    println!("# Offered: {}", offered.join(", "));
    println!("1..{}", tests.len());

    // `connect::Config` is `#[non_exhaustive]`: take the defaults and set what we own.
    let mut config = moq_tokio::connect::Config::default();
    config.version = versions;
    if cli.tls_disable_verify {
        config.tls.insecure = Some(true);
    }
    // One dial per test: a failed connect must fail the test, not be retried.
    config.once = Some(true);
    let client = config
        .init(moq_tokio::quic::Config::default())
        .context("failed to init client")?;

    let mut all_passed = true;

    for (i, test_name) in tests.iter().enumerate() {
        let num = i + 1;
        let start = Instant::now();

        let result = run_test(test_name, &client, &relay_url).await;
        let duration_ms = start.elapsed().as_millis();

        match result {
            Ok(diag) => {
                match &diag.skip {
                    Some(reason) => println!("ok {} - {} # SKIP {}", num, test_name, reason),
                    None => println!("ok {} - {}", num, test_name),
                }
                print_diagnostics(duration_ms, &diag);
            }
            Err(e) => {
                all_passed = false;
                println!("not ok {} - {}", num, test_name);
                print_failure_diagnostics(duration_ms, &format!("{:#}", e));
            }
        }
    }

    // Let the last sessions' QUIC CONNECTION_CLOSE go out before the process exits, so
    // the relay isn't left holding them until its idle timeout.
    tokio::time::sleep(Duration::from_millis(200)).await;

    if !all_passed {
        std::process::exit(1);
    }

    Ok(())
}

#[derive(Default)]
struct Diagnostics {
    negotiated: Option<String>,
    outcome: Option<String>,
    /// Report the test as `ok … # SKIP <reason>`: nothing was exercised on the wire.
    skip: Option<String>,
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
        "rendezvous-timeout" => Duration::from_secs(2),
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
        "rendezvous-timeout" => Ok(test_rendezvous_timeout()),
        "announce-subscribe" => test_announce_subscribe(client, relay_url).await,
        "subscribe-before-announce" => test_subscribe_before_announce(client, relay_url).await,
        _ => anyhow::bail!("unknown test: {}", name),
    }
}

/// rendezvous-timeout wants a SUBSCRIBE carrying RENDEZVOUS_TIMEOUT. moq-net 0.3 decodes that
/// parameter but its subscribe API cannot send one, so the test is reported as not implemented
/// rather than run without the parameter (which would just repeat subscribe-error).
fn test_rendezvous_timeout() -> Diagnostics {
    Diagnostics {
        skip: Some("not implemented: moq-net 0.3 cannot put RENDEZVOUS_TIMEOUT on a SUBSCRIBE".into()),
        ..Default::default()
    }
}

/// Dial the relay once — as a publisher of `publish`, a subscriber into `subscribe`, or
/// neither — and wait until the MoQ session is established.
async fn connect(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
    publish: Option<moq_net::origin::Consumer>,
    subscribe: Option<moq_net::origin::Producer>,
) -> anyhow::Result<moq_tokio::Connection> {
    let mut client = client.clone();
    if let Some(origin) = publish {
        client = client.with_publisher(origin);
    }
    if let Some(origin) = subscribe {
        client = client.with_subscriber(origin);
    }
    client
        .connect(relay_url.clone())
        .established()
        .await
        .context("failed to connect")
}

fn negotiated(connection: &moq_tokio::Connection) -> String {
    connection
        .version()
        .map(|v| v.to_string())
        .unwrap_or_else(|| "unknown".into())
}

/// Connect, complete SETUP, close gracefully.
async fn test_setup_only(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let connection = connect(client, relay_url, None, None).await?;
    let negotiated = negotiated(&connection);
    connection.abort(Error::Cancel);

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
    let origin = moq_tokio::origin::spawn();
    let broadcast = origin
        .create_broadcast(TEST_NAMESPACE)
        .context("failed to create broadcast")?;
    // On the 0.15 line a broadcast is invisible until announced.
    broadcast
        .announce(Route::default())
        .context("failed to announce")?;

    let connection = connect(client, relay_url, Some(origin.consume()), None).await?;
    let negotiated = negotiated(&connection);

    tokio::select! {
        res = connection.closed() => anyhow::bail!("session closed after announce: {:?}", res),
        _ = tokio::time::sleep(Duration::from_millis(700)) => {}
    }

    connection.abort(Error::Cancel);
    drop(broadcast);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some(
            "PUBLISH_NAMESPACE not rejected: session healthy 700 ms later (moq-net does not surface PUBLISH_NAMESPACE_OK)"
                .into(),
        ),
        ..Default::default()
    })
}

/// Connect, announce, then withdraw the namespace (PUBLISH_NAMESPACE_DONE on the wire).
async fn test_publish_namespace_done(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let origin = moq_tokio::origin::spawn();
    let broadcast = origin
        .create_broadcast(TEST_NAMESPACE)
        .context("failed to create broadcast")?;
    broadcast
        .announce(Route::default())
        .context("failed to announce")?;

    let connection = connect(client, relay_url, Some(origin.consume()), None).await?;
    let negotiated = negotiated(&connection);

    // Let the announce land.
    tokio::select! {
        res = connection.closed() => anyhow::bail!("session closed after announce: {:?}", res),
        _ = tokio::time::sleep(Duration::from_millis(500)) => {}
    }

    // Withdraw: retract the announcement, then end the broadcast.
    broadcast.unannounce();
    broadcast.close();
    drop(broadcast);

    tokio::select! {
        res = connection.closed() => anyhow::bail!("session closed after unpublish: {:?}", res),
        _ = tokio::time::sleep(Duration::from_millis(300)) => {}
    }

    connection.abort(Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some("PUBLISH_NAMESPACE_DONE sent; session healthy 300 ms later".into()),
        ..Default::default()
    })
}

/// SUBSCRIBE to a nonexistent namespace/track and expect a clean per-request error
/// (REQUEST_ERROR / not-found), with the session surviving.
async fn test_subscribe_error(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let root = moq_tokio::origin::spawn();
    let origin = scoped(&root, NONEXISTENT_NAMESPACE)?;
    let consumer = origin.consume();

    let connection = connect(client, relay_url, None, Some(origin)).await?;
    let negotiated = negotiated(&connection);

    let mut skip = None;
    let outcome = match consumer.request_broadcast(NONEXISTENT_NAMESPACE).await {
        // No announced route covers the path, so moq-net answered without sending a
        // SUBSCRIBE: the relay's REQUEST_ERROR path was not exercised.
        Err(Error::Unroutable) => {
            skip = Some(
                "moq-net answers a request for an unannounced path locally (unroutable); no SUBSCRIBE reached the relay"
                    .to_string(),
            );
            "request answered locally: unroutable".to_string()
        }
        Err(e) => format!("request rejected cleanly: {}", e),
        Ok(broadcast) => {
            // The request resolved optimistically (a route covers the path), so a SUBSCRIBE
            // goes to the relay. moq-net accepts an IETF subscription locally before the
            // answer arrives; the relay's REQUEST_ERROR shows up as the track aborting.
            let track = broadcast
                .track(TEST_TRACK)
                .context("failed to request track")?;
            match track.subscribe(None).await {
                Err(e) => format!("track rejected cleanly: {}", e),
                Ok(mut subscriber) => {
                    match tokio::time::timeout(Duration::from_millis(1000), subscriber.recv_group())
                        .await
                    {
                        Ok(Err(e)) if is_request_error(&e) => format!("REQUEST_ERROR: {}", e),
                        Ok(Err(e)) => anyhow::bail!(
                            "the subscription failed locally ({}), not with a REQUEST_ERROR",
                            e
                        ),
                        _ => anyhow::bail!(
                            "relay did not reject the SUBSCRIBE for a nonexistent track within 1000 ms"
                        ),
                    }
                }
            }
        }
    };

    // The error must be request-scoped: the session has to survive it.
    tokio::select! {
        res = connection.closed() => anyhow::bail!("session died instead of returning a request error: {:?}", res),
        _ = tokio::time::sleep(Duration::from_millis(300)) => {}
    }

    connection.abort(Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some(outcome),
        skip,
    })
}

/// Two connections: publisher announces + serves a track, subscriber subscribes.
async fn test_announce_subscribe(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let started = Instant::now();

    // Publisher.
    let pub_origin = moq_tokio::origin::spawn();
    let broadcast = pub_origin
        .create_broadcast(TEST_NAMESPACE)
        .context("failed to create broadcast")?;
    let pub_track = broadcast
        .create_track(TEST_TRACK, None)
        .context("failed to create track")?;
    broadcast
        .announce(Route::default())
        .context("failed to announce")?;

    let pub_connection = connect(client, relay_url, Some(pub_origin.consume()), None)
        .await
        .context("publisher")?;

    // Give the relay time to process the announce.
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Subscriber.
    let sub_root = moq_tokio::origin::spawn();
    let sub_origin = scoped(&sub_root, TEST_NAMESPACE)?;
    let sub_consumer = sub_origin.consume();
    let dialed = Instant::now();
    let sub_connection = connect(client, relay_url, None, Some(sub_origin))
        .await
        .context("subscriber")?;
    let rtt_hint = rtt(&sub_connection, dialed.elapsed());
    let negotiated = negotiated(&sub_connection);

    // Wait for the relay to route the publisher's announcement to us, then subscribe.
    let sub_broadcast = tokio::time::timeout(
        Duration::from_millis(1500),
        sub_consumer.routed_broadcast(TEST_NAMESPACE),
    )
    .await
    .context("timeout waiting for announcement")?
    .context("broadcast never became routable")?;

    let track = sub_broadcast
        .track(TEST_TRACK)
        .context("failed to subscribe track")?;
    let mut subscriber = track
        .subscribe(None)
        .await
        .context("track subscription rejected")?;

    // Leave room in the 3 s budget for the confirm window.
    let route_by = started + Duration::from_millis(2400);
    let routed = match relay_answer(
        &pub_track,
        &mut subscriber,
        route_by,
        confirm_window(rtt_hint),
    )
    .await?
    {
        RelayAnswer::Accepted { routed } => routed,
        RelayAnswer::Rejected(e) => anyhow::bail!("relay rejected the SUBSCRIBE: {}", e),
    };

    // Subscriber leaves first, then the publisher: a relay that tears a namespace down
    // lazily while a subscription through it is live can otherwise keep advertising it
    // into the next test.
    drop(subscriber);
    sub_connection.abort(Error::Cancel);
    tokio::time::sleep(Duration::from_millis(100)).await;
    pub_connection.abort(Error::Cancel);
    drop(broadcast);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some(format!(
            "relay routed the SUBSCRIBE to the publisher ({} ms), no REQUEST_ERROR followed",
            routed.as_millis()
        )),
        ..Default::default()
    })
}

/// Subscriber connects first; publisher announces 500ms later.
/// Per the test spec, either a late success or a clean REQUEST_ERROR passes: the test
/// checks graceful handling of the out-of-order flow. moq-net sends a SUBSCRIBE only once
/// an announced route covers the path, so the subscriber's interest waits locally and the
/// SUBSCRIBE goes out after the late announce reaches it.
async fn test_subscribe_before_announce(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let started = Instant::now();

    // Subscriber connects first.
    let sub_root = moq_tokio::origin::spawn();
    let sub_origin = scoped(&sub_root, TEST_NAMESPACE)?;
    let sub_consumer = sub_origin.consume();
    let dialed = Instant::now();
    let sub_connection = connect(client, relay_url, None, Some(sub_origin))
        .await
        .context("subscriber")?;
    let rtt_hint = rtt(&sub_connection, dialed.elapsed());
    let negotiated = negotiated(&sub_connection);

    // "Before announce" only means something if the relay is not already advertising
    // the namespace. It can be: a relay may keep a previous session's namespace listed
    // for a while after that session is gone. The relay's namespace snapshot arrives a
    // round trip or two after SETUP, so watch until then, and give a stale covering
    // route a bounded chance to retract.
    let mut announcements = sub_consumer.announced();
    let mut stale: HashSet<String> = HashSet::new();
    let snapshot_by = Instant::now() + snapshot_window(rtt_hint);
    let give_up = snapshot_by + Duration::from_millis(800);
    loop {
        let until = if stale.is_empty() {
            snapshot_by
        } else {
            give_up
        };
        let wait = until.saturating_duration_since(Instant::now());
        if wait.is_zero() {
            break;
        }
        match tokio::time::timeout(wait, announcements.next()).await {
            Ok(Some(update)) if covers(update.prefix.as_str(), TEST_NAMESPACE) => {
                let prefix = update.prefix.as_str().to_string();
                if matches!(update.kind, moq_net::announce::Kind::Retracted) {
                    stale.remove(&prefix);
                } else {
                    stale.insert(prefix);
                }
            }
            Ok(Some(_)) => continue, // unrelated route
            Ok(None) => anyhow::bail!("origin closed while settling"),
            Err(_) => break,
        }
    }

    // Express interest before any announcement exists: start waiting for the broadcast
    // now. The wait completes once the publisher's announce is routed to us.
    let pending = sub_consumer.routed_broadcast(TEST_NAMESPACE);
    tokio::pin!(pending);

    // Nothing may resolve while the namespace is unpublished. Anything that does is not
    // our publisher (it doesn't exist yet): a stale route the snapshot delivered late.
    // Note it rather than fail; the subscribe-first ordering just can't be claimed.
    let mut ordered = stale.is_empty();
    let mut resolved_early = false;
    tokio::select! {
        _ = &mut pending => {
            ordered = false;
            resolved_early = true;
        }
        _ = tokio::time::sleep(Duration::from_millis(500)) => {}
    }

    // Updates so far predate our publisher; drop them so the wait below sees its announce.
    while announcements.try_next().is_some() {}

    // Publisher starts 500ms after the subscriber, per the spec.
    let pub_origin = moq_tokio::origin::spawn();
    let broadcast = pub_origin
        .create_broadcast(TEST_NAMESPACE)
        .context("failed to create broadcast")?;
    let pub_track = broadcast
        .create_track(TEST_TRACK, None)
        .context("failed to create track")?;
    broadcast
        .announce(Route::default())
        .context("failed to announce")?;

    let pub_connection = connect(client, relay_url, Some(pub_origin.consume()), None)
        .await
        .context("publisher")?;

    let sub_broadcast = if resolved_early {
        // Resolved through a stale route: give our announce a moment to reach the relay
        // (and us), then resolve afresh, so the SUBSCRIBE neither races the announce nor
        // rides a route that may be about to retract.
        let _ = tokio::time::timeout(Duration::from_millis(1000), async {
            while let Some(update) = announcements.next().await {
                if covers(update.prefix.as_str(), TEST_NAMESPACE)
                    && !matches!(update.kind, moq_net::announce::Kind::Retracted)
                {
                    break;
                }
            }
        })
        .await;
        tokio::time::timeout(
            Duration::from_millis(1500),
            sub_consumer.routed_broadcast(TEST_NAMESPACE),
        )
        .await
        .context("no route after the announce")?
        .context("broadcast never became routable")?
    } else {
        // The early interest must now resolve (the relay routes the late announcement),
        // per the spec's "eventually succeeds once publisher announces" outcome.
        tokio::time::timeout(Duration::from_millis(2000), &mut pending)
            .await
            .context("early subscribe never resolved after the announce")?
            .context("broadcast never became routable")?
    };

    let track = sub_broadcast
        .track(TEST_TRACK)
        .context("failed to subscribe track")?;
    let mut subscriber = track
        .subscribe(None)
        .await
        .context("track subscription rejected")?;

    // Leave room in the 5 s budget for the confirm window.
    let route_by = started + Duration::from_millis(4300);
    let answer = relay_answer(
        &pub_track,
        &mut subscriber,
        route_by,
        confirm_window(rtt_hint),
    )
    .await?;

    // The spec also accepts a clean REQUEST_ERROR, provided it is request-scoped.
    if let RelayAnswer::Rejected(_) = &answer {
        tokio::select! {
            res = sub_connection.closed() => anyhow::bail!("session died instead of returning a request error: {:?}", res),
            _ = tokio::time::sleep(Duration::from_millis(100)) => {}
        }
    }

    drop(subscriber);
    sub_connection.abort(Error::Cancel);
    tokio::time::sleep(Duration::from_millis(100)).await;
    pub_connection.abort(Error::Cancel);
    drop(broadcast);

    let routed = match answer {
        RelayAnswer::Accepted { routed } => routed,
        RelayAnswer::Rejected(e) => {
            return Ok(Diagnostics {
                negotiated: Some(negotiated),
                outcome: Some(format!(
                    "relay answered the SUBSCRIBE with REQUEST_ERROR ({}) and the session survived; the spec accepts a clean REQUEST_ERROR here",
                    e
                )),
                ..Default::default()
            });
        }
    };

    let outcome = if ordered {
        format!(
            "subscriber connected first; nothing resolved until the late announce, which the relay routed to it; the SUBSCRIBE then reached the publisher ({} ms), no REQUEST_ERROR followed (moq-net sends SUBSCRIBE only after an announce)",
            routed.as_millis()
        )
    } else {
        format!(
            "relay still advertised {} from an earlier session when the subscriber connected, so subscribe-first ordering is unverified; after the late announce the SUBSCRIBE reached the publisher ({} ms), no REQUEST_ERROR followed",
            TEST_NAMESPACE,
            routed.as_millis()
        )
    };

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some(outcome),
        ..Default::default()
    })
}

/// Whether an announced route for `prefix` covers `path`: moq-net routes cover every
/// path beneath them, and the empty prefix covers everything.
fn covers(prefix: &str, path: &str) -> bool {
    prefix.is_empty()
        || path == prefix
        || (path.starts_with(prefix) && path.as_bytes().get(prefix.len()) == Some(&b'/'))
}

/// The connection's smoothed round-trip time, or `fallback` (the connect time) when the
/// transport doesn't report one. The connect time alone overstates it whenever the
/// handshake needed retransmissions.
fn rtt(connection: &moq_tokio::Connection, fallback: Duration) -> Duration {
    connection
        .monitor()
        .stats()
        .and_then(|stats| stats.rtt)
        .unwrap_or(fallback)
}

/// How long after SETUP a relay's namespace snapshot can take to arrive: its SETUP,
/// then SUBSCRIBE_NAMESPACE and the answer, each about a round trip.
fn snapshot_window(rtt_hint: Duration) -> Duration {
    (rtt_hint * 4).clamp(Duration::from_millis(600), Duration::from_millis(1500))
}

/// How long to watch for a REQUEST_ERROR after the relay routed a SUBSCRIBE: the
/// publisher's SUBSCRIBE_OK, and the relay's answer to us, are a round trip.
fn confirm_window(rtt_hint: Duration) -> Duration {
    (rtt_hint * 2).clamp(Duration::from_millis(200), Duration::from_millis(500))
}

/// What the relay did with a subscription moq-net had already accepted locally.
enum RelayAnswer {
    /// Routed to our publisher, and no REQUEST_ERROR followed within the confirm window.
    Accepted { routed: Duration },
    /// Answered with REQUEST_ERROR (the error its code maps to).
    Rejected(Error),
}

/// Whether a subscription's abort error is what moq-net makes of a REQUEST_ERROR code,
/// as opposed to a local failure (an answer that did not decode, a dead session, ...).
fn is_request_error(err: &Error) -> bool {
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

/// A subscription abort as a relay answer, or the local failure it really is.
fn rejection(err: Error) -> anyhow::Result<RelayAnswer> {
    if is_request_error(&err) {
        Ok(RelayAnswer::Rejected(err))
    } else {
        anyhow::bail!(
            "the subscription failed locally ({}), not with a REQUEST_ERROR: e.g. the relay's answer did not decode",
            err
        )
    }
}

/// Evidence of what the relay did with a subscription.
///
/// moq-net resolves an IETF subscription locally, before SUBSCRIBE_OK (objects can
/// outrun the reply, so it accepts at once and a later REQUEST_ERROR aborts the track),
/// so the resolve alone proves nothing about the relay. What does: the relay routing
/// the SUBSCRIBE to our own publisher (its track gains a consumer) by `route_by`, then no
/// REQUEST_ERROR within `confirm`.
async fn relay_answer(
    publisher_track: &moq_net::track::Producer,
    subscriber: &mut moq_net::track::Subscriber,
    route_by: Instant,
    confirm: Duration,
) -> anyhow::Result<RelayAnswer> {
    let start = Instant::now();
    let route_within = route_by.saturating_duration_since(start);
    tokio::select! {
        res = publisher_track.used() => {
            res.context("publisher track closed before the SUBSCRIBE reached it")?
        }
        res = subscriber.recv_group() => return match res {
            Err(e) => rejection(e),
            Ok(_) => anyhow::bail!("subscription ended before the relay routed it to the publisher"),
        },
        _ = tokio::time::sleep(route_within) => anyhow::bail!(
            "the relay did not route the SUBSCRIBE to the publisher within {} ms (and sent no REQUEST_ERROR)",
            route_within.as_millis()
        ),
    }
    let routed = start.elapsed();

    match tokio::time::timeout(confirm, subscriber.recv_group()).await {
        Ok(Err(e)) => rejection(e),
        // Still open (or already carrying data, or cleanly finished): accepted.
        Err(_) | Ok(Ok(_)) => Ok(RelayAnswer::Accepted { routed }),
    }
}

/// A subscriber origin scoped to `namespace`, so moq-net's namespace discovery asks the
/// relay for that prefix (SUBSCRIBE_NAMESPACE `namespace`) rather than the empty prefix,
/// which draft-14 forbids and which several relays reject or answer without the
/// namespaces already published. Keep `root` alive for as long as the scoped origin.
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
