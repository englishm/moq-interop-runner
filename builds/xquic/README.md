# xquic MoQ build

This build definition keeps the existing draft-14 xquic relay/client images
and adds a separate draft-18 interop client from `moq/draft_18_dev`.

| Target | Local image | Default source branch in CI |
|---|---|---|
| `relay` | `xquic-moq-relay:latest` | `moq_draft_14_dev_relay` |
| `client` | `xquic-moq-client:latest` | `moq_draft_14_dev_relay` |
| `client-draft-18` | `xquic-moq-client-draft-18:latest` | `moq/draft_18_dev` |

The legacy relay and client remain registered as `xquic` and must not be
advertised as draft-18 implementations.

## Build the draft-18 client

From a local checkout:

```bash
./scripts/local-container-env.sh \
  ./builds/xquic/build.sh \
  --local /absolute/path/to/xquic \
  --target client-draft-18
```

From the published development branch:

```bash
./builds/xquic/build.sh \
  --ref moq/draft_18_dev \
  --target client-draft-18
```

The registered CI image is
`ghcr.io/englishm/moq-interop-runner-xquic-moq-client-draft-18:latest`.

## Draft-18 client interface

The native client reads the standard runner variables directly:

- `RELAY_URL`: required `moqt://host:port` relay URL
- `TESTCASE`: optional case name; currently `setup-only` or `announce-only`
- `TLS_DISABLE_VERIFY`: `1` or `true` to accept the test certificate
- `VERBOSE`: `1` or `true` for diagnostic logs on stderr

It emits TAP version 14 and returns 127 for unsupported transports or cases.
