# Antigravity Strategic Orchestrator Protocol

This document defines **Antigravity CLI-specific** mechanics for Crucible pipeline orchestration. Read `.crucible/docs/orchestrator.md` and `.crucible/sops/orchestrator.md` first - the persona establishes who you are, the SOP defines the loop, gate protocols, and failure taxonomy. This document covers only how to invoke sub-agents in the Antigravity CLI environment. The legacy Gemini CLI runtime is retained at the end for reference.

> **Invocation.** Commands use `pwsh` (PowerShell 7+). Windows PowerShell 5.1 is not supported.

## The "Orchestrate" Directive

When the human says `"Orchestrate {TASK_ID}"` or `"Orchestrate the next task in the backlog"`, the Antigravity CLI session adopts the **Strategic Orchestrator** persona. The current session is the controller. It does not become Groomer, Architect, Reviewer, Operator, or Researcher.

---

## Sub-Agent Invocation

Antigravity CLI uses `invoke_subagent` and targets the `self` sub-agent type (which inherits all of the parent session's configuration and tools for read/write execution):

```json
invoke_subagent(
  Subagents=[
    {
      "TypeName": "self",
      "Role": "{Role}",
      "Prompt": (
        f"{Role}: {TASK_ID} - read and follow all instructions in "
        f".crucible/session/{TASK_ID}/{phase}/prompt.md\n\n"
        "Follow the linked phase SOP."
      )
    }
  ]
)
```

---

### Bootstrap: Groomer Selects Next Item

When no task ID is known:

```json
invoke_subagent(
  Subagents=[
    {
      "TypeName": "self",
      "Role": "Groomer",
      "Prompt": (
        "Groomer: Next Item. Target: gemini. Read and follow .crucible/sops/grooming.md#bootstrap-no-task-id."
      )
    }
  ]
)
```

---

## After Each Sub-Agent Returns

Follow [Step 5](../../sops/orchestrator.md#step-5---verify-specialist-output-and-track-budget), then [Step 6](../../sops/orchestrator.md#step-6---verify-crucible-output-and-next-phase-artifacts) to verify Crucible output and next phase artifacts.


## Human Confirmation

Follow the [approval procedure](../../sops/orchestrator.md#step-3---report-to-human-and-request-confirmation).


## Gate and Failure Protocols

Follow the [Gate Protocol](../../sops/orchestrator.md#gate-protocol), [Failure Protocol](../../sops/orchestrator.md#failure-protocol), and [Session End](../../sops/orchestrator.md#session-end).


## Benefits
- **No Context Rot**: Each specialist starts with 0 tokens of history, preventing hallucination creep in long sessions.
- **Reliability**: Turn limits are managed by the Orchestrator, not by specialists.
- **Auditability**: The main session history becomes a high-level log of transitions, not an implementation dump.

---

## Legacy: Gemini CLI Runtime

The Gemini CLI was the original runtime for this orchestrator doc before Antigravity. It uses `invoke_agent` and targets the `generalist` sub-agent. Retained for adopters still on that runtime; new work uses the Antigravity path above.

```python
invoke_agent(
  agent_name="generalist",
  prompt=(
    f"{Role}: {TASK_ID} - read and follow all instructions in "
    f".crucible/session/{TASK_ID}/{phase}/prompt.md\n\n"
    "Follow the linked phase SOP."
  )
)
```

Bootstrap form (no task ID known):

```python
invoke_agent(
  agent_name="generalist",
  prompt=(
    "Groomer: Next Item\n\n"
    "Read AGENTS.md, <crucible_root>/docs/operating-manual.md, <crucible_root>/personas/groomer.md, "
    "and .crucible/sops/grooming.md. Select the next eligible backlog item, write or "
    "update its spec, write the grooming -> implementation handoff, then run:\n\n"
    "  pwsh -ExecutionPolicy Bypass -File \"{{crucible_root}}/powershell/crucible.ps1\" "
    "-Init -TaskId <selected_task_id> -ProjectRoot \"{project_root}\" -Quiet\n\n"
    "Follow your SOP checkpoint mandate. Do not write the handoff until required "
    "checklist items are complete. Stop after Crucible output. Report the selected "
    "task ID and Crucible output verbatim."
  )
)
```

---

**Status**: ACTIVE
**Owner**: Antigravity CLI Agent
