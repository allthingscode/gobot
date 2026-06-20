<!-- prompt_version: groomer-sop-v1 -->
# SOP: Grooming

**Platform note:** Command examples use `powershell.exe` for Windows. On Linux/macOS, replace `powershell.exe` with `pwsh`.

**Role:** De-risk backlog items and prepare complete technical specifications for the implementation phase.

**Trigger forms:**
- `Grooming: {task_id}` — groom a specific item
- `Grooming: Next item` — find and groom the highest priority ready item
- `Grooming: Review and update the backlog` — full grooming session

---

## Inputs Required

| Input | Source |
|---|---|
| Task context | `.crucible/session/{task_id}/grooming/task.md` |
| Incoming handoff | `.crucible/session/handoffs/{task_id}-*.json` |
| Backlog master index | `{{backlog_dir}}/BACKLOG.md` |
| Backlog spec files | `{{backlog_dir}}/{type}/active/` |
| Research artifacts (if Researcher was involved) | `.crucible/research/R-NNN_*.md` |

---

## Execution Workflow

### Pass 1: Archive & Index Verification
Scan `{{backlog_dir}}/BACKLOG.md` master index for items marked `Production` or `Resolved`. Verify their corresponding `.md` files have been moved from `active/` to `archived/`. If any remain in `active/`, perform the move and update the frontmatter status. Ensure the index tables exactly match the actual active/archived backlog files. Run `{{crucible_root}}/powershell/validate-backlog.ps1 -FixSummary` to sync Priority Summary counts and item IDs.

### Pass 2: Inventory & Deduplication
Scan `{{backlog_dir}}/` for new or untracked items. Deduplicate entries (merge semantic duplicates into the oldest item and archive the duplicate). Refine item titles and descriptions for clarity. Detect rot (items referencing paths or files that no longer exist) and update or archive them. Update state after this pass.

### Pass 3: Priority Triage
Identify the highest priority (`P0` → `P1` → `P2` → `P3`) items. Apply the hardening-first matrix (stability/hardening fixes must rank above features). Confirm status transitions are accurate. Flag any items blocked on external dependencies. Update state after this pass.

#### Ship-vs-Local Severity Check
Before assigning P0/P1 severity to vulnerability, dependency, generated-artifact, vendor, lockfile, or build-output claims, verify whether the affected artifact actually ships or participates in CI/release packaging.

Check the concrete delivery path, not just the file's existence:
- `.gitignore` and release packaging include/exclude rules
- CI build mode and dependency mode (for example `-mod=vendor` vs `-mod=readonly`)
- committed lockfiles/manifests used by the build
- whether the artifact is generated, cached, local-only, or developer-machine-only
- whether the current shipped/released commit already contains the alleged fix

If the affected artifact is local-only, reclassify severity accordingly and describe the issue as developer-experience, hygiene, or local footgun unless it creates a real production/release risk.


### Pass 4: Technical Specification & Definition of Ready Audit
Audit existing active items to ensure they meet the Definition of Ready (valid YAML frontmatter, problem statement, proposed architecture, checkboxes for acceptance criteria, context/dependencies). Draft/complete the detailed spec file for the next item to be implemented. The spec MUST include:
- Clear acceptance criteria (checkboxes)
- All affected packages and files (under a `## Affected Files` or `## Scope` heading, used to validate `file_affinity`)
- A proposed implementation strategy (enough for implementation to start without clarifying questions)
- Any known risks or constraints

**Dependency Identification ({task_id}):** If the item depends on other active or recently completed tasks, add `depends_on: ["F-XXX", "C-YYY"]` to the YAML frontmatter.

### Mid-Session Progress (Checkpointing)
Specialists MUST log their progress mid-session to ensure state recovery in case of failure.
- **Mandate**: Write `### CHECKPOINT [Brief Summary]` to `task.md` after completing a major sub-task or pass.
- **Example**: `### CHECKPOINT Pass 1: Archive Sweep Complete`

---

## Handoff to Implementation

When a P0/P1 item is marked "Ready" with complete specification:

### Step 1 — Assign Budget Tier ({task_id})
Tier ceilings are defined in `{{crucible_root}}/docs/policy.md` Section 2 (canonical source). Guidance:
- **Low**: Docs, small refactors, single-file chores
- **Medium**: Standard features, multi-file refactors
- **High**: New packages, complex architectural changes

### Step 2 — Run new-handoff.ps1

Do NOT hand-author or hand-edit the handoff JSON. You must use the `new-handoff.ps1` tool.

Run `new-handoff.ps1` to write the handoff JSON:
```bash
powershell.exe -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source grooming -Target <implementation|research|verification> -Reason "Ready for next phase" [-FileAffinity "<paths>"] [-BudgetTier <low|medium|high|extended>]
```
(The tool automatically sets `generated_by` and `tool_version` to satisfy preflight verification, and correctly formats fields like `file_affinity`.)

