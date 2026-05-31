<!-- prompt_version: operator-sop-v3 -->
# SOP: Deployment

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
{{crucible_root}}/powershell/check-merge-conflicts.ps1 -TaskId {task_id}
```

**If simulation fails:**
- Set task status to `"Ready for Rebase"`
- Write handoff to **implementation** with reason: "Merge conflict detected during simulation. See conflict_report.json."
- Instruct implementation to rebase `task/{task_id}` onto `master`

- If simulation passes: Proceed to Step 4.

### Mid-Session Progress (Checkpointing)
Specialists MUST log their progress mid-session to ensure state recovery in case of failure.
- **Mandate**: Write `### CHECKPOINT [Brief Summary]` to `task.md` after completing a major step (e.g., "Step 4: Merge to Master Complete").
- **Example**: `### CHECKPOINT Step 5: Dev Log Generated`

### Step 4 — Local Merge
```bash
git checkout master
git merge --no-edit task/{task_id}
```

Do NOT run `git push`. The factory's Human Gate will perform the push to origin automatically once accepted.

**Verify merge succeeded:**
```bash
git log master --oneline -1
```
Confirm the merge commit succeeded locally. If the merge failed or has conflicts: STOP. Do NOT write a handoff until merge is verified.

### Step 5 — Dev Log Generation ({task_id})
Draft a narrative update using `.crucible/dev-logs/TEMPLATE.md` and append to `.crucible/dev-logs/UNPUBLISHED_LOGS.md`.

For strictly internal Dev Factory tasks with no public-facing changes: append an entry with Date, Topic, and: `*Internal Dev Factory task. No public narrative required.*`

Validate before continuing:
```powershell
{{crucible_root}}/powershell/validate_dev_log.ps1 -FileToPublish .crucible/dev-logs/UNPUBLISHED_LOGS.md
```

### Step 6 — Cleanup
```bash
git worktree remove .crucible/.agent-workspaces/implementation-{task_id}
git branch -d task/{task_id}
git status --short
```

Delete any untracked files outside `.crucible/`, `.agent-workspaces/`, `.gemini/`, `.vscode/`. The working tree must be clean — `factory.ps1` will block if stray files remain.

### Step 7 — Capture Eval Record

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

### Step 8 — Update Backlog & Archive
- **Atomic Resolution**: Run `powershell.exe -File {{crucible_root}}/powershell/archive-task.ps1 -BacklogPath {{backlog_dir}}/BACKLOG.md -SpecPath {{backlog_dir}}/{type}/active/{task_id}_*.md`. This updates the `BACKLOG.md` row to `Production` for features or `Resolved` for chores/bugs, moves the spec to `{{backlog_dir}}/{type}/archived/`, and rewrites the archived spec frontmatter `status` to the same terminal value.
- Update `BACKLOG.md` summary table: `powershell.exe -File {{crucible_root}}/powershell/validate-backlog.ps1 -FixSummary`
- Move pipeline log: `.crucible/session/{task_id}/pipeline.log.jsonl` → `.crucible/session/archived/pipeline-{task_id}-{timestamp}.log.jsonl`

### Step 9 — Write Handoff & Advance Pipeline
Write handoff.json (set target_phase to "done" and commit_hash to the merged master/main commit hash):
```json
{
  "task_id": "F-XXX",
  "source_phase": "deployment",
  "target_phase": "done",
  "handoff_retry_count": 0,
  "cumulative_handoff_count": N,
  "budget_tier": "...",
  "prompt_version": "deployment-sop-v3",
  "commit_hash": "MERGE_COMMIT_HASH",
  "reason": "Deployment complete. Pipeline resolved."
}
```

Run factory:
```bash
powershell.exe -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id} -Quiet
```

**Human Gate handling:** If `factory.ps1` exits without `[NEXT SESSION COMMAND]`, check for `gate_pending.txt` in your session dir. Present the gate menu and ask for the human's choice:

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

## Feedback Loop for Production Issues

When production issues are discovered that meet the circuit breaker threshold (P0 crash/data loss, OR 5+ occurrences of a minor issue):

1. Document findings in `.crucible/session/{task_id}/deployment/deployment_report.md`
2. Route to **grooming** (the only valid deployment successor). Include a clear reason that tells grooming this is a production issue requiring research:
```json
{
  "task_id": "F-XXX",
  "source_phase": "deployment",
  "target_phase": "grooming",
  "handoff_retry_count": 0,
  "cumulative_handoff_count": N,
  "budget_tier": "...",
  "prompt_version": "deployment-sop-v3",
  "reason": "Production issues detected — see deployment_report.md. grooming should dispatch Researcher.",
  "suspicious_content": null
}
```
3. Run factory and present output to human

> **Note**: `deployment → research` is NOT a valid pipeline transition. The deployment phase can only route to grooming. The grooming phase can then dispatch the Researcher if a research task is warranted.

---

## Quality Bar

Pre-flight gate — confirm all are true before writing handoff:
- [ ] `git log master --oneline -1` shows the merge commit (merge succeeded locally)
- [ ] `BACKLOG.md` entry for `{task_id}` shows `Production` or `Resolved`
- [ ] Worktree and task branch have been deleted
- [ ] Pipeline log archived
- [ ] Working tree is clean (`git status --short` shows nothing unexpected)
- [ ] Routing to: `done` (or `grooming` if production issue threshold met)
- [ ] `task_id` in handoff matches the task I was given
- [ ] `commit_hash` in handoff matches the local merge commit hash
- [ ] Eval record written to `.crucible/session/eval/eval-{task_id}.json`
