# MPEG-TS Multiple Programs

| Attribute | Value |
|-----------|-------|
| Identifier | `ts-multi-program` |
| Status | Proposal |
| Proposed placement | Media profile, MPEG-TS |
| Specification revision | 1 |

## Purpose

This test verifies that a multiplex of several programs, each with its own PMT
and its own clock, arrives whole. A distribution feed carries several
services; a packaging that reads only the first PMT, or one clock, loses the
others.

## Protocol References

As [`ts-carriage-integrity`](./ts-carriage-integrity.md#protocol-references).

## Roles And Preconditions

As
[`ts-carriage-integrity`](./ts-carriage-integrity.md#roles-and-preconditions),
with the namespace `("moq-test", "ts-multi-program", "<run-id>")` and the
fixture below, published as one track of the whole multiplex.

## Fixture

`make-fixture.sh --mpts` writes `fixture-mpts.ts`: three programs, 20 s, one
PAT listing three PMTs. Program 1 is the area's fixture; program 2 is video
only; program 3 is video and audio on a clock unrelated to the other two (its
PCR starts near 3 s where program 1's starts near 25,630 s). TSDuck's `merge`
builds it, so the image needs TSDuck at build time as `check-ts.py` already
does at run time.

## Procedure

As [`ts-carriage-integrity`](./ts-carriage-integrity.md#procedure), publishing
`fixture-mpts.ts`, and verifying with `check-ts.py --fixture fixture-mpts.ts
--received received.ts --objects objects.txt --programs 3`.

## Success Criteria

The test passes when `byte-identical`, `ordering`, `packet-alignment`,
`transport-errors` and `continuity` pass as in `ts-carriage-integrity`, and:

- `psi-unchanged`: the PAT and all three PMTs equal the fixture's;
- `decode`: each program decodes from its first random access point with the
  frame counts the fixture predicts (`--programs 3` makes `decode` read each
  program alone).

Permitted variation: as in `ts-carriage-integrity`. Per-program tracks are out
of scope: they need a packaging both sides read.

## Failure And Timeout Behavior

As `ts-carriage-integrity`. A stream carrying only the first program fails
`psi-unchanged` and `byte-identical`.

## Diagnostics

As `ts-carriage-integrity`, with the test point `ts-multi-program`, adding
`ts_programs` (the program numbers found) and per-program `ts_decoded_frames`.

## Revision History

- Revision 1: Initial proposal.
