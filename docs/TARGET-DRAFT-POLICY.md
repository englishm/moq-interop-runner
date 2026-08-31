# Target-Draft Policy

Canonical test specifications describe the protocol draft selected by `implementations.json.current_target`. Every canonical specification declares both its target draft and the draft for which its identifier semantics were reviewed.

## Identifier Lifecycle

Test IDs are designed for enduring RFC semantics, not coexistence among drafts. IDs and corresponding public function names must describe observable test meaning without version markers such as `d18`, `draft-18`, or `moqt18` anywhere in the name.

Retain an ID when a new target changes only section numbers or editorial placement and the test's meaning, observable behavior, applicability, and pass criteria remain equivalent. Retention requires one atomic change that updates the target declarations, exact section references, normative links, message terminology, test vectors, and support manifests as needed.

If an ID's meaning, observable behavior, applicability, or pass criteria become stale or incompatible, retire it. Never reuse a retired ID for different semantics. Introduce a new semantic ID and record the retired ID, its replacement, its last-known target draft, profile revision, implementation source, commit, and image digest in [tests/retired-test-identifiers.json](./tests/retired-test-identifiers.json). Record unavailable legacy provenance explicitly as `unknown`; do not imply that it was captured. A retired ID is a tombstone, not an alias, and test clients must not emit it as a new canonical result.

Historical results record provenance as metadata. Each result set must identify the explicit target draft, profile revision, runner commit, driver commit, and image digest. Consumers must use that metadata rather than infer or parse a draft from an ID.

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
- **Retired/New**: the old ID's last-valid provenance and replacement are recorded, and a new semantic ID is introduced when applicable

Do not treat a mechanical draft-number replacement as sufficient. Automation cannot decide semantic equivalence. The `Identifier Semantics Reviewed For` declaration is a human- or agent-reviewed gate attesting that these retention and retirement decisions were made for the declared target.

## Validation

Each canonical specification must contain exactly one declaration of each form, both matching `implementations.json.current_target`:

```markdown
**Target Draft**: `draft-18`
**Identifier Semantics Reviewed For**: `draft-18`
```

Run `make validate-target-draft`. The validator removes HTML comments and fenced code examples before checking exact declarations, canonical heading and first-column table IDs, external Rust `test_*` function identifiers, formal references, and retirement integrity. Commented or fenced declarations, IDs, functions, and replacement headings are not active. Malformed or decorated definition attempts fail instead of being ignored. The registry has an explicit format version and a stable full-record pin for its initial tombstones. Existing tombstones are immutable and the registry is append-only; `--previous-retired FILE` requires the prior tombstone array to be an exact prefix, and the Make target accepts the same path as `PREVIOUS_RETIRED=FILE`. The validator does not interpret normative target prose or links as public identifiers, and it cannot verify the semantic-equivalence judgment attested by the review declaration. Validator maintainers can run `make test-target-draft-validator` for positive and negative regression cases.

Stacked profiles can include their canonical specs with `make validate-target-draft SPEC_FILES="path/to/profile-spec.md"` or by passing files directly to `scripts/validate-target-draft.sh`.

The existing registration workflow runs when `implementations.json` (including `current_target`), `implementations.schema.json`, or `validate-registration.sh` changes. A registration-wrapper change therefore exercises this validator. The wrapper also passes the prior retirement snapshot for append-only comparison when `--base` contains one. The workflow does not cover spec-only, validator-only, or retirement-registry-only changes. Because its path scope cannot be expanded with the current GitHub App permission, those contributors must run `make validate-target-draft` and `make test-target-draft-validator`; do not assume broader CI coverage.
