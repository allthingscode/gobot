# Codex Strategic Orchestrator Protocol

This document defines **Codex CLI-specific** mechanics for Dev Factory pipeline orchestration. Read `.crucible/personas/orchestrator.md` and `.crucible/sops/orchestrator.md` first - the persona establishes who you are, the SOP defines the loop, gate protocols, and failure taxonomy. This document covers only how to invoke sub-agents in the Codex CLI environment.

## The "Orchestrate" Directive

When the human says `"Orchestrate {TASK_ID}"`, `"Orchestrate the next task in the backlog"`, or asks Codex to run the factory loop, the current Codex session adopts the **Strategic Orchestrator** persona.

The parent session is the controller. It does not become Groomer, Architect, Reviewer, Operator, or Researcher.

## Adapter Boundary

This file is the Codex adapter layer. `.crucible/sops/orchestrator.md` remains the canonical, platform-neutral SOP for all agent runtimes (Codex, Claude Code, Gemini CLI).

Boundary rules:

- Do not add Codex-specific tool semantics to `.crucible/sops/orchestrator.md`.
- Keep gates, failure taxonomy, and role workflow definitions in the SOP.
- Keep Codex execution mappings in this file only (for example `spawn_agent`, `multi_tool_use.parallel`, `update_plan`, `gh run view <id> --log`).
- If a rule applies to every runtime, update the SOP. If a rule only describes how Codex executes the SOP, update this file.

## Core Mandates (Codex-Specific)

1. **Zero-Implementation Policy**: Covered in `.crucible/personas/orchestrator.md`. Codex adds: never run `gemini`, `claude`, or another `agent` CLI process from inside Codex to create a specialist session - use Codex subagents exclusively.
2. **Delegation via Subagents**: Every specialist role is executed with `spawn_agent`.
3. **Context Isolation**: Spawn specialist subagents with `fork_context: false`. Pass only the generated specialist prompt or a short bootstrap prompt that tells the subagent which files to read.
4. **Parent-Owned Routing**: Subagents MUST NOT spawn successor agents. The parent session waits for completion, runs or verifies `factory.ps1`, checks gates, asks the human for confirmation, and then spawns the next subagent.
5. **Human Gates Stay Blocking**: Research Gate, Operator Human Gate, circuit breakers, missing handoffs, and factory validation failures always stop the loop.
6. **Checkpoint Enforcement**: The parent session MUST verify required `### CHECKPOINT` markers in the specialist `task.md` before accepting a subagent's completion.
7. **Plan State Is Mandatory**: Parent session must keep `update_plan` current with a 4-6 step loop (`Research -> Spec -> Exec -> Validate -> Handoff`) and only one `in_progress` step.
8. **Parallelize Only Independent Work**: Use `multi_tool_use.parallel` for independent reads/searches and allow concurrent subagents only for non-overlapping, non-gated workstreams explicitly approved by the human.
9. **Retry Discipline**: Follow one retry per adjusted attempt, then alternate method, then stop and report; never loop identical failing calls.

## Codex Subagent Type Selection

Use Codex subagent types conservatively:

- `worker`: default for Groomer, Architect, Reviewer, and Operator because they may write files, run validation, or update handoffs.
- `explorer`: only for bounded read-only Researcher tasks where no files should be modified.
- `default`: acceptable fallback when the environment does not expose a more specific subagent type.

When using `worker`, the parent prompt must assign clear ownership and remind the subagent that it is not alone in the codebase and must not revert unrelated edits.

## Checkpoint Discipline

Gemini subagents have previously skipped over checkpoint expectations. Codex orchestration must make checkpoints an explicit parent-owned contract.

The parent session must do the following for every specialist subagent:

1. Include checkpoint instructions in the spawn prompt:

   ```text
   Follow the checkpoint mandate in your SOP. After every major phase, append
   `### CHECKPOINT [brief summary]` to your task.md. Do not write the final
   handoff until the required checkpoints and task checklist are complete.
   ```

2. After the subagent returns, inspect `.crucible/session/{TASK_ID}/{role}/task.md`.
3. Confirm the file contains at least one `### CHECKPOINT` marker for non-trivial work.
4. Confirm the required `## Task List` has no unchecked required items before accepting the handoff.
5. If checkpoints are missing, do not advance the pipeline. Re-dispatch the same specialist with a repair prompt, or ask the human for direction if the work cannot be verified.

Checkpoint verification is not a replacement for `factory.ps1` gates. It is an additional parent-side check to prevent subagents from rushing directly to handoff.

## Bootstrap: Next Backlog Item

`factory.ps1 -Init -TaskId` requires a task ID, so `"Groomer: Next Item"` starts in bootstrap mode.

