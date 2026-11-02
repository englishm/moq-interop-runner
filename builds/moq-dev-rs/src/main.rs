use std::time::{Duration, Instant};

use anyhow::Context;
use clap::Parser;
use moq_net::{broadcast, track, Error, Pattern, Patterns, Timestamp};
use moq_tokio::moq_net;

#[derive(Parser)]
#[command(name = "moq-dev-rs-client")]
#[command(about = "MoQT interop test client using moq-net/moq-tokio")]
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
    "data-subgroup-basic",
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

/// The revision of each prose specification this client implements, for tests that declare one.
fn spec_revision(test: &str) -> Option<u32> {
    match test {
        "data-subgroup-basic" => Some(2),
        _ => None,
    }
}

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
            .with_env_filter("moq=debug,moq_net=debug,moq_tokio=debug")
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
    println!("# moq-dev-rs-client v0.1.0 (moq-tokio 0.19.28)");
    println!("# Relay: {}", cli.relay);
    println!("1..{}", tests.len());

    let relay_url = url::Url::parse(&cli.relay).context("invalid relay URL")?;

    let mut client_config = moq_tokio::connect::Config::default();
    // Each test dials once; a dropped session is a failure, not something to redial.
    client_config.once = Some(true);
    if cli.tls_disable_verify {
        client_config.tls.insecure = Some(true);
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

    let client = client_config
        .init(moq_tokio::quic::Config::default())
        .context("failed to init client")?;

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
                print_diagnostics(duration_ms, spec_revision(test_name), &diag);
            }
            Err(e) => {
                all_passed = false;
                println!("not ok {} - {}", num, test_name);
                print_failure_diagnostics(
                    duration_ms,
                    spec_revision(test_name),
                    &format!("{:#}", e),
                );
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

fn print_diagnostics(duration_ms: u128, revision: Option<u32>, diag: &Diagnostics) {
    println!("  ---");
    println!("  duration_ms: {}", duration_ms);
    if let Some(revision) = revision {
        println!("  test_spec_revision: {}", revision);
    }
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

fn print_failure_diagnostics(duration_ms: u128, revision: Option<u32>, message: &str) {
    println!("  ---");
    println!("  duration_ms: {}", duration_ms);
    if let Some(revision) = revision {
        println!("  test_spec_revision: {}", revision);
    }
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
        "subscribe-namespace-lifecycle" => Duration::from_secs(12),
        "announce-subscribe" => Duration::from_secs(3),
        // Two 5 s setup and subscription phases, then 10 s to deliver and drain.
        "data-subgroup-basic" => Duration::from_secs(20),
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
        "subscribe-namespace-lifecycle" => {
            test_subscribe_namespace_lifecycle(client, relay_url).await
        }
        "announce-subscribe" => test_announce_subscribe(client, relay_url).await,
        "data-subgroup-basic" => test_data_subgroup_basic(client, relay_url).await,
        _ => anyhow::bail!("unknown test: {}", name),
    }
}

/// Create and announce a broadcast at `path`.
fn announce(origin: &moq_net::origin::Producer, path: &str) -> anyhow::Result<broadcast::Producer> {
    let broadcast = origin
        .create_broadcast(path)
        .context("failed to create broadcast")?;
    broadcast
        .announce(Default::default())
        .context("failed to announce broadcast")?;
    Ok(broadcast)
}

/// An origin that only asks the relay for announcements under `namespace`.
fn scoped(namespace: &str) -> anyhow::Result<moq_net::origin::Producer> {
    let pattern = Pattern::subtree(namespace).context("invalid namespace pattern")?;
    moq_tokio::origin::spawn()
        .scope("", &Patterns::from(pattern))
        .context("failed to scope subscriber")
}

fn negotiated(session: &moq_tokio::Connection) -> String {
    session
        .version()
        .map_or_else(|| "unknown".into(), |version| version.to_string())
}

/// Connect via WebTransport, complete handshake, close session.
async fn test_setup_only(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let session = client
        .clone()
        .connect(relay_url.clone())
        .established()
        .await
        .context("failed to connect")?;
    let negotiated = negotiated(&session);
    session.abort(Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        ..Default::default()
    })
}

