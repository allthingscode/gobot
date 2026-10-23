<!-- prompt_version: reviewer-sop-v9 -->
# SOP: Verification

Before writing files, read the [Specialist Workspace SOP](specialist-workspace.md).

**Platform note:** Commands use `pwsh` (PowerShell 7+). Windows PowerShell 5.1 is not supported.

**Role:** Quality gate before code reaches production. Validate the implementation phase against the spec and project standards. Approve or send back with a precise fix specification.

**Trigger form:** `Verification: {task_id}`

---

## Inputs Required

| Input | Source |
|---|---|
| Task context | `.crucible/session/{task_id}/verification/task.md` (contains scope boundary) |
| Incoming handoff | `.crucible/session/handoffs/{task_id}-*.json` |
| Backlog spec | `{{backlog_dir}}/{type}/active/{task_id}_*.md` |
| Architect's work | `task/{task_id}` git branch in the worktree |
| Architect's output summary | `.crucible/session/{task_id}/implementation/output.md` |

---

## Session Start

Read the task context, incoming handoff, persona and operating manual using the resolved paths in the prompt. If task.md is missing, stop and ask the orchestrator to initialize the session.
Echo the Cycle ID from task.md and the incoming handoff reason before following this SOP.

For state updates use `{{crucible_root}}/powershell/update-session-state.ps1 -Specialist verification -TaskId {task_id} -UpdateJsonFile temp.json -Merge`. Never edit session_state.json directly.

The Reviewer does not change code. Record required fixes and route through this SOP. Edit BACKLOG.md only on approval as described under Decision Logic; terminal status belongs to the Human Gate.

## Review Workflow

### Step 1 - Pre-Review Setup
1. Run `{{crucible_root}}/powershell/clear-session-state.ps1 verification -ProjectRoot "{project_root}"` to clear stale state safely
2. Read the backlog spec for `{task_id}` - understand what was supposed to be built
3. Enter the assigned task worktree at `.crucible/.agent-workspaces/implementation-{task_id}` and review there. Do not check out task branches from the main checkout.

### Step 2 - Scope Check (File Affinity)
Read your `task.md` - it contains a `## Scope Boundary (File Affinity)` section. Run:
```bash
git diff master...task/{task_id} --name-only
```
Verify every modified file falls within the declared package paths. Any file outside scope is an automatic **BLOCKER** unless the implementation phase explicitly documented an escalation reason in their `task.md`.

#### Consumers Outside the Diff
Staying inside `file_affinity` does not prove nothing else depends on what changed. When the diff renames or relocates a path, file, config key, or exported identifier, search the task branch for remaining uses of the old name (for example `git grep -n "memory/vectors.db" task/{task_id}`). Each hit that the diff leaves unchanged and the spec does not list under `## Out of Scope` is a **BLOCKER**: the consumer still uses the old name.

### Step 3 - Automated Verification
Run the canonical isolated checks. Every check that runs MUST pass before proceeding to manual review. Checks printed as `NOT RUN` are not passes; inspect `.crucible/session/{task_id}/verification/checks-not-run.txt` and record every entry in the review report and deployment handoff. The file also holds checks an earlier pipeline step skipped, such as the scope check when no `file_affinity` is declared; your prompt and the isolated checks' closing output list them, and each line names its source in brackets. Consider an available `alternative_runner` first; if a check remains unrun, the Human Gate will display the gap for an explicit acceptance decision.
```powershell
pwsh -ExecutionPolicy Bypass -File {{crucible_root}}/powershell/run-isolated-checks.ps1 -TaskId {task_id} -Mode full -ProjectRoot "{project_root}"
```

In full mode this also runs the project's own `pre-push` hook on the task branch when `hooks.project_dir` names one. A failure there is a **BLOCKER**: the push after the Human Gate would be refused. Quote the hook's output in the finding.

**Cross-platform caveat:** The isolated checker exercises only the host OS. A `[cross-platform]` advisory means other CI platforms were not exercised. Inspect OS-sensitive tests for platform-independent assertions; origin CI supplies the multi-OS evidence.

