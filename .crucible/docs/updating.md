# Updating Your Installed Crucible Bundle

Your installed `.crucible/` bundle is self-contained and belongs entirely to your project. Upstream changes are never pulled automatically. You decide when to classify, apply, and commit them.

---

## When to update

Consider pulling upstream changes when:

- A bug fix in the framework scripts (`powershell/`) affects your workflow.
- New specialist behavior (personas, SOPs, prompt templates) is worth adopting.
- A schema change (`schemas/`) affects validation you rely on.
- New documentation clarifies something your team keeps asking about.

There is no obligation to stay current. Your bundle is stable by design.

---

## Where the source lives

The upstream Crucible source repository is the canonical place to pull changes from. Clone or pull it to a local path:

```powershell
git clone <crucible-upstream-url> C:\path\to\crucible-source
# or, if already cloned:
git -C C:\path\to\crucible-source pull
```

The source repo is used only for installs and updates. It is not referenced at runtime.

---

## Supported update workflow

1. **Update your source checkout.**

   ```powershell
   git -C C:\path\to\crucible-source pull
   ```

2. **Stamp older installs once.** If `.crucible/config.yaml` does not contain `crucible_install_commit`, establish a baseline before updating:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\crucible-source\powershell\init-project.ps1" `
     -ProjectRoot . `
     -StampVersionOnly
   ```

   Re-run with `-Force` only when you intentionally want to refresh existing `crucible_version` and `crucible_install_commit` metadata.

3. **Preview the update.** Run the updater in report mode from your project root:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\crucible-source\powershell\update-bundle.ps1" `
     -FrameworkSource "C:\path\to\crucible-source" `
     -AdopterRoot . `
     -Mode report-only
   ```

4. **Apply safe updates.** When the report looks right, apply files that have no local adopter edits:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\crucible-source\powershell\update-bundle.ps1" `
     -FrameworkSource "C:\path\to\crucible-source" `
     -AdopterRoot . `
     -Mode auto-safe
   ```

   `safe-overwrite` files are copied from upstream because they still match your recorded baseline. `add` files are new upstream files and are copied too. `needs-merge` and `review-removal` files are reported for human review and are not auto-changed.

5. **Manually merge anything flagged.** For each `needs-merge` item, compare your local file against upstream HEAD, then edit the adopter file by hand.

6. **Verify.** Run your bundle's test suite from your project root:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File ".crucible\powershell\run_all_tests.ps1"
   ```

7. **Commit.** Treat the update like any other change: review, test, commit.

---

## What the updater will not overwrite

`update-bundle.ps1` never auto-touches adopter-owned paths:

- `config.yaml`
- `backlog/`
- `session/`
- `research/`
- `.gemini/`
- `.private/`
- `.agent-workspaces/`
- Anything ignored by the adopter repo under `.crucible/`

For customized framework files, the updater uses the recorded `crucible_install_commit` to distinguish safe upstream changes from local edits that need manual merge.

---

## Manual copy fallback

Use manual copying only when you intentionally want a single upstream file outside the normal updater flow. Read the upstream diff first, copy only the file you want, re-apply any local customization, and run verification before committing.

---

For the initial install, see [GET_STARTED.md](GET_STARTED.md).
