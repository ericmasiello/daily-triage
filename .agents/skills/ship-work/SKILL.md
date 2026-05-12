---
name: project:ship-work
description: "Commit, push, and optionally create a GitHub pull request, then update the source issue's status labels. Use when the user says 'ship this', 'commit and push', 'push it up', 'create PR', 'create pull request', or wants to go from reviewed code to a pushed branch with issue tracking updated."
---

# Ship Work

Commit, push, optionally open a GitHub PR, and update the source issue's status labels.

## Workflow

### 1. Identify the source issue(s)

Determine which GitHub issue(s) this work addresses. Check, in order:

1. **Conversation context** — if `project:do-work` was invoked earlier with an issue reference, use that.
2. **Branch name** — if the branch contains an issue number (e.g., `123-fix-thing`), use that.
3. **Commit messages** — scan `git log origin/HEAD..HEAD --oneline` for issue references.
4. **Ask the user** — "Which GitHub issue(s) does this work close?"

Fetch each issue to confirm it exists and read its current labels:

```bash
gh issue view <number>
```

Note each issue's `workstream:*` and current `status:*` label.

### 2. Build

Verify the project compiles before shipping:

```bash
swiftc Sources/*.swift -o triage-cache
```

If the build fails, fix issues before proceeding. Do NOT ship broken code.

### 3. Commit (if needed)

If there are uncommitted changes, stage and commit following the repo's conventions (see `git log --oneline -10` for style).

```bash
git add <files> && git commit -m "type(scope): description"
```

If the working tree is clean, skip to step 4.

### 4. Push

```bash
git push -u origin HEAD
```

### 5. Pull request

Check if a PR already exists for this branch:

```bash
gh pr view 2>&1
```

#### 5a. No existing PR

Ask the user: **"Create a pull request for this branch?"**

Do NOT assume — wait for explicit confirmation.

If **yes**, create the PR. List every issue it closes in the body:

```bash
gh pr create --title "type(scope): description" \
  --head "$(git branch --show-current)" \
  --body "## Summary

<description>

## Issues

Closes #<number1>
Closes #<number2>"
```

If **no**, skip to step 6.

#### 5b. Existing PR — update description

If a PR already exists and new commits were pushed:

1. Read current description: `gh pr view --json body -q .body`
2. Update to cover all commits, not just the latest push
3. Ensure every closed issue is listed
4. Apply: `gh pr edit --body "<updated description>"`

### 6. Update issue status

Update **every** issue identified in step 1. Remove the old `status:*` label (noted in step 1) and apply the new one:

| Scenario | New label |
|----------|-----------|
| PR created or updated, ready for review | `status:awaiting-review` |
| Pushed, no PR yet | `status:in-progress` |
| Work is partial (more slices remain) | `status:in-progress` |

```bash
gh issue edit <number> --remove-label "status:<old>" --add-label "status:awaiting-review"
```

### 7. Report

Output:
- Commit hash(es) and subject line(s)
- Push result (branch + remote)
- PR URL (if created or updated) and which issues it closes
- Issue status update confirmation for each issue

## Label reference

**Workstream** (one per issue): `workstream:*`

**Status** (one per issue, mutually exclusive):
- `status:blocked` — has open blockers
- `status:ready` — unblocked, ready for implementation
- `status:in-progress` — active work or PR open
- `status:awaiting-review` — engineering work complete, PR awaiting review