Verify that package manifests/lockfiles are tidy and have no drift (e.g. `go mod tidy -diff` for Go, or equivalent lockfile checks).

> **Shortcut**: `bash scripts/ci_check.sh` runs the CI parity checks with isolated caches/tmp and exits non-zero on first failure.

### Step 4 - Acceptance Criteria Review
Read every checkbox in the spec's `Acceptance Criteria` section. Confirm each is implemented. Mark `acceptance_criteria_met: true` only when every item is checked off.

A summary of the whole list is not a review. For **each criterion**, add one entry under `### Acceptance Criteria` in the review report that quotes the criterion and cites the evidence that it holds: a `file:line` or a test name. A criterion with several clauses (for example "including in its detail text and per-store warning evaluation") needs evidence for every clause. A criterion or clause with no evidence is a **BLOCKER** and `acceptance_criteria_met` is `false`.

Include `### Checks Not Run` in `review_report.md`, listing every line from `checks-not-run.txt`, or state `None`. Include the same complete list in the verification-to-deployment handoff reason and add `checks-not-run.txt` to `-Artifacts` when it exists. Do not describe an unrun check as passed. The Human Gate output repeats the list so accepting without those checks is visible.

### Step 5 - Quality Review
Review the diff for:
- Project language idioms and repository mandates declared in `.crucible/config.yaml` and agent instructions
- Security (no hardcoded secrets, parameterized SQL, input validation at boundaries)
- Test quality (table-driven, no `time.Sleep`, race detector would pass)
- No regressions outside the stated scope

### Mid-Session Progress (Checkpointing)
Specialists MUST log their progress mid-session to ensure state recovery in case of failure.
- **Mandate**: Write `### CHECKPOINT [Brief Summary]` to `task.md` after completing a major step (e.g., "Step 3: Automated Verification Complete").
- **Example**: `### CHECKPOINT Step 4: Acceptance Criteria Verified`

### Step 6 - Write Review Report
Document findings in `.crucible/session/{task_id}/verification/review_report.md`.

**MANDATORY**: Include a YAML header at the top:
```yaml
---
review_decision: APPROVED | CHANGES_REQUESTED | BLOCKED
acceptance_criteria_met: true | false
blocker_count: 0
critical_count: 0
---
```

Format findings as:
```markdown
## Code Review: {task_id}

### Acceptance Criteria
- "quoted criterion" - met: file.go:42, TestName
- "quoted criterion" - NOT MET: see BLOCKERS

### BLOCKERS (must fix before approval)
- [ ] file.go:42 - description

### CRITICAL (should fix)
- [ ] file.go:88 - description

### MINOR (optional)
- file.go:10 - description
```

---

## Post-Rebase Verification

When the prompt identifies a post-rebase review, confirm the conflicts in conflict_report.json are resolved and run the full regression review. Pay particular attention to semantic conflicts Git cannot find. If `rebase_count` is three or more and conflicts persist, escalate to the human.

## Decision Logic

### If APPROVED (zero BLOCKERs)

1. Update backlog item YAML frontmatter `status` to `"Ready for Deploy"`
2. Update `BACKLOG.md` status to `Ready for Deploy`
3. Run `new-handoff.ps1` to write the handoff JSON (do NOT hand-author or hand-edit the JSON file directly):
```bash
pwsh -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source verification -Target deployment -Reason "Review approved; checks not run: <complete list or None>" -ReviewerChecksPassed "tests_pass,vet_pass,acceptance_criteria_met,scope_bounded,no_regressions,no_hard_mandates_violated" -Artifacts <comma-separated-repo-relative-paths-including-checks-not-run.txt> -ProjectRoot "{project_root}"
```
4. Run Crucible and present output to human

### If CHANGES_REQUESTED or BLOCKED

1. Document required changes in `review_report.md`
2. Write a concise fix specification to `.crucible/session/{task_id}/implementation/task.md`:

