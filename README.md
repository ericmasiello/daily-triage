# triage-cache

Swift binary that fetches GitLab data for the [`eric:triage`](https://gitlab.com/vistaprint-org/design-technology/studio/studio/-/work_items/156) agent skill. It gathers MRs, issues, worktrees, and merged branches in parallel, outputs structured JSON for LLM consumption, and caches results to disk.

## Prerequisites

- macOS with Swift toolchain (ships with Xcode or Xcode Command Line Tools)
- [`glab`](https://gitlab.com/gitlab-org/cli) CLI authenticated (`brew install glab && glab auth login`)
- `~/Sites/studio` directory (the Studio GitLab repo clone)

## Build

```bash
swiftc Sources/*.swift -o triage-cache
```

Compiles in ~1s. No SPM, no Package.swift, no external dependencies.

## Run

```bash
# Standard run — fetches data, outputs MODE: FULL, writes cache
./triage-cache

# Save an LLM-generated report to the cache
./triage-cache --save-report "<markdown report>"
```

## Output Format

```
MODE: FULL
REASON: first_run | cache_expired | cache_corrupt | cache_valid

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

## Source Layout

```
Sources/
  main.swift    — Entry point and arg parsing
  Shell.swift   — Subprocess execution
  JSON.swift    — JSON array parsing
  Models.swift  — MR and issue field extraction
  Cache.swift   — Cache read/write/reason logic
  Fetch.swift   — Parallel data fetching (DispatchGroup)
```

## Related Issues

- [#156 PRD: Triage Cache Layer](https://gitlab.com/vistaprint-org/design-technology/studio/studio/-/work_items/156)
- [#157 FULL mode + cache persistence](https://gitlab.com/vistaprint-org/design-technology/studio/studio/-/work_items/157)
- [#158 Diff algorithm + NO_CHANGES + DELTA](https://gitlab.com/vistaprint-org/design-technology/studio/studio/-/work_items/158) (planned — this is where repeat runs get fast)
- [#159 Edge cases + --force + integration tests](https://gitlab.com/vistaprint-org/design-technology/studio/studio/-/work_items/159) (planned)
