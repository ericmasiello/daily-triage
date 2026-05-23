---
name: project:sync-triage-skill
description: "Keep skills/triage/SKILL.md in sync with the triage-cache binary's output format. Use after modifying Swift source files that affect output structure, analysis fields, modes, or data model — specifically Output.swift, GitLabService.swift, Models.swift, TodoistService.swift, or ServiceProtocol.swift."
---

# Sync Triage Skill

After modifying the triage-cache binary, check whether `skills/triage/SKILL.md` needs updating and apply changes.

## When to run

After any change to these files:

- `Sources/Output.swift` — output format, MODE lines, section markers
- `Sources/GitLabService.swift` — analysis fields, recommendation logic, tiering
- `Sources/Models.swift` — data model changes affecting output shape
- `Sources/TodoistService.swift` — todoist data format
- `Sources/ServiceProtocol.swift` — new service types or diff signals

Skip if changes are limited to `Sources/App.swift`, `Sources/Cache.swift`, `Sources/Shell.swift`, or `Sources/Config.swift` (plumbing — no output format impact).

## What to check

Read the changed Swift code and compare against `skills/triage/SKILL.md` for drift in:

1. **MODE handling** (Step 2) — Are all modes still described? Any new modes added?
2. **ANALYSIS field table** — Do the field names and descriptions match `AnalysisResult` in `GitLabService.swift`?
3. **RAW_DATA references** — Does the skill correctly describe what's in the raw data (`todoist` key path, `draft_mrs`, etc.)?
4. **Format instructions** (Step 3) — Do the 5 report sections still match what the binary produces?
5. **Build command** — Still `swiftc -parse-as-library Sources/*.swift -o triage-cache`?
6. **Binary CLI flags** — Any new flags beyond `--force` and `--save-report`?

## What to do

If drift is found:

1. Edit `skills/triage/SKILL.md` to match the current binary behavior
2. Run `./install-skill.sh` to sync the installed copy
3. Note the skill update in your commit message

If no drift — do nothing. Don't touch the skill file.

## Guardrails

- Do NOT add Priority Hierarchy rules to the skill (binary is authoritative)
- Do NOT add data-gathering commands (binary handles all fetching)
- Do NOT expand the skill beyond formatting + judgment scope
- Keep the skill under 100 lines
