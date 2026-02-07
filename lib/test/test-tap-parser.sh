#!/bin/bash
# lib/test/test-tap-parser.sh - Tests for the TAP parser
#
# Run with: bash lib/test/test-tap-parser.sh
# Outputs TAP format (naturally).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../tap-parser.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TESTS=0
FAILURES=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    TESTS=$((TESTS + 1))
    if [ "$expected" = "$actual" ]; then
        echo "ok $TESTS - $desc"
    else
        echo "not ok $TESTS - $desc"
        echo "  ---"
        echo "  expected: \"$expected\""
        echo "  actual: \"$actual\""
        echo "  ..."
        FAILURES=$((FAILURES + 1))
    fi
}

# ── Test: Basic TAP14 all passing ──────────────────────────────────────────

cat > "$TMPDIR/basic-pass.log" << 'EOF'
TAP version 14
1..3
ok 1 - setup-only
ok 2 - announce-only
ok 3 - subscribe-error
EOF

parse_tap_file "$TMPDIR/basic-pass.log"
assert_eq "basic TAP14: format detected" "tap14" "$TAP_FORMAT"
assert_eq "basic TAP14: 3 passed" "3" "$TAP_PASSED"
assert_eq "basic TAP14: 0 failed" "0" "$TAP_FAILED"
assert_eq "basic TAP14: 0 skipped" "0" "$TAP_SKIPPED"
assert_eq "basic TAP14: 3 total" "3" "$TAP_TOTAL"

# ── Test: TAP14 with failures ─────────────────────────────────────────────

cat > "$TMPDIR/mixed.log" << 'EOF'
TAP version 14
1..3
ok 1 - setup-only
not ok 2 - announce-only
  ---
  message: "timeout"
  ...
ok 3 - subscribe-error
EOF

parse_tap_file "$TMPDIR/mixed.log"
assert_eq "mixed TAP14: format detected" "tap14" "$TAP_FORMAT"
assert_eq "mixed TAP14: 2 passed" "2" "$TAP_PASSED"
assert_eq "mixed TAP14: 1 failed" "1" "$TAP_FAILED"
assert_eq "mixed TAP14: 3 total" "3" "$TAP_TOTAL"

# ── Test: TAP14 with SKIP ─────────────────────────────────────────────────

cat > "$TMPDIR/skip.log" << 'EOF'
TAP version 14
1..3
ok 1 - setup-only
ok 2 - announce-only
ok 3 - publish-namespace-done # SKIP not implemented
EOF

parse_tap_file "$TMPDIR/skip.log"
assert_eq "skip TAP14: 2 passed" "2" "$TAP_PASSED"
assert_eq "skip TAP14: 0 failed" "0" "$TAP_FAILED"
assert_eq "skip TAP14: 1 skipped" "1" "$TAP_SKIPPED"
assert_eq "skip TAP14: 3 total" "3" "$TAP_TOTAL"

# ── Test: TAP14 with TODO ───────────────────────────────────���─────────────

cat > "$TMPDIR/todo.log" << 'EOF'
TAP version 14
1..2
ok 1 - setup-only
not ok 2 - new-feature # TODO not yet implemented
EOF

parse_tap_file "$TMPDIR/todo.log"
assert_eq "todo TAP14: 2 passed (TODO not a failure)" "2" "$TAP_PASSED"
assert_eq "todo TAP14: 0 failed" "0" "$TAP_FAILED"
assert_eq "todo TAP14: 2 total" "2" "$TAP_TOTAL"

# ── Test: TAP14 with subtests (only count parent) ─────────────────────────

cat > "$TMPDIR/subtest.log" << 'EOF'
TAP version 14
1..2
ok 1 - setup-only
# Subtest: announce-subscribe
    1..3
    ok 1 - publisher connected
    ok 2 - subscriber connected
    not ok 3 - data received
ok 2 - announce-subscribe
EOF

parse_tap_file "$TMPDIR/subtest.log"
assert_eq "subtest TAP14: 2 passed (parent only)" "2" "$TAP_PASSED"
assert_eq "subtest TAP14: 0 failed (parent only)" "0" "$TAP_FAILED"
assert_eq "subtest TAP14: 2 total (parent only)" "2" "$TAP_TOTAL"

# ── Test: Legacy checkmark format ─────────────────────────────────────────

cat > "$TMPDIR/legacy.log" << 'EOF'
✓ setup-only (24 ms)
✓ announce-only (31 ms)
✗ subscribe-error (timeout after 2000 ms)
Results: 2 passed, 1 failed
MOQT_TEST_RESULT: FAILURE
EOF

