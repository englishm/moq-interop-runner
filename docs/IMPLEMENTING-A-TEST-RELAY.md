# Implementing a MoQT Test Relay

> **This is a how-to guide for test relay authors.** If you just want to run
> existing tests against your relay, see [Getting Started](./GETTING-STARTED.md).
> For the exact interface specification, see
> [TEST-RELAY-INTERFACE.md](./TEST-RELAY-INTERFACE.md).

> **Not yet implemented.** The runner does not run test relays yet.
> [Decision 004](./decisions/004-client-validation-with-test-relays.md)
> explains the plan. This guide shows the intended shape, and details may
> change as the first test relay is built.

This guide explains how to build a test relay on your MoQT relay stack that is
compatible with the moq-interop-runner framework.

## Why Test Relays?

Test clients check relays. A test client judges what comes back from the relay,
so the runner checks a client's own messages only indirectly. A relay that
tolerates an unusual client message hides it, and a failed test does not show
which side caused the failure.

A test relay checks the other direction. It knows which test is running, so it
can check the messages the client sends. It can also exercise each relay
behavior that a test permits, one variant at a time. A client tested against
production relays sees only the behaviors those relays happen to choose.

Each test relay records its implementer's reading of the relay-side
expectations, as each test client does for the client side. When two test
relays disagree about the same client, implementers are reading the
specification differently. Client validation starts with one test relay, and
test relays from other implementers are welcome. No implementation is
required to build one.

## Overview

A test relay is a standalone executable that:

1. Listens as a MoQT relay for one test
2. Accepts the client's sessions, routes between them and applies the
   requested variant
3. Checks the client's messages against the test's relay-side observations
4. Reports one TAP result and exits

The test relay judges only the relay side. The client reports its own result
as usual, and the runner combines the two.

## Interface Requirements

Your test relay MUST implement the interface defined in
[TEST-RELAY-INTERFACE.md](./TEST-RELAY-INTERFACE.md):

- Read the test and variant from command-line arguments or environment
  variables, and exit 127 for an entry it does not support
- List its tests and variants with `--list`
- Open its port only when ready, and write TAP even after SIGTERM
- Return appropriate exit codes

## Building on Your Relay Stack

A test relay is your relay with test hooks, in the same way a test client is
your client with test logic. It needs three things that a production relay may
not expose:

- **Routing between the client's sessions.** Several tests have the client
  open a publisher session and a subscriber session. Reuse your relay's
  routing for this.
- **Hooks that choose responses.** A variant may answer a SUBSCRIBE with
  REQUEST_ERROR, hold it, or set the Stream Count in PUBLISH_DONE.
- **Hooks that observe messages.** The test relay needs each message the client
  sends, in order, with the session it arrived on.

If your library exposes only high-level relay APIs, the hooks may need access
to lower layers. Keep them behind a test-only interface or a separate binary,
so that production behavior does not change.

A test relay must not send malformed messages or violate the protocol. Each
variant is a behavior that the protocol permits.

## Test Case Implementation

