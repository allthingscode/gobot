<!-- prompt_version: grooming_prompt-v31 -->
Grooming: {task_id}

{prev_session_summary}

## POLICY ENFORCEMENT (Mandatory)

- Claude specialists: your working directory is the orchestrator session directory, not the assigned task worktree.
- [Workspace SOP: read before writes](<{{crucible_root}}/sops/specialist-workspace.md>).
See [pipeline policy](<{{crucible_root}}/docs/policy.md>) and the [grooming SOP](<{{crucible_root}}/sops/grooming.md>) for the workflow and boundaries.
- **Successors**: `implementation`, `research`, `verification` (Stub-Only Close-Out), or `done` (closure path).
- **Budget**: {handoff_count}/{budget_ceiling} handoffs used ({budget_remaining} remaining).

## Session Context

1. **Task context**: `{session_dir}/grooming/task.md` - resolved paths and Cycle ID
2. **Incoming handoff**: `{handoff_file}`
3. **Your persona**: [Groomer](<{{crucible_root}}/personas/groomer.md>) - judgment and mandates
4. **Your SOP**: [Grooming](<{{crucible_root}}/sops/grooming.md>) - read before acting; session start, workflow, state and handoff
5. **Context Bundle**: `{context_bundle_path}`

{context_block}

[Approved stub scope and deviations](<{{crucible_root}}/sops/grooming.md#step-2---run-new-handoffps1>).

- [Quality Bar](<{{crucible_root}}/sops/grooming.md#quality-bar>) - required `task.md` checklist before handoff

[Handoff tool reference](<{{crucible_root}}/powershell/new-handoff.ps1>)

Timestamp format: `yyyyMMddTHHmmssZ` (UTC) - e.g., `{task_id}-20260418T143022Z.json`
