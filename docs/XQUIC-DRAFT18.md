# xquic draft-18 client interoperability

The runner registers the draft-18 client as `xquic-draft-18`, separately from
the existing draft-14 `xquic` relay/client entry. The client uses raw QUIC and
currently supports `setup-only`, `announce-only`,
`publish-namespace-done`, and `subscribe-error`.

In draft-18, `publish-namespace-done` is implemented by waiting for
`REQUEST_OK` and then cancelling the PUBLISH_NAMESPACE bidirectional request
stream with the MOQT `CANCELLED` (`0x1`) stream error code. The client does not
send the legacy PUBLISH_NAMESPACE_DONE message.

For `subscribe-error`, the client opens a bidirectional request stream, sends
the draft-18 `SUBSCRIBE` message for `nonexistent/namespace` and `test-track`,
and passes only after receiving a `REQUEST_ERROR` on that same stream. Its
request ID is correlated with the stream metadata before the subscription is
cleaned up.

## Build

Build from xquic's `moq/draft_18_dev` branch:

```bash
make xquic-client-build XQUIC_SOURCE=/absolute/path/to/xquic
```

This produces `xquic-moq-client-draft-18:latest`. The test script re-tags that
local image with the name registered in `implementations.json`; it does not
modify the shared registry or any relay configuration.

## Run the draft-18 remote matrix

```bash
make xquic-client-test-draft18
```

To build and test the current checkout in one command:

```bash
make xquic-client-test-draft18 \
  XQUIC_SOURCE=/absolute/path/to/xquic
```

Additional runner filters can be passed through `XQUIC_TEST_ARGS`:

```bash
make xquic-client-test-draft18 \
  XQUIC_TEST_ARGS="--relay moq-rs-draft-18"
```

The command runs only draft-18 raw-QUIC endpoints, writes the normal runner
`summary.json` and endpoint logs under `results/`, and generates `report.html`
with the existing report generator.

## Validation snapshot

xquic commit `eda88ce` on `moq/draft_18_dev` was validated on 2026-07-19:

| Relay | `setup-only` | `announce-only` | `publish-namespace-done` | `subscribe-error` |
|---|---:|---:|---:|---:|
| `imquic` | Pass | Pass | Pass | Pass |
| `moq-rs-draft-18` | Pass | Pass | Pass | Pass |
| `moqt-nr` | Pass | Pass | Pass | Pass |
| `moqx` | Pass | Pass | Pass | Pass |
| `moxygen` | Pass | Pass | Pass | Pass |

The generated matrix reports 5/5 relay combinations and 20/20 case executions
passing.
