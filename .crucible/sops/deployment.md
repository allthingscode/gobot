<!-- prompt_version: operator-sop-v3 -->
# SOP: Deployment

**Platform note:** Command examples use `powershell.exe` for Windows. On Linux/macOS, replace `powershell.exe` with `pwsh`.

**Role:** Merge approved code, verify production health, clean up artifacts, and hand off to the Groomer for the next cycle.

**Trigger form:** `Deployment: {task_id}`

---

## Inputs Required

| Input | Source |
|---|---|
| Task context | `.crucible/session/{task_id}/deployment/task.md` |
| Incoming handoff | `.crucible/session/handoffs/{task_id}-*.json` (must be from verification, status `Ready for Deploy`) |
| Deployment plan | `.crucible/session/{task_id}/implementation/deployment_plan.md` |
| Backlog | `{{backlog_dir}}/BACKLOG.md` |

---

## Standard Deployment Workflow

### Step 1 — Verify Task Dependencies ({task_id})
- Confirm `factory.ps1 -Init` did not emit a blocking dependency error
- If it blocked due to unsatisfied dependencies: STOP. Hand off to grooming or wait for prerequisites to reach `Production`

### Step 2 — Verify Approval
Confirm the latest verification handoff for `{task_id}` has `status: "Ready for Deploy"`. Do not proceed if verification has not approved.

### Step 3 — Merge Simulation ({task_id})
Before touching `master`, run the merge simulation:
```powershell
{{crucible_root}}/powershell/check-merge-conflicts.ps1 -TaskId {task_id} -ProjectRoot "{project_root}"
```

> [!NOTE]
> Pattern-C closures (research/grooming items with no code changes) have no task branch. `check-merge-conflicts.ps1` will automatically detect the missing branch, print a Pattern-C message, and exit successfully with code 0. You can proceed directly to the next step.

**If simulation fails:**
- Set task status to `"Ready for Rebase"`
- Write handoff to **implementation** with reason: "Merge conflict detected during simulation. See conflict_report.json."
- Instruct implementation to rebase `task/{task_id}` onto `master`

- If simulation passes: Proceed to Step 4.

### Mid-Session Progress (Checkpointing)
Specialists MUST log their progress mid-session to ensure state recovery in case of failure.
- **Mandate**: Write `### CHECKPOINT [Brief Summary]` to `task.md` after completing a major step (e.g., "Step 4: Dev Log Generated").
- **Example**: `### CHECKPOINT Step 4: Dev Log Generated`

### Step 4 — Dev Log Generation ({task_id})
Draft a narrative update using `.crucible/dev-logs/TEMPLATE.md` and append to `.crucible/dev-logs/UNPUBLISHED_LOGS.md`.

For strictly internal Dev Factory tasks with no public-facing changes: append an entry with Date, Topic, and: `*Internal Dev Factory task. No public narrative required.*`

Validate before continuing:
```powershell
{{crucible_root}}/powershell/validate-dev-log.ps1 -FileToPublish .crucible/dev-logs/UNPUBLISHED_LOGS.md
```

### Step 5 — Capture Eval Record

Write a structured eval record before archiving the pipeline log. This feeds `{{crucible_root}}/powershell/analyze-evals.ps1`.

```powershell
# Replace {task_id} with the actual task ID
$log = Get-Content ".crucible/session/{task_id}/pipeline.log.jsonl" | ForEach-Object { $_ | ConvertFrom-Json }
$archSessions = @($log | Where-Object { $_.event -eq "session_end" -and $_.phase -eq "implementation" }).Count
$degraded     = @($log | Where-Object { $_.event -eq "degraded" }).Count
$finalMetrics = ($log | Where-Object { $_.event -eq "session_end" -and $_.metrics } | Select-Object -Last 1).metrics

$gate = Get-ChildItem ".crucible/session/global/gate_decisions/{task_id}*.json" |
    Sort-Object Name -Descending | Select-Object -First 1 |
    ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }

$eval = [ordered]@{
    task_id         = "{task_id}"
    completed_at    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    budget_tier     = $finalMetrics.budget_tier
    budget_pct_used = $finalMetrics.budget_pct_used
    gate_outcome    = $gate.outcome
    rework_requested = [bool]$gate.rework_requested
    review_cycles   = $archSessions
    degraded_events = $degraded
    ac_verified     = $true   # set $false if any AC items were skipped or not fully met
    notes           = ""
}

New-Item -ItemType Directory -Force -Path ".crucible/session/eval" | Out-Null
$eval | ConvertTo-Json | Out-File -FilePath ".crucible/session/eval/eval-{task_id}.json" -Encoding utf8
```

### Step 6 — Backlog, Log Deferral, and Cleanup
No manual backlog update, log archiving, or Git cleanup is required here. The factory's Human Gate automatically merges the branch `task/{task_id}`, pushes to remote origin, deletes the worktree and branch, archives the backlog spec, updates the `BACKLOG.md` status, reconciles the Priority-Summary, and archives the pipeline log once the human records an `accepted` or `redirected` decision.

