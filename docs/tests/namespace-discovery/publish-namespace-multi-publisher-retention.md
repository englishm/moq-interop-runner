# Publish Namespace Multi-publisher Retention

| Attribute | Value |
|-----------|-------|
| Identifier | `publish-namespace-multi-publisher-retention` |
| Status | Candidate |
| Profile | Namespace discovery |
| Specification revision | 1 |

## Purpose

Verify that a relay retains and fans out a namespace after one of two publishers
advertising that same namespace withdraws. The other publisher remains
authoritative, so a withdrawal from one source must not remove the namespace
from discovery. No tracks or objects are published.

## Protocol References

- MoQT draft 18: Sections 6.2 (Publishing Namespaces) and 9.3 (Multiple
  Publishers); `SUBSCRIBE_NAMESPACE`, `NAMESPACE`, `PUBLISH_NAMESPACE`, and
  `NAMESPACE_DONE`

## Scenario

1. An observer subscribes to a unique run prefix.
2. A first publisher advertises a child namespace; the observer receives its
   `NAMESPACE`.
3. A second publisher advertises that same namespace plus a synchronization
   namespace. The observer receiving the synchronization `NAMESPACE` confirms
   that the second publisher is active.
4. The second publisher withdraws both advertisements. The observer receives
   `NAMESPACE_DONE` for the synchronization namespace, while the first publisher
   continues advertising the shared namespace.
5. Two new subscribers send `SUBSCRIBE_NAMESPACE` for the run prefix. Both
   receive `NAMESPACE` for the shared namespace retained from the first
   publisher.
6. The first publisher withdraws it; both subscribers receive `NAMESPACE_DONE`.

## Success Criteria

The test passes when both fan-out subscribers discover the namespace after the
duplicate publisher has withdrawn, then both observe its final withdrawal when
the remaining publisher leaves, without any session ending unexpectedly.

## Timeout

The complete scenario must finish within 8 seconds.
