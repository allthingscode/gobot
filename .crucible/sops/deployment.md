<!-- prompt_version: operator-sop-v9 -->
# SOP: Deployment

Before writing files, read the [Specialist Workspace SOP](specialist-workspace.md).

**Platform note:** Commands use `pwsh` (PowerShell 7+). Windows PowerShell 5.1 is not supported.

**Role:** Merge approved code, verify production health, clean up artifacts, and hand off to the Groomer for the next cycle.

**Trigger form:** `Deployment: {task_id}`

---

## Inputs Required

| Input | Source |
|---|---|
| Task context | `.crucible/session/{task_id}/deployment/task.md` |
| Incoming handoff | `.crucible/session/handoffs/{task_id}-*.json` (from verification, `target_phase: deployment`) |
| Deployment plan | `.crucible/session/{task_id}/implementation/deployment_plan.md` |
| Backlog | `{{backlog_dir}}/BACKLOG.md` |

---

## Session Start

Read the task context, incoming handoff, persona and operating manual using the resolved paths in the prompt. If task.md is missing, stop and ask the orchestrator to initialize the session.
Before proceeding, echo the following from the required files:

1. From task.md: What is the Cycle ID?
2. From the incoming handoff: What is the handoff reason?
3. Which legal successor phase will this session use: `done`, `grooming`, or `implementation` (rework only)?

If any answer is missing, stop and re-read the files.

For state updates use `{{crucible_root}}/powershell/update-session-state.ps1 -Specialist deployment -TaskId {task_id} -UpdateJsonFile temp.json -Merge`. Never edit session_state.json directly.

The specialist never pushes. The Human Gate pushes only when `review.auto_push` is true. Perform deployment work in the main checkout; leave merge and cleanup to the Human Gate. Run the configured health check before and after significant operational changes. Write full reports to `.crucible/session/{task_id}/deployment/deployment_report.md` and summarize them in 1-2 sentences.

## Standard Deployment Workflow

### Step 1 - Verify Task Dependencies ({task_id})
- The orchestrator's `crucible.ps1 -Init` already ran the dependency gate. A blocking result exits with code 2 before `task.md` is created, so an existing `task.md` means the gate passed. Do not re-run `-Init` at session start
- If `task.md` is missing or a `[DEPENDENCY] BLOCKING` line was shown: STOP. Hand off to grooming or wait for prerequisites to reach `Production`

### Step 2 - Verify Approval
Confirm the latest verification handoff for `{task_id}` has `target_phase: deployment` and the verification `review_report.md` YAML header has `review_decision: APPROVED` and `acceptance_criteria_met: true`.
The BACKLOG status `Ready for Deploy` also records approval for manual confirmation. Do not proceed if verification has not approved. Crucible checks the handoff and review report before `-Init` creates the deployment session; BACKLOG status alone does not bypass that gate.

### Step 3 - Merge Simulation ({task_id})
Before touching `master`, run the merge simulation:
```powershell
{{crucible_root}}/powershell/check-merge-conflicts.ps1 -TaskId {task_id} -ProjectRoot "{project_root}"
```

> [!NOTE]
> No-Code Closures (research/grooming items with no code changes) have no task branch. `check-merge-conflicts.ps1` will automatically detect the missing branch, print a No-Code Closure message, and exit successfully with code 0. At `deployment -> done`, the Crucible gate also detects proven No-Code Closures (spec has `type: research` or `type: grooming` in frontmatter or task ID uses `R-*` prefix, AND no `refs/heads/task/{task_id}` branch exists, AND `commit_hash` is null/absent) and skips merge verification. You can proceed directly to the next step. `validate-handoff.ps1` decides the same exemption from the same evidence (`lib/no-code-closure.ps1`), so `new-handoff.ps1` writes this handoff with a null `commit_hash` rather than refusing it.

**Exit 2 is not a conflict.** The main checkout has uncommitted changes to tracked files, or the simulated merge could not be undone; the simulation refuses to run over uncommitted work. Do not hand off for rebase: stop and escalate to the human with the output.

**If simulation fails with exit 1 (a conflict):**
- Set task status to `"Ready for Rebase"`
- Write handoff to **implementation** with reason: "Merge conflict detected during simulation. See conflict_report.json.", passing `-RebaseCount` one above the incoming handoff's `rebase_count`. Validation refuses deployment -> implementation at `rebase_count` 0. Use the next rebase count supplied in the prompt as `{next_rebase_count}` in this command:
  ```powershell
  pwsh -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source deployment -Target implementation -Reason "Merge conflict detected during simulation. See conflict_report.json." -RebaseCount {next_rebase_count} -ProjectRoot "{project_root}"
  ```
