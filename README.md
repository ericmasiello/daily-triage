# triage-cache

Swift binary that fetches GitLab data for the [`eric:triage`](https://gitlab.com/vistaprint-org/design-technology/studio/studio/-/work_items/156) agent skill. It gathers MRs, issues, worktrees, and merged branches in parallel, outputs structured JSON for LLM consumption, and caches results to disk.

## Prerequisites

- macOS with Swift toolchain (ships with Xcode or Xcode Command Line Tools)
- [`glab`](https://gitlab.com/gitlab-org/cli) CLI authenticated (`brew install glab && glab auth login`)
- `~/Sites/studio` directory (the Studio GitLab repo clone)

## Build

```bash
swiftc -parse-as-library Sources/*.swift -o triage-cache
```

Compiles in ~1s. No SPM, no Package.swift, no external dependencies.

## Run

```bash
# Standard run — fetches data, outputs MODE: FULL, writes cache
./triage-cache

# Bypass cache entirely — always runs FULL mode
./triage-cache --force

# Save an LLM-generated report to the cache
./triage-cache --save-report "<markdown report>"
```

## Output Format

The binary outputs one of three modes depending on cache state and data changes:

### FULL Mode

Triggered on first run, expired cache (>1h), corrupt cache, `--force` flag, or priority label changes.

```
MODE: FULL
REASON: first_run | cache_expired | cache_corrupt | forced | priority_labels_changed

---RAW_DATA---
{
  "non_draft_mrs": [...],
  "draft_mrs": [...],
  "sandcastle_mrs": [...],
  "issues": [...],
  "worktrees": [...],
  "merged_branches": [...]
}
---END_RAW_DATA---
```

### NO_CHANGES Mode

Triggered when fresh data is identical to the cached snapshot.

```
MODE: NO_CHANGES
CACHE_AGE_MINUTES: 5

---PREVIOUS_REPORT---
<cached markdown report>
---END_PREVIOUS_REPORT---

PREVIOUS_RECOMMENDATION: <cached recommendation line>
```

### DELTA Mode

Triggered when some data changed but no full re-analysis triggers fired.

```
MODE: DELTA
CACHE_AGE_MINUTES: 5
CHANGES_SUMMARY: 3 changes detected

---CHANGES---
MR !11393: detailed_merge_status changed not_approved → approved
MR !11500: added (Add new feature)
Issue #200: labels added p::2; removed p::3
---END_CHANGES---

---PREVIOUS_REPORT---
<cached markdown report>
---END_PREVIOUS_REPORT---

PREVIOUS_RECOMMENDATION: <cached recommendation line>
```

## Cache

Written to `~/.cache/eric-triage/last-run.json` with a 1-hour TTL. Schema:

```json
{
  "version": 1,
  "timestamp": "2026-05-12T14:30:00Z",
  "ttl_seconds": 3600,
  "snapshot": { ... },
  "report": null,
  "recommendation": null
}
```

`--save-report` updates the `report` and `recommendation` fields without re-fetching data.

Cache directory and studio directory can be overridden via `TRIAGE_CACHE_DIR` and `TRIAGE_STUDIO_DIR` environment variables (used by the test suite).

## Graceful Degradation

- **Corrupt cache**: invalid JSON is deleted automatically and a fresh `FULL` run executes
- **Schema mismatch**: treated as corrupt (same behavior)
- **`glab` not found**: prints error to stderr, exits with code 1
- **`glab` auth expired**: if 4+ data sources fail, prints error to stderr, exits with code 1

## Tests

```bash
./tests/run-all.sh
```

Shell-based integration suite with several test cases. Mock `glab` and `git` scripts in `tests/mocks/` isolate the binary from real API calls. Fixture data lives in `tests/fixtures/`.

## Source Layout

All source lives in `Sources/` — no subdirectories, no modules.

## Related Issues

- [#156 PRD: Triage Cache Layer](https://gitlab.com/vistaprint-org/design-technology/studio/studio/-/work_items/156)
- [#157 FULL mode + cache persistence](https://gitlab.com/vistaprint-org/design-technology/studio/studio/-/work_items/157)
- [#158 Diff algorithm + NO_CHANGES + DELTA](https://gitlab.com/vistaprint-org/design-technology/studio/studio/-/work_items/158) (planned — this is where repeat runs get fast)
- [#159 Edge cases + --force + integration tests](https://gitlab.com/vistaprint-org/design-technology/studio/studio/-/work_items/159) (planned)
