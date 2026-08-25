# Access Apple Reminders via `keith/reminders-cli`, not a custom bridge

`RemindersService` shells out to the brew-installable `reminders-cli`
(`keith/formulae/reminders-cli`) — `reminders show "Reminders" --format json` — exactly
like every other source shells out to `glab`/`acli`/`td`. No change to `triage-cache`'s own
build model (still plain `swiftc`, no `Package.swift`, no Xcode project).

This supersedes ADR-0001. That ADR's premise — that EventKit access requires either a
signed `.app` bundle or a Shortcuts/AppleScript workaround, and that adopting EventKit would
therefore force `triage-cache` itself onto SPM/Xcode — turned out to be solvable one layer
down instead: `reminders-cli` already embeds the `Info.plist`/signing EventKit needs (via
SPM linker flags, confirmed via its own and comparable projects' `Package.swift`), so that
complexity lives in a dependency we install, not in code we write or a build model we
adopt. Measured directly against the real 6,043-item "Reminders" list: `reminders show
"Reminders" --format json` completed in 1.6s and returned `externalId` (a stable UUID),
`title`, `dueDate`, `priority` (Int, same shape as `TodoistTask.priority`), `isCompleted`,
and `list` — no per-item performance pathology, unlike the AppleScript path measured in
ADR-0001.

## Consequences

- `reminders-cli` becomes a new `Brewfile` dependency, installed and available on PATH like
  `glab`/`acli`/`td` — no auth step needed (grants Reminders access via macOS TCC on first
  run, a one-time interactive prompt).
- `externalId` (a UUID) is the reminder's stable identifier, used as `Reminder.id` — unlike
  ADR-0001's plan to infer an id from a `x-apple-reminder://` URL, this is a documented,
  purpose-built identifier field.
- No hand-built Shortcut to author or maintain; nothing GUI-authored sits outside version
  control for this source.
