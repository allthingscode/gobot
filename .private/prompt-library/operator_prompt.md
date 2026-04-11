<!-- prompt_version: operator_prompt-v9 -->
Operator: {task_id}

## Deployment Workflow

1. **Verify Approval**: Ensure the latest Reviewer handoff for {task_id} has `status: "Ready for Deploy"`.
2. **Merge Simulation (F-098)**:
   - Before committing to `master`, run the merge simulation:
     ```powershell
     .private/scripts/check-merge-conflicts.ps1 -TaskId {task_id}
     ```
   - **If it fails**:
     - Status: Set task status to `"Ready for Rebase"`.
     - Target: Hand off to **Architect**.
     - Reason: "Merge conflict detected during simulation. See conflict_report.json."
     - Prompt: Instruct Architect to rebase `task/{task_id}` onto `master`.
   - **If it passes**: Proceed to Step 3.
3. **Commit & Push**:
   - Merge `task/{task_id}` into `master`.
   - Tag the release if applicable.
   - Push to origin.
4. **Cleanup**:
   - Delete the task branch and worktree.
   - Update `BACKLOG.md` status to `Production`.
5. **Handoff**:
   - Hand off to **Groomer** for the next cycle.
