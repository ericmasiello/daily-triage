# AGENTS.md

## Project

Swift CLI binary (`triage-cache`) that fetches GitLab MRs/issues via `glab`, diffs against a local cache, and outputs structured text for LLM consumption. No SPM, no Package.swift, no external dependencies — just `swiftc` against `Sources/*.swift`.

## Build & Run

```bash
# Build (~1s)
swiftc -parse-as-library Sources/*.swift -o triage-cache

# Run (requires glab auth + ~/Sites/studio)
./triage-cache
./triage-cache --force
./triage-cache --save-report "<markdown>"
```

The binary is `.gitignore`d. Always rebuild after source changes.

## Validation

Before pushing any change, all three checks must pass. Run them in a loop until clean:

```bash
swiftformat Sources/       # auto-fix formatting
swiftlint lint --lenient Sources/  # lint (warnings allowed, errors fail)
./tests/run-all.sh         # build + 25 integration tests + format check
```

`./tests/run-all.sh` runs `swiftformat` and `swiftlint --lenient` internally as well, so a clean `run-all.sh` means all three pass. Iterate — fix any failures, then re-run — until the script exits 0.

**SwiftLint requires full Xcode** (not just Command Line Tools). If `swiftlint` crashes with a `sourcekitdInProc` error, run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` to point the toolchain at Xcode.

Shell-based integration suite (25 tests). The test runner builds the binary first, so you don't need a separate build step. Tests use mock `glab` and `git` scripts in `tests/mocks/` that read fixture JSON from `tests/fixtures/`. Five fixture sets: `default`, `changed-mr`, `priority-changed`, `many-branches`, `analysis-hierarchy`.

**Environment variables for test isolation:**
- `TRIAGE_CACHE_DIR` — overrides `~/.cache/eric-triage`
- `TRIAGE_STUDIO_DIR` — overrides `~/Sites/studio`
- `MOCK_FIXTURE_DIR` — points mocks at fixture data
- `MOCK_FIXTURE_SET` — selects which fixture set to use

New tests: add a numbered block in `run-all.sh` following the existing pattern. Update `TOTAL=` at the top. New fixture data goes in `tests/fixtures/<set-name>/`.

## Source Layout

All Swift in `Sources/`. No subdirectories, no modules.

**Note:** README mentions `JSON.swift` but that file was removed in a refactor. The do-work skill also references it — both are stale. The actual JSON decoding now lives in `Fetch.swift`.

## Conventions

- **No JSON library** — uses Foundation `Codable` with `convertFromSnakeCase` / `convertToSnakeCase` key strategies throughout
- **All top-level functions** — free functions with `Snapshot` / `DiffResult` value types. The only struct with behavior is the `@main` entry point in `App.swift`
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

## Editor / LSP Setup

This project has no SPM `Package.swift` or Xcode project. To get sourcekit-lsp working (cross-file symbol resolution, code completion, diagnostics), the project uses a `compile_commands.json` file that tells the LSP all `Sources/*.swift` files compile as a single module.

```bash
# Generate (or regenerate) compile_commands.json
./generate-compile-commands.sh
```

Re-run this script after adding or removing any `.swift` file in `Sources/`. The generated `compile_commands.json` is gitignored because it contains machine-specific absolute paths.

**After adding a new Swift source file**, you must:
1. Re-run `./generate-compile-commands.sh`
2. Restart the editor's LSP server (or reopen the project)
