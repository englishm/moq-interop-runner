# MoQT Test Specifications

This document has been reorganized into separate, focused documents:

| Document | Content |
|----------|---------|
| **[tests/TEST-CASES.md](./tests/TEST-CASES.md)** | Test case definitions with protocol references |
| **[tests/DATA-PLANE.md](./tests/DATA-PLANE.md)** | Canonical data-plane vector semantics and test IDs |
| **[tests/vectors/data-plane.json](./tests/vectors/data-plane.json)** | Data-plane fixtures and expected results |
| **[tests/vectors/data-plane.schema.json](./tests/vectors/data-plane.schema.json)** | Data-plane vector JSON Schema |
| **[tests/PRIOR-ART.md](./tests/PRIOR-ART.md)** | Acknowledgments and prior art |
| **[TEST-CLIENT-INTERFACE.md](./TEST-CLIENT-INTERFACE.md)** | CLI, environment variables, exit codes, output format |
| **[IMPLEMENTING-A-TEST-CLIENT.md](./IMPLEMENTING-A-TEST-CLIENT.md)** | Guide for implementing a compatible test client |
| **[TARGET-DRAFT-POLICY.md](./TARGET-DRAFT-POLICY.md)** | Identifier lifecycle and target-draft review checklist |
| **[tests/retired-test-identifiers.json](./tests/retired-test-identifiers.json)** | Retired identifier tombstones and replacements |

## Quick Reference

### Test Cases

| Identifier | Category | Description |
|------------|----------|-------------|
| `setup-only` | Session | Basic SETUP exchange |
| `announce-only` | Namespace | PUBLISH_NAMESPACE flow |
| `publish-namespace-done` | Namespace | Unpublish namespace |
| `subscribe-error` | Subscription | Error for non-existent track |
| `announce-subscribe` | Subscription | Relay routes subscription to publisher |
| `subscribe-before-announce` | Subscription | Out-of-order subscribe/announce |
| `publish-without-subscriber` | Track publishing | Exercise the Forward-State-aware lifecycle without a subscriber |
| `publish-to-pending-subscription` | Track publishing | Rendezvous a subscriber-first request with PUBLISH delivery |
| `subscribe-one-subgroup-per-group` | Data plane | Deliver one Subgroup in each of multiple Groups |
| `subscribe-one-subgroup-per-object` | Data plane | Deliver every Object in a distinct Subgroup |
| `subscribe-two-subgroups-per-group` | Data plane | Deliver two interleaved Subgroups in one Group |
| `subscribe-nonzero-start-group` | Data plane | Begin publication at a nonzero Group ID |
| `subscribe-nonzero-start-object` | Data plane | Begin publication at a nonzero Object ID |
| `subscribe-sparse-group-object-ids` | Data plane | Deliver sparse Group and Object identifiers |
| `subscribe-object-properties` | Data plane | Preserve deterministic application-specific Object Properties |

### Interface Summary

**CLI**:
```bash
moq-test-client -r <RELAY_URL> [-t <TEST>] [--tls-disable-verify]
```

**Environment**:
- `RELAY_URL` - Relay URL (required)
- `TESTCASE` - Specific test (optional)
- `TLS_DISABLE_VERIFY=1` - Skip cert verification (optional)

**Exit codes**: 0 = success, 1 = failure, 127 = unknown selected test ID

**Output**: TAP version 14 on stdout (see [TEST-CLIENT-INTERFACE.md](./TEST-CLIENT-INTERFACE.md))
