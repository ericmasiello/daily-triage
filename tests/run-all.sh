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
TOTAL=25

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
  export TRIAGE_TODAY="2026-05-21"
  export MOCK_FIXTURE_DIR="$FIXTURE_DIR"
  export MOCK_FIXTURE_SET="default"
  unset MOCK_GLAB_AUTH_FAIL 2>/dev/null || true
  unset MOCK_TD_FAIL 2>/dev/null || true
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
(cd "$REPO_DIR" && swiftc -parse-as-library Sources/*.swift -o triage-cache 2>&1)
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
  "version": 2,
  "timestamp": "$old_ts",
  "ttl_seconds": 3600,
  "snapshot": {"non_draft_mrs":[],"draft_mrs":[],"sandcastle_mrs":[],"issues":[],"worktrees":[],"merged_branches":[]},
  "report": null,
  "recommendation": null,
  "todoist": null
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

# ── Test 11: glab auth expired → exit 1, actionable error ───────────────────

setup_test "11. glab auth expired → exit 1 + actionable error"
(
  export MOCK_GLAB_AUTH_FAIL=1

  exit_code=0
  stdout=$("$BINARY" 2>/tmp/test11_stderr) || exit_code=$?
  stderr_content=$(cat /tmp/test11_stderr)
  rm -f /tmp/test11_stderr
  ok=true

  assert_exit_code "$exit_code" "1" || ok=false

  if [[ -n "$stdout" ]]; then
    fail "stdout should be empty when auth expired"
    ok=false
  fi

  if ! echo "$stderr_content" | grep -q "glab auth login"; then
    fail "stderr should tell user to run 'glab auth login'"
    ok=false
  fi

  if ! echo "$stderr_content" | grep -q "token has expired"; then
    fail "stderr should surface the actual glab error detail"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 12: RAW_DATA JSON is compact (no newlines/indentation) ─────────────

setup_test "12. RAW_DATA JSON is compact (no newlines between keys)"
(
  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false

  raw_data=$(echo "$stdout" | sed -n '/---RAW_DATA---/,/---END_RAW_DATA---/p' | grep -v '^---')

  line_count=$(echo "$raw_data" | wc -l | tr -d ' ')
  if [[ "$line_count" -ne 1 ]]; then
    fail "RAW_DATA JSON should be a single line (compact), got $line_count lines"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 13: Issue objects have no description field ─────────────────────────

setup_test "13. Issue objects have no description field in RAW_DATA"
(
  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false

  raw_data=$(echo "$stdout" | sed -n '/---RAW_DATA---/,/---END_RAW_DATA---/p' | grep -v '^---')

  if echo "$raw_data" | grep -q '"description"'; then
    fail "RAW_DATA should not contain 'description' field"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 14: Merged branches filtered to worktree-matching only ──────────────

setup_test "14. Merged branches filtered to worktree matches only"
(
  export MOCK_FIXTURE_SET="many-branches"
  mkdir -p "$TEST_STUDIO_DIR/.worktrees/worktree-one"
  mkdir -p "$TEST_STUDIO_DIR/.worktrees/worktree-two"

  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false

  raw_data=$(echo "$stdout" | sed -n '/---RAW_DATA---/,/---END_RAW_DATA---/p' | grep -v '^---')

  branch_count=$(echo "$raw_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['merged_branches']))" 2>/dev/null)
  if [[ "$branch_count" != "2" ]]; then
    fail "expected 2 filtered branches, got ${branch_count:-parse_error}"
    ok=false
  fi

  if ! echo "$raw_data" | grep -q "worktree-one"; then
    fail "filtered branches should include worktree-one"
    ok=false
  fi
  if ! echo "$raw_data" | grep -q "worktree-two"; then
    fail "filtered branches should include worktree-two"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 15: v1 cache triggers cache_corrupt and fresh FULL run ──────────────

setup_test "15. v1 cache → cache_corrupt (v2 auto-invalidation)"
(
  cat > "$TEST_CACHE_DIR/last-run.json" <<CACHE
{
  "version": 1,
  "timestamp": "2026-05-12T10:00:00Z",
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
  assert_stdout_contains "$stdout" "REASON: cache_corrupt" || ok=false

  assert_file_exists "$TEST_CACHE_DIR/last-run.json" || ok=false
  assert_valid_json "$TEST_CACHE_DIR/last-run.json" || ok=false

  cache_version=$(python3 -c "import json; print(json.load(open('$TEST_CACHE_DIR/last-run.json'))['version'])" 2>/dev/null)
  if [[ "$cache_version" != "2" ]]; then
    fail "cache should be rewritten as version 2, got ${cache_version:-parse_error}"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 16: ANALYSIS section with PRD hierarchy ────────────────────────────

setup_test "16. FULL output contains ---ANALYSIS--- with prd_hierarchy"
(
  export MOCK_FIXTURE_SET="analysis-hierarchy"

  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: FULL" || ok=false
  assert_stdout_contains "$stdout" "---ANALYSIS---" || ok=false
  assert_stdout_contains "$stdout" "---END_ANALYSIS---" || ok=false
  assert_stdout_contains "$stdout" "---RAW_DATA---" || ok=false

  analysis_json=$(echo "$stdout" | sed -n '/---ANALYSIS---/,/---END_ANALYSIS---/p' | grep -v '^---')

  if ! echo "$analysis_json" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
    fail "ANALYSIS section is not valid JSON"
    ok=false
  fi

  if ! echo "$analysis_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert 'prd_hierarchy' in data, 'missing prd_hierarchy key'
h = data['prd_hierarchy']
assert len(h) == 1, f'expected 1 PRD, got {len(h)}'
prd = h[0]
assert prd['prd_iid'] == 7, f'expected prd_iid 7, got {prd[\"prd_iid\"]}'
assert len(prd['children']) == 3, f'expected 3 children, got {len(prd[\"children\"])}'
assert prd['completion']['total'] == 3, f'expected total 3, got {prd[\"completion\"][\"total\"]}'
assert prd['completion']['closed'] == 2, f'expected closed 2, got {prd[\"completion\"][\"closed\"]}'
assert prd['completion']['percentage'] == 66, f'expected 66%%, got {prd[\"completion\"][\"percentage\"]}'
" 2>/dev/null; then
    fail "ANALYSIS prd_hierarchy content is incorrect"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 17: Todoist data in FULL output ────────────────────────────────────

setup_test "17. Todoist tasks appear in FULL output with overdue/today/up_next"
(
  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: FULL" || ok=false

  raw_data=$(echo "$stdout" | sed -n '/---RAW_DATA---/,/---END_RAW_DATA---/p' | grep -v '^---')

  if ! echo "$raw_data" | python3 -c "
import sys, json
data = json.load(sys.stdin)
t = data['todoist']
assert len(t['overdue']) == 1, f'expected 1 overdue, got {len(t[\"overdue\"])}'
assert len(t['today']) == 1, f'expected 1 today, got {len(t[\"today\"])}'
assert len(t['up_next']) == 1, f'expected 1 up_next, got {len(t[\"up_next\"])}'
assert t['overdue'][0]['id'] == 'task-overdue-1', f'wrong overdue task id'
assert t['today'][0]['id'] == 'task-today-1', f'wrong today task id'
assert t['up_next'][0]['id'] == 'task-upnext-1', f'wrong up_next task id'
" 2>/dev/null; then
    fail "Todoist data incorrect in RAW_DATA"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 18: td failure → graceful degradation ──────────────────────────────

setup_test "18. td failure → todoist_error in output, exit 0"
(
  export MOCK_TD_FAIL=1

  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: FULL" || ok=false

  raw_data=$(echo "$stdout" | sed -n '/---RAW_DATA---/,/---END_RAW_DATA---/p' | grep -v '^---')

  if ! echo "$raw_data" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert data.get('todoist_error') is not None, 'todoist_error should be set'
assert data.get('todoist') is None, 'todoist should be null when td fails'
" 2>/dev/null; then
    fail "Graceful degradation incorrect"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 19: Todoist cached on NO_CHANGES (td fails on second run) ──────────

setup_test "19. Todoist cached on NO_CHANGES (td fails second run)"
(
  # First run: td succeeds, Todoist data cached
  "$BINARY" >/dev/null 2>&1

  # Second run: td fails, but cache has Todoist data
  export MOCK_TD_FAIL=1
  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: NO_CHANGES" || ok=false

  # Verify cache still has Todoist data
  if ! python3 -c "
import json
data = json.load(open('$TEST_CACHE_DIR/last-run.json'))
t = data['snapshot']['todoist']
assert t is not None, 'cached todoist should not be null'
assert len(t['overdue']) == 1, 'cached overdue should have 1 task'
assert len(t['today']) == 1, 'cached today should have 1 task'
assert len(t['up_next']) == 1, 'cached up_next should have 1 task'
" 2>/dev/null; then
    fail "Todoist data not properly cached"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 20: DELTA detects Todoist changes ───────────────────────────────────

setup_test "20. DELTA detects Todoist task changes"
(
  # First run with default Todoist fixtures
  "$BINARY" >/dev/null 2>&1

  # Second run with changed Todoist data (task-overdue-1 removed, task-today-new added)
  export MOCK_FIXTURE_SET="changed-todoist"
  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: DELTA" || ok=false
  assert_stdout_contains "$stdout" "---CHANGES---" || ok=false
  assert_stdout_contains "$stdout" "Todoist: added (Deploy hotfix)" || ok=false
  assert_stdout_contains "$stdout" "Todoist: removed (Update documentation)" || ok=false

  $ok && pass
)
teardown_test

# ── Test 21: Issue tiering — tier assignment, priority sort, no cross-tier promotion

setup_test "21. Issue tiering: Tier 2/3 assignment with priority boosts"
(
  export MOCK_FIXTURE_SET="issue-tiering"

  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: FULL" || ok=false
  assert_stdout_contains "$stdout" "---ANALYSIS---" || ok=false

  analysis_json=$(echo "$stdout" | sed -n '/---ANALYSIS---/,/---END_ANALYSIS---/p' | grep -v '^---')

  if ! echo "$analysis_json" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
    fail "ANALYSIS section is not valid JSON"
    ok=false
  fi

  if ! echo "$analysis_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)

# Tier 2: exactly 1 issue (iid 103) from the 80%-complete workstream
t2 = data['tier_2_issues']
assert len(t2) == 1, f'tier_2_issues: expected 1, got {len(t2)}'
assert t2[0]['iid'] == 103, f'tier_2 iid: expected 103, got {t2[0][\"iid\"]}'
assert t2[0]['workstream_completion'] == 80, f'tier_2 completion: expected 80, got {t2[0][\"workstream_completion\"]}'
assert t2[0].get('priority') == 'p::2', f'tier_2 priority: expected p::2, got {t2[0].get(\"priority\")}'
assert t2[0]['reason'] == 'near_complete_workstream', f'tier_2 reason wrong: {t2[0][\"reason\"]}'

# Tier 3: 3 issues sorted by priority (p::1 > p::3 > none)
t3 = data['tier_3_issues']
assert len(t3) == 3, f'tier_3_issues: expected 3, got {len(t3)}'
assert t3[0]['iid'] == 201, f'tier_3[0] iid: expected 201 (p::1), got {t3[0][\"iid\"]}'
assert t3[0].get('priority') == 'p::1', f'tier_3[0] priority: expected p::1, got {t3[0].get(\"priority\")}'
assert t3[1]['iid'] == 203, f'tier_3[1] iid: expected 203 (p::3), got {t3[1][\"iid\"]}'
assert t3[1].get('priority') == 'p::3', f'tier_3[1] priority: expected p::3, got {t3[1].get(\"priority\")}'
assert t3[2]['iid'] == 300, f'tier_3[2] iid: expected 300 (no priority), got {t3[2][\"iid\"]}'
assert t3[2].get('priority') is None, f'tier_3[2] priority: expected null, got {t3[2].get(\"priority\")}'

# Cross-tier check: p::1 issue stays in Tier 3 (not promoted to Tier 2)
t2_iids = {i['iid'] for i in t2}
assert 201 not in t2_iids, 'p::1 issue (201) must NOT be promoted to Tier 2'

# Tier 3 workstream_completion should be absent or null
for item in t3:
    assert item.get('workstream_completion') is None, f'tier_3 item {item[\"iid\"]} should have null workstream_completion'

# Tier 3 reason
for item in t3:
    assert item['reason'] == 'remaining_by_value_age', f'tier_3 item {item[\"iid\"]} reason wrong: {item[\"reason\"]}'
" 2>/dev/null; then
    fail "Issue tiering content is incorrect"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 22: MR ranking order in ANALYSIS ────────────────────────────────

setup_test "22. Tier 1 MR ranking: changes_requested first, then by age"
(
  export MOCK_FIXTURE_SET="mr-ranking"

  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: FULL" || ok=false
  assert_stdout_contains "$stdout" "---ANALYSIS---" || ok=false

  analysis_json=$(echo "$stdout" | sed -n '/---ANALYSIS---/,/---END_ANALYSIS---/p' | grep -v '^---')

  if ! echo "$analysis_json" | python3 -c "import sys, json; json.load(sys.stdin)" 2>/dev/null; then
    fail "ANALYSIS section is not valid JSON"
    ok=false
  fi

  if ! echo "$analysis_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
mrs = data['tier_1_mrs']
assert len(mrs) == 4, f'expected 4 tier_1_mrs, got {len(mrs)}'

assert mrs[0]['iid'] == 100, f'first should be MR 100 (changes_requested, oldest), got {mrs[0][\"iid\"]}'
assert mrs[0]['review_status'] == 'changes_requested', f'MR 100 status wrong: {mrs[0][\"review_status\"]}'
assert mrs[0]['age_hours'] == 470, f'MR 100 age wrong: {mrs[0][\"age_hours\"]}'

assert mrs[1]['iid'] == 150, f'second should be MR 150 (changes_requested, newer), got {mrs[1][\"iid\"]}'
assert mrs[1]['review_status'] == 'changes_requested', f'MR 150 status wrong: {mrs[1][\"review_status\"]}'
assert mrs[1]['age_hours'] == 254, f'MR 150 age wrong: {mrs[1][\"age_hours\"]}'

assert mrs[2]['iid'] == 200, f'third should be MR 200 (awaiting_review), got {mrs[2][\"iid\"]}'
assert mrs[2]['review_status'] == 'awaiting_review', f'MR 200 status wrong: {mrs[2][\"review_status\"]}'

assert mrs[3]['iid'] == 300, f'fourth should be MR 300 (approved), got {mrs[3][\"iid\"]}'
assert mrs[3]['review_status'] == 'approved', f'MR 300 status wrong: {mrs[3][\"review_status\"]}'
" 2>/dev/null; then
    fail "Tier 1 MR ranking order or content is incorrect"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 23: Stale worktree detection in ANALYSIS ────────────────────────

setup_test "23. Stale worktree detection in ANALYSIS"
(
  export MOCK_FIXTURE_SET="many-branches"
  mkdir -p "$TEST_STUDIO_DIR/.worktrees/worktree-one"
  mkdir -p "$TEST_STUDIO_DIR/.worktrees/worktree-two"

  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "---ANALYSIS---" || ok=false

  analysis_json=$(echo "$stdout" | sed -n '/---ANALYSIS---/,/---END_ANALYSIS---/p' | grep -v '^---')

  if ! echo "$analysis_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
stale = data['stale_worktrees']
assert len(stale) == 2, f'expected 2 stale worktrees, got {len(stale)}'
paths = sorted([s['path'] for s in stale])
assert paths == ['worktree-one', 'worktree-two'], f'wrong stale worktree paths: {paths}'
for s in stale:
    assert s['reason'] == 'branch_merged', f'wrong reason for {s[\"path\"]}: {s[\"reason\"]}'
" 2>/dev/null; then
    fail "Stale worktree detection incorrect"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 24: Recommendation string in ANALYSIS + persisted to cache ──────

setup_test "24. Recommendation string in ANALYSIS and cache"
(
  export MOCK_FIXTURE_SET="mr-ranking"

  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false

  analysis_json=$(echo "$stdout" | sed -n '/---ANALYSIS---/,/---END_ANALYSIS---/p' | grep -v '^---')

  if ! echo "$analysis_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
rec = data['recommendation']
assert rec == 'Address review feedback on MR !100', f'wrong recommendation: {rec}'
" 2>/dev/null; then
    fail "Recommendation in ANALYSIS is incorrect"
    ok=false
  fi

  if ! python3 -c "
import json
data = json.load(open('$TEST_CACHE_DIR/last-run.json'))
rec = data.get('recommendation')
assert rec is not None, 'recommendation should be in cache'
assert rec == 'Address review feedback on MR !100', f'wrong cached recommendation: {rec}'
" 2>/dev/null; then
    fail "Recommendation not persisted to cache correctly"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Test 25: writeCache preserves saved report across data changes ────────

setup_test "25. writeCache preserves report/recommendation across DELTA"
(
  # First run: creates cache
  "$BINARY" >/dev/null 2>&1

  # Save a report with recommendation
  "$BINARY" --save-report "## Triage Report
- MR !100 needs review
My recommendation: Focus on MR !100" 2>/dev/null

  # Verify report is in cache before the second run
  if ! python3 -c "
import json
data = json.load(open('$TEST_CACHE_DIR/last-run.json'))
assert data.get('report') is not None, 'report should exist after save-report'
assert 'MR !100' in data['report'], 'report content wrong'
assert data.get('recommendation') is not None, 'recommendation should exist after save-report'
" 2>/dev/null; then
    fail "report not in cache after save-report"
    exit 1
  fi

  # Second run with changed data → triggers DELTA, calls writeCache
  export MOCK_FIXTURE_SET="changed-mr"
  stdout=$("$BINARY" 2>/dev/null)
  exit_code=$?
  ok=true

  assert_exit_code "$exit_code" "0" || ok=false
  assert_stdout_contains "$stdout" "MODE: DELTA" || ok=false

  # Verify report and recommendation survived writeCache
  if ! python3 -c "
import json
data = json.load(open('$TEST_CACHE_DIR/last-run.json'))
assert data.get('report') is not None, 'report was discarded by writeCache'
assert 'MR !100' in data['report'], 'report content was corrupted'
assert data.get('recommendation') is not None, 'recommendation was discarded by writeCache'
assert 'Focus on MR !100' in data['recommendation'], 'recommendation content was corrupted'
" 2>/dev/null; then
    fail "report/recommendation lost after DELTA writeCache"
    ok=false
  fi

  $ok && pass
)
teardown_test

# ── Lint & format checks ─────────────────────────────────────────────────────

STATIC_FAILED=false

printf "\n${BOLD}Static analysis:${RESET}\n"

if command -v swiftformat &>/dev/null; then
  printf "  ${BOLD}swiftformat --lint${RESET} ... "
  if swiftformat --lint "$REPO_DIR/Sources/" 2>/dev/null; then
    printf "${GREEN}PASS${RESET}\n"
  else
    printf "${RED}FAIL${RESET}\n"
    printf "    ${RED}→ Run: swiftformat Sources/${RESET}\n"
    STATIC_FAILED=true
  fi
else
  printf "  ${BOLD}swiftformat${RESET} ... ${RED}not installed${RESET} (run: brew bundle)\n"
  STATIC_FAILED=true
fi

if command -v swiftlint &>/dev/null; then
  printf "  ${BOLD}swiftlint lint${RESET} ... "
  lint_tmpout="$(mktemp)"
  lint_exit=0
  (set +e; swiftlint lint --quiet --lenient "$REPO_DIR/Sources/" >"$lint_tmpout" 2>&1; exit $?) 2>/dev/null || lint_exit=$?
  lint_output="$(cat "$lint_tmpout")"
  rm -f "$lint_tmpout"
  if [[ $lint_exit -eq 133 ]] || echo "$lint_output" | grep -q "sourcekitdInProc"; then
    printf "${BOLD}SKIP${RESET} (requires full Xcode — CLT only)\n"
  elif [[ $lint_exit -eq 0 ]]; then
    printf "${GREEN}PASS${RESET}\n"
  else
    printf "${RED}FAIL${RESET}\n"
    echo "$lint_output" | head -10 | sed 's/^/    /'
    printf "    ${RED}→ Run: swiftlint lint Sources/${RESET}\n"
    STATIC_FAILED=true
  fi
else
  printf "  ${BOLD}swiftlint${RESET} ... ${RED}not installed${RESET} (run: brew bundle)\n"
  STATIC_FAILED=true
fi

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

if [[ "$FAILED" -gt 0 ]] || [[ "$STATIC_FAILED" == "true" ]]; then
  exit 1
fi
exit 0
