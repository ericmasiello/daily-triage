# AGENTS.md

## Project

Swift CLI binary (`triage-cache`) that fetches GitLab MRs/issues via `glab`, diffs against a local cache, and outputs structured text for LLM consumption. No SPM, no Package.swift, no external dependencies — just `swiftc` against `Sources/*.swift`.

## Build & Run

```bash
# Build (~1s)
swiftc Sources/*.swift -o triage-cache

# Run (requires glab auth + ~/Sites/studio)
./triage-cache
./triage-cache --force
./triage-cache --save-report "<markdown>"
```

The binary is `.gitignore`d. Always rebuild after source changes.

## Tests

```bash
./tests/run-all.sh
```

Shell-based integration suite (10 tests). The test runner builds the binary first, so you don't need a separate build step. Tests use mock `glab` and `git` scripts in `tests/mocks/` that read fixture JSON from `tests/fixtures/`. Three fixture sets: `default`, `changed-mr`, `priority-changed`.

**Environment variables for test isolation:**
- `TRIAGE_CACHE_DIR` — overrides `~/.cache/eric-triage`
- `TRIAGE_STUDIO_DIR` — overrides `~/Sites/studio`
- `MOCK_FIXTURE_DIR` — points mocks at fixture data
- `MOCK_FIXTURE_SET` — selects which fixture set to use

New tests: add a numbered block in `run-all.sh` following the existing pattern. Update `TOTAL=` at the top. New fixture data goes in `tests/fixtures/<set-name>/`.

## Source Layout

All Swift in `Sources/`. No subdirectories, no modules.

| File | Role |
|---|---|
| `main.swift` | Entry point, arg parsing, orchestration |
| `Cache.swift` | Cache read/write, TTL, `determineReason()`, `saveReport()` |
| `Fetch.swift` | Parallel `glab`/`git` calls via `DispatchGroup`. Private `Raw*` structs decode glab JSON, then map to public `Models` types |
| `Diff.swift` | Snapshot diffing. Priority label changes (`p::*`) force FULL mode |
| `Output.swift` | Formats FULL / NO_CHANGES / DELTA text output |
| `Models.swift` | `MR`, `Issue`, `Snapshot`, `CacheEnvelope` — all `Codable` |
| `Shell.swift` | `shell()` subprocess helper (bash, captures stdout, suppresses stderr) |

**Note:** README mentions `JSON.swift` but that file was removed in a refactor. The do-work skill also references it — both are stale. The actual JSON decoding now lives in `Fetch.swift`.

## Conventions

- **No JSON library** — uses Foundation `Codable` with `convertFromSnakeCase` / `convertToSnakeCase` key strategies throughout
- **All top-level functions** — no classes or protocols. Free functions with `Snapshot` / `DiffResult` value types
- **Errors to stderr** via `fputs(..., stderr)`, structured output to stdout via `print()`
- **Exit codes**: 0 = success, 1 = missing prereqs or auth failure (4+ data source failures)
- **File-private raw types** in `Fetch.swift` — glab JSON shapes are `private struct Raw*`, mapped to public models via `private extension`

## GitHub Issue Labels

Defined in `.agents/LABELS.md`. Status labels (`status:*`) are mutually exclusive — always remove old before adding new:

```bash
gh issue edit <n> --remove-label "status:<old>" --add-label "status:<new>"
```

## Gotchas

- The binary shells out to `glab` and `git` at runtime. It expects `glab` on PATH and an authenticated session. Without those, it exits 1.
- `studioDir` defaults to `~/Sites/studio`. If that directory doesn't exist, the binary exits 1. Tests override it via `TRIAGE_STUDIO_DIR`.
- `triageAuthor` defaults to `ericmasiello` but can be overridden via `TRIAGE_AUTHOR` env var.
- Cache lives at `~/.cache/eric-triage/last-run.json` with 1-hour TTL. Don't run the binary against real APIs during development — use the test suite.
