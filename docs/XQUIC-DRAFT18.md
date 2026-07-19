# xquic draft-18 client interoperability

The runner registers the draft-18 client as `xquic-draft-18`, separately from
the existing draft-14 `xquic` relay/client entry. The client uses raw QUIC and
currently supports `setup-only`, `announce-only`,
`publish-namespace-done`, `subscribe-error`, `announce-subscribe`, and
`subscribe-before-announce`.

In draft-18, `publish-namespace-done` is implemented by waiting for
`REQUEST_OK` and then cancelling the PUBLISH_NAMESPACE bidirectional request
stream with the MOQT `CANCELLED` (`0x1`) stream error code. The client does not
send the legacy PUBLISH_NAMESPACE_DONE message.

For `subscribe-error`, the client opens a bidirectional request stream, sends
the draft-18 `SUBSCRIBE` message for `nonexistent/namespace` and `test-track`,
and passes only after receiving a `REQUEST_ERROR` on that same stream. Its
request ID is correlated with the stream metadata before the subscription is
cleaned up.

For `announce-subscribe`, the publisher first receives `REQUEST_OK` for its
namespace. A separate subscriber then sends `SUBSCRIBE`; the relay forwards the
request to the publisher, which returns `SUBSCRIBE_OK` on the same bidirectional
request stream. The subscriber passes only after receiving its corresponding
`SUBSCRIBE_OK`.

For `subscribe-before-announce`, the subscriber completes SETUP and sends
`SUBSCRIBE` before the publisher exists. The publisher connection is created
500 ms after that SUBSCRIBE is sent and advertises the namespace. Both legal
draft-18 outcomes are accepted: an immediate `REQUEST_ERROR`, or a later
`SUBSCRIBE_OK`. In either path, the test also waits for the publisher's matching
`REQUEST_OK`, so both sides of the topology are exercised.

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

## Run the draft-18 relay matrix

Build the relay from the current xquic checkout and run one server-side case:

```bash
make xquic-relay-test-draft18 \
  XQUIC_SOURCE=/absolute/path/to/xquic \
  XQUIC_TEST_ARGS=announce-subscribe
```

The relay gate runs aiomoqt, moq-rs-draft-18, moxygen, and xquic-draft-18 as
clients. It captures UDP/4443 with tcpdump while the clients run, then retains
the TAP logs, relay log, `summary.json`, `report.html`, and `.pcap` under one
timestamped `results/` directory. Each client is bounded by
`CLIENT_TIMEOUT_SECONDS` (60 seconds by default).

The upstream aiomoqt image is amd64-only. For native arm64 local runs, the gate
builds `aiomoqt-interop-client-draft-18:local` from upstream commit
`fdb41348376f1286a09d11352e15a288c620485a` and pins both `DRAFT` and
`MOQT_DRAFT` to 18. This adapter is isolated under `builds/xquic`; it does not
change aiomoqt's registry entry or any other implementation's configuration.

For `publish-namespace-done`, the relay binds each advertised namespace to its
PUBLISH_NAMESPACE request stream and removes the registration when that stream
is reset or ended. The gate also records relay-side removal evidence in
`summary.json` and the HTML detail table. A draft-16-style
PUBLISH_NAMESPACE_DONE message is accepted only as an input compatibility path;
the xquic draft-18 client continues to cancel the request stream.

The local server-side `publish-namespace-done` validation on 2026-07-19 found:

| Client | TAP | Relay-side namespace removal |
|---|---:|---|
| `aiomoqt` | Pass | Explicit withdrawal observed (legacy input compatibility path) |
| `moq-rs-draft-18` | Pass | Explicit request-stream withdrawal observed |
| `moxygen` | Pass | Removed during session-close cleanup; no request withdrawal observed |
| `xquic-draft-18` | Pass | Explicit request-stream withdrawal observed |

The moxygen row is intentionally retained as a qualified result: its client
reports PASS, but the relay-side gate does not claim an explicit draft-18
withdrawal when only connection teardown was visible.

For `announce-subscribe`, the xquic relay records the publisher's namespace,
forwards the subscriber's request to that publisher on a new draft-18 request
stream, and maps the publisher's `SUBSCRIBE_OK` back to the subscriber's
original request stream. For `subscribe-before-announce`, it holds the request
for up to 1.5 seconds. A matching namespace advertisement wakes the request;
otherwise the relay returns `REQUEST_ERROR` with `DOES_NOT_EXIST`.

The local server-side validation on 2026-07-19 produced this matrix:

| Client | `announce-subscribe` | `subscribe-before-announce` |
|---|---:|---:|
| `aiomoqt` | Pass | Pass (`SUBSCRIBE_OK`) |
| `moq-rs-draft-18` | Pass | Pass (`SUBSCRIBE_OK`) |
| `moxygen` | Pass | Pass (`REQUEST_ERROR`) |
| `xquic-draft-18` | Pass | Pass (`SUBSCRIBE_OK`) |

## Validation snapshot

xquic commit `4115531` on `moq/draft_18_dev` was validated on 2026-07-19:

| Relay | `setup-only` | `announce-only` | `publish-namespace-done` | `subscribe-error` | `announce-subscribe` | `subscribe-before-announce` |
|---|---:|---:|---:|---:|---:|---:|
| `imquic` | Pass | Pass | Pass | Pass | Pass | Pass |
| `moq-rs-draft-18` | Pass | Pass | Pass | Pass | Pass | Pass |
| `moqt-nr` | Pass | Pass | Pass | Pass | Pass | Pass |
| `moqx` | Pass | Pass | Pass | Pass | Pass | Pass |
| `moxygen` | Pass | Pass | Pass | Pass | Pass | Pass |

The generated matrix reports 5/5 relay combinations and 30/30 case executions
passing.
