# Uninstalling Crucible

To completely remove Crucible from your project, follow these steps:

1. **Delete the Crucible bundle**:
   Run the following to delete the `.crucible` folder:
   ```powershell
   Remove-Item -Recurse -Force .crucible
   ```
   If `.crucible/` was committed to Git, commit the removal to clean up your repository state:
   ```powershell
   git add -A .crucible/
   git commit -m "chore: remove Crucible bundle"
   ```

2. **Clean up instruction files**:
   Crucible appends its instructions inside sentinel markers in `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md`. If these files exist, open each and delete the blocks including the markers:
   ```html
   <!-- crucible-instructions-start -->
   ...
   <!-- crucible-instructions-end -->
   ```
   If a file does not exist, skip it. If a file was created by Crucible and is now empty, you can delete it.

3. **Backlog data (optional)**:
   If you have active or completed task specifications in your backlog directory that you wish to keep, make sure to export or move them before deleting the `.crucible/` folder.

4. **Residual git state**:
   Crucible creates temporary task branches and git worktrees under the ignored path `.crucible/`. Deleting the `.crucible/` folder automatically removes those folders. If you had active task worktrees during use, run `git worktree prune` to clean up stale worktree registrations under `.git/worktrees/`. No other global git configuration or hidden state is modified outside your repository.
