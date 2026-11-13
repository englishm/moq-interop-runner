# xquic draft-22 endpoint

XQUIC has one current image, `xquic-moq:latest`, for the Native QUIC
(`moqt://`, ALPN `moqt-22`) client and direct server. The registry key is
`xquic`; only draft-22 is registered. Legacy draft-14/18 images and build
targets have been removed.

## Build

```bash
# Defaults to alibaba/xquic dev/moqt-interop, based on dev/moqt-22-base.
./builds/xquic/build.sh

# Local development uses the same endpoint image.
make xquic-build XQUIC_SOURCE=/absolute/path/to/xquic

# A branch, tag or commit can be selected explicitly.
./builds/xquic/build.sh --ref dev/moqt-interop --target endpoint
```

`config.json` owns the default source ref and image names. The multi-stage
`Dockerfile.endpoint` builds Tongsuo 8.4.0 and XQUIC with MoQT enabled, then
copies `moqt_interop` into an Ubuntu 22.04 runtime. Source provenance is
written to `.last-build.json`. Local builds do not modify the source checkout.

The build also tags the same image as
`ghcr.io/englishm/moq-interop-runner-xquic-moq:latest` so the registry works
locally. This preview does not publish to GHCR. After review, the `xquic`
image workflow is the single publication entry in both manual and bulk builds.

## Run the client

```bash
docker run --rm xquic-moq:latest --list
docker run --rm -e RELAY_URL=moqt://relay:4443 -e TLS_DISABLE_VERIFY=1 \
  xquic-moq:latest
./run-interop-tests.sh --client xquic --target-version draft-22 --dry-run
```

The client uses `RELAY_URL`, `TESTCASE`, `TLS_DISABLE_VERIFY` and `VERBOSE`
and writes TAP v14 to stdout. Exit codes are 0 (pass), 1 (failure) and
127 (unsupported/SKIP). `--list` is the implemented case set. Unsupported
SUBSCRIBE_TRACKS, multi-publisher retention, WebTransport and media cases
return SKIP; attempted peer failures remain failures.

## Run the direct server

```bash
# /path/to/test-certs contains disposable cert.pem and priv.key files.
docker run --rm -p 4443:4443/udp \
  -v /path/to/test-certs:/certs:ro xquic-moq:latest --server
```

The server accepts `MOQT_PORT` (default 4443), or explicit `--port`, `--cert`
and `--key` flags. Certificate paths default to `/certs/cert.pem` and
`/certs/priv.key`. It is a direct endpoint/origin, with no
cross-connection routing or forwarding; it has no registry relay role.
Direct-origin probes must be recorded separately from runner relay cases.

The current local peer regression uses aiomoqt 0.14.1 (draft-22, aiopquic):
19 client cases against its relay, 5 peer control cases against the XQUIC
server, and 8 independent direct-origin data probes. The probe scripts and
results are local evidence rather than shared runner modifications.

## Build regression checks

```bash
python3 builds/xquic/test_build.py
```

These checks stub Git/Docker in a temporary runner tree to verify source-ref
selection, a single image build with both local tags, provenance and rejected
inputs/build failures. They do not replace real peer interoperability runs.
