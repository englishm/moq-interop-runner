# Decision: Version Selection Strategy for Interop Pairing

**Date:** 2026-02-07

## Problem

The interop runner needs to decide which draft version to test for each (client, relay) pair. The previous implementation used a 3-phase algorithm (target, behind-target, ahead-of-target) with pair-level deduplication, which had correctness issues and was hard to reason about. More fundamentally, it tried to "select" a version for each pair, implying a degree of control the runner doesn't actually have.

## Background

### How MoQT version negotiation works

When two MoQT implementations connect, they negotiate the protocol version on the wire. The runner cannot inject a version preference into this process. In practice, the negotiated version is *expected* to be the newest draft version both sides support -- though runtime flags, endpoint-specific constraints, or implementation quirks may cause a different outcome.

This means the runner's "version selection" is really a *prediction* of what the pair will negotiate, used for labeling and filtering -- not a directive. The actual negotiated version may differ from the prediction.

### The MoQT implementation landscape

Implementations fall into a few categories with respect to version support:

- **Single-version.** Most implementations support exactly one draft version at a time. They track the latest interop target and move forward as the working group does. Their `draft_versions` array has one entry.

- **Multi-branch / multi-deployment.** Some implementations maintain separate branches or deployments for different draft versions. For example, moq-rs might have a `main` branch supporting draft-14 and a `draft-16` branch for forward-looking work. These appear as separate entries in `implementations.json`, each with their own `draft_versions`.

- **Multi-version.** A few implementations (moxygen, imquic) support multiple draft versions simultaneously in a single deployment via version negotiation. Their `draft_versions` arrays list all supported versions, though older version support may waver or eventually be dropped.

### Interop events and target versions

For each IETF interop event, there is a **target version** that implementors invest effort into for maximum interop coverage. But not all implementors attend every event, and some who have "completed" a target version move on to implementing newer drafts.

### Milestone versions

Some draft versions become de facto milestones with broad multi-implementation support (draft-07 was one; draft-14 appears to be another). This concept isn't formalized because it's in tension with the need to move forward and gain implementation experience with newer drafts to inform spec refinements.

### The goal

The ultimate goal is to get the MoQT draft to WGLC and published as an RFC, informed by as much implementation experience as possible. Interop testing serves this by identifying incompatibilities across implementations. Meanwhile, stable milestone versions with broad support benefit MoQ adoption.

## Decision

The runner uses a simple, honest model:

1. **For each (client, relay) pair, compute the newest shared draft version.** This is the predicted negotiated version. If no shared version exists, skip the pair.

2. **Classify each pair relative to the target version:** `at`, `ahead`, or `behind` (these are the values emitted in `summary.json`; displayed as "at-target", "ahead", "behind" in terminal output).

**Caveat:** `draft_versions` is declared per-implementation, but individual endpoints (remote URLs, Docker images) may not all support every listed version. The prediction assumes all endpoints of an implementation share the same version support. If this becomes a real problem, per-endpoint `draft_versions` may be needed (see Future Directions).

**Version format:** versions must follow the `draft-NN` format (e.g., `draft-14`). The runner validates `--target-version` and relies on this format for numeric sorting and classification.

3. **By default, run all pairs** that have a shared version, sorted by classification (at-target first, then ahead, then behind).

4. **Provide optional filters** (`--only-at-target`, `--only-ahead-of-target`, `--only-behind-target`) for focused test runs. A `--dry-run` flag shows the computed plan without executing.

5. **`--target-version` is metadata**, not a selection input. It sets the reference point for classification and sorting. Defaults to `current_target` in `implementations.json`.

## Alternatives Considered

### Target-priority selection (previous approach)

The 3-phase algorithm prioritized the target version, fell back to the highest shared version below target, then the lowest above target. This had two problems:

- It implied the runner was choosing which version to negotiate, when it can't.
- The fallback logic (behind then ahead) embedded a policy choice ("prefer stability over forward progress") that isn't obviously correct and doesn't match what the wire will do anyway.

### Target as hard filter

Only test pairs that share the target version, skip everything else. Simple, but discards useful interop signal. A pair testing at draft-13 still reveals real bugs. And implementations working ahead of the target provide early signal on upcoming draft versions.

### No target concept at all

Just compute newest-shared for every pair and run them all. This is close to what we chose, but loses the ability to focus a test run (e.g., "only show me draft-14 results for the interop event dashboard") or to sort results by relevance to the current event.

## Rationale

- **Matches expected wire behavior.** The computed version is what the pair is expected to negotiate. No false precision about "selecting" versions.

- **Default is maximal coverage.** Running all pairs by default means we don't miss interop signal. Filters exist for when you need to focus.

- **Classification is cheap and useful.** Knowing that a pair is behind-target or ahead-of-target is valuable for event reporting and for understanding the implementation landscape, even if it doesn't change which tests run.

- **Supports multi-deployment entries.** An implementation can have separate entries in `implementations.json` for different branches/deployments (e.g., `moq-rs` for draft-14 from main, `moq-rs-draft16` for draft-16 from a feature branch). The runner pairs them normally without special logic.

- **Separates concerns cleanly.** Pairing and version computation are always the same regardless of filters. Filtering and sorting are layered on top. This makes each piece easy to test and reason about.

## What This Means in Practice

### For the test runner

The main loop becomes: compute plan (all pairs + predicted versions + classifications), apply filters, sort, execute. The plan step is separable from execution, enabling `--dry-run`.

### For `implementations.json`

No schema changes required. The `current_target` field and per-implementation `draft_versions` arrays are sufficient. Implementations that want to test multiple draft versions can add separate entries with distinct keys.

### For interop event operators

- Default run: all pairs, sorted by relevance to target. Good for comprehensive testing.
- `--only-at-target`: focused run for the event dashboard. Fastest path to the results people care about most.
- `--dry-run`: preview which pairs will run and at which versions before committing to a full test run. Useful for event prep.
- `--only-ahead-of-target` / `--only-behind-target`: useful for generating separate result sets (e.g., slides showing forward-looking or legacy interop).

### For reporting

Each test result in `summary.json` includes the computed negotiated version and its classification relative to the target. Downstream consumers can group, filter, or visualize by classification without re-deriving it.

## Future Directions

- **Per-endpoint version overrides.** If an implementation's remote endpoints serve different versions (e.g., different subdomains for different drafts), we may need `draft_versions` at the endpoint level, not just the implementation level. Not needed yet.

- **Milestone tracking.** If the community formalizes the concept of milestone draft versions, the runner could classify pairs against multiple reference points, not just the current target. This would be a natural extension of the classification system.

- **Version negotiation verification.** If test clients gain the ability to report which version was actually negotiated (e.g., in TAP YAML diagnostics), the runner could verify its prediction against reality and flag mismatches.
