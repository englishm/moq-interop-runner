# moxygen Diagnostic Gates

These seven runner diagnostic gates refine the intended source bindings in [`MOXYGEN-RELAY-SUPPORT-PROFILE.md`](./MOXYGEN-RELAY-SUPPORT-PROFILE.md). Each immutable gate ID is a draft-agnostic semantic slug. A moxygen ordinal and exact case name separately identify the declaration in the pinned moxygen script; they are source provenance, not canonical protocol test IDs.

**Target Draft**: `draft-18`

**Identifier Semantics Reviewed For**: `draft-18`

All normative references are to [`draft-ietf-moq-transport-18`](https://github.com/moq-wg/moq-transport/blob/cb2e772fd8ca8cbe7550b1765c269be89fb1c886/draft-ietf-moq-transport.md) at commit `cb2e772fd8ca8cbe7550b1765c269be89fb1c886`. The draft remains normative.

Semantic test IDs survive an equivalent editorial or section-only migration only when protocol behavior, pass criteria, and applicability remain equivalent; all references are then updated atomically. Any incompatible change to those semantics or pass criteria retires the old ID permanently and requires a new semantic ID plus an `identifier_history.retired_ids` record. A gate and its moxygen source binding intentionally share one semantic test ID while exposing multiple driver bindings. Result `target_draft`, profile revision, gate revision, and exact revisions preserve the historical interpretation of an execution.

## Semantic Contract And Bindings

Each gate has one implementation-neutral semantic contract and two driver bindings:

`gate_normative_references` applies to the implementation-neutral semantic contract and therefore to both bindings. Source-script facts are labeled as moxygen binding provenance; independently derived fixture references and limitations are labeled under the independent binding.

- The semantic topology consists only of publisher, relay-under-test, and subscriber roles. Canonical success criteria describe protocol-visible subscription, framing, identity, metadata, payload, and termination behavior.
- The `moxygen_driver` binding places moxygen `moqtest_server` upstream and moxygen `moqtest_client` downstream of the relay. Its exact `moq-test-00` tuple, source ordinal, and source name are binding inputs and evidence labels, not normative behavior.
- The `independent_moq_test_client` binding uses independently authored publisher fixtures, subscriber assertions, namespaces, fixed payload constants, and planned Rust functions. It must not encode or call moxygen's tuple generator or verifier. Payload constants are unique per object; they are not generated from a template, and evidence must match their exact bytes.
- A result from one binding does not prove the other binding passed. Every result record identifies its binding and independence class.

## Common Procedure

For the moxygen binding:

1. Start the pinned moxygen `moqtest_server`, attach it to the relay, and observe the relay's current-target (`draft-18`) REQUEST_OK for PUBLISH_NAMESPACE for this same active case. Process liveness, SETUP, or a separate announce-only run is not readiness.
2. Run the pinned moxygen `moqtest_client` declaration named by the source binding with its exact tuple.
3. Capture both moxygen roles, the relay, decoded control and data observations, and the unmodified driver output.

For the independent binding:

1. Start the Rust publisher session and derive the full namespace by appending that session's publisher connection ID to the vector's namespace prefix. The CID component gives each run a unique namespace and is part of exact-track routing identity.
2. Start the Rust subscriber session through the mapped function, negotiate the profile's `draft-18` target, and issue SUBSCRIBE for the exact namespace and track.
3. Require both SUBSCRIBE_OK and delivery of that exact namespace-plus-track to the publisher serve model before publishing data.
4. Validate serve-model subgroup identity, priority, normal Object status, absolute Object IDs, exact properties and payloads, then require TRACK_ENDED after the finite fixture.

For either binding, apply the same gate-level semantic criteria to observations and use that binding's deterministic vector only to identify expected fixture instances. The independent binding optionally records concurrent role setup wall time, then readiness at no more than 10,000 ms and delivery/terminal observation at no more than 10,000 ms. Each moxygen gate records shared publisher readiness at no more than 10,000 ms followed by a case phase no longer than its selected 10,000 ms timeout. Aggregate `duration_ms` may include additional orchestration and is not capped by the selected timeout, but it must be at least the sum of the binding's recorded sequential wall-clock phases. Cross-stream reordering is permitted; ordering within a subgroup is not. Duplicate, missing, rewritten, or unexpected fixture objects fail closed.

## Common Evidence And Results

An evaluator `pass` requires exactly the selected gate's complete `required_assertion_ids` set, every assertion at pass with evidence references, all seven profile evidence categories, exact revisions, actual protocol metadata, and deployment provenance. A `fail` requires that same complete set and verified evidence/provenance, with at least one failed assertion. `inconclusive` requires a not-observed assertion or non-verified evidence/provenance; an all-pass, fully verified record is not inconclusive. Assertions from another gate or one arbitrary assertion cannot establish an outcome. The `publisher-readiness` and `delivery-observations` assertions are binding-specific. moxygen requires same-case REQUEST_OK plus wire subgroup and FIN/reset evidence. The current Rust binding requires SUBSCRIBE_OK, exact-track routing, serve-model observations, and TRACK_ENDED; it does not directly observe PUBLISH_NAMESPACE REQUEST_OK, raw Object ID deltas, FIRST_OBJECT, or wire FIN/reset. Results conform to `#/definitions/result_record` in [`moxygen-relay-support-profile.schema.json`](./moxygen-relay-support-profile.schema.json).

Evidence descriptors retain SHA-256 syntax, but schema and jq validation cannot prove a digest matches external bytes. An external publication step must recompute every evidence digest from the referenced artifact and set `evidence_integrity_verification=verified`. It must also verify executable/image provenance and set `provenance_verification=verified`; an evaluator pass is invalid without both.

Result identity and exact revisions both preserve `target_draft` and profile revision; gate IDs remain semantic across target changes. `reproducibility` and `independence_class` are submitted claims until external verification occurs. Structural validation does not externally prove deployment identity or provenance, implementation independence, or evidence integrity.

| Evidence category | Compatible kinds | Compatible producers |
|-------------------|------------------|----------------------|
| `publisher-readiness` | `control-trace`, `serve-model` | publisher, relay, subscriber, driver |
| `control-observations` | `control-trace` | publisher, relay, subscriber, driver |
| `object-observations` | `object-trace`, `serve-model` | publisher, relay, subscriber, driver |
| `delivery-observations` | `stream-trace`, `serve-model` | publisher, relay, subscriber, driver |
| `tap14` | `tap14` | driver |
| `process-logs` | `stdout`, `stderr`, `process-log` | publisher, relay, subscriber, runner, driver |
| `reproduction-metadata` | `metadata` | runner, driver |

Protocol metadata records the transport layers separately. Raw QUIC uses `transport=raw-quic`, `transport_alpn=moqt-18`, and `webtransport_protocol=null`. WebTransport uses `transport=webtransport`, the actually negotiated valid `h3` transport ALPN, and `webtransport_protocol=moqt-18`. Both record `negotiated_draft=draft-18`.

Disposition, execution, evaluator verdict, and driver/exported claimed outcome are separate fields. Missing readiness or orchestration is `harness-error`; insufficient evidence is `inconclusive`; an unexecuted case is `not-run`. An opaque deployment records no fake image digest and must carry its locator, observed version, limitations, and opaque reproducibility classification. Baseline SHAs are reference inputs only: every executable result requires the actual full driver landing SHA and must not contain `TBD`.

Exact priorities, exact payload bytes, and absence of extra fixture properties are profile fixture requirements, not universal draft MUSTs. Assertions label their basis as `profile-fixture-requirement` or `draft-protocol-requirement`, using Sections 7 and 9 when judging priority forwarding. A profile mismatch is not automatically a draft protocol contradiction. All seven reviewed Rust vectors pin publisher priority per subgroup.

The reviewed moxygen baseline has a known global cross-stream ordering false-failure risk. Until a fixed moxygen executable SHA is pinned, a moxygen failure whose only mismatch is global ordering across otherwise valid streams is `driver-inconclusive` with evaluator verdict `inconclusive`, never a relay failure.

Normal vectors use non-empty payloads and do not request explicit end-of-group Object Status. Stream framing and FIN observations cannot be reported as support for the separately deferred Object Status cases.

## `subscribe-one-subgroup-per-group` Revision 1

**Semantic scenario**: A successful subscription delivers multiple normal objects in one subgroup per group. The relay preserves each object's Group ID, Object ID, Subgroup ID, priority, properties, and payload exactly once; every subgroup is validly framed and closes cleanly.

**Gate-semantic normative references (both bindings)**: Sections 2.1, 2.2, 5.1, 5.1.2, 7, 9, 10.7, 10.8, 11.2, 11.4, 11.4.2, and 11.4.3.

**moxygen source binding**: `subscribe-one-subgroup-per-group`, ordinal 1, exact name `Basic subscribe with default parameters`.

- Topology: `moxygen moqtest_server -> relay-under-test -> moxygen moqtest_client`.
- Tuple: `("moq-test-00","0","0","0","2","5","5","1024","100","50","1","1","0","-1","-1","0")`; Track Name `test`.
- Expected fixture instances: Groups `0,1,2`; Objects `0..5`; Subgroup `0`; 18 objects on 3 streams. Object 0 has 1024 `0x74` octets and other objects have 100. Effective priority is 200 for even groups and 201 for odd groups.

The six Object IDs reflect the pinned driver's derivation and are not a protocol rule.

**Independent binding**:

- Topology: `independent publisher role -> relay-under-test -> independent subscriber role`.
- Namespace rule `moq-test/interop/subscribe-one-subgroup-per-group/{publisher_cid}`; Track `one-subgroup-per-group`. Groups `0,1`; Objects `0,1,2` in Subgroup `0` for each group; Publisher Priority 17 for Group 0/Subgroup 0 and 23 for Group 1/Subgroup 0.
- Fixed payloads, ASCII (`hex`): `subscribe-one-subgroup-per-group-g0-s0-o0` (`7375627363726962652d6f6e652d73756267726f75702d7065722d67726f75702d67302d73302d6f30`), `subscribe-one-subgroup-per-group-g0-s0-o1` (`7375627363726962652d6f6e652d73756267726f75702d7065722d67726f75702d67302d73302d6f31`), `subscribe-one-subgroup-per-group-g0-s0-o2` (`7375627363726962652d6f6e652d73756267726f75702d7065722d67726f75702d67302d73302d6f32`), `subscribe-one-subgroup-per-group-g1-s0-o0` (`7375627363726962652d6f6e652d73756267726f75702d7065722d67726f75702d67312d73302d6f30`), `subscribe-one-subgroup-per-group-g1-s0-o1` (`7375627363726962652d6f6e652d73756267726f75702d7065722d67726f75702d67312d73302d6f31`), `subscribe-one-subgroup-per-group-g1-s0-o2` (`7375627363726962652d6f6e652d73756267726f75702d7065722d67726f75702d67312d73302d6f32`).
- Planned Rust function: `test_subscribe_one_subgroup_per_group`.

**Gate-specific fail-closed criteria**: SUBSCRIBE is accepted; all binding fixture objects are observed exactly once with unchanged profile fields and exact payload bytes; one subgroup is used per group; Object IDs increase within each subgroup; the Rust priorities are exactly 17 and 23. moxygen additionally requires wire/FIN evidence; Rust requires serve-model completion with TRACK_ENDED.

## `subscribe-one-subgroup-per-object` Revision 1

**Semantic scenario**: A successful subscription delivers each normal object in a distinct subgroup. The relay does not merge subgroup identities or move an object between subgroups.

**Gate-semantic normative references (both bindings)**: Sections 2.1, 2.2, 5.1, 5.1.2, 7, 9, 10.7, 10.8, 11.2, 11.4, 11.4.2, and 11.4.3.

**moxygen source binding**: `subscribe-one-subgroup-per-object`, ordinal 2, exact name `ONE_SUBGROUP_PER_OBJECT forwarding`.

- Topology: `moxygen moqtest_server -> relay-under-test -> moxygen moqtest_client`.
- Tuple: `("moq-test-00","1","0","0","2","5","5","1024","100","50","1","1","0","-1","-1","0")`; Track Name `test`.
- Expected fixture instances: Groups `0,1,2`; Objects `0..5`; each object's Subgroup ID equals its Object ID; 18 objects on 18 streams. Payload and priority rules match the moxygen one-subgroup-per-group binding described above.

**Independent binding**:

- Topology: `independent publisher role -> relay-under-test -> independent subscriber role`.
- Namespace rule `moq-test/interop/subscribe-one-subgroup-per-object/{publisher_cid}`; Track `one-subgroup-per-object`. Group `0`; Subgroup 40 contains only Object 4 at priority 29, Subgroup 41 only Object 5 at priority 31, and Subgroup 42 only Object 6 at priority 37.
- Fixed payloads, ASCII (`hex`): `subscribe-one-subgroup-per-object-g0-s40-o4` (`7375627363726962652d6f6e652d73756267726f75702d7065722d6f626a6563742d67302d7334302d6f34`), `subscribe-one-subgroup-per-object-g0-s41-o5` (`7375627363726962652d6f6e652d73756267726f75702d7065722d6f626a6563742d67302d7334312d6f35`), `subscribe-one-subgroup-per-object-g0-s42-o6` (`7375627363726962652d6f6e652d73756267726f75702d7065722d6f626a6563742d67302d7334322d6f36`).
- Planned Rust function: `test_subscribe_one_subgroup_per_object`.

**Gate-specific fail-closed criteria**: SUBSCRIBE is accepted; every fixture object has one distinct publisher-selected subgroup with the exact priority and payload. moxygen additionally requires wire/FIN evidence; Rust requires exact serve-model observations and TRACK_ENDED. Equality between Object ID and Subgroup ID is moxygen-binding evidence only, not canonical behavior.

## `subscribe-two-subgroups-per-group` Revision 1

**Semantic scenario**: A group is delivered over two distinct subgroups. Objects can interleave across streams, but the relay preserves subgroup identity, exact membership, and internal Object ID order.

**Gate-semantic normative references (both bindings)**: Sections 2.1, 2.2, 5.1, 5.1.2, 7, 9, 10.7, 10.8, 11.2, 11.4, 11.4.2, and 11.4.3.

**moxygen source binding**: `subscribe-two-subgroups-per-group`, ordinal 3, exact name `TWO_SUBGROUPS_PER_GROUP forwarding`.

- Topology: `moxygen moqtest_server -> relay-under-test -> moxygen moqtest_client`.
- Tuple: `("moq-test-00","2","0","0","2","6","6","1024","100","50","1","1","0","-1","-1","0")`; Track Name `test`.
- Expected fixture instances: Groups `0,1,2`; Subgroup 0 carries `0,2,4,6`; Subgroup 1 carries `1,3,5`; 21 objects on 6 streams.

**Independent binding**:

- Topology: `independent publisher role -> relay-under-test -> independent subscriber role`.
- Namespace rule `moq-test/interop/subscribe-two-subgroups-per-group/{publisher_cid}`; Track `two-subgroups-per-group`. Group `2`; Subgroup 10 at priority 41 carries Objects `0,2,4`; Subgroup 11 at priority 43 carries Objects `1,3,5`.
- Fixed payloads, ASCII (`hex`): `subscribe-two-subgroups-per-group-g2-s10-o0` (`7375627363726962652d74776f2d73756267726f7570732d7065722d67726f75702d67322d7331302d6f30`), `subscribe-two-subgroups-per-group-g2-s10-o2` (`7375627363726962652d74776f2d73756267726f7570732d7065722d67726f75702d67322d7331302d6f32`), `subscribe-two-subgroups-per-group-g2-s10-o4` (`7375627363726962652d74776f2d73756267726f7570732d7065722d67726f75702d67322d7331302d6f34`), `subscribe-two-subgroups-per-group-g2-s11-o1` (`7375627363726962652d74776f2d73756267726f7570732d7065722d67726f75702d67322d7331312d6f31`), `subscribe-two-subgroups-per-group-g2-s11-o3` (`7375627363726962652d74776f2d73756267726f7570732d7065722d67726f75702d67322d7331312d6f33`), `subscribe-two-subgroups-per-group-g2-s11-o5` (`7375627363726962652d74776f2d73756267726f7570732d7065722d67726f75702d67322d7331312d6f35`).
- Planned Rust function: `test_subscribe_two_subgroups_per_group`.

**Gate-specific fail-closed criteria**: SUBSCRIBE is accepted; exactly two fixture subgroups, priorities, membership, and in-subgroup order match; no global cross-stream order is required. moxygen additionally requires stream FIN evidence; Rust requires exact serve-model observations and TRACK_ENDED.

## `subscribe-nonzero-start-group` Revision 1

**Semantic scenario**: The first published and delivered group has a non-zero Group ID. The relay preserves that ID and does not synthesize earlier groups.

**Gate-semantic normative references (both bindings)**: Sections 1.4.2, 2.1, 2.3, 5.1, 5.1.2, 7, 9, 10.7, 10.8, 11.2, 11.4, 11.4.2, and 11.4.3.

**moxygen source binding**: `subscribe-nonzero-start-group`, ordinal 12, exact name `Start from group 5`.

- Topology: `moxygen moqtest_server -> relay-under-test -> moxygen moqtest_client`.
- Tuple: `("moq-test-00","0","5","0","7","3","3","1024","100","50","1","1","0","-1","-1","0")`; Track Name `test`.
- Expected fixture instances: Groups `5,6,7`; Objects `0..3`; Subgroup `0`; 12 objects on 3 streams.

**Independent binding**:

- Topology: `independent publisher role -> relay-under-test -> independent subscriber role`.
- Namespace rule `moq-test/interop/subscribe-nonzero-start-group/{publisher_cid}`; Track `nonzero-start-group`. Group 5/Subgroup 0 has priority 47 and Objects `0,1`; Group 6/Subgroup 0 has priority 53 and Objects `0,1`.
- Fixed payloads, ASCII (`hex`): `subscribe-nonzero-start-group-g5-s0-o0` (`7375627363726962652d6e6f6e7a65726f2d73746172742d67726f75702d67352d73302d6f30`), `subscribe-nonzero-start-group-g5-s0-o1` (`7375627363726962652d6e6f6e7a65726f2d73746172742d67726f75702d67352d73302d6f31`), `subscribe-nonzero-start-group-g6-s0-o0` (`7375627363726962652d6e6f6e7a65726f2d73746172742d67726f75702d67362d73302d6f30`), `subscribe-nonzero-start-group-g6-s0-o1` (`7375627363726962652d6e6f6e7a65726f2d73746172742d67726f75702d67362d73302d6f31`).
- Planned Rust function: `test_subscribe_nonzero_start_group`.

**Gate-specific fail-closed criteria**: SUBSCRIBE is accepted; the selected binding's first observed Group ID is 5; only the fixture's groups, priorities, objects, and payloads are accepted. moxygen additionally requires wire/FIN evidence; Rust requires exact serve-model observations and TRACK_ENDED. No claim is made that absent lower Group IDs do not exist.

## `subscribe-nonzero-start-object` Revision 1

**Semantic scenario**: The first object in a subgroup has a non-zero Object ID. The relay preserves the first absolute Object ID and correctly forwards subsequent delta-encoded IDs.

**Gate-semantic normative references (both bindings)**: Sections 1.4.2, 2.1, 2.2, 5.1, 5.1.2, 7, 9, 10.7, 10.8, 11.2, 11.4, 11.4.2, and 11.4.3.

**moxygen source binding**: `subscribe-nonzero-start-object`, ordinal 13, exact name `Start from object 3`.

- Topology: `moxygen moqtest_server -> relay-under-test -> moxygen moqtest_client`.
- Tuple: `("moq-test-00","0","0","3","1","8","8","1024","100","50","1","1","0","-1","-1","0")`; Track Name `test`.
- Expected fixture instances: Groups `0,1`; Objects `3..8`; Subgroup `0`; 12 objects on 2 streams. Object 3, not Object 0, receives the binding's first-object payload size.

**Independent binding**:

- Topology: `independent publisher role -> relay-under-test -> independent subscriber role`.
- Namespace rule `moq-test/interop/subscribe-nonzero-start-object/{publisher_cid}`; Track `nonzero-start-object`. Group 0/Subgroup 7 has priority 59 and Objects `3,4,5`.
- Fixed payloads, ASCII (`hex`): `subscribe-nonzero-start-object-g0-s7-o3` (`7375627363726962652d6e6f6e7a65726f2d73746172742d6f626a6563742d67302d73372d6f33`), `subscribe-nonzero-start-object-g0-s7-o4` (`7375627363726962652d6e6f6e7a65726f2d73746172742d6f626a6563742d67302d73372d6f34`), `subscribe-nonzero-start-object-g0-s7-o5` (`7375627363726962652d6e6f6e7a65726f2d73746172742d6f626a6563742d67302d73372d6f35`).
- Planned Rust function: `test_subscribe_nonzero_start_object`.

**Gate-specific fail-closed criteria**: SUBSCRIBE is accepted; the first serve-model Object ID is 3 and subsequent absolute IDs are exact; no lower fixture Object ID is accepted; subgroup identity, priority, payload, and metadata match. moxygen additionally requires wire/FIN evidence; Rust requires TRACK_ENDED. No claim is made that absent lower Object IDs do not exist.

## `subscribe-sparse-group-object-ids` Revision 1

**Semantic scenario**: Sparse Group IDs and Object IDs are forwarded without renumbering. This fixture contains no Prior Group ID Gap or Prior Object ID Gap properties; the evaluator checks that observable fact and does not claim to observe the peer's internal inference state.

**Gate-semantic normative references (both bindings)**: Sections 1.4.2, 2.1, 2.2, 2.3.1, 5.1, 5.1.2, 7, 9, 10.7, 10.8, 11.2, 11.4, 11.4.2, 11.4.3, 12.8, and 12.9.

**moxygen source binding**: `subscribe-sparse-group-object-ids`, ordinal 29, exact name `Group and object increment of 2`.

- Topology: `moxygen moqtest_server -> relay-under-test -> moxygen moqtest_client`.
- Tuple: `("moq-test-00","2","0","0","4","12","6","1024","100","50","2","2","0","-1","-1","0")`; Track Name `test`.
- Expected fixture instances: Groups `0,2,4`; Objects `0,2,4,6,8,10,12`; only Subgroup `0` is opened because all generated Object IDs are even; 21 objects on 3 streams.

**Independent binding**:

- Topology: `independent publisher role -> relay-under-test -> independent subscriber role`.
- Namespace rule `moq-test/interop/subscribe-sparse-group-object-ids/{publisher_cid}`; Track `sparse-group-object-ids`. Group 0/Subgroup 0 has priority 61; Group 2/Subgroup 0 has priority 67; each contains Objects `0,2,4`; no prior-gap properties.
- Fixed payloads, ASCII (`hex`): `subscribe-sparse-group-object-ids-g0-s0-o0` (`7375627363726962652d7370617273652d67726f75702d6f626a6563742d6964732d67302d73302d6f30`), `subscribe-sparse-group-object-ids-g0-s0-o2` (`7375627363726962652d7370617273652d67726f75702d6f626a6563742d6964732d67302d73302d6f32`), `subscribe-sparse-group-object-ids-g0-s0-o4` (`7375627363726962652d7370617273652d67726f75702d6f626a6563742d6964732d67302d73302d6f34`), `subscribe-sparse-group-object-ids-g2-s0-o0` (`7375627363726962652d7370617273652d67726f75702d6f626a6563742d6964732d67322d73302d6f30`), `subscribe-sparse-group-object-ids-g2-s0-o2` (`7375627363726962652d7370617273652d67726f75702d6f626a6563742d6964732d67322d73302d6f32`), `subscribe-sparse-group-object-ids-g2-s0-o4` (`7375627363726962652d7370617273652d67726f75702d6f626a6563742d6964732d67322d73302d6f34`).
- Planned Rust function: `test_subscribe_sparse_group_object_ids`.

**Gate-specific fail-closed criteria**: SUBSCRIBE is accepted; exact sparse absolute IDs, priorities, and payloads are present in the serve model; no object or group is renumbered or synthesized; no gap property is observed. The Rust binding does not claim peer inference state, raw delta, or FIN observation and requires TRACK_ENDED.

## `subscribe-object-properties` Revision 1

**Semantic scenario**: Normal objects carry higher odd byte-valued and even integer-valued Object Property types. The relay preserves valid Key-Value-Pair encoding, exact binding values, and object association.

**Gate-semantic normative references (both bindings)**: Sections 1.4.3, 2.1, 2.2, 2.5, 2.5.1, 5.1, 5.1.2, 7, 9, 10.7, 10.8, 11.2, 11.2.1.2, 11.4, 11.4.2, and 11.4.3.

**moxygen source binding**: `subscribe-object-properties`, ordinal 40, exact name `Extensions with higher IDs`.

- Topology: `moxygen moqtest_server -> relay-under-test -> moxygen moqtest_client`.
- Tuple: `("moq-test-00","1","0","0","1","4","4","1024","100","50","1","1","0","5","3","0")`; Track Name `test`.
- Expected fixture instances: Groups `0,1`; Objects `0..4`; Subgroup ID equals Object ID; 10 objects on 10 streams. Every object has type 7 with 1..20 bytes and type 10 with a varint. The pinned declaration does not fix their generated values.

**Independent binding**:

- Topology: `independent publisher role -> relay-under-test -> independent subscriber role`.
- Namespace rule `moq-test/interop/subscribe-object-properties/{publisher_cid}`; Track `object-properties`; Group 9/Subgroup 7 has priority 59 and Objects `4,7`.
- Fixed payloads, ASCII (`hex`): `subscribe-object-properties-g9-s7-o4` (`7375627363726962652d6f626a6563742d70726f706572746965732d67392d73372d6f34`) and `subscribe-object-properties-g9-s7-o7` (`7375627363726962652d6f626a6563742d70726f706572746965732d67392d73372d6f37`).
- Object 4 properties: type `0x3800` (14336), even integer value `0x1234` (4660); type `0x3801` (14337), odd byte value ASCII `high-type-3801` (`686967682d747970652d33383031`).
- Object 7 properties: type `0x3802` (14338), even integer value `0x10203040` (270544960); type `0x3803` (14339), odd byte value ASCII `high-type-3803` (`686967682d747970652d33383033`).
- Independent-binding property reference: Draft-18 reserves `0x3800..0x3fff` for application-specific Properties, so all four independent fixture types are valid. The Mandatory Track Property range `0x4000..0x7fff` is Track-scope only; Section 2.5.1 makes an Object carrying a type in that range malformed, so the independent binding forbids that range for Object Properties. The moxygen binding instead preserves its pinned source-generated types 7 and 10 without claiming the independent fixture's exact values.
- Planned Rust function: `test_subscribe_object_properties`.

**Gate-specific fail-closed criteria**: SUBSCRIBE is accepted; Group 9/Subgroup 7 at priority 59 contains exactly Objects 4 and 7; each object contains exactly its two specified property types and values; no Object Property type is in `0x4000..0x7fff`; duplicate, extra, malformed, or misassociated properties fail. Rust requires exact serve-model payload/property observations and TRACK_ENDED, not wire FIN. The moxygen binding does not claim exact value-preservation coverage because its source values are not fixed.