1. Parent spawns a Groomer subagent with a short bootstrap prompt:

   ```text
   Groomer: Next Item

   Read AGENTS.md, <crucible_root>/docs/operating-manual.md, <crucible_root>/personas/groomer.md,
   and .crucible/sops/groomer.md. Select the next eligible backlog item, write or
   update its spec, write the groomer -> architect handoff, run factory.ps1
   -Init -TaskId <selected_task_id> -Quiet, then stop and report the task ID and
   factory output. Follow your SOP checkpoint mandate: append `### CHECKPOINT`
   entries to task.md after each major pass, and do not write the handoff until
   required checklist items are complete.
   ```

2. Parent waits for the Groomer subagent to finish.
3. Parent reads the generated handoff and factory output paths.
4. Parent asks the human for confirmation before launching the Architect subagent.

## Continuation: Known Task ID

For an existing task, the parent runs:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {TASK_ID} -Quiet
```

Then it reads:

- `.crucible/session/{TASK_ID}/{ROLE}/prompt.md`
- `.crucible/session/{TASK_ID}/{ROLE}/next_step.txt`
- `.crucible/session/{TASK_ID}/gate_pending.txt` if present

If no gate or circuit breaker is active, the parent spawns the next specialist subagent with:

```text
{Role}: {TASK_ID} - read and follow all instructions in .crucible/session/{TASK_ID}/{role}/prompt.md

Follow your SOP checkpoint mandate. Append `### CHECKPOINT [brief summary]`
to task.md after every major phase. Do not write the final handoff until the
required checkpoints and task checklist are complete. Stop after running
factory.ps1 and report the result to the parent.
```

## Parent Session Responsibilities

The parent Codex session is responsible for:

- Keeping the visible task list for the orchestration loop.
- Maintaining `update_plan` state with one active step and explicit completion transitions.
- Spawning exactly one specialist subagent at a time unless the human explicitly authorizes parallel work.
- Waiting for specialist completion when on the critical path; if parallel specialists are running, continue non-overlapping parent checks/work.
- Reading the latest handoff for the task and validating that `factory.ps1` produced the next session artifacts.
- Inspecting the completed specialist `task.md` for required checkpoints and unchecked required task-list items.
- Presenting the Step 3 status report (from `.crucible/sops/orchestrator.md`) before each specialist launch, including budget tracking, and waiting for explicit human confirmation.
- Pulling CI diagnostics directly with `gh run view <id> --log` when CI status affects gates; do not ask humans to paste logs.
- Stopping on all gates, circuit breakers, missing artifacts, failed validation, or ambiguous task state.
- Logging or reporting enough detail for the human to understand the current task, role, and next action.

## Subagent Prompt Rules

Specialist subagent prompts should be short. They should point to filesystem instructions, not inline the whole process.

Required prompt constraints:

- Tell the subagent to read `AGENTS.md`.
- Tell the subagent to read the generated `prompt.md` for its role when one exists.
- Tell the subagent to run `factory.ps1 -Init -TaskId {TASK_ID} -Quiet` at session end after writing handoff JSON.
- Tell the subagent to append `### CHECKPOINT` markers to `task.md` after major phases.
- Tell the subagent not to write handoff JSON until required checklist items are complete.
- Tell the subagent to stop after factory output is produced and report the result to the parent.
- Tell the subagent it is not alone in the codebase and must not revert unrelated edits.

## Parallelization Policy (Codex)

Use parallelism to reduce cycle time without weakening control:

- Use `multi_tool_use.parallel` for independent file reads, content searches, and metadata inspections.
- Do not parallelize dependent operations (for example, reading generated artifacts before `factory.ps1` completes).
- Parallel specialist sessions are allowed only when all conditions are true:
  - Human explicitly approves parallel work.
  - Workstreams have disjoint ownership and no shared write paths.
  - Neither branch crosses a blocking gate before rejoin.
- Parent must define ownership boundaries in each parallel subagent prompt and integrate results before advancing to the next gated phase.

## Session Lifecycle Automation

Treat session lifecycle as a hard requirement:

- On session start, run `factory.ps1 -Init -TaskId {TASK_ID}` and verify artifacts exist before specialist launch.
- On specialist completion, validate handoff + checkpoints, then re-run or verify `factory.ps1` output before routing.
- On session end, ensure handoff is written, clear lock/process residue per SOP, run `factory.ps1 -Init -TaskId {TASK_ID}`, and report the exact output to the human.

## Gate and Failure Protocols

All gate presentation formats (Research Gate, Human Gate, Circuit Breaker Gate) and the failure decision tree are defined in `.crucible/sops/orchestrator.md`. Follow them exactly. The Codex parent session does not have its own gate format - all tools use the same canonical presentation.

## Status

**Status**: ACTIVE
**Owner**: Codex CLI Agent
