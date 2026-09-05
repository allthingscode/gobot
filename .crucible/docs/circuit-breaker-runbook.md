# Circuit Breaker Runbook

When a circuit breaker fires, `factory.ps1` writes a blocked record to `.crucible/backlog/blocked/{task_id}-{timestamp}.json`, updates session state to `blocked`, and halts the pipeline. This runbook has a section for every breaker type.

> **Canonical policy** (thresholds, DAG rules): [policy.md](policy.md)  
> **Blocked record location**: `.crucible/backlog/blocked/{task_id}-{timestamp}.json`  
> **Re-entry command**: `factory.ps1 -Init -TaskId {task_id} -Recover`

---

## How to read a blocked record

```json
{
  "task_id": "F-001",
  "blocked_at": "2026-05-22T14:00:00Z",
  "circuit_breaker": "review_stalemate",
  "attempt_count": 3,
  "last_specialist": "reviewer",
  "summary": "Reviewer rejected implementation three times; scope appears too broad.",
  "human_decision_needed": "Reduce scope, split the task, or abandon?"
}
```

Read `summary` and `human_decision_needed` first. They tell you what failed and what decision is required.

---

## Re-entry procedure (applies to all breakers)

Once you have made a decision:

1. Move the blocked record to archive:
   ```powershell
   Move-Item .crucible/backlog/blocked/{task_id}-*.json .crucible/backlog/blocked/archived/
   ```
2. Update the backlog item status back to `Ready` in `BACKLOG.md` and the spec frontmatter.
3. Resume the pipeline:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File ".crucible/powershell/factory.ps1" -Init -TaskId {task_id} -Recover
   ```
   *(Linux/macOS: replace `powershell.exe` with `pwsh`.)*

The human is never required to edit session JSON directly. The agent handles all file operations after you give verbal direction.

---

## Breaker 1 — Review Stalemate (3-Strike Rule)

**Trigger**: The Architect has failed the Reviewer's checklist 3 times on the same task.

**What it means**: The task as scoped is not converging. Either the spec is ambiguous, the scope is too large, or there is a fundamental technical disagreement between the Architect and Reviewer.

**Decision tree**:

```
Is the spec clearly written with unambiguous acceptance criteria?
├── No → Rewrite the spec. Send back to Groomer.
└── Yes
    Is the task too large to implement cleanly in one cycle?
    ├── Yes → Split the task. Create F-001a and F-001b. Abandon F-001.
    └── No
        Is the Reviewer applying criteria not in the spec?
        ├── Yes → Override: tell the Reviewer which criteria are out of scope.
        └── No → Reduce scope. Remove the contentious acceptance criteria. Defer to a follow-up task.
```

**Resolution steps**:
1. Read the Reviewer's last `review_report.md` in `.crucible/session/{task_id}/reviewer/`.
2. Identify the specific failure reason (a concrete file, a specific test, a mandate violation).
3. Choose: split, reduce scope, or rewrite spec.
4. If splitting: create new spec files, update BACKLOG.md, abandon this task.
5. If reducing scope: edit the spec file's acceptance criteria, un-check only what you are deferring.
6. Follow re-entry procedure above.

---

## Breaker 2 - DEGRADED Signals

**Trigger**: The factory logs a `degraded` event because the pipeline continued with reduced assurance.

**How to identify it**: Inspect the event's `kind` and `outcome` in the pipeline log. `kind` names which check spoke. `outcome: "unverifiable"` means that check could not run; do not treat the absence of a finding as a pass.

| Kind | Outcome | Operator response |
|---|---|---|
| `review_strike_2` | `warned` | No immediate human decision is needed. Watch the next Architect session. It should remove the most contentious part, defer it to a follow-up task, or submit a smaller change for review. If it re-implements the same contentious code, intervene before the third strike fires. |
| `file_affinity_unverifiable` | `unverifiable` | The task was not scope-checked because the spec had no affected-files section. The human is the only remaining scope check: compare the change set against the intended task before allowing deployment. |
| `file_affinity_scope` | `warned` | The scope gate ran and found handoff paths the spec did not mention. Confirm whether the spec should expand or the out-of-scope changes should be removed. |
| `task_checklist` | `warned` | Review `task.md` checklist formatting and optional items before the next handoff. |
| `session_cycle_id_mismatch` | `warned` | Confirm the active specialist read the current `task.md` before continuing. |
| `review_report_format` | `warned` | Ask the Reviewer to use the structured review report format on the next pass. |
| `unknown` | `warned` | Legacy archived event without `kind`; use the event notes and surrounding log context. It is not an unverifiable gate. |

Duplicate handoffs are not DEGRADED. They are reported by `analyze-evals.ps1` under handoff quality.

---

## Breaker 3 — Handoff Retry Limit

**Trigger**: A specialist has handed off to themselves more than twice (same role as both source and target in consecutive handoffs).

**What it means**: A specialist is stuck in a self-loop. This usually means the task is ill-defined, the agent is confused about what "done" means, or the SOP is being misread.

**Decision tree**:

```
Is the task spec clear?
├── No → Rewrite. Send to Groomer.
└── Yes
    Did the specialist misunderstand their role?
    ├── Yes → Re-dispatch with an explicit correction prompt.
    └── No → The task may be blocked on an external dependency.
        Is there a dependency that needs to resolve first?
        ├── Yes → Block this task, work the dependency.
        └── No → Reduce scope or abandon.
