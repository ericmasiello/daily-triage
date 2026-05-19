---
name: project:do-work
description: "Execute a unit of work end-to-end in the triage-cache Swift project: understand the task, plan, implement incrementally, validate with build and smoke test, then commit. Use when the user wants to do work, build a feature, fix a bug, or implement a change."
---

# Do Work

Execute a complete unit of work in the triage-cache Swift binary: plan it, build it, validate it, commit it.

## Workflow

### 1. Understand the task

Read any referenced plan, PRD, or issue. Explore the relevant source files in `Sources/` to understand existing patterns and conventions.

If the task is ambiguous, ask the user to clarify scope before proceeding.

### 2. Plan the implementation

If the task involves more than a single, obvious change, outline the steps before writing code. For multi-file changes, identify which files are affected and in what order.

### 3. Implement

Work incrementally -- one logical change at a time. After each change, build to confirm it compiles.

Since this project has no test framework, validate behavior by:
1. Making the smallest meaningful change
2. Building to confirm compilation (step 4)
3. Reasoning about correctness against the change's intent
4. Moving to the next change

### 4. Validate

#### 4a. Build

Build the binary and fix any issues. Repeat until the build succeeds.

```bash
swiftc Sources/*.swift -o triage-cache
```

#### 4b. Regenerate LSP metadata (if files were added or removed)

If you **added or removed** any `.swift` file in `Sources/` during this task, regenerate the compile commands so sourcekit-lsp can resolve cross-file symbols:

```bash
./generate-compile-commands.sh
```

Skip this step if you only modified existing files.

#### 4c. Run the test suite

```bash
./tests/run-all.sh
```

Shell-based integration suite. Fix any failures your changes introduced. Pre-existing failures unrelated to your changes should be noted but not fixed.

#### 4d. Smoke test (if runtime behavior changed)

If the change affects runtime behavior, run a smoke test:

```bash
./triage-cache
```

Verify the output format matches expectations from the README (MODE line, REASON, JSON structure).

### 5. Commit

Once the build passes, tests pass, and behavior is verified, commit the work.