- Instruct implementation to rebase `task/{task_id}` onto `master`
- After writing the conflict handoff, run Crucible with the advance command in Step 7, then STOP. Skip Steps 4-6: nothing was deployed, so do not write a dev log or eval record. Do not write the Step 7 deployment-to-done handoff.

- If simulation passes: Proceed to Step 4.

### Mid-Session Progress (Checkpointing)
Specialists MUST log their progress mid-session to ensure state recovery in case of failure.
- **Mandate**: Write `### CHECKPOINT [Brief Summary]` to `task.md` after completing a major step (e.g., "Step 4: Dev Log Generated").
- **Example**: `### CHECKPOINT Step 4: Dev Log Generated`

### Step 4 - Dev Log Generation ({task_id})
Draft a narrative update using `.crucible/templates/dev-log-entry.md` and append to `.crucible/dev-logs/UNPUBLISHED_LOGS.md`.

For strictly internal Crucible tasks with no public-facing changes: append an entry with Date, Topic, and: `*Internal Crucible task. No public narrative required.*`

Validate before continuing:
```powershell
{{crucible_root}}/powershell/validate-dev-log.ps1 -FileToPublish .crucible/dev-logs/UNPUBLISHED_LOGS.md
```

### Step 5 - Capture Eval Record

Write a structured eval record before archiving the pipeline log. This feeds `{{crucible_root}}/powershell/analyze-evals.ps1`.