```

**Resolution steps**:
1. Read the specialist's `task.md` to understand what they were attempting.
2. If the spec is the issue, send back to Groomer with a note: "Spec is ambiguous on X. Please clarify."
3. If the agent was confused, re-dispatch the same specialist with a short correction prompt pointing to the specific SOP step they missed.

---

## Breaker 4 — Token Budget Exceeded

<!-- crucible:generated budget-tier-ceilings-inline -->
**Trigger**: `cumulative_handoff_count` exceeds the tier ceiling (Low=10, Medium=16, High=28, Extended=40).
<!-- crucible:end budget-tier-ceilings-inline -->

**What it means**: The task consumed more pipeline cycles than estimated. This is not necessarily a failure — complex tasks legitimately need more cycles — but it requires explicit human approval to continue.

**Decision tree**:

```
Is the remaining work clearly defined and bounded?
├── No → Reduce scope. Close with what's done. Defer the rest.
└── Yes
    Is the remaining work worth the additional cost?
    ├── No → Abandon or reduce scope.
    └── Yes → Approve a tier escalation.
        Current tier is Low?      → Escalate to Medium.
        Current tier is Medium?   → Escalate to High.
        Current tier is High?     → Escalate to Extended.
        Current tier is Extended? → Split the task or abandon.
```

**Resolution steps**:
1. Read the blocked record's `summary` — what has been done vs. what remains.
2. Make one of three decisions:
   - **Escalate**: Edit the spec frontmatter: `budget_tier: medium` (or `high`). This requires your explicit approval.
   - **Reduce scope**: Edit acceptance criteria to remove unfinished items. Defer to a new task.
   - **Abandon**: Mark the task `Abandoned` in BACKLOG.md. Create a new, smaller task from what remains.
3. The agent MUST NOT auto-escalate or silently adjust the tier. If it did, that is a policy violation — treat the handoff as invalid and re-dispatch the specialist.

---

## Breaker 5 — Reviewer Verification Failure

**Trigger**: The Reviewer self-reported APPROVED, but `factory.ps1` independently re-ran the project's test suite and it failed.

**What it means**: The Reviewer's checklist was not executed correctly — they marked tests as passing without actually running them, or ran the wrong test command.

**Decision tree**:

```
Did the Reviewer run the correct verification commands?
├── No → Re-dispatch Reviewer with explicit instructions to run .crucible/config.yaml verification.full commands.
└── Yes
    Did the Architect's code actually pass tests before handoff?
    ├── No → Route back to Architect. The failure is in the implementation.
    └── Yes (tests pass in worktree, fail in factory run) → Environment issue.
        → Run factory.ps1 -Health to check worktree state.
        → Verify worktree is at the correct commit.
```

**Resolution steps**:
1. Check `.crucible/session/{task_id}/reviewer/review_report.md` — does it list specific test results?
2. If the Reviewer skipped tests: re-dispatch with "Re-run your verification checklist. Step 1 is running tests; show me the actual output."
3. If the Architect's code has a real failure: route to Architect with the specific failing test name and output.
4. Increment `review_strike_count` when re-dispatching the Architect.

---

## Breaker 6 — Fabricated Artifacts

**Trigger**: A path listed in the handoff's `artifacts` array does not exist or is empty.

**What it means**: The agent listed files it did not actually create or modify. This is a reliability signal — the agent is over-reporting its work.

**Decision tree**:

```
Were the files supposed to be created?
├── Yes → The Architect failed to produce required output. Re-dispatch Architect.
└── No → The Architect listed the wrong files. Correct the handoff and re-run factory.
```

**Resolution steps**:
1. List what actually exists in the worktree: `git -C .crucible/.agent-workspaces/implementation-{task_id} status`
2. Compare against the spec's acceptance criteria.
3. If work is genuinely missing: re-dispatch the Architect with "Your handoff lists {file} as an artifact but it does not exist. Create it."
4. If the handoff just listed the wrong path: have the agent correct the handoff JSON and re-run `factory.ps1 -Init -TaskId {task_id}`.

---

## Breaker 7 — Recurring Merge Conflicts

**Trigger**: `rebase_count` reaches 3 on the same task.

**What it means**: The task's branch and `master` have diverged repeatedly. Another task is making conflicting changes to the same files, or the task has been in-flight so long that `master` has moved significantly.

**Decision tree**:

```
Is another task actively modifying the same files?
├── Yes → Serialize. Finish the other task first, then resume this one.
└── No
    Has master changed significantly since this task started?
    ├── Yes → Consider abandoning and re-grooming on top of current master.
    └── No → The conflict is a merge strategy issue.
        → Have the Architect do a clean rebase and resolve conflicts manually.
