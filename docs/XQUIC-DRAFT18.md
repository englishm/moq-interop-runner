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

By default, the relay gate runs aiomoqt, moq-rs-draft-18, moxygen, and
xquic-draft-18 as clients; `CLIENTS` can select a different local set. It
captures UDP/4443 with tcpdump while the clients run, then retains
the TAP logs, relay log, `summary.json`, `report.html`, and `.pcap` under one
timestamped `results/` directory. Each client is bounded by
`CLIENT_TIMEOUT_SECONDS` (60 seconds by default).

The upstream aiomoqt image is amd64-only. For native arm64 local runs, the gate
builds `aiomoqt-interop-client-draft-18:local` from upstream commit
`fdb41348376f1286a09d11352e15a288c620485a` and pins both `DRAFT` and
`MOQT_DRAFT` to 18. This adapter is isolated under `builds/xquic`; it does not
change aiomoqt's registry entry or any other implementation's configuration.

## Run the complete local bidirectional matrix

Build both xquic roles from the current checkout and run all six cases against
five local Docker implementations:

```bash
make xquic-full-matrix-draft18 \
  XQUIC_SOURCE=/absolute/path/to/xquic
```

The fixed peer set is aiomoqt, imquic, moq-rs-draft-18, moqx, and moxygen.
The gate runs xquic client against all five relays and all five clients against
the xquic relay. Its top-level `summary.json` and `report.html` use the normal
moq-interop-runner ten-pair format, with each matrix cell showing `n/6` TAP
results. `case-summary.json` retains the 60 individual case rows and evidence.

tcpdump runs concurrently with every pairing. The result directory contains
five client-side captures and six server-side captures. The xquic relay listens
on UDP/4443. The native aiomoqt relay used by this gate is built from the same
pinned commit as the native aiomoqt client and is isolated under `builds/xquic`;
the shared aiomoqt registry entry and adapter remain unchanged.

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

For `subscribe-error`, an unknown namespace/track remains pending for up to
1.5 seconds so `subscribe-before-announce` can still succeed. If no publisher
appears, the relay returns `REQUEST_ERROR` with `DOES_NOT_EXIST` on the same
SUBSCRIBE request stream. Allocation, request-copy, timer-setup, and upstream
forwarding failures also terminate the request instead of leaving it pending.

The local server-side `subscribe-error` validation on 2026-07-19 produced:

| Client | TAP | Relay-side evidence |
|---|---:|---|
| `aiomoqt` | Pass | `REQUEST_ERROR(DOES_NOT_EXIST)`, write `ret:0` |
| `moq-rs-draft-18` | Pass | `REQUEST_ERROR(DOES_NOT_EXIST)`, write `ret:0` |
| `moxygen` | Pass | `REQUEST_ERROR(DOES_NOT_EXIST)`, write `ret:0` |
| `xquic-draft-18` | Pass | `REQUEST_ERROR(DOES_NOT_EXIST)`, write `ret:0` |

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

## Complete local validation snapshot

xquic commit `2fed664` on `moq/draft_18_dev` was rebuilt from a clean checkout
and validated on 2026-07-19. These are the unmodified results from that complete
local Docker run:

| xquic client → relay | setup | announce | namespace done | subscribe error | announce + subscribe | subscribe before announce |
|---|---:|---:|---:|---:|---:|---:|
| `aiomoqt` | Pass | Fail | Fail | Fail | Fail | Fail |
| `imquic` | Pass | Pass | Pass | Pass | Pass | Pass |
| `moq-rs-draft-18` | Pass | Pass | Pass | Pass | Pass | Pass |
| `moqx` | Pass | Pass | Pass | Pass | Pass | Pass |
| `moxygen` | Pass | Pass | Pass | Pass | Pass | Pass |

| client → xquic relay | setup | announce | namespace done | subscribe error | announce + subscribe | subscribe before announce |
|---|---:|---:|---:|---:|---:|---:|
| `aiomoqt` | Pass | Pass | Pass | Pass | Pass | Pass |
| `imquic` | Fail | Fail | Fail | Fail | Fail | Fail |
| `moq-rs-draft-18` | Pass | Pass | Pass | Pass | Pass | Pass |
| `moqx` | Fail | Fail | Fail | Fail | Fail | Fail |
| `moxygen` | Pass | Pass | Pass | Pass | Pass | Fail |

The standard report records 6/10 passing client/relay pairings and 42/60
passing individual cases. All eleven packet captures are non-empty. The logs
retain the observed peer-side failures: aiomoqt sends responses that xquic
closes with protocol error 3 after SETUP; imquic either exits unsuccessfully or
hits the gate timeout (including an invalid-free termination); the moqx client
image does not negotiate `moqt-18` with the xquic relay; and moxygen timed out
in this run's server-side `subscribe-before-announce` case.
