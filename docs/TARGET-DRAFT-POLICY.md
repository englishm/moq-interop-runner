# Target-Draft Policy

Canonical test specifications describe the protocol draft selected by `implementations.json.current_target`. Every canonical specification declares both its target draft and the draft for which its identifier semantics were reviewed.

## Identifier Lifecycle

Test IDs are designed for enduring RFC semantics, not coexistence among drafts. IDs must describe observable test meaning without version markers such as `d18`, `draft-18`, or `moqt18` anywhere in the name.

Retain an ID when a new target changes only section numbers or editorial placement and the test's meaning, observable behavior, applicability, and pass criteria remain equivalent. Retention requires one atomic change that updates the target declarations, exact section references, normative links, message terminology, test specifications, and vectors as needed.

If an ID's meaning, observable behavior, applicability, or pass criteria become stale or incompatible, retire it. Never reuse a retired ID for different semantics. Record the retired ID, its replacement, last-known target draft, specification revision, and reason in [tests/retired-test-identifiers.json](./tests/retired-test-identifiers.json). `replacement` is the next semantic ID, which may itself later be retired, or `null` when there is no replacement. Every non-null chain must terminate at a current active ID and must not contain a cycle.

Canonical specifications and vectors identify their target draft and specification or vector revision. Test IDs do not encode a draft or client version.

Only IDs listed in the canonical test specifications belong in the retirement registry.

`publish-without-subscriber` and `publish-to-pending-subscription` are distinct test IDs with the procedures defined in [tests/TEST-CASES.md](./tests/TEST-CASES.md).

## Target Migration Checklist

When `implementations.json.current_target` changes, review every canonical test specification and its associated vectors in the same change. That review includes:

- Protocol References
- Target-draft declarations
- Normative links
- Message terminology
- Expected outcomes
- Test vectors
- Vector and schema revisions

For every existing ID, the migration review must state one of these outcomes:

- **Retained**: semantics and pass criteria remain equivalent
- **Retired/New**: the old ID's last-valid provenance and replacement, or explicit lack of replacement, are recorded

Do not treat a mechanical draft-number replacement as sufficient. The `Identifier Semantics Reviewed For` declaration records that retention and retirement decisions were reviewed for the declared target.

## Validation

Each canonical specification must contain exactly one declaration of each form, both matching `implementations.json.current_target`:

```markdown
**Target Draft**: `draft-18`
**Identifier Semantics Reviewed For**: `draft-18`
```

Run `bun install` once, then run `make validate-target-draft`. The validator uses the pinned CommonMark parser to exclude code and HTML blocks before checking exact declarations, formal references, canonical test headings, table naming hygiene, and retirement integrity. Without the parser dependency, it accepts the repository's simple block syntax but fails closed on ambiguous comments or nested headings. Only visible `### semantic-id` headings in the primary canonical specification define active runner IDs; nested visible headings are normalized before scanning. Tables are proposals or indexes and never define active IDs or satisfy retirement replacements. The generic retirement registry permits exactly `id`, `last_known_target`, `last_known_spec_revision`, `reason`, and `replacement` in each record and is append-only; `--previous-retired FILE` requires the prior tombstone array to be an exact prefix. `--previous-spec FILE` compares only the prior primary canonical specification and requires every removed active heading ID to have a retirement tombstone. The Make target exposes these as `PREVIOUS_RETIRED=FILE` and `PREVIOUS_SPEC=FILE`. Validator maintainers can run `make test-target-draft-validator` for positive and negative regression cases.

## Validator Scope

The validator checks that the visible primary canonical specification agrees with `current_target`, uses valid and unique heading IDs, preserves or retires prior primary IDs, and maintains a well-formed append-only retirement history.

It does not execute protocol traffic or inspect client and container behavior. Semantic equivalence remains part of the target-draft review.

Additional specs can be checked for target declarations, references, heading grammar, and table naming hygiene with `SPEC_FILES="path/to/additional-spec.md"`. Additional documents cannot satisfy retirements from the primary specification.

The registration workflow runs the data-plane validator through `validate-registration.sh`. For changes outside that workflow's path filter, run both validator regression suites locally.
