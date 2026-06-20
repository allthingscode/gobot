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

> **Cross-platform note.** Examples below use `powershell.exe` and a Windows
> source path. On Linux/macOS, replace `powershell.exe` with `pwsh` and use a
> Unix path (e.g. `~/src/crucible-source`). Forward-slash paths work on every
> platform.

The source repo is used only for installs and updates. It is not referenced at runtime.

---

## Previewing Customization Drift

Before pulling updates, you can inspect your local `.crucible/` customizations compared to your baseline (recorded at install or the last successful update) using the drift-detection tool:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".crucible/powershell/factory-status.ps1" -Drift
```

This is a read-only command that classifies all files into:
- **pristine**: unchanged framework files.
- **customized**: framework files edited by the adopter.
- **adopter-added**: new files created in framework scan directories.
- **framework-removed**: files in the manifest but missing on disk.

It exits with code `0` when no customized files exist, and `1` if customizations or drift-detection errors are detected.

### Backfilling Provenance Manifest
Crucible uses a provenance manifest (`.crucible/install-provenance.json`) to track files. If this manifest is missing (e.g. from an older install version), the drift tool automatically backfills it in memory using the `crucible_install_commit` from your `config.yaml`. To do this, it requires access to the upstream Crucible source repository containing that commit:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".crucible/powershell/factory-status.ps1" -Drift -FrameworkSource "C:\path\to\crucible-source"
```

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
   powershell.exe -ExecutionPolicy Bypass -File ".crucible/powershell/run-all-tests.ps1"
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

## Preserving Custom Regions

For files that you must edit but still want to keep tracking upstream updates, Crucible supports marked custom regions:

```powershell
# >>> CRUCIBLE-CUSTOM
# your custom logic here
# <<< CRUCIBLE-CUSTOM
```

When `update-bundle.ps1` runs:
- If a file has modifications only within these custom regions, it is classified as `safe-overwrite` or `no-op`.
- During update application, the updater merges the local custom region content with the upstream framework changes, preserving your customizations.
- If a file has modifications outside the custom regions, it is classified as `needs-merge` for manual resolution.

---

## Manual copy fallback

Use manual copying only when you intentionally want a single upstream file outside the normal updater flow. Read the upstream diff first, copy only the file you want, re-apply any local customization, and run verification before committing.

---

For the initial install, see [get-started.md](get-started.md).
