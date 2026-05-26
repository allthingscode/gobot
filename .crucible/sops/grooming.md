---
name: grooming
title: "Backlog Grooming Session"
version: "1.0.0"
owner: "groomer"
frequency: "weekly"
last_run: ""
last_run_by: ""
last_run_outcome: ""
requires_terminal: false
---

# Runbook: Backlog Grooming Session

## Quick Start

Paste into Claude Code:
```
Follow the procedure in .crucible/sops/grooming.md
```

Quick priority check only:
```
Follow the procedure in .crucible/sops/grooming.md — run Pass 3 and Pass 4 only, skip Pass 1 and 2
```

## Procedure

Follow the Groomer SOP (`.crucible/personas/groomer.md`) strictly.

1. **Load Groomer SOP**: Read `.crucible/personas/groomer.md`. Adopt the groomer persona. Check for lock at `.crucible/locks/groomer.lock` — if it exists, stop and inform the human.

2. **Resume from state** (per grooming SOP): Read `.crucible/session/global/session_state.json` → `personas.groomer`. If there is active state, resume from the saved phase and last item. If idle, start a fresh session.

3. **Pass 1 — Inventory & Deduplication**:
   - Scan `{{backlog_dir}}/` root — count active items by prefix (F-XXX, B-XXX, C-XXX)
   - Read `{{backlog_dir}}/BACKLOG.md` master index
   - Find semantic duplicates (same problem, different IDs). Merge context into the older item, set the duplicate to `status: "Archived"`
   - Detect rot: items referencing paths/files that no longer exist. Update or archive them.

4. **Pass 2 — Definition of Ready audit**:
   - Each item must have: valid YAML frontmatter, Problem Statement, Proposed Architecture/Solution, Acceptance Criteria (as checkboxes), Context & Dependencies
   - Items missing required sections → set `status: "Draft"`, add notes about what is missing

5. **Pass 3 — Prioritization & Rot detection**:
   - Apply the Hardening-First matrix: P0 (stability fix), P1 (hardening/reliability), P2 (features/bugs), P3 (speculative)
   - Hardening must rank above any extensibility work
   - Flag items that have been Draft for a long time with no updates

6. **Pass 4 — Index reconciliation**:
   - Ensure `{{backlog_dir}}/BACKLOG.md` tables match the actual files and their current frontmatter
   - Production/Resolved items should be moved to the Archived section of the index
   - **Never delete files.** Move Production/Resolved items from root to `archived/` directory, then update each file's frontmatter `status` to `"Production"` or `"Resolved"`.

7. **Update runbook registry**: Edit `.crucible/sops/registry.md` — update this runbook's `last_run`, `last_run_by`, and `last_run_outcome` fields.

8. **Append to runbook log**: Write entry to `.crucible/session/global/runbook_log.md`:
   ```markdown
   ### grooming -- <ISO timestamp>
   - Outcome: success
   - Items reviewed: <N>
   - Items reclassified: <N>
   - Items archived: <N>
   - Files modified: <list>
   ```

## Completion Block

```
==================================================
RUNBOOK COMPLETE: grooming
==================================================
Items reviewed: <N>
Items reclassified: <N>
Items archived: <N>
Files modified: <list>
```
