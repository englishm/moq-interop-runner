# Decision: Version-Pinned Interop Matrix

**Date:** 2026-06-27

**Status:** Accepted (supersedes the reporting/classification aspects of
[002-version-selection-strategy](002-version-selection-strategy.md); the
"negotiation is a prediction" premise of 002 still holds on the wire).

## Problem

The current matrix tests **one cell per (client, relay) pair**, at the version
the pair is predicted to negotiate (the newest shared draft). This has two
costs:

1. **Coverage gaps.** Two implementations that both support draft-14 *and*
   draft-16 are only ever tested at draft-16. Their draft-14 interop — often a
   stable milestone with broad support — is never exercised.
2. **Reporting strain.** As implementations support more drafts simultaneously,
   a single matrix cell has to represent multiple version outcomes. The
   considered fix (N "pills" per cell) clutters quickly and doesn't scale.

It also forces a `current_target` notion and an `at`/`ahead`/`behind`
classification that exist *only* because we compare a negotiated version to a
moving target.

## Decision

Test and display the matrix **per draft version**.

- **Unit of test:** a pinned pairing `(client@D, relay@D)` for each draft `D`,
  rather than one negotiated cell per pair.
- **Display:** a **draft-selector dropdown**. Each selection renders one clean
  `client × relay` matrix for that single draft. No pills, no per-cell version
  ambiguity.
- **Drop `current_target` and the `at`/`ahead`/`behind` classification.** With a
  fixed draft per page, classification is meaningless. The related code in
  `run-interop-tests.sh` and `generate-report.sh` is removed.

### Coverage model: hybrid (pin-one-side, else N/A)

The runner cannot change wire negotiation (per ADR 002), but it **can constrain
what a side advertises** via registration config (a version-specific image, or a
switch/env that pins the advertised draft list).

To test `(A, B)` at draft `D`, we only need **one** side constrained to
advertise *only* `D`; a switchless peer that also supports `D` will negotiate
down to it. Therefore:

- A pairing is **runnable at D** if at least one side can be constrained to `D`
  (or both naturally negotiate `D`).
- Otherwise the cell is **N/A** — shown honestly, not hidden.

This maximizes coverage without requiring every implementation to add a
version switch.

### Implementation tiers (migration)

- **Tier 1 — version-specific images (trivial).** Implementations that already
  ship per-draft images (e.g. `moq-rs-draft-16`, `moq-rs-draft-18`) migrate
  directly: one registration entry per draft.
- **Tier 2 — pin switch (templated).** Implementations with a flag/env to pin
  the advertised draft (e.g. moqx `--moqt-versions 16`): one image plus
  per-version args/env.
- **Tier 3 — no switch.** Cannot be constrained. Still reachable at draft `D`
  whenever their partner can be pinned to `D`; otherwise N/A on that page.

### Registration schema (additive, backward-compatible)

Add per-role `versions` and (optional) `peer_overrides` maps. Keep the existing
`draft_versions` + single `docker.image` as the negotiated/default fallback
during migration. Per-layer config carries an optional `image`, a `flags` map
(switch → value), and an `env` map:

```jsonc
"roles": {
  "relay": {
    "docker": { "image": "..." },                              // base layer
    "flags":  { "--port": "4433" },
    "versions": {
      "draft-16": { "flags": { "--moqt-versions": "16" },
                    "remote": [ /* version-pinned endpoints */ ] },
      "draft-18": { "image": "...:draft-18" }                  // image-pinned (no flag needed)
    },
    "peer_overrides": {                                        // this relay, facing a given client
      "moxygen":          { "flags": { "--compat-moxygen": true } },   // any draft
      "moxygen@draft-14": { "env":   { "MOQ_QUIRK": "1" } }            // peer + draft
    }
  }
}
```

