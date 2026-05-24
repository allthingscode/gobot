# Handoff Protocol — Quick Reference

> **Source of Truth:** The complete handoff protocol including schema, workflow, circuit breaker validation, and Universal Handoff Output Template is maintained in **`docs/operating-manual.md`** and **`docs/policy.md`**.

## Handoff Schema (Quick Reference)

Formal definition: `schemas/handoff.schema.json`

```json
{
  "task_id": "F-XXX",
  "source_specialist": "architect",
  "target_specialist": "reviewer",
  "reason": "Implementation complete, ready for validation",
  "handoff_retry_count": 0,
  "review_strike_count": 0,
  "budget_tier": "low",
  "cumulative_handoff_count": 3,
  "prompt_version": "architect_prompt-v20",
  "suspicious_content": null,
  "session_cycle_id": "{cycle_id from task.md}",
  "artifacts": ["src/agent/agent.go"]
}
```

Path: `.crucible/session/handoffs/{task_id}-{timestamp}.json`

## Mandatory Persona Sequence

1. **Groomer** → Triage & spec
2. **Architect** → Design & implementation
3. **Reviewer** → Validation (MUST approve before deploy)
4. **Operator** → Deployment (final gate)

**Standard Handoffs**:
- `Groomer` → `Architect` (implementation)
- `Architect` → `Reviewer` (review required)
- `Reviewer` → `Operator` (approved for deploy)
- `Reviewer` → `Architect` (fix blockers)
- `Operator` → `Done` (pipeline resolved) or `Groomer` (if production issue threshold met)

## Circuit Breaker Rules (Canonical in POLICY.md)

1. **Review Strike Rule**: 3 failed review cycles → BLOCK.
2. **Handoff Retry Limit**: > 2 consecutive retries to same role → BLOCK.
3. **Token Budget Enforcement**: 6/10/16 handoffs based on `budget_tier`.
4. **Merge Conflict Limit**: > 3 rebase attempts → BLOCK.
5. **Verification Failure**: `go test` failure after Reviewer approval → BLOCK.

## Universal Handoff Output Template

Every specialist MUST end their response with this format:

```markdown
### [SPECIALIST ROLE] TASK COMPLETE

- **Item**: [Task ID] - [Brief Title]
- **Status**: [Current Status]
- **Artifacts**: [Files updated/created]
- **Next Priority**: [Next task ID if applicable]

[1-2 sentence summary]

Next step:
Run `{{crucible_root}}/powershell/factory.ps1 -Init -TaskId {task_id}` to generate the next command and initialize the workspace.
```

## Git Ownership & Boundaries (MANDATORY)

To prevent accidental state pollution and ensure proper review cycles, Git operations are strictly partitioned by persona:

- **ARCHITECT / RESEARCHER / GROOMER**: YOU ARE STRICTLY FORBIDDEN FROM RUNNING `git commit` OR `git push`. You must implement changes and leave them in the working directory (uncommitted). Your turn ends with uncommitted modifications.
- **REVIEWER**: You review the uncommitted changes in the working directory. Do not commit.
- **OPERATOR**: Only the Operator persona (or the human) is authorized to stage (`git add`), commit (`git commit`), and push (`git push`) code changes.

## Agent Execution Boundaries

Agents **construct and write `handoff.json`** but do **not** generate the next command themselves. Instead, the agent executes the **Factory Orchestrator Script** (`{{crucible_root}}/powershell/factory.ps1 -Init -TaskId {task_id}`) which validates the handoff, initializes the workspace (worktrees, task scratchpads), and generates the deterministic next prompt from a template.

### Usage:
1. Agent completes task.
2. Agent writes `.crucible/session/handoffs/{task_id}-{timestamp}.json`.
3. Agent runs `factory.ps1 -Init -TaskId {task_id}` via the Bash tool (**`-TaskId` is required**):
   ```bash
   powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id}
   ```
4. Agent presents the factory output to the human (summary of what was done, verbatim `[NEXT SESSION COMMAND]` block, recommended model) and **waits for human confirmation** before the next specialist session begins. The human may continue in this session or take the command to a different session.

## Session State Management

- All specialists update `session/global/session_state.json` after each phase
- Write `handoffs/{task_id}-{timestamp}.json` before ending session
- Read `handoff.schema.json` and validate before handoff
- Do NOT manually delete `task.md` — `factory.ps1 -Init` handles stale file cleanup automatically
- Read `handoffs/*.json` on session start (via `{{crucible_root}}/powershell/factory.ps1 -Init -TaskId {task_id}`)
- The `factory.ps1 -Init -TaskId {task_id}` command automatically clears stale locks and task files.

---

**For complete protocol details including state recovery, crash resilience, and deployment checklist: see `OPERATING_MANUAL.md`**
