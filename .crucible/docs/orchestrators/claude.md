# Claude Code Strategic Orchestrator Protocol

This document defines **Claude Code-specific** mechanics for Crucible pipeline orchestration. Read `.crucible/docs/orchestrator.md` and `.crucible/sops/orchestrator.md` first - the persona establishes who you are, the SOP defines the loop and gate protocols. This document covers only how to invoke sub-agents and run Crucible commands in the Claude Code environment.

> **Cross-platform.** The `powershell.exe` invocations below are the Windows form. On Linux/macOS, use `pwsh` (PowerShell 7+) in their place.

## The "Orchestrate" Directive

When the human says `"Orchestrate {TASK_ID}"` or `"Orchestrate the next task in the backlog"`, this Claude Code session adopts the **Strategic Orchestrator** persona. The current session is the controller. It does not become Groomer, Architect, Reviewer, Operator, or Researcher.

---

## Sub-Agent Invocation

Claude Code's `Agent` tool is the sub-agent mechanism. Most specialists are dispatched as `general-purpose` sub-agents. The Researcher uses `Explore` (read-only search tools, enforces the trust boundary at the toolset level). Sub-agents share the same working directory and git state - they are not sandboxed. Do not pass orchestrator session history to sub-agents. Because of that shared state, run `git status` before every dispatch and confirm the tree matches expectation; never build on, or commit alongside, uncommitted changes you did not author -- establish their provenance first (see `sops/orchestrator.md` Step 4).

### Default Specialist Target: Codex

In this operating configuration, **Claude is the orchestrator and Codex runs all specialist work** (Groomer, Architect, Reviewer, Operator, Researcher). Default every dispatch to a Codex specialist via `launch-codex-specialist.ps1` (see *Dispatching a Codex Specialist*), resolving the model/effort with `crucible.ps1 -Init -Target codex`. Fall back to a Claude `Agent` sub-agent only when a Codex preflight fails or the human asks for Claude on a specific phase. The orchestrator itself stays Claude - it never becomes a specialist.

### Specialist Model Selection

Do **not** hard-code a per-role model. Crucible computes the model from the activity
(`target_phase`, `budget_tier`, `design_required`) and prints a `[RECOMMENDED MODEL] <x>`
line next to the dispatch command after each `crucible.ps1 -Init`. Dispatch the sub-agent
with that model. The canonical policy and the default/escalation table live in
[`docs/policy.md`](../policy.md) section 2.3.

Quick reference: Sonnet is the default; Opus is reserved for Research (always), design-heavy
or `high`/`extended`-tier Architect work (`design_required`), and `high`/`extended`-tier
Grooming/Review; the Operator now runs at the high-capability tier (raised from `fast`, since deployment mutates BACKLOG.md, merges, and gates and must not use the lightest model); the orchestrator itself runs on Sonnet.

### Standard Specialist Dispatch (Groomer, Architect, Reviewer, Operator)

```
Agent({
  subagent_type: "general-purpose",
  model: "{model from the [RECOMMENDED MODEL] line Crucible printed}",
  description: "{Phase} session for {task_id}",
  prompt: `{Role}: {task_id} - read and follow all instructions in
.crucible/session/{task_id}/{phase}/prompt.md

