# xquic draft-22 endpoint

XQUIC provides two role images for the current draft-22 Native QUIC
(`moqt://`, ALPN `moqt-22`) and WebTransport (`https://`, H3 with `moqt-22`
application protocol) endpoint:

| Image | Default process |
|-------|-----------------|
| `xquic-client:latest` | TAP interop client |
| `xquic-relay:latest` | Direct test server |

The registry key is `xquic`; only draft-22 is registered. Legacy draft-14/18
images and build targets have been removed.

## Build

```bash
# Defaults to alibaba/xquic dev/moqt-interop, based on dev/moqt-over-webtrans.
./builds/xquic/build.sh

# Local development builds both role images.
make xquic-build XQUIC_SOURCE=/absolute/path/to/xquic

# A branch, tag or commit can be selected explicitly.
./builds/xquic/build.sh --ref dev/moqt-interop --target client
./builds/xquic/build.sh --ref dev/moqt-interop --target relay
```

`config.json` owns the default source ref and image names. The multi-stage
`Dockerfile.endpoint` builds Tongsuo 8.4.0 and XQUIC with MoQT and WT enabled, then
copies `moqt_interop` into Ubuntu 22.04 runtimes with separate client/relay
entrypoints. Source provenance is
written to `.last-build.json`. Local builds do not modify the source checkout.

The client build also tags
`ghcr.io/englishm/moq-interop-runner-xquic-client:latest` for local registry
use. The `xquic` image workflow builds both images and publishes only the
registered client; `xquic-relay` remains a local direct-server image. This
preview does not publish to GHCR.

## Run the client

```bash
docker run --rm xquic-client:latest --list
docker run --rm -e RELAY_URL=moqt://relay:4443 -e TLS_DISABLE_VERIFY=1 \
  xquic-client:latest
docker run --rm -e RELAY_URL=https://relay:4443 -e TLS_DISABLE_VERIFY=1 \
  xquic-client:latest
./run-interop-tests.sh --client xquic --target-version draft-22 --dry-run
```

The client uses `RELAY_URL`, `TESTCASE`, `TLS_DISABLE_VERIFY` and `VERBOSE`
and writes TAP v14 to stdout. Exit codes are 0 (pass), 1 (failure) and
127 (unsupported/SKIP). `--list` is the implemented case set. Unsupported
SUBSCRIBE_TRACKS and media cases
return SKIP; attempted peer failures remain failures.

HTTPS selects WT. `--transport webtransport` also runs a canonical `moqt://`
locator over WT. Both paths reuse the same 22 scenario drivers/oracles;
readiness still requires MoQT SETUP after CONNECT. Transport selection may
also use `MOQT_TRANSPORT=quic|webtransport`; explicit flags take priority.

## Run the direct server

```bash
# /path/to/test-certs contains disposable cert.pem and priv.key files.
docker run --rm -p 4443:4443/udp \
  -v /path/to/test-certs:/certs:ro xquic-relay:latest
docker run --rm -p 4443:4443/udp -e MOQT_TRANSPORT=webtransport \
  -v /path/to/test-certs:/certs:ro xquic-relay:latest
```

The server accepts `MOQT_PORT` (default 4443), or explicit `--port`, `--cert`
and `--key` flags. Certificate paths default to `/certs/cert.pem` and
`/certs/priv.key`. The image starts server mode without an extra flag.
It is a direct endpoint/origin, with no
cross-connection routing or forwarding; it has no registry relay role.
Direct-origin probes must be recorded separately from runner relay cases.

The current local peer regression uses aiomoqt 0.14.1 (draft-22, aiopquic):
22 client cases against its relay, including multi-publisher retention,
standalone FETCH and Join/Fill. Reverse-direction validation includes five
control cases, eight direct-origin data vectors, ascending/descending FETCH
and invalid-range recovery. aiomoqt's default Join sender uses a counted Fill
parameter block and is rejected by XQUIC's unchanged inner-sequence codec;
record this mismatch separately from diagnostic wire variants. The probe
scripts and results are local evidence rather than shared runner changes.

## Build regression checks

```bash
python3 builds/xquic/test_build.py
```

These checks stub Git/Docker in a temporary runner tree to verify source-ref
selection, both role builds, individual role selection, provenance and rejected
inputs/build failures. They do not replace real peer interoperability runs.
