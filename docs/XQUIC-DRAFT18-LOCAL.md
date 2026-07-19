# xquic draft-18 local pipeline

The runner registers the draft-18 client as `xquic-draft-18`, separately from
the legacy draft-14 xquic relay/client entry. The client is raw-QUIC-only and
currently advertises `setup-only` and `announce-only`.

## 1. Start the local container runtime

On Apple Silicon macOS:

```bash
make local-runtime-start
make local-runtime-status
```

The pinned Docker CLI, Compose, Colima, and Lima binaries live under the
gitignored `.local-tools/` directory. Colima VM state lives under
`~/.moq-interop-colima` to keep its Unix socket path short.

On macOS, the pipeline stages only certificates and runtime logs under
`~/.moq-interop-colima/io`. This avoids the operating system's protected
Documents-directory restriction on Colima's virtiofs process; source code and
test reports remain in the checkout.

## 2. Run the closed-loop pipeline

Build the current xquic checkout, pull the registered moq-rs draft-18 relay,
run the supported cases, and render the result as HTML:

```bash
make xquic-local-pipeline \
  XQUIC_SOURCE=/absolute/path/to/xquic
```

The images and protocol version used by this path are:

| Role | Registry key / image | Draft | Transport |
|---|---|---|---|
| client | `xquic-draft-18` / `xquic-moq-client-draft-18:latest` | draft-18 | raw QUIC |
| relay | `moq-rs-draft-18` / GHCR relay image | draft-18 | raw QUIC |

Each run writes `summary.json`, endpoint logs, and `report.html` under a unique
`results/<timestamp>-xquic-draft18-local/` directory. `results/index.html`
links all generated runs.

## 3. Run the remote draft-18 matrix

Use every active draft-18 raw-QUIC endpoint in `implementations.json`:

```bash
make xquic-client-test-draft18 \
  XQUIC_SOURCE=/absolute/path/to/xquic
```

Pass runner filters through `XQUIC_TEST_ARGS`, for example:

```bash
make xquic-client-test-draft18 \
  XQUIC_TEST_ARGS="--relay moq-rs-draft-18"
```

### Validation snapshot

The xquic `moq/draft_18_dev` branch at commit `6c67044` was validated on
2026-07-19 against every registered draft-18 raw-QUIC endpoint:

| Relay | `setup-only` | `announce-only` |
|---|---:|---:|
| `imquic` | Pass | Pass |
| `moq-rs-draft-18` | Pass | Pass |
| `moqt-nr` | Pass | Pass |
| `moqx` | Pass | Pass |
| `moxygen` | Pass | Pass |

The generated detail report records all five combinations as `2/2` with no
failures. Result directories remain gitignored and are intended as local or CI
artifacts rather than source files.

## Wireshark capture

The Compose relay listens on UDP port `4443`, and the host publishes the same
port (`4443/udp -> 4443/udp`). Use this Wireshark display filter:

```text
udp.port == 4443
```

Or use the capture filter `udp port 4443` before starting the pipeline.

On macOS with Colima, the normal pipeline's client-to-relay traffic stays on a
Docker bridge inside the Colima VM. Capturing only the Mac's Wi-Fi interface
can therefore miss it. Capture all relevant interfaces, or capture inside the
VM and open the resulting `.pcap` in Wireshark:

```bash
RUNNER_ROOT="$(pwd)"
mkdir -p "$RUNNER_ROOT/results"
(cd /tmp && "$RUNNER_ROOT/scripts/local-container-env.sh" colima ssh -- \
  sudo tcpdump -i any -s 0 -w /tmp/xquic-draft18.pcap 'udp port 4443')
```

Run the pipeline in a second terminal, stop `tcpdump` with Ctrl-C, then copy
the capture to the host:

```bash
(cd /tmp && "$RUNNER_ROOT/scripts/local-container-env.sh" colima ssh -- \
  cat /tmp/xquic-draft18.pcap) > "$RUNNER_ROOT/results/xquic-draft18.pcap"
```

The `cd /tmp` is intentional: the Colima VM cannot enter the macOS-protected
`Documents` working directory when starting an SSH command.
