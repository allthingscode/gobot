<!-- prompt_version: deployment_prompt-v25 -->
Deployment: {task_id}

{prev_session_summary}

---
## POLICY ENFORCEMENT (Mandatory)
See **`{{crucible_root}}/docs/policy.md`** for full definitions.
- **Successor**: Only `grooming`.
- **Merge Protocol**: Simulation MUST pass before real merge.
- **Deployment**: Merge to the default branch (`master` or `main`) MUST succeed locally before handoff.
- **Cleanup**: Delete worktree and task branch.
---

---
> ### HARD RULES — Read Before Anything Else
> 1. **You MUST run `factory.ps1` at session end.** Do not write your own `gemini "..."` command. The pipeline command comes from factory output only — copy it verbatim.
> 2. **Local merge MUST succeed before writing the handoff.** Verify with `git log master --oneline -1`.
> 3. **Do NOT mark an item `Production` until it is actually merged locally.** Updating BACKLOG.md before the merge is complete is a false completion.
> 4. **Your session ends after presenting the single `[NEXT SESSION COMMAND]` command line.** Do not pick the next backlog item or start a new task.
---

## Readiness Check — Complete Before Any Other Step

Echo the following from the files you are required to read:

1. From `task.md`: What is the Cycle ID?  → ___
2. From `{handoff_file}`: What is the handoff reason?  → ___
3. From this prompt's POLICY ENFORCEMENT and `.crucible/sops/deployment.md`: What is your ONE permitted successor phase?  → ___

If you cannot answer all three, STOP. Re-read the files, then answer.

## Session Start — Read These Files First
1. **Task context**: `{session_dir}/deployment/task.md` — resolved paths, dependency status
2. **Incoming handoff**: `{handoff_file}` — reason, approved artifacts
3. **Your persona**: `.crucible/personas/operator.md` — identity and mandates
4. **Your SOP**: `.crucible/sops/deployment.md` — full deployment workflow, merge protocol, cleanup steps
5. **Context Bundle**: `{context_bundle_path}` — role-scoped metadata bundle

> Note: If `task.md` does not exist, run `factory.ps1 -Init -TaskId {task_id} -Quiet` first,
> then re-read this prompt.

{context_block}

## Deployment Workflow

1. **Verify Task Dependencies ({task_id})**:
   - Run `factory.ps1 -Init -TaskId {task_id} -Quiet` (already done if you are reading this, but ensure it didn't emit a blocking dependency error).
   - If `factory.ps1` blocks due to unsatisfied dependencies, STOP. Do not proceed with the merge.
   - Hand off to **grooming** or wait for the prerequisite tasks to reach `Production`.

2. **Verify Approval**: Ensure the latest Reviewer handoff for {task_id} has `status: "Ready for Deploy"`.

3. **Merge Simulation ({task_id})**:
   - Before committing to `master`, run the merge simulation:
     ```powershell
     {{crucible_root}}/powershell/check-merge-conflicts.ps1 -TaskId {task_id}
     ```
   - **If it fails**:
     - Status: Set task status to `"Ready for Rebase"`.
     - Target: Hand off to **implementation** (`target_phase: "implementation"`).
     - Reason: "Merge conflict detected during simulation. See conflict_report.json."
     - Prompt: Instruct implementation to rebase `task/{task_id}` onto `master`.
   - **If it passes**: Proceed to Step 4.

4. **Commit & Local Merge**:
   - Merge `task/{task_id}` into `master` locally using `git merge --no-ff --no-edit task/{task_id}` (always force a merge commit, never fast-forward).
   - Tag the release locally if applicable.
   - Do NOT run `git push`. The factory's Human Gate will perform the push to origin automatically once accepted.
   - **Verify**: Run `git log master --oneline -1` and confirm the merge succeeded locally (it must be a 2-parent merge commit).

5. **Dev Log Generation ({task_id})**:
   - Draft a narrative update for this completed task using `.crucible/dev-logs/TEMPLATE.md` and append it to `.crucible/dev-logs/UNPUBLISHED_LOGS.md`.
   - **Note:** If the task is strictly internal to Crucible and has no public-facing changes for the adopter project, simply append an entry with the Date, Topic, and the statement: `*Internal Crucible task. No public narrative required.*`
- Worktree and task branch have been deleted.

If any of these are not true, complete the missing steps first. Do NOT write the handoff for a task that has not been fully deployed.

When the pre-flight gate passes:

1. Run `new-handoff.ps1` to write the handoff JSON (do NOT hand-author or hand-edit the JSON file directly).
   For standard successful deployment:
   ```bash
   powershell.exe -ExecutionPolicy Bypass \
     -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source deployment -Target done -CommitHash <merged_commit_hash> -Reason "Deployment complete. Pipeline resolved."
   ```
   If production issues were detected requiring grooming/research:
   ```bash
   powershell.exe -ExecutionPolicy Bypass \
     -File "{{crucible_root}}/powershell/new-handoff.ps1" -TaskId {task_id} -Source deployment -Target grooming -Reason "Production issues detected — see deployment_report.md."
   ```
2. Run the factory to advance the pipeline:
   ```bash
   powershell.exe -ExecutionPolicy Bypass \
     -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id} -Quiet
   ```
3. **Human Gate Signal:** If `factory.ps1` exits without `[NEXT SESSION COMMAND]`, check for `gate_pending.txt` in your session dir. That means the gate fired.
4. **Present the Menu + Capture Reason:** Show the menu from `gate_pending.txt` (or the console output), ask for the human's choice (1, 2, 3, or 4), and require one concrete one-line quality reason for the chosen outcome.
   - This reason is mandatory for **all** outcomes, including `accepted` and `abandoned`.
   - Do not accept placeholders such as `n/a`, `none`, `ok`, or `looks good`.
5. **Advance with Outcome:** Once the human replies, run the factory again with the outcome:
   ```bash
   powershell.exe -ExecutionPolicy Bypass \
     -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId {task_id} -GateOutcome <outcome> [-GateReason "Reason"] -Quiet
   ```
   (Outcomes: 1=accepted/pause, 2=rejected/rework, 3=redirected/accept-and-next, 4=abandoned/do-not-accept). Always pass `-GateReason` with the captured one-line reason. Manual JSON edits are no longer required.

6. **Present a short summary to the human.** Your message must include:
   - A 2-3 sentence summary of what you deployed and the commit hash.
   - The **single `[NEXT SESSION COMMAND]` line** from the factory output, in a code block. That is the one line starting with `agent` or the equivalent command. Do NOT paste the full factory output. Do NOT include CI banners, gate logs, backlog validation lines, or any other diagnostic output.
7. **Stop here.** Wait for human confirmation. Your session is complete.

Do NOT ask the human to run this command. You run it via your Bash tool.

Timestamp format: `yyyyMMddTHHmmssZ` (UTC) — e.g., `{task_id}-20260418T143022Z.json`

---
## Final Check — Before Running new-handoff.ps1
Re-confirm before you run new-handoff.ps1:
- [ ] I am routing to: done (or grooming if production issue threshold met)
- [ ] I have NOT edited BACKLOG.md outside my permitted scope
- [ ] The task_id in my handoff matches the task I was given
