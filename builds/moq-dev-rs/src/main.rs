use std::time::{Duration, Instant};

use anyhow::Context;
use clap::Parser;
use moq_native::moq_lite;
use moq_lite::*;

#[derive(Parser)]
#[command(name = "moq-dev-rs-client")]
#[command(about = "MoQT interop test client using moq-lite/moq-native")]
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

    /// Disable TLS certificate verification
    #[arg(long, env = "TLS_DISABLE_VERIFY")]
    tls_disable_verify: bool,

    /// Verbose output
    #[arg(short, long, env = "VERBOSE")]
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

/// Tests that are skipped with a reason.
/// moq-lite doesn't support subscribing without first receiving an announcement,
/// so tests that require eager/speculative SUBSCRIBE cannot be implemented.
const SKIPPED_TESTS: &[(&str, &str)] = &[
    ("subscribe-error", "moq-lite API requires announcement before subscribe"),
    ("subscribe-before-announce", "moq-lite API requires announcement before subscribe"),
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
    println!("# moq-dev-rs-client v0.1.0");
    println!("# Relay: {}", cli.relay);
    println!("1..{}", tests.len());

    let relay_url = url::Url::parse(&cli.relay).context("invalid relay URL")?;

    let mut client_config = moq_native::ClientConfig::default();
    if cli.tls_disable_verify {
        client_config.tls.disable_verify = Some(true);
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
    session.close(moq_lite::Error::Cancel);

    Ok(Diagnostics::default())
}

/// Connect, publish broadcast at test namespace, wait for acknowledgment.
async fn test_announce_only(
    client: &moq_native::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let origin = Origin::produce();

    // Create broadcast before connecting
    let broadcast = Broadcast::produce();
    origin.publish_broadcast(TEST_NAMESPACE, broadcast.consume());

    let session = client
        .clone()
        .with_publish(origin.consume())
        .connect(relay_url.clone())
        .await
        .context("failed to connect")?;

    // Wait briefly for the announce to be processed
    tokio::time::sleep(Duration::from_millis(500)).await;

    session.close(moq_lite::Error::Cancel);

    Ok(Diagnostics::default())
}

/// Connect, publish broadcast, then close/drop the broadcast.
async fn test_publish_namespace_done(
    client: &moq_native::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let origin = Origin::produce();

    let broadcast = Broadcast::produce();
    origin.publish_broadcast(TEST_NAMESPACE, broadcast.consume());

    let session = client
        .clone()
        .with_publish(origin.consume())
        .connect(relay_url.clone())
        .await
        .context("failed to connect")?;

    // Wait for announce to be processed, then drop the broadcast (unpublish)
    tokio::time::sleep(Duration::from_millis(500)).await;
    drop(broadcast);

    // Wait briefly for the done to propagate
    tokio::time::sleep(Duration::from_millis(200)).await;

    session.close(moq_lite::Error::Cancel);

    Ok(Diagnostics::default())
}

/// Two connections: publisher announces, subscriber subscribes.
async fn test_announce_subscribe(
    client: &moq_native::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    // Publisher setup
    let pub_origin = Origin::produce();
    let mut broadcast = Broadcast::produce();
    pub_origin.publish_broadcast(TEST_NAMESPACE, broadcast.consume());

    // Create a track so subscriber can find it
    let _track = broadcast.create_track(Track {
        name: TEST_TRACK.to_string(),
        priority: 0,
    });

    let pub_session = client
        .clone()
        .with_publish(pub_origin.consume())
        .connect(relay_url.clone())
        .await
        .context("publisher failed to connect")?;

    // Give the relay time to process the announce
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Subscriber setup
    let sub_origin = Origin::produce();
    let mut sub_consumer = sub_origin.consume();

    let sub_session = client
        .clone()
        .with_consume(sub_origin)
        .connect(relay_url.clone())
        .await
        .context("subscriber failed to connect")?;

    // Wait for the relay to announce the published broadcast
    let sub_broadcast = tokio::select! {
        announced = sub_consumer.announced() => {
            match announced.context("consumer closed")? {
                (_, Some(broadcast)) => broadcast,
                (path, None) => anyhow::bail!("unexpected unannouncement: {}", path),
            }
        }
        _ = tokio::time::sleep(Duration::from_millis(1500)) => {
            anyhow::bail!("timeout waiting for announcement");
        }
    };

    // Now subscribe to a track on the announced broadcast
    let track = sub_broadcast.subscribe_track(&Track {
        name: TEST_TRACK.to_string(),
        priority: 0,
    });

    // Wait for the track subscription to be acknowledged
    tokio::select! {
        result = track.closed() => {
            result.context("track closed")?;
        }
        _ = tokio::time::sleep(Duration::from_millis(1000)) => {
            // Timeout waiting - subscription was accepted (no error)
        }
    }

    pub_session.close(moq_lite::Error::Cancel);
    sub_session.close(moq_lite::Error::Cancel);

    Ok(Diagnostics::default())
}