/// Connect, publish broadcast at test namespace, wait for acknowledgment.
async fn test_announce_only(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let origin = moq_tokio::origin::spawn();
    let _broadcast = announce(&origin, TEST_NAMESPACE)?;

    let session = client
        .clone()
        .with_publisher(&origin)
        .connect(relay_url.clone())
        .established()
        .await
        .context("failed to connect")?;
    let negotiated = negotiated(&session);

    tokio::select! {
        result = session.closed() => anyhow::bail!("session closed after announce: {:?}", result),
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
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let origin = moq_tokio::origin::spawn();
    let broadcast = announce(&origin, TEST_NAMESPACE)?;

    let session = client
        .clone()
        .with_publisher(&origin)
        .connect(relay_url.clone())
        .established()
        .await
        .context("failed to connect")?;
    let negotiated = negotiated(&session);

    tokio::select! {
        result = session.closed() => anyhow::bail!("session closed after announce: {:?}", result),
        _ = tokio::time::sleep(Duration::from_millis(500)) => {}
    }

    broadcast.close();

    tokio::select! {
        result = session.closed() => anyhow::bail!("session closed after unpublish: {:?}", result),
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
            if event.prefix.as_str() == namespace {
                return Ok(event.kind.is_active());
            }
        }
    })
    .await
    .context("timeout waiting for namespace event")?
}

/// Observe NAMESPACE followed by NAMESPACE_DONE for one unique namespace.
async fn test_subscribe_namespace_lifecycle(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    // Unique per run, so a namespace a previous run left behind cannot satisfy this one.
    let run_id = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .context("clock before the Unix epoch")?
        .as_nanos();
    let namespace = format!(
        "{TEST_NAMESPACE}/subscribe-namespace-lifecycle/{}-{run_id}",
        std::process::id()
    );

    let sub_origin = scoped(&namespace)?;
    let mut announcements = sub_origin.consume().announced();
    let sub_session = client
        .clone()
        .with_subscriber(sub_origin)
        .connect(relay_url.clone())
        .established()
        .await
        .context("namespace subscriber failed to connect")?;
    let negotiated = negotiated(&sub_session);

    let pub_origin = moq_tokio::origin::spawn();
    let broadcast = announce(&pub_origin, &namespace)?;
    let pub_session = client
        .clone()
        .with_publisher(&pub_origin)
        .connect(relay_url.clone())
        .established()
        .await
        .context("namespace publisher failed to connect")?;

    anyhow::ensure!(
        next_namespace_state(&mut announcements, &namespace).await?,
        "received NAMESPACE_DONE before NAMESPACE"
    );
    broadcast.close();
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
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    // Publisher setup
    let pub_origin = moq_tokio::origin::spawn();
    let broadcast = announce(&pub_origin, TEST_NAMESPACE)?;

    // Create a track so subscriber can find it
    let pub_track = broadcast
        .create_track(TEST_TRACK, None)
        .context("failed to create track")?;

    let pub_session = client
        .clone()
        .with_publisher(&pub_origin)
        .connect(relay_url.clone())
        .established()
        .await
        .context("publisher failed to connect")?;

    // Give the relay time to process the announce
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Subscriber setup
    let sub_origin = scoped(TEST_NAMESPACE)?;
    let sub_consumer = sub_origin.consume();

    let sub_session = client
        .clone()
        .with_subscriber(sub_origin)
        .connect(relay_url.clone())
        .established()
        .await
        .context("subscriber failed to connect")?;
    let negotiated = negotiated(&sub_session);

    // moq-net currently discovers namespaces before it can send a track SUBSCRIBE.
    // Wait for the exact path so unrelated relay announcements cannot produce a false pass.
    let sub_broadcast = tokio::time::timeout(
        Duration::from_millis(1500),
        sub_consumer.routed_broadcast(TEST_NAMESPACE),
    )
    .await
    .context("timeout waiting for the test namespace announcement")?
    .context("failed to resolve the test namespace")?;

    let track = sub_broadcast
        .track(TEST_TRACK)
        .context("failed to request track")?;
    let subscriber = track
        .subscribe(None)
        .await
        .context("track subscription rejected")?;

    drop(subscriber);
    pub_track.finish().context("failed to finish track")?;
    broadcast.close();
    pub_session.abort(Error::Cancel);
    sub_session.abort(Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some("SUBSCRIBE_OK for moq-test/interop/test-track".into()),
        ..Default::default()
    })
}

