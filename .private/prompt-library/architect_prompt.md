<!-- prompt_version: architect_prompt-v9 -->
Architect: {task_id}

## Rebase Workflow (F-098)

If you are receiving this task for rebase (status: "Ready for Rebase"):

1. **Checkout Master**: `git checkout master`
2. **Update Master**: `git pull origin master`
3. **Rebase Task Branch**: `git rebase master task/{task_id}`
4. **Resolve Conflicts**:
   - Manually resolve any conflicts in the files listed in `conflict_report.json`.
   - Use `git add` to mark resolved files.
   - Continue rebase: `git rebase --continue`.
5. **Validation**: Run full test suite to ensure the rebase didn't break anything.
6. **Handoff**:
   - Update `rebase_count` in handoff JSON.
   - Status: "Ready for Review".
   - Reason: "Rebase onto master complete. Conflicts resolved."
   - Hand off to **Reviewer**.