```

**Resolution steps**:
1. Check `git log --oneline master..task/{task_id}` to see how far behind the branch is.
2. Check `git log --oneline task/{task_id}..master` to see what master added.
3. If the conflict is small: re-dispatch Architect with "Rebase against current master and resolve conflicts. This is attempt {n}; be precise."
4. If the conflict is large: abandon this task, create a new version of the spec on current master, re-groom.
5. If a concurrent task caused the conflict: check `file_affinity` overlap and enforce serialization.

---

## Breaker 8 — Git Hook Bypass Attempt

**Trigger**: The handoff text reports `--no-verify`, an equivalent hook bypass, or `CRUCIBLE_BYPASS_LINUX_LEG`.

**What it means**: This is a security violation, not a normal operational block. Pre-commit hooks enforce code quality and prevent bad commits from reaching the pipeline.

The breaker reads the handoff text only. It deliberately does not key off any on-disk bypass record: nothing in the pipeline clears such a file, so a single bypass would wedge every later task in the repo. If you are chasing an unexplained `git_hook_bypass`, the cause is in the handoff, not in `.private/`.

**Action**: Do not re-dispatch the specialist automatically. Review:
1. Why the agent used `--no-verify`.
2. What the hook failure was.
3. Whether the hook failure is legitimate (hook broken) or the agent was cutting corners.

If the hook is broken: fix the hook, then re-dispatch.
If the agent was cutting corners: re-dispatch with an explicit instruction: "You are not permitted to use --no-verify. Fix the underlying hook failure."

**Linux leg bypass** (framework repo only): `CRUCIBLE_BYPASS_LINUX_LEG` skips the pre-push Linux verification gate and drops a record at `.private/linux-leg-bypass.json`. That record is evidence for the human, not a gate input; a successful `scripts/test-linux.ps1` run clears it. Treat a handoff that mentions the variable the same way as `--no-verify`: find out why the Linux leg could not run, then require a real run before the work lands.

---

## Breaker 9 — Scope Boundary Violation

**Trigger**: The Architect modified files outside the `file_affinity` boundary declared in the spec.

**What it means**: The Architect exceeded the declared scope. This is a risk because: (1) the Reviewer was only checking the in-scope files, and (2) out-of-scope changes may conflict with parallel tasks.

**Decision tree**:

```
Were the out-of-scope changes necessary for the task?
├── Yes → The spec's file_affinity is wrong. Send back to Groomer to broaden scope.
└── No → The Architect over-implemented. Revert the out-of-scope changes.
    Are the out-of-scope changes useful and safe?
    ├── Yes → Create a separate task for them. Revert from this task.
    └── No → Revert and re-dispatch Architect.
```

**Resolution steps**:
1. Identify out-of-scope files: compare `git diff` in the worktree against the spec's `file_affinity`.
2. If scope needs expanding: send back to Groomer with "file_affinity needs to include {files}."
3. If reverting: have the Architect `git checkout {file}` in the worktree, re-run tests, re-submit.

---

## Breaker 10 — Operator Threshold

**Trigger**: Researcher feedback was triggered for a P1/P2/P3 issue (not P0 or a batch of 5+).

**What it means**: The factory prevents low-signal research triggers from clogging the pipeline. A P2 bug report from the Operator does not automatically kick off a Researcher session.

**Action**: This is informational. The Operator logged the issue but did not route to Researcher. Review the Operator's report:
- If it's genuinely P0 (crash/data loss): override and route to Researcher manually.
- Otherwise: add it to the backlog as a new item with appropriate priority. Let it enter the pipeline normally.

---

## Breaker 11 — Auto-Kickoff Scan Limit

**Trigger**: Factory scanned 5 backlog items and found no item in `Ready` status eligible for the next pipeline step.

**What it means**: The backlog has stalled — everything is blocked, in-flight, or in a status that can't advance automatically.

**Action**:
1. Run `factory.ps1 -Health` to see what's in-flight and what's blocked.
2. Check `BACKLOG.md` for items that are `Blocked`, `In Progress`, or `Ready for Deploy` but haven't moved.
3. Manually identify the next item to work and tell the agent: "Work F-007" (explicit task ID).

---

## Breaker 12 - Unreadable Retry History

**Trigger**: A gate scanned the pipeline log to decide whether the current failure is a repeat, and one or more log lines would not parse as JSON. The gate could not rule out a prior failure, so it stopped instead of treating this as a first offence.

**What it means**: This breaker makes no claim that the task did anything wrong. It reports that the evidence needed to make the repeat-or-first decision is unreadable. The two scans that raise it are the artifact-integrity check and the independent-verification check; the blocked record names which one and how many lines were skipped. A matching `degraded` event with `kind: unreadable_retry_history` is written whenever a scan skips a line, whether or not it blocks.

**Decision tree**:

```
Is the malformed line explicable - a crash mid-write, a disk-full, a manual edit?
├── Yes → Repair or archive the log, then recover. The task itself is unaffected.
└── No → Treat the log as tampered. A planted malformed line is the documented way
         to suppress this gate. Inspect who wrote it before recovering.
