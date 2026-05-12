---
name: project:prd-to-issues
description: Break a PRD into independently-grabbable GitHub issues using tracer-bullet vertical slices. Use when user wants to convert a PRD to issues, create implementation tickets, or break down a PRD into work items.
---

# PRD to Issues

Break a PRD into independently-grabbable GitHub issues using vertical slices (tracer bullets).

## Process

### 1. Locate the PRD

Ask the user for the PRD GitHub issue number (or URL).

If the PRD is not already in your context window, fetch it:
```bash
gh issue view <number>
```

Read the parent PRD's labels to identify its `workstream:*` label. All child issues will inherit this workstream label.

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code.

### 3. Draft vertical slices

Break the PRD into **tracer bullet** issues. Each issue is a thin vertical slice that cuts through ALL integration layers end-to-end, NOT a horizontal slice of one layer.

Slices may be 'HITL' or 'AFK'. HITL slices require human interaction, such as an architectural decision or a design review. AFK slices can be implemented and merged without human interaction. Prefer AFK over HITL where possible.

<vertical-slice-rules>
- Each slice delivers a narrow but COMPLETE path through every layer (schema, API, UI, tests)
- A completed slice is demoable or verifiable on its own
- Prefer many thin slices over few thick ones
</vertical-slice-rules>

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type**: HITL / AFK
- **Blocked by**: which other slices (if any) must complete first
- **User stories covered**: which user stories from the PRD this addresses

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the dependency relationships correct?
- Should any slices be merged or split further?
- Are the correct slices marked as HITL and AFK?
- Should all the work be done in a single branch, or should some slices be split into separate branches and PRs?
- Do you prefer the work is done in a worktree?

Iterate until the user approves the breakdown.

### 5. Create the GitHub issues

For each approved slice, create a GitHub issue. Use the `gh` CLI. Use the issue body template below.

Create issues in dependency order (blockers first) so you can reference real issue numbers in the "Blocked by" field.

**Labels:** When creating each issue, apply labels via the `--label` flag:
- Inherit the `workstream:*` label from the parent PRD
- Apply `status:ready` if the issue has no blockers
- Apply `status:blocked` if the issue is blocked by another slice

```bash
gh issue create --title "<title>" --label "workstream:<inherited>,status:ready" --body "..."
```

**Dependency tracking:** GitHub does not have native blocking links. Instead, use task lists in the parent PRD to track progress, and reference blockers in each issue body.

After ALL issues are created, update the parent PRD body to include a task list:
```bash
gh issue edit <prd-number> --body "$(gh issue view <prd-number> --json body -q .body)

## Implementation Issues

- [ ] #<issue-1> — <title>
- [ ] #<issue-2> — <title>
..."
```

**Update parent PRD status:**
```bash
gh issue edit <prd-number> --add-label "status:in-progress" --remove-label "status:ready"
```

<issue-template>
## Parent PRD

#<prd-issue-number>

## What to build

A concise description of this vertical slice. Describe the end-to-end behavior, not layer-by-layer implementation. Reference specific sections of the parent PRD rather than duplicating content.

## Acceptance criteria

- [ ] Work must be performed in a worktree (if applicable)
- [ ] Work must be performed in a branch named `<feature-name>` (if applicable)
- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Blocked by

- Blocked by #<issue-number> (if any)

Or "None - can start immediately" if no blockers.

## User stories addressed

Reference by number from the parent PRD:

- User story 3
- User story 7

</issue-template>

Do NOT close or modify the parent PRD issue.
