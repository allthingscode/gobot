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

> **Cross-platform note.** Examples below use `pwsh` (PowerShell 7+) and a
> Windows source path. On Linux/macOS, use a Unix path (e.g.
> `~/src/crucible-source`). Forward-slash paths work on every platform.

The source repo is used only for installs and updates. It is not referenced at runtime.

---

## Previewing Customization Drift

Before pulling updates, you can inspect your local `.crucible/` customizations compared to your baseline (recorded at install or the last successful update) using the drift-detection tool:

```powershell
pwsh -ExecutionPolicy Bypass -File ".crucible/powershell/crucible-status.ps1" -Drift
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
pwsh -ExecutionPolicy Bypass -File ".crucible/powershell/crucible-status.ps1" -Drift -FrameworkSource "C:\path\to\crucible-source"
```

---

## Supported update workflow

1. **Update your source checkout.**

   ```powershell
   git -C C:\path\to\crucible-source pull
   ```

2. **Stamp older installs once.** If `.crucible/config.yaml` does not contain `crucible_install_commit`, establish a baseline before updating:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File "C:\path\to\crucible-source\powershell\init-project.ps1" `
     -ProjectRoot . `
     -StampVersionOnly
   ```

   Re-run with `-Force` only when you intentionally want to refresh existing `crucible_version` and `crucible_install_commit` metadata.

3. **Preview the update.** Run the updater in report mode from your project root:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File "C:\path\to\crucible-source\powershell\update-bundle.ps1" `
     -FrameworkSource "C:\path\to\crucible-source" `
     -AdopterRoot . `
     -Mode report-only
   ```

4. **Apply safe updates.** When the report looks right, apply files that have no local adopter edits:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File "C:\path\to\crucible-source\powershell\update-bundle.ps1" `
     -FrameworkSource "C:\path\to\crucible-source" `
     -AdopterRoot . `
     -Mode auto-safe
   ```

   `safe-overwrite` files are copied from upstream because they still match your recorded baseline. `add` files are new upstream files and are copied too. `retired` files are deleted: Crucible renamed them, the replacement is landing in this same update, and your copy still matched the baseline. `needs-merge` and `review-removal` files are reported for human review and are not auto-changed.

   A real apply, prune, restamp-only, or all-no-op run also runs the installed `.crucible/powershell/install-hooks.ps1`. `core.hooksPath` is local uncommitted config, so a clone or an unset leaves copied hooks inert until something sets it. A clone whose bundle is already current still heals: the run classifies all-no-op and activates hooks without restamping. Preview (`report-only`) does not.

   A file you have edited is never retired, whatever the rename says. It is reported as `needs-merge` so you can move your changes to the new path yourself.

5. **Manually merge anything flagged.** For each `needs-merge` item, compare your local file against upstream HEAD, then edit the adopter file by hand.

6. **Verify.** Run your bundle's test suite from your project root:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File ".crucible/powershell/run-all-tests.ps1"
   ```

7. **Commit.** Treat the update like any other change: review, test, commit.

---

## The update log

Every run writes its classification report to `.crucible/session/update-bundle/{timestamp}.log`
and prints the path. The timestamp is UTC `yyyyMMdd-HHmmss`, so the directory sorts oldest to
newest by name.

**Retention: the newest 20 logs, counting the one the run just wrote.** A normal update
produces two - the preview and the apply - so twenty is about the last ten updates. Anything
older is deleted at the end of each run, and the run says how many it removed. The directory
is inside `session/`, which the bundle `.gitignore` excludes, so none of this is committed.

Logs written before 2026-09-09 landed in the root of `.crucible/session/` as
`update-bundle-{timestamp}.log`, where nothing pruned them and they buried the per-task
directories an operator lists to orient. The next run moves them into
`session/update-bundle/` and reports how many it moved; retention then applies to them like
any other log. There is nothing to do by hand.

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
- Anything ignored by the adopter repo under `.crucible/`, except the scaffold snapshot under `.crucible/templates/project/.crucible/` (see below)

For customized framework files, the updater uses the recorded `crucible_install_commit` to distinguish safe upstream changes from local edits that need manual merge.

---

## Scaffold content and how to decline it

Files under `.crucible/templates/project/.crucible/` in the source repo are the **scaffold**. Each one reaches your bundle twice:

- as a **snapshot**, at the same path (`.crucible/templates/project/.crucible/README.md`) - this is framework-owned reference material and is always restored if missing;
- as an **instantiated** copy, at the bundle root (`.crucible/README.md`) - this is seed material for your project to own and edit.

`update-bundle.ps1` creates instantiated scaffold files that are absent, including ones added upstream after you installed. When it does, it names them:

```
Instantiated 1 scaffold file(s) into your bundle:
  .crucible/agent-instructions/AGENTS.md
```

If the path was already shipped at your recorded baseline, the wording changes, because the likely cause is that you deleted it:

```
Recreated 1 scaffold file(s) that are missing from your bundle:
  .crucible/agent-instructions/AGENTS.md
```

Both notices appear on `-Mode report-only` and `-DryRun` runs too, phrased as "Would instantiate" / "Would recreate", so a preview tells you which paths are yours to decline before anything is written.

