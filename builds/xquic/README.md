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
# Defaults to alibaba/xquic dev/moqt-interop-40-cases, based on dev/moqt-over-webtrans.
./builds/xquic/build.sh

# Local development builds both role images.
make xquic-build XQUIC_SOURCE=/absolute/path/to/xquic

# A branch, tag or commit can be selected explicitly.
./builds/xquic/build.sh --ref dev/moqt-interop-40-cases --target client
./builds/xquic/build.sh --ref dev/moqt-interop-40-cases --target relay
```

`config.json` owns the default source ref and image names. The multi-stage
`Dockerfile.client` builds a pinned BoringSSL revision; `Dockerfile.relay`
builds Tongsuo 8.4.0. Both build XQUIC with MoQT and WT enabled, then
copy `moqt_interop` into Ubuntu 22.04 runtimes with separate client/relay
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
return SKIP; attempted peer failures remain failures. This branch exposes 40
draft-22 cases. The runner discovers them from `--list` and runs every case
exposed by the selected client; an absent case from another client is unknown
unless that client reports it unsupported.

The client installs Ubuntu's `ca-certificates` and selects its bundle with
`SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` and its hashed directory
with `SSL_CERT_DIR=/etc/ssl/certs`. The image build checks that both paths
exist. XQUIC must include the client default-CA loading fix; changing the TLS
backend alone does not initialize its trust store. Public-CA relays use
verification by default. Override these variables to mount a private CA
bundle; `TLS_DISABLE_VERIFY=1` remains an explicit local-test bypass.

HTTPS selects WT. `--transport webtransport` also runs a canonical `moqt://`
locator over WT. Both paths reuse the same 40 scenario drivers/oracles,
including namespace discovery through SUBSCRIBE_TRACKS;
readiness still requires MoQT SETUP after CONNECT. Transport selection may
also use `MOQT_TRANSPORT=quic|webtransport`; explicit flags take priority.

The 26 cases in the November 15, 2026 report retain their existing contracts.
Fourteen draft-22 cases extend that set:

- Cases 27–36 cover no-EOG Subgroups, nonzero and sparse Group/Object IDs,
  Datagram identity, each Object Property encoding independently, fragmented
  Objects, and IDs above 2^40.
- Cases 37–40 cover Track completion followed by namespace withdrawal, live
  subscription cancellation, descending FETCH, and invalid-range recovery on
  the same Session.

The XQUIC client and relay are exercised over both Native QUIC and WT. For the
aiomoqt comparison, count its 20 default standard cases in common with XQUIC,
in both client directions and both transports (80 results total). A missing
case is not a skip unless the peer explicitly reports it unsupported.

`publish-subscribe-media` uses an independent MSF-01 catalog, LOC-05 public
metadata and three 16x16 VP8 keyframes. The subscriber selects the catalog
Track, assembles all Objects, checks properties/identities, then independently
decodes with FFmpeg and renders the actual luma pixels as terminal art. Normal
decoder exit and three rendered frames are required. `media-catalog-error` and
`media-loc-error` reject unsupported catalogs/invalid Timescale and recover on
the same Sessions.
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
`--origin` for 23 direct endpoint probes: five control scenarios and eighteen
MoQT Test data vectors with complete payload oracles. Keep these observations
separate from independent publisher/subscriber relay scenarios.

The peer comparison uses aiomoqt (draft-22, aiopquic) in both client/relay
directions. Keep its unsupported cases outside the common-case denominator and
record any peer encoding mismatch with the exact test and transport. The target
is 20 common cases × two directions × two transports; use the generated runner
report as the result source.

The November 15, 2026 report showed the XQUIC client's only QUIC failure
against moq-go in `join` (case 22). The relay logged
`FILL_PARAMETERS: unknown parameter type ParamID(0x1)`: XQUIC omitted the
parameter count from the nested Fill parameter sequence. The updated source
uses the counted Fill encoding and rejects the old form.
It also serves Header/FIN for valid empty historical ranges; moq-go probes
these cache gaps during descending FETCH and Join. quic-zig also failed
`join`, but its log does not establish the same cause; verify it in the refreshed report.
Other report failures remain open where TAP or transport logs do not identify
a specific protocol mismatch. Cases absent from the old 26-case catalog need
same-case evidence before they can be marked unsupported.

## Build regression checks

```bash
python3 builds/xquic/test_build.py
```

These checks stub Git/Docker in a temporary runner tree to verify source-ref
selection, both role builds, individual role selection, provenance and rejected
inputs/build failures. They do not replace real peer interoperability runs.

Native peer validation uses aiomoqt 0.14.1 at
`76f29a85596237218c1ff91f2595c2e41606c303` and moq-go at
`4547d8c13e7408fd648d8cd11f3ef8c59b355c07`, without peer changes or compatibility
overrides. aiomoqt's optional client-side Join currently fails because its
publisher explicitly rejects a second subscription to the same Track in one
Session (`track already subscribed in this session`). Preserve these optional
failures outside the 20-default-case denominator.
