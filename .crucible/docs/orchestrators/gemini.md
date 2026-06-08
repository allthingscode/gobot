# Gemini / Antigravity Strategic Orchestrator Protocol

This document defines **Gemini / Antigravity CLI-specific** mechanics for Dev Factory pipeline orchestration. Read `.crucible/docs/orchestrator.md` and `.crucible/sops/orchestrator.md` first — the persona establishes who you are, the SOP defines the loop, gate protocols, and failure taxonomy. This document covers only how to invoke sub-agents in the Gemini / Antigravity CLI environments.

> **Cross-platform.** The `powershell.exe` invocations below are the Windows form. On Linux/macOS, use `pwsh` (PowerShell 7+) in their place.

## The "Orchestrate" Directive

When the human says `"Orchestrate {TASK_ID}"` or `"Orchestrate the next task in the backlog"`, Gemini/Antigravity CLI adopts the **Strategic Orchestrator** persona. The current session is the controller. It does not become Groomer, Architect, Reviewer, Operator, or Researcher.

---

## Sub-Agent Invocation

Depending on the CLI runtime (Gemini CLI vs. Antigravity CLI), the invocation syntax and target sub-agent differ:

### 1. Antigravity CLI Runtime (Recommended / Active)
Antigravity CLI uses `invoke_subagent` and targets the `self` sub-agent type (which inherits all of the parent session's configuration and tools for read/write execution):

```json
invoke_subagent(
  Subagents=[
    {
      "TypeName": "self",
      "Role": "{Role}",
      "Prompt": (
        f"{Role}: {TASK_ID} — read and follow all instructions in "
        f".crucible/session/{TASK_ID}/{phase}/prompt.md\n\n"
        "Follow your SOP checkpoint mandate: append `### CHECKPOINT [brief summary]` "
        "to task.md after each major phase. Do not write the final handoff until all "
        "required task checklist items are complete.\n\n"
        "After writing handoff JSON, run factory.ps1 -Init -TaskId {TASK_ID} -Quiet "
        "and report the factory output verbatim. Stop after reporting. "
        "Do not spawn successor agents."
      )
    }
  ]
)
```

### 2. Gemini CLI Runtime (Legacy)
Gemini CLI uses `invoke_agent` and targets the `generalist` sub-agent:

```python
invoke_agent(
  agent_name="generalist",
  prompt=(
    f"{Role}: {TASK_ID} — read and follow all instructions in "
    f".crucible/session/{TASK_ID}/{phase}/prompt.md\n\n"
    "Follow your SOP checkpoint mandate: append `### CHECKPOINT [brief summary]` "
    "to task.md after each major phase. Do not write the final handoff until all "
    "required task checklist items are complete.\n\n"
    "After writing handoff JSON, run factory.ps1 -Init -TaskId {TASK_ID} -Quiet "
    "and report the factory output verbatim. Stop after reporting. "
    "Do not spawn successor agents."
  )
)
```

---

### Bootstrap: Groomer Selects Next Item

When no task ID is known:

#### Antigravity CLI Runtime
```json
invoke_subagent(
  Subagents=[
    {
      "TypeName": "self",
      "Role": "Groomer",
      "Prompt": (
        "Groomer: Next Item\n\n"
        "Read AGENTS.md, <crucible_root>/docs/operating-manual.md, <crucible_root>/personas/groomer.md, "
        "and .crucible/sops/grooming.md. Select the next eligible backlog item, write or "
        "update its spec, write the grooming -> implementation handoff, then run:\n\n"
        "  powershell.exe -ExecutionPolicy Bypass -File \"{{crucible_root}}/powershell/factory.ps1\" "
        "-Init -TaskId <selected_task_id> -Quiet\n\n"
        "Follow your SOP checkpoint mandate. Do not write the handoff until required "
        "checklist items are complete. Stop after factory output. Report the selected "
        "task ID and factory output verbatim."
      )
    }
  ]
)
```

#### Gemini CLI Runtime
```python
invoke_agent(
  agent_name="generalist",
  prompt=(
    "Groomer: Next Item\n\n"
    "Read AGENTS.md, <crucible_root>/docs/operating-manual.md, <crucible_root>/personas/groomer.md, "
    "and .crucible/sops/grooming.md. Select the next eligible backlog item, write or "
    "update its spec, write the grooming -> implementation handoff, then run:\n\n"
    "  powershell.exe -ExecutionPolicy Bypass -File \"{{crucible_root}}/powershell/factory.ps1\" "
    "-Init -TaskId <selected_task_id> -Quiet\n\n"
    "Follow your SOP checkpoint mandate. Do not write the handoff until required "
    "checklist items are complete. Stop after factory output. Report the selected "
    "task ID and factory output verbatim."
  )
)
```

---

## After Each Sub-Agent Returns

Before advancing the pipeline:

1. Read `.crucible/session/{TASK_ID}/{ROLE}/task.md` — confirm `### CHECKPOINT` markers present and no required `- [ ]` items unchecked
2. Confirm a new handoff file exists in `.crucible/session/handoffs/{TASK_ID}-*.json`
3. Run `factory.ps1 -Init -TaskId {TASK_ID} -Quiet` — check for gate signals or circuit breakers
4. If any check fails → Failure Protocol (see `.crucible/sops/orchestrator.md`)

---

## Human Confirmation

Before every specialist dispatch, present the status report format defined in `.crucible/sops/orchestrator.md` Step 3 — including the budget tracking line. The human is the Pilot in Command; every dispatch is their decision, not a formality.

Wait for an explicit "go" or redirect. Do not dispatch without confirmation.

---

## Gate and Failure Protocols

All gate presentation formats (Research Gate, Human Gate, Circuit Breaker Gate) and the failure decision tree are defined in `.crucible/sops/orchestrator.md`. Follow them exactly.

---

## Benefits
- **No Context Rot**: Each specialist starts with 0 tokens of history, preventing hallucination creep in long sessions.
- **Reliability**: Turn limits are managed by the Orchestrator, not by specialists.
- **Auditability**: The main session history becomes a high-level log of transitions, not an implementation dump.

---

**Status**: ACTIVE
**Owner**: Gemini / Antigravity CLI Agent

