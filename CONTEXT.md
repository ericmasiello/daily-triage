# triage-cache

Aggregates work signals from multiple sources (GitLab, Jira, Todoist, and soon Apple
Reminders) into one cached snapshot, diffed against the previous run and formatted for
an LLM-driven daily triage skill.

## Language

**Data Source**:
One external system fetched via its own `DataSourceService` conformer (`GitLabService`,
`JiraService`, `TodoistService`, ...). Each shells out to an already-authenticated CLI
(`glab`, `acli`, `td`) rather than calling an API directly.
_Avoid_: Provider, integration, adapter.

**Recommendation**:
The single suggested next action computed by `computeAnalysis`, derived only from GitLab
MR review status and Jira tier-2/tier-3 issues. A data source either **drives** the
recommendation (GitLab, Jira) or is **informational** — fetched, diffed, and shown in raw
data, but never considered when choosing the recommendation (Todoist; planned: Reminders).
_Avoid_: Priority source, actionable source.

**Reminder**:
An item from Apple's Reminders app, read via the `reminders-cli` binary (a separate
EventKit-backed dependency — see ADR-0002). Distinct from a Todoist **Task**, which is a
different data source's item shape.
_Avoid_: Task, to-do item.

**List** (Reminders):
Apple Reminders' grouping for reminders (e.g. "Work", "Personal"), analogous in role to a
Todoist label but a different underlying concept — sources are not assumed to share
vocabulary just because they group items similarly.
_Avoid_: Project, folder, category.
