# Crucible Install

This directory is this application's installed Crucible dev factory. It is self-contained.

Nothing in this application should directly reference a separate Crucible product checkout, a developer's personal filesystem path, or any Crucible file outside this installed `.crucible/` directory.

## Runtime Root

[`config.yaml`](config.yaml) should resolve Crucible to this installed directory:

```yaml
crucible_root: ".crucible"
```

Agents and scripts then read:

- `{{crucible_root}}/docs/operating-manual.md`
- `{{crucible_root}}/docs/policy.md`
- `{{crucible_root}}/docs/orchestrators/`
- `{{crucible_root}}/prompts/`
- `{{crucible_root}}/personas/`
- `{{crucible_root}}/sops/`
- `{{crucible_root}}/schemas/`
- `{{crucible_root}}/powershell/`

## What Belongs Here

Commit durable Crucible behavior and configuration:

- `config.yaml`
- `.gitignore`
- `README.md`
- `docs/`
- `personas/`
- `sops/`
- `prompts/`
- `schemas/`
- `powershell/`
- `agent-instructions/`, if present

Project-specific edits to personas, SOPs, or prompts are made in these installed files. They are self-contained within this directory.

## Product Repo Boundary

The Crucible product repo is used to develop and package Crucible itself. It is not an application runtime dependency.

If a needed manual, prompt, persona, SOP, schema, or script is missing from this directory, treat that as an installation packaging bug.

## What Stays Runtime-Only

The nested `.gitignore` excludes runtime state and generated artifacts by default:

- `backlog/` - task data, unless Gobot deliberately chooses to publish it
- `session/` - scratchpads, handoffs, event logs
- `.agent-workspaces/` - git worktrees
- `locks/`, `tmp/`, `cache/`
- `research/`, `dev-logs/`
- generated logs, JSONL files, handoffs, and eval output
