# moxygen Conformance Client Registration Contract

This document defines the minimum contract for a future moxygen draft-18 conformance-client image. It does not register an image. `implementations.json` must not change until a real `linux/amd64` image is published and its manifest digest is verified.

Registration is then a one-file PR changing only `implementations.json`, but that change provides TAP-compatible scheduling only. Full ingestion and evaluation of the profile's assertion, evidence, provenance, and opaque-deployment records requires a later runner result/evidence PR. The registration PR does not make the current runner profile-evidence-aware.

## Container Interface

The image entrypoint must conform to the existing test-client interface:

- `RELAY_URL` is required and identifies the relay under test.
- `TESTCASE` is optional. When present in a manual run, it is one profile-local `MOXYGEN-D18-CASE-NNN` source-binding handle.
- `TLS_DISABLE_VERIFY=1` disables peer certificate verification. Other values must not silently disable verification. The future wrapper must actively plumb this setting to both relevant moxygen connections; the reviewed baseline's unconditional insecure verifier is not acceptable executable behavior.
- `--list` prints exactly one supported source-binding handle per line and exits 0. The initial scheduled set is the seven source bindings mapped to diagnostic gates. Deferred bindings are unsupported.
- Standard output is valid TAP version 14. Diagnostic logs go to standard error or valid indented TAP diagnostics, never unframed standard output.
- Exit 0 means every requested case passed. Exit 1 means at least one requested case failed or the harness/readiness/evidence path failed. Exit 127 means the selected `TESTCASE` is unknown, deferred, or otherwise unsupported.
- Each moxygen case has an enforced timeout selected from the manifest after publisher readiness. Diagnostic gates and ordinary intended cases use 10 seconds; intended slow cases 044 and 046 use at least 30 seconds. Every wrapper timeout remains below the runner's 120-second whole-container limit. Server attachment has its own bounded readiness timeout.

The current runner invokes a client image once, without `TESTCASE`, under one 120-second whole-container timeout. Therefore the initial registered entrypoint must default to the seven diagnostic gates only and complete all seven within that limit. The other 22 intended declarations remain manual/full-profile cases until a later per-case scheduling PR; they must not run in the initial scheduled default.

The wrapper must invoke each moxygen declaration separately and map its exact source ordinal and name to the profile-local binding handle. It must reject ambiguous moxygen output strictly:

- Exactly one `MoQTest verification result: SUCCESS` and no `MoQTest verification result: FAILURE` is eligible to pass.
- One or more FAILURE markers fail the case.
- Mixed SUCCESS and FAILURE markers fail the case, regardless of order.
- Missing, repeated, truncated, or otherwise ambiguous terminal markers fail the case.
- A zero child exit status cannot override failed or ambiguous output.

The reviewed baseline verifier can falsely fail on global ordering across independently scheduled subgroup streams. Registration is blocked until the image identifies a fixed full executable SHA with corrected ordering behavior. Historical or manual ordering-only failures are inconclusive evidence, not relay failures; the current TAP report cannot represent this driver-inconclusive state.

## Three-Party Readiness

The logical topology for subscription cases is:

```text
moxygen moqtest_server -> relay under test -> moxygen conformance client
```

The image may package the server and client in one container, but they remain separate MOQT sessions and roles. Before starting a case, the wrapper must:

1. Start `moqtest_server` and have it attach to `RELAY_URL`.
2. Observe the relay's draft-18 `REQUEST_OK` response to the server's PUBLISH_NAMESPACE request for the `moq-test-00` namespace.
3. Record that decoded response, connection role, and timestamp as readiness evidence.
4. Only then start the conformance client case.

Process liveness, a listening socket, elapsed sleep, or successful SETUP alone is not readiness. Failure to observe REQUEST_OK within the readiness timeout is a harness failure and exit 1, not a relay conformance result.

## Image Requirement

The eventual image must:

- Be published for `linux/amd64`.
- Be referenced by an immutable OCI manifest digest in the form `registry/repository@sha256:<64 lowercase hexadecimal characters>`.
- Contain the wrapper, moxygen client, and moxygen server versions identified in TAP diagnostics.
- Identify the actual full executable driver SHA; the reference baseline SHA is insufficient and `TBD` is forbidden in executable output.
- Advertise only draft-18 for this registration.
- Produce enough metadata to reproduce the image, command, profile revision, and pinned source revisions.

A mutable tag such as `:latest`, a tag plus an unverified digest, an architecture index that does not resolve to `linux/amd64`, or a guessed digest is not acceptable.

## Eventual Registry Entry

After the image exists, its fixed ordering behavior and executable SHA are pinned, and the seven-gate default completes below 120 seconds, insert the following key in alphabetical order under `implementations`. Replace both angle-bracket placeholders with verified release data; do not paste this template before then.

```json
"moxygen-conformance": {
  "name": "moxygen conformance client (draft-18)",
  "organization": "Meta",
  "repository": "https://github.com/facebookexperimental/moxygen",
  "draft_versions": [
    "draft-18"
  ],
  "notes": "Profile-driven moxygen MoQTest conformance client. Source/profile release: <release-identifier>. Image is linux/amd64 and digest-pinned.",
  "roles": {
    "client": {
      "docker": {
        "image": "<registry>/<repository>@sha256:<64-lowercase-hex-digest>",
        "notes": "Implements RELAY_URL, optional TESTCASE, TLS_DISABLE_VERIFY=1, --list, TAP14, exit 0/1/127, strict terminal-marker parsing, per-case timeouts, and observed REQUEST_OK readiness."
      }
    }
  }
}
```

Those are the exact eventual entry fields. Build metadata, mutable fallback tags, local build paths, and runner-specific exceptions do not belong in the registration.
