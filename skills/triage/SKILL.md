---
name: eric:triage
description: Decide what to work on right now. Runs the triage-cache binary and formats its ranked analysis into a report with a single recommendation. Use when the user says 'what should I work on', 'triage', 'prioritize', 'what's next', 'pick something up', or wants help deciding which task to tackle.
---

# Triage

Answer: **"What should I work on right now?"**

Run this anytime — between meetings, after lunch, start of day. A 30-second decision aid, not a planning session.

## Step 1: Run the binary

```bash
~/Sites/daily-triage/triage-cache
```

If the binary doesn't exist, build first:

```bash
swiftc -parse-as-library ~/Sites/daily-triage/Sources/*.swift \
  -o ~/Sites/daily-triage/triage-cache
```

## Step 2: Branch on MODE

### NO_CHANGES

Reply: "Nothing new since last triage ({CACHE_AGE_MINUTES} min ago)."
Echo the `---PREVIOUS_REPORT---` and `PREVIOUS_RECOMMENDATION` verbatim. Done — skip everything below.

### DELTA

Use `---PREVIOUS_REPORT---` as a base. Apply only the changes listed in `---CHANGES---`: update affected items, adjust ranking within their tier if needed, regenerate the recommendation. Do not re-analyze unchanged items. Then continue to Steps 3–4.

### FULL

The binary has already ranked everything in the `---ANALYSIS---` JSON section. Use it directly:

| Field | Contents |
|---|---|
| `tier_1_mrs` | Non-draft MRs ranked by review status then age. Always first. |
| `tier_2_issues` | Issues in near-complete work streams (>=80% closed). |
| `tier_3_issues` | Remaining issues by priority label then value/age. |
| `stale_worktrees` | Worktrees whose branches are merged (safe to delete). |
| `prd_hierarchy` | PRD parent/child maps with completion percentages. |
| `recommendation` | The binary's single top recommendation. |

**Trust these rankings.** The binary applies the full Priority Hierarchy (non-draft MRs first, then near-complete work streams, then remaining by value/age, with `p::*` labels as within-tier boosts). Do not re-derive it.

If you disagree based on contextual judgment the binary lacks (e.g., a conversation about shifting priorities, or knowledge of a blocking dependency), use `---RAW_DATA---` to override specific items and explain your reasoning.

Todoist tasks are in `---RAW_DATA---` under the `todoist` key (with `overdue`, `today`, and `up_next` arrays). Format them as informational context — they are not tier-ranked.

## Step 3: Format the report

Present results as nested bullet lists, in this order:

1. **Open MRs** — from `tier_1_mrs`. Show: title (full MR URL), review status, age, recommended action.
2. **GitLab Issues (top 3)** — from `tier_2_issues` then `tier_3_issues`. Group by parent PRD using `prd_hierarchy`; show completion %, priority label, and next actionable child issues (full issue URLs).
3. **Todoist Tasks** — from `raw_data.todoist`. Show overdue first, then today, then up next. Deduplicate across groups. Rank within each group by Todoist priority (p1 > p2 > p3 > p4).
4. **Draft MRs** — from `raw_data.draft_mrs`. List for awareness only (not prioritized).
5. **Stale Worktrees** — from `stale_worktrees`. Present a ready-to-run cleanup script using `trash` (macOS). **Never execute it** — present for user review.

End with: **"My recommendation: {recommendation}. Want me to start on that?"**

## Step 4: Save the report

After generating the report (FULL or DELTA modes only), persist it to the cache:

```bash
~/Sites/daily-triage/triage-cache --save-report "<full report markdown including recommendation>"
```

## Rules

- Be opinionated — recommend ONE specific next action, not a menu.
- Non-draft MRs before new work, always.
- Bias toward finishing over starting.
- Keep it fast — under 30 seconds.
- Always use full URLs when linking issues or MRs.
- Never execute worktree deletion — present the script for user review.
- Todoist tasks are context, not tier-ranked. Call out overdue tasks in the recommendation as a side note.
- If the binary exits with code 1, report the error and stop. Do not fall back to manual `glab` commands.
