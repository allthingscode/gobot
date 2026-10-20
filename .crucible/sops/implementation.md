<!-- prompt_version: architect-sop-v6 -->
# SOP: Implementation

**Platform note:** Commands use `pwsh` (PowerShell 7+). Windows PowerShell 5.1 is not supported.

**Role:** Design and implement backlog items in an isolated worktree. Always hand off to Verification - never to any other phase.

**Trigger form:** `Implementation: {task_id}`

---

## Inputs Required

| Input | Source |
|---|---|
| Task context | `.crucible/session/{task_id}/implementation/task.md` |
| Incoming handoff | `.crucible/session/handoffs/{task_id}-*.json` |
| Backlog spec | `{{backlog_dir}}/{type}/active/{task_id}_*.md` |
| Worktree | `.crucible/.agent-workspaces/implementation-{task_id}/` (created by crucible.ps1) |
| Review fix spec (if from Verification) | `.crucible/session/{task_id}/verification/review_report.md` and `task.md` |

---

## Session Start

Read `.crucible/session/{task_id}/implementation/task.md` for resolved paths and instructions, the incoming handoff, and `{{crucible_root}}/docs/operating-manual.md`. If `task.md` does not exist, run `crucible.ps1 -Init -TaskId {task_id} -ProjectRoot "{project_root}" -Quiet` first.

Before doing anything, run `{{crucible_root}}/powershell/clear-session-state.ps1 implementation -ProjectRoot "{project_root}"` to clear stale state safely. Do not edit `session_state.json` manually.

For state updates, use `update-session-state.ps1 -Specialist implementation -TaskId {task_id} -UpdateJsonFile temp.json -Merge`. Implementation session files go to `.crucible/session/{task_id}/implementation/`.