For each test you support, follow the prose specification linked from the
[test catalog](./tests/README.md). Its
[client validation sections](./tests/README.md#client-validation-sections)
list what to check and which variants to offer. Until a specification has
those sections, check only the messages its procedure requires.

The examples below are pseudocode using draft 18 message names. They assume a
helper, `run`, that wraps the relay for one test:

- `relay.start_run(deadline)` waits for the client's first session, up to the
  first-session wait, then starts the test clock. It returns `None` if no
  session arrives. The run records the negotiated version of every session it
  accepts, before any role is known.
- `run.next_request(type)` returns the next request message of that type from
  any client session, or `None` at the deadline or after SIGTERM.
- `run.assign_role(session, role)` records a session's logical role for the
  YAML diagnostics. A session left without a role, including one whose role
  is already taken, is reported under an `unassigned_N` key.
- `run.fail(message)`, `run.skip(reason)` and `run.finish()` build the result
  with its duration and session metadata. Each first keeps serving until the
  client closes its sessions or SIGTERM arrives, so the test relay's exit
  cannot disturb the client's result. `run.finish()` then fails if a session
  ended with an error, and passes otherwise.

The examples use the namespace and track from the test specifications:

```python
TEST_NAMESPACE = "moq-test/interop"  # as written in the test specification
TEST_TRACK = "test-track"
```

### Example: `setup-only`

```python
def test_setup_only(relay, variant):
    """Check that the client completes SETUP and closes the session cleanly."""
    run = relay.start_run(deadline=2.0)
    if run is None:
        return TestResult.fail("no client session")

    client = run.first_session
    run.assign_role(client, "client")

    # Draft 18: each peer opens a control stream that begins with SETUP.
    client.send_setup()
    msg = client.recv_control()
    if msg is None or msg.type != SETUP:
        return run.fail(f"expected SETUP, got {describe(msg)}")

    # The procedure ends with a graceful close by the client.
    close = client.wait_closed()
    if close is None:
        return run.fail("client did not close the session before the deadline")
    if close.code != NO_ERROR:
        return run.fail(f"client closed the session with {close.code}")

    return run.finish()
```

### Example: `subscribe-before-announce` (Variants)

The specification accepts two outcomes for a SUBSCRIBE that arrives before
PUBLISH_NAMESPACE, so this test relay lists two entries,
`subscribe-before-announce@hold` and `subscribe-before-announce@reject`.

Draft 18 Section 10.2.6 limits the `hold` variant. When RENDEZVOUS_TIMEOUT is
absent or 0, a relay with no publisher MUST answer at once with REQUEST_ERROR
and error code DOES_NOT_EXIST. The test relay then reports SKIP for `hold`.

```python
def test_subscribe_before_announce(relay, variant):
    """Answer an early SUBSCRIBE with the behavior the variant names."""
    run = relay.start_run(deadline=3.5)
    if run is None:
        return TestResult.fail("no client session")

    # The subscriber's SUBSCRIBE must arrive before any PUBLISH_NAMESPACE.
    first = run.next_request(type=(SUBSCRIBE, PUBLISH_NAMESPACE))
    if first is None or first.type != SUBSCRIBE:
        return run.fail(f"expected SUBSCRIBE first, got {describe(first)}")
    run.assign_role(first.session, "subscriber")
    if (first.namespace, first.track) != (TEST_NAMESPACE, TEST_TRACK):
        return run.fail(f"SUBSCRIBE named {first.namespace}/{first.track}")

    hold_ms = first.params.get(RENDEZVOUS_TIMEOUT, 0)
    holding = variant == "hold" and hold_ms > 0
    if holding:
        # Relay routing forwards the SUBSCRIBE once the namespace appears,
        # or sends REQUEST_ERROR with TIMEOUT when hold_ms expires.
        pending = run.hold(first, timeout_ms=hold_ms)
    elif hold_ms == 0:
        first.reply_error(DOES_NOT_EXIST)
    else:
        # A relay MAY use a shorter timeout than requested.
        first.reply_error(TIMEOUT)

    # The publisher starts about 500 ms after the subscriber.
    announce = run.next_request(type=PUBLISH_NAMESPACE)
    if announce is None:
        return run.fail("no PUBLISH_NAMESPACE before the deadline")
    if announce.session is first.session:
        return run.fail("PUBLISH_NAMESPACE arrived on the subscriber session")
    run.assign_role(announce.session, "publisher")
    if announce.namespace != TEST_NAMESPACE:
        return run.fail(f"PUBLISH_NAMESPACE named {announce.namespace}")
    announce.reply_ok()  # REQUEST_OK

    if variant == "hold":
        if not holding:
            return run.skip("hold needs a nonzero RENDEZVOUS_TIMEOUT")
        outcome = pending.wait()
        if outcome.timed_out:
            return run.skip("RENDEZVOUS_TIMEOUT expired before PUBLISH_NAMESPACE")
        if outcome.upstream_reply != SUBSCRIBE_OK:
            return run.fail(
                f"publisher answered the forwarded SUBSCRIBE with {outcome.upstream_reply}"
            )

    # Neither session may end with an error.
    return run.finish()
```

The client's own TAP must pass in both variants, because the specification
accepts either outcome. The client is not told the variant.

### Example: `announce-subscribe` (Routing Between Sessions)

This test has no variants. The test relay routes the subscriber's SUBSCRIBE to
the publisher session, as a production relay would:

```python
def test_announce_subscribe(relay, variant):
    """Route the subscriber's SUBSCRIBE to the publisher session."""
    run = relay.start_run(deadline=3.0)
    if run is None:
        return TestResult.fail("no client session")

    announce = run.next_request(type=PUBLISH_NAMESPACE)
    if announce is None:
        return run.fail("no PUBLISH_NAMESPACE before the deadline")
    run.assign_role(announce.session, "publisher")
    if announce.namespace != TEST_NAMESPACE:
        return run.fail(f"PUBLISH_NAMESPACE named {announce.namespace}")
    announce.reply_ok()  # REQUEST_OK

    subscribe = run.next_request(type=SUBSCRIBE)
    if subscribe is None:
        return run.fail("no SUBSCRIBE before the deadline")
    if subscribe.session is announce.session:
        return run.fail("SUBSCRIBE arrived on the publisher session")
    run.assign_role(subscribe.session, "subscriber")
    if (subscribe.namespace, subscribe.track) != (TEST_NAMESPACE, TEST_TRACK):
        return run.fail(f"SUBSCRIBE named {subscribe.namespace}/{subscribe.track}")

    # Forward through the relay's routing, which keeps the parameters draft 18
    # requires a relay to send upstream, such as NEW_GROUP_REQUEST
    # (Section 10.2.13).
    upstream = run.forward_subscribe(subscribe, to=announce.session)
    reply = upstream.recv()
    if reply is None:
        return run.fail("publisher did not answer the forwarded SUBSCRIBE")
    subscribe.forward_reply(reply)  # SUBSCRIBE_OK or REQUEST_ERROR
    if reply.type != SUBSCRIBE_OK:
        return run.fail(f"publisher answered the forwarded SUBSCRIBE with {reply.type}")

    return run.finish()
```

The procedure does not require either session to close, so `run.finish()`
fails only when a session ends with an error.

## Output Formatting

Test relays output [TAP version 14](https://testanything.org/tap-version-14-specification.html).
See [TEST-RELAY-INTERFACE.md](./TEST-RELAY-INTERFACE.md#output-format) for the
full specification.

### Main Entry Point

```python
def main():
    args = parse_args()  # or parse environment variables

    if args.list:
        for entry in SUPPORTED_ENTRIES:  # "test-id" or "test-id@variant"
            print(entry)
        sys.exit(0)

    entry = args.test + (f"@{args.variant}" if args.variant else "")
    if entry not in SUPPORTED_ENTRIES:
        sys.exit(127)  # before opening the port

    relay = Relay(port=args.port, cert=args.cert, key=args.key)
    # On SIGTERM, pending waits return at once and the test judges what it has.
    signal.signal(signal.SIGTERM, lambda *_: relay.stop_input())
    relay.listen()  # an open port tells the health check the relay is ready

    result = TESTS[args.test](relay, args.variant)

    print("TAP version 14")
    print(f"# {RELAY_NAME} v{RELAY_VERSION}")
    print(f"# Test: {args.test}")
    if args.variant:
        print(f"# Variant: {args.variant}")
    print("1..1")
    print(format_tap_result(1, result, variant=args.variant))

    sys.exit(1 if result.failed else 0)
```

`format_tap_result` follows the version in the
[test client guide](./IMPLEMENTING-A-TEST-CLIENT.md#main-entry-point), with two
changes. It adds a `variant` field to the YAML metadata when a variant is set.
It also writes the YAML block after a SKIP test point, because the interface
requires the negotiated version of every session.

## Lifecycle and Timeouts

A test relay waits in three places. Each wait needs a bound:

1. **First session**: wait up to the first-session wait for the client's first
   session. The default is 30 seconds.
2. **Test deadline**: apply the timeouts in the test specification, or 5
   seconds when it gives none. The verdict comes when the completion
   condition holds or the deadline expires. After it, keep serving until the
   client closes its sessions or SIGTERM arrives.
3. **SIGTERM**: stop waiting, judge the evidence collected, write TAP and exit
   within 5 seconds.

Don't let a test hang. A `not ok` result after a timeout should name the
message the test relay was waiting for.

## Identifying Sessions

Report each client session under its logical role from the test specification.
Assign the role from the first request message the session sends, such as
`publisher` for PUBLISH_NAMESPACE and `subscriber` for SUBSCRIBE or
SUBSCRIBE_NAMESPACE. Do not identify sessions by connection order. A test with
one session uses the role its specification names.

Some sessions get no role: a session that sends no request before the
deadline, or a second session whose request matches a role already assigned.
Report them as `unassigned_1`, `unassigned_2` and so on, so that their
negotiated versions still reach the runner. Record each session's metadata
when you accept it, because a failing run may never reveal its role.

For each QUIC session, report the Destination Connection ID from the client's
first Initial packet. A QUIC server echoes this value in its
`original_destination_connection_id` transport parameter
([RFC 9000 Section 7.3](https://www.rfc-editor.org/rfc/rfc9000#section-7.3)),
so the server's QUIC stack has it. Encode it as lowercase hexadecimal without
separators or a `0x` prefix. The client reports the same value, so the runner
can match sessions across the two TAP streams.

Report the negotiated `moqt_version` of every session that completed
negotiation, as the interface requires, and its `transport`:

```tap
ok 1 - announce-subscribe
  ---
  duration_ms: 156
  sessions:
    publisher:
      moqt_version: "moqt-18"
      transport: "quic"
      quic_initial_destination_connection_id: "abc1234567890def"
    subscriber:
      moqt_version: "moqt-18"
      transport: "quic"
      quic_initial_destination_connection_id: "def6789012345abc"
  ...
```

## Docker Considerations

When containerizing your test relay:

1. **Entry point**: use an exec-form `ENTRYPOINT`, or end an entrypoint script
   with `exec moq-test-relay "$@"`. Container arguments then reach `--list`,
   and SIGTERM reaches the test relay directly.
2. **Inputs**: read `TESTCASE`, `TEST_VARIANT`, `MOQT_PORT` and `VERBOSE` from
   the environment.
3. **Certificates**: load the certificate and key from `/certs/cert.pem` and
   `/certs/priv.key`. The runner's Compose file runs containers as a non-root
   user, so the files must be readable by that user.
4. **Health check**: the runner checks that the UDP port is listening, through
   `ss`, `netstat` or `/proc/net/udp`. The `/proc` fallback needs neither `ss`
   nor `netstat`, but the check still runs `sh`, `printf` and `grep` inside the
   image. Open the port only when ready.
5. **Output**: write only TAP to stdout. Send logs to stderr.

Example Dockerfile pattern:

```dockerfile
FROM rust:1.75 as builder
WORKDIR /app
COPY . .
RUN cargo build --release --bin moq-test-relay

FROM debian:bookworm-slim
COPY --from=builder /app/target/release/moq-test-relay /usr/local/bin/
EXPOSE 4443/udp
ENTRYPOINT ["moq-test-relay"]
```

Register the image under the `test-relay` role in
`implementations.json`:

```json
"roles": {
  "test-relay": {
    "docker": { "image": "ghcr.io/example/moqt-test-relay:latest" }
  }
}
```

## Example Implementation

None yet. The first test relay will be linked here.
