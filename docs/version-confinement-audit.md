# Client version-confinement audit (Tier C)

For the version-pinned matrix (ADR 003), a cell on draft-D's page must genuinely
test draft D. The runner cannot change wire negotiation — only what a side
advertises — so **confinement is fundamentally the client's responsibility** in a
pairing. (A relay offering version-specific images/deployments is its own
freedom, not the mechanism the matrix relies on.)

The runner always supplies the standard `MOQT_DRAFT=draft-D` (with
`${MOQT_DRAFT_NUM}` = the bare number for interpolation). Each **client**
registration maps that to whatever knob the client exposes.

## Findings (multi-version clients)

| Client | Knob | Evidence | Status |
|--------|------|----------|--------|
| **moqx** | `MOQX_MOQT_VERSIONS=<N>` env | moqx core (wraps moxygen's `getMoqtProtocols`) | ✅ encoded: `MOQX_MOQT_VERSIONS=${MOQT_DRAFT_NUM}` |
| **moq-dev-rs** | `MOQ_CLIENT_VERSION=moq-transport-<N>` env | `builds/moq-dev-rs/src/main.rs` (reads env, pins `client_config.version`) | ✅ encoded: `MOQ_CLIENT_VERSION=moq-transport-${MOQT_DRAFT_NUM}` |
| **aiomoqt** | `DRAFT=<N>` env (single int pins) | `aiomoqt/examples/moq_interop_client.py` | ✅ encoded: `DRAFT=${MOQT_DRAFT_NUM}` |
| **moxygen** | none *exposed by the interop client* | `MoQInteropClientMain.cpp` gflags = relay/test/list/tls/verbose only; `MoQInteropClient.cpp` hardcodes `kInteropAlpns = {moqt-16,moqt-14,moq-00}` | ❌ capability exists in the moxygen lib (`MoQVersions.h` / `getMoqtProtocols`, used by moqx) but is **not wired to the interop client** → add a flag/env (read `MOQT_DRAFT`) |
| **moq-dev-js** | none *in the interop wrapper* | `builds/moq-dev-js/src/main.ts` parses only `--relay/--test/--list/--tls/--verbose` | ❌ lib supports it (sibling moq-dev-rs has `MOQ_CLIENT_VERSION`; author confirms a switch) → **wire the wrapper** to read it and pass through to `Moq.Connection` |
| **imquic** | none exposed by the entrypoint | `builds/imquic/entrypoint-client.sh` passes only `--relay/--test/--tls/--verbose`; no local source | ❓ needs Meetecho / imquic source for a version flag |
| **moqlivemock** | unknown | no local checkout (Eyevinn/moqlivemock) | ❓ needs source / maintainer |

Single-version clients (`moq-rs` draft family, `moq-go`, `xquic`) are inherently
confined by their image and ignore `MOQT_DRAFT`.

## The recurring pattern

The version-confinement capability almost always **exists in the implementation's
core** — but the **interop test-client wrapper doesn't surface it** (moxygen and
moq-dev-js both fit this exactly). So most of Tier C is not "add version support,"
it's **"have each interop client read `MOQT_DRAFT` and confine."** That is exactly
what the `MOQT_DRAFT` convention asks of test clients, and it slots into the
[test-client interface](TEST-CLIENT-INTERFACE.md) as a small required behavior.

## Format note (`draft-NN` vs `N`)

The runner injects `MOQT_DRAFT=draft-NN` (canonical, self-documenting); clients
that want the bare number interpolate `${MOQT_DRAFT_NUM}` (or strip `draft-` in
shell). aiomoqt's relay entrypoint already reads `MOQT_DRAFT` and passes it to
`--draft`, which surfaced this — the encoded client registrations use
`${MOQT_DRAFT_NUM}` where a bare number is required.

## Encoded so far

Confirmed from source and live in `implementations.json`: **moqx**,
**moq-dev-rs** (client), **aiomoqt** (client) — real Tier-C confinement today.
**moxygen** and **moq-dev-js** need their interop wrappers wired to `MOQT_DRAFT`;
**imquic** / **moqlivemock** need a source/maintainer check.
