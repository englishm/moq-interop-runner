use std::time::{Duration, Instant};

use anyhow::Context;
use clap::Parser;
use moq_native::moq_net;
use moq_net::{broadcast, Error, Origin};

#[derive(Parser)]
#[command(name = "moq-dev-rs-client")]
#[command(about = "MoQT interop test client using moq-net/moq-native")]
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
    /// The container entrypoint translates the interface's 0/1 environment value
    /// to this flag because clap's boolean environment parser rejects 0 and 1.
    #[arg(long)]
    tls_disable_verify: bool,

    /// Verbose output. The container entrypoint translates the environment value.
    #[arg(short, long)]
    verbose: bool,
}

const TESTS: &[&str] = &[
    "setup-only",
    "announce-only",
    "publish-namespace-done",
    "subscribe-namespace-lifecycle",
    "subscribe-error",
    "announce-subscribe",
    "subscribe-before-announce",
];

/// Tests that are skipped with a reason.
/// The moq-net consumer API exposes tracks after namespace discovery, so it cannot
/// send the speculative SUBSCRIBE required by these tests.
const SKIPPED_TESTS: &[(&str, &str)] = &[
    (
        "subscribe-error",
        "moq-net API requires namespace discovery before SUBSCRIBE",
    ),
    (
        "subscribe-before-announce",
        "moq-net API requires namespace discovery before SUBSCRIBE",
    ),
];