**Deleting an instantiated scaffold file is not an opt-out.** The updater decides what to write purely from presence on disk: a missing file is restored, full stop. The two wordings above come from the provenance manifest and change nothing about that - a deleted file is recreated on the next update and on every update after that.

To decline a scaffold file permanently, delete it **and** ignore its path in your repo:

```powershell
Remove-Item .crucible/agent-instructions/AGENTS.md
Add-Content .gitignore ".crucible/agent-instructions/AGENTS.md"
```

The updater consults `git check-ignore` for instantiated paths, so full gitignore syntax works - directory patterns (`.crucible/agent-instructions/`), globs, and negations. The declaration lives in a file you own, survives updates, and shows up in a diff.

Two limits worth knowing:

- The exemption does not apply to the snapshot under `.crucible/templates/project/.crucible/`. Ignoring a snapshot path does not stop it being restored; that content is framework-owned.
- Ignoring a path means you get no file at all. There is currently no way to keep an instantiated scaffold file present but untracked.

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

> **Gotcha: a no-op `update-bundle` run does NOT re-stamp `crucible_install_commit`
> unless you pass `-Restamp`.**
> The updater only rewrites `crucible_install_commit` and `install-provenance.json`
> when it actually applies or prunes at least one file. If you hand-copy upstream
> files into the bundle yourself (manual fallback above) and then run
> `update-bundle` to "record" them, the run classifies everything as `no-op`, so the
> re-stamp block never fires and the recorded commit stays behind. The bundle then
> reports stale via the `bundle.staleness` advisory even though its content is
> current. Pass `-Restamp` to advance `crucible_install_commit` and regenerate
> `install-provenance.json` to the framework HEAD on an otherwise all-no-op run:
>
> ```powershell
> .crucible/powershell/update-bundle.ps1 -FrameworkSource <crucible> -AdopterRoot . -Mode auto-safe -Restamp
> ```
>
> `-Restamp` is refused (with a message, no write) if any file still needs
> apply/prune/merge - run a normal update first so it cannot mark a bundle current
> while it is missing real upstream changes. Prefer letting `update-bundle` apply
> upstream files in the first place rather than hand-copying.

---

## Migrating Existing Adopters (2026-08-10 Gitignore Anchoring & Scaffold Snapshot)

Existing adopters installed prior to 2026-08-10 may have an unanchored `.crucible/.gitignore` and a nested scaffold snapshot (`.crucible/templates/project/.crucible/`) where backlog files were ignored during `git add -A`.

To migrate an existing adopter repository:

1. **Update bundle files from upstream:**
   Run the updater from your project root:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File "C:\path\to\crucible-source\powershell\update-bundle.ps1" `
     -FrameworkSource "C:\path\to\crucible-source" `
     -AdopterRoot . `
     -Mode auto-safe `
     -Prune
   ```

   Run the source checkout's copy of `update-bundle.ps1`, not your bundled `.crucible/powershell/update-bundle.ps1`. Your bundled copy predates this change and would classify the live `.crucible/.gitignore` for removal, deleting it.

   This replaces `.crucible/.gitignore` with the anchored version and prunes the retired `.crucible/templates/project/.crucible/.gitignore` snapshot file while installing `.crucible/templates/project/.crucible/gitignore`. Confirm `.crucible/.gitignore` still exists on disk before proceeding.

2. **Force-add any untracked scaffold snapshot files:**
   Because git ignored nested backlog files under `.crucible/templates/project/.crucible/` in older commits, force-stage all snapshot files so your repository tracks the complete scaffold:
   ```powershell
   git add -f .crucible/templates/project/.crucible
   ```

3. **Verify and commit:**
   Run `.crucible/powershell/run-all-tests.ps1` and verify `git ls-files .crucible/templates/project/.crucible` returns as many tracked files as `git ls-files templates/project/.crucible` returns in the source checkout. Then commit the updated bundle.

---

## Migrating Existing Adopters (2026-09-09 Project Scorecard Moves Out Of `research/`)

The adopter-project audit scorecard used to live at
`.crucible/research/scorecard-{project}.md`. The bundle's own `.gitignore` excludes
`research/`, so that file was never committed: never reviewed, and gone from a fresh clone
with nothing left to say what the audit used to require. Audit reports are output and still
belong in `research/`. The scorecard is the standard they are written against, so it belongs
in git.

Updating installs `.crucible/standards/scorecard-TEMPLATE.md`, and
`.crucible/sops/research-audit-project.md` now reads
`.crucible/standards/scorecard-{project}.md`. After updating, move your copy:

```powershell
Move-Item ".crucible\research\scorecard-<project>.md" ".crucible\standards\"
git add .crucible/standards
```

Use `git mv` instead if your repository already tracks the old copy.

**Leaving it where it is also works.** The audit SOP reads the old path when it finds a
scorecard only there, and records in its report that the file needs to move. Nothing breaks;
the scorecard simply stays untracked, which is the condition this change exists to end.

---

For the initial install, see [get-started.md](get-started.md).