Follow your SOP checkpoint mandate: append \`### CHECKPOINT [brief summary]\`
to task.md after each major phase. Do not write the final handoff until all
required task checklist items are complete.

After writing handoff JSON, run:
  powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/crucible.ps1" -Init -TaskId {task_id} -Quiet

Report the Crucible output verbatim. Stop after reporting. Do not spawn successor agents.`
})
```

### Dispatching a Codex Specialist (non-Claude)

Crucible is a multi-brand pipeline: a phase can be run by a Codex specialist instead of a Claude
sub-agent. When the dispatch target is Codex, do **not** use the `Agent` tool and do **not** use the
codex plugin's `codex-rescue` / `task` runtime (it hardcodes a read-only sandbox and, on Windows,
fails through a missing sandbox helper - producing a false `CHANGES_REQUESTED`). Use the
Crucible-blessed launcher, which wraps `codex exec -s danger-full-access` and reports an explicit
launch status.

1. Compute the Codex model. Run `crucible.ps1 -Init` with `-Target codex` so the `[RECOMMENDED MODEL]`
   line resolves to the configured Codex model (e.g. `gpt-5.5`):

   ```bash
   powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/crucible.ps1" -Init -TaskId {task_id} -Target codex -Quiet
   ```

2. **Preflight once** (cheap runtime smoke). This catches a broken Codex runtime/auth BEFORE the phase
   runs, so a dead runtime can never masquerade as a verdict:

   ```bash
   powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/launch-codex-specialist.ps1" -Preflight -Model {model}
   ```

   Proceed only on `[CODEX PREFLIGHT] PASS`. On FAIL, fix the runtime (`codex login`, sandbox helper)
   or fall back to a Claude specialist - do not dispatch.

3. Launch the specialist for the phase:

   ```bash
   powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/launch-codex-specialist.ps1" \
     -TaskId {task_id} -Phase {phase} -Model {model} -Effort {effort}
   ```

   Add `-WorkingDir {worktree}` for implementation/verification phases that operate in a task worktree,
   and `-ReviewSchema` for a verification phase to enforce a structured review verdict.

   **Pass the recommended effort.** Alongside `[RECOMMENDED MODEL]`, Crucible prints a
   `[RECOMMENDED EFFORT] <none|minimal|low|medium|high|xhigh>` line for a Codex target (it is the
   capability tier mapped to a Codex reasoning effort: strong/light -> `high`, default -> `medium`).
   Pass that value as `-Effort`; the launcher forwards it as `-c model_reasoning_effort`. Effort is a
   Codex-only lever -- Claude's `Agent` dispatch has no effort knob (its effort is encoded in the model
   tier), so no effort line is printed for a Claude target.

   **Keep the dispatch prompt a one-line file pointer.** The launcher auto-generates the specialist
   prompt: a single "read and follow `.crucible/session/{task_id}/{phase}/prompt.md`" instruction plus
   the standard contract. **Rule: an external specialist ALWAYS gets a handoff/instruction file plus a
   simple prompt that says to read and follow it.** A multi-line prompt carrying quotes, percent
   signs, or newlines is shattered into separate argv tokens by PowerShell native-argument quoting and
   codex rejects it (`error: unexpected argument ...`) - use `-PromptFile <path>` for non-trivial prompt
   overrides to keep the harness call clean and the prompt contents in a file.

   For a **normal phase**, that file is the auto-generated `prompt.md` (neither `-PromptText` nor `-PromptFile` needed). For a
   **human gate continuation** (notably the **Research Gate**), do NOT append the decision to `prompt.md`
   - the phase SOP's present-and-wait step wins and the run re-presents with zero deliverables. Instead
   generate a dedicated continuation file and pass a pointer to it via `-PromptFile <path to gate-filing.md>`. For the Research Gate use
   `record-research-gate.ps1`:

   ```bash
   powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/record-research-gate.ps1" \
     -TaskId {task_id} -Reason "<gate reason>" -Approved "C-350","C-351" [-Deferred ...] [-Rejected ...]
   ```

   It records the decision and writes `session/{task_id}/research/gate-filing.md`, then prints the
   dispatch pointer. Re-dispatch with `-PromptFile <path to gate-filing.md>` (or a trivial one-line `-PromptText`). The specialist
   then files the approved stubs and hands off without re-auditing.

   For work that is **not a backlog task at all** - Crucible's own `TODO.md` items, or any one-off
   with no task ID - omit `-TaskId` and `-Phase` entirely and pass only `-PromptFile`. On that path
   they select no content anyway (the auto-generated prompt is skipped), so the launcher names the
   session after the prompt file instead: `.crucible/session/adhoc/{prompt-file-basename}/`, where
   the transcript and last message land. Do **not** invent a task ID to satisfy the arguments - a
   fake ID names a directory the backlog knows nothing about, and `crucible-health` reads a
   top-level `session/{F|B|C}-{n}/` directory as a real task session and will archive it. Passing
   only one of `-TaskId`/`-Phase` is rejected; pass both or neither.

   > **Anti-pattern (dogfooding integrity): do NOT hand-hold a normal phase with a bespoke prompt.**
   > It is tempting to write a detailed `-PromptFile` that restates the spec, dictates the exact
   > `new-handoff.ps1` invocation, pre-bakes the commit message, or re-lists the scope. Don't. For any
   > normal phase the auto-generated `prompt.md` **is the contract under test** - it already carries the
   > readiness echo, SOP, checklist, scope boundary, and handoff mechanics. Substituting your own
   > instructions **masks defects in `prompt.md`/the SOPs**: if the generated prompt were incomplete,
   > your scaffolding would paper over it, and the run would prove only "Crucible + heavy orchestrator
   > hand-holding works," never "Crucible works." That is the opposite of what a dogfooding session
   > must establish. A phase that stumbles on the bare `prompt.md` is a **finding to file, not a gap to
   > pre-patch**. Reserve `-PromptFile`/`-PromptText` for exactly three cases: (a) an argv-hostile prompt
   > the harness cannot pass cleanly, (b) a human-gate continuation (e.g. the Research Gate's
   > `gate-filing.md`), and (c) a dispatch with no backlog task behind it, such as a Crucible `TODO.md`
   > item (see the ad-hoc form above). Everything the specialist needs for a normal phase belongs in the
   > spec and the handoff - authored by the upstream phase - not in the dispatch call.

4. **Trust the status, not the label.** The launcher prints `[CODEX SPECIALIST] STATUS=SUCCESS` or
   `STATUS=LAUNCH_FAILED`. A verdict is only valid when `STATUS=SUCCESS` **and** the handoff +
   `### CHECKPOINT` checks below pass. `STATUS=LAUNCH_FAILED` is an infrastructure failure - re-run the
   preflight, fix the runtime, and re-dispatch; never record it as `CHANGES_REQUESTED`.

