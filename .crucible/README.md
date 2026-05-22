# Project Crucible Directory

This directory contains project-local Crucible configuration, behavior overrides, and runtime state.

Commit configuration and behavior:

- `config.yaml` — how the project uses Crucible
- `.gitignore` — the policy file itself
- `personas/`, `sops/`, `prompts/` — project-specific behavior overrides, only when defaults aren't sufficient

Do not commit data or runtime state. The nested `.gitignore` excludes by default:

- `backlog/` — tickets are data, not code (see `docs/git-policy.md`)
- `session/` — agent scratchpads, handoffs, event logs
- `.agent-workspaces/` — git worktrees
- `locks/`, `tmp/`, `cache/` — ephemeral runtime files
- `research/`, `dev-logs/` — generated artifacts

The "configuration in, data out" principle means git history stays focused on real code/behavior changes, not on every ticket status update.
