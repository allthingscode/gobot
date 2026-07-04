# Proposal: Green adopter CI in the Definition of Done (post-merge CI gate)

Status: DRAFT (design only; not yet implemented)
Author: orchestrator dogfood
Related: gobot coverage-windows flake (fixed by gobot d8f09841); this closes the
process gap that let the red land on master unnoticed.

## Problem

The pipeline declares a task done the moment the Human Gate merges (and optionally
pushes) the task branch. It never consults the adopter's CI. So any failure that
only surfaces in CI -- a broken build, a lint/vet error, a platform-specific or
flaky test -- lands on the trunk and is caught by luck (a human noticing a red
check), not by the process.

Concrete instance: gobot's coverage-windows job went red on a post-merge push.
The identical code had passed on the merge commit; the failure was Windows-only
and nondeterministic, so local/Linux verification was green. Nothing in crucible
watched GitHub, so "done" and "trunk is red" were true at the same time.

Best-practice principle: **the trunk is always releasable; a task is not done
until the change it merged is green in CI.** Green CI belongs in the Definition
of Done, enforced by the machine, not by a human remembering to look.

## Current close-path (grounded)

`Invoke-HumanGateAction` in `powershell/lib/factory-gates.ps1` (accept branch):

1. `git checkout <primary>; git merge --no-ff --no-edit task/<id>` (~2372-2379)
2. If `review.auto_push == true` and `origin` exists: `git push origin <primary>`
   (~2387-2398). Otherwise the merge stays LOCAL and the operator pushes later
   (~2400-2402).
3. Remove worktree, delete branch, archive log + handoffs (~2404+).
4. Return success -> task done.

The gap is between step 2 (push) and step 4 (done): no wait for CI.

Two push modes to handle:
- `auto_push: true` -> the gate itself pushes; it can watch CI inline.
- `auto_push: false` (gobot today) -> CI only runs after the operator's manual
  push, which happens outside the gate. The watch must be runnable then too.

## Design

### New config: `review.require_green_ci` (default false, opt-in)

```yaml
review:
  auto_push: false
  require_green_ci: false      # optional; defaults to false
  ci_timeout_minutes: 20       # optional; defaults to 20
```

Advisory/opt-in so adopters without GitHub CI (or without `gh`) are unaffected,
mirroring how `auto_push` is gated. Read via `Get-ConfiguredReview`.

### New helper: `powershell/watch-adopter-ci.ps1` (ships + mirrors)

Thin, testable wrapper over `gh`:

- Params: `-Commit <sha>` (default: current `HEAD`), `-Repo` (default: origin's
  GitHub slug), `-TimeoutMinutes` (default 20), `-CrucibleRoot`.
- Preflight: if `gh` is absent or unauthenticated -> print
  `[CI WATCH] SKIPPED (gh unavailable)` and exit 0 (advisory). Never blocks an
  adopter that has no gh.
- Resolve the run: `gh run list --commit <sha> --json databaseId,status,conclusion`.
  Poll until every run for that commit reaches `completed`, or timeout.
- Classify and print one clear block, matching the launcher STATUS-not-label
  convention:
  - `[CI WATCH] STATUS=GREEN` -> all runs `success` (or `neutral`/`skipped`).
  - `[CI WATCH] STATUS=RED` -> any run `failure`/`timed_out`/`cancelled`; list the
    failed job names (`gh run view <id> --json jobs`).
  - `[CI WATCH] STATUS=PENDING_TIMEOUT` -> still running past the timeout.
  - `[CI WATCH] STATUS=NO_RUNS` -> no CI runs found for the commit (repo has no
    workflows, or push not yet propagated).
- Distinct exit codes (0 green/skipped, 1 red, 2 pending-timeout, 3 no-runs) so
  callers can branch. RED is the only "task not done" signal; SKIPPED/NO_RUNS are
  advisory and do not block (absence of CI is not failure).

### Wiring into the Human Gate

After a successful push in `auto_push: true` mode, if `require_green_ci`:

```
[HUMAN GATE] Watching origin CI for <sha> before finalizing...
watch-adopter-ci.ps1 -Commit <sha> -TimeoutMinutes <ci_timeout_minutes>
```

- GREEN/SKIPPED/NO_RUNS -> proceed to finalize (archive, done) as today.
- RED -> do NOT archive/close. Print the failed jobs and:
  `[HUMAN GATE] CI is RED for <sha>; task <id> is NOT done. Fix forward and
   re-run the gate, or investigate the run.` Leave the task in its pre-archive
  state so it is re-triable. (The merge stays on trunk -- we do not auto-revert;
  fix-forward is the norm. A future extension could offer `-RevertOnRed`.)
- PENDING_TIMEOUT -> advisory warning, do not block (CI slowness != task failure);
  print the run URL so the operator can watch it out of band.

For `auto_push: false`: the gate cannot watch CI it did not trigger. Instead it
prints, as part of the accept summary, the exact publish-then-verify sequence:

```
git push origin <primary>
pwsh -File .crucible/powershell/watch-adopter-ci.ps1 -Commit <primary-sha>
```

so "done" for a local-merge adopter explicitly includes a CI check the operator
runs after pushing. (This keeps the human in the loop without the gate blocking
on a push it never made.)

### Orchestrator SOP (`docs/orchestrators/CLAUDE.md` + mirror; `sops/orchestrator.md`)

Add to the Definition of Done / gate protocol: **a task that merges code to trunk
is not done until adopter CI for the merge commit is GREEN.** The orchestrator,
after any push of task work (gate auto-push or a manual publish it performs on the
user's behalf), runs `watch-adopter-ci.ps1` and treats STATUS=RED as "task not
done -- fix forward," never as an acceptance. This is the same STATUS-not-label
discipline used for Codex specialist verdicts.

## Tests (canonical; dev-only excluded from mirror)

- `powershell/tests/watch-adopter-ci.tests.ps1`: stub `gh` on PATH with shims for
  green, red (assert failed-job names surfaced), still-running (timeout ->
  PENDING_TIMEOUT), no-runs, and gh-absent (SKIPPED). Assert STATUS + exit codes.
- Extend the gate tests: `require_green_ci=true` + a red `gh` shim -> gate does
  NOT archive/finalize and reports RED; green shim -> normal finalize; absent gh
  -> finalize (advisory skip).

## Rollout

1. Land helper + config + SOP with `require_green_ci` default **false** (no
   behavior change for anyone).
2. Dogfood on gobot: set `require_green_ci: true`, run a task, confirm a
   deliberately-red branch is held open and a green one finalizes.
3. Once proven, consider defaulting to true for adopters that have `gh` + CI.

## Alternatives considered

- **Pre-merge gating (push branch -> CI green -> merge).** Strictly better --
  red never touches trunk. But it reorders the Human Gate (which merges locally
  first) and assumes a PR/branch-CI workflow; larger change. Post-merge watch is
  the pragmatic step that fits today's local-merge-then-push topology; it can
  evolve into pre-merge gating later.
- **Doc-only SOP ("remember to check CI").** Rejected: relying on a human/agent
  to remember is the same failure class as the original bug. Automated
  enforcement dominates a checklist.

## Open decisions (for the operator)

1. Config default: keep `require_green_ci` false initially (recommended) vs. true
   for gh-enabled repos from the start.
2. On RED with `auto_push: true`: hold-open + fix-forward (recommended) vs. offer
   an opt-in `-RevertOnRed` that unwinds the merge.
3. `ci_timeout_minutes` default (20 proposed) and whether PENDING_TIMEOUT should
   ever block (proposed: never).
