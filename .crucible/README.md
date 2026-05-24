# Crucible Install

This directory is this application's installed Crucible dev factory. It must be self-contained.

Nothing in this application should reference external paths outside the repository. Crucible files, settings, docs, prompts, personas, SOPs, schemas, and scripts must be self-contained within this directory.

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

## What Stays Runtime-Only

The nested `.gitignore` excludes runtime state and generated artifacts by default:

- `backlog/` - task data, unless Gobot deliberately chooses to publish it
- `session/` - scratchpads, handoffs, event logs
- `.agent-workspaces/` - git worktrees
- `locks/`, `tmp/`, `cache/`
- `research/`, `dev-logs/`
- generated logs, JSONL files, handoffs, and eval output

## Crucible Framework Files

Crucible is designed to run in a self-contained manner directly from this directory. No external installations or checkouts are required at runtime.

If a needed manual, prompt, persona, SOP, schema, or script is missing from this directory, please check your installation package.
