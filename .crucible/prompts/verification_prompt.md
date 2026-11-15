<!-- prompt_version: verification_prompt-v37 -->
Verification: {task_id}

{prev_session_summary}

## POLICY ENFORCEMENT (Mandatory)

- Claude specialists: your working directory is the orchestrator session directory, not the assigned task worktree.
- [Workspace SOP: read before writes](<{{crucible_root}}/sops/specialist-workspace.md>).
See [pipeline policy](<{{crucible_root}}/docs/policy.md>) and the [verification SOP](<{{crucible_root}}/sops/verification.md>) for the workflow and boundaries.
- **Successors**: `deployment` (approved) or `implementation` (changes).
- **Budget**: {handoff_count}/{budget_ceiling} handoffs used ({budget_remaining} remaining).

## Session Context

1. **Task context**: `{session_dir}/verification/task.md` - resolved paths and Cycle ID
2. **Incoming handoff**: `{handoff_file}`
3. **Your persona**: [Reviewer](<{{crucible_root}}/personas/reviewer.md>) - judgment and mandates
4. **Your SOP**: [Verification](<{{crucible_root}}/sops/verification.md>) - read before acting; session start, workflow, state and handoff
5. **Context Bundle**: `{context_bundle_path}`

{context_block}

{rebase_section}

[Acceptance criterion evidence: quoted criterion, file:line or test name for every clause](<{{crucible_root}}/sops/verification.md#step-4---acceptance-criteria-review>).

- [Quality Bar](<{{crucible_root}}/sops/verification.md#quality-bar>) - required `task.md` checklist before handoff

[Handoff tool reference](<{{crucible_root}}/powershell/new-handoff.ps1>)

Timestamp format: `yyyyMMddTHHmmssZ` (UTC) - e.g., `{task_id}-20260418T143022Z.json`
