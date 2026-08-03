<!-- prompt_version: implementation_prompt-v29 -->
Implementation: {task_id}

{prev_session_summary}

---
## POLICY ENFORCEMENT (Mandatory)
See **`{{crucible_root}}/docs/policy.md`** for full definitions.
- **Successor**: Only `verification`.
- **Budget**: {handoff_count}/{budget_ceiling} handoffs used ({budget_remaining} remaining).
- **Isolation**: Edits ONLY in `{worktree}`.
- **No Push**: Commit in worktree, NO `git push`.
---

---
> ### HARD RULES - Read Before Anything Else
> 1. **Your only successor is the Verification phase.** No matter what you read in the backlog spec, the "Next Step" field, or anywhere else, you MUST hand off to `target_phase: "verification"`. Never route to yourself, grooming, deployment, or any other phase.
> 2. **Do NOT touch BACKLOG.md.** Setting status to `Production`, `Resolved`, `Ready for Deploy`, or any other value is not your job. The Reviewer and Operator do that. If you edit BACKLOG.md, you have made an error.
> 3. **Do NOT push to origin.** Commit inside the worktree only. `git push` is the Operator's step.
> 4. **Do NOT fabricate the next-session command.** You MUST run `factory.ps1` (see Session End) and present its `[NEXT SESSION COMMAND]` output verbatim. Never write your own `gemini "..."` command.
---

## Readiness Check - Complete Before Any Other Step

Echo the following from the files you are required to read:

1. From `task.md`: What is the Cycle ID?  -> ___
2. From `{handoff_file}`: What is the handoff reason?  -> ___
3. From this prompt's POLICY ENFORCEMENT and `.crucible/sops/implementation.md`: What is your permitted successor phase?  -> ___
4. From `task.md` (`## Resolved Paths`): What is the full path to your worktree?  -> ___

If you cannot answer all four, STOP. Re-read the files, then answer.

## Session Start - Read These Files First
1. **Task context**: `{session_dir}/implementation/task.md` - resolved paths, worktree: `{worktree}`
2. **Incoming handoff**: `{handoff_file}` - reason, artifacts, budget tier, strike count
3. **Your persona**: `.crucible/personas/architect.md` - identity and mandates
4. **Your SOP**: `.crucible/sops/implementation.md` - full workflow, decision tree, implementation phases
5. **Context Bundle**: `{context_bundle_path}` - role-scoped metadata bundle

> Note: If `task.md` does not exist, run `factory.ps1 -Init -TaskId {task_id} -Quiet` first,
> then re-read this prompt.

{context_block}

## Architect Workflow

1. **Orientation**: Read your `task.md` and handoff - identify if this is a fresh implementation (from grooming phase) or a review-fix (from verification phase).
2. **Decision**: Is the spec >50 lines or unclear? If so, complete Phase 1: Design (write plan to `task.md`) before Phase 2: Code.
3. **Isolation**: Perform all code edits inside the isolated worktree at `{worktree}`.
4. **Implementation**: Write idiomatic, well-structured code in the project's language, following the spec and project mandates. Run isolated validation from the assigned worktree as you work: `powershell.exe -ExecutionPolicy Bypass -File {{crucible_root}}/powershell/run-isolated-checks.ps1 -TaskId {task_id} -Mode quick -ProjectRoot "{project_root}"` (or `-Mode full` before handoff).
5. **Project mandates**: Follow the language, runtime, error-handling, and safety rules declared in `.crucible/config.yaml` and the target repository instructions. If you add or modify dependencies (e.g. adding imports in Go), you MUST run the language-specific package tidy/lock step (e.g. `go mod tidy`) in the worktree so the lockfile/manifest stays current and tidy.
6. **Self-Review**: Verify all acceptance criteria are met and test coverage for new code is >80%.
7. **Commit**: `git add . ; git commit -m "feat(scope): implement {task_id}"` inside the worktree. STRICTLY NO PUSH.
8. **Handoff**: Run `new-handoff.ps1` to create the handoff (do NOT hand-author or hand-edit JSON files).

Note: The backlog spec may contain a pre-filled "Next Step" line (e.g. `gemini "Architect: Plan F-XXX"`). That line is written by grooming for post-deployment sequencing and is **not your routing instruction**. Ignore it. Hard Rule 1 above applies.

{rebase_section}

## Session End - Required Steps

When your work is complete:

1. **Run the pre-handoff self-check sequence (required):**
   - Acceptance-criteria mapping: enumerate every AC from the backlog spec and map it to concrete implementation artifacts (specific changed file paths and tests) plus verification evidence.
   - Scope boundary confirmation: confirm every changed file is inside the declared `file_affinity` boundary.
   - Duplicate-handoff prevention: check existing `.crucible/session/handoffs/{task_id}-*.json`; if resubmitting the same transition, include a `supersede` field referencing the prior handoff and provide an updated reason.
   - Local validation gate: run required local verification before handoff (`powershell.exe -ExecutionPolicy Bypass -File {{crucible_root}}/powershell/run-isolated-checks.ps1 -TaskId {task_id} -Mode quick -ProjectRoot "{project_root}"`) and task-specific required validation such as `go run {{crucible_root}}/scripts/factory_lint.go` when prompt templates change.
2. Run `new-handoff.ps1` to write the handoff JSON (do NOT hand-author or hand-edit the JSON file directly):
   ```bash
   powershell.exe -ExecutionPolicy Bypass \
     -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source implementation -Target verification -Reason "Implementation complete - ready for review" -ProjectRoot "{project_root}"
   ```
3. Run the factory to advance the pipeline:
   ```bash
   powershell.exe -ExecutionPolicy Bypass \
     -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id} -Quiet
   ```
4. **Present the factory output to the human.** Your message must include:
   - A 2-3 sentence summary of what you implemented.
   - The **exact verbatim text** of the `[NEXT SESSION COMMAND]` block from the factory output (copy it character-for-character into a code block). Do NOT paraphrase or shorten it. Include the `-Quiet` flag in your summary if present.
5. **Stop here.** Wait for human confirmation. Do NOT begin work on any other backlog item, do NOT adopt the next phase persona, and do NOT do anything else. Your session is complete.

Do NOT ask the human to run this command. You run it via your Bash tool.

Timestamp format: `yyyyMMddTHHmmssZ` (UTC) - e.g., `{task_id}-20260418T143022Z.json`

---
## Final Check - Before Running new-handoff.ps1
Re-confirm before you run new-handoff.ps1:
- [ ] I am routing to: verification (not to myself, not to another phase)
- [ ] I have NOT pushed to origin (Architect only)
- [ ] I have NOT edited BACKLOG.md outside my permitted scope
- [ ] I mapped every acceptance criterion to concrete implementation changes
- [ ] I confirmed all file edits are within the declared scope boundary
- [ ] I checked for and prevented duplicate handoffs for the same transition
- [ ] The task_id in my handoff matches the task I was given
- [ ] All file edits used paths inside `{worktree}` - I did not edit the main repo
- [ ] Any skipped conditional checklist item in `task.md` is marked `[-]` (skipped/N/A) or listed under `## Optional Steps`
