---
name: health-check
title: "System Health Check"
version: "1.0.0"
owner: "operator"
frequency: "daily"
last_run: ""
last_run_by: ""
last_run_outcome: ""
requires_terminal: false
---

# Runbook: System Health Check

A quick scan of the adopter project's operational health. No code changes — reads and reports only.

## Quick Start

Paste into Claude Code:
```
Follow the procedure in .crucible/sops/health-check.md
```

## Procedure

1. **Git state**: Run `git status --short`. Classify:
   - **clean** — no modified or untracked files (or only expected runbook updates)
   - **dirty** — uncommitted changes in source code that may be in-progress work

2. **Project Tooling**: Run the project's configured verification commands (e.g. build, lint, test). Report as:
   - Configured quick checks: clean | <N> failures
   - Configured full checks: clean | <N> failures

   - **clean** — no issues
   - **<N> failures** — capture the first 3 failure lines only (do NOT dump full output)

3. **Lock file scan**: Check `.crucible/locks/`. Any lock file older than 24 hours is stale.
   - Report stale locks. **Do NOT delete them** — the human must review first.

4. **Handoff validation** (if `.crucible/session/handoffs/*.json` exists):
   - Run `{{crucible_root}}/powershell/factory.ps1` to verify latest handoff integrity.
   - If script fails, flag as critical protocol issue.

5. **Session state validation**: Read `.crucible/session/global/session_state.json`.
   - Parse as JSON. Check each specialist section exists and has a `status` field.
   - Flag corrupt or missing sections.

6. **Backlog archival scan**:
   - Verify that all items marked as **Production** or **Resolved** in the active backlog have their corresponding spec files moved to the appropriate `archived/` subdirectory:
     - Features -> `features/archived/`
     - Bugs -> `bugs/archived/`
     - Chores -> `chores/archived/`
   - Report counts: Draft, Planning, In Progress, Production, Resolved.
   - Flag any Production/Resolved item missing its archived spec file.
   - **Note**: The `ARCHIVED.md` file is deprecated; do NOT use it for health validation.

7. **Minor issues scan**: If `.crucible/session/global/minor_issues.log` exists, count entries.
   - If the same issue appears 5+ times, flag it as requiring a real backlog item (Operator circuit-breaker threshold).

8. **Update runbook registry**: Edit `.crucible/sops/registry.md` — update this runbook's `last_run`, `last_run_by`, and `last_run_outcome` fields.

9. **Append to runbook log**: Write entry to `.crucible/session/global/runbook_log.md`:

   ```markdown
   ### health-check -- <ISO timestamp>
   - Outcome: success | partial | failure
   - Git: clean | dirty
   - Quick checks: clean | <N> failures
   - Full checks: clean | <N> failures
   - Stale locks: <N>
   - Handoff: valid | invalid | missing
   - Session state: valid | corrupt | missing
   - Issues: <summary or "none">
   ```

## Completion Block

```
==================================================
RUNBOOK COMPLETE: health-check
==================================================
Git tree:      clean | dirty
Quick checks:  clean | <N> failures
Full checks:   clean | <N> failures
Stale locks:   <N> (<list or "none">)
Handoff:       valid | invalid | missing
Session state: valid | corrupt | missing
Issues found:  <list or "none">

Backlog summary:
  Draft: <N> | Planning: <N> | In Progress: <N> | Production: <N> | Archived: <N>
```
