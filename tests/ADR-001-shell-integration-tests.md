# ADR-001: Shell-based integration tests over Swift unit tests

**Status:** Accepted
**Date:** 2026-05-19

## Context

`triage-cache` is a small CLI binary (~500 lines) compiled with raw `swiftc` — no SPM, no Xcode project, no external dependencies. We needed a way to test it.

## Decision

Use a single shell script (`run-all.sh`) with mock `glab`/`git` scripts on `$PATH` and fixture JSON files, rather than Swift unit tests via XCTest.

## Rationale

- **No test infrastructure exists.** XCTest requires SPM or Xcode to discover and run tests. Adding either solely for testing would significantly increase project complexity.
- **The valuable behavior is end-to-end.** The binary's contract is: given `glab`/`git` responses → produce correct stdout, exit code, and cache file. Shell tests exercise this naturally.
- **Mock injection is trivial in shell.** Prepending `tests/mocks/` to `$PATH` hijacks `glab` and `git` for the subprocess. Achieving the same in Swift would require refactoring all of `Fetch.swift` to accept injectable command runners — an architectural change that isn't justified at this scale.
- **No function-level seams exist.** The codebase uses free functions with hardcoded `shell()` calls, not protocols or dependency injection. Swift unit tests would need significant refactoring to test anything smaller than the full binary.

## Tradeoffs

- Cannot unit test individual functions (e.g., `computeDiff`, `determineReason`) in isolation.
- Test assertions are string-based (`grep -qF`), not type-safe.
- Harder to extend as the project grows — each new test is a hand-written bash block.

## When to revisit

If the project grows large enough to justify SPM (e.g., adding external dependencies, multiple build targets, or substantially more source files), migrate to XCTest at that point.
