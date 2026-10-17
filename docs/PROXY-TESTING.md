# Testing Through a Proxy

The runner can put a MoQT proxy between each test client and the relay under
test:

```
test-client ──► proxy ──► relay
```

A proxy here is anything that terminates or forwards a client's MoQT session
on the way to one relay: a session-level MoQT proxy, a middlebox, an edge
that opens its own upstream session per client. The runner treats it as a
black box with a small image contract (below). It does not need a cache, and
it does not have to understand every message.

Every proxied run has a direct control: the same client and relay, with no
proxy, in the same run. A test that passes directly and fails through the
proxy points at the proxy. One that fails both ways is a client or relay
issue, the same as without the proxy.

## Running

Proxies are registered like other implementations, with a `proxy` role. One
that is not in `implementations.json` can be added for a run with an overlay
(below). The repository has a stand-in, [proxies/udp-forward](../proxies/udp-forward/),
which forwards UDP unchanged and is useful for checking the setup:

```sh
make build-udp-forward-proxy
./run-interop-tests.sh --docker-only \
    --overlay proxies/udp-forward/overlay.json --proxy udp-forward --relay moxygen
```

The same with Make:

```sh
make interop-proxy PROXY=udp-forward OVERLAY=proxies/udp-forward/overlay.json RELAY=moxygen
```

| Flag | Effect |
|------|--------|
| `--proxy NAME` | For every Docker client × relay pair, also run it through `NAME` |
| `--proxy-only` | Skip the direct runs (Docker and remote); keeps only proxied ones |
| `--overlay FILE` | Merge `FILE` over `implementations.json` for this run |

Proxied runs apply to Docker relay images only. Remote endpoints still run
directly unless `--docker-only` or `--proxy-only` is given. `--dry-run` shows
the proxied runs in the plan as mode `docker-via-<proxy>`.

A single pair can be run by hand with `make test-proxy`:

```sh
make test-proxy PROXY_IMAGE=my-proxy:latest RELAY_IMAGE=moxygen-interop:latest \
    CLIENT_IMAGE=ghcr.io/facebookexperimental/moxygen-interop-client:latest-amd64 \
    MOQT_DRAFT=draft-18
```

## Topology

`make test-proxy` adds [docker-compose.proxy.yml](../docker-compose.proxy.yml)
to [docker-compose.test.yml](../docker-compose.test.yml):

| Service | Runs | Hostname |
|---------|------|----------|
| `test-client` | the client image, unchanged | |
| `relay` | **the proxy** | `relay` |
| `moq-relay` | the relay image | `moq-relay` |

The proxy takes over the `relay` hostname, so clients use the URL they use
without a proxy (`https://relay:4443`, or the relay's `docker.url`), with the
same SNI and authority. The test certificate already covers both `relay` and
`moq-relay`, so the proxy can serve it to clients and verify the relay with it.

Startup order is `moq-relay`, then the proxy, then the client, each waiting
for the previous one's UDP port.

## Proxy image contract

The image runs with the same conventions as a relay image (non-root user
`1000:65534`, certificates at `/certs`, `/mlog` writable), plus these
environment variables:

| Variable | Example | Meaning |
|----------|---------|---------|
| `MOQT_ROLE` | `proxy` | |
| `MOQT_PORT` | `4443` | UDP port to listen on |
| `MOQT_PROXY_HOST` | `relay` | Hostname clients connect to: the SNI and authority they send |
| `MOQT_DRAFT` | `draft-18` | Draft the runner expects this run to negotiate |
| `MOQT_UPSTREAM_URL` | `moqt://moq-relay:4443` | The relay's URL, as clients would see it, with the host replaced |
| `MOQT_UPSTREAM_HOST` | `moq-relay` | |
| `MOQT_UPSTREAM_PORT` | `4443` | |
| `MOQT_UPSTREAM_PATH` | (empty) | Path of the relay's URL, empty if it has none |
| `MOQT_UPSTREAM_CA` | `/certs/cert.pem` | CA to verify the relay's certificate with (the self-signed test certificate) |
| `SSLKEYLOGFILE` | `/mlog/sslkeylog.txt` | Optional: where to write TLS secrets, for decrypting captures |

The certificate and key for the proxy's own listener are `/certs/cert.pem`
and `/certs/priv.key`. Write any generated configuration under `/tmp`. The
proxy's logs (stdout and stderr) end up in the run's log next to the client's
and relay's, and `/mlog` is kept in `mlog/proxy/` until the next run.

`MOQT_UPSTREAM_URL` keeps the scheme of the relay's registered URL. A proxy
that always reaches relays over one transport should use the host, port and
path, and declare `upstream_transports` (below).

## Registering a proxy

A proxy entry has a `proxy` role with a Docker image:

```json
{
  "implementations": {
    "example-proxy": {
      "name": "Example MoQT Proxy",
      "draft_versions": ["draft-22", "draft-18"],
      "roles": {
        "proxy": {
          "docker": { "image": "example-proxy:latest" },
          "upstream_transports": ["quic"]
        }
      }
    }
  }
}
```

- **`draft_versions`**: drafts the proxy speaks. A proxied run's draft is the
  newest one that the client, the proxy and the relay all support. Leave it
  out for a proxy that passes MoQT through without parsing it (such as
  `udp-forward`); the run then negotiates what the direct run does. Proxies
  that translate between drafts are not supported yet.
- **`upstream_transports`**: how the proxy reaches the relay (`quic`,
  `webtransport`). Leave it out if the proxy uses the client's transport.
  A relay image can declare what it serves in `roles.relay.docker.transports`.
  When both are declared and share nothing, the proxied run is skipped with
  the reason; otherwise it runs.

An entry with only a `proxy` role never appears as a client or a relay.

### Overlays

`--overlay FILE` merges `FILE` into `implementations.json` for one run, with
`jq`'s recursive object merge (`*`): objects merge key by key, and arrays
and other values in the overlay replace the ones in the registry. An overlay
can add implementations, or add a field to an existing one, for example a
relay's `docker.transports`. It is for implementations that are not, or not
yet, in the registry: a private build, or a proxy under development.

## Results

- **Console**: each proxied run is shown as `client → proxy → relay`. The
  summary ends with the proxied runs that failed where the direct run of the
  same pair passed.
- **`summary.json`**: proxied runs have `"mode": "docker-via-<proxy>"`,
  `"proxy"` and `"proxy_image"`. Logs are
  `<client>_to_<relay>_docker-via-<proxy>.log`.
- **HTML report** (`make report`): `report.html` stays direct-only and links
  to `report-via-<proxy>.html`. That page has the matrix of proxied runs and
  a table of the tests that fail through the proxy but not in the direct run
  of the same pair and draft.

## Triage

For each test in the "fails via proxy, not directly" table:

1. Open both logs. The proxied log has the proxy's output between the
   client's and the relay's.
2. Rerun the pair by hand (`make test-proxy … TESTCASE=<test>`), with
   `VERBOSE=1` if the client supports it. Run it more than once: a test that
   fails intermittently in both modes is not the proxy's.
3. With `SSLKEYLOGFILE` honoured, captures of both hops can be decrypted.

Some failures are the client's or relay's even though they only show through
a proxy. A client can leave out a SETUP parameter that a relay ignores but a
routing proxy needs, for example. Report them to the implementation,
not as proxy failures.