parse_tap_file "$TMPDIR/legacy.log"
assert_eq "legacy: format detected" "legacy" "$TAP_FORMAT"
assert_eq "legacy: 2 passed" "2" "$TAP_PASSED"
assert_eq "legacy: 1 failed" "1" "$TAP_FAILED"
assert_eq "legacy: 3 total" "3" "$TAP_TOTAL"

# ── Test: TAP embedded in docker/make output ──────────────────────────────

cat > "$TMPDIR/docker-wrapped.log" << 'EOF'
Running interop tests...
  Relay:  moq-relay-ietf:latest
  Client: moq-test-client:latest
TAP version 14
1..2
ok 1 - setup-only
ok 2 - announce-only
EOF

parse_tap_file "$TMPDIR/docker-wrapped.log"
assert_eq "docker-wrapped: format detected" "tap14" "$TAP_FORMAT"
assert_eq "docker-wrapped: 2 passed" "2" "$TAP_PASSED"
assert_eq "docker-wrapped: 0 failed" "0" "$TAP_FAILED"

# ── Test: Empty/missing file ──────────────────────────────────────────────

parse_tap_file "$TMPDIR/nonexistent.log" || true
assert_eq "missing file: 0 total" "0" "$TAP_TOTAL"
assert_eq "missing file: unknown format" "unknown" "$TAP_FORMAT"

cat > "$TMPDIR/empty.log" << 'EOF'
EOF

parse_tap_file "$TMPDIR/empty.log" || true
assert_eq "empty file: 0 total" "0" "$TAP_TOTAL"

# ── Test: TAP14 with docker-compose prefix ────────────────────────────────

cat > "$TMPDIR/docker-compose-tap.log" << 'EOF'
 Container moq-interop-runner-relay-1  Recreate
 Container moq-interop-runner-relay-1  Recreated
Attaching to relay-1, test-client-1
relay-1        | Starting moq-rs relay on port 4443
test-client-1  | TAP version 14
test-client-1  | 1..3
test-client-1  | ok 1 - setup-only
test-client-1  | not ok 2 - announce-only
test-client-1  |   ---
test-client-1  |   message: "timeout"
test-client-1  |   ...
test-client-1  | ok 3 - subscribe-error
test-client-1 exited with code 1
EOF

parse_tap_file "$TMPDIR/docker-compose-tap.log"
assert_eq "docker-compose TAP: format detected" "tap14" "$TAP_FORMAT"
assert_eq "docker-compose TAP: 2 passed" "2" "$TAP_PASSED"
assert_eq "docker-compose TAP: 1 failed" "1" "$TAP_FAILED"
assert_eq "docker-compose TAP: 3 total" "3" "$TAP_TOTAL"

# ── Test: Legacy checkmarks with docker-compose prefix ────────────────────

cat > "$TMPDIR/docker-compose-legacy.log" << 'EOF'
relay-1        | Starting moq-rs relay on port 4443
test-client-1  | ✓ setup-only (24 ms) [CID: abc123]
test-client-1  | ✓ announce-only (31 ms) [CID: def456]
test-client-1  | ✗ subscribe-error (timeout after 2000 ms)
test-client-1  | 
test-client-1  | Results: 2 passed, 1 failed
test-client-1  | MOQT_TEST_RESULT: FAILURE
test-client-1 exited with code 1
EOF

parse_tap_file "$TMPDIR/docker-compose-legacy.log"
assert_eq "docker-compose legacy: format detected" "legacy" "$TAP_FORMAT"
assert_eq "docker-compose legacy: 2 passed" "2" "$TAP_PASSED"
assert_eq "docker-compose legacy: 1 failed" "1" "$TAP_FAILED"
assert_eq "docker-compose legacy: 3 total" "3" "$TAP_TOTAL"

# ── Test: TAP13 also accepted ─────────────────────────────────────────────

cat > "$TMPDIR/tap13.log" << 'EOF'
TAP version 13
1..2
ok 1 - setup-only
not ok 2 - announce-only
EOF

parse_tap_file "$TMPDIR/tap13.log"
assert_eq "TAP13: format detected as tap14" "tap14" "$TAP_FORMAT"
assert_eq "TAP13: 1 passed" "1" "$TAP_PASSED"
assert_eq "TAP13: 1 failed" "1" "$TAP_FAILED"

# ── Summary ───────────────────────────────────────────────────────────────

echo "1..$TESTS"

if [ "$FAILURES" -gt 0 ]; then
    echo "# $FAILURES of $TESTS tests failed"
    exit 1
fi