```powershell
# Replace {task_id} with the actual task ID
$log = Get-Content ".crucible/session/{task_id}/pipeline.log.jsonl" | ForEach-Object { $_ | ConvertFrom-Json }
$archSessions = @($log | Where-Object { $_.event -eq "session_end" -and $_.phase -eq "implementation" }).Count
# Reduced-assurance events only. Duplicate handoff bookkeeping is reported separately by analyze-evals.ps1 handoff_quality.
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

### Step 6 - Do Not Finalize the Task
Do NOT run `archive-task.ps1`, and do NOT set the `BACKLOG.md` status to `Production` or `Resolved`. Leave the task in an active status and let the Human Gate finalize it.

The gate enforces this from both sides, keyed on whether a human has decided:

- **Before** an `accepted` or `redirected` decision exists, a task marked `Production` or `Resolved` is refused, because that status claims work shipped that nobody approved.
- **After** the decision, the same task is required to be terminal, and the gate archives it itself.

So finalizing early does not save a step. It trips the first check, and recovery means reverting the spec location, its frontmatter status, its `BACKLOG.md` row, and the Priority Summary count by hand.

(Note: no manual Git cleanup or pipeline log archiving is required either; on an `accepted` or `redirected` decision the Human Gate merges `task/{task_id}`, deletes the worktree and branch, and archives the pipeline log. It pushes to origin only when `review.auto_push` is true.)

### Step 7 - Run new-handoff.ps1 & Advance Pipeline
Run `new-handoff.ps1` to write the handoff JSON (do NOT hand-author or hand-edit the JSON file directly). Set target_phase to "done". Omit `-CommitHash` and the tool records the tip of `task/{task_id}` itself; pass it only to record a different commit:
```bash
pwsh -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source deployment -Target done -Reason "Deployment complete. Pipeline resolved." -ProjectRoot "{project_root}"
```
(The tool automatically sets `generated_by` and `tool_version` to satisfy preflight verification.)

Run Crucible:
```bash
pwsh -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/crucible.ps1" -Init -TaskId {task_id} -ProjectRoot "{project_root}" -Quiet
```

**Human Gate handling:** If `crucible.ps1` exits without `[NEXT SESSION COMMAND]`, check for `gate_pending.txt` in your session dir. The file contains the gate menu and visual review options (Launch visual diff tool, Command-line text diff, and Open the worktree folder in your editor) to help the human inspect changes. Present the gate menu and options, and ask for the human's choice:

Copy the Accept line out of `gate_pending.txt` rather than retyping it: its wording follows
`review.auto_push`, so a line typed from this SOP can promise the human a push that will not
happen (or hide one that will).

```
1) Accept   - {the Accept line from gate_pending.txt, verbatim; it states whether the merge also publishes to origin}
2) Reject   - something is wrong, send back for rework
3) Redirect - accept this item and work a specific item next
4) Abandon  - do not accept; stop the pipeline
```

**Before recording the decision, ask:**
> "In one sentence, describe the output quality or reason for this decision (e.g. 'Clean, all AC met' or 'Accepted but error handling was thin')."

The reason is required for **every** outcome, including `accepted` and `abandoned`. Crucible refuses a reason that is empty or is exactly one of these stock phrases, ignoring case and surrounding spaces: `n/a`, `na`, `none`, `ok`, `looks good`, `looks good.`, `approved`, `accept`, `accepted`, `done`, `ship it`, `auto`. Any longer reason is recorded as the human's own, even one that starts with a stock phrase. Ask for a concrete reason, but do not tell the human that a longer one will be refused.

Once you have the human's sentence, pass it to Crucible with `-GateReason`. Crucible records it in the decision and removes the pending file.

```bash
pwsh -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/crucible.ps1" -Init -TaskId {task_id} -ProjectRoot "{project_root}" -GateOutcome <outcome> -GateReason "<human's one-sentence quality note>" -Quiet
```

Present a 2-3 sentence summary of the deployment and commit hash, and only the single `[NEXT SESSION COMMAND]` command line from Crucible output, verbatim in a code block. Do NOT paste the full Crucible output, CI banners, gate logs, backlog validation lines or other diagnostics. If no next-session command was emitted, follow the Human Gate handling above. Wait for confirmation before ending your session.

---

## Reject - Send Back for Rework Loop

If a task is rejected during the Human Gate (e.g. choice 2: `rejected`), the following automatic and manual procedures apply to resume the task:

1. **Automatic Unwind and Re-creation**:
   - Crucible automatically unwinds the local merge on the default branch, resetting it to the pre-merge tip.
   - The task branch `task/{task_id}` is restored.
   - The implementation worktree at `.crucible/.agent-workspaces/implementation-{task_id}` is automatically re-created from the restored branch.
   - A sanctioned re-entry handoff targeting `implementation` is generated automatically under `.crucible/session/handoffs/` (with the strike/rework counter incremented and `generated_by=new-handoff.ps1`).

2. **Orchestrator Resumption**:
   - The orchestrator or operator resumes the task by executing the standard initialization:
     ```bash
     pwsh -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/crucible.ps1" -Init -TaskId {task_id} -ProjectRoot "{project_root}"
     ```
   - This will boot the implementation phase, print the prompt, and output the command line for the next session under `[NEXT SESSION COMMAND]`.

---

## Abandon - Stop the Pipeline

If a task is abandoned during the Human Gate (choice 4: `abandoned`), the following procedures apply:

1. **Automatic Unwind**:
   - Crucible automatically unwinds the local merge on the default branch, resetting it to the pre-merge tip.
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
pwsh -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source deployment -Target grooming -Reason "Production issues detected - see deployment_report.md. grooming should dispatch Researcher." -ProjectRoot "{project_root}"
```
(The tool automatically sets `generated_by` and `tool_version` to satisfy preflight verification.)
3. Run Crucible and present the next-session command as specified in [Step 7](#step-7---run-new-handoffps1--advance-pipeline).

> **Note**: `deployment -> research` is NOT a valid pipeline transition. The deployment phase can only route to grooming. The grooming phase can then dispatch the Researcher if a research task is warranted.

---

## Quality Bar

Pre-flight gate - confirm all are true before writing handoff:
- [ ] `BACKLOG.md` entry for `{task_id}` shows active status (e.g. `Ready for Deploy` or `In Progress`)
- [ ] Pipeline log is in `.crucible/session/{task_id}/` (will be archived by Crucible on accept)
- [ ] Working tree is clean (`git status --short` shows nothing unexpected)
- [ ] Routing to one legal successor: `done`, `grooming` (production issue threshold met), or `implementation` (rework only)
- [ ] `task_id` in handoff matches the task I was given
- [ ] `commit_hash` rule: for `deployment -> done` with code changes, it matches the merge commit on the primary branch; for No-Code Closures (type: research/grooming or R-* task ID, no task branch, no commit_hash), it is null/absent; for `deployment -> grooming` incident handoffs, it identifies the merged commit that caused the production issue
- [ ] Eval record written to `.crucible/session/eval/eval-{task_id}.json`

- [ ] Every required `## Task List` item in `task.md` is `[x]`, or `[-]` if genuinely skipped, or moved under `## Optional Steps` - a `[ ]` or `[/]` item left in that section fails the gate and exits the run with code 2

## Session End

Follow the handoff and advance commands above. Present the emitted next-session command verbatim, report the outcome briefly, then stop. Do not spawn successor agents.
