# Release Process

This is the convention Crucible maintainers follow when cutting a release. Adopters do not need to read this — see [updating.md](updating.md) for the adopter-side workflow.

---

## Versioning

Crucible follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html):

- **MAJOR** — breaking change to the adopter contract (schema-incompatible config changes, removed flags, renamed canonical paths, deleted public scripts).
- **MINOR** — backward-compatible additions (new flags, new docs, new optional config fields, additive schema changes).
- **PATCH** — backward-compatible bug fixes only.

Pre-1.0 (`0.x.y`): MINOR may include breaking changes. After `1.0.0`, MAJOR is required for any break.

---

## The version anchor

`VERSION` at the repository root is the single source of truth for the current Crucible version. It is read by:

- `powershell/init-project.ps1` when stamping `crucible_version` into a newly-scaffolded adopter config
- `powershell/factory.ps1` indirectly, via the stamped value in the adopter's `.crucible/config.yaml`

Bump `VERSION` BEFORE tagging. The tag references the commit that contains the new `VERSION`.

---

## Release checklist

1. **Settle the work.** All planned changes for this release are merged to `main`. Tests pass: `powershell/run_all_tests.ps1`.

2. **Update `CHANGELOG.md`:**
   - Promote the `## [Unreleased]` section to a versioned section: `## [X.Y.Z] - YYYY-MM-DD`.
   - Confirm each entry is grouped under Added / Changed / Fixed / Removed (Keep a Changelog format).
   - Add a fresh empty `## [Unreleased]` section above the new release.
   - Update the link references at the bottom of the file:
     ```
     [Unreleased]: https://github.com/allthingscode/crucible/compare/vX.Y.Z...HEAD
     [X.Y.Z]: https://github.com/allthingscode/crucible/releases/tag/vX.Y.Z
     ```

3. **Bump `VERSION`** to `X.Y.Z` (no `v` prefix; semver only).

4. **Commit:** `chore(release): vX.Y.Z` (single commit covering the CHANGELOG promotion + VERSION bump).

5. **Tag the commit** with an annotated tag:
   ```powershell
   git tag -a "vX.Y.Z" -m "Release vX.Y.Z"
   ```

6. **Push the commit and tag:**
   ```powershell
   git push origin main
   git push origin vX.Y.Z
   ```

7. **Verify** that a fresh `init-project.ps1` run on the new commit stamps the new version into the adopter's config:
   ```powershell
   .\powershell\init-project.ps1 -ProjectRoot $env:TEMP\release-smoke
   Select-String -Path "$env:TEMP\release-smoke\.crucible\config.yaml" -Pattern "crucible_version"
   # Should show: crucible_version: "X.Y.Z"
   ```

---

## What goes in CHANGELOG.md

- **User-visible behavior changes.** New flags, removed flags, changed defaults, new docs, removed docs.
- **Bug fixes that adopters would notice.** Include the fix commit hash for traceability.
- **Architectural commitments.** When `ROADMAP.md` changes, the next release mentions it.

What does NOT go in CHANGELOG:

- Internal refactors invisible to adopters (e.g. extracting a helper function with no behavior change).
- Test additions/fixes (unless they catch a bug that's also in the Fixed section).
- Doc typos and prose polish.

When in doubt: would an adopter pulling updates want to know? If yes, include it.

---

## Hotfix releases

If a `0.1.0` user hits a critical bug:

1. Branch from `v0.1.0`: `git checkout -b hotfix/v0.1.1 v0.1.0`
2. Fix on the branch.
3. Bump `VERSION` to `0.1.1`, update `CHANGELOG.md` (`## [0.1.1] - YYYY-MM-DD` with the fix entry), commit, tag `v0.1.1`.
4. Merge the hotfix branch back to `main` (preserves the fix for future releases).
5. Push branch + tag.

---

## Pre-release (alpha / beta / rc)

For pre-1.0 work this is rare, but the format is:

- `VERSION`: `0.2.0-alpha.1` (or `-beta.1`, `-rc.1`)
- Tag: `v0.2.0-alpha.1`
- `CHANGELOG.md` section: `## [0.2.0-alpha.1] - YYYY-MM-DD`

Pre-release tags do not become the basis for hotfix branches — they're cumulative drafts of the eventual `0.2.0`.