```

**Resolution steps**:
1. Open the pipeline log and find the lines that do not parse. Each is a single JSON object per line; a truncated or concatenated line is the usual shape.
2. Decide whether the corruption is accidental or deliberate. Writers serialize through `Invoke-FileLock`, so ordinary operation should not tear a line.
3. Repair the malformed lines, or move them to an archive file so the scan reads a clean log. Do not delete history you have not read.
4. Run `factory.ps1 -Init -TaskId {task_id} -Recover`.
5. If the scan now finds a genuine prior retry, the underlying breaker fires and you handle that one instead. That is the intended outcome, not a second failure.

---

## Breaker 13 - Unverifiable Handoff Count

**Trigger**: The server-side handoff count is derived by counting `session_end` events for the task in the pipeline log, because an agent-reported `cumulative_handoff_count` cannot be trusted to guard its own budget. Some log lines would not parse. The counted handoffs are under the tier ceiling, but by fewer than the number of unreadable lines - so the count cannot establish that the ceiling was not crossed.

**What it means**: Not that the budget was exceeded, and not that the task misbehaved. Each unreadable line may or may not be a `session_end` this count never saw. The gate stops rather than passing a ceiling check its own evidence does not support. A `degraded` event with `kind: unreadable_handoff_history` and `outcome: unverifiable` is written on every run where any line is skipped, including runs far below the ceiling where nothing blocks.

**Decision tree**:

```
Do the counted handoffs alone already exceed the ceiling?
└── No, or this breaker would be Breaker 4 instead.

Is the corruption explicable - a crash mid-write, disk full, a hand edit?
├── Yes → Repair or archive the log so the count can be recomputed, then recover.
└── No → Suppressing a session_end is the direct way to buy handoffs past the
         ceiling. Establish who wrote the line before granting the task more room.
```

**Resolution steps**:
1. Read the pipeline log and locate the lines that do not parse. One JSON object per line; truncated or concatenated lines are the usual shape.
2. If the lines are recoverable, repair them so their `session_end` events are counted. The honest resolution is to recompute the count, not to raise the ceiling.
3. If they are not recoverable, move them to an archive file and decide the count deliberately. Record that decision - the next run will not know you made it.
4. Run `factory.ps1 -Init -TaskId {task_id} -Recover`.
5. If the repaired count now exceeds the ceiling, Breaker 4 fires. That is the correct outcome, not a new problem.

---

## Quick reference

| Breaker | Trigger | Your decision |
|---------|---------|---------------|
| Review Stalemate | 3 Architect failures | Split task, reduce scope, or rewrite spec |
| DEGRADED Signal | Pipeline continued with reduced assurance | Inspect `kind`; for `file_affinity_unverifiable`, manually scope-check the task; for `review_strike_2`, watch next Architect session |
| Handoff Retry | Self-loop >2× | Clarify spec or re-dispatch with correction |
| Token Budget | Handoff ceiling hit | Escalate tier, reduce scope, or abandon |
| Reviewer Verification Failure | Factory re-ran tests, they failed | Fix Reviewer execution or re-route to Architect |
| Fabricated Artifacts | Listed file doesn't exist | Re-dispatch Architect to produce missing output |
| Recurring Merge Conflicts | 3+ rebases | Serialize tasks or re-groom on current master |
| Hook Bypass | `--no-verify` used | Fix the hook; never allow bypass |
| Scope Violation | Modified out-of-scope files | Expand spec or revert out-of-scope changes |
| Operator Threshold | Low-priority feedback | Log as backlog item; don't auto-trigger Researcher |
| Scan Limit | No Ready items found | Check health; give explicit next task ID |
| Unreadable Retry History | Pipeline log lines would not parse, so repeat-or-first could not be decided | Repair or archive the malformed lines, then recover; if the corruption is unexplained, treat it as tampering |
| Unverifiable Handoff Count | Unreadable log lines could hide enough `session_end` events to cross the tier ceiling | Repair the log and recompute the count; do not raise the ceiling to clear it |