/// The canonical `data-subgroup-basic` MoQT Test tuple: groups 0-2, objects 0-4 on subgroup 0,
/// a 64-byte object 0 then 32-byte objects, 2 ms apart, with no end-of-group markers,
/// extensions, or delivery timeout.
const SUBGROUP_BASIC_TUPLE: &str = "moq-test-00/0/0/0/2/4/5/64/32/2/1/1/0/-1/-1/0";
const SUBGROUP_BASIC_GROUPS: u64 = 3;
const SUBGROUP_BASIC_OBJECTS: u64 = 5;
const SUBGROUP_BASIC_TRACK: &str = "track";

/// A run identifier with 128 bits of entropy, as lowercase hex.
fn run_id() -> anyhow::Result<String> {
    use std::io::Read;

    let mut bytes = [0u8; 16];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .context("failed to read a random run id")?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// The payload of one canonical object: MoQT Test fills it with `t`.
fn subgroup_basic_payload(object: u64) -> Vec<u8> {
    vec![b't'; if object == 0 { 64 } else { 32 }]
}

/// Publish the routing prefix, serve the canonical tuple beneath it on demand, and verify
/// that a second session subscribing through the relay receives exactly that object set.
///
/// moq-net does not surface subgroup IDs, publisher priority, or PUBLISH_DONE, so the
/// subscriber checks only what the track exposes: every object, and a clean end. A
/// downstream PUBLISH_DONE with an error status aborts the track, which fails the test.
///
/// Two departures from the specified stimulus come from moq-net itself: its SUBSCRIBE
/// joins at the live edge (Largest Object plus a joining FETCH, or Next Object plus a fill
/// from draft 20) instead of omitting the filter, and moq-tokio 0.19 stamps every object
/// with a Timestamp property. Neither changes the object set a relay must deliver.
async fn test_data_subgroup_basic(
    client: &moq_tokio::Client,
    relay_url: &url::Url,
) -> anyhow::Result<Diagnostics> {
    let prefix = format!("moq-test/data-subgroup-basic/{}", run_id()?);
    let path = format!("{prefix}/{SUBGROUP_BASIC_TUPLE}");

    let pub_origin = moq_tokio::origin::spawn();
    let dynamic = pub_origin
        .dynamic(prefix.as_str(), Default::default())
        .context("failed to publish the routing prefix")?;
    let pub_session = tokio::time::timeout(
        Duration::from_secs(5),
        client
            .clone()
            .with_publisher(&pub_origin)
            .connect(relay_url.clone())
            .established(),
    )
    .await
    .context("timeout connecting the publisher")?
    .context("publisher failed to connect")?;

    // Asking only for the routing prefix keeps the namespace subscription off the empty
    // prefix, which drafts before 16 forbid.
    let sub_origin = scoped(&prefix)?;
    let sub_consumer = sub_origin.consume();
    let sub_session = tokio::time::timeout(
        Duration::from_secs(5),
        client
            .clone()
            .with_subscriber(sub_origin)
            .connect(relay_url.clone())
            .established(),
    )
    .await
    .context("timeout connecting the subscriber")?
    .context("subscriber failed to connect")?;
    let negotiated = negotiated(&sub_session);

    // The publisher never returns on success: it keeps the track alive while the relay drains.
    let (established, subscribed) = tokio::sync::oneshot::channel();
    let received = tokio::select! {
        res = serve_subgroup_basic(&dynamic, &path, subscribed) => return Err(res.unwrap_err()),
        res = receive_subgroup_basic(&sub_consumer, &path, established) => res?,
    };

    pub_session.abort(Error::Cancel);
    sub_session.abort(Error::Cancel);

    Ok(Diagnostics {
        negotiated: Some(negotiated),
        outcome: Some(format!(
            "received all {received} objects, then the track ended"
        )),
        ..Default::default()
    })
}

/// Answer the relay's request for the tuple's namespace and publish the canonical objects
/// once both subscriptions are established, then hold the track open until cancelled.
async fn serve_subgroup_basic(
    dynamic: &moq_net::origin::Dynamic,
    path: &str,
    subscribed: tokio::sync::oneshot::Receiver<()>,
) -> anyhow::Result<std::convert::Infallible> {
    let request = tokio::time::timeout(Duration::from_secs(5), dynamic.requested_broadcast())
        .await
        .context("timeout waiting for the relay to request the tuple's namespace")?
        .context("routing prefix closed")?;
    if request.path().as_str() != path {
        let requested = request.path().to_owned();
        request.reject(Error::NotFound);
        anyhow::bail!("relay requested {requested}, expected {path}");
    }

    let broadcast = broadcast::Info::new().produce();
    let track = broadcast
        .create_track(SUBGROUP_BASIC_TRACK, None)
        .context("failed to create track")?;
    request.accept(&broadcast);

    // Objects start once both subscriptions are established, as the normal publication flow
    // orders. The relay answers downstream only after the upstream SUBSCRIBE_OK, so waiting for
    // the subscriber's answer keeps object 0 out of that SUBSCRIBE_OK's Largest Location, which
    // would leave the relay to recover it with a joining FETCH.
    tokio::time::timeout(Duration::from_secs(5), track.used())
        .await
        .context("timeout waiting for the relay to subscribe")?
        .context("track closed before the relay subscribed")?;
    subscribed
        .await
        .context("subscriber gave up before SUBSCRIBE_OK")?;

    for sequence in 0..SUBGROUP_BASIC_GROUPS {
        let mut group = track.append_group().context("failed to create group")?;
        for object in 0..SUBGROUP_BASIC_OBJECTS {
            if sequence > 0 || object > 0 {
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
            group
                .write_frame(Timestamp::now(), subgroup_basic_payload(object))
                .context("failed to write object")?;
        }
        group.finish().context("failed to finish group")?;
    }
    track.finish().context("failed to finish track")?;

    std::future::pending().await
}

/// Subscribe to the canonical track through the relay and verify every object it delivers,
/// returning how many arrived once the track ends.
async fn receive_subgroup_basic(
    consumer: &moq_net::origin::Consumer,
    path: &str,
    established: tokio::sync::oneshot::Sender<()>,
) -> anyhow::Result<usize> {
    let broadcast = tokio::time::timeout(Duration::from_secs(5), consumer.routed_broadcast(path))
        .await
        .context("timeout waiting for the routing prefix")?
        .context("failed to resolve the tuple's namespace")?;
    // Verified against the expected set, so keep every group however late it lands.
    let subscription = track::Subscription::default().with_max_age(Duration::from_secs(10));
    let mut subscriber = tokio::time::timeout(
        Duration::from_secs(5),
        broadcast
            .track(SUBGROUP_BASIC_TRACK)
            .context("failed to request track")?
            .subscribe(subscription),
    )
    .await
    .context("timeout waiting for SUBSCRIBE_OK")?
    .context("subscription rejected")?;
    let _ = established.send(());

    let mut seen = std::collections::BTreeSet::new();
    let mut failures = Vec::new();
    let delivered = tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(mut group) = subscriber.recv_group().await.context("track aborted")? {
            let sequence = group.sequence;
            let mut object = 0;
            while let Some(frame) = group
                .read_frame()
                .await
                .with_context(|| format!("group {sequence} aborted"))?
            {
                if sequence >= SUBGROUP_BASIC_GROUPS || object >= SUBGROUP_BASIC_OBJECTS {
                    failures.push(format!("unexpected object ({sequence}, {object})"));
                } else if !seen.insert((sequence, object)) {
                    failures.push(format!("duplicate object ({sequence}, {object})"));
                } else if frame.payload.as_ref() != subgroup_basic_payload(object).as_slice() {
                    failures.push(format!(
                        "object ({sequence}, {object}) carried {} unexpected bytes",
                        frame.payload.len()
                    ));
                }
                object += 1;
            }
        }
        anyhow::Ok(())
    })
    .await;

    let missing: Vec<String> = (0..SUBGROUP_BASIC_GROUPS)
        .flat_map(|group| (0..SUBGROUP_BASIC_OBJECTS).map(move |object| (group, object)))
        .filter(|location| !seen.contains(location))
        .map(|(group, object)| format!("({group}, {object})"))
        .collect();
    if !missing.is_empty() {
        failures.push(format!("missing objects {}", missing.join(", ")));
    }
    match delivered {
        Err(_) => failures.push("timeout waiting for the track to end".into()),
        Ok(Err(err)) => failures.push(format!("{err:#}")),
        Ok(Ok(())) => {}
    }
    anyhow::ensure!(failures.is_empty(), "{}", failures.join("; "));
    Ok(seen.len())
}
