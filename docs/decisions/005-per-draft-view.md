# Decision: Per-Draft View of Interop Results

**Date:** 2026-10-17

**Status:** Proposed. An alternate view beside the existing report; the nightly
and its report are unchanged.

## Problem

The report shows one cell per client × relay pair, labelled with the draft the
pair is *predicted* to negotiate (ADR 002). Three things are lost:

1. **What actually ran.** Clients that report the negotiated version (TAP YAML
   `sessions.*.moqt_version`, [TAP YAML Metadata](../TAP-YAML-METADATA.md)) often
   negotiated something else; on 2026-10-17, 36 runs that reported a version
   differed from the prediction.
2. **Per-draft standing.** Implementations now support several drafts at once.
   A reader can't ask "who interoperates at draft-22?" without opening logs.
3. **Per-test detail.** A cell aggregates every endpoint and test into one
   count; which test failed, over which transport, needs the log.

## Decision

Add a per-draft view, generated from the same results directory as the report
(`summary.json` plus the TAP logs), by `report/v2/generate.py`:

- **Placement by reported version.** Each run sits at the draft its client
  reported negotiating, otherwise at the prediction, marked as predicted.
- **Per-test rows.** Each run carries its tests (`id`, `status`, message,
  negotiated version). IDs that implementations spell differently map to the
  catalog through `report/v2/aliases.json`.
- **One pill per endpoint.** A cell lists every run of the pair (docker or
  public endpoint, native QUIC or WebTransport) with its own pass count.
- **Three views:** by draft (client × relay matrix), by implementation (its
  pairings by draft, as client and as relay), and open relays (each public
  endpoint against every client). Any cell opens the test-by-endpoint table
  with links to the logs.
- **Self-contained output.** `index.html` embeds its data; `data.json` holds
  the same model for other consumers.

`v2-preview.yml` renders the newest published nightly on each PR that touches
`report/v2/` and links the preview from the PR. It runs no tests.

## Consequences

- The view is only as good as the version reporting: clients that report no
  negotiated version stay at the prediction. Adopting
  `sessions.*.moqt_version` is the way to move them.
- It does not add coverage. A pair still negotiates one draft per run.

## Confined Per-Draft Runs

A pair that shares several drafts negotiates one per run, so the nightly shows
it at one draft only. `run-interop-pinned.sh` runs every docker client × relay
pair once per even draft both sides register, confining each side where its
registration says how:

- **`confine.images`:** a separate image per draft;
- **a single registered draft:** the image is already confined;
- **`confine.env` / `confine.args`:** rendered with `${MOQT_DRAFT}` (`draft-NN`)
  and `${MOQT_DRAFT_NUM}` (`NN`) into a compose override for that run.

A side with none of these runs as registered. Pairs are never dropped: each
run records `confined` (`both`, `client`, `relay` or `none`), and a pinned relay
leaves an unconfinable client one draft to negotiate. The client's reported
version checks each run: **verified** when it matches the pinned draft,
**mismatch** when it doesn't, **unreported** when the client reports nothing.

The docker matrix uses these runs when present; open relays still come from
the nightly. The preview workflow runs them per relay on the `vpm-real` label
or a `run_pinned` dispatch and stores them for later renders.

## Next Steps

- **More suites.** A suites registry (pinned version, adapter image, ID
  namespace, topology) so existing suites run unmodified: the moq-test
  conformance suite (76 cases), and publisher conformance from
  mondain/moq-contribution-interop-runner (MUST/MUST NOT rows per draft).
