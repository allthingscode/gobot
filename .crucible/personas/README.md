# Personas

A persona defines WHO a specialist agent is - its mandate, voice, and boundaries - for
one pipeline phase. The matching procedure lives in the phase SOP (`../sops/<phase>.md`)
and the runtime template in `../prompts/<phase>_prompt.md`. See
[../sops/README.md](../sops/README.md) "Anatomy of a phase" for how the pieces relate.

| Persona | Phase | SOP | Prompt |
|---|---|---|---|
| [researcher.md](researcher.md) | research | [research.md](../sops/research.md) | [research_prompt.md](../prompts/research_prompt.md) |
| [groomer.md](groomer.md) | grooming | [grooming.md](../sops/grooming.md) | [grooming_prompt.md](../prompts/grooming_prompt.md) |
| [architect.md](architect.md) | implementation | [implementation.md](../sops/implementation.md) | [implementation_prompt.md](../prompts/implementation_prompt.md) |
| [reviewer.md](reviewer.md) | verification | [verification.md](../sops/verification.md) | [verification_prompt.md](../prompts/verification_prompt.md) |
| [operator.md](operator.md) | deployment | [deployment.md](../sops/deployment.md) | [deployment_prompt.md](../prompts/deployment_prompt.md) |

The **Orchestrator** is intentionally NOT here: it is the meta-role that drives the
pipeline rather than a phase specialist. Its identity lives in
[../docs/orchestrator.md](../docs/orchestrator.md) and its procedure in
[../sops/orchestrator.md](../sops/orchestrator.md).
