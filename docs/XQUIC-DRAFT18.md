# xquic draft-18 client interoperability

The runner registers the draft-18 client as `xquic-draft-18`, separately from
the existing draft-14 `xquic` relay/client entry. The client uses raw QUIC and
currently supports `setup-only` and `announce-only`.

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

xquic commit `6c67044` on `moq/draft_18_dev` was validated on 2026-07-19:

| Relay | `setup-only` | `announce-only` |
|---|---:|---:|
| `imquic` | Pass | Pass |
| `moq-rs-draft-18` | Pass | Pass |
| `moqt-nr` | Pass | Pass |
| `moqx` | Pass | Pass |
| `moxygen` | Pass | Pass |

The generated matrix reports 5/5 relay combinations and 10/10 case executions
passing.
