# Crucible Documentation

The map of every doc in this folder, grouped by what you are trying to do. New here?
Start with **[why-crucible.md](why-crucible.md)** for the pitch and the mental model,
then **[get-started.md](get-started.md)** to run your first task.

Related folders (each has its own index): per-phase SOPs and runbooks in
[`../sops/`](../sops/README.md), persona definitions in
[`../personas/`](../personas/README.md), validation schemas in
[`../schemas/`](../schemas/README.md), and prompt templates in
[`../prompts/`](../prompts/README.md).

---

## Start here

| Doc | What it is |
|---|---|
| [why-crucible.md](why-crucible.md) | The one-page "what is this and why use it" - pitch plus the core concepts. |
| [get-started.md](get-started.md) | Clone to first completed task in ~10 minutes (uses a TypeScript example). |
| [bootstrap.md](bootstrap.md) | How to install Crucible into an existing project. |
| [cheat-sheet.md](cheat-sheet.md) | The shortest summary of the Human/Agent loop - keep it open while driving. |
| [when-to-use.md](when-to-use.md) | Decision guide: when Crucible is worth the ceremony and when it is not. |

## Concepts

| Doc | What it is |
|---|---|
| [why-crucible.md](why-crucible.md) | The five specialists, the trust model, and the architectural commitments. |
| [agent-discovery.md](agent-discovery.md) | How an agent, from a short trigger prompt, finds everything it needs to execute. |
| [agent-instructions.md](agent-instructions.md) | The two things Crucible needs present in a project for agents to operate. |

## Reference (authoritative)

| Doc | What it is |
|---|---|
| [operating-manual.md](operating-manual.md) | The end-to-end workflow and the phase-transition state machine. |
| [policy.md](policy.md) | Canonical definition of gates, circuit breakers, and enforcement rules. |
| [config-reference.md](config-reference.md) | Every key in `.crucible/config.yaml` (schema: `../schemas/config.schema.json`). |
| [handoff-protocol.md](handoff-protocol.md) | The phase-to-phase handoff: schema, workflow, and breaker validation. |
| [git-policy.md](git-policy.md) | What to commit versus ignore in an adopting project. |
| [implementation-phase-reference.md](implementation-phase-reference.md) | Human-readable reference for the implementation phase workflow. |
| [orchestrator.md](orchestrator.md) | The Orchestrator meta-role: mandates and gate enforcement (tool-agnostic). |
| [orchestrators/](orchestrators/) | CLI-specific orchestrator mechanics: [claude](orchestrators/claude.md), [codex](orchestrators/codex.md), [gemini](orchestrators/gemini.md). |

## Operations and runbooks

| Doc | What it is |
|---|---|
| [circuit-breaker-runbook.md](circuit-breaker-runbook.md) | Recover the pipeline after a circuit breaker fires. |
| [updating.md](updating.md) | Pull upstream framework changes into your installed `.crucible/` bundle. |
| [uninstall.md](uninstall.md) | Cleanly remove Crucible from a project. |
| [release-process.md](release-process.md) | Maintainer convention for cutting a release (adopters can skip this). |