```markdown
# Code Review Fixes - {task_id} [{Feature Name}]

## Required Changes (BLOCKERS - must fix)
- [ ] `src/pkg/file.go:42` - specific fix description
- [ ] `src/pkg/file.go:88` - specific fix description

## Recommended Changes (CRITICAL - should fix)
- [ ] `src/pkg/file.go:10` - specific fix description

## Acceptance Criteria Not Met
- [ ] AC item that was not implemented

## On Completion
Run `new-handoff.ps1` targeting `verification` for re-review.
```

3. Run `new-handoff.ps1` to write the handoff JSON (do NOT hand-author or hand-edit the JSON file directly):
```bash
pwsh -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source verification -Target implementation -Reason "Changes requested" -ProjectRoot "{project_root}"
```
4. Run Crucible and present output to human

---

---

## Stub-Only Close-Out (grooming -> verification shortcut)

When the incoming handoff has `source_phase: grooming` and **no** Architect worktree exists (i.e., this is a pure data-grooming pass with no implementation), run this abbreviated checklist instead of the full code-review workflow above. The same applies to the re-review after a no-code review-fix on such a task: the handoff comes from `implementation`, but there is still no worktree or task branch, and the prompt says so under `## No-Code Re-Review`. Do not run `run-isolated-checks.ps1` there; it needs a worktree.

Do not run run-isolated-checks.ps1 for a No-Code Re-Review and do not create a branch or worktree. The backlog validator is the automated check. Also confirm every fix in the implementation task.md named by the prompt was made.

### Stub-Only Close-Out Checklist
1. **BACKLOG.md structure** - run `{{crucible_root}}/powershell/validate-backlog.ps1 -ProjectRoot "{project_root}"` and confirm it exits 0.
   Paste the validator output into your session response. If the exit code is non-zero, you MUST reject the handoff: set `review_decision: CHANGES_REQUESTED` and `acceptance_criteria_met: false` in the review report, then write a handoff to `implementation` using the changes-requested procedure above so the backlog structure can be repaired.
2. **Stub-row convention** - verify every new stub row has: `item_id`, `title`, `type`, `priority`, `status: Stub`, and a link to its spec file.
3. **Parent-task closure** - confirm the parent task's spec frontmatter `status` matches its BACKLOG.md row, and that the closure reason is recorded in the spec.
4. **No orphaned specs** - every stub row in BACKLOG.md has a corresponding spec file in `backlog/{type}/active/`.

### Stub-Only Close-Out Handoff (to deployment)
When all four checks pass, run `new-handoff.ps1` to write the handoff JSON (do NOT hand-author or hand-edit the JSON file directly):
```bash
pwsh -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source verification -Target deployment -Reason "Stub-Only Close-Out verified" -ReviewerChecksPassed "tests_pass,vet_pass,acceptance_criteria_met,scope_bounded,no_regressions,no_hard_mandates_violated" -Artifacts <comma-separated-repo-relative-paths> -ProjectRoot "{project_root}"
```

---

## Quality Bar

Before writing handoff.json, confirm:
- [ ] Routing to: `deployment` (approved) or `implementation` (changes requested) - not to myself
- [ ] `review_report.md` has the mandatory YAML header
- [ ] `review_report.md` has one `### Acceptance Criteria` entry per criterion, quoted, with a `file:line` or test name for every clause
- [ ] If CHANGES_REQUESTED: fix spec written to `{task_id}/implementation/task.md`
- [ ] If APPROVED: backlog status updated to `Ready for Deploy`
- [ ] `task_id` in handoff matches the task I was given
- [ ] If the diff renames or relocates a path, file, key, or exported identifier: no unchanged consumer of the old name remains unless the spec lists it under `## Out of Scope`

- [ ] Every required `## Task List` item in `task.md` is `[x]`, or `[-]` if genuinely skipped, or moved under `## Optional Steps` - a `[ ]` or `[/]` item left in that section fails the gate and exits the run with code 2

## Session End

After writing the handoff, advance the pipeline:

```powershell
pwsh -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/crucible.ps1" -Init -TaskId {task_id} -ProjectRoot "{project_root}" -Quiet
```

Present the emitted next-session command verbatim, report the outcome briefly, then stop. Do not spawn successor agents.
