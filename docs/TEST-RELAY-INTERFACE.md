# MoQT Test Relay Interface Specification

> **This is reference material.** It defines the exact contract test relays
> must follow. For a guided walkthrough of building a test relay, see
> [IMPLEMENTING-A-TEST-RELAY.md](./IMPLEMENTING-A-TEST-RELAY.md).

> **Not yet implemented.** The runner does not run test relays yet.
> [Decision 004](./decisions/004-client-validation-with-test-relays.md)
> explains the plan, and this contract may change as the first test relay is
> built.

This document defines the interface that MoQT test relays MUST implement to
take part in client validation. A test relay is a relay that knows which test
is running. A client under test connects to it, and the test relay checks the
client's behavior from the relay side. It reports the result as TAP, as a test
client does for a relay under test.

## Command Line Interface

Test relays SHOULD support the following command-line interface:

```bash
moq-test-relay [OPTIONS]

Options:
  -t, --test <NAME>           Test to run
      --variant <NAME>        Relay variant to exercise
  -p, --port <PORT>           UDP port to listen on (default: 4443)
      --cert <PATH>           TLS certificate (default: /certs/cert.pem)
      --key <PATH>            TLS private key (default: /certs/priv.key)
  -l, --list                  List supported tests and variants
  -v, --verbose               Verbose output on stderr
```

`--list` is REQUIRED, because the runner reads it to plan each run. The image
MUST pass container arguments to the test relay, so that
`docker run IMAGE --list` reaches it. An exec-form `ENTRYPOINT` does this, and
so does an entrypoint script that ends with `exec moq-test-relay "$@"`.

