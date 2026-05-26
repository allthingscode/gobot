# Agent Instructions For Adopter Projects

Crucible needs two things in a project:

- A complete installed `.crucible/` directory.
- Root agent instruction files that tell AI tools to use that installed directory.

Agents must use the project's own `.crucible/` folder as configured in `.crucible/config.yaml` (default: `.crucible`) as the runtime source of truth, rather than any external or temporary directories.

## Required Block For `AGENTS.md`

Add this block near the top of the target project's `AGENTS.md`. If the project does not have an `AGENTS.md`, create one and keep any existing product-specific engineering rules below this block.

````markdown
<!-- crucible-instructions-start -->
## Crucible

This project uses Crucible for multi-agent planning, implementation, review, and handoff control.

Before running a Crucible task:

1. Read `.crucible/config.yaml`.
2. Resolve `crucible_root` from that file. `crucible_root` defaults to `.crucible` but adopters may configure a different bundle directory.
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
<!-- crucible-instructions-end -->
````

## Optional Tool-Specific Files

Some tools read their own root instruction files. Keep these small and make them defer to `AGENTS.md` plus the installed Crucible docs.

### `CLAUDE.md`

```markdown
<!-- crucible-instructions-start -->
# Claude Instructions

Read `AGENTS.md` first.

For Crucible work, read `.crucible/config.yaml`, resolve `crucible_root`, then follow:

- `{{crucible_root}}/docs/operating-manual.md`
- `{{crucible_root}}/docs/policy.md`
- `{{crucible_root}}/docs/orchestrators/claude.md`
<!-- crucible-instructions-end -->
```

### `GEMINI.md`

```markdown
<!-- crucible-instructions-start -->
# Gemini Instructions

Read `AGENTS.md` first.

For Crucible work, read `.crucible/config.yaml`, resolve `crucible_root`, then follow:

- `{{crucible_root}}/docs/operating-manual.md`
- `{{crucible_root}}/docs/policy.md`
- `{{crucible_root}}/docs/orchestrators/gemini.md`
<!-- crucible-instructions-end -->
```

### Codex

Codex normally reads `AGENTS.md`. If the project has a Codex-specific instruction file, use the same forwarding pattern and point it at:

```markdown
{{crucible_root}}/docs/orchestrators/codex.md
```

## What Not To Do

- Do not tell agents to read `.private/`.
- Ensure agents resolve and use the configured `crucible_root` (normally `.crucible/`) inside the project repository.
- Do not ignore the entire `.crucible/` directory.
- Do not treat `personas/`, `sops/`, or `prompts/` as overrides-only directories; in an installed project they contain the active defaults, and project-specific edits are made in place.
