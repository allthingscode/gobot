<!-- prompt_version: implementation-reference-v3 -->
> **Human Reference Only.** In the factory pipeline, agents are driven by `implementation_prompt.md`
> (loaded by `factory.ps1`) and their `task.md`. This file documents the workflow for humans
> and for manual (non-factory) invocations.

# Implementation Phase Reference

The implementation phase is responsible for implementing features, fixing bugs, and performing significant refactors within the Dev Factory pipeline.

## 1. Factory-Driven Workflow (Primary)

In the automated pipeline, the implementation phase is driven by `factory.ps1` using the `implementation_prompt.md` template.

### Process
1. **Context Initialization**: The agent is invoked with a command pointing to the latest handoff and an initialized `task.md`.
2. **Research & Strategy**: Read the incoming handoff from `.crucible/session/handoffs/` and the specialist's `task.md`.
3. **Execution**: Work exclusively inside the isolated worktree assigned to the task (e.g., `.agent-workspaces/implementation-{task_id}/`).
4. **No Approval Gate**: Unlike the manual workflow, the implementation phase in the factory pipeline proceeds directly to implementation based on the groomed backlog item and handoff instructions.
5. **Validation**: Run tests and workspace standards to confirm the success of the changes.
6. **Handoff**: Write the handoff JSON to `.crucible/session/handoffs/` and update the backlog item status to `"Ready for Review"`.
7. **Pipeline Advance**: Execute `factory.ps1 -Init -TaskId {task_id} -Quiet` via the Bash tool (PowerShell invocation — see OPERATING_MANUAL.md Session Protocol), present the factory output to the human: a brief summary of what was accomplished, the assembled next-specialist prompt, and which model is recommended. Wait for human confirmation before continuing — they may run the next step here or in a separate session.

## 2. Manual Workflow (Non-Factory)

Use this workflow when invoking the implementation phase manually outside the automated factory pipeline (e.g., `Architect: Implement F-XXX`).

### Process
1. **Read the backlog item** from `.crucible/backlog/features/F-XXX.md`.
2. **Analyze context** by reading relevant code files.
3. **Create a plan** in the `.crucible/plans/` directory.
4. **Wait for approval**: Present the plan to the human and wait for an "Approved" signal before writing implementation code.
5. **Execute step-by-step**, updating plan progress.
6. **Finalize**: Update backlog status to `"Ready for Review"`, write a handoff JSON, and instruct the human to run the factory script.

## Common Mistakes to Avoid

- **DO NOT** provide lengthy "what I did" summaries after implementation.
- **DO NOT** explain implementation details in the final response unless explicitly asked.
- **DO** keep intermediate responses concise (status updates only).
- **DO** ensure all work stays within the assigned worktree.

## Quick Reference

- **Factory Template**: `prompts/implementation_prompt.md`
- **Backlog**: `.crucible/backlog/`
- **Isolated Worktrees**: `.agent-workspaces/implementation-{task_id}/`
- **Handoffs**: `.crucible/session/handoffs/`
