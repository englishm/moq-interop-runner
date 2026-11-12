# xquic MoQ Build

Build Docker images for xquic's MoQT implementation from source.

## Overview

| Role   | Image Name         | GHCR                                        |
|--------|--------------------|---------------------------------------------|
| client | xquic-moq-client   | `ghcr.io/sy0307/xquic-moq-client:latest`   |
| relay  | xquic-moq-relay    | `ghcr.io/sy0307/xquic-moq-relay:latest`    |

- **Language**: C
- **QUIC stack**: xquic (with BabaSSL/Tongsuo)
- **Draft version**: draft-14 (RFC 9760)
- **Transport**: Raw QUIC only (`moqt://`)

## Building from Source

```bash
# Build both client and relay (clones from GitHub)
./builds/xquic/build.sh

# Use a local xquic checkout
./builds/xquic/build.sh --local ~/path/to/xquic

# Build a specific branch
./builds/xquic/build.sh --ref moq_draft_14_dev_relay

# Build only the client
./builds/xquic/build.sh --local ~/path/to/xquic --target client
```

The Dockerfiles use multi-stage builds: the builder stage compiles xquic
and BabaSSL from source, then copies the binaries into a minimal Ubuntu
22.04 runtime image.

## Quick Test

```bash
# Test client against a remote relay
docker run --rm \
  -e RELAY_URL=moqt://draft-14.cloudflare.mediaoverquic.com:443 \
  -e TESTCASE=setup-only \
  xquic-moq-client:latest
```

## Supported Test Cases

| Test Case                  | Description                                          |
|----------------------------|------------------------------------------------------|
| `setup-only`               | CLIENT_SETUP / SERVER_SETUP handshake                |
| `announce-only`            | PUBLISH_NAMESPACE and wait for OK                    |
| `subscribe-error`          | Subscribe to a non-existent namespace                |
| `publish-namespace-done`   | PUBLISH_NAMESPACE followed by PUBLISH_NAMESPACE_DONE |
| `announce-subscribe`       | Publisher announces, subscriber subscribes           |
| `subscribe-before-announce`| Subscriber subscribes before publisher announces     |

## Environment Variables

### Client

| Variable             | Description                          | Example                |
|----------------------|--------------------------------------|------------------------|
| `RELAY_URL`          | Relay address (required)             | `moqt://host:4443`    |
| `TESTCASE`           | Test case name (optional)            | `setup-only`           |
| `TLS_DISABLE_VERIFY` | Skip certificate verification        | `1`                    |
| `VERBOSE`            | Enable debug output                  | `1`                    |

### Relay

| Variable    | Description                   | Default             |
|-------------|-------------------------------|---------------------|
| `MOQT_PORT` | UDP port to listen on         | `4443`              |
| `MOQT_CERT` | Path to TLS certificate       | `/certs/cert.pem`   |
| `MOQT_KEY`  | Path to TLS private key       | `/certs/priv.key`   |
| `MOQT_LOG`  | Log level (e/w/i/d)          | `d`                 |

## Draft-18 Client

The `client-draft-18` target builds the native interop client from xquic's
`moq/draft_18_dev` branch without changing the existing draft-14 images:

```bash
./builds/xquic/build.sh \
  --ref moq/draft_18_dev \
  --target client-draft-18
```

Its local image is `xquic-moq-client-draft-18:latest`; the registered CI image
is `ghcr.io/englishm/moq-interop-runner-xquic-moq-client-draft-18:latest`.
The client supports all six core cases over raw QUIC: `setup-only`,
`announce-only`, `publish-namespace-done`, `subscribe-error`,
`announce-subscribe`, and `subscribe-before-announce`.

## Draft-18 Relay

The `relay-draft-18` target builds the native xquic relay from the same branch:

```bash
./builds/xquic/build.sh \
  --ref moq/draft_18_dev \
  --target relay-draft-18
```

Its local image is `xquic-moq-relay-draft-18:latest`; the registered image is
`ghcr.io/englishm/moq-interop-runner-xquic-moq-relay-draft-18:latest`. The
relay listens on UDP/4443 and supports the same six core cases.

## Draft-22 endpoint preview

Build the endpoint client and direct server from the same XQUIC checkout:

```bash
./builds/xquic/build.sh --local /path/to/xquic --target client-draft-22
docker run --rm -e RELAY_URL=moqt://relay:4443 -e TLS_DISABLE_VERIFY=1 \
  xquic-moq-client-draft-22:latest
docker run --rm xquic-moq-client-draft-22:latest --list
```

The source branch is `dev/moqt-interop`, based on `dev/moqt-22-base`.
Without a local checkout, pass `--ref dev/moqt-interop` explicitly. The image
also starts a direct endpoint with `--server`, `MOQT_PORT` (4443 by default),
and test certificates at `/certs/cert.pem` and `/certs/priv.key`.
It performs no relay routing or forwarding and has no registry relay role.
Do not count direct-origin probes as relay case passes.

The preview registers a locally built client image only; GHCR publication is
deferred until review. Existing draft-14/18 registrations and images are
unchanged. `--list` exposes the integrated case set. Unsupported
SUBSCRIBE_TRACKS, multi-publisher retention, WebTransport, and media cases
return 127/SKIP; attempted peer failures remain failures.

## Pushing to GHCR

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <username> --password-stdin

docker tag xquic-moq-client:latest ghcr.io/<username>/xquic-moq-client:latest
docker tag xquic-moq-relay:latest ghcr.io/<username>/xquic-moq-relay:latest

docker push ghcr.io/<username>/xquic-moq-client:latest
docker push ghcr.io/<username>/xquic-moq-relay:latest
```

After pushing, set the package visibility to **Public** on GitHub Packages
so the interop runner CI can pull the images.