### Step 7 — Run new-handoff.ps1 & Advance Pipeline
Run `new-handoff.ps1` to write the handoff JSON (do NOT hand-author or hand-edit the JSON file directly). Set target_phase to "done" and pass the task branch commit hash (or simply omit it to inherit the implementation branch commit hash from the previous phase):
```bash
powershell.exe -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source deployment -Target done -Reason "Deployment complete. Pipeline resolved."
```
(The tool automatically sets `generated_by` and `tool_version` to satisfy preflight verification.)

Run factory:
```bash
powershell.exe -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id} -Quiet
```

**Human Gate handling:** If `factory.ps1` exits without `[NEXT SESSION COMMAND]`, check for `gate_pending.txt` in your session dir. The file contains the gate menu and visual review options (Launch visual diff tool, Command-line text diff, and Open the worktree folder in your editor) to help the human inspect changes. Present the gate menu and options, and ask for the human's choice:

```
1) Accept   - work looks good; pause after this item
2) Reject   - something is wrong, send back for rework
3) Redirect - accept this item and work a specific item next
4) Abandon  - do not accept; stop the pipeline
```

**Before recording the decision, ask:**
> "In one sentence, describe the output quality or reason for this decision (e.g. 'Clean, all AC met' or 'Accepted but error handling was thin')."

The reason is required for **every** outcome, including `accepted` and `abandoned`. Placeholder text (`n/a`, `none`, `ok`, `looks good`) is invalid.

Once you have the human's sentence, patch it into the pending gate decision file and then call factory:

```powershell
# Patch the qualitative reason into the pending gate decision before factory records it
$pendingFile = Get-ChildItem ".crucible/session/global/gate_decisions/gate_decision_{task_id}_pending.json" -ErrorAction SilentlyContinue
if ($pendingFile) {
    $pending = Get-Content $pendingFile.FullName -Raw | ConvertFrom-Json
    $pending.reason = "<human's one-sentence quality note>"
    $pending | ConvertTo-Json | Out-File $pendingFile.FullName -Encoding utf8
}
```

```bash
powershell.exe -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id} -GateOutcome <outcome> -GateReason "<human's one-sentence quality note>" -Quiet
```

Present factory output to the human. Wait for confirmation before ending your session.

---

## Reject — Send Back for Rework Loop

If a task is rejected during the Human Gate (e.g. choice 2: `rejected`), the following automatic and manual procedures apply to resume the task:

1. **Automatic Unwind and Re-creation**:
   - The factory automatically unwinds the local merge on the default branch, resetting it to the pre-merge tip.
   - The task branch `task/{task_id}` is restored.
   - The implementation worktree at `.crucible/.agent-workspaces/implementation-{task_id}` is automatically re-created from the restored branch.
   - A sanctioned re-entry handoff targeting `implementation` is generated automatically under `.crucible/session/handoffs/` (with the strike/rework counter incremented and `generated_by=new-handoff.ps1`).

2. **Orchestrator Resumption**:
   - The orchestrator or operator resumes the task by executing the standard initialization:
     ```bash
     powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id}
     ```
   - This will boot the implementation phase, print the prompt, and output the command line for the next session under `[NEXT SESSION COMMAND]`.

---

## Abandon — Stop the Pipeline

If a task is abandoned during the Human Gate (choice 4: `abandoned`), the following procedures apply:

1. **Automatic Unwind**:
   - The factory automatically unwinds the local merge on the default branch, resetting it to the pre-merge tip.
   - Unlike the reject path, no task branch is restored and no new implementation worktree is created.

2. **Backlog End State**:
   - Because backlog finalization is deferred to accept/redirect outcomes, the task's spec remains in the `active/` directory and is NOT marked as `Resolved` or `Production` in `BACKLOG.md`. This ensures the task does not mistakenly read as completed.
   - The operator or human can manually mark the task row as `Abandoned` in `BACKLOG.md` and archive/delete the spec file as needed.

---

## Feedback Loop for Production Issues

When production issues are discovered that meet the circuit breaker threshold (P0 crash/data loss, OR 5+ occurrences of a minor issue):

1. Document findings in `.crucible/session/{task_id}/deployment/deployment_report.md`
2. Run `new-handoff.ps1` to write the handoff JSON targeting grooming (do NOT hand-author or hand-edit the JSON file directly):
```bash
powershell.exe -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source deployment -Target grooming -Reason "Production issues detected — see deployment_report.md. grooming should dispatch Researcher."
```
(The tool automatically sets `generated_by` and `tool_version` to satisfy preflight verification.)
3. Run factory and present output to human

> **Note**: `deployment → research` is NOT a valid pipeline transition. The deployment phase can only route to grooming. The grooming phase can then dispatch the Researcher if a research task is warranted.

---

## Quality Bar

Pre-flight gate — confirm all are true before writing handoff:
- [ ] `BACKLOG.md` entry for `{task_id}` shows active status (e.g. `Ready for Deploy` or `In Progress`)
- [ ] Pipeline log is in `.crucible/session/{task_id}/` (will be archived by the factory on accept)
- [ ] Working tree is clean (`git status --short` shows nothing unexpected)
- [ ] Routing to: `done` (or `grooming` if production issue threshold met)
- [ ] `task_id` in handoff matches the task I was given
- [ ] `commit_hash` in handoff matches the task branch tip commit hash (or is inherited)
- [ ] Eval record written to `.crucible/session/eval/eval-{task_id}.json`