Everything after the launch (gate signal, `task.md` checkpoints, handoff glob, `crucible.ps1 -Init`) is
identical to a Claude specialist - see *After Each Sub-Agent Returns*.

### Researcher Dispatch

Use `Explore` (not `general-purpose`) to enforce read-only tool access and the trust boundary at the toolset level.

```
Agent({
  subagent_type: "Explore",
  model: "opus",
  description: "Research session for {task_id}",
  prompt: `Researcher: {task_id} - read and follow all instructions in
.crucible/session/{task_id}/research/prompt.md

Follow your SOP checkpoint mandate: append \`### CHECKPOINT [brief summary]\`
to task.md after each major phase. Do not write the final handoff until all
required task checklist items are complete.

After writing handoff JSON, run:
  powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/crucible.ps1" -Init -TaskId {task_id} -Quiet

Report the Crucible output verbatim. Stop after reporting. Do not spawn successor agents.`
})
```

### Bootstrap: Groomer Selects Next Item

When no task ID is known (human said "Orchestrate the next task in the backlog"):

```
Agent({
  subagent_type: "general-purpose",
  description: "Groomer bootstrap - select next backlog item",
  prompt: `Groomer: Next Item

Read AGENTS.md, <crucible_root>/docs/operating-manual.md, <crucible_root>/personas/groomer.md, and
.crucible/sops/grooming.md. Select the next eligible backlog item. Once you have
selected a task ID, create your scratchpad at
.crucible/session/<selected_task_id>/grooming/task.md (create the directory if
needed) and use it for all ### CHECKPOINT entries throughout your session.

Write or update the item's spec, write the grooming -> implementation handoff, then run:

  powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/crucible.ps1" -Init -TaskId <selected_task_id> -Quiet

Do not write the handoff until required checklist items are complete. Stop after
Crucible output is produced. Report the selected task ID and Crucible output verbatim.`
})
```

Wait for the sub-agent to return. Read the reported task ID. Ask the human for confirmation before dispatching the Architect.

---

## Picking Up a Backlog Item

A backlog item is a claim someone made earlier, not a fact. Before any work starts on
one:

1. **Re-validate the premise.** Confirm the defect still exists, by running it. A file
   the item names may have been deleted or split; the code it describes may be
   unreachable; the numbers it quotes may be stale. An item written against code that
   has since changed can be entirely false while still reading as urgent.
2. **Re-decide the solution.** The fix the item proposes was chosen against the old
   state of the tree and without a survey. Check it against how the problem is normally
   solved before building it, and prefer the established pattern to a local invention.
3. **Say so when the item is wrong.** If the premise does not hold, stop and report
   rather than silently redefining the work. Whether to delete the item, narrow it, or
   replace it is the human's call.

Both halves have been wrong in practice. Item 28 was filed against a code path that
turned out to be unreachable, and closed as a deletion rather than the refactor it
asked for. Item 27's first design measured the wrong thing and used an unevidenced
threshold; measurement moved it.

---

## Running Crucible Commands

Crucible commands run via Bash tool using the PowerShell invocation:

```bash
powershell.exe -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/crucible.ps1" -Init -TaskId {task_id} -Quiet
```

The orchestrator runs `crucible.ps1 -Init` at two points per specialist cycle:
1. **Before dispatch** - to verify the previous handoff and assemble the next prompt
2. **After sub-agent returns** - to advance the pipeline and detect gates

---

## After Each Sub-Agent Returns

Follow `.crucible/sops/orchestrator.md` **Step 5** (verify specialist output and track budget), then **Step 6** (run Crucible and check for gates). A gate signal at `.crucible/session/{task_id}/gate_pending.txt` goes straight to the Gate Protocol before anything else.

Step 5 carries checks worth knowing are there before you reach it: verdict-not-label and provenance for a non-Claude specialist, the `task.md` checkpoint and checklist checks, the handoff check, and the **budget ladder** that warns, then escalates and waits, then presents the ceiling as a Circuit Breaker Gate. Read its thresholds from the SOP; they are not repeated here, so they cannot go stale here.

None of that is Claude-specific, so it lives in the SOP alone. This section used to restate it as a four-item block, and the copy had already drifted: it dropped the budget check, so an orchestrator following this document never warned the human on spend and met the ceiling as an unexplained `crucible.ps1` block. Point at Step 5 here; do not re-inline it.

---

## Human Confirmation Model

Before every specialist dispatch, present the status report format defined in `.crucible/sops/orchestrator.md` Step 3 - not a one-liner. The human is the Pilot in Command; every dispatch is their decision. Include the budget tracking line so they can see spend at a glance.

Do not dispatch until the human confirms with an explicit "go" or redirect. Do not infer confirmation from prior messages or session context.

---

## Gate and Failure Protocols

All gate presentation formats and the failure decision tree are in `.crucible/sops/orchestrator.md`. Follow them exactly.

**Critical for Human Gate**: after recording the human's gate decision via `crucible.ps1 -GateOutcome`, stop immediately. Do not spawn another sub-agent. Do not run `crucible.ps1 -Init` to look for the next prompt. Report the pipeline state and end the session. The human must re-trigger orchestration explicitly for the next cycle. The human's choice is the gate - the orchestrator never crosses it on their behalf.

**CI Definition of Done**: a task that merges code to trunk is not done until adopter CI for the merge commit reports `[CI WATCH] STATUS=GREEN`. After any push of accepted task work, run `{{crucible_root}}/powershell/watch-adopter-ci.ps1 -Commit <merge-sha>` and trust the STATUS value, not a prose label. Treat `STATUS=RED` as "task not done -- fix forward and re-run the gate." `[CI WATCH] SKIPPED (gh unavailable)`, `STATUS=NO_RUNS`, and `STATUS=PENDING_TIMEOUT` are advisory unless project policy says otherwise.

If a sub-agent does not produce the required handoff or does not run crucible.ps1, follow the Failure Protocol in `.crucible/sops/orchestrator.md`. The orchestrator may only:

- Read sub-agent output and inspect task state files
- Run `crucible.ps1 -Init -TaskId {task_id} -Quiet` if a valid handoff already exists
- Re-dispatch the same specialist with a repair prompt
- Escalate to the human

The orchestrator MUST NOT complete specialist work to keep the loop moving.

---

## Status

**Status**: ACTIVE
**Owner**: Claude Code Agent