**This dispatch is your approval to implement.** The groomed spec is the approved plan. A project instruction to pause for plan approval (for example an AGENTS.md planning protocol) belongs to the manual workflow and does not apply here: write any Phase 1 design to `task.md`, then implement, commit and hand off in this session. Stop early only to escalate a genuine blocker, as [Escalating a Blocker](#escalating-a-blocker) describes.

**Check for pre-written fix spec first:** If `task.md` exists and describes code review fixes from a verification handoff - follow it directly. Do NOT redesign. Skip to Phase 2: Code.

The backlog spec's pre-filled "Next Step" line is for post-deployment sequencing, not routing. Follow this SOP's Verification handoff.

Before proceeding, echo the Cycle ID from `task.md`, the incoming handoff reason, the permitted successor from this SOP, and the worktree path from `task.md`'s Resolved Paths. If any answer is missing, stop and re-read the files.

---

## Decision Tree (For New Features/Bugs - Not Review Fixes)

Read the backlog item spec, then:

1. **Is it <20 lines AND straightforward?** (e.g., add log field, fix typo, rename variable)
   - YES -> Skip Phase 1, go directly to Phase 2: Code
   - NO -> Continue

2. **Is the spec completely clear AND the change isolated AND <50 lines?**
   - YES -> Go directly to Phase 2: Code
   - NO or >50 lines -> Complete Phase 1 first

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

**Step 0 - Navigate to worktree (mandatory before any edits):**
```bash
cd .crucible/.agent-workspaces/implementation-{task_id}
git status  # must show: On branch task/{task_id}
```
If the worktree does not exist or the branch is wrong, STOP and run `crucible.ps1 -Init -TaskId {task_id} -ProjectRoot "{project_root}"` before proceeding.

Perform ALL edits inside the isolated worktree at `.crucible/.agent-workspaces/implementation-{task_id}/`.

**If `task.md` exists from Verification**: Read `review_report.md` and follow the fix specifications directly. Do NOT redesign.

Follow all project mandates:
- Follow project language/runtime mandates from `.crucible/config.yaml`; do not introduce panics or unsafe shortcuts unless explicitly allowed.
- If you add or modify dependencies (e.g. adding imports in Go, Node, Python, Rust), you MUST run the language-specific package tidy/lock step (e.g. `go mod tidy`, `npm install`, `poetry lock`) in the worktree so the lockfile/manifest stays current and tidy.
- Wrap errors: `fmt.Errorf("context: %w", err)`
- Structured logging: `log/slog` with attributes
- Durable by default: SQLite
- Zero-trust: validate at system boundaries

### Mid-Session Progress (Checkpointing)
Specialists MUST log their progress mid-session to ensure state recovery in case of failure.
- **Mandate**: Write `### CHECKPOINT [Brief Summary]` to `task.md` after completing a major sub-task or phase (e.g., "Phase 1 Design Complete").
- **Example**: `### CHECKPOINT Phase 2: Logic implementation complete`

Write table-driven tests as you go - not after. Run continuously:
```powershell
pwsh -ExecutionPolicy Bypass -File {{crucible_root}}/powershell/run-isolated-checks.ps1 -TaskId {task_id} -Mode quick -ProjectRoot "{project_root}"
```

**STRICTLY FORBIDDEN**: `git push`. Do not commit to `master`. Do not touch `BACKLOG.md`.

### Escalating a Blocker

Escalate only when the approved spec cannot be met as written: a needed change falls outside `file_affinity`, the spec contradicts the code or itself, or a decision belongs to the human. Do not escalate for something you can resolve inside the spec.

1. Leave your work uncommitted in the worktree. Do not commit failing or out-of-scope work, and do not stash or discard it.
2. Write `### ESCALATION` to `task.md` with the blocker, the evidence (file and line, failing test output), the exact decision you need, and your recommendation.
3. Do not write a handoff or run `crucible.ps1 -Init`. End the session with the question as your final message.

The orchestrator brings the question to the human and records the answer under `### ESCALATION` as `Decision:` (and in the spec when it changes scope). It then re-dispatches this phase on the same worktree; the launcher recognises the work you left and lets the new session continue it. On a re-dispatch, read the `Decision:` line first and carry on from your last checkpoint.
### Phase 3: Self-Review

Before marking ready for Verification:

1. Run full verification:
   ```powershell
   pwsh -ExecutionPolicy Bypass -File {{crucible_root}}/powershell/run-isolated-checks.ps1 -TaskId {task_id} -Mode full -ProjectRoot "{project_root}"
   <project race/coverage test command>
   ```
   Run task-specific required validation. In the framework repo, when prompt templates change, also run `go run {{crucible_root}}/scripts/crucible_lint.go -framework-root {{crucible_root}} -backlog-dir <path>`. Resolve `<path>` with `{{crucible_root}}/powershell/resolve-config-path.ps1 -Key backlog -ProjectRoot "{project_root}"`. This linter checks Crucible's own backlog and docs and is not part of a bundle.
2. Coverage >80% for new code? If not, add tests.
3. Commit inside the worktree with a message in the style of this repo's recent commits (read `git log -5` first): a subject that names the change and a body that says why.
   ```bash
   git add .
   git commit -m "<subject naming the change>" -m "<body saying why>"
   ```
4. Review your own diff - would you approve this in a PR?
5. Write completion summary to `.crucible/session/{task_id}/implementation/output.md`
6. Map every acceptance criterion from the backlog spec to concrete changed file paths, tests and verification evidence.
7. Confirm every changed file is inside the declared `file_affinity` boundary.

**Note on trivial changes**: Even for <20-line changes, you MUST route to Verification. `implementation -> deployment` is not a valid pipeline transition - crucible.ps1 will hard-block it. For truly trivial changes the Verification session will simply be fast.

### Phase 4: Handoff to Verification

1. Ensure `task.md` contains:
   - Implementation plan (what was designed)
   - Files modified
   - Test coverage percentage
   - Any deviations from the original plan
2. Write deployment plan to `.crucible/session/{task_id}/implementation/deployment_plan.md`:
   - Files committed
   - Commit message (subject and body, as committed)
   - Ordered deployment steps
3. Run `new-handoff.ps1` to write the handoff JSON (do NOT hand-author or hand-edit the handoff JSON file directly):
```bash
pwsh -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source implementation -Target verification -Reason "Implementation complete - ready for review" -ProjectRoot "{project_root}"
```
(The tool automatically sets `generated_by` and `tool_version` to satisfy preflight verification.)
4. Run Crucible and present output to human:
```bash
pwsh -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/crucible.ps1" -Init -TaskId {task_id} -ProjectRoot "{project_root}" -Quiet
```
5. Present a 2-3 sentence summary and the exact verbatim `[NEXT SESSION COMMAND]` block from the Crucible output in a code block. Do not fabricate, paraphrase or shorten the command. Include the `-Quiet` flag if present. You run Crucible via the shell tool; do not ask the human to run it.
6. Stop and wait for human confirmation. Do not begin another backlog item or adopt the next phase persona.

---

## Quality Bar

Before writing handoff.json, confirm:
- [ ] Routing to: `verification` (always - `implementation -> deployment` is not a valid transition and will be hard-blocked by crucible.ps1)
- [ ] All edits are inside the worktree - nothing committed to `master`
- [ ] NOT pushed to origin
- [ ] `BACKLOG.md` not edited (that's the Reviewer/Operator's job)
- [ ] `session_cycle_id` included in handoff
- [ ] `task_id` in handoff matches the task I was given
- [ ] Every required `## Task List` item in `task.md` is `[x]`, or `[-]` if genuinely skipped, or moved under `## Optional Steps` - a `[ ]` or `[/]` item left in that section fails the gate and exits the run with code 2
