#!/bin/bash
# Integration test suite for triage-cache binary.
# Isolates tests from real APIs using mock glab/git scripts on PATH.
#
# Usage: ./tests/run-all.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$REPO_DIR/triage-cache"
MOCK_DIR="$SCRIPT_DIR/mocks"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"

RESULT_DIR="$(mktemp -d)"
TOTAL=10

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────────

setup_test() {
  local test_name="$1"
  TEST_TMPDIR="$(mktemp -d)"
  TEST_CACHE_DIR="$TEST_TMPDIR/cache"
  TEST_STUDIO_DIR="$TEST_TMPDIR/studio"
  mkdir -p "$TEST_CACHE_DIR" "$TEST_STUDIO_DIR/.worktrees/feature-branch"

  export TRIAGE_CACHE_DIR="$TEST_CACHE_DIR"
  export TRIAGE_STUDIO_DIR="$TEST_STUDIO_DIR"
  export MOCK_FIXTURE_DIR="$FIXTURE_DIR"
  export MOCK_FIXTURE_SET="default"
  unset MOCK_GLAB_AUTH_FAIL 2>/dev/null || true
  export PATH="$MOCK_DIR:$PATH"

  printf "  ${BOLD}Test: %s${RESET} ... " "$test_name"
}

teardown_test() {
  rm -rf "$TEST_TMPDIR"
}

pass() {
  printf "${GREEN}PASS${RESET}\n"
  echo "1" >> "$RESULT_DIR/passed"
}

fail() {
  printf "${RED}FAIL${RESET}\n"
  if [[ -n "${1:-}" ]]; then
    printf "    ${RED}→ %s${RESET}\n" "$1"
  fi
  echo "1" >> "$RESULT_DIR/failed"
}

assert_stdout_contains() {
  local stdout="$1"
  local pattern="$2"
  if ! echo "$stdout" | grep -qF -- "$pattern"; then
    fail "stdout missing: '$pattern'"
    echo "    stdout was:"
    echo "$stdout" | head -5 | sed 's/^/    | /'
    return 1
  fi
  return 0
}

assert_stdout_not_empty() {
  local stdout="$1"
  if [[ -z "$stdout" ]]; then
    fail "stdout was empty"
    return 1
  fi
  return 0
}

assert_exit_code() {
  local actual="$1"
  local expected="$2"
  if [[ "$actual" != "$expected" ]]; then
    fail "exit code $actual, expected $expected"
    return 1
  fi
  return 0
}

assert_file_exists() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    fail "file not found: $path"
    return 1
  fi
  return 0
}

assert_file_not_exists() {
  local path="$1"
  if [[ -f "$path" ]]; then
    fail "file should not exist: $path"
    return 1
  fi
  return 0
}

assert_valid_json() {
  local path="$1"
  if ! python3 -c "import json; json.load(open('$path'))" 2>/dev/null; then
    fail "invalid JSON in $path"
    return 1
  fi
  return 0
}

# ── Build ────────────────────────────────────────────────────────────────────

