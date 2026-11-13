# xquic draft-22 interop

XQUIC provides two role images for the current draft-22 Native QUIC
(`moqt://`, ALPN `moqt-22`) and WebTransport (`https://`, H3 with `moqt-22`
application protocol) interop application:

| Image | Default process |
|-------|-----------------|
| `xquic-client:latest` | TAP interop client |
| `xquic-relay:latest` | Bounded relay, both transports on one UDP port |

The registry keys are `xquic-client` and `xquic-relay`, so reports show the
client and relay roles separately. Only draft-22 is registered. Legacy
draft-14/18 images and build targets have been removed.

## Build

```bash
# Defaults to alibaba/xquic dev/moqt-interop, based on dev/loc-msf.
./builds/xquic/build.sh

# Local development builds both role images.
make xquic-build XQUIC_SOURCE=/absolute/path/to/xquic

# A branch, tag or commit can be selected explicitly.
./builds/xquic/build.sh --ref dev/moqt-interop --target client
./builds/xquic/build.sh --ref dev/moqt-interop --target relay
```

`config.json` owns the default source ref and image names. The multi-stage
`Dockerfile.client` and `Dockerfile.relay` independently build Tongsuo 8.4.0
and XQUIC with MoQT and WT enabled, then
copies `moqt_interop` into Ubuntu 22.04 runtimes with separate client/relay
entrypoints. The client runtime includes FFmpeg for media decoding; the relay
does not require a decoder. Source provenance is
written to `.last-build.json`. Local builds do not modify the source checkout.

Both roles also receive their
`ghcr.io/englishm/moq-interop-runner-xquic-{client,relay}:latest` tags for local
runner use. The `xquic` image workflow builds the two registered roles. This
preview does not publish to GHCR.

## Run the client

```bash
docker run --rm xquic-client:latest --list
docker run --rm -e RELAY_URL=moqt://relay:4443 -e TLS_DISABLE_VERIFY=1 \
  xquic-client:latest
docker run --rm -e RELAY_URL=https://relay:4443 -e TLS_DISABLE_VERIFY=1 \
  xquic-client:latest
./run-interop-tests.sh --client xquic-client --relay xquic-relay \
  --target-version draft-22 --docker-only --dry-run
```

The client uses `RELAY_URL`, `TESTCASE`, `TLS_DISABLE_VERIFY` and `VERBOSE`
and writes TAP v14 to stdout. Exit codes are 0 (pass), 1 (failure) and
127 (unsupported/SKIP). `--list` is the implemented case set. Unknown cases
return SKIP; attempted peer failures remain failures.

HTTPS selects WT. `--transport webtransport` also runs a canonical `moqt://`
locator over WT. Both paths reuse the same 26 scenario drivers/oracles,
including namespace discovery through SUBSCRIBE_TRACKS;
readiness still requires MoQT SETUP after CONNECT. Transport selection may
also use `MOQT_TRANSPORT=quic|webtransport`; explicit flags take priority.

The 23 existing scenarios retain their contracts. `publish-subscribe-media`
adds C22 using an independent MSF-01 catalog, LOC-05 public metadata and three
16x16 VP8 keyframes. The subscriber selects the catalog Track, assembles all
Objects, checks properties/identities, then independently decodes with FFmpeg
and renders the actual luma pixels as terminal art. Normal decoder exit and
three rendered frames are required. `media-catalog-error` and `media-loc-error`
reject unsupported catalogs/invalid Timescale and recover on the same Sessions.
These two cases are extensions to the runner's 22-case core catalog.
The source adapter README records fixture provenance and profile limitations.

## Run the relay or direct origin

```bash
# /path/to/test-certs contains disposable cert.pem and priv.key files.
docker run --rm -p 4443:4443/udp \
  -v /path/to/test-certs:/certs:ro xquic-relay:latest
docker run --rm -p 4443:4443/udp -e MOQT_TRANSPORT=webtransport \
  -v /path/to/test-certs:/certs:ro xquic-relay:latest
```

The relay accepts `MOQT_PORT` (default 4443), or explicit `--port`, `--cert`
and `--key` flags. Certificate paths default to `/certs/cert.pem` and
`/certs/priv.key`. The image starts `--relay-server --transport dual` through
its default entrypoint and environment. The registry's two URLs select QUIC
or WT on that listener. `--transport quic|webtransport` limits the listener.
The adapter supplies anonymous test policies to XQUIC's bounded relay API;
the library owns routing, namespace retention, discovery, fanout, and
FETCH/Fill forwarding. It supplies no relay history cache.

Append `--server` to select the direct origin instead. Run the client with
`--origin` for 13 direct endpoint probes: five control scenarios and eight
MoQT Test data vectors with complete payload oracles. Keep these observations
separate from independent publisher/subscriber relay scenarios.

The local peer regression uses unchanged aiomoqt 0.14.1 (draft-22, aiopquic)
as client, relay, and origin, with both self-pairs and both cross-pairs over
QUIC and WT. The XQUIC client adds multi-publisher retention to the peer's
22-case catalog. aiomoqt's default Join sender uses a counted Fill
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
