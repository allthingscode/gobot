# Handoff Protocol — Quick Reference

> **Source of Truth:** The complete handoff protocol including schema, workflow, circuit breaker validation, and Universal Handoff Output Template is maintained in **`docs/operating-manual.md`** and **`docs/policy.md`**.

## Handoff Schema (Quick Reference)

Formal definition: `schemas/handoff.schema.json`

```json
{
  "task_id": "F-XXX",
  "source_phase": "implementation",
  "target_phase": "verification",
  "reason": "Implementation complete, ready for validation",
  "handoff_retry_count": 0,
  "review_strike_count": 0,
  "budget_tier": "low",
  "cumulative_handoff_count": 3,
  "prompt_version": "implementation_prompt-v27",
  "suspicious_content": null,
  "session_cycle_id": "{cycle_id from task.md}",
  "artifacts": ["src/agent/agent.go"]
}
```

Path: `.crucible/session/handoffs/{task_id}-{timestamp}.json`

## Mandatory Phase Sequence

1. **grooming** → Triage & spec
2. **implementation** → Design & implementation
3. **verification** → Validation (MUST approve before deploy)
4. **deployment** → Deployment (final gate)

**Standard Handoffs**:
- `grooming` → `implementation` (implementation)
- `implementation` → `verification` (review required)
- `verification` → `deployment` (approved for deploy)
- `verification` → `implementation` (fix blockers)
- `deployment` → `done` (pipeline resolved) or `grooming` (if production issue threshold met)

## Circuit Breaker Rules (Canonical in POLICY.md)

See [`docs/policy.md`](policy.md#2-circuit-breakers) §2 for the canonical list of breaker types, thresholds, and rules.

## Universal Handoff Output Template

Every specialist MUST end their response with this format:

```markdown
### [FSM PHASE] TASK COMPLETE

- **Item**: [Task ID] - [Brief Title]
- **Status**: [Current Status]
- **Artifacts**: [Files updated/created]
- **Next Priority**: [Next task ID if applicable]

[1-2 sentence summary]

Next step:
Run `{{crucible_root}}/powershell/factory.ps1 -Init -TaskId {task_id}` to generate the next command and initialize the workspace.
```

## Git Ownership & Boundaries (MANDATORY)

To prevent accidental state pollution and ensure proper review cycles, Git operations are strictly partitioned by phase:

- **implementation / research / grooming**: YOU ARE STRICTLY FORBIDDEN FROM RUNNING `git commit` OR `git push`. You must implement changes and leave them in the working directory (uncommitted). Your turn ends with uncommitted modifications.
- **verification**: You review the uncommitted changes in the working directory. Do not commit.
- **deployment**: Only the deployment phase (or the human) is authorized to stage (`git add`), commit (`git commit`), and push (`git push`) code changes.

## Agent Execution Boundaries

Agents **construct and write `handoff.json`** but do **not** generate the next command themselves. Instead, the agent executes the **Factory Orchestrator Script** (`{{crucible_root}}/powershell/factory.ps1 -Init -TaskId {task_id}`) which validates the handoff, initializes the workspace (worktrees, task scratchpads), and generates the deterministic next prompt from a template.

### Usage:
1. Agent completes task.
2. Agent writes `.crucible/session/handoffs/{task_id}-{timestamp}.json`.
3. Agent runs `factory.ps1 -Init -TaskId {task_id}` via the Bash tool (**`-TaskId` is required**):
   ```bash
   powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id}
   ```
   *(Linux/macOS: replace `powershell.exe` with `pwsh`.)*
4. Agent presents the factory output to the human (summary of what was done, verbatim `[NEXT SESSION COMMAND]` block, recommended model) and **waits for human confirmation** before the next phase session begins. The human may continue in this session or take the command to a different session.

## Session State Management

- All FSM phases update `session/global/session_state.json` after each phase
- Write `handoffs/{task_id}-{timestamp}.json` before ending session
- Read `handoff.schema.json` and validate before handoff
- Do NOT manually delete `task.md` — `factory.ps1 -Init` handles stale file cleanup automatically
- Read `handoffs/*.json` on session start (via `{{crucible_root}}/powershell/factory.ps1 -Init -TaskId {task_id}`)
- The `factory.ps1 -Init -TaskId {task_id}` command automatically clears stale locks and task files.

---

**For complete protocol details including state recovery, crash resilience, and deployment checklist: see `OPERATING_MANUAL.md`**
