# Target-Draft Policy

Canonical test specifications describe the protocol draft selected by `implementations.json.current_target`. Every canonical specification declares both its target draft and the draft for which its identifier semantics were reviewed.

## Identifier Lifecycle

Test IDs are designed for enduring RFC semantics, not coexistence among drafts. IDs must describe observable test meaning without version markers such as `d18`, `draft-18`, or `moqt18` anywhere in the name.

Retain an ID when a new target changes only section numbers or editorial placement and the test's meaning, observable behavior, applicability, and pass criteria remain equivalent. Retention requires one atomic change that updates the target declarations, exact section references, normative links, message terminology, test vectors, and support manifests as needed.

If an ID's meaning, observable behavior, applicability, or pass criteria become stale or incompatible, retire it. Never reuse a retired ID for different semantics. Record the runner-owned retired ID, its replacement, last-known target draft, profile revision, and reason in [tests/retired-test-identifiers.json](./tests/retired-test-identifiers.json). `replacement` is the next semantic ID, which may itself later be retired, or `null` when there is explicitly no replacement. Every non-null chain must terminate at a current active ID and must not contain a cycle. A retired ID is a tombstone, not an alias, and must not count as a new canonical result. Runtime TAP/result-parser quarantine for retired IDs is a follow-up; this policy change does not add that runtime enforcement.

Canonical profile and result artifacts require the explicit target draft, profile revision, runner commit, driver commit, and image digest. Legacy aggregate runner output does not yet satisfy that provenance contract and must not be described as fully reproducible. Adding complete runtime provenance is a follow-up, not present behavior. Consumers must not infer a draft or provenance from an ID.

Implementation-specific parity and retirement belong in the implementation's own repository or in an optional, uniformly defined driver profile. Implementation-local names that were never canonical runner IDs do not belong in the runner retirement registry.

`publish-without-subscriber` and `publish-to-pending-subscription` are new runner-owned semantic specifications. They are not runner aliases or replacements for implementation-local identifiers.

## Target Migration Checklist

When `implementations.json.current_target` changes, review every canonical test specification and its associated support metadata in the same change. That review includes:

- Protocol References
- Target-draft declarations
- Normative links
- Message terminology
- Expected outcomes
- Test vectors
- Test-client support manifests

For every existing ID, the migration review must state one of these outcomes:

- **Retained**: semantics and pass criteria remain equivalent
- **Retired/New**: the old ID's last-valid provenance and replacement, or explicit lack of replacement, are recorded

Do not treat a mechanical draft-number replacement as sufficient. Automation cannot decide semantic equivalence. The `Identifier Semantics Reviewed For` declaration is a human- or agent-reviewed gate attesting that these retention and retirement decisions were made for the declared target.

## Validation

Each canonical specification must contain exactly one declaration of each form, both matching `implementations.json.current_target`:

```markdown
**Target Draft**: `draft-18`
**Identifier Semantics Reviewed For**: `draft-18`
```

Run `make validate-target-draft`. The validator removes HTML comments and fenced code examples before checking exact declarations, formal references, canonical test headings, table naming hygiene, and retirement integrity. Only visible `### semantic-id` headings in the primary canonical specification define active runner IDs; Markdown permits zero to three leading spaces. Tables are proposals or indexes and never define active IDs or satisfy retirement replacements. The generic retirement registry permits exactly `id`, `last_known_target`, `last_known_profile_revision`, `reason`, and `replacement` in each record and is append-only; `--previous-retired FILE` requires the prior tombstone array to be an exact prefix. `--previous-spec FILE` compares only the prior primary canonical specification and requires every removed active heading ID to have a retirement tombstone. The Make target exposes these as `PREVIOUS_RETIRED=FILE` and `PREVIOUS_SPEC=FILE`. Validator maintainers can run `make test-target-draft-validator` for positive and negative regression cases.

## Proof Boundary

The validator proves only that the visible runner-owned primary canonical specification agrees with `current_target`, uses valid and unique heading IDs, preserves or retires prior primary IDs, and maintains a well-formed append-only runner retirement history.

It does not prove:

- Implementation source parity with a canonical test
- Test CLI availability or identifier support
- Wire behavior or interoperability
- Protocol conformance
- Container image identity or provenance

Automation also cannot determine semantic equivalence; the review declaration remains a human- or agent-reviewed gate.

Additional specs can still be checked for target declarations, references, heading grammar, and table naming hygiene with `SPEC_FILES="path/to/profile-spec.md"`. Their lifecycle and implementation parity require the profile's own uniform validator; additional profiles cannot satisfy primary runner retirements.

The existing registration workflow runs when `implementations.json` (including `current_target`), `implementations.schema.json`, or `validate-registration.sh` changes. A registration-wrapper change therefore exercises this validator. The wrapper passes prior retirement and canonical-spec snapshots from `--base` when present. The workflow does not cover spec-only, validator-only, or retirement-registry-only changes. Because its path scope cannot be expanded with the current GitHub App permission, those contributors must run `make validate-target-draft` and `make test-target-draft-validator`; do not assume broader CI coverage.
