# Decision: URL Scheme and Transport Selection

**Date:** 2026-09-06

**Status:** Proposed migration; current runner behavior is unchanged

## Problem

The runner and many test clients use `https://` to select WebTransport and
`moqt://` to select native QUIC. That was the protocol model through MoQT draft
17. Beginning with draft 18, one `moqt://` URI identifies the MOQT resource and
transport selection is negotiated separately.

Changing every registered URL immediately would break implementations that
still dispatch on the scheme. Keeping the historical convention indefinitely
would make new integrations diverge from the current specification and would
prevent a single resource URI from being tested over multiple transports.

## Protocol History

MoQT drafts through 17 identify WebTransport servers with an HTTPS URI and
native QUIC servers with an `moqt` URI. The working group unified these in
[moq-transport PR #1486](https://github.com/moq-wg/moq-transport/pull/1486),
following discussion in
[issue #268](https://github.com/moq-wg/moq-transport/issues/268#issuecomment-3879776434)
and at IETF 125.

[MoQT draft 20, Section 3.1](https://www.ietf.org/archive/id/draft-ietf-moq-transport-20.html#section-3.1)
uses `moqt://` for both native QUIC and WebTransport. On a QUIC connection, a
client can offer version-specific MoQT ALPNs and `h3`; the selected ALPN
determines whether the session uses native QUIC or WebTransport over HTTP/3.
For WebTransport, the client derives an HTTPS URI by replacing the `moqt`
scheme and negotiates the MoQT protocol using `WT-Available-Protocols` and
`WT-Protocol`. A client can also establish WebTransport over HTTP/2 and
TLS/TCP.

Version selection is a separate dimension. Since draft 15, native QUIC uses a
version-specific `moqt-NN` ALPN and WebTransport uses the same identifier in
its application protocol negotiation. Earlier drafts use ALPN `moq-00` and
negotiate a version in SETUP.

## Decision

The target interface separates three concepts:

1. **Resource identity:** one canonical `moqt://` URI for draft 18 and later.
2. **Requested transport constraint:** an explicit runner-to-client input,
   initially `auto`, `quic`, or `webtransport`.
3. **Observed result:** TAP metadata records the transport stack and protocol
   identifiers actually selected.

`https://` remains accepted as a legacy WebTransport locator while registered
clients need it. It does not become the permanent way to force WebTransport
for draft 18 and later. The explicit transport constraint will perform that
job without changing the resource identity.

## Migration Plan

### Phase 1: Document the boundary

- Preserve current runner behavior and registered endpoint URLs.
- Describe `https://` as current compatibility behavior, not current MoQT URI
  semantics.
- Encourage new draft 18 and later integrations to register `moqt://` URIs.
- Record actual protocol and transport negotiation in optional TAP metadata.

### Phase 2: Add an explicit client constraint

- Add a runner-to-client environment variable for `auto`, `quic`, or
  `webtransport`; settle its final name in the implementation change.
- In `auto` mode, a draft 18 and later client can offer both native MoQT and
  HTTP ALPNs in preference order as specified by MoQT.
- In constrained modes, the client narrows what it offers. The URI remains
  `moqt://`.
- Keep the runner's existing endpoint `transport` value as the requested and
  expected transport for a forced run. It must not be treated as proof of what
  was negotiated.

### Phase 3: Adapt lagging clients

- Pass the canonical URI and requested constraint directly to clients that
  support the new interface.
- Let per-implementation adapters translate a constrained WebTransport run to
  an `https://` locator when a legacy client still selects transport by scheme.
- Keep existing `https://` registry entries until the corresponding client and
  endpoint have been verified with `moqt://` plus an explicit constraint.

### Phase 4: Retire compatibility behavior

- Migrate an endpoint only after its client succeeds over every registered
  transport using the canonical URI and reports the selected stack.
- Remove scheme translation per implementation rather than on a global date.
- Stop accepting `https://` as a MoQT relay locator after no active registered
  implementation requires it. It remains the internally derived URI used by a
  WebTransport handshake.

## QMux

QMux broadens the transport matrix but does not change the separation above.
[QMux draft 02](https://www.ietf.org/archive/id/draft-ietf-quic-qmux-02.html)
requires an application mapping over TLS to assign an ALPN distinct from that
application's native QUIC ALPN. The
[QMux over WebSocket draft 00](https://www.ietf.org/archive/id/draft-lcurley-qmux-websocket-00.html)
instead carries the application's native QUIC identifier in
`Sec-WebSocket-Protocol`.

The expired
[MOQT over QMux draft 00](https://www.ietf.org/archive/id/draft-nandakumar-moq-qmux-moqt-00.html)
proposes a MoQT mapping over QMux/TLS/TCP, including direct stream mapping and
reuse of the native `moqt-NN` ALPN. However, that proposal references the
earlier `draft-opik-quic-qmux-00`; its ALPN choice does not satisfy QMux draft
02's newer requirement for a mapping-specific identifier. It also does not
define a QMux-over-WebSocket mapping. The proposal is therefore part of the
implementation picture, but no MoQT-over-QMux identifier aligned with the
current QMux draft is standardized yet. The runner can name observed stacks
without predicting how that mismatch will be resolved.

## Consequences

- Current implementations continue to work during migration.
- A transport-filtered run becomes an explicit test condition rather than an
  inference from URL syntax.
- The same MOQT resource can be tested over native QUIC and WebTransport.
- Reports distinguish requested constraints from observed negotiation.
- Implementing the new constraint requires coordinated runner, adapter, and
  client changes; this decision does not implement them.
