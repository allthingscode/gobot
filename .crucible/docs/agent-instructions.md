# Agent Instructions For Adopter Projects

Crucible needs two things in a project:

- A complete installed `.crucible/` directory.
- Root agent instruction files that tell AI tools to use that installed directory.

## Required Block For `AGENTS.md`

Add this block near the top of the target project's `AGENTS.md`. If the project does not have an `AGENTS.md`, create one and keep any existing product-specific engineering rules below this block.

````markdown
## Crucible

This project uses Crucible for multi-agent planning, implementation, review, and handoff control.

Before running a Crucible task:

1. Read `.crucible/config.yaml`.
2. Resolve `crucible_root` from that file. In a typical install this is `.crucible`.
3. Read `{{crucible_root}}/docs/operating-manual.md`.
4. Read `{{crucible_root}}/docs/policy.md`.
5. Read the relevant CLI orchestration guide under `{{crucible_root}}/docs/orchestrators/`.

The `.crucible/` directory is the installed Crucible bundle for this project. It includes docs, prompts, personas, SOPs, schemas, runtime scripts, project config, backlog, and runtime state.

Commit durable Crucible files:

- `.crucible/config.yaml`
- `.crucible/.gitignore`
- `.crucible/README.md`
- `.crucible/docs/`
- `.crucible/personas/`
- `.crucible/sops/`
- `.crucible/prompts/`
- `.crucible/schemas/`
- `.crucible/powershell/`
- `.crucible/agent-instructions/`

Do not commit runtime data:

- `.crucible/session/`
- `.crucible/.agent-workspaces/`
- `.crucible/locks/`
- `.crucible/tmp/`
- `.crucible/cache/`
- generated logs, JSONL files, handoffs, and eval output

Run the installed runtime from the project root:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId <task-id>
```
````

### `AGENTS.md`
```markdown
# Crucible Instructions

Read `.crucible/config.yaml`, resolve `crucible_root`, then follow:

- `{{crucible_root}}/docs/operating-manual.md`
- `{{crucible_root}}/docs/policy.md`
- `{{crucible_root}}/docs/orchestrators/claude.md`
```

### `CLAUDE.md`

```markdown
# Claude Instructions

Read `AGENTS.md` first.
```

### `GEMINI.md`

```markdown
# Gemini Instructions

Read `AGENTS.md` first.
```

### Codex

Codex normally reads `AGENTS.md`. If the project has a Codex-specific instruction file, use the same forwarding pattern.
