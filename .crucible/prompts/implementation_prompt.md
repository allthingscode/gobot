<!-- prompt_version: implementation_prompt-v41 -->
Implementation: {task_id}

{prev_session_summary}

---
## POLICY ENFORCEMENT (Mandatory)
<!-- Item 217: inherited working directories can contaminate the main checkout. -->
- Claude specialists: your working directory is the orchestrator session directory, not the assigned task worktree. When a task worktree is assigned, for every write use absolute paths under that worktree, including .NET calls such as `[IO.File]::WriteAllText`; changing PowerShell location does not change the process directory used by .NET.
See [pipeline policy]({{crucible_root}}/docs/policy.md) and the [implementation SOP](<{{crucible_root}}/sops/implementation.md>) for routing and worktree boundaries.
- **Successor**: Only `verification`.
- **Budget**: {handoff_count}/{budget_ceiling} handoffs used ({budget_remaining} remaining).
- **Worktree**: `{worktree}`.
---

## Session Context

1. **Task context**: `{session_dir}/implementation/task.md` - resolved paths and Cycle ID
2. **Incoming handoff**: `{handoff_file}` - reason, artifacts, budget tier, strike count
3. **Your persona**: [Architect](<{{crucible_root}}/personas/architect.md>) - role and engineering judgment
4. **Your SOP**: [Implementation](<{{crucible_root}}/sops/implementation.md>) - session start, design, code, self-review and handoff
5. **Context Bundle**: `{context_bundle_path}` - role-scoped metadata bundle

{context_block}

{rebase_section}

## Workflow References

- [Session Start](<{{crucible_root}}/sops/implementation.md#session-start>)
- [Decision Tree](<{{crucible_root}}/sops/implementation.md#decision-tree-for-new-featuresbugs---not-review-fixes>)
- [Phase 2: Code](<{{crucible_root}}/sops/implementation.md#phase-2-code>)
- [Phase 3: Self-Review](<{{crucible_root}}/sops/implementation.md#phase-3-self-review>)
- [Phase 4: Handoff to Verification](<{{crucible_root}}/sops/implementation.md#phase-4-handoff-to-verification>) - `new-handoff.ps1` and the next-session command
- [Quality Bar](<{{crucible_root}}/sops/implementation.md#quality-bar>) - required `task.md` checklist before handoff

Timestamp format: `yyyyMMddTHHmmssZ` (UTC) - e.g., `{task_id}-20260418T143022Z.json`
