---
name: project:do-work
description: "Execute a unit of work end-to-end in the triage-cache Swift project: understand the task, plan, implement incrementally, validate with build and smoke test. Asks upfront whether the user wants to review changes or auto-ship. Use when the user wants to do work, build a feature, fix a bug, or implement a change."
---

# Do Work

Execute a complete unit of work in the triage-cache Swift binary: plan it, build it, validate it, then review or ship.

## Workflow

### 1. Review or ship?

Before starting any work, ask the user: **"Do you want to review the changes when I'm done, or should I commit and ship automatically?"**

Remember their choice — it determines what happens after validation.

### 2. Understand the task

Read any referenced plan, PRD, or issue. Explore the relevant source files in `Sources/` to understand existing patterns and conventions.

If the task is ambiguous, ask the user to clarify scope before proceeding.

### 3. Plan the implementation

If the task involves more than a single, obvious change, outline the steps before writing code. For multi-file changes, identify which files are affected and in what order.

### 4. Implement

Work incrementally -- one logical change at a time. After each change, build to confirm it compiles.

Since this project has no test framework, validate behavior by:
1. Making the smallest meaningful change
2. Building to confirm compilation (step 5)
3. Reasoning about correctness against the change's intent
4. Moving to the next change

### 5. Validate

#### 5a. Build

Build the binary and fix any issues. Repeat until the build succeeds.

```bash
swiftc Sources/*.swift -o triage-cache
```

#### 5b. Regenerate LSP metadata (if files were added or removed)

If you **added or removed** any `.swift` file in `Sources/` during this task, regenerate the compile commands so sourcekit-lsp can resolve cross-file symbols:

```bash
./generate-compile-commands.sh
```

Skip this step if you only modified existing files.

#### 5c. Run the test suite

```bash
./tests/run-all.sh
```

Shell-based integration suite. Fix any failures your changes introduced. Pre-existing failures unrelated to your changes should be noted but not fixed.

#### 5d. Smoke test (if runtime behavior changed)

If the change affects runtime behavior, run a smoke test:

```bash
./triage-cache
```

Verify the output format matches expectations from the README (MODE line, REASON, JSON structure).

#### 5e. Sync triage skill (if output format changed)

If your changes touched `Output.swift`, `GitLabService.swift`, `Models.swift`, `TodoistService.swift`, or `ServiceProtocol.swift`, invoke the `project:sync-triage-skill` skill to check whether `skills/triage/SKILL.md` needs updating.

### 6. Finish

Apply the choice from step 1:

#### If review — leave uncommitted

Leave all changes uncommitted. Summarize what files were changed and what the changes do. The user will review at their leisure.

Do NOT commit. Do NOT invoke `project:ship-work`. Stop here.

#### If ship — commit and ship

Commit the work, then invoke the `project:ship-work` skill to push the branch and open a PR.
