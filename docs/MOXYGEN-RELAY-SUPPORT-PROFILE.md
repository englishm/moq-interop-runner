# moxygen Relay Support Profile

This is the canonical runner-side support profile for the moxygen MoQTest declarations at commit [`0d886e3e907e2236a6d927afefd09bb0c3dc8211`](https://github.com/facebookexperimental/moxygen/tree/0d886e3e907e2236a6d927afefd09bb0c3dc8211). Its current target is `draft-18`, and it is subordinate to the normative [`draft-ietf-moq-transport-18`](https://github.com/moq-wg/moq-transport/blob/cb2e772fd8ca8cbe7550b1765c269be89fb1c886/draft-ietf-moq-transport.md) source at tag commit `cb2e772fd8ca8cbe7550b1765c269be89fb1c886`.

**Target Draft**: `draft-18`

**Identifier Semantics Reviewed For**: `draft-18`

The runner is an ecosystem executable-specification harness. Its composite oracle is the normative draft prose, reviewed profiles and binding-specific deterministic vectors, and independent observations and evidence. Profiles do not replace or amend the IETF draft. A profile disposition is not proof that any implementation passed a case, and a driver vector is not normative protocol behavior.

The machine-readable authority for counts, IDs, dispositions, gates, driver bindings, provenance, result semantics, and evidence records is [`moxygen-relay-support-profile.json`](./moxygen-relay-support-profile.json). Validate it with:

```bash
make validate-moxygen-profile
./scripts/test-moxygen-profile-validator.sh
./scripts/validate-moxygen-result.sh path/to/result.json
```

Profile validation compares `profile.target_draft` with `implementations.json.current_target` when no alternate registry snapshot is supplied. Integration tooling can supply another snapshot as the third positional argument or through `TARGET_DRAFT_REFERENCE` without changing workflow permissions. The implementation-neutral base target validator checks identifiers and declarations; controlled-driver parity remains profile-specific and is enforced only by these profile validators. `validate-registration.sh` invokes that generic profile hook when this profile exists.

## Identifier Lifecycle

The profile ID and seven formal gate IDs identify enduring protocol semantics through RFC publication rather than a draft, implementation revision, or moxygen declaration ordinal. A gate-mapped source binding intentionally shares its gate's semantic test ID, allowing one behavior ID to have multiple driver bindings. The other 51 source-binding IDs are semantic inventory handles for this profile revision, not canonical executable tests; they gain enduring test-ID status only with a formal contract. A migration to later draft or RFC text retains a formal ID only when the behavior, pass criteria, and applicability remain equivalent. Pure editorial changes and section-only moves keep the ID, and every manifest, schema, binding, timeout, documentation, and result-contract reference must change atomically.

An incompatible change to protocol semantics, pass criteria, or applicability is not an editorial migration. It permanently retires the old ID, records its kind, `last_valid_target` (draft or RFC), last-valid profile revision, reason, and optional replacement in `identifier_history.retired_ids`, and introduces a new semantic ID. The retired-ID history is append-only, and retired IDs are never reused. The history is empty because the prior draft-specific profile commit was unpublished and produced no accepted ecosystem identifiers or results; this semantic migration therefore needs neither aliases nor retirement entries.

`identifier_history.reviewed_for_target` and both canonical reviewed-for declarations must equal `profile.target_draft`. The local target-reference hook enforces the same value against the runner registry, and the profile validator passes both canonical documents together to the generic base target-draft contract so cross-document active-ID collisions are evaluated in one run.

## Support Verification

`intended` and `deferred` are planning dispositions, not verified implementation support. The canonical `support_verification.state` is `unverified`: no support claim follows from the inventory, seven gate contracts, registration instructions, or an `implementations.json` entry.

Profile-wide support can move to `verified` only when `verified_at` is set; `verified_gate_ids` contains all seven gates; one `driver_binding`, relay `verified_subject`, and `verified_role` identify the covered execution subject; `pinned_implementation_revision` identifies both an immutable source revision and image digest; `result_links` contains exactly one uniquely located and digested result for every gate; and the separate `evidence_links` collection contains uniquely located and digested evidence artifacts. One successful gate result never verifies the profile. Run-specific observations remain in result records; they are linked verification inputs, not fields copied into the profile. Registration documentation and the implementation registry are scheduling/provenance inputs, never substitutes for evidence or results.

Verification is invalidated by a target-draft semantic change, a profile or gate criteria revision, an implementation revision or image change, or evidence loss/invalidation. A future `invalidated` state preserves its former coverage and evidence while requiring `invalidated_at` at or after `verified_at` and a non-empty `invalidation_reason`. Schema and jq checks enforce state consistency only; external publication tooling must still verify implementation provenance, image identity, result records, and evidence bytes.

## Reference And Executable Provenance

`reference_baselines` contains the normative draft, pinned moxygen declarations appropriate to this source profile, and runner baseline. The moq-rs review commit is instead explicit non-normative metadata under `implementation_bindings.independent_driver`; it is one specific controlled implementation binding, not an authority or privileged oracle. The neutral result field `driver_review_baseline_sha` resolves through whichever profile binding the result selects. Future implementations satisfy the same uniform `independent_driver` contract with their own binding metadata, profile evidence, executable provenance, and results.

The future moxygen conformance driver SHA and image digest, and the Rust diagnostic-gate landing SHA, are unresolved `TBD` in the manifest. Execution remains disabled until the selected binding has real provenance. An executable result record must contain the actual full driver landing SHA and image provenance; `TBD` is invalid in a result.

The future moxygen driver must honor `TLS_DISABLE_VERIFY` exactly. The reviewed baseline's unconditional insecure-verifier behavior is not acceptable executable provenance.

Result records carry the profile ID, `target_draft`, profile revision, gate revision, and exact source/executable revisions so historical interpretation never depends on an ID suffix or mutable current meaning. The selected `driver_landing_sha` must equal both publisher and subscriber deployment `source_sha`; the relay has separate provenance. Result-record `reproducibility` and `independence_class` values are submitted claims. The schema and jq validators prove only structure and internal consistency; they do not externally prove provenance, evidence integrity, or implementation independence. Publishable evaluator passes additionally require external tooling to recompute evidence SHA-256 values, verify executable/image provenance, and set both verification fields to `verified`.

## Provenance And Count Method

The inventory counts the 58 lexical `run_test` declarations in [`moxygen/moqtest/conformance_test.sh`](https://github.com/facebookexperimental/moxygen/blob/0d886e3e907e2236a6d927afefd09bb0c3dc8211/moxygen/moqtest/conformance_test.sh), including declarations inside disabled FETCH branches. The adjacent moxygen `CONFORMANCE_README.md` says 56, but that prose is stale at the pinned commit: the script declares six numbered PUBLISH cases plus two additional publish-first cases, for 58 total.

The partition is exactly:

| Disposition | Count | Meaning |
|-------------|------:|---------|
| Intended | 27 | In scope for later runner execution under this profile. Not an observed support claim. |
| Deferred | 31 | Excluded from execution and support claims in this profile revision. |

The deferred set is disjoint: 9 FETCH + 8 composite PUBLISH + 4 remaining datagram + 7 remaining explicit end-of-group/Object Status + 1 publisher delivery timeout + 2 invalid Object Property scope declarations = 31. PUBLISH cases that also use datagrams or explicit end-of-group behavior remain classified by their first blocking dependency, SUBSCRIBE_TRACKS.

## Capability Boundary

This profile does not claim support for timeout expiration, explicit end-of-group Object Status, datagrams, FETCH, SUBSCRIBE_TRACKS, or REQUEST_UPDATE. In particular:

- `Delivery timeout (500ms)` is intended only as a future non-expiring parameter-observation case. It cannot establish timeout-expiration support.
- All nine FETCH declarations are deferred.
- All eight composite PUBLISH declarations are deferred because they require SUBSCRIBE_TRACKS. The two publish-first declarations also require REQUEST_UPDATE to change Forward State.
- The four non-PUBLISH datagram declarations are deferred.
- The seven non-FETCH, non-PUBLISH declarations that request explicit end-of-group/Object Status behavior are deferred.
- `Integer extension (ID=2)` and `Both integer and variable extensions` are deferred because their generated Object Property type `0x02` is OBJECT_DELIVERY_TIMEOUT, which is Track-only for the target draft. This is a conservative scope correction, not support expansion.
- `Publisher delivery timeout (1000ms)` is deferred.

The moxygen wire-evidence binding can observe subgroup framing and FIN/reset disposition. The current controlled Rust binding observes the serve model and TRACK_ENDED, not raw subgroup header bits or FIN/reset. Neither establishes the separately deferred explicit end-of-group/Object Status cases.

## Timeouts And Driver Risk

Result timeouts are selected by gate ID and driver binding. A successful `independent_driver` result records concurrent role setup wall time as `setup_ms`, followed sequentially by `readiness_ms` at no more than 10 seconds and `delivery_terminal_ms` at no more than 10 seconds. A successful moxygen result records shared `publisher_readiness_ms` at no more than 10 seconds followed by `case_ms` at no more than its selected 10-second gate timeout. Failed, inconclusive, unsupported, or harness results may contain only the phases reached; for example, failed controlled-driver TAP may omit `delivery_terminal_ms`. Aggregate `duration_ms` may include additional orchestration and is not capped by the selected timeout, but it must be at least the sum of all recorded wall-clock phases. The intended moxygen source-case timeouts are unchanged: `subscribe-low-frequency-updates` (ordinal 44) and `subscribe-many-groups-and-objects` (ordinal 46) use 30 seconds, and the other intended source cases use 10 seconds.

The seven-gate TAP-only moxygen registration allocates 70 seconds to gate case windows, leaving 50 seconds of the runner's 120-second whole-container limit for bounded startup, readiness, transitions, TAP emission, and shutdown. Registration still requires evidence that the complete scheduled invocation finishes inside that whole-container limit. The `independent_driver` binding's seven 20-second budgets are not the moxygen registration schedule.

The reviewed moxygen baseline can report a false failure by imposing global order across independently scheduled subgroup streams. Registration requires a fixed executable SHA. Before then, an ordering-only mismatch can be retained only as manual `driver-inconclusive` evidence with evaluator verdict `inconclusive`; it is never a relay failure and the current TAP report cannot represent that state.

## Declaration Inventory

The machine manifest preserves each pinned moxygen source name and ordinal as separate fields alongside its semantic source-binding inventory handle. The exact names below remain unchanged; IDs never encode the target draft or source ordinal. Only the seven entries mapped to `required_assertion_ids` gates are canonical executable tests in this revision; the remaining 51 are inventory handles awaiting formal semantic contracts.

| Source binding | moxygen case name | Disposition | Reason |
|----|--------------------|-------------|--------|
| `subscribe-one-subgroup-per-group` | `Basic subscribe with default parameters` | Intended | Diagnostic gate |
| `subscribe-one-subgroup-per-object` | `ONE_SUBGROUP_PER_OBJECT forwarding` | Intended | Diagnostic gate |
| `subscribe-two-subgroups-per-group` | `TWO_SUBGROUPS_PER_GROUP forwarding` | Intended | Diagnostic gate |
| `subscribe-datagram-small-objects` | `DATAGRAM forwarding with small objects` | Deferred | Datagram |
| `fetch-one-subgroup-per-group` | `FETCH with ONE_SUBGROUP_PER_GROUP` | Deferred | FETCH |
| `fetch-one-subgroup-per-object` | `FETCH with ONE_SUBGROUP_PER_OBJECT` | Deferred | FETCH |
| `fetch-two-subgroups-per-group` | `FETCH with TWO_SUBGROUPS_PER_GROUP` | Deferred | FETCH |
| `fetch-datagram` | `FETCH with DATAGRAM` | Deferred | FETCH |
| `subscribe-datagram-single-object-per-group` | `Single object per group` | Deferred | Datagram |
| `subscribe-many-objects-per-group` | `Many objects per group (20)` | Intended | Subscription stream inventory |
| `subscribe-single-group-many-objects` | `Single group with 10 objects` | Intended | Subscription stream inventory |
| `subscribe-nonzero-start-group` | `Start from group 5` | Intended | Diagnostic gate |
| `subscribe-nonzero-start-object` | `Start from object 3` | Intended | Diagnostic gate |
| `subscribe-partial-group` | `Partial group (first 5 objects of 10)` | Intended | Subscription stream inventory |
| `fetch-bounded-range` | `FETCH specific range` | Deferred | FETCH |
| `fetch-single-object` | `FETCH single object` | Deferred | FETCH |
| `subscribe-tiny-objects` | `Tiny objects (10 bytes)` | Intended | Subscription stream inventory |
| `subscribe-large-first-object` | `Large object 0 (10KB)` | Intended | Subscription stream inventory |
| `subscribe-large-nonzero-objects` | `Large non-zero objects (5KB)` | Intended | Subscription stream inventory |
| `subscribe-all-large-objects` | `All large objects (8KB)` | Intended | Subscription stream inventory |
| `subscribe-mixed-sizes-two-subgroups` | `Mixed sizes with TWO_SUBGROUPS_PER_GROUP` | Intended | Subscription stream inventory |
| `subscribe-single-byte-objects` | `Single byte objects` | Intended | Subscription stream inventory |
| `fetch-large-objects` | `FETCH with large objects` | Deferred | FETCH |
| `subscribe-varied-object-sizes` | `Very different object sizes` | Intended | Subscription stream inventory |
| `subscribe-sparse-group-ids-step-two` | `Group increment of 2` | Intended | Subscription stream inventory |
| `subscribe-sparse-group-ids-step-five` | `Group increment of 5` | Intended | Subscription stream inventory |
| `subscribe-sparse-object-ids-step-two` | `Object increment of 2` | Intended | Subscription stream inventory |
| `subscribe-sparse-object-ids-step-three` | `Object increment of 3` | Intended | Subscription stream inventory |
| `subscribe-sparse-group-object-ids` | `Group and object increment of 2` | Intended | Diagnostic gate |
| `subscribe-large-group-object-id-gaps` | `Large increments (group=10, object=5)` | Intended | Subscription stream inventory |
| `subscribe-end-of-group-one-subgroup-per-group` | `End of group markers - basic` | Deferred | Explicit end-of-group/Object Status |
| `subscribe-end-of-group-one-subgroup-per-object` | `End of group markers with ONE_SUBGROUP_PER_OBJECT` | Deferred | Explicit end-of-group/Object Status |
| `subscribe-end-of-group-two-subgroups-per-group` | `End of group markers with TWO_SUBGROUPS_PER_GROUP` | Deferred | Explicit end-of-group/Object Status |
| `fetch-end-of-group` | `FETCH with end of group markers` | Deferred | FETCH |
| `subscribe-end-of-group-sparse-objects` | `End of group markers with object increment` | Deferred | Explicit end-of-group/Object Status |
| `subscribe-end-of-group-single-object` | `End of group markers with single object` | Deferred | Explicit end-of-group/Object Status |
| `subscribe-integer-property-type-two` | `Integer extension (ID=2)` | Deferred | Invalid Object Property scope (`0x02` is Track-only) |
| `subscribe-bytes-property-type-three` | `Variable extension (ID=3)` | Deferred | Datagram |
| `subscribe-integer-and-bytes-properties` | `Both integer and variable extensions` | Deferred | Invalid Object Property scope (`0x02` is Track-only) |
| `subscribe-object-properties` | `Extensions with higher IDs` | Intended | Diagnostic gate |
| `fetch-object-properties` | `FETCH with extensions` | Deferred | FETCH |
| `subscribe-object-properties-end-of-group` | `Extensions with end of group markers` | Deferred | Explicit end-of-group/Object Status |
| `subscribe-high-frequency-updates` | `High frequency updates (100ms)` | Intended | Subscription stream inventory |
| `subscribe-low-frequency-updates` | `Low frequency updates (2000ms)` | Intended | Subscription stream inventory |
| `subscribe-two-subgroups-sparse-ids-mixed-sizes-properties-end-of-group` | `Complex: All features combined` | Deferred | Explicit end-of-group/Object Status |
| `subscribe-many-groups-and-objects` | `Large scale: Many groups and objects` | Intended | Subscription stream inventory |
| `subscribe-sparse-groups-large-step` | `Sparse groups with large increment` | Intended | Subscription stream inventory |
| `subscribe-delivery-timeout` | `Delivery timeout (500ms)` | Intended | Parameter observation only; no expiration claim |
| `subscribe-publisher-delivery-timeout` | `Publisher delivery timeout (1000ms)` | Deferred | Publisher delivery timeout |
| `subscribe-datagram-rapid-delivery` | `Stress: DATAGRAM rapid delivery` | Deferred | Datagram |
| `publish-one-subgroup-per-group` | `PUBLISH with ONE_SUBGROUP_PER_GROUP` | Deferred | SUBSCRIBE_TRACKS |
| `publish-one-subgroup-per-object` | `PUBLISH with ONE_SUBGROUP_PER_OBJECT` | Deferred | SUBSCRIBE_TRACKS |
| `publish-two-subgroups-per-group` | `PUBLISH with TWO_SUBGROUPS_PER_GROUP` | Deferred | SUBSCRIBE_TRACKS |
| `publish-datagram` | `PUBLISH with DATAGRAM` | Deferred | SUBSCRIBE_TRACKS |
| `publish-end-of-group` | `PUBLISH with end of group markers` | Deferred | SUBSCRIBE_TRACKS |
| `publish-object-properties` | `PUBLISH with both extensions` | Deferred | SUBSCRIBE_TRACKS |
| `publish-before-subscribe-tracks` | `PUBLISH before SUBSCRIBE_TRACKS` | Deferred | SUBSCRIBE_TRACKS + REQUEST_UPDATE |
| `publish-before-subscribe-tracks-datagram` | `PUBLISH before SUBSCRIBE_TRACKS with DATAGRAM` | Deferred | SUBSCRIBE_TRACKS + REQUEST_UPDATE |

## Diagnostic Gates

The seven immutable runner gate IDs and revision-1 prose are in [`MOXYGEN-DIAGNOSTIC-GATES.md`](./MOXYGEN-DIAGNOSTIC-GATES.md). Each gate maps to one intended moxygen source binding, but its protocol-level semantic contract is implementation-neutral. All other intended declarations remain inventory-only in this profile revision.

Implementation diversity is a requirement, not an optimization. The moxygen binding uses moxygen `moqtest_server` and moxygen `moqtest_client` around the relay. The independent binding uses separately authored publisher fixtures, subscriber assertions, namespaces, payloads, and Rust functions. The two bindings share only the gate's protocol-level semantic criteria; they must not copy each other's generators or assertions.
