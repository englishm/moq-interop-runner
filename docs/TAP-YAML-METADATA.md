# TAP YAML Metadata

TAP version 14 permits a YAML diagnostic block after a test point. Test clients
may use these blocks to report structured context in addition to the test's
`ok` or `not ok` result.

Every field in this document is currently optional. A client that emits no YAML
remains compatible with the current runner and existing nightly interop report.
The runner and report generator in this repository are the primary consumers of
these fields.

As of September 2026, the runner preserves the client output but does not parse
these fields into the nightly report.

As implementations adopt the fields, future reports can group results by the
MoQT version and transport actually negotiated, distinguish the protocol stack
selected in fallback scenarios,
compare results that use the same test specification revision, and link a
failure to session logs. This metadata adds context; it does not alter the TAP
pass or fail result.

## Example

```tap
not ok 1 - announce-subscribe
  ---
  duration_ms: 3200
  implementation_version: "31c73575"
  sessions:
    publisher:
      moqt_version: "moqt-18"
      transport: "quic"
      alpn: "moqt-18"
      quic_initial_destination_connection_id: "abc1234567890def"
    subscriber:
      moqt_version: "moqt-18"
      transport: "quic"
      alpn: "moqt-18"
      quic_initial_destination_connection_id: "def4567890abcdef"
  message: "subscriber did not receive the expected object"
  ...
```

