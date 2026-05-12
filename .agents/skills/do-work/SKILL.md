---
name: project:do-work
description: "Execute a unit of work end-to-end in the triage-cache Swift project: understand the task, plan, implement incrementally, validate with build and smoke test, then commit. Use when the user wants to do work, build a feature, fix a bug, or implement a change."
---

# Do Work

Execute a complete unit of work in the triage-cache Swift binary: plan it, build it, validate it, commit it.

## Workflow

### 1. Understand the task

Read any referenced plan, PRD, or issue. Explore the relevant source files in `Sources/` to understand existing patterns and conventions.

Key files:
- `Sources/main.swift` -- entry point, arg parsing
- `Sources/Shell.swift` -- subprocess execution
- `Sources/JSON.swift` -- JSON array parsing
- `Sources/Models.swift` -- MR and issue field extraction
- `Sources/Cache.swift` -- cache read/write/reason logic
- `Sources/Fetch.swift` -- parallel data fetching (DispatchGroup)

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

Build the binary and fix any issues. Repeat until the build succeeds.

```bash
swiftc Sources/*.swift -o triage-cache
```

If the change affects runtime behavior, run a smoke test:

```bash
./triage-cache
```

Verify the output format matches expectations from the README (MODE line, REASON, JSON structure).

### 5. Commit

Once the build passes and behavior is verified, commit the work.
