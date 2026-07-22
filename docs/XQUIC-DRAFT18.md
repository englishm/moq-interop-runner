# xquic draft-18 interoperability

The runner registers the draft-18 xquic client and relay as `xquic-draft-18`,
separately from the existing draft-14 `xquic` entry. Both roles use raw QUIC
and support the six core cases: `setup-only`, `announce-only`,
`publish-namespace-done`, `subscribe-error`, `announce-subscribe`, and
`subscribe-before-announce`.

In draft-18, `publish-namespace-done` cancels the PUBLISH_NAMESPACE
bidirectional request stream with the MOQT `CANCELLED` (`0x1`) stream error;
it does not send the legacy PUBLISH_NAMESPACE_DONE message. SUBSCRIBE uses its
own bidirectional request stream, with `SUBSCRIBE_OK` or `REQUEST_ERROR`
returned on that same stream.

## Build

Build from xquic's `moq/draft_18_dev` branch:

```bash
make xquic-client-build XQUIC_SOURCE=/absolute/path/to/xquic
```

This produces `xquic-moq-client-draft-18:latest`. The test script re-tags that
local image with the name registered in `implementations.json`; it does not
modify the shared registry or any relay configuration.

Build the relay from the same checkout with:

```bash
make xquic-relay-build XQUIC_SOURCE=/absolute/path/to/xquic
```

This produces `xquic-moq-relay-draft-18:latest`. The relay listens on UDP/4443;
its container reads TLS material from `/certs/cert.pem` and
`/certs/priv.key`.

## Run the draft-18 remote matrix

```bash
make xquic-client-test-draft18
```

To build and test the current checkout in one command:

```bash
make xquic-client-test-draft18 \
  XQUIC_SOURCE=/absolute/path/to/xquic
```

Additional runner filters can be passed through `XQUIC_TEST_ARGS`:

```bash
make xquic-client-test-draft18 \
  XQUIC_TEST_ARGS="--relay moq-rs-draft-18"
```

The command runs only draft-18 raw-QUIC endpoints, writes the normal runner
`summary.json` and endpoint logs under `results/`, and generates `report.html`
with the existing report generator.
