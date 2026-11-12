//! The reference publisher: one broadcast at the run's namespace with the tracks
//! `catalog.json` and `0.m2ts`, the fixture's objects written as a live importer behind a
//! PCR-paced source would have them, each when its last packet has arrived.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Context;
use moq_net::origin::Route;
use moq_net::{Error, Timestamp};
use moq_tokio::moq_net;

use crate::fixture::{Fixture, CATALOG, TRACK};
use crate::Session;

/// How long a superseded group stays fresh: moq-dev's importer default.
const MAX_AGE: Duration = Duration::from_secs(30);

pub struct Publisher {
    /// Keeps the origin, and with it every route, alive.
    _origin: moq_net::origin::Producer,
    broadcast: moq_net::broadcast::Producer,
    catalog: moq_net::track::Producer,
    track: moq_net::track::Producer,
    pub connection: moq_tokio::Connection,
    pub session: Session,
    /// The highest Group ID opened, plus one; zero before the first.
    pub opened: Arc<AtomicU64>,
}

impl Publisher {
    /// Create the broadcast and its tracks, announce the namespace, dial the relay and
    /// wait for the session. Returns once SETUP completed; the announce is in flight.
    pub async fn connect(
        client: &moq_tokio::Client,
        relay_url: &url::Url,
        namespace: &str,
    ) -> anyhow::Result<Self> {
        let origin = moq_tokio::origin::spawn();
        let broadcast = origin
            .create_broadcast(namespace)
            .context("failed to create broadcast")?;
        let info = || Some(moq_net::track::Info::default().with_max_age(MAX_AGE));
        let catalog = broadcast
            .create_track(CATALOG, info())
            .context("failed to create the catalog track")?;
        let track = broadcast
            .create_track(TRACK, info())
            .context("failed to create the TS track")?;
        broadcast
            .announce(Route::default())
            .context("failed to announce")?;

        let connection = client
            .clone()
            .with_publisher(origin.consume())
            .connect(relay_url.clone())
            .established()
            .await
            .context("publisher failed to connect")?;
        let session = Session::from_connection(&connection, relay_url);
        Ok(Self {
            _origin: origin,
            broadcast,
            catalog,
            track,
            connection,
            session,
            opened: Arc::new(AtomicU64::new(0)),
        })
    }

    /// Fail if the session has ended, otherwise wait `settle` for the announce to land.
    pub async fn settle(&self, settle: Duration) -> anyhow::Result<()> {
        tokio::select! {
            res = self.connection.closed() => anyhow::bail!("publisher session closed after the announce: {:?}", res),
            _ = tokio::time::sleep(settle) => Ok(()),
        }
    }

    /// Publish the catalog: Group 0, Object 0, naming the TS track in its `m2ts` section.
    pub fn publish_catalog(&mut self, fixture: &Fixture) -> anyhow::Result<()> {
        self.catalog
            .write_frame(Timestamp::ZERO, fixture.catalog.clone())
            .context("failed to publish the catalog")
    }

    /// Publish every object at `t0` plus its arrival, then end the track. Fails early if the
    /// session ends.
    pub async fn publish(&self, fixture: &Fixture, t0: Instant) -> anyhow::Result<()> {
        let mut group: Option<moq_net::group::Producer> = None;
        for (i, object) in fixture.objects.iter().enumerate() {
            let at = t0 + Duration::from_secs_f64(object.ready_secs);
            tokio::select! {
                res = self.connection.closed() => anyhow::bail!("publisher session closed while publishing: {:?}", res),
                _ = tokio::time::sleep_until(tokio::time::Instant::from_std(at)) => {}
            }
            if object.object == 0 {
                if let Some(done) = group.take() {
                    done.finish().context("group finish")?;
                }
                group = Some(
                    self.track
                        .create_group(moq_net::group::Info {
                            sequence: object.group,
                        })
                        .with_context(|| format!("group {}", object.group))?,
                );
                self.opened.store(object.group + 1, Ordering::SeqCst);
            }
            let timestamp = Timestamp::from_micros(object.timestamp_us)
                .map_err(|e| anyhow::anyhow!("timestamp of object {}: {:?}", i, e))?;
            group
                .as_mut()
                .expect("the first object opens a group")
                .write_frame(timestamp, object.payload.clone())
                .with_context(|| format!("group {} object {}", object.group, object.object))?;
            tracing::debug!(
                group = object.group,
                object = object.object,
                bytes = object.payload.len(),
                "published"
            );
        }
        if let Some(done) = group.take() {
            done.finish().context("group finish")?;
        }
        self.track.finish().context("track finish")?;
        Ok(())
    }

    /// Close the broadcast and the session, letting CONNECTION_CLOSE go out.
    pub async fn close(self) {
        self.broadcast.close();
        drop(self.track);
        drop(self.catalog);
        self.connection.abort(Error::Cancel);
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}