const TEST_NAMESPACE: &str = "moq-test/interop";
const TEST_TRACK: &str = "test-track";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    if cli.list {
        for t in TESTS {
            println!("{}", t);
        }
        return Ok(());
    }

    if cli.verbose {
        tracing_subscriber::fmt()
            .with_env_filter("moq=debug,moq_native=debug")
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
    println!("# moq-dev-rs-client v0.1.0 (moq-native 0.19.15)");
    println!("# Relay: {}", cli.relay);
    println!("1..{}", tests.len());

    let relay_url = url::Url::parse(&cli.relay).context("invalid relay URL")?;

    let mut client_config = moq_native::ClientConfig::default();
    if cli.tls_disable_verify {
        client_config.tls.disable_verify = Some(true);
    }

    // Optionally pin the offered protocol version(s) via MOQ_CLIENT_VERSION
    // (comma-separated, e.g. "moq-transport-18"). By default the client offers
    // every supported version and lets the relay choose -- which prefers the
    // native moq-lite protocol over IETF moq-transport when both are available.
    // Pin a version to force a specific draft for interop testing.
    if let Ok(versions) = std::env::var("MOQ_CLIENT_VERSION") {
        let versions = versions
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|s| {
                s.parse::<moq_net::Version>()
                    .map_err(|e| anyhow::anyhow!(e))
            })
            .collect::<anyhow::Result<Vec<_>>>()
            .context("invalid MOQ_CLIENT_VERSION")?;
        if !versions.is_empty() {
            client_config.version = versions;
        }
    }

    let client = client_config.init().context("failed to init client")?;

    let mut all_passed = true;

    for (i, test_name) in tests.iter().enumerate() {
        let num = i + 1;

        // Check if this test should be skipped
        if let Some((_, reason)) = SKIPPED_TESTS.iter().find(|(name, _)| name == test_name) {
            println!("ok {} - {} # SKIP {}", num, test_name, reason);
            continue;
        }

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

#[derive(Default)]
struct Diagnostics {
    connection_id: Option<String>,
    publisher_connection_id: Option<String>,
    subscriber_connection_id: Option<String>,
    negotiated: Option<String>,
    outcome: Option<String>,
}

fn print_diagnostics(duration_ms: u128, diag: &Diagnostics) {
    println!("  ---");
    println!("  duration_ms: {}", duration_ms);
    if let Some(id) = &diag.connection_id {
        println!("  connection_id: {}", id);
    }
    if let Some(id) = &diag.publisher_connection_id {
        println!("  publisher_connection_id: {}", id);
    }
    if let Some(id) = &diag.subscriber_connection_id {
        println!("  subscriber_connection_id: {}", id);
    }
    if let Some(version) = &diag.negotiated {
        println!("  negotiated: {}", version);
    }
    if let Some(outcome) = &diag.outcome {
        println!("  outcome: \"{}\"", outcome.replace('"', "\\\""));
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
    client: &moq_native::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let timeout = match name {
        "setup-only" => Duration::from_secs(2),
        "announce-only" => Duration::from_secs(2),
        "publish-namespace-done" => Duration::from_secs(2),
        "subscribe-namespace-lifecycle" => Duration::from_secs(12),
        "announce-subscribe" => Duration::from_secs(3),
        _ => Duration::from_secs(5),
    };

    tokio::time::timeout(timeout, run_test_inner(name, client, relay_url))
        .await
        .context(format!("timeout after {}ms", timeout.as_millis()))?
}

async fn run_test_inner(
    name: &str,
    client: &moq_native::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    match name {
        "setup-only" => test_setup_only(client, relay_url).await,
        "announce-only" => test_announce_only(client, relay_url).await,
        "publish-namespace-done" => test_publish_namespace_done(client, relay_url).await,
        "subscribe-namespace-lifecycle" => {
            test_subscribe_namespace_lifecycle(client, relay_url).await
        }
        "announce-subscribe" => test_announce_subscribe(client, relay_url).await,
        _ => anyhow::bail!("unknown test: {}", name),
    }
}

/// Connect via WebTransport, complete handshake, close session.
async fn test_setup_only(
    client: &moq_native::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let session = client
        .clone()
        .connect(relay_url.clone())
        .await
        .context("failed to connect")?;
    let negotiated = session.version().to_string();
    session.abort(Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        ..Default::default()
    })
}

/// Connect, publish broadcast at test namespace, wait for acknowledgment.
async fn test_announce_only(
    client: &moq_native::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let origin = Origin::random().produce();

    let _broadcast = origin
        .create_broadcast(TEST_NAMESPACE, broadcast::Route::new().with_announce(true))
        .context("failed to create broadcast")?;

    let session = client
        .clone()
        .with_publisher(&origin)
        .connect(relay_url.clone())
        .await
        .context("failed to connect")?;
    let negotiated = session.version().to_string();

    tokio::select! {
        error = session.closed() => anyhow::bail!("session closed after announce: {}", error),
        _ = tokio::time::sleep(Duration::from_millis(500)) => {}
    }

    session.abort(Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some("namespace remained accepted".into()),
        ..Default::default()
    })
}

/// Connect, publish broadcast, then close/drop the broadcast.
async fn test_publish_namespace_done(
    client: &moq_native::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let origin = Origin::random().produce();

    let mut broadcast = origin
        .create_broadcast(TEST_NAMESPACE, broadcast::Route::new().with_announce(true))
        .context("failed to create broadcast")?;

    let session = client
        .clone()
        .with_publisher(&origin)
        .connect(relay_url.clone())
        .await
        .context("failed to connect")?;
    let negotiated = session.version().to_string();

    tokio::select! {
        error = session.closed() => anyhow::bail!("session closed after announce: {}", error),
        _ = tokio::time::sleep(Duration::from_millis(500)) => {}
    }

    broadcast.finish();

    tokio::select! {
        error = session.closed() => anyhow::bail!("session closed after unpublish: {}", error),
        _ = tokio::time::sleep(Duration::from_millis(200)) => {}
    }

    session.abort(Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some("namespace withdrawn cleanly".into()),
        ..Default::default()
    })
}

async fn next_namespace_state(
    announcements: &mut moq_net::announce::Consumer,
    namespace: &str,
) -> anyhow::Result<bool> {
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let event = announcements
                .next()
                .await
                .context("namespace subscription closed")?;
            if event.path.as_str() == namespace {
                return Ok(event.broadcast.is_some());
            }
        }
    })
    .await
    .context("timeout waiting for namespace event")?
}

