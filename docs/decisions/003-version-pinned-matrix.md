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

### Execution (entrypoint/env convention)

For pinned + overridden runs to actually execute, the runner resolves each side's
`{image, flags, env}` and injects it into the container. Image-pinned impls
(e.g. the moq-rs draft family) need nothing more. Flag/env-pinned impls rely on a
small container convention: the entrypoint honors injected extra args/env
(carried via the compose file as e.g. `RELAY_EXTRA_ARGS` / `CLIENT_EXTRA_ARGS`
plus passthrough env). This is the "when everyone gets on board" surface; the POC
wires the runner end-to-end and migrates a subset whose containers already honor
pinning, so it both *looks* and *runs* like the target state.

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
