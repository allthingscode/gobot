# Bootstrap

This guide explains how to install Crucible into a software project.

## Ownership Model

Crucible has two locations with different jobs:

| Location | Purpose |
|---|---|
| Crucible source repository | The folder containing the framework source code, templates, and installation scripts. |
| Adopter project `.crucible/` | The complete installed Crucible bundle for that project. Agents and runtime scripts use this folder directly. |

An adopter project should not depend on a separate Crucible checkout at runtime. The source repository is only used to install or update `.crucible/` in your repository.

## What Gets Installed

A complete installed `.crucible/` contains:

- `config.yaml` - project-specific commands, paths, roles, and mandates.
- `.gitignore` - commit policy for durable behavior vs. runtime data.
- `docs/` - operating manual, policies, runbooks, and quick references.
- `personas/` - specialist role definitions for this project; edit in place to customize.
- `sops/` - specialist workflows for this project; edit in place to customize.
- `prompts/` - prompt templates and prompt README.
- `schemas/` - handoff and config validation schemas.
- `powershell/` - current executable runtime.
- `agent-instructions/` - copy-ready snippets for root `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md`.
- `backlog/` - project task index and task specs.

Runtime directories such as `session/`, `.agent-workspaces/`, `locks/`, `tmp/`, and `cache/` are created as needed and ignored by git.

## Install

From the Crucible source repository (on Linux/macOS, prefix the script with `pwsh`; see [get-started.md](get-started.md#prerequisites)):

```powershell
./powershell/init-project.ps1 -ProjectRoot <project-root> -ProjectName "<name>" -Language <go|node|python|rust> -WithSampleTask -AppendInstructions
```

The script copies the self-contained template into `<project-root>/.crucible`, fills basic project metadata, and sets:

```yaml
crucible_root: ".crucible"
```

The three optional flags are worth passing on a first install:

| Flag | Effect |
|---|---|
| `-Language <go\|node\|python\|rust>` | Fills `verification.quick` / `verification.full` with that language's usual commands. Omit it and those keys stay as `replace-with-...` placeholders that you must edit by hand before `validate-config.ps1` will pass. |
| `-WithSampleTask` | Adds a runnable `F-001_Hello_World` item so you can exercise the pipeline end to end immediately. |
| `-AppendInstructions` | Appends the Crucible block to the project's `AGENTS.md` / `CLAUDE.md` / `GEMINI.md`, which is otherwise a manual step (see "Agent Instruction Setup" below). |

Re-running against an existing scaffold refuses to overwrite files unless `-Force` is passed.



## Configure

Edit `<project-root>/.crucible/config.yaml`:

- Set project name, description, and default branch.
- Replace verification commands with the adopter project's actual commands.
- Add project mandates.
- Keep paths relative to the project root unless there is a strong reason to change them.

From the adopter project root, validate the install:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".crucible/powershell/validate-config.ps1" -ConfigPath ".crucible/config.yaml"
```
*(Linux/macOS: replace `powershell.exe` with `pwsh`.)*

## Agent Instruction Setup

After bootstrapping `.crucible/`, update the target project's root instruction files:

1. Add the block from [agent-instructions.md](agent-instructions.md) to the project root `AGENTS.md`.
2. If the project uses Claude Code, add or update `CLAUDE.md` with the Claude snippet.
3. If the project uses Gemini or Antigravity, add or update `GEMINI.md` with the Gemini snippet.
4. If the project has a Codex-specific instruction file, point it at `AGENTS.md` and `.crucible/docs/orchestrators/codex.md`.

The scaffold also places copy-ready snippets in `.crucible/agent-instructions/`. Those snippets are source material; paste or merge them into the root instruction files that your agent tool actually reads.

Use [../examples/gobot](../examples/gobot) as a working example configuration reference.

## What This Repository Keeps

This repo remains the source of truth for the Crucible product:

- Product docs and release notes.
- Default docs, personas, SOPs, prompts, schemas, and runtime scripts.
- Installer and update scripts.
- Templates used to create complete `.crucible/` installs.
- Examples and tests.

Project-specific work belongs in the adopter project's installed `.crucible/`.

## First-Read Order

For a new human or agent, read:

1. [../README.md](../README.md) - what Crucible is and why it exists.
2. [get-started.md](get-started.md) - step-by-step first task walkthrough and 10-minute quickstart.
3. [operating-manual.md](operating-manual.md) - end-to-end workflow.
4. [policy.md](policy.md) - canonical gates and circuit breakers.
5. [handoff-protocol.md](handoff-protocol.md) - handoff shape and session lifecycle.
6. [agent-instructions.md](agent-instructions.md) - what to add to adopter instruction files.
7. [git-policy.md](git-policy.md) - what belongs in git under `.crucible/`.
8. [cheat-sheet.md](cheat-sheet.md) - compact operational summary.
9. [uninstall.md](uninstall.md) - how to cleanly remove Crucible.

## Advanced: Custom Installers

If you are packaging Crucible into a custom installer or running inside a specialized configuration framework, you can copy the [../templates/project/.crucible](../templates/project/.crucible) template directory manually instead of using `init-project.ps1`.


