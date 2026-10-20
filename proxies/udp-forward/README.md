# udp-forward

A stand-in proxy for testing the runner's proxy hop
([docs/PROXY-TESTING.md](../../docs/PROXY-TESTING.md)). It forwards each
client's UDP flow to the relay with `socat` and does nothing else: TLS and
MoQT pass through untouched, so it lists no `draft_versions` and proxied runs
negotiate what the direct runs do.

A proxied run through it should give the same result as the direct run of
the same pair. A difference points at the runner's proxy plumbing (or at a
relay that depends on the client's address), not at a MoQT implementation.

It is not a registered implementation: [overlay.json](overlay.json) adds it
for a run.

```sh
make build-udp-forward-proxy
./run-interop-tests.sh --docker-only --overlay proxies/udp-forward/overlay.json \
    --proxy udp-forward --relay moxygen
```

It reads `MOQT_PORT`, `MOQT_UPSTREAM_HOST` and `MOQT_UPSTREAM_PORT` from the
proxy contract and ignores the rest.