/// Observe NAMESPACE followed by NAMESPACE_DONE for one unique namespace.
async fn test_subscribe_namespace_lifecycle(
    client: &moq_native::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let subscriber_id = Origin::random();
    let publisher_id = Origin::random();
    let namespace =
        format!("{TEST_NAMESPACE}/subscribe-namespace-lifecycle/{subscriber_id}-{publisher_id}");

    let sub_origin = subscriber_id
        .produce()
        .scope(&[moq_net::Path::new(namespace.as_str())])
        .context("failed to scope namespace subscriber")?;
    let mut announcements = sub_origin.consume().announced();
    let sub_session = client
        .clone()
        .with_subscriber(sub_origin)
        .connect(relay_url.clone())
        .await
        .context("namespace subscriber failed to connect")?;
    let negotiated = sub_session.version().to_string();

    let pub_origin = publisher_id.produce();
    let mut broadcast = pub_origin
        .create_broadcast(&namespace, broadcast::Route::new().with_announce(true))
        .context("failed to create lifecycle broadcast")?;
    let pub_session = client
        .clone()
        .with_publisher(&pub_origin)
        .connect(relay_url.clone())
        .await
        .context("namespace publisher failed to connect")?;

    anyhow::ensure!(
        next_namespace_state(&mut announcements, &namespace).await?,
        "received NAMESPACE_DONE before NAMESPACE"
    );
    broadcast.finish();
    drop(broadcast);
    anyhow::ensure!(
        !next_namespace_state(&mut announcements, &namespace).await?,
        "received duplicate NAMESPACE before NAMESPACE_DONE"
    );

    pub_session.abort(Error::Cancel);
    sub_session.abort(Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some("observed NAMESPACE followed by NAMESPACE_DONE".into()),
        ..Default::default()
    })
}

/// Two connections: publisher announces, subscriber subscribes.
async fn test_announce_subscribe(
    client: &moq_native::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    // Publisher setup
    let pub_origin = Origin::random().produce();
    let mut broadcast = pub_origin
        .create_broadcast(TEST_NAMESPACE, broadcast::Route::new().with_announce(true))
        .context("failed to create broadcast")?;

    // Create a track so subscriber can find it
    let mut pub_track = broadcast
        .create_track(TEST_TRACK, None)
        .context("failed to create track")?;

    let pub_session = client
        .clone()
        .with_publisher(&pub_origin)
        .connect(relay_url.clone())
        .await
        .context("publisher failed to connect")?;

    // Give the relay time to process the announce
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Subscriber setup
    let sub_origin = Origin::random()
        .produce()
        .scope(&[moq_net::Path::new(TEST_NAMESPACE)])
        .context("failed to scope subscriber to the test namespace")?;
    let sub_consumer = sub_origin.consume();

    let sub_session = client
        .clone()
        .with_subscriber(sub_origin)
        .connect(relay_url.clone())
        .await
        .context("subscriber failed to connect")?;
    let negotiated = sub_session.version().to_string();

    // moq-net currently discovers namespaces before it can send a track SUBSCRIBE.
    // Wait for the exact path so unrelated relay announcements cannot produce a false pass.
    let sub_broadcast = tokio::time::timeout(
        Duration::from_millis(1500),
        sub_consumer.announced_broadcast(TEST_NAMESPACE),
    )
    .await
    .context("timeout waiting for the test namespace announcement")?
    .context("origin closed before the test namespace was announced")?;

    let track = sub_broadcast
        .track(TEST_TRACK)
        .context("failed to request track")?;
    let subscriber = track
        .subscribe(None)
        .await
        .context("track subscription rejected")?;

    drop(subscriber);
    pub_track.finish().context("failed to finish track")?;
    broadcast.finish();
    pub_session.abort(Error::Cancel);
    sub_session.abort(Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some("SUBSCRIBE_OK for moq-test/interop/test-track".into()),
        ..Default::default()
    })
}
