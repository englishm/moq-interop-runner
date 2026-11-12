//! The checker's subscriber: one session that reads the catalog to find the TS track,
//! subscribes to it, and records every object with its Group and Object IDs in arrival order.

use std::time::{Duration, Instant};

use anyhow::Context;
use bytes::Bytes;
use moq_net::Error;
use moq_tokio::moq_net;
use serde_json::Value;

use crate::fixture::CATALOG;
use crate::Session;

/// A tolerant max age, as the CMSF client keeps: a late object of group g must not be
/// abandoned because group g + 1 started on another stream.
const MEDIA_MAX_AGE: Duration = Duration::from_secs(10);

/// A subscriber session: the scoped origin, the routed broadcast and the connection.
pub struct Subscriber {
    /// Keeps the scoped origin alive.
    _root: moq_net::origin::Producer,
    broadcast: moq_net::broadcast::Consumer,
    pub connection: moq_tokio::Connection,
    pub session: Session,
    /// The catalog subscription, held for the rest of the test.
    held: Option<moq_net::track::Subscriber>,
}

impl Subscriber {
    /// Dial the relay as a subscriber of `namespace` and wait until the relay routes the
    /// publisher's announcement to us; SETUP and the routing each have `within`.
    pub async fn connect(
        client: &moq_tokio::Client,
        relay_url: &url::Url,
        namespace: &str,
        within: Duration,
    ) -> anyhow::Result<Self> {
        let root = moq_tokio::origin::spawn();
        let origin = scoped(&root, namespace)?;
        let consumer = origin.consume();
        let connection = tokio::time::timeout(
            within,
            client
                .clone()
                .with_subscriber(origin)
                .connect(relay_url.clone())
                .established(),
        )
        .await
        .context("subscriber SETUP timed out")?
        .context("subscriber failed to connect")?;
        let session = Session::from_connection(&connection, relay_url);

        let broadcast = tokio::time::timeout(within, consumer.routed_broadcast(namespace))
            .await
            .with_context(|| {
                format!(
                    "the relay did not route the namespace to the subscriber within {} ms",
                    within.as_millis()
                )
            })?
            .context("broadcast never became routable")?;

        Ok(Self {
            _root: root,
            broadcast,
            connection,
            session,
            held: None,
        })
    }

    /// Subscribe to the catalog and read Object 0 of its first group, holding the
    /// subscription for the rest of the test.
    pub async fn read_catalog(&mut self, deadline: Duration) -> anyhow::Result<Catalog> {
        let (catalog, subscriber) = read_catalog(&self.broadcast, deadline).await?;
        self.held = Some(subscriber);
        Ok(catalog)
    }

    /// Subscribe to the TS track with the common subscription stimulus, answered `within`.
    pub async fn subscribe(
        &self,
        name: &str,
        within: Duration,
    ) -> anyhow::Result<moq_net::track::Subscriber> {
        subscribe(&self.broadcast, name, within).await
    }