The TAP description should be the stable identifier from the
[test catalog](./tests/README.md). The block follows the indentation rules in
[TEST-CLIENT-INTERFACE.md](./TEST-CLIENT-INTERFACE.md#yaml-diagnostics).

## Common Fields

| Field | Type | Meaning |
|-------|------|---------|
| `duration_ms` | non-negative integer | Total elapsed time for this test in milliseconds |
| `implementation_version` | string | Client release, source revision, or build identifier |
| `test_spec_revision` | positive integer | Revision of the prose specification implemented by the client |
| `udp_blocked` | boolean | Whether the test environment intentionally made UDP unavailable for this test |
| `sessions` | mapping | Session details keyed by logical role from the test specification |
| `message` | string | Concise human-readable diagnostic context |

`duration_ms` covers the complete test, from immediately before its first
test-specific action through its procedure and verification. It is not an
object-delivery latency or any other narrower timing measurement.

`implementation_version` is opaque. Quote values that YAML might otherwise
interpret as another type. The meaning and update rules for
`test_spec_revision` are defined in
[Test Specification Revisions](./tests/README.md#test-specification-revisions).

`udp_blocked: true` records an intentional test condition, such as a fallback
test where UDP has been made unavailable. It does not by itself claim that a
QUIC attempt was made. Omit the field when the client does not know whether UDP
was blocked.

## Session Fields

Each key under `sessions` is a stable logical role defined by the test, such as
`client`, `publisher`, or `subscriber`. This allows each leg of a multi-session
test to report what it actually negotiated.

| Field | Type | Meaning |
|-------|------|---------|
| `moqt_version` | string | Normalized MoQT protocol identifier selected for this session, such as `moqt-18` or the final `moqt` |
| `transport` | string | Selected transport stack from the values below |
| `alpn` | string | Exact ALPN selected on the underlying QUIC or TLS connection |
| `webtransport_protocol` | string | Exact WebTransport application protocol selected in `WT-Protocol`; omitted unless WebTransport is used |
| `websocket_subprotocol` | string | Exact WebSocket subprotocol selected in `Sec-WebSocket-Protocol`; omitted unless WebSocket is used |
| `quic_initial_destination_connection_id` | string | Client's Initial Destination Connection ID as lowercase hexadecimal without separators or a `0x` prefix; omitted when unavailable or no QUIC connection is used |

For drafts 15 and later, the MoQT version is selected by the MoQT ALPN for
native QUIC or by WebTransport application protocol negotiation. Earlier
drafts used the `moq-00` ALPN and selected a version during SETUP.
`moqt_version` normalizes the selected version to the protocol identifier form
(`moqt-NN` for an Internet-Draft and `moqt` for the final protocol), including
when an earlier draft selected its version in SETUP. It reports the version
actually selected by the applicable mechanism, not a requested, predicted, or
maximum supported version. The raw `alpn`, `webtransport_protocol`, and
`websocket_subprotocol` fields provide supporting negotiation evidence when an
implementation exposes it. An experimental QMux mapping can use the same
normalized `moqt_version` while reporting its actual ALPN or selected WebSocket
subprotocol as raw evidence.

The initial `transport` values are:

| Value | Stack |
|-------|-------|
| `quic` | Native MoQT over QUIC |
| `webtransport-h3` | MoQT over WebTransport over HTTP/3 and QUIC |
| `webtransport-h2` | MoQT over WebTransport over HTTP/2 and TLS/TCP |
| `qmux-wss` | MoQT over QMux over secure WebSocket |
| `qmux-tcp-tls` | MoQT over QMux over TLS/TCP |

The QMux values describe experimental mappings rather than transports defined
by the core MoQT specification. `qmux-tcp-tls` refers to QMux draft 02 over
TLS/TCP; an application mapping must assign it an ALPN distinct from the same
application's native QUIC ALPN. `qmux-wss` additionally uses the QMux over
WebSocket draft 00 binding, which carries the application's native QUIC
identifier in `Sec-WebSocket-Protocol`. The expired MOQT over QMux draft 00
proposes a MoQT mapping over QMux/TLS/TCP that reuses the native `moqt-NN`
ALPN, but it references an earlier QMux draft and its ALPN choice does not
satisfy QMux draft 02's mapping-specific requirement. It does not define the
WebSocket mapping. No MoQT-over-QMux identifier aligned with the current QMux
draft is standardized yet. Reports record the identifier actually selected;
new values can be documented as transports evolve. A report that does not
recognize a value leaves it unclassified rather than rejecting the result.

The runner does not currently provide a way to block UDP. A future fallback
test that intentionally adds this condition could report:

```tap
ok 1 - setup-only
  ---
  duration_ms: 4187
  implementation_version: "v0.4.2"
  udp_blocked: true
  sessions:
    client:
      moqt_version: "moqt-18"
      transport: "webtransport-h2"
      alpn: "h2"
      webtransport_protocol: "moqt-18"
  ...
```

## How Compatibility Works

- YAML augments a TAP result; it does not replace the test point or plan.
- An omitted field will be interpreted as unknown or unreported, not as a
  default value.
- Clients report versions and transports they actually negotiated, not values
  requested or predicted before the session was established.
- The runner and report generator ignore fields and values they do not yet
  classify.
- The runner continues to accept TAP output without YAML diagnostics.
- Existing producer-specific fields remain valid even when they are not part of
  the shared vocabulary documented here.
- New fields can be documented without requiring coordinated client upgrades.

YAML blocks are the preferred place for structured diagnostics because they do
not interfere with TAP parsing. Plain TAP remains valid, and TAP comments remain
available for additional human-readable context.

## Protocol References

- [MoQT draft 18, Version Negotiation](https://www.ietf.org/archive/id/draft-ietf-moq-transport-18.html#section-3.1)
- [WebTransport over HTTP/3, Protocol Negotiation](https://www.ietf.org/archive/id/draft-ietf-webtrans-http3-16.html#section-3.3)
- [WebTransport over HTTP/2](https://www.ietf.org/archive/id/draft-ietf-webtrans-http2-15.html)
- [QMux draft 02](https://www.ietf.org/archive/id/draft-ietf-quic-qmux-02.html)
- [QMux over WebSocket draft 00](https://www.ietf.org/archive/id/draft-lcurley-qmux-websocket-00.html)
- [MOQT over QMux draft 00](https://www.ietf.org/archive/id/draft-nandakumar-moq-qmux-moqt-00.html)
