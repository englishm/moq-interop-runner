# Data-Plane Test Conventions

This directory contains prose specifications for tests that deliver MoQT
objects through a relay and verify what a subscriber receives. The
repository-wide [catalog and lifecycle](../README.md) applies to every test
here.

These conventions avoid repeating common setup in each scenario. A scenario
overrides them only when the protocol property under test requires a different
flow.

## Proposed Scenarios

- [`data-subgroup-basic`](./data-subgroup-basic.md) verifies baseline finite
  subgroup delivery through namespace-based routing.

## Normal Publication Flow

The normal flow is publisher first:

1. The publisher and relay complete SETUP.
2. The publisher sends PUBLISH_NAMESPACE for the run's [routing
   prefix](#moqt-test-namespace) and receives REQUEST_OK.
3. The subscriber and relay complete SETUP.
4. The subscriber sends SUBSCRIBE for a track whose namespace is the routing
   prefix followed by the scenario's MoQT Test tuple.
5. The relay matches the SUBSCRIBE to the publisher by Namespace Prefix
   Matching and sends a matching upstream SUBSCRIBE. The publisher derives the
   object set from the tuple and responds with SUBSCRIBE_OK. Once that upstream
   subscription is established, the relay sends SUBSCRIBE_OK on the downstream
   subscription.
6. The publisher sends the scenario's objects, closes every data stream it will
   open, has no further datagrams to send, and sends PUBLISH_DONE with the status
   defined by the scenario.
7. The downstream subscriber accepts that PUBLISH_DONE may precede late-arriving
   data. It uses an exact Stream Count when provided; if the publisher reports
   the unknown-count sentinel, it drains data within the scenario's deadline.
   It then verifies the scenario's required observations.

This flow does not use RENDEZVOUS_TIMEOUT. A subscribe-first test exercises
explicit rendezvous behavior and belongs in a separate profile.

Direct PUBLISH is also outside the normal flow. Tests for
SUBSCRIBE_NAMESPACE, SUBSCRIBE_TRACKS, or other direct-publication behavior may
specify it when that distinction is the property under test.

## Common Subscription Stimulus

The downstream SUBSCRIBE sets GROUP_ORDER to Ascending. It omits FORWARD and
SUBSCRIBER_PRIORITY, selecting their defaults of Forward State 1 and Subscriber
Priority 128 (unchanged since MoQT draft 18). It also omits SUBSCRIPTION_FILTER,
so all newly published objects pass the filter.

All other optional parameters are omitted, including RENDEZVOUS_TIMEOUT, object
and subgroup delivery timeouts, and NEW_GROUP_REQUEST. An environment may add
an authorization token as deployment configuration; it is not part of the test
case. The test does not use REQUEST_UPDATE.

Parameters are hop-by-hop. A relay may select its own Group Order and Subscriber
Priority for the upstream SUBSCRIBE as permitted by MoQT. Ascending order is a
scheduling preference, not an assertion about arrival order across groups or
independent streams.

## MoQT Test Namespace

Scenarios describe their object sets with the
[MoQT Test](https://datatracker.ietf.org/doc/html/draft-afrind-moq-test)
Track Namespace format. MoQT Test encodes generation parameters as a 16-field
tuple beginning with `moq-test-00`, so the namespace itself tells a publisher
what to send and tells a subscriber what to expect.

Each data-plane Track Namespace has two parts:

1. A three-field **routing prefix**: `("moq-test", "<test-id>", "<run-id>")`,
   where `<test-id>` is the scenario identifier and `<run-id>` follows
   [Test Identity](#test-identity).
2. The scenario's 16-field **MoQT Test tuple**, beginning with `moq-test-00`.

For example, a SUBSCRIBE in `data-subgroup-basic` uses this 19-field Track
Namespace:

```text
("moq-test", "data-subgroup-basic", "<run-id>",
 "moq-test-00", "0", "0", "0", "2", "4", "5", "64", "32", "2", "1", "1",
 "0", "-1", "-1", "0")
```

The publisher sends PUBLISH_NAMESPACE for the routing prefix only. It acts as a
MoQT Test publisher rooted at that prefix: for a SUBSCRIBE whose namespace is
the prefix followed by a MoQT Test tuple, it generates the objects that the tuple
describes. The relay routes the SUBSCRIBE by Namespace Prefix Matching (MoQT
draft 18, Section 9.5), so a test covers prefix routing as well as delivery. The
publisher may reject a SUBSCRIBE whose remaining fields are not a valid tuple
it supports.

The `moq-test` root lets deployments that limit anonymous publication to
test namespaces accept the run. Every field is a non-empty ASCII string, as
MoQT requires. Because MoQT forbids empty namespace fields, scenarios spell
every tuple field explicitly instead of leaving fields blank to select MoQT Test
defaults. They use the encoding that existing MoQT Test implementations use:
`-1` disables the test extensions in fields 13 and 14, and `0` in field 15 means
no publisher delivery timeout.

Each scenario lists its exact tuple. The scenario's canonical-case table
interprets that tuple for readers; when they disagree, the tuple is
authoritative and the table should be corrected. MoQT Test does not constrain
the Track Name, and every Track Name under the same namespace yields the same
content. Scenarios use the Track Name `track`.

## Test Identity

Each run uses a collision-resistant routing prefix. The run identifier is the
lowercase hexadecimal encoding of at least 128 bits of random entropy, making it
a non-empty UTF-8 field. Uniqueness keeps concurrent runs at one relay from
reaching each other's publishers. It also prevents a relay cache from satisfying
a test with stale objects.

The publisher and subscriber use the same run identifier. It may be generated by
the client or supplied by the harness, but must not depend on an implementation
registry name.

## Common Case Defaults

Unless a scenario's tuple or text overrides them, the controlled publisher:

- uses effective Publisher Priority 128;
- fills every data payload with byte `0x74` (`t`);
- waits 2 milliseconds between data objects (tuple field 9 is `2`);
- sends no object extensions or delivery-timeout parameter (tuple fields 13,
  14, and 15 are `-1`, `-1`, and `0`); and
- does not generate End of Group signaling (tuple field 12 is `0`).

MoQT Test fixes the payload byte but not the Publisher Priority. This suite
requires Publisher Priority 128.

## Stimulus And Verification

A scenario defines a finite deterministic object set. It must provide enough
information to derive the expected group IDs, subgroup IDs, object IDs,
publisher priority, payload lengths, payload bytes, and final expected object
location. When the scenario terminates the subscription, it also defines the
expected PUBLISH_DONE status and whether an exact Stream Count is required.

The subscriber verifies the complete expected set. Missing, additional,
duplicated, or corrupt objects fail the test. A scenario may add assertions for
the particular property it isolates.

The controlled upstream publisher reports the exact number of streams it opens
in PUBLISH_DONE. A baseline scenario does not require the relay to report that
same exact downstream Stream Count: the relay may report its actual count after
legal representation changes or use the unknown-count sentinel. The subscriber
processes the reported number of streams when the count is exact. With the
unknown-count sentinel, it drains streams until the delivery deadline and then
decides the result from the complete object set observed.

Unless a scenario explicitly tests End of Group, pass or fail depends on the
complete set of Normal data objects, not on EOG signaling. Non-Normal status
objects are excluded from the data-object count, and their EOG representation
or boundary is not otherwise asserted by baseline scenarios. Signaling that
contradicts the delivered data remains malformed peer behavior and fails the
test independently of the EOG profile.

Test specifications distinguish required observations from permitted
variation. Unless a scenario says otherwise, these details may vary:

- QUIC stream IDs and packetization;
- scheduling and arrival order across independent streams;
- connection IDs;
- reason phrases;
- elapsed time within the scenario's deadlines.

## Timeouts And Diagnostics

Timeouts bound the test process; they are not protocol behavior unless the
scenario explicitly tests a protocol timeout. Unless overridden by a scenario,
each SETUP and namespace/subscription phase has a 5-second deadline, and object
delivery and draining have a 10-second deadline.

A client that does not implement a scenario may use the existing unsupported
test behavior. Once a client attempts it, a peer error or missing required
observation is a test failure.

## Scope

Passing a data-plane test demonstrates only the behavior in that scenario for
the observed client, relay, protocol draft, and transport. It is not a general
MoQT conformance result.
