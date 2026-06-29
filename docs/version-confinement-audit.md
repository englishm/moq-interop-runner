# Client version-confinement audit (Tier C)

For the version-pinned matrix (ADR 003), a multi-version implementation needs a
way to be **confined to one draft** so a cell on draft-D's page genuinely tests D.
The runner always supplies the standard `MOQT_DRAFT=draft-D` (and the
`${MOQT_DRAFT_NUM}` template = bare number); each registration interpolates that
into whatever knob the impl actually exposes. This audit records the knob per
implementation.

Single-version impls (the `moq-rs` draft family, `moq-go`, `xquic`, …) are
inherently confined by their image and need nothing.

| Impl | Role | Confinement knob | Source | Status |
|------|------|------------------|--------|--------|
| **moqx** | client + relay | `MOQX_MOQT_VERSIONS=<N>` (env, read by binary) | moqx-run.sh / entrypoint | ✅ encoded — `env: MOQX_MOQT_VERSIONS=${MOQT_DRAFT_NUM}` |
| **moq-dev-rs** | client | `MOQ_CLIENT_VERSION=moq-transport-<N>` (env, read by binary) | `builds/moq-dev-rs/src/main.rs` | ✅ encoded — `env: MOQ_CLIENT_VERSION=moq-transport-${MOQT_DRAFT_NUM}` |
| **aiomoqt** | client | `DRAFT=<N>` env (a single int pins; otherwise a `16,14,18` probe) | `aiomoqt/examples/moq_interop_client.py` | ✅ encoded — `env: DRAFT=${MOQT_DRAFT_NUM}` |
| **aiomoqt** | relay | entrypoint maps `MOQT_DRAFT` → `--draft` | `aiomoqt docker-entrypoint.sh` | ⚠️ already honors the convention name — confirm `draft-16` vs `16` format (see below) |
| **moq-dev-rs** | relay | (relay-side pin TBD) | — | ❓ needs check (`moq-relay` version flag/env) |
| **moq-dev-js** | client | none found (`CERT_PATH` only) | `builds/moq-dev-js/src/main.ts` | ❌ needs upstream support |
| **imquic** | client + relay | entrypoint passes only `--relay/--test/--tls/--verbose`; no version flag exposed | `builds/imquic/entrypoint-client.sh` (no local source) | ❓ needs Meetecho / source check |
| **moxygen** | client | none found locally | `~/Projects/moq/moxygen` | ❓ needs check / maintainer |
| **moqlivemock** | client | — (no local checkout) | Eyevinn/moqlivemock | ❓ needs source check / maintainer |

## Format note surfaced by aiomoqt

The runner sets `MOQT_DRAFT=draft-16` (canonical draft id) and exposes
`${MOQT_DRAFT_NUM}` = `16` for registrations that want the bare number. aiomoqt's
relay entrypoint already reads `MOQT_DRAFT` and passes it to `--draft`, which
expects the **number** — so either the convention's injected value should be the
number, the impl should accept `draft-NN`, or the registration/entrypoint strips
the prefix. **Recommendation:** keep `MOQT_DRAFT=draft-NN` as the canonical env
(self-documenting), and have impls interpolate `${MOQT_DRAFT_NUM}` (or strip
`draft-` in shell) where a bare number is required — which is exactly what the
encoded client registrations above do.

## Encoded so far

Confirmed from source and live in `implementations.json` (via `${MOQT_DRAFT_NUM}`
interpolation): **moqx** (both roles), **moq-dev-rs** (client), **aiomoqt**
(client). These produce real Tier-C confinement today; the rest are tracked above
pending a knob (or maintainer input).
