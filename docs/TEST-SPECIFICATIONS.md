# MoQT Test Specifications

This document has been reorganized into separate, focused documents:

| Document | Content |
|----------|---------|
| **[tests/TEST-CASES.md](./tests/TEST-CASES.md)** | Test case definitions with protocol references |
| **[TEST-CLIENT-INTERFACE.md](./TEST-CLIENT-INTERFACE.md)** | CLI, environment variables, exit codes, output format |
| **[IMPLEMENTING-A-TEST-CLIENT.md](./IMPLEMENTING-A-TEST-CLIENT.md)** | Guide for implementing a compatible test client |

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

### Interface Summary

**CLI**:
```bash
moq-test-client -r <RELAY_URL> [-t <TEST>] [--tls-disable-verify]
```

**Environment**:
- `RELAY_URL` - Relay URL (required)
- `TESTCASE` - Specific test (optional)
- `TLS_DISABLE_VERIFY=1` - Skip cert verification (optional)

**Exit codes**: 0 = success, 1 = failure, 127 = unsupported test

**Output**: TAP version 14 on stdout (see [TEST-CLIENT-INTERFACE.md](./TEST-CLIENT-INTERFACE.md))