A test and a variant together name one entry from the
[list output](#list-output). When no variant is given, the test relay runs the
entry without a variant.

## Environment Variable Interface

For containerized testing, the following environment variables are supported:

| Variable | Required | Description |
|----------|----------|-------------|
| `TESTCASE` | Yes | Test identifier from the [test catalog](./tests/README.md) |
| `TEST_VARIANT` | No | Relay variant to exercise; unset or empty selects the entry without a variant |
| `MOQT_PORT` | No | UDP port to listen on (default 4443) |
| `VERBOSE` | No | Set to `1` for verbose output on stderr |

The runner mounts the TLS certificate and key at `/certs/cert.pem` and
`/certs/priv.key`, as it does for relay images. Environment variables take
precedence over command-line defaults but not over explicit command-line
arguments.

## Listening and Transports

A test relay MUST open its UDP port only when it is ready to accept the
client's first session. The runner's health check treats an open port as
ready, and the runner starts the client as soon as the check passes.

Clients receive the locator in the test relay's `docker.url` registry field,
or `https://relay:4443` when that field is absent. The test relay MUST accept
sessions at that locator. A client that cannot use the locator's transport
fails or skips the test. Client validation does not depend on the transport
constraint that
[Decision 003](./decisions/003-url-scheme-transport-selection.md) proposes.

A test relay negotiates the MoQT version as a relay normally would. The runner
predicts a version as
[Decision 002](./decisions/002-version-selection-strategy.md) describes, but
it does not tell the test relay which version to accept. The test relay
reports the version each session actually negotiated, as described under
[YAML Diagnostics](#yaml-diagnostics).

## Lifecycle

A test relay runs one test per process:

1. Read the test and variant. If the test relay does not support that entry,
   exit 127 at once, without opening the port.
2. Open the port when ready to accept sessions.
3. Wait for the client's first session, up to the
   [first-session wait](#timeout-handling).
4. Run the test until its completion condition holds or its deadline expires.
   The test relay then has its verdict.
5. Keep serving until the client has closed all its sessions, or until
   SIGTERM arrives.
6. Write TAP to stdout and exit.

The test relay keeps serving after its verdict because the client may still
be finishing its own procedure. Closing the client's sessions at that point
could change the client's result. A session that ends with an error before
the test relay writes TAP still fails the result. The test relay MUST NOT
depend on the client container's exit. When the client leaves a session open,
the runner's SIGTERM ends the run, as described under
[How the Runner Runs a Test](#how-the-runner-runs-a-test).

When the test relay receives SIGTERM, it MUST treat the client's input as
finished. It judges the evidence it has, writes TAP and exits within 5 seconds.
The test relay MUST receive SIGTERM directly. Run it as the container's main
process, through an exec-form `ENTRYPOINT` or `exec` in an entrypoint script.

## Relay Behavior

A test relay MUST behave as a relay for the test. Several tests open a
publisher session and a subscriber session from the same client and expect the
relay to route between them. The test relay forwards control messages and
objects between the sessions, or it serves the deterministic object set that
the test specification defines.

### Variants

A variant selects one relay behavior that the test permits. A test relay MUST
exercise only the requested variant, and each variant MUST appear under "Relay
variants" in the test specification. Variants are limited to behavior that the
protocol permits for the negotiated draft. A test relay MUST NOT send
malformed messages or violate the protocol to produce a variant.

For example, a variant in which objects arrive after PUBLISH_DONE still closes
every stream before it sends PUBLISH_DONE, as draft 18 Section 10.11 requires.
It delays the stream data through send scheduling.

A client's messages can make a variant impossible to run. The test relay then
responds as the protocol requires and reports SKIP. For example, draft 18
Section 10.2.6 permits a relay to hold a SUBSCRIBE for a track with no
publisher only when the SUBSCRIBE carries a nonzero RENDEZVOUS_TIMEOUT.

### Observations

A test relay checks the relay-side observations that the test specification
lists. They are limited to the messages that the test's procedure requires, as
the [test catalog](./tests/README.md#client-validation-sections) describes. A
client attempts a test once it opens a session for it. If the client then
omits a required message, or sends it out of the required order, the test
relay reports `not ok` and names what it saw.

If no client session arrives within the first-session wait, the test relay
reports `not ok` with the message `no client session`. A client that does not
support the test can exit 127 without connecting. The
[classification rules](#how-the-runner-classifies-results) then record the
cell as unsupported by the client.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | The test point is `ok`, including `ok ... # SKIP` |
| 1 | The test point is `not ok` |
| 127 | Test or variant not supported by this test relay |

Any other exit status means that the test relay could not run the test, for
example because it could not bind its port. The runner records an error. A
test relay SHOULD report its own internal failures this way. The runner treats
`Bail out!` as a failed observation, which counts against the client.

## Output Format

Test relays MUST output valid
[TAP version 14](https://testanything.org/tap-version-14-specification.html)
to stdout, as [Decision 001](./decisions/001-tap-output-format.md) describes
for test clients. Logs go to stderr.

### Required Elements

Every run that reaches a verdict MUST include the elements below. A test relay
that exits 127, or fails before it can run the test, need not print TAP.

1. **Version line**: `TAP version 14`
2. **Plan**: `1..1`
3. **Test point**: one test point whose description is the test identifier,
   without the variant, such as `ok 1 - subscribe-before-announce`
4. **Negotiated versions**: when any session completed version negotiation, a
   YAML block after the test point with `moqt_version` under `sessions` for
   each such session. See [YAML Diagnostics](#yaml-diagnostics).

### Run-Level Comments

Test relays SHOULD identify the run in comments between the version line and
the plan:

```tap
TAP version 14
# moq-test-relay v0.1.0
# Test: subscribe-before-announce
# Variant: reject
1..1
ok 1 - subscribe-before-announce
  ---
  variant: "reject"
  sessions:
    subscriber:
      moqt_version: "moqt-18"
    publisher:
      moqt_version: "moqt-18"
  ...
```

### YAML Diagnostics

A test relay MUST write a YAML block after its test point whenever at least
one session completed version negotiation. The block uses the fields in
[TAP YAML Metadata](./TAP-YAML-METADATA.md) and follows the indentation rules
in the [test client interface](./TEST-CLIENT-INTERFACE.md#yaml-diagnostics).
`moqt_version` is REQUIRED for each such session, although TAP YAML Metadata
keeps it optional for test clients. The other fields are OPTIONAL. A session
that did not complete negotiation has no reported version, and the runner does
not infer one from its prediction.

The fields are used as follows:

- `sessions` has one entry for each client session, keyed by the logical role
  from the test specification. The test relay assigns each session its role
  from the first request message that session sends. For example, a session
  that sends PUBLISH_NAMESPACE is the `publisher`. A test with one session
  uses the role its specification names, such as `client` for `setup-only`.
- A session that sent no request, or whose request would repeat a role already
  assigned, is keyed `unassigned_1`, `unassigned_2` and so on, in the order the
  test relay accepted those sessions. These keys are labels for test relays
  only, and they claim no role. The test relay records each session's
  negotiated version when it accepts the session, before it knows the role.
- `moqt_version` reports the version each session actually negotiated, and
  `transport` reports its transport. The runner compares `moqt_version` with
  its prediction and flags a mismatch.
- `quic_initial_destination_connection_id` is the Destination Connection ID
  from the client's first Initial packet. The client reports the same value, so
  the runner can match the sessions in both TAP streams.
- `variant` names the variant that the test relay exercised. Omit it for an
  entry without a variant. This field is specific to test relays.
- `test_spec_revision` is the revision of the prose specification that the
  test relay implemented, including its relay-side sections.
- `duration_ms` covers the test from accepting the client's first session to
  the verdict.
- `message` names the failed observation and what the test relay saw.

```tap
ok 1 - subscribe-before-announce
  ---
  duration_ms: 812
  variant: "reject"
  sessions:
    subscriber:
      moqt_version: "moqt-18"
      transport: "quic"
      quic_initial_destination_connection_id: "84ee7793841adcadd926a1baf1c677cc"
    publisher:
      moqt_version: "moqt-18"
      transport: "quic"
      quic_initial_destination_connection_id: "a1b2c3d4e5f67890"
  ...
```

### Skipped Tests

Use the `SKIP` directive when the test relay implements the entry but cannot
run it in this environment or with this client:

```tap
TAP version 14
1..1
ok 1 - subscribe-before-announce # SKIP hold needs a nonzero RENDEZVOUS_TIMEOUT
  ---
  variant: "hold"
  sessions:
    subscriber:
      moqt_version: "moqt-18"
    publisher:
      moqt_version: "moqt-18"
  ...
```

### List Output

When `--list` is specified, output one entry per line (not TAP format). An entry
is a test identifier, optionally followed by `@` and a variant name:

```
setup-only
announce-only
publish-namespace-done
subscribe-namespace-lifecycle
subscribe-error
rendezvous-timeout
announce-subscribe
subscribe-before-announce@hold
subscribe-before-announce@reject
```

The command exits 0 and prints nothing else to stdout. The runner runs each
entry as a separate test.

## How the Runner Runs a Test

The runner pairs a client with a test relay when they share a draft, following
Decision 002. Pairs without a shared draft are listed as not paired.

For each pair, the runner reads the test relay's list. It also asks the client
for its list with `--list`. It accepts the client's list only when the
container exits 0 and prints nothing except test identifiers. Otherwise it runs
every test relay entry and relies on the client's SKIP and unsupported
signals. As of October 2026, the client entrypoint scripts under `builds/` do
not forward container arguments, so `--list` does not reach clients that start
through them.

Each entry runs as follows:

1. Start the test relay as the `relay` service with `TESTCASE` and
   `TEST_VARIANT`, so the client's default `RELAY_URL` resolves.
2. Wait for the health check to pass.
3. Run the client with the same `TESTCASE`. Do not tell the client the
   variant, so it cannot treat one relay behavior as a special case.
4. Wait for both containers to exit, up to the first-session wait plus the
   test deadline plus a short grace period. One container's exit does not
   stop the other.
5. Send SIGTERM to a container that is still running, and wait at least 5
   seconds before killing it.
6. Collect the stdout of each container separately and parse both TAP streams.

## How the Runner Classifies Results

Each run records a relay-side result from the test relay and a client-side
result from the client. The runner reduces each side to pass, skip, fail or
error by applying these rules in order:

1. Exit 127, with or without TAP, is a skip.
2. A kill after the SIGTERM allowance expires, or any exit status other than
   0, 1 or 127, is an error.
3. A `Bail out!` line is a fail.
4. No test point for the test is an error.
5. An `ok ... # SKIP` test point is a skip.
6. An `ok` test point without a directive, with exit 0, is a pass.
7. Any other test point is a fail. This covers `not ok`, and `ok` with exit 1.

A test relay that reaches its own deadline still writes TAP, so its result is
judged from that TAP. The same applies to a container that writes TAP after
SIGTERM. A container that must be killed has stopped responding to the
harness, so it counts as an error. The cell then follows the first matching
row:

| Relay side | Client side | Cell |
|------------|-------------|------|
| error | any | error |
| any | skip | unsupported by the client |
| skip | any | not run |
| fail | any | fail, relay-side observation |
| pass | fail or error | fail, client side |
| pass | pass | pass |

A test relay error comes first so that test relay bugs stay visible, even when
the client skipped the test. A client error after a passing relay side is a
client crash or hang, so it counts against the client. The runner keeps both
raw results in every case.

A person still decides whether a failure belongs to the client, the test relay
or the specification text. `summary.json` gains `mode: "client-validation"`
and the fields `test_relay`, `testcase`, `variant`, `relay_side` and
`client_side`. The report shows client validation as a separate matrix, with
clients as rows and test relays as columns.

## Timeout Handling

Test relays MUST implement timeouts to prevent hanging:

- The first-session wait bounds how long the test relay waits for the client's
  first session. The default is 30 seconds, to be measured with the first test
  relay. It covers the client container's start-up time.
- Each test SHOULD time out after the duration in its test specification. If
  no timeout is specified, default to 5 seconds, as test clients do.
- On timeout, the test relay judges the evidence it has. A `not ok` result
  names the message it was waiting for.

## Error Reporting

When an observation fails, the test relay SHOULD name it and say what it saw:

```tap
not ok 1 - subscribe-before-announce
  ---
  duration_ms: 1240
  variant: "hold"
  message: "PUBLISH_NAMESPACE arrived 12 ms before SUBSCRIBE; the procedure sends SUBSCRIBE first"
  sessions:
    publisher:
      moqt_version: "moqt-18"
      quic_initial_destination_connection_id: "a1b2c3d4e5f67890"
    subscriber:
      moqt_version: "moqt-18"
      quic_initial_destination_connection_id: "84ee7793841adcadd926a1baf1c677cc"
  ...
```
