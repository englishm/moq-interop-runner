# Shaka Player Browser Client

Runs [Shaka Player](https://github.com/shaka-project/shaka-player) as a MoQT
subscriber in a real browser for the
[`publish-subscribe-media`](../../docs/tests/TEST-CASES.md#publish-subscribe-media)
test. The [moqxr](https://github.com/openmoq/moqxr) `openmoq-publisher` in the
same container publishes the media.

## Overview

One image per browser, all built from the same Dockerfile:

| Browser  | Image                                   | Browser build                        |
|----------|-----------------------------------------|--------------------------------------|
| chromium | `shaka-player-chromium-interop-client`  | Playwright's Chromium headless shell |
| chrome   | `shaka-player-chrome-interop-client`    | Google Chrome stable                 |
| firefox  | `shaka-player-firefox-interop-client`   | Playwright's Firefox                 |

- **Player**: Shaka Player 5.3.0, experimental build (MSF manifest parser)
- **Publisher**: moqxr `openmoq-publisher` v0.4.10, built from source. It needs v0.4.9 or later, the first release with [#58](https://github.com/openmoq/moqxr/pull/58) and [#59](https://github.com/openmoq/moqxr/pull/59)
- **Draft versions**: draft-18, draft-22 (`MOQ_CLIENT_VERSION`, default draft-22)
- **Transport**: WebTransport (`https://`) for the player. `moqt://` relays report SKIP.
- **Test cases**: `publish-subscribe-media` only. Any other test case reports SKIP and exits 127.
- **Platforms**: linux/amd64 and linux/arm64. Chrome on arm64 comes from Google's apt repository, because Playwright can't install it there.

All three browsers decode H.264, which the test fixture uses.

Safari runs natively on macOS through a separate host mode; see
[Safari on macOS](#safari-on-macos). Playwright's Linux WebKit can't run this
test: WebKit implements WebTransport only on Apple platforms.

## How a Run Works

1. The client serves the player page, Shaka's files and the relay certificate hash from a localhost HTTP server. Browsers treat localhost as a secure context, which WebTransport requires.
2. It launches the browser and loads the page.
3. It starts the publisher in a fresh `moq-test/interop/<run-id>` namespace with a media catalog, paced playback and `--loop`, then waits for the relay to accept the namespace.
4. Shaka subscribes to the catalog and video track and plays.
5. The test passes once at least 2 video frames are decoded within 8 seconds.

The client prints TAP version 14 with YAML diagnostics (see
[TAP-YAML-METADATA.md](../../docs/TAP-YAML-METADATA.md)). These include the
negotiated draft and each session's transport. When a run fails, they also
include the browser console and the end of the publisher's output.

### Self-signed relay certificates

With `TLS_DISABLE_VERIFY=1` and a certificate at `/certs/cert.pem`, the client
serves that certificate's SHA-256 hash to the page. Shaka then pins it with
WebTransport's `serverCertificateHashes`, so the browser accepts the
self-signed relay. The certificates from `generate-certs.sh` meet the
browsers' pinning rules (ECDSA P-256, valid for under 14 days).

Remote relays with CA-signed certificates need nothing extra. A remote relay
with a self-signed certificate can't be pinned unless its certificate is
mounted at `/certs/cert.pem`.

### Publisher transport

moqxr applies one transport to all of its endpoints. When the WebTransport
publisher fails before its namespace is accepted, for example because the
relay doesn't advertise the `reset_stream_at` transport parameter, the client
reruns it over raw QUIC (`moqt://`) on the same host and port. The player keeps
using `https://`. The transport the publisher ended up using is reported under
`sessions.publisher`.

## Building from Source

```bash
# Chromium image (default)
./builds/shaka-player/build.sh

# One browser, or all three
./builds/shaka-player/build.sh --browser firefox
./builds/shaka-player/build.sh --all-browsers

# Another Shaka Player version from npm
./builds/shaka-player/build.sh --ref 5.3.0

# Another moqxr tag, branch or commit, or a local moqxr checkout (must be a git checkout)
./builds/shaka-player/build.sh --moqxr-ref main
./builds/shaka-player/build.sh --moqxr-local ~/path/to/moqxr

# Cross-build for another architecture
./builds/shaka-player/build.sh --platform linux/amd64
```

The Dockerfile has three stages:

- **moqxr source:** a shallow fetch of the moqxr ref, replaced by `--moqxr-local`.
- **Builder:** compiles only the `openmoq-publisher` target, with picoquic and picotls pinned to known-good commits.
- **Runtime:** Node 22, Playwright and the selected browser, plus the publisher and its fixture. It runs as uid 1000.

## Quick Test

Through the runner, with a relay image:

```bash
TESTCASE=publish-subscribe-media MOQ_CLIENT_VERSION=draft-18 \
  make test RELAY_IMAGE=<relay-image> \
  CLIENT_IMAGE=shaka-player-chromium-interop-client:latest CLIENT_MEMORY_LIMIT=512M
```

Directly with `docker run`, against a relay on a user-defined network:

```bash
docker run --rm --network <net> --memory 512m -v "$PWD/certs:/certs:ro" \
  -e RELAY_URL=https://relay:4443/ -e TESTCASE=publish-subscribe-media \
  -e TLS_DISABLE_VERIFY=1 -e MOQ_CLIENT_VERSION=draft-18 \
  shaka-player-chromium-interop-client:latest
```

`--list` prints the supported test cases.

## Memory

The runner limits clients to 256M by default, and Firefox and Chrome need
more. Peak memory measured over a full 8-second playback window:

| Browser  | Peak       |
|----------|------------|
| Chromium | ~170 MiB   |
| Chrome   | ~260 MiB   |
| Firefox  | ~385 MiB   |

At 256M, Firefox crashes ("browser has been closed"). Use 512M for every
browser: set `memory_limit: "512M"` under `roles.client.docker` in
`implementations.json`, or pass `CLIENT_MEMORY_LIMIT=512M` to `make test` or
`make test-external`.

## Environment Variables

### Standard client variables

| Variable             | Description                                         | Default             |
|----------------------|-----------------------------------------------------|---------------------|
| `RELAY_URL`          | Relay URL for the player (required)                 |                     |
| `TESTCASE`           | Test case to run                                    | all (`publish-subscribe-media`) |
| `TLS_DISABLE_VERIFY` | Pin `CERT_PATH` and run the publisher `--insecure`  | off                 |
| `VERBOSE`            | Load Shaka's debug build and print full diagnostics | off                 |
| `MOQ_CLIENT_VERSION` | `draft-18` or `draft-22`                            | `draft-22`          |

### Client-specific variables

| Variable                      | Description                                                                 | Default            |
|-------------------------------|-----------------------------------------------------------------------------|--------------------|
| `BROWSER`                     | `chromium`, `chrome`, `firefox` or `safari`; set by each image               | the image's browser |
| `PUBLISHER_RELAY_URL`         | Relay URL for the publisher, when it reaches the relay by another name       | `RELAY_URL`        |
| `PUBLISHER_RAW_QUIC_FALLBACK` | `0` disables the raw-QUIC retry described above                              | on                 |
| `MOQXR_ARGS`                  | Extra `openmoq-publisher` flags, space-separated                             |                    |
| `MOQXR_PACKAGING`             | `cmaf` or `locmaf` packaging for the publisher                               | moqxr's default (`cmaf`) |
| `MOQ_MEDIA_NAMESPACE`         | Fixed namespace instead of a fresh `moq-test/interop/<run-id>`              |                    |
| `CERT_PATH`                   | Relay certificate to pin                                                    | `/certs/cert.pem`  |
| `SHAKA_FULL_WINDOW`           | `1` plays the whole 8-second window and reports media time against wall time (diagnostic; the pass rule is unchanged) | off |
| `MOQXR_BIN`, `MOQXR_FIXTURE`  | Publisher binary and input file                                             | `/app/openmoq-publisher`, `/app/fixture.mp4` |
| `SHAKA_APP_DIR`, `SHAKA_DIST` | Location of the player page and of Shaka's `dist/` files                    | `/app`, its `node_modules/shaka-player/dist` |

## Safari on macOS

`make test-safari` runs the client on a macOS host and drives the real Safari
over WebDriver (`safaridriver`). The publisher runs in Docker, taken from a
built Shaka image. Safari has no headless mode, so a window opens during the
run.

One-time setup:

1. `sudo safaridriver --enable`
2. In Safari, turn on **Develop › Allow Remote Automation**.
3. Build an image to take the publisher from: `./builds/shaka-player/build.sh`.

Safari 26 or later is required. Earlier versions don't have WebTransport.

```bash
# Relay on this machine (default https://localhost:4443, cert pinned from ./certs)
make test-safari MOQ_CLIENT_VERSION=draft-18

# Relay in Docker: Safari uses the published port, the publisher joins the relay's network
make test-safari RELAY_URL=https://localhost:4434/ \
  PUBLISHER_RELAY_URL=https://relay:4434/ PUBLISHER_NETWORK=<relay-network> \
  MOQ_CLIENT_VERSION=draft-18

# Remote relay with a CA-signed certificate
make test-safari RELAY_URL=https://relay.example.com:4443/moq MOQ_CLIENT_VERSION=draft-18
```

Safari-mode variables, on top of the client variables above:

| Variable              | Description                                               | Default |
|-----------------------|-----------------------------------------------------------|---------|
| `PUBLISHER_NETWORK`   | Docker network for the publisher container                | `host` for a localhost relay |
| `PUBLISHER_IMAGE`     | Image to take `openmoq-publisher` from                    | `shaka-player-chromium-interop-client:latest` |
| `CERT_PATH`           | Certificate to pin                                        | `./certs/cert.pem` |
| `TLS_DISABLE_VERIFY`  | Pin `CERT_PATH`                                           | on for localhost relays, off otherwise |

To reach a relay running in Docker, Safari needs the relay's UDP port
forwarded to macOS. Docker Desktop forwards UDP. Colima's default ssh port
forwarder handles TCP only, so set `portForwarder: grpc` in
`~/.colima/default/colima.yaml`, or start with
`colima start --port-forwarder grpc`.

## Known Limitations

- **The relay must accept `PUBLISH`.** moqxr publishes its tracks with `PUBLISH`. Relays that reject it, such as moq-dev-rs and moqlivemock's mlmrel, fail before playback starts.
- **Relays that don't answer FETCH,** such as quic-zig, delay startup while Shaka waits for its Joining FETCH to time out. Playback then starts from the subscription alone.
- **Linux WebKit isn't supported.** WebKit's WebTransport backend exists only for Apple platforms, so use the Safari mode instead.
