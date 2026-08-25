---
status: superseded by ADR-0002
---

# Access Apple Reminders via the `shortcuts` CLI, not EventKit

**Superseded**: `keith/reminders-cli` (a separately-maintained, brew-installable EventKit
wrapper) turned out to solve the underlying problem this ADR was rejecting EventKit over —
see ADR-0002. Kept for the record of what was considered and measured before that was
found.

Every existing data source (`glab`, `acli`, `td`) reads data by shelling out to an
already-authenticated CLI, and the whole project is built with `swiftc -parse-as-library
Sources/*.swift` — no `Package.swift`, no Xcode project, no signed app bundle. Raw EventKit
reminder access is gated by macOS TCC per signed-bundle-identity; a bare `swiftc`-compiled
executable has no bundle identity to hold that grant. Rather than introduce a signed `.app`
just for this one source, `RemindersService` shells out to `shortcuts run "<name>" -o -`
against a hand-built Shortcut (authored once in Shortcuts.app) that reads the Reminders
list and emits JSON — same shape as every other source.

## Considered Options

- **Raw EventKit (Swift)**: the "proper" API, but requires a signed bundle with
  `NSRemindersUsageDescription`, breaking the project's no-bundle build model for one
  source only. Rejected.
- **Read Reminders' underlying `.ics`/SQLite storage directly**: undocumented, described by
  existing open-source exporters as unstable across macOS versions. Rejected.
- **AppleScript via `osascript`**: no GUI authoring needed at all — Reminders.app is
  scriptable and `get name of every list` returns instantly. But it's built on the legacy
  Apple Events bridge, not EventKit: `count of reminders in list "Reminders"` is instant
  (6,043 items), but any per-item property access or `whose` predicate against that same
  list hung indefinitely (killed after 15-20s with zero output) — a known Reminders.app +
  AppleScript performance pathology at this list size. Rejected on measured evidence, not
  theory.
- **Shortcuts CLI bridge**: matches the existing "shell out to an authenticated CLI, parse
  JSON" convention exactly, no bundle/entitlements needed. Chosen.

## Consequences

- The Shortcut itself must be authored manually in Shortcuts.app (GUI-only, no CLI
  authoring) and kept in sync by hand if its logic changes — there's no source-controlled
  definition of it alongside `Sources/*.swift`.
- Reminders exposes no stable UUID via Shortcuts actions; `RemindersService` uses the
  reminder's `x-apple-reminder://` URL as its `id`, mirroring how `TodoistTask.url` is used
  today — unlike Todoist's task `id`, this is inferred from a URL scheme, not a documented
  identifier field.
