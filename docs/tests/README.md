# Test Catalog And Contribution Process

This directory catalogs MoQT interoperability tests. The framework primarily
supports the IETF MoQ working group's efforts to demonstrate interoperability
between independent implementations and independently implemented protocol
features. Results inform that work rather than formally certifying an
implementation. Implementors may also use them as one signal when validating
their work or run some tests in their own CI.

## Current Test Inventory

Some tests in the suite predate the lifecycle labels below. They can be labeled
as participants revisit them; adding a label does not change their behavior.

| Identifier | Area | Specification |
|------------|------|---------------|
| `setup-only` | Session establishment | [TEST-CASES.md](./TEST-CASES.md#setup-only) |
| `announce-only` | Namespace discovery | [TEST-CASES.md](./TEST-CASES.md#announce-only) |
| `publish-namespace-done` | Namespace discovery | [TEST-CASES.md](./TEST-CASES.md#publish-namespace-done) |
| `subscribe-error` | Subscription | [TEST-CASES.md](./TEST-CASES.md#subscribe-error) |
| `rendezvous-timeout` | Subscription | [TEST-CASES.md](./TEST-CASES.md#rendezvous-timeout) |
| `announce-subscribe` | Subscription | [TEST-CASES.md](./TEST-CASES.md#announce-subscribe) |
| `subscribe-before-announce` | Subscription | [TEST-CASES.md](./TEST-CASES.md#subscribe-before-announce) |

## Specification Layout

`TEST-CASES.md` remains the reference for existing tests. New tests may use one
prose file per identifier under an area directory, such as
`data-plane/data-subgroup-basic.md`. Area README files define only mechanics
shared by tests in that area.

A test specification should make it possible for another implementation to
reproduce the scenario. It will usually state:

- its stable identifier, lifecycle status, and
  [test specification revision](#test-specification-revisions);
- applicable protocol drafts and normative references;
- required roles, preconditions, and controlled procedure;
- observable success criteria and permitted variation;
- timeout behavior and useful diagnostics;
- core level or profile membership, when applicable.

The prose specification is normative. Examples, implementation source, and TAP
YAML diagnostics can illustrate or report the test, but do not define it.

## Proposing A Test

A test may begin with an implementation, an issue, or a PR. Implementors are
encouraged to document useful tests here so that others can understand,
discuss, and independently implement the same scenario. Early proposals are
also welcome when writing down a scenario would help clarify protocol text or
an interoperability question.

Tests may cover the core MoQT specification or extension drafts. In either
case, the specification should identify the interoperability property, relevant
protocol text, and observable behavior. It may leave details open while they
are being discussed. As a test sees wider use, its specification should converge
on an unambiguous procedure and expected behavior that independent
implementations can reproduce.

## Test Lifecycle

The labels below organize the catalog and communicate where a test stands from
early proposal through broad adoption. As of September 2026, they do not
determine which tests the runner executes: it runs every test exposed by each
participating client. Implementors can take advantage of that behavior to try
anything they are curious about, whether or not it is cataloged here yet.

### Proposal

A proposal is a test idea that would benefit from discussion or broader
implementation. It may describe a scenario before anyone implements it, or it
may document a test that one implementation already exposes. Proposals can be
listed in area indexes to make that work visible and invite collaboration.

### Candidate

A candidate has a sufficiently clear prose specification for other
implementations to try. It will commonly describe a test already exposed by at
least one implementation, but a well-understood unimplemented scenario may
also be useful as a candidate. Results and implementation experience can then
improve the procedure, account for permitted variation, and distinguish the
intended property from setup or harness problems.

The candidate label makes promising shared work easier to find.

### Standard

A standard test recognizes a scenario that already has broad support across
diverse, independently maintained implementations. The designation helps
participants find scenarios that have proven useful for comparison over time.

Broad independent implementation is the primary signal for this label. As that
experience accumulates, the shared specification should also make clear that:

- the behavior is grounded in the applicable protocol specification;
- independently maintained implementations can execute the same procedure;
- results are reproducible across relevant clients, relays, and environments;
- failures distinguish the intended property from setup or harness problems;
- remaining permitted implementation variation is documented.

The label has no special execution behavior today. As the suite grows, standard
tests could form a bounded, regularly run set that covers essential MoQT
behavior without crowding the nightly report with every proposal and candidate.

### Retired

A retired test remains documented so that historical results can be
interpreted, but is no longer suggested for new comparisons. This will most
often happen when a test no longer applies to recent MoQT drafts or when a newer
test covers the same behavior more clearly. Its specification explains the
reason and points to any replacement. Existing result history is not rewritten.

## Support Levels And Profiles

Levels and profiles are a provisional experiment inspired by interoperability
discussions at IETF 126 in Vienna. They are intended to help organize expanding
test coverage, and feedback on the approach is welcome.

Core support levels are cumulative collections of standard tests. A coverage
summary could say that a client covers level N when it exposes every test in
that level and every lower level. Individual pass, fail, skip, and unsupported
outcomes remain separate; coverage does not imply that every test passed. The
contents of each level will be recorded here as the experiment develops.

Coverage is based on explicit evidence, such as an implementation opting into
`--list` discovery or reporting a test result. If a client does not report a
test, its support is unknown rather than unsupported.

Profiles group capabilities that are useful but do not fit a universal
progression, such as datagrams or rendezvous behavior. Reports may summarize
profile coverage independently of core levels while continuing to show each
observed outcome.

Levels and profiles offer an informational view of coverage rather than a claim
of total MoQT conformance.

## Test Specification Revisions

Each new test specification starts at revision 1. The revision is scoped to its
stable test identifier and increases when a change could alter whether an
unchanged implementation passes or fails. This includes changes to the
procedure, wire stimulus, required observations, timeout or completion
behavior, and permitted variation.

Editorial changes, corrected references, lifecycle labels, diagnostics, and
examples that do not alter required behavior keep the current revision. A
materially different interoperability property should use a new test identifier
instead of a new revision. Revisions are never reused or reset.

A client that reports [`test_spec_revision`](../TAP-YAML-METADATA.md#common-fields)
reports the revision it implemented, which may be older than the latest one in
this repository. An omitted revision is unknown; it is not assumed to be 1.

## Adding Or Changing A Test

Share whatever context is available: the protocol property being explored,
implementation experience, known unsupported cases, or open questions. If
experience is still thin, writing the test down is a good way to invite
collaboration.
