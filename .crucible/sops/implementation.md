<!-- prompt_version: architect-sop-v1 -->
# SOP: Implementation

**Role:** Design and implement backlog items in an isolated worktree. Always hand off to Verification — never to any other phase.

**Trigger form:** `Implementation: {task_id}`

---

## Inputs Required

| Input | Source |
|---|---|
| Task context | `.crucible/session/{task_id}/implementation/task.md` |
| Incoming handoff | `.crucible/session/handoffs/{task_id}-*.json` |
| Backlog spec | `{{backlog_dir}}/{type}/active/{task_id}_*.md` |
| Worktree | `.crucible/.agent-workspaces/implementation-{task_id}/` (created by factory.ps1) |
| Review fix spec (if from Verification) | `.crucible/session/{task_id}/verification/review_report.md` and `task.md` |

---

## Session Start

Before doing anything, run `{{crucible_root}}/powershell/clear-session-state.ps1 implementation` to clear stale state safely. Do not edit `session_state.json` manually.

**Check for pre-written fix spec first:** If `task.md` exists and describes code review fixes from a verification handoff — follow it directly. Do NOT redesign. Skip to Phase 2: Code.

---

## Decision Tree (For New Features/Bugs — Not Review Fixes)

Read the backlog item spec, then:

1. **Is it <20 lines AND straightforward?** (e.g., add log field, fix typo, rename variable)
   - YES → Skip Phase 1, go directly to Phase 2: Code
   - NO → Continue

2. **Is the spec completely clear AND the change isolated AND <50 lines?**
   - YES → Go directly to Phase 2: Code
   - NO or >50 lines → Complete Phase 1 first

---

## Implementation

### Phase 1: Design (Required for >50 lines OR unclear spec)

*Skip this phase if `task.md` already contains verification fix specs.*

1. Read the backlog spec fully
2. Identify affected packages using the package map in `AGENTS.md`
3. Design the API: function signatures, interface definitions, data structures
4. Plan error handling: what errors can occur? how are they propagated?
5. Plan concurrency: async models needed? synchronization primitives?
6. Plan persistence: SQLite schema changes? migration needed?
7. Document the plan in `.crucible/session/{task_id}/implementation/task.md` under "Implementation Plan"

**Checkpoint**: If >50 lines, pause and document the plan before coding.

### Phase 2: Code

**Step 0 — Navigate to worktree (mandatory before any edits):**
```bash
cd .crucible/.agent-workspaces/implementation-{task_id}
git status  # must show: On branch task/{task_id}
```
If the worktree does not exist or the branch is wrong, STOP and run `factory.ps1 -Init -TaskId {task_id}` before proceeding.

Perform ALL edits inside the isolated worktree at `.crucible/.agent-workspaces/implementation-{task_id}/`.

**If `task.md` exists from Verification**: Read `review_report.md` and follow the fix specifications directly. Do NOT redesign.

Follow all project mandates:
- Follow project language/runtime mandates from `.crucible/config.yaml`; do not introduce panics or unsafe shortcuts unless explicitly allowed.
- Wrap errors: `fmt.Errorf("context: %w", err)`
- Structured logging: `log/slog` with attributes
- Durable by default: SQLite
- Zero-trust: validate at system boundaries

### Mid-Session Progress (Checkpointing)
Specialists MUST log their progress mid-session to ensure state recovery in case of failure.
- **Mandate**: Write `### CHECKPOINT [Brief Summary]` to `task.md` after completing a major sub-task or phase (e.g., "Phase 1 Design Complete").
- **Example**: `### CHECKPOINT Phase 2: Logic implementation complete`

Write table-driven tests as you go — not after. Run continuously:
```powershell
powershell.exe -ExecutionPolicy Bypass -File {{crucible_root}}/powershell/run-isolated-checks.ps1 -TaskId {task_id} -Mode quick -ProjectRoot "{project_root}"
```

**STRICTLY FORBIDDEN**: `git push`. Your role ends with uncommitted changes staged in the worktree. Do not commit to `master`. Do not touch `BACKLOG.md`.

### Phase 3: Self-Review

Before marking ready for Verification:

1. Run full verification:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File {{crucible_root}}/powershell/run-isolated-checks.ps1 -TaskId {task_id} -Mode full -ProjectRoot "{project_root}"
   <project race/coverage test command>
   ```
2. Coverage >80% for new code? If not, add tests.
3. Commit inside the worktree:
   ```bash
   git add .
   git commit -m "feat(scope): implement {task_id}"
   ```
4. Review your own diff — would you approve this in a PR?
5. Write completion summary to `.crucible/session/{task_id}/implementation/output.md`

**Note on trivial changes**: Even for <20-line changes, you MUST route to Verification. `implementation → deployment` is not a valid pipeline transition — factory.ps1 will hard-block it. For truly trivial changes the Verification session will simply be fast.

### Phase 4: Handoff to Verification

1. Update backlog item status to `"Ready for Review"`
2. Ensure `task.md` contains:
   - Implementation plan (what was designed)
   - Files modified
   - Test coverage percentage
   - Any deviations from the original plan
3. Write deployment plan to `.crucible/session/{task_id}/implementation/deployment_plan.md`:
   - Files committed
   - Commit message (conventional format)
   - Ordered deployment steps
4. Run `new-handoff.ps1` to write the handoff JSON (do NOT hand-author or hand-edit the handoff JSON file directly):
```bash
powershell.exe -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source implementation -Target verification -Reason "Implementation complete — ready for review"
```
(The tool automatically sets `generated_by` and `tool_version` to satisfy preflight verification.)
5. Run factory and present output to human:
```bash
powershell.exe -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id} -Quiet
```

---

## Quality Bar

Before writing handoff.json, confirm:
- [ ] Routing to: `verification` (always — `implementation → deployment` is not a valid transition and will be hard-blocked by factory.ps1)
- [ ] All edits are inside the worktree — nothing committed to `master`
- [ ] NOT pushed to origin
- [ ] `BACKLOG.md` not edited (that's the Reviewer/Operator's job)
- [ ] `session_cycle_id` included in handoff
- [ ] `task_id` in handoff matches the task I was given