printf "\n${BOLD}Building triage-cache...${RESET}\n"
(cd "$REPO_DIR" && swiftc Sources/*.swift -o triage-cache 2>&1)
printf "${GREEN}Build succeeded.${RESET}\n\n"
printf "${BOLD}Running %d tests:${RESET}\n\n" "$TOTAL"

# ── Test 1: First run (no cache) ────────────────────────────────────────────

setup_test "1. First run (no cache) → FULL + first_run"
(
  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: FULL" || ok=false
  assert_stdout_contains "$stdout" "REASON: first_run" || ok=false
  assert_stdout_contains "$stdout" "---RAW_DATA---" || ok=false
  assert_file_exists "$TEST_CACHE_DIR/last-run.json" || ok=false
  assert_valid_json "$TEST_CACHE_DIR/last-run.json" || ok=false

  $ok && pass
)
teardown_test

# ── Test 2: Repeat run (no changes) → NO_CHANGES ────────────────────────────

setup_test "2. Repeat run (no changes) → NO_CHANGES"
(
  # First run: creates cache
  "$BINARY" >/dev/null 2>&1

  # Save a report
  "$BINARY" --save-report "Test report content
My recommendation: keep working" 2>/dev/null

  # Second run with same data: should get NO_CHANGES
  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: NO_CHANGES" || ok=false
  assert_stdout_contains "$stdout" "CACHE_AGE_MINUTES:" || ok=false
  assert_stdout_contains "$stdout" "---PREVIOUS_REPORT---" || ok=false
  assert_stdout_contains "$stdout" "Test report content" || ok=false
  assert_stdout_contains "$stdout" "PREVIOUS_RECOMMENDATION:" || ok=false

  $ok && pass
)
teardown_test

# ── Test 3: Repeat run (MR status changed) → DELTA ──────────────────────────

setup_test "3. Repeat run (MR changed) → DELTA"
(
  # First run with default fixtures
  "$BINARY" >/dev/null 2>&1

  # Save a report so we can check it persists
  "$BINARY" --save-report "Initial report
My recommendation: review MRs" 2>/dev/null

  # Second run with changed MR (detailed_merge_status: not_approved → approved)
  export MOCK_FIXTURE_SET="changed-mr"
  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: DELTA" || ok=false
  assert_stdout_contains "$stdout" "CHANGES_SUMMARY:" || ok=false
  assert_stdout_contains "$stdout" "---CHANGES---" || ok=false
  assert_stdout_contains "$stdout" "detailed_merge_status" || ok=false
  assert_stdout_contains "$stdout" "---PREVIOUS_REPORT---" || ok=false

  $ok && pass
)
teardown_test

# ── Test 4: Priority label changed → FULL + priority_labels_changed ─────────

setup_test "4. Priority label changed → FULL + priority_labels_changed"
(
  # First run with default fixtures (issue 10 has p::1)
  "$BINARY" >/dev/null 2>&1

  # Second run with priority-changed fixtures (issue 10 now has p::2)
  export MOCK_FIXTURE_SET="priority-changed"
  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: FULL" || ok=false
  assert_stdout_contains "$stdout" "REASON: priority_labels_changed" || ok=false

  $ok && pass
)
teardown_test

# ── Test 5: Cache expired (>1h) → FULL + cache_expired ──────────────────────

setup_test "5. Cache expired (>1h) → FULL + cache_expired"
(
  # Create a cache with a timestamp > 1 hour ago
  old_ts=$(date -u -v-2H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "2 hours ago" +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$TEST_CACHE_DIR/last-run.json" <<CACHE
{
  "version": 1,
  "timestamp": "$old_ts",
  "ttl_seconds": 3600,
  "snapshot": {"non_draft_mrs":[],"draft_mrs":[],"sandcastle_mrs":[],"issues":[],"worktrees":[],"merged_branches":[]},
  "report": null,
  "recommendation": null
}
CACHE

  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: FULL" || ok=false
  assert_stdout_contains "$stdout" "REASON: cache_expired" || ok=false

  $ok && pass
)
teardown_test

# ── Test 6: Corrupt cache → FULL + cache_corrupt + old file deleted ──────────

setup_test "6. Corrupt cache → FULL + cache_corrupt"
(
  # Write garbage to cache file
  echo "this is not json {{{" > "$TEST_CACHE_DIR/last-run.json"

  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: FULL" || ok=false
  assert_stdout_contains "$stdout" "REASON: cache_corrupt" || ok=false

  # After run, cache should be valid JSON (rewritten by the binary)
  assert_file_exists "$TEST_CACHE_DIR/last-run.json" || ok=false
  assert_valid_json "$TEST_CACHE_DIR/last-run.json" || ok=false

  $ok && pass
)
teardown_test

# ── Test 7: Schema version mismatch → treated as corrupt ────────────────────

setup_test "7. Schema version mismatch → FULL (treated as corrupt)"
(
  # Write valid JSON but with wrong schema version
  cat > "$TEST_CACHE_DIR/last-run.json" <<CACHE
{
  "version": 999,
  "timestamp": "2026-05-12T10:00:00Z",
  "ttl_seconds": 3600,
  "snapshot": {},
  "report": null,
  "recommendation": null
}
CACHE

  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: FULL" || ok=false
  assert_stdout_contains "$stdout" "REASON: cache_corrupt" || ok=false

  $ok && pass
)
teardown_test

# ── Test 8: --force flag → always FULL ───────────────────────────────────────

setup_test "8. --force flag → always FULL"
(
  # Create a valid, fresh cache so normally we'd get NO_CHANGES or DELTA
  "$BINARY" >/dev/null 2>&1

  # Run with --force: should still get FULL
  stdout=$("$BINARY" --force 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: FULL" || ok=false

  $ok && pass
)
teardown_test

# ── Test 9: --save-report → updates cache fields ────────────────────────────

setup_test "9. --save-report → updates cache report + recommendation"
(
  # First run to create cache
  "$BINARY" >/dev/null 2>&1

  # Save a report
  report_text="## Triage Report
- MR !100 needs review
My recommendation: Focus on MR !100"

  stdout=$("$BINARY" --save-report "$report_text" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false

  # Verify cache file has report and recommendation
  cache_content=$(cat "$TEST_CACHE_DIR/last-run.json")
  if ! echo "$cache_content" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert data.get('report') is not None, 'report is null'
assert 'MR !100' in data['report'], 'report missing content'
assert data.get('recommendation') is not None, 'recommendation is null'
" 2>/dev/null; then
    fail "cache file missing report or recommendation"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 10: glab not found → exit 1, error on stderr, no stdout ────────────

setup_test "10. glab not found → exit 1 + stderr error"
(
  export PATH="/usr/bin:/bin"

  exit_code=0
  stdout=$("$BINARY" 2>/tmp/test10_stderr) || exit_code=$?
  stderr_content=$(cat /tmp/test10_stderr)
  rm -f /tmp/test10_stderr
  ok=true

  assert_exit_code "$exit_code" "1" || ok=false

  # stdout should be empty
  if [[ -n "$stdout" ]]; then
    fail "stdout should be empty when glab not found"
    ok=false
  fi

  # stderr should have error message
  if ! echo "$stderr_content" | grep -qi "glab"; then
    fail "stderr should mention glab"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Summary ──────────────────────────────────────────────────────────────────

PASSED=0
FAILED=0
if [[ -f "$RESULT_DIR/passed" ]]; then
  PASSED=$(wc -l < "$RESULT_DIR/passed" | tr -d ' ')
fi
if [[ -f "$RESULT_DIR/failed" ]]; then
  FAILED=$(wc -l < "$RESULT_DIR/failed" | tr -d ' ')
fi
rm -rf "$RESULT_DIR"

printf "\n${BOLD}Results: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET} out of %d\n\n" "$PASSED" "$FAILED" "$TOTAL"

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
exit 0