`flags` is a **map** (not a list) so merge is well-defined; bare flags use
`true`, repeatable flags use a list. `implementations.schema.json` (and the
PR-CI validator from PR #3) are updated to accept and check `versions` /
`peer_overrides`.

### Override resolution

For a given `(my role, peer, draft)`, resolve the effective config by layering,
shallow → deep:

`base` → `versions[draft]` → `peer_overrides[peer]` → `peer_overrides[peer@draft]`

- **image:** the deepest layer that specifies one wins (image-pinning).
- **flags:** maps are merged — for the **same switch**, the deepest layer wins;
  **different switches accumulate** (additive). Rendered to CLI args at launch
  (`true` → bare flag, scalar → `--k v`, list → repeated).
- **env:** merged key-wise, deepest wins.

**Directionality:** overrides are declared by an implementation and apply only to
its own container. For test `(client A → relay B)@D`: **A** resolves its
*client*-side config facing relay B@D; **B** resolves its *relay*-side config
facing client A@D. "When X talks to me as a relay…" and "when I talk to Y as a
client…" are just the relay-side and client-side views of one override map. Most
implementations declare none of this — base config is enough; the layers exist
for the long tail of pairwise compat quirks.

### Execution and the `MOQT_DRAFT` convention

The runner resolves each side's `{image, flags, env}` and injects it into the
container. There are two layered, equivalent ways to confine a multi-version
implementation to draft D — both supported:

1. **Explicit per-draft entries.** `versions[draft-D]` carries the concrete
   image/env/flags for D (e.g. moqx's `MOQX_MOQT_VERSIONS`). The container
   receives the resolved value directly; nothing to translate. Best when drafts
   genuinely differ (a different image, a per-draft endpoint).
2. **The `MOQT_DRAFT` convention.** The runner *always* injects
   `MOQT_DRAFT=draft-D` and `MOQT_DRAFT_NUM=D`. An impl that would rather not
   enumerate drafts can either (a) have its entrypoint translate `MOQT_DRAFT_NUM`
   to its own flag in shell (`--advertise draft-$MOQT_DRAFT_NUM`), or (b) put a
   `${MOQT_DRAFT_NUM}` placeholder in a registration env/flag value, which the
   runner expands at resolution time.

Image-pinned single-version impls (the moq-rs draft family, etc.) need none of
this — the image *is* the draft. `MOQT_DRAFT` is a convenience/fallback, never a
requirement; an explicit `versions[D]` value wins where specified.

### Version confinement & negotiated-version verification

Placing a result on draft-D's page asserts the test negotiated D. The runner
cannot change wire negotiation, only what a side *advertises*:

- **Forcing D requires ≥1 side to advertise only D.** For a multi-version
  *remote* relay (whose advertised set we don't control), that side must be the
  **client** — so a multi-version client needs an advertise-only mechanism (a
  `versions[D]` entry or a `MOQT_DRAFT` translation) to be testable at non-max
  drafts against such relays.
- **Verify, don't assume.** The test client must report the *actually negotiated*
  version (a required field of the test-client interface), and the runner places
  each result on the page of that version — never the intended one. A run meant
  for D that negotiates 16 lands on the 16 page (or is flagged), never mislabeled.
- **Honest N/A.** If neither side can confine to D, that cell is N/A for
  *intentional* coverage; the pair may still appear on its natural negotiated page
  via verification.

This keeps the per-draft matrix sound regardless of whether pinning "took," and
tells implementers exactly what capability buys coverage: a client-side
advertise-only knob unlocks chosen-draft testing against multi-version remotes.

### Relay state isolation

A stateful relay must not serve more than one test — or more than one draft — at
a time (risk of test-to-test state corruption: leftover tracks, subscriptions,
namespaces).

- **Docker mode** already starts a **fresh relay container per test**, so it is
  safe and is the model for per-version testing (a pinned relay instance per
  draft).
- **Shared remote endpoints** are the pre-existing hazard; version-pinning
  sharpens it (one live remote can't be pinned to two drafts at once).
  Remote pairings stay **sequential per endpoint**, and version-pinned remotes
  must be **separate instances/ports** per draft.

### Reporting / cell display

- **One result set per cell.** With the page fixed to a single draft, a cell is
  just `(client, relay)` at that draft — no version pills, and the per-cell
  draft-number superscript is removed (redundant).
- **No-pairing cells are blank (`—`)**, kept distinct from **`SKIP`**, which is
  reserved for pairings that exist but were *explicitly* skipped (image
  unavailable / notation).
- **Transport is the cell's sub-dimension.** A pairing is exercised over raw
  QUIC (`moqt://`) and/or HTTP/3 WebTransport (`https://`) — a relay may register
  both — so the cell shows **per-transport pills** (e.g. `QUIC 12/12 · WT 12/12`)
  rather than a blended total. Transport-pills are bounded (≤ ~3), unlike the
  rejected version-pills. The aggregate max is the sum over transports
  (both transports at N tests each → 2N). For remote-endpoint cases the pill
  reflects the chosen transport per endpoint.

## Consequences

**Positive**
- Full version coverage, including stable milestone drafts.
- Clean, scalable browsing (one matrix per draft) — replaces the pills idea.
- Removes `current_target`/classification complexity.
- **Draft becomes a natural parallelization shard key** (version, or
  version × relay), and pinning removes the negotiated-version ambiguity that
  complicated relay-sharding — so this *simplifies* the parallelization work.

**Negative / costs**
- A real `implementations.json` schema migration and per-impl registration work
  (graded by tier above).
- More total test runs (the pinned cross-product is larger than one-cell-per-pair),
  mitigated by parallelizing across drafts.
- Tier-3 implementations show N/A cells on non-default draft pages until a
  partner pins.

## Roadmap impact

This **precedes and redefines** the matrix-parallelization work (the shard key
becomes the draft, not the relay), **replaces** the multi-version-pills work, and
**feeds** the results-browsing redesign (the dropdown is the browse mechanism).

Phased plan:
1. Schema + validator support for the `versions` map (backward compatible).
2. Migrate Tier-1 (version-specific-image) registrations.
3. Reporter: per-draft pages + dropdown; remove target/classification.
4. Parallelize by draft (× relay), with per-version relay isolation.