    /// Close the session, letting CONNECTION_CLOSE go out.
    pub async fn close(self) {
        drop(self.held);
        self.connection.abort(Error::Cancel);
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// The catalog object as received.
pub struct Catalog {
    /// The name its `m2ts` section gives the TS track.
    pub track: String,
    pub payload: Bytes,
    /// From the catalog SUBSCRIBE to the object's arrival.
    pub elapsed: Duration,
}

/// Subscribe to the catalog and read Object 0 of its first group, the subscription's answer,
/// the group and the object all within `deadline`.
async fn read_catalog(
    broadcast: &moq_net::broadcast::Consumer,
    deadline: Duration,
) -> anyhow::Result<(Catalog, moq_net::track::Subscriber)> {
    let started = Instant::now();
    let by = tokio::time::Instant::now() + deadline;
    let track = broadcast
        .track(CATALOG)
        .context("failed to request the catalog track")?;
    let mut subscriber = match tokio::time::timeout_at(by, track.subscribe(None)).await {
        Ok(res) => res.context("catalog subscription rejected")?,
        Err(_) => anyhow::bail!(
            "the catalog SUBSCRIBE was not answered within {} ms",
            deadline.as_millis()
        ),
    };
    let mut group = match tokio::time::timeout_at(by, subscriber.recv_group()).await {
        Ok(Ok(Some(group))) => group,
        Ok(Ok(None)) => anyhow::bail!("the catalog track ended before delivering a group"),
        Ok(Err(e)) if is_request_error(&e) => anyhow::bail!(
            "the relay answered the catalog SUBSCRIBE with REQUEST_ERROR ({})",
            e
        ),
        Ok(Err(e)) => anyhow::bail!("the catalog subscription failed locally ({})", e),
        Err(_) => anyhow::bail!(
            "no catalog object arrived within {} ms of the SUBSCRIBE (and no REQUEST_ERROR)",
            deadline.as_millis()
        ),
    };
    let frame = match tokio::time::timeout_at(by, group.read_frame()).await {
        Ok(Ok(Some(frame))) => frame,
        Ok(Ok(None)) => anyhow::bail!("catalog group {} arrived empty", group.sequence),
        Ok(Err(e)) => anyhow::bail!("reading the catalog object failed ({})", e),
        Err(_) => anyhow::bail!(
            "catalog group {} opened but its object did not arrive in time",
            group.sequence
        ),
    };
    let catalog: Value = serde_json::from_slice(&frame.payload)
        .context("the received catalog does not parse as JSON")?;
    let track = catalog
        .pointer("/m2ts/track")
        .and_then(Value::as_str)
        .context("the received catalog has no m2ts section naming the TS track")?
        .to_string();
    let catalog = Catalog {
        track,
        payload: frame.payload,
        elapsed: started.elapsed(),
    };
    Ok((catalog, subscriber))
}

async fn subscribe(
    broadcast: &moq_net::broadcast::Consumer,
    name: &str,
    within: Duration,
) -> anyhow::Result<moq_net::track::Subscriber> {
    let track = broadcast
        .track(name)
        .with_context(|| format!("failed to request track {}", name))?;
    let subscription = moq_net::track::Subscription::default().with_max_age(MEDIA_MAX_AGE);
    tokio::time::timeout(within, track.subscribe(subscription))
        .await
        .with_context(|| {
            format!(
                "the SUBSCRIBE for {} was not answered within {} ms",
                name,
                within.as_millis()
            )
        })?
        .with_context(|| format!("subscription to {} rejected", name))
}

/// One received object.
#[derive(Debug, Clone)]
pub struct Received {
    pub group: u64,
    pub object: u64,
    pub payload: Bytes,
}

/// What a collection run observed.
#[derive(Debug, Default)]
pub struct Collected {
    /// Every object, in arrival order.
    pub objects: Vec<Received>,
    /// How the track ended: `None` if it did not end before the deadline.
    pub end: Option<Result<(), String>>,
}

enum Event {
    Object(Received),
    TrackEnd(Result<(), String>),
}

/// Read every object of `subscriber` until the track ends and its groups have drained, or
/// `deadline` passes. Groups are read concurrently, so objects of adjacent groups may
/// interleave in the log as they did on the wire.
pub async fn collect(mut subscriber: moq_net::track::Subscriber, deadline: Instant) -> Collected {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Event>();
    let reader = tokio::spawn(async move {
        let mut groups = Vec::new();
        let end = loop {
            match subscriber.recv_group().await {
                Ok(Some(mut group)) => {
                    let tx = tx.clone();
                    groups.push(tokio::spawn(async move {
                        let sequence = group.sequence;
                        loop {
                            let index = group.index();
                            match group.read_frame().await {
                                Ok(Some(frame)) => {
                                    let _ = tx.send(Event::Object(Received {
                                        group: sequence,
                                        object: index,
                                        payload: frame.payload,
                                    }));
                                }
                                Ok(None) => break,
                                Err(e) => {
                                    tracing::debug!(group = sequence, error = %e, "group read ended");
                                    break;
                                }
                            }
                        }
                    }));
                }
                Ok(None) => break Ok(()),
                Err(e) if is_request_error(&e) => {
                    break Err(format!(
                        "the relay ended the subscription with REQUEST_ERROR ({})",
                        e
                    ))
                }
                Err(e) => break Err(format!("the subscription ended ({})", e)),
            }
        };
        for group in groups {
            let _ = group.await;
        }
        let _ = tx.send(Event::TrackEnd(end));
    });

    let mut collected = Collected::default();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match tokio::time::timeout(remaining, rx.recv()).await {
            Ok(Some(Event::Object(received))) => collected.objects.push(received),
            Ok(Some(Event::TrackEnd(end))) => {
                collected.end = Some(end);
                break;
            }
            Ok(None) | Err(_) => break,
        }
    }
    reader.abort();
    collected
}

/// Whether a subscription's abort error is what moq-net makes of a REQUEST_ERROR code, as
/// opposed to a local failure (an answer that did not decode, a dead session, …).
pub fn is_request_error(err: &Error) -> bool {
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

/// A subscriber origin scoped to `namespace`, so moq-net's namespace discovery asks the
/// relay for that prefix (SUBSCRIBE_NAMESPACE `namespace`) rather than the empty prefix,
/// which draft-14 forbids and which several relays reject. Keep `root` alive for as long
/// as the scoped origin.
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

#[cfg(test)]
mod test {
    use super::*;
    use moq_net::Timestamp;

    const PUBLISHED: &[u8] = br#"{"m2ts":{"track":"0.m2ts"}}"#;

    /// A broadcast whose catalog track is accepted `answer` after it is requested, with its
    /// object written `object` after that.
    fn broadcast(answer: Duration, object: Duration) -> moq_net::broadcast::Consumer {
        let producer = moq_net::broadcast::Info::new().produce();
        let mut dynamic = producer.dynamic();
        let consumer = dynamic.consume();
        tokio::spawn(async move {
            let _producer = producer;
            let request = dynamic.requested_track().await.unwrap();
            tokio::time::sleep(answer).await;
            let mut track = request.accept(None);
            tokio::time::sleep(object).await;
            track.write_frame(Timestamp::ZERO, PUBLISHED).unwrap();
            tokio::time::sleep(Duration::from_secs(5)).await;
        });
        consumer
    }

    #[tokio::test]
    async fn reads_the_track_name_and_keeps_the_object() {
        let consumer = broadcast(Duration::ZERO, Duration::ZERO);
        let (catalog, _held) = read_catalog(&consumer, Duration::from_millis(500))
            .await
            .unwrap();
        assert_eq!(catalog.track, "0.m2ts");
        assert_eq!(&catalog.payload[..], PUBLISHED);
    }

    #[tokio::test]
    async fn an_unanswered_ts_subscribe_fails_at_its_deadline() {
        // The handler holds the request and never answers it.
        let producer = moq_net::broadcast::Info::new().produce();
        let dynamic = producer.dynamic();
        let consumer = dynamic.consume();
        let err = tokio::time::timeout(
            Duration::from_secs(2),
            subscribe(&consumer, "0.m2ts", Duration::from_millis(300)),
        )
        .await
        .expect("the SUBSCRIBE must give up at its own deadline")
        .err()
        .expect("an unanswered SUBSCRIBE must fail");
        assert!(
            err.to_string().contains("not answered within 300 ms"),
            "{err}"
        );
        drop((dynamic, producer));
    }

    #[tokio::test]
    async fn one_deadline_covers_the_subscription_and_the_object() {
        let consumer = broadcast(Duration::from_millis(200), Duration::from_millis(200));
        let err = read_catalog(&consumer, Duration::from_millis(300))
            .await
            .err()
            .expect("an object 400 ms after the SUBSCRIBE must miss a 300 ms deadline");
        assert!(err.to_string().contains("within 300 ms"), "{err}");
    }
}
