# Subscribe Namespace Lifecycle

| Attribute | Value |
|-----------|-------|
| Identifier | `subscribe-namespace-lifecycle` |
| Status | Candidate |
| Profile | Namespace discovery |
| Specification revision | 1 |

## Purpose

This test verifies the subscriber-facing lifecycle of a published namespace.
After a subscriber establishes `SUBSCRIBE_NAMESPACE`, it must learn when an
exactly matching namespace becomes available through `NAMESPACE` and when that
namespace is withdrawn through `NAMESPACE_DONE`.

Unlike `announce-only` and `publish-namespace-done`, this test observes the
effect from a separate subscriber session. It does not infer success merely
from the publisher's request being accepted or cancelled.

## Protocol References

- [MoQT draft 18, Section 6.1](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-18#section-6.1): subscribing to namespaces
- [MoQT draft 18, Section 6.2](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-18#section-6.2): publishing namespaces
- MoQT draft 18 Sections 10.15 through 10.18: `PUBLISH_NAMESPACE`, `NAMESPACE`, `NAMESPACE_DONE`, and `SUBSCRIBE_NAMESPACE`
- MoQT draft 18 Section 3.3.2: request cancellation and rejection

The test applies to draft 18 and later drafts that retain these message
semantics.

## Roles And Test Namespace

The test client operates two independent sessions through the relay under test:

- `namespace_subscriber` sends `SUBSCRIBE_NAMESPACE` and observes namespace
  events.
- `namespace_publisher` sends and later cancels `PUBLISH_NAMESPACE`.

Every run uses an exact namespace of the form:

`("moq-test", "interop", "subscribe-namespace-lifecycle", "<run-id>")`

`<run-id>` is the lowercase hexadecimal encoding of at least 128 bits of random
entropy. The unique value prevents stale relay state or a concurrent run from
satisfying the test.

## Procedure

1. Establish the `namespace_subscriber` session.
2. Send `SUBSCRIBE_NAMESPACE` for the exact run-unique namespace and receive
   `REQUEST_OK` (`SUBSCRIBE_NAMESPACE_OK`). Keep its bidirectional request
   stream open.
3. Establish the `namespace_publisher` session.
4. Send `PUBLISH_NAMESPACE` for that exact namespace and receive `REQUEST_OK`
   (`PUBLISH_NAMESPACE_OK`).
5. Require the subscriber to receive one `NAMESPACE` naming the exact namespace.
6. Withdraw the namespace by cancelling the publisher's
   `PUBLISH_NAMESPACE` request stream as described in Section 3.3.2.
7. Require the subscriber to receive `NAMESPACE_DONE` for the same namespace on
   its still-active namespace subscription.
8. Cancel the subscriber's request and close both sessions.

The test publishes no Tracks or Objects.

## Success Criteria

The test passes when:

- both sessions complete SETUP;
- both namespace requests receive `REQUEST_OK`;
- the subscriber observes exactly one matching `NAMESPACE` after publication;
- it subsequently observes `NAMESPACE_DONE` for the same namespace after
  withdrawal;
- the events occur in that order; and
- neither session terminates unexpectedly before the lifecycle is observed.

Unrelated namespace events do not satisfy or fail the test. A matching
`NAMESPACE_DONE` before `NAMESPACE`, a duplicate matching `NAMESPACE`, a
request error, or a session failure does fail it.

## Timeouts And Diagnostics

SETUP and request establishment use a 5-second deadline. After the publisher's
request is accepted, `NAMESPACE` has a 3-second deadline. After withdrawal,
`NAMESPACE_DONE` has a 3-second deadline. The overall test deadline is 12
seconds.

TAP diagnostics should use the roles `namespace_subscriber` and
`namespace_publisher`, and should report which expected event was last observed
when the test fails.
