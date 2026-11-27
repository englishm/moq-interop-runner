# MPEG-TS Clock Step

| Attribute | Value |
|-----------|-------|
| Identifier | `ts-clock-step` |
| Status | Proposal |
| Proposed placement | Media profile, MPEG-TS |
| Specification revision | 1 |

## Purpose

This test verifies that a transport stream whose clock steps without warning
arrives as published. A contribution feed switching between two encoders whose
clocks are not locked does this: at one packet every PID moves onto a clock
thousands of seconds away, every continuity counter breaks once, and no packet
sets `discontinuity_indicator`. A publisher, relay or subscriber that reads
time from the stream can refuse, reorder or drop around it; an opaque
packaging should carry it untouched.

## Protocol References

As [`ts-carriage-integrity`](./ts-carriage-integrity.md#protocol-references).

## Roles And Preconditions

As
[`ts-carriage-integrity`](./ts-carriage-integrity.md#roles-and-preconditions),
with the namespace `("moq-test", "ts-clock-step", "<run-id>")` and the fixture
below.

## Fixture

`make-fixture.sh --step` writes `fixture-step.ts`: two encodes of the area's
fixture on clocks 16,844.5 s apart, spliced at one packet 10 s into a 20 s
stream, the second joining mid-GOP with a random access point 0.08 s after the
splice. The PAT and PMT are byte-identical on both sides. The generator
records the splice's packet index in the fixture's manifest,
`fixture-step.json`, which `check-ts.py` reads beside the fixture.

## Procedure

As [`ts-carriage-integrity`](./ts-carriage-integrity.md#procedure), publishing
`fixture-step.ts`, and verifying with `check-ts.py --fixture fixture-step.ts
--received received.ts --objects objects.txt --expect-step`.

## Success Criteria

The test passes when `byte-identical`, `ordering`, `packet-alignment`,
`transport-errors` and `psi-unchanged` pass as in `ts-carriage-integrity`,
and:

- `continuity`: the received stream breaks no continuity counter the fixture
  does not break, and breaks each one the fixture breaks at the splice;
- `decode`: the stream decodes from its first random access point to the
  splice, and from the second encode's first random access point to its end,
  with the frame counts the fixture predicts for each span (`--expect-step`
  makes `decode` read the two spans).

Permitted variation: as in `ts-carriage-integrity`. A packaging may start a
group at the splice.

## Failure And Timeout Behavior

As `ts-carriage-integrity`. A stream that ends at the splice, or resumes after
it with packets missing, fails `byte-identical`; one that re-stamps the second
encode's clock fails it too.

## Diagnostics

As `ts-carriage-integrity`, with the test point `ts-clock-step`, adding
`ts_step_packet` (the fixture's splice) and `ts_step_received` (where the
received stream carries it).

## Revision History

- Revision 1: Initial proposal.
