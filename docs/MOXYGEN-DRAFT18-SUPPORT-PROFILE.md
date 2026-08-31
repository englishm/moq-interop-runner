# moxygen Draft-18 Support Profile

This is the canonical runner-side support profile for the moxygen MoQTest declarations at commit [`0d886e3e907e2236a6d927afefd09bb0c3dc8211`](https://github.com/facebookexperimental/moxygen/tree/0d886e3e907e2236a6d927afefd09bb0c3dc8211). It is subordinate to the normative [`draft-ietf-moq-transport-18`](https://github.com/moq-wg/moq-transport/blob/cb2e772fd8ca8cbe7550b1765c269be89fb1c886/draft-ietf-moq-transport.md) source at tag commit `cb2e772fd8ca8cbe7550b1765c269be89fb1c886`.

The runner is an ecosystem executable-specification harness. Its composite oracle is the normative draft prose, reviewed profiles and binding-specific deterministic vectors, and independent observations and evidence. Profiles do not replace or amend the IETF draft. A profile disposition is not proof that any implementation passed a case, and a driver vector is not normative protocol behavior.

The machine-readable authority for counts, IDs, dispositions, gates, driver bindings, provenance, result semantics, and evidence records is [`moxygen-draft18-support-profile.json`](./moxygen-draft18-support-profile.json). Validate it with:

```bash
make validate-moxygen-draft18-profile
./scripts/test-moxygen-draft18-profile-validator.sh
./scripts/validate-moxygen-draft18-result.sh path/to/result.json
```

## Reference And Executable Provenance

The pinned moxygen `0d886e3e907e2236a6d927afefd09bb0c3dc8211` and moq-rs `b01d3f6707e3a74f69905722b451a08cbb3364f3` commits are reviewed declaration/reference baselines. They are not executable driver revisions for this profile.

The future moxygen conformance driver SHA and image digest, and the Rust diagnostic-gate landing SHA, are unresolved `TBD` in the manifest. Execution remains disabled until the selected binding has real provenance. An executable result record must contain the actual full driver landing SHA and image provenance; `TBD` is invalid in a result.

The future moxygen driver must honor `TLS_DISABLE_VERIFY` exactly. The reviewed baseline's unconditional insecure-verifier behavior is not acceptable executable provenance.

Result-record `reproducibility` and `independence_class` values are submitted claims. Schema and jq validators check structure and internal consistency only. Publishable evaluator passes additionally require external tooling to recompute evidence SHA-256 values, verify executable/image provenance, and set both verification fields to `verified`.

## Provenance And Count Method

The inventory counts the 58 lexical `run_test` declarations in [`moxygen/moqtest/conformance_test.sh`](https://github.com/facebookexperimental/moxygen/blob/0d886e3e907e2236a6d927afefd09bb0c3dc8211/moxygen/moqtest/conformance_test.sh), including declarations inside disabled FETCH branches. The adjacent moxygen `CONFORMANCE_README.md` says 56, but that prose is stale at the pinned commit: the script declares six numbered PUBLISH cases plus two additional publish-first cases, for 58 total.

The partition is exactly:

| Disposition | Count | Meaning |
|-------------|------:|---------|
| Intended | 29 | In scope for later runner execution under this profile. Not an observed support claim. |
| Deferred | 29 | Excluded from execution and support claims in this profile revision. |

The deferred set is disjoint: 9 FETCH + 8 composite PUBLISH + 4 remaining datagram + 7 remaining explicit end-of-group/Object Status + 1 publisher delivery timeout = 29. PUBLISH cases that also use datagrams or explicit end-of-group behavior remain classified by their first blocking dependency, SUBSCRIBE_TRACKS.

## Capability Boundary

This profile does not claim support for timeout expiration, explicit end-of-group Object Status, datagrams, FETCH, SUBSCRIBE_TRACKS, or REQUEST_UPDATE. In particular:

- `Delivery timeout (500ms)` is intended only as a future non-expiring parameter-observation case. It cannot establish timeout-expiration support.
- All nine FETCH declarations are deferred.
- All eight composite PUBLISH declarations are deferred because they require SUBSCRIBE_TRACKS. The two publish-first declarations also require REQUEST_UPDATE to change Forward State.
- The four non-PUBLISH datagram declarations are deferred.
- The seven non-FETCH, non-PUBLISH declarations that request explicit end-of-group/Object Status behavior are deferred.
- `Publisher delivery timeout (1000ms)` is deferred.

The moxygen wire-evidence binding can observe subgroup framing and FIN/reset disposition. The current Rust binding observes the serve model and TRACK_ENDED, not raw subgroup header bits or FIN/reset. Neither establishes the separately deferred explicit end-of-group/Object Status cases.

## Timeouts And Driver Risk

Timeouts are selected per case from the manifest. The moxygen binding starts its case timeout after publisher readiness. The independent Rust binding starts its gate timeout immediately before SUBSCRIBE and includes exact-track routing. The seven diagnostic gates use 10 seconds. Intended cases 044 (`Low frequency updates (2000ms)`) and 046 (`Large scale: Many groups and objects`) use 30 seconds; other intended cases use 10 seconds. Every per-case timeout remains below the runner's 120-second whole-container limit.

The reviewed moxygen baseline can report a false failure by imposing global order across independently scheduled subgroup streams. Registration requires a fixed executable SHA. Before then, an ordering-only mismatch can be retained only as manual `driver-inconclusive` evidence with evaluator verdict `inconclusive`; it is never a relay failure and the current TAP report cannot represent that state.

## Declaration Inventory

Names and ordinals below reproduce the pinned moxygen declarations exactly. `MOXYGEN-D18-CASE-NNN` is a profile-local source-binding handle. It is not an immutable runner gate ID and does not name normative protocol behavior.

| Source binding | moxygen case name | Disposition | Reason |
|----|--------------------|-------------|--------|
| `MOXYGEN-D18-CASE-001` | `Basic subscribe with default parameters` | Intended | Diagnostic gate 001 |
| `MOXYGEN-D18-CASE-002` | `ONE_SUBGROUP_PER_OBJECT forwarding` | Intended | Diagnostic gate 002 |
| `MOXYGEN-D18-CASE-003` | `TWO_SUBGROUPS_PER_GROUP forwarding` | Intended | Diagnostic gate 003 |
| `MOXYGEN-D18-CASE-004` | `DATAGRAM forwarding with small objects` | Deferred | Datagram |
| `MOXYGEN-D18-CASE-005` | `FETCH with ONE_SUBGROUP_PER_GROUP` | Deferred | FETCH |
| `MOXYGEN-D18-CASE-006` | `FETCH with ONE_SUBGROUP_PER_OBJECT` | Deferred | FETCH |
| `MOXYGEN-D18-CASE-007` | `FETCH with TWO_SUBGROUPS_PER_GROUP` | Deferred | FETCH |
| `MOXYGEN-D18-CASE-008` | `FETCH with DATAGRAM` | Deferred | FETCH |
| `MOXYGEN-D18-CASE-009` | `Single object per group` | Deferred | Datagram |
| `MOXYGEN-D18-CASE-010` | `Many objects per group (20)` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-011` | `Single group with 10 objects` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-012` | `Start from group 5` | Intended | Diagnostic gate 004 |
| `MOXYGEN-D18-CASE-013` | `Start from object 3` | Intended | Diagnostic gate 005 |
| `MOXYGEN-D18-CASE-014` | `Partial group (first 5 objects of 10)` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-015` | `FETCH specific range` | Deferred | FETCH |
| `MOXYGEN-D18-CASE-016` | `FETCH single object` | Deferred | FETCH |
| `MOXYGEN-D18-CASE-017` | `Tiny objects (10 bytes)` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-018` | `Large object 0 (10KB)` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-019` | `Large non-zero objects (5KB)` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-020` | `All large objects (8KB)` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-021` | `Mixed sizes with TWO_SUBGROUPS_PER_GROUP` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-022` | `Single byte objects` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-023` | `FETCH with large objects` | Deferred | FETCH |
| `MOXYGEN-D18-CASE-024` | `Very different object sizes` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-025` | `Group increment of 2` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-026` | `Group increment of 5` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-027` | `Object increment of 2` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-028` | `Object increment of 3` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-029` | `Group and object increment of 2` | Intended | Diagnostic gate 006 |
| `MOXYGEN-D18-CASE-030` | `Large increments (group=10, object=5)` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-031` | `End of group markers - basic` | Deferred | Explicit end-of-group/Object Status |
| `MOXYGEN-D18-CASE-032` | `End of group markers with ONE_SUBGROUP_PER_OBJECT` | Deferred | Explicit end-of-group/Object Status |
| `MOXYGEN-D18-CASE-033` | `End of group markers with TWO_SUBGROUPS_PER_GROUP` | Deferred | Explicit end-of-group/Object Status |
| `MOXYGEN-D18-CASE-034` | `FETCH with end of group markers` | Deferred | FETCH |
| `MOXYGEN-D18-CASE-035` | `End of group markers with object increment` | Deferred | Explicit end-of-group/Object Status |
| `MOXYGEN-D18-CASE-036` | `End of group markers with single object` | Deferred | Explicit end-of-group/Object Status |
| `MOXYGEN-D18-CASE-037` | `Integer extension (ID=2)` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-038` | `Variable extension (ID=3)` | Deferred | Datagram |
| `MOXYGEN-D18-CASE-039` | `Both integer and variable extensions` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-040` | `Extensions with higher IDs` | Intended | Diagnostic gate 007 |
| `MOXYGEN-D18-CASE-041` | `FETCH with extensions` | Deferred | FETCH |
| `MOXYGEN-D18-CASE-042` | `Extensions with end of group markers` | Deferred | Explicit end-of-group/Object Status |
| `MOXYGEN-D18-CASE-043` | `High frequency updates (100ms)` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-044` | `Low frequency updates (2000ms)` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-045` | `Complex: All features combined` | Deferred | Explicit end-of-group/Object Status |
| `MOXYGEN-D18-CASE-046` | `Large scale: Many groups and objects` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-047` | `Sparse groups with large increment` | Intended | Subscription stream inventory |
| `MOXYGEN-D18-CASE-048` | `Delivery timeout (500ms)` | Intended | Parameter observation only; no expiration claim |
| `MOXYGEN-D18-CASE-049` | `Publisher delivery timeout (1000ms)` | Deferred | Publisher delivery timeout |
| `MOXYGEN-D18-CASE-050` | `Stress: DATAGRAM rapid delivery` | Deferred | Datagram |
| `MOXYGEN-D18-CASE-051` | `PUBLISH with ONE_SUBGROUP_PER_GROUP` | Deferred | SUBSCRIBE_TRACKS |
| `MOXYGEN-D18-CASE-052` | `PUBLISH with ONE_SUBGROUP_PER_OBJECT` | Deferred | SUBSCRIBE_TRACKS |
| `MOXYGEN-D18-CASE-053` | `PUBLISH with TWO_SUBGROUPS_PER_GROUP` | Deferred | SUBSCRIBE_TRACKS |
| `MOXYGEN-D18-CASE-054` | `PUBLISH with DATAGRAM` | Deferred | SUBSCRIBE_TRACKS |
| `MOXYGEN-D18-CASE-055` | `PUBLISH with end of group markers` | Deferred | SUBSCRIBE_TRACKS |
| `MOXYGEN-D18-CASE-056` | `PUBLISH with both extensions` | Deferred | SUBSCRIBE_TRACKS |
| `MOXYGEN-D18-CASE-057` | `PUBLISH before SUBSCRIBE_TRACKS` | Deferred | SUBSCRIBE_TRACKS + REQUEST_UPDATE |
| `MOXYGEN-D18-CASE-058` | `PUBLISH before SUBSCRIBE_TRACKS with DATAGRAM` | Deferred | SUBSCRIBE_TRACKS + REQUEST_UPDATE |

## Diagnostic Gates

The seven immutable runner gate IDs and revision-1 prose are in [`MOXYGEN-DRAFT18-DIAGNOSTIC-GATES.md`](./MOXYGEN-DRAFT18-DIAGNOSTIC-GATES.md). Each gate maps to one intended moxygen source binding, but its protocol-level semantic contract is implementation-neutral. All other intended declarations remain inventory-only in this profile revision.

Implementation diversity is a requirement, not an optimization. The moxygen binding uses moxygen `moqtest_server` and moxygen `moqtest_client` around the relay. The independent binding uses separately authored publisher fixtures, subscriber assertions, namespaces, payloads, and Rust functions. The two bindings share only the gate's protocol-level semantic criteria; they must not copy each other's generators or assertions.
