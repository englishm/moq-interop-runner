# Subscribe Namespace Lifecycle

| Attribute | Value |
|-----------|-------|
| Identifier | `subscribe-namespace-lifecycle` |
| Status | Candidate |
| Profile | Namespace discovery |
| Specification revision | 1 |

## Purpose

Verify that a namespace subscriber is notified when a matching namespace is
published and again when it is withdrawn.

This covers the subscriber-facing lifecycle defined by `SUBSCRIBE_NAMESPACE`,
`NAMESPACE`, `PUBLISH_NAMESPACE`, and `NAMESPACE_DONE` in MoQT draft 18.

## Scenario

1. A subscriber subscribes to a unique namespace.
2. A separate publisher publishes that namespace.
3. The subscriber receives `NAMESPACE`.
4. The publisher withdraws the namespace.
5. The subscriber receives `NAMESPACE_DONE`.

No tracks or objects are published.

## Success Criteria

The test passes when the subscriber receives the matching `NAMESPACE` followed
by `NAMESPACE_DONE`, in that order, without either session ending unexpectedly.
