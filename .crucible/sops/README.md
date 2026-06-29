# SOPs

Standard operating procedures for Crucible. There are two kinds: **pipeline phase
SOPs** that `factory.ps1` routes to automatically as a task moves through the FSM, and
**human-initiated runbooks** you trigger by hand.

For the runbook triggers (the exact prompt to paste), see [registry.md](registry.md).
For how a phase's SOP relates to its persona and prompt, see "Anatomy of a phase" below.

---

## Pipeline phase SOPs (auto-routed by `factory.ps1`)

One per FSM phase. The orchestrator never picks these by hand - the factory assembles
the matching prompt when a handoff lands in that phase.

| SOP | Phase | Persona | Prompt template |
|---|---|---|---|
| [research.md](research.md) | research | [Researcher](../personas/researcher.md) | [research_prompt.md](../prompts/research_prompt.md) |
| [grooming.md](grooming.md) | grooming | [Groomer](../personas/groomer.md) | [grooming_prompt.md](../prompts/grooming_prompt.md) |
| [implementation.md](implementation.md) | implementation | [Architect](../personas/architect.md) | [implementation_prompt.md](../prompts/implementation_prompt.md) |
| [verification.md](verification.md) | verification | [Reviewer](../personas/reviewer.md) | [verification_prompt.md](../prompts/verification_prompt.md) |
| [deployment.md](deployment.md) | deployment | [Operator](../personas/operator.md) | [deployment_prompt.md](../prompts/deployment_prompt.md) |

`research.md` is the root research SOP; it routes to a task-type-specific sub-SOP:

| Sub-SOP | Use when |
|---|---|
| [research-investigate.md](research-investigate.md) | Investigating a specific topic, library, or gap. |
| [research-audit-project.md](research-audit-project.md) | Running a structured quality audit of the adopter project. |
| [research-audit-framework.md](research-audit-framework.md) | Running a structured quality audit of the Crucible framework. |

## Orchestration

The Orchestrator is the meta-role that drives the pipeline (not a phase specialist).

| Doc | What it is |
|---|---|
| [orchestrator.md](orchestrator.md) | The procedure: drive the pipeline, spawn specialists, honor gates. |
| [../docs/orchestrator.md](../docs/orchestrator.md) | The persona/identity (who the Orchestrator is). |
| [../docs/orchestrators/](../docs/orchestrators/) | CLI-specific mechanics (Claude Code, Codex, Antigravity). |

## Human-initiated runbooks

Triggered by hand, not by the factory. Paste the trigger from [registry.md](registry.md).

| Runbook | What it is |
|---|---|
| [health-check.md](health-check.md) | System health check (routine). |
| [grooming.md](grooming.md) | Backlog grooming in Runbook Mode (same file as the phase SOP, different entry). |
| [system-analysis.md](system-analysis.md) | Full system analysis plus a direction conversation. |

---

## Anatomy of a phase

Each pipeline phase is described by up to four files, by concern. When you edit, change
the one that matches your intent:

- **Persona** (`../personas/<role>.md`) - WHO the agent is: mandate, voice, boundaries.
- **SOP** (`sops/<phase>.md`) - HOW the phase runs: the procedure and its gates.
- **Prompt** (`../prompts/<phase>_prompt.md`) - the runtime template `factory.ps1`
  assembles and hands to the specialist. Edit here to change what the agent actually receives.
- **Reference** (`../docs/<phase>-reference.md`, where present) - human-readable
  explanation; not loaded at runtime.