### Step 3 — Run validation
Run `{{crucible_root}}/powershell/validate-backlog.ps1`. A failing validation blocks the handoff — fix `BACKLOG.md` before proceeding.

### Step 4 — Advance pipeline
```bash
powershell.exe -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id} -Quiet
```

Present factory output to the human. Wait for confirmation before ending your session.

---

## Empty Backlog Handling

If there are no active items to implement:
1. Do NOT write a handoff file
2. Do NOT run `factory.ps1`
3. Inform the human the backlog is empty and the pipeline is paused
4. Stop

---

## Pattern C Close-Out (stub-only grooming pass)

When a Research Gate produces only stub backlog rows (no implementation spec and no implementation work to dispatch), hand off directly to `verification` instead of `implementation`. This allows the Verification phase to validate BACKLOG.md structure and parent-task closure before Deployment finalizes the cycle.

Write the handoff with `target_phase: "verification"` and **omit** `file_affinity` (no implementation scope):

```json
{
  "task_id": "...",
  "source_phase": "grooming",
  "target_phase": "verification",
  "handoff_retry_count": 0,
  "cumulative_handoff_count": N,
  "budget_tier": "low",
  "prompt_version": "groomer-sop-v1",
  "reason": "Pattern C: stub rows filed, parent task closed — no implementation work",
  "artifacts": ["{{backlog_dir}}/BACKLOG.md", "{{backlog_dir}}/{type}/active/{task_id}_*.md"],
  "suspicious_content": null
}
```

## Closure Routing (Grooming → Done)

If a grooming session or task results in a closure with no code deliverable (e.g., closing an already-shipped or obsolete feature without deploying new code):
- Run `new-handoff.ps1` with `-Target done` and `-Source grooming`.
- The transition requires a recorded human decision (either a Research-Gate approval as in Pass 17, or a Human Gate).
- If no prior Research Gate approval exists, the factory will trigger a Human Gate, requiring the human to approve it via `-GateOutcome accepted` before it can transition to `done`.
- On transition, the factory will automatically archive and finalize the task status as `Resolved` in both the BACKLOG.md row and the spec frontmatter status. No code push is performed.

## Routing to Research (Grooming → Research)

When routing a task to the `research` phase, the Groomer defines the open questions, scope, and objectives of the investigation.
- **Mandate**: The Groomer MUST NOT perform the investigation itself or write a pre-baked conclusion / closure recommendation into the spec.
- The research acceptance criteria (AC) must be formulated as a neutral open question (e.g., "Investigate whether X is supported; classify outcome as shipped, partially-shipped, obsolete, or needed; cite concrete evidence on disk") rather than a pre-conclusion (e.g., "Confirm that X is shipped and recommend closure").

---

## Quality Bar

Before writing handoff.json, confirm:
- [ ] Routing to: `implementation`, `research`, `done` (closure path), or `verification` (Pattern C only) — not to myself
- [ ] If routing to `implementation`: `file_affinity` is populated with package-level paths
- [ ] If routing to `verification` (Pattern C): no `file_affinity` required; confirm no implementation spec was created
- [ ] Spec file exists in `backlog/{type}/active/` with acceptance criteria (or stubs for Pattern C)
- [ ] `BACKLOG.md` status is updated
- [ ] Backlog validation script passes
- [ ] `task_id` in handoff matches the task being handed off
- [ ] For vuln/dependency/build-artifact claims, ship-vs-local reality was checked before priority/severity was assigned

---

## Runbook Mode: Backlog Grooming Session

Use this runbook for manual, weekly backlog grooming sessions. 

### Trigger
Paste into the agent:
`Follow the procedure in .crucible/sops/grooming.md — Runbook Mode`

To perform a quick priority check only (skipping inventory sweep):
`Follow the procedure in .crucible/sops/grooming.md — Runbook Mode — run Pass 3 and Pass 4 only, skip Pass 1 and 2`

### Procedure
1. **Load Persona**: Read `.crucible/personas/groomer.md` and adopt the Groomer persona.
2. **Resume state**: Read `.crucible/session/global/session_state.json` → `phases.grooming` to check for active state.
3. **Execute Passes**: Run all 4 passes (or Pass 3 & 4 only if requested) across the entire backlog directory as described in the **Execution Workflow** above.
4. **Update runbook registry**: Edit `.crucible/sops/registry.md` — update the `grooming` row's `last_run` and `outcome` fields.
5. **Append to runbook log**: Write an entry to `.crucible/session/global/runbook_log.md`:
   ```markdown
   ### grooming -- <ISO timestamp>
   - Outcome: success
   - Items reviewed: <N>
   - Items reclassified: <N>
   - Items archived: <N>
   - Files modified: <list>
   ```

### Completion Block
Print the following block verbatim to the human at the end of the session:
```
==================================================
RUNBOOK COMPLETE: grooming
==================================================
Items reviewed: <N>
Items reclassified: <N>
Items archived: <N>
Files modified: <list>
```
