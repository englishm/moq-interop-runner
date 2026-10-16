# Decision: Testing Through a Proxy

**Date:** 2026-10-16

## Problem

MoQT deployments are not always a client talking straight to a relay. CDNs
and edges put session-level proxies and middleboxes in between, which open
their own upstream session per client, rewrite control messages, or route on
SETUP parameters. Interop problems there only show with a real client on one
side and a real relay on the other, and the runner could only run the two
directly.

## Decision

Add an optional third container, the proxy, to Docker runs:
`test-client → proxy → relay`. See [PROXY-TESTING.md](../PROXY-TESTING.md)
for the contract and usage.

### The proxy takes over the relay's hostname

The proxy runs as the `relay` service and the relay as `moq-relay`. The
other way round, clients would need a different URL for proxied runs, and the
runner would have to rewrite each relay's `docker.url`. That URL also selects
the transport for many clients (see
[003](003-url-scheme-transport-selection.md)), so rewriting it risks changing
what is tested. With the swap, clients send exactly the URL, SNI and authority
they send without a proxy, and the test certificate already covers both names.

### Direct controls in the same run

`--proxy` runs every pair both directly and through the proxy, and reports
the tests that fail only through the proxy. Without the control, a proxied
failure says little, because many pairs already fail some tests directly.
`--proxy-only` is there for repeat runs.

### Proxies do not translate drafts (yet)

A proxied run's draft is predicted as the newest one shared by the client,
the proxy and the relay, the same rule as
[002](002-version-selection-strategy.md) with one more party. A proxy that
lists no `draft_versions` is transparent and does not constrain it. A proxy
that negotiates separately on each side would need two predicted versions
per run. Nothing needs that yet, so the runner does not model it.

### Overlays for unregistered implementations

`--overlay` merges a JSON file over `implementations.json` for one run.
Proxies under development, or ones that cannot be published, can then be
tested without a registry entry. Results of those runs stay with whoever
ran them. The runner's CI does not use overlays.

### Separate report pages

The report's matrix merges all of a pair's runs into one cell. Proxied runs
get their own page per proxy instead, so a proxy's failures neither hide in
nor change the direct matrix.

## Consequences

- Proxy images follow a contract like relay images do: the `MOQT_*`
  variables, `/certs` and `/mlog`.
- Results gain an optional `proxy` field and `docker-via-<proxy>` modes.
  Reports of runs without a proxy are unchanged.
- Only Docker relays can be proxied. Proxying to remote endpoints, and
  chains of proxies, are left until someone needs them.
