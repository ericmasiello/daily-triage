# Labels

Single source of truth for GitHub issue labels used across all project skills.

## Status labels

Mutually exclusive — each issue has exactly one `status:*` label. GitHub does not enforce this automatically, so when changing status you must remove the old label and add the new one.

| Label | Meaning |
|---|---|
| `status:blocked` | Has open blockers — cannot proceed |
| `status:ready` | Unblocked, ready for implementation |
| `status:in-progress` | Active work underway or PR open |
| `status:awaiting-review` | Engineering work complete, PR awaiting review |
| `status:needs-investigation` | Unclear scope — needs review before work begins |

## Workstream labels

Each issue belongs to exactly one workstream. Workstream labels use the format `workstream:<name>`.

To list existing workstreams:

```bash
gh label list --search "workstream:"
```

To create a new workstream label:

```bash
gh label create "workstream:<name>" --color "<hex>" --description "<description>"
```

## Swapping status labels

GitHub does not have scoped-label mutual exclusivity like GitLab. Always remove the old status before adding the new one:

```bash
gh issue edit <number> --remove-label "status:<old>" --add-label "status:<new>"
```
