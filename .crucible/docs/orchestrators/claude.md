# Claude Code Strategic Orchestrator Protocol

This document defines **Claude Code-specific** mechanics for Dev Factory pipeline orchestration. Read `.crucible/docs/orchestrator.md` and `.crucible/sops/orchestrator.md` first — the persona establishes who you are, the SOP defines the loop and gate protocols. This document covers only how to invoke sub-agents and run factory commands in the Claude Code environment.

> **Cross-platform.** The `powershell.exe` invocations below are the Windows form. On Linux/macOS, use `pwsh` (PowerShell 7+) in their place.

## The "Orchestrate" Directive

When the human says `"Orchestrate {TASK_ID}"` or `"Orchestrate the next task in the backlog"`, this Claude Code session adopts the **Strategic Orchestrator** persona. The current session is the controller. It does not become Groomer, Architect, Reviewer, Operator, or Researcher.

---

## Sub-Agent Invocation

Claude Code's `Agent` tool is the sub-agent mechanism. Most specialists are dispatched as `general-purpose` sub-agents. The Researcher uses `Explore` (read-only search tools, enforces the trust boundary at the toolset level). Sub-agents share the same working directory and git state — they are not sandboxed. Do not pass orchestrator session history to sub-agents.

### Specialist Model Tiers

| Specialist | model |
|------------|-------|
| Architect  | opus  |
| Reviewer   | opus  |
| Groomer    | haiku |
| Researcher | opus  |
| Operator   | haiku |

### Standard Specialist Dispatch (Groomer, Architect, Reviewer, Operator)

```
Agent({
  subagent_type: "general-purpose",
  model: "{model-from-table-above}",
  description: "{Phase} session for {task_id}",
  prompt: `{Role}: {task_id} — read and follow all instructions in
.crucible/session/{task_id}/{phase}/prompt.md

Follow your SOP checkpoint mandate: append \`### CHECKPOINT [brief summary]\`
to task.md after each major phase. Do not write the final handoff until all
required task checklist items are complete.

After writing handoff JSON, run:
  powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id} -Quiet

Report the factory output verbatim. Stop after reporting. Do not spawn successor agents.`
})
```

### Researcher Dispatch

Use `Explore` (not `general-purpose`) to enforce read-only tool access and the trust boundary at the toolset level.

```
Agent({
  subagent_type: "Explore",
  model: "opus",
  description: "Research session for {task_id}",
  prompt: `Researcher: {task_id} — read and follow all instructions in
.crucible/session/{task_id}/research/prompt.md

Follow your SOP checkpoint mandate: append \`### CHECKPOINT [brief summary]\`
to task.md after each major phase. Do not write the final handoff until all
required task checklist items are complete.

After writing handoff JSON, run:
  powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id} -Quiet

Report the factory output verbatim. Stop after reporting. Do not spawn successor agents.`
})
```

### Bootstrap: Groomer Selects Next Item

When no task ID is known (human said "Orchestrate the next task in the backlog"):

```
Agent({
  subagent_type: "general-purpose",
  description: "Groomer bootstrap — select next backlog item",
  prompt: `Groomer: Next Item

Read AGENTS.md, <crucible_root>/docs/operating-manual.md, <crucible_root>/personas/groomer.md, and
.crucible/sops/grooming.md. Select the next eligible backlog item. Once you have
selected a task ID, create your scratchpad at
.crucible/session/<selected_task_id>/grooming/task.md (create the directory if
needed) and use it for all ### CHECKPOINT entries throughout your session.

Write or update the item's spec, write the grooming -> implementation handoff, then run:

  powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId <selected_task_id> -Quiet

Do not write the handoff until required checklist items are complete. Stop after
factory output is produced. Report the selected task ID and factory output verbatim.`
})
```

Wait for the sub-agent to return. Read the reported task ID. Ask the human for confirmation before dispatching the Architect.

---

## Running Factory Commands

Factory commands run via Bash tool using the PowerShell invocation:

```bash
powershell.exe -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id} -Quiet
```

The orchestrator runs `factory.ps1 -Init` at two points per specialist cycle:
1. **Before dispatch** — to verify the previous handoff and assemble the next prompt
2. **After sub-agent returns** — to advance the pipeline and detect gates

---

## After Each Sub-Agent Returns

Run these checks before advancing:

```
1. Check for gate signal:
   - Read .crucible/session/{task_id}/gate_pending.txt
   - If present → Gate Protocol (stop, present to human)

2. Verify task.md:
   - Read .crucible/session/{task_id}/{role}/task.md
   - Confirm ### CHECKPOINT markers exist for non-trivial work
   - Confirm no required - [ ] items remain unchecked

3. Confirm handoff exists:
   - Glob .crucible/session/handoffs/{task_id}-*.json
   - Newest timestamp = latest handoff for this task

4. If all checks pass:
   - Run factory.ps1 -Init -TaskId {task_id} -Quiet
   - Read output — gate signal? circuit breaker? next prompt?
```

---

## Human Confirmation Model

Before every specialist dispatch, present the status report format defined in `.crucible/sops/orchestrator.md` Step 3 — not a one-liner. The human is the Pilot in Command; every dispatch is their decision. Include the budget tracking line so they can see spend at a glance.

Do not dispatch until the human confirms with an explicit "go" or redirect. Do not infer confirmation from prior messages or session context.

---

## Gate and Failure Protocols

All gate presentation formats and the failure decision tree are in `.crucible/sops/orchestrator.md`. Follow them exactly.

**Critical for Human Gate**: after recording the human's gate decision via `factory.ps1 -GateOutcome`, stop immediately. Do not spawn another sub-agent. Do not run `factory.ps1 -Init` to look for the next prompt. Report the pipeline state and end the session. The human must re-trigger orchestration explicitly for the next cycle. The human's choice is the gate — the orchestrator never crosses it on their behalf.

If a sub-agent does not produce the required handoff or does not run factory.ps1, follow the Failure Protocol in `.crucible/sops/orchestrator.md`. The orchestrator may only:

- Read sub-agent output and inspect task state files
- Run `factory.ps1 -Init -TaskId {task_id} -Quiet` if a valid handoff already exists
- Re-dispatch the same specialist with a repair prompt
- Escalate to the human

The orchestrator MUST NOT complete specialist work to keep the loop moving.

---

## Status

**Status**: ACTIVE
**Owner**: Claude Code Agent
