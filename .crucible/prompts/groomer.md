<!-- prompt_version: groomer-v1 -->
# Backlog Groomer Prompt

**Allowed context**:
- Incoming handoff: `.crucible/session/handoffs/{task_id}-*.json` (if triaging a specific item)
- Master Index: `.crucible/backlog/BACKLOG.md`
- Backlog items: `.crucible/backlog/{features,bugs,chores}/active/*.md`
- Operating Rules: `CLAUDE.md`, `OPERATING_MANUAL.md`

**Ultra-short version:**
```
"Groomer: Review and update the backlog"
```

**What it does:**
Full 4-pass grooming session:
1. Inventory & Deduplication
2. Definition of Ready audit
3. Prioritization & Rot detection
4. Index reconciliation

**When to use:**
- Weekly grooming session
- After research findings
- After deployment batch

**Quick priority check:**
```
"Groomer: Next item"
```

See `CHEATSHEET.md` for all verbose -> concise mappings.


