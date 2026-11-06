//! The reference publisher: one broadcast at the run's routing prefix with the tracks
//! `catalog`, `video` and `audio`, mapped as docs/tests/media/cmsf.md fixes it: a group is
//! the whole second a fragment starts in, an object is one fragment, all on subgroup 0,
//! paced to the fragment's decode time.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Context;
use moq_net::origin::Route;
use moq_net::{Error, Timescale, Timestamp};
use moq_tokio::moq_net;

use crate::fixture::Fixture;
use crate::Session;

/// How long a non-latest group stays in the publisher's cache, in media time. Longer than
/// the fixture, so a relay that fetches back over the live edge finds every group; the
/// latest group is retained regardless.
const MEDIA_MAX_AGE: Duration = Duration::from_secs(60);

pub struct Publisher {
    /// Keeps the origin, and with it every route, alive.
    _origin: moq_net::origin::Producer,
    broadcast: moq_net::broadcast::Producer,
    catalog: moq_net::track::Producer,
    media: BTreeMap<String, moq_net::track::Producer>,
    pub connection: moq_tokio::Connection,
    pub session: Session,
    fixture: Arc<Fixture>,
}

impl Publisher {
    /// Create the broadcast and its tracks, announce the namespace, dial the relay and
    /// wait for the session. Returns once SETUP completed; the announce is in flight.
    pub async fn connect(
        client: &moq_tokio::Client,
        relay_url: &url::Url,
        fixture: Arc<Fixture>,
        namespace: &str,
    ) -> anyhow::Result<Self> {
        let origin = moq_tokio::origin::spawn();
        let broadcast = origin
            .create_broadcast(namespace)
            .context("failed to create broadcast")?;

        let catalog = broadcast
            .create_track(
                "catalog",
                Some(moq_net::track::Info::default().with_max_age(MEDIA_MAX_AGE)),
            )
            .context("failed to create the catalog track")?;

        let mut media = BTreeMap::new();
        for (name, track) in &fixture.tracks {
            let timescale = Timescale::new(track.manifest.timescale)
                .map_err(|e| anyhow::anyhow!("{} timescale: {:?}", name, e))?;
            let info = moq_net::track::Info::default()
                .with_timescale(timescale)
                .with_max_age(MEDIA_MAX_AGE);
            let producer = broadcast
                .create_track(name.as_str(), Some(info))
                .with_context(|| format!("failed to create track {}", name))?;
            media.insert(name.clone(), producer);
        }

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
            media,
            connection,
            session,
            fixture,
        })
    }

    /// Fail if the session has ended, otherwise wait `settle` for the announce to land.
    pub async fn settle(&self, settle: Duration) -> anyhow::Result<()> {
        tokio::select! {
            res = self.connection.closed() => anyhow::bail!("publisher session closed after the announce: {:?}", res),
            _ = tokio::time::sleep(settle) => Ok(()),
        }
    }

    /// Publish the catalog: Group 0, Object 0, the bytes of `catalog.json`.
    pub fn publish_catalog(&mut self) -> anyhow::Result<()> {
        self.catalog
            .write_frame(Timestamp::ZERO, self.fixture.catalog.clone())
            .context("failed to publish the catalog")
    }

    /// Publish groups `first..=last` of every media track, each object at
    /// `start + (its decode time - the decode time of group first)`. Groups are created
    /// with their manifest sequence number and finished after their last object. Fails
    /// early if the session ends.
    pub async fn publish_groups(
        &self,
        first: u64,
        last: u64,
        start: Instant,
    ) -> anyhow::Result<()> {
        // Every object of the range, across tracks, in send order.
        let mut schedule: Vec<(f64, &str, usize)> = Vec::new();
        for (name, track) in &self.fixture.tracks {
            for (i, object) in track.objects.iter().enumerate() {
                if object.group >= first && object.group <= last {
                    schedule.push((track.seconds(object.tfdt), name.as_str(), i));
                }
            }
        }
        schedule.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap().then_with(|| a.1.cmp(b.1)));
        let base = first as f64 * self.fixture.manifest.group_ms as f64 / 1000.0;

        let mut open: BTreeMap<(&str, u64), moq_net::group::Producer> = BTreeMap::new();
        for (seconds, name, index) in schedule {
            let at = start + Duration::from_secs_f64((seconds - base).max(0.0));
            tokio::select! {
                res = self.connection.closed() => anyhow::bail!("publisher session closed while publishing: {:?}", res),
                _ = tokio::time::sleep_until(tokio::time::Instant::from_std(at)) => {}
            }

            let track = &self.fixture.tracks[name];
            let object = &track.objects[index];
            let producer = &self.media[name];
            let key = (name, object.group);
            if let std::collections::btree_map::Entry::Vacant(slot) = open.entry(key) {
                let group = producer
                    .create_group(moq_net::group::Info {
                        sequence: object.group,
                    })
                    .with_context(|| format!("{} group {}", name, object.group))?;
                slot.insert(group);
            }
            let timescale = Timescale::new(track.manifest.timescale)
                .map_err(|e| anyhow::anyhow!("{} timescale: {:?}", name, e))?;
            let timestamp = Timestamp::new(object.tfdt, timescale)
                .map_err(|e| anyhow::anyhow!("{} tfdt {}: {:?}", name, object.tfdt, e))?;
            let group = open.get_mut(&key).unwrap();
            group
                .write_frame(timestamp, object.payload.clone())
                .with_context(|| {
                    format!("{} group {} object {}", name, object.group, object.object)
                })?;
            tracing::debug!(
                track = name,
                group = object.group,
                object = object.object,
                bytes = object.payload.len(),
                "published"
            );

            if Some(object.object) == track.last_object(object.group) {
                let group = open.remove(&key).unwrap();
                group
                    .finish()
                    .with_context(|| format!("{} group {} finish", name, object.group))?;
            }
        }
        Ok(())
    }

    /// End every media track after its last group (PUBLISH_DONE on the wire).
    pub fn finish_media(&self) -> anyhow::Result<()> {
        for (name, producer) in &self.media {
            producer
                .finish()
                .with_context(|| format!("{} finish", name))?;
        }
        Ok(())
    }

    /// Close the broadcast and the session, letting CONNECTION_CLOSE go out.
    pub async fn close(self) {
        self.broadcast.close();
        drop(self.media);
        drop(self.catalog);
        self.connection.abort(Error::Cancel);
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}
