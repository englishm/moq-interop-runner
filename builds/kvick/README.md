# kvick relay build

Build the kvick relay image from current upstream `main`:

```bash
./builds/kvick/build.sh --target relay
```

For local development, build a checkout or worktree directly:

```bash
./builds/kvick/build.sh --local /absolute/path/to/kvick-ai --target relay
```

The resulting image is `kvick-relay:latest`. Its entrypoint follows the runner
certificate and port conventions and configures a catch-all origin route. It
sets `unknown_track_subscribe_grace_ms = 750` as the #3827 interoperability
experiment value; kvick's shipped product default remains 2000 ms.

Run the entrypoint contract test without Docker:

```bash
./builds/kvick/test-entrypoint.sh
```
