<!-- prompt_version: implementation-reference-v5 -->
> **Human Reference Only.** In the pipeline, agents are driven by `implementation_prompt.md`
> (loaded by `crucible.ps1`) and their `task.md`. This file documents the workflow for humans
> and for manual invocations made outside the pipeline.

# Implementation Phase Reference

The implementation phase is responsible for implementing features, fixing bugs, and performing significant refactors within the pipeline.

## 1. Pipeline-Driven Workflow (Primary)

In the automated pipeline, the implementation phase is driven by `crucible.ps1` using the `implementation_prompt.md` template.

### Process
Follow the [Implementation SOP](../sops/implementation.md) for session start, design, worktree edits, validation, commits and handoff to Verification.

## 2. Manual Workflow (Outside the Pipeline)

Use this workflow when invoking the implementation phase manually outside the automated pipeline (e.g., `Architect: Implement F-XXX`).

### Process
1. **Read the backlog item** from `.crucible/backlog/features/F-XXX.md`.
2. **Analyze context** by reading relevant code files.
3. **Create a plan** in the `.crucible/plans/` directory.
4. **Wait for approval**: Present the plan to the human and wait for an "Approved" signal before writing implementation code.
5. **Execute step-by-step**, updating plan progress.
6. **Finalize**: Follow [Handoff to Verification](../sops/implementation.md#phase-4-handoff-to-verification).

## Common Mistakes to Avoid

- **DO NOT** provide lengthy "what I did" summaries after implementation.
- **DO NOT** explain implementation details in the final response unless explicitly asked.
- **DO** keep intermediate responses concise (status updates only).
- **DO** ensure all work stays within the assigned worktree.

## Quick Reference

- **Prompt Template**: `prompts/implementation_prompt.md`
- **Backlog**: `.crucible/backlog/`
- **Isolated Worktrees**: `.agent-workspaces/implementation-{task_id}/`
- **Handoffs**: `.crucible/session/handoffs/`
