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
