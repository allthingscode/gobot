<!-- prompt_version: implementation_prompt-v42 -->
Implementation: {task_id}

{prev_session_summary}

## POLICY ENFORCEMENT (Mandatory)

- Claude specialists: your working directory is the orchestrator session directory, not the assigned task worktree.
- [Workspace SOP: read before writes](<{{crucible_root}}/sops/specialist-workspace.md>).
See [pipeline policy](<{{crucible_root}}/docs/policy.md>) and the [implementation SOP](<{{crucible_root}}/sops/implementation.md>) for the workflow and boundaries.
- **Successors**: Only `verification`.
- **Budget**: {handoff_count}/{budget_ceiling} handoffs used ({budget_remaining} remaining).
- **Worktree**: `{worktree}`.

## Session Context

1. **Task context**: `{session_dir}/implementation/task.md` - resolved paths and Cycle ID
2. **Incoming handoff**: `{handoff_file}`
3. **Your persona**: [Architect](<{{crucible_root}}/personas/architect.md>) - judgment and mandates
4. **Your SOP**: [Implementation](<{{crucible_root}}/sops/implementation.md>) - read before acting; session start, workflow, state and handoff
5. **Context Bundle**: `{context_bundle_path}`

{context_block}

{rebase_section}

## Workflow References

- [Session Start](<{{crucible_root}}/sops/implementation.md#session-start>)
- [Decision Tree](<{{crucible_root}}/sops/implementation.md#decision-tree-for-new-featuresbugs---not-review-fixes>)
- [Phase 2: Code](<{{crucible_root}}/sops/implementation.md#phase-2-code>)
- [Phase 3: Self-Review](<{{crucible_root}}/sops/implementation.md#phase-3-self-review>)
- [Phase 4: Handoff to Verification](<{{crucible_root}}/sops/implementation.md#phase-4-handoff-to-verification>)

- [Quality Bar](<{{crucible_root}}/sops/implementation.md#quality-bar>) - required `task.md` checklist before handoff

[Handoff tool reference](<{{crucible_root}}/powershell/new-handoff.ps1>)

Timestamp format: `yyyyMMddTHHmmssZ` (UTC) - e.g., `{task_id}-20260418T143022Z.json`
