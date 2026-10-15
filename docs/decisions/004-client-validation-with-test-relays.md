# Decision: Client Validation With Test Relays

**Date:** 2026-10-12

## Problem

The runner validates relays. Each implementation supplies a test client that
runs catalog scenarios through a relay under test and reports TAP. A test
client judges what comes back from the relay, so client behavior is checked
only indirectly. A relay that tolerates an unusual client message hides the
client's error. When a test fails, the result does not show which side caused
it.

The catalog also lets relays behave in more than one way, and each relay picks
one behavior. A client meets only the behaviors its paired relays happen to
implement.

## Background

Several sources permit more than one relay behavior.
`subscribe-before-announce` accepts both a SUBSCRIBE that succeeds once the
publisher announces and a REQUEST_ERROR. Under draft 18, the first outcome
requires the SUBSCRIBE to carry a nonzero RENDEZVOUS_TIMEOUT (Section 10.2.6).
The [data-plane conventions](../tests/data-plane/README.md) accept an exact
Stream Count or the unknown-count sentinel, and data arriving after
PUBLISH_DONE.
[MoQT draft 18](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-18)
Section 10.3 requires endpoints to ignore unknown Setup Options, so a relay may
send options a client has never seen.

Some specifications state facts that only a relay can observe. The proposed
`data-subgroup-basic` test requires the upstream PUBLISH_DONE to report
TRACK_ENDED with Stream Count 3. Docker runs can retain a relay's mlog, but
nothing turns it into an automated relay-side verdict.

## Decision

Add client validation as a second mode of the runner, alongside relay
validation.

- **Test relays.** An implementation may register a test relay: a relay that
  knows which test is running. It checks the client's behavior from the relay
  side and reports TAP. The contract is in
  [TEST-RELAY-INTERFACE.md](../TEST-RELAY-INTERFACE.md).
- **One to start, more expected.** Client validation starts with one test
  relay, and test relays from other implementers are expected to follow. No
  implementation is required to build one. A client validation test does not
  become standard until at least two independently maintained test relays
  implement it.
- **Pairing.** The runner pairs each registered client with each test relay,
  using the existing test identifiers and client images. It runs one test per
  container pair and records both sides. A result passes only when both sides
  pass.
- **Specification sections.** A test specification may list relay-side
  observations and relay variants, as the
  [test catalog](../tests/README.md#client-validation-sections) defines.
- **Within the non-goals.** The runner computes no compliance score for a
  client. Malformed input and protocol violations stay out of scope.

Version pairing follows
[Decision 002](./002-version-selection-strategy.md) unchanged. The runner
predicts the newest shared draft and does not tell the test relay which draft
to accept. The test relay reports the negotiated version, so a mismatch with
the prediction is visible.

## Alternatives Considered

### Passive observation against production relays

The runner could capture decrypted traffic, as proposed in the open
[PCAP capture issue](https://github.com/englishm/moq-interop-runner/issues/128),
or collect mlog for a neutral decoder to check. This cannot exercise relay
variants, because it sees only what each production relay does. A
runner-owned decoder for each draft would also move toward a reference
implementation. It remains useful for diagnosis.

### A single project-owned test relay

With no second reading of the specification to disagree with it, a single
test relay would become the arbiter of correct client behavior, a role the
README excludes. A project-owned test relay could still be one of several, as
`builds/moq-dev-rs` is for test clients.

### Requirement-level scoring for clients

Scoring every MUST would make this project a compliance tool, which the README
excludes.

### Checking clients only through test clients

This leaves both gaps described in the problem statement.

## Rationale

- **It measures the client's half of interoperability.** A client that passes
  every variant of a test handles each relay behavior the test permits, for
  that draft and transport.
- **It separates client faults from relay faults.** A test relay observes the
  upstream half of a test directly.
- **It compares readings of the specification.** Each test relay records its
  implementer's reading of the relay-side expectations, as test clients do for
  the client side. Disagreement between test relays shows where readings
  differ. Several test relays also make it less likely that a shared library
  hides a client's mistake.
- **It needs no new work from clients at first.** Clients that follow the test
  client interface take part unchanged.

Relay-side observations check that the client follows the test's procedure,
as test clients already check relays. For example, `rendezvous-timeout`
requires the relay to answer with error code TIMEOUT. A client can therefore
fail an observation even when a more lenient relay would have worked with it.
This decision limits observations to the messages each procedure requires.
The maintainers decide whether that boundary is right.

## What This Means in Practice

### For test relay implementers

[Implementing a MoQT Test Relay](../IMPLEMENTING-A-TEST-RELAY.md) explains how
to build one on an existing relay stack. A test relay needs routing between a
client's sessions, plus hooks that choose responses and observe messages.

### For test client implementers

Nothing changes. The runner sets `TESTCASE` to one test per run and does not
tell the client the variant. A client that cannot perform a test's procedure
should report SKIP or exit 127. A test relay can expose a client whose wire
procedure differs from the specification under the same test identifier.

### For the runner

- A separate Compose file and Make targets run client validation. The relay
  validation path stays unchanged.
- `implementations.json` gains a `test-relay` role, and `summary.json` records
  both sides of each result. The report shows client validation as its own
  matrix.
- Test relays are Docker-only at first. A remote endpoint cannot receive
  `TESTCASE` or return TAP through the current contract.

## Migration Plan

### Phase 1: Contract and first test relay

Agree on this decision. Add the role to the schema and registration checks,
then add the Compose file, the runner mode and the report matrix. The first
test relay covers the current eight tests with relay-side observations and both
`subscribe-before-announce` variants. It runs on demand, outside the nightly
job. Phase 1 is complete when:

- the first test relay runs against every registered client that shares a draft with it,
  and the report lists clients without a shared draft as not paired;
- each run records the predicted and the negotiated version, and every
  mismatch is flagged and triaged;
- either container can finish first without stopping the other, and the test
  relay writes its TAP after SIGTERM;
- two consecutive runs give the same results;
- each failure is triaged as a client, test relay or specification problem.

### Phase 2: More test relays and variants

Invite test relays from other implementers. Add relay variants to the
data-plane tests and an unknown Setup Options variant to `setup-only`. Add
client validation to the nightly report once its run time is measured, because
it starts one container pair per test and variant.

### Phase 3: Production clients and profiles

Define a client adapter contract, so that clients without a test harness can
be driven for each scenario. Such a client prints no TAP, so the contract must
also define its client-side result. Add profiles such as GOAWAY migration.

## Future Directions

- **Revisions.** Relay-side additions raise a specification's single revision,
  which relay validation results then carry too. A separate client validation
  revision would extend the current policy.
- **Result rule.** A result could require only a passing relay side.
- **Transport.** Once the constraint proposed in
  [Decision 003](./003-url-scheme-transport-selection.md) exists, each pair
  could run over both native QUIC and WebTransport.
- **Hosted test relays.** A hosted test relay with an HTTP API could let
  browser clients take part, which the README defers today.
