# Crucible Policy (Canonical)

> **Source of Truth**: This file is the authoritative definition of Crucible operational policies. Documentation and prompt templates must be synchronized with this file.

## 1. FSM Phase Sequence (The DAG)

Crucible operates as a strict Directed Acyclic Graph (DAG). Self-loops and out-of-order transitions are prohibited.

- **grooming** -> `implementation` | `research` | `verification` (Stub-Only Close-Out) | `done` (terminal; requires a recorded human decision)
- **research** -> `grooming`
- **implementation** -> `verification`
- **verification** -> `deployment` (Approved) | `implementation` (Changes Requested)
- **deployment** -> `done` | `implementation` (if rejected/rework requested) | `grooming` (if production issue threshold met)

## 2. Circuit Breakers

Circuit breakers prevent "infinite loops" and budget escalation by blocking tasks for human intervention.

| Breaker Type | Threshold / Trigger | Action |
|--------------|---------------------|--------|
| **Review Strike Rule** | 3 failed review cycles | BLOCK task; route to Human |
| **Handoff Retry Limit** (backstop) | > 2 retries on a same-phase (`X -> X`) handoff | BLOCK task; route to Human |
| **Token Budget** | `cumulative_handoff_count` exceeds the task's tier ceiling (see 2.1) | BLOCK task; route to Human |
| **Merge Conflict** | > 3 rebase attempts | BLOCK task; route to Human |
| **Fabricated Artifacts** | Missing paths in `artifacts` field | BLOCK task; route to Human |
| **Verification Failure** | The project's `verification.full` checks fail when Crucible re-runs them in the worktree after the Reviewer reports APPROVED. The first failure is a retry, not a block; a repeat failure fires the breaker | BLOCK task; route to implementation |
| **Git Hook Bypass** | Reports or references `--no-verify` or equivalent hook bypass | BLOCK task; route to Human |

The **Handoff Retry Limit** is a defense-in-depth backstop, not a live-accruing breaker: no same-phase (`X -> X`) transition exists in the FSM's allowed-transition map, so a schema-valid handoff can never satisfy its `source_phase == target_phase` predicate. It fires only if a same-phase handoff bypasses validation and reaches the breaker with `handoff_retry_count > 2`. Persistent re-review failure - a task repeatedly bounced back for rework - is caught live by the **Review Strike Rule** instead.

### 2.1 Budget Overage Protocol

A task's `budget_tier` sets the ceiling on its `cumulative_handoff_count`. The table
below is generated from `$script:BUDGET_CEILINGS` in `powershell/crucible-lib.ps1`;
change the ceilings there and regenerate.
The regenerator is `powershell/gates/check-generated-docs.ps1 -Write`, which runs in the framework repo only and is not part of a bundle.
An adopter who changes these ceilings edits the table below by hand.

<!-- crucible:generated budget-tier-ceilings -->
| Tier | Handoff ceiling |
|---|---|
| `low` | 10 |
| `medium` | 16 |
| `high` | 28 |
| `extended` | 40 |
<!-- crucible:end budget-tier-ceilings -->

When a circuit breaker for **Token Budget** is triggered:
1. **Mandatory Stop**: The agent MUST NOT proceed, modify the budget tier in the spec, or attempt to bypass the block.
2. **Justification**: The agent MUST provide a concise justification for why the initial budget was insufficient and what remains to be done.
3. **Approval**: A budget increase MUST be explicitly approved by a human. Agents are prohibited from "auto-increasing" or silently adjusting tiers to keep the pipeline moving.

### 2.2 DEGRADED Signal Taxonomy

A `degraded` event means the pipeline continued with reduced assurance. The event's `kind` names which check spoke, and `outcome` names whether that check ran. `outcome: "unverifiable"` means the check could not run and its finding MUST NOT be read as a pass. Historical events without `kind` are classified as `unknown` for reporting compatibility and are not counted as unverifiable gates.

Known degraded kinds:

| Kind | Outcome | Meaning |
|---|---|---|
| `review_strike_2` | `warned` | When `review_strike_count` reaches 2, `crucible.ps1` emits a visible DEGRADED warning and logs a `degraded` event. The Architect MUST treat this as a directive to reduce scope - split the task, defer the contentious part, or simplify - rather than attempting a full re-implementation. If the blocker requires human input, escalate before consuming the last strike. |
| `file_affinity_unverifiable` | `unverifiable` | The scope-violation gate could not run because the spec declared no affected-files section. Human review is the remaining scope check. |
| `file_affinity_scope` | `warned` | The scope gate ran and the handoff `file_affinity` listed paths the spec did not mention. |
| `task_checklist` | `warned` | `task.md` checklist content had malformed or unchecked optional items. |
| `session_cycle_id_mismatch` | `warned` | The agent may not have read the current `task.md`. |
| `unreadable_retry_history` | `warned` | A retry-history scan skipped pipeline-log lines that would not parse; `notes` carries the count. Emitted whether or not the scan then blocked. When the skipped lines meant a repeat failure could not be ruled out, a `circuit_breaker` of the same name accompanies it - see docs/circuit-breaker-runbook.md 'Breaker 12 - Unreadable Retry History'. |
| `unreadable_handoff_history` | `unverifiable` | The server-side handoff count skipped pipeline-log lines that would not parse, so it is a lower bound and the agent-reported count could not be checked against it; `notes` carries the count of skipped lines. Emitted on every run where any line is skipped. When the skipped lines could account for crossing the tier ceiling, a `circuit_breaker` of the same name accompanies it - see docs/circuit-breaker-runbook.md 'Breaker 13 - Unverifiable Handoff Count'. |
| `unreadable_gate_decision` | `unverifiable` | The newest human-gate decision file would not parse, so gate state is unknown. The checks that key off it - backlog finalization and deployment-to-done merge verification - were enforced as though the gate had passed, because the alternative reading skips them entirely. |
| `framework_integrity_no_baseline` | `unverifiable` | The framework-integrity gate resolved no task baseline - the handoff carries no `base_commit` and no task-branch merge-base resolves - so it checked the working tree only. A framework edit committed during the task would not be seen. |
| `unknown` | `warned` | Backward-compatible reporting bucket for archived pre-taxonomy events with no `kind`. |

Duplicate handoffs are reported under handoff quality. They are not a degradation and MUST NOT emit `degraded`.

Kinds carried by other event types. These are not degradations, and reporting MUST NOT count them as reduced assurance:

| Kind | Event | Meaning |
|---|---|---|
| `deprecated_entrypoint_factory_ps1` | `deprecated_entrypoint` | A call arrived through `powershell/factory.ps1`, the forwarding shim the entrypoint rename left at the old path. The call was forwarded to `crucible.ps1` unchanged and nothing about it ran with reduced assurance. The event exists so the shim's deletion criterion is a query rather than a guess - see the framework repo's `docs/proposals/crucible-rename-and-factory-migration.md`, D2, which is not part of a bundle. |

### 2.3 Model Selection

The model a specialist runs on is **computed by Crucible, not fixed per role**, in two stages:

1. **Activity -> capability tier.** `Get-SpecialistModel` derives an abstract tier - `strong`, `default`, or `light` - from the handoff's `target_phase`, `budget_tier`, and `design_required`. This stage is provider-agnostic; it knows nothing about specific model names.
2. **Tier -> concrete model for the active target.** `Get-ConfiguredModel` resolves that tier to a real model for the active `-Target` (`claude` | `codex` | `antigravity` | `grok`; `agent` uses the `claude` row), reading the editable `models:` block in `config.yaml`. Crucible prints the result as a `[RECOMMENDED MODEL]` line that names the target. The orchestrator dispatches with that line and keeps no per-role table of its own. `inherit` is not a slug: omit `model` and let the specialist inherit the session.

The tier policy defaults to the `default` workhorse and escalates to `strong` only where the activity warrants deeper reasoning:

| Phase / Role | Tier | Escalates to `strong` when |
|---|---|---|
| research / Researcher | `strong` | always (open-ended synthesis + judgment) |
| grooming / Groomer | `default` | `budget_tier` is `high` or `extended` |
| implementation / Architect | `default` | `design_required` is true, **or** `budget_tier` is `high`/`extended` |
| verification / Reviewer | `default` | `budget_tier` is `high` or `extended` |
| deployment / Operator | `light` | never on budget: escalates only to `default`, when `rebase_count` or `handoff_retry_count` is above 0 (a rebase re-entry or a retried handoff). The Operator's work is procedural and does not grow with the item. |
| (orchestrator) | `default` | never - orchestration is procedural verification |

The concrete model each tier maps to lives in `config.yaml` under `models:` (see `docs/config-reference.md`) so it is easy to update as providers ship new models. Framework defaults:

| Target | `strong` | `default` | `light` |
|---|---|---|---|
| `claude` (and `agent`) | claude-opus-5-5 at high | claude-sonnet-5-5 at medium | claude-haiku-5-5 at high |
| `codex` | gpt-6.1-sol at high | gpt-6.1-sol at low | gpt-6-luna at high |
| `antigravity` | Gemini 3.1 Pro (High) | Gemini 3.8 Flash (High) | Gemini 3.8 Flash (Medium) |
| `grok` | inherit | inherit | inherit |

For Codex and Claude a tier is a **level**: a model and a reasoning effort taken together, resolved as one pair by `Get-ModelLevel` (`Get-CodexLevel`, `Get-ClaudeLevel`) and printed as `[RECOMMENDED LEVEL] <tier> = <model> at <effort> effort`. A level is changed as a pair under `models.targets.<target>.<tier>` (`model:` and `effort:`), never one half alone. A Claude orchestrator dispatches the generated `crucible-<tier>` agent definition, which pins the model ID and effort (Item 213). Other targets have no effort setting, so their tiers are a model alone.

`design_required` is the one bit that captures design-vs-execution: the Groomer sets it on the grooming->implementation handoff (`new-handoff.ps1 -DesignRequired`) when the Architect must produce the design, and omits it when the spec already carries a complete design. Specialists never pick their own model; like `budget_tier`, the signal is set upstream and enforced by Crucible.

## 3. Human Gates


Transitions across the "Trust Boundary" require a formal human decision.

- **Research Gate**: Researcher findings MUST be presented to and approved by a human before a Groomer spec is written.
- **Human Gate (Operator)**: Every completed task must be accepted by a human.
    - **Outcomes**: `accepted` (approve and pause), `rejected` (rework), `redirected` (approve and jump to a specific task), `abandoned` (do not accept; stop).
    - **Mandate**: Every decision requires a specific, non-placeholder reason.

## 4. Reviewer Verification Checklist (MANDATORY)

A Reviewer MUST verify these 7 steps in order. A failure at any step blocks approval.

1. **Tests pass** - run the project's `verification.full` test command from `.crucible/config.yaml` (e.g. `go test`, `npm test`, `pytest`)
2. **Vet / static analysis passes** - run the project's vet/lint commands from `.crucible/config.yaml` (e.g. `go vet`, `npm run lint`, `cargo clippy`)
3. **Lint passes** - run the project's linter command from `.crucible/config.yaml` (e.g. `golangci-lint`, `ruff`, `eslint`)
4. **Doc-lint passes** - run the project's doc-lint command if defined in `.crucible/config.yaml`
5. **Config-format/validate check passes** - run the project's config-format/validate command if defined in `.crucible/config.yaml` (e.g. `config_check` command)
6. **Acceptance Criteria met** (mapped 1:1 to spec)
7. **Scope bounded** (strictly within `file_affinity`)

> The specific commands in steps 1-5 come from the project's `.crucible/config.yaml`, not from Crucible itself. Crucible is language-agnostic; the examples in this repo use Go (`go test`, `go vet`, `golangci-lint`) because the reference application is written in Go.

## 5. Pipeline State Machine

Crucible tracks each task through a fixed set of states. Only `crucible.ps1` transitions states - specialists never update state directly.

```
                    +-----------------------------------------+
                    |                                         |
         [New item] |                             [Rework]    |
              v     |                                ^        |
           READY ---+                         READY_FOR_REVIEW|
              |     |                                |        |
         [Groomer]  |                          [Architect]    |
              v     |                                |        |
        IN_PROGRESS |                    +-----------+        |
              |     |                    |  [Reviewer: APPROVED]
         [Research] |                    v                    |
              v     |           READY_FOR_DEPLOY              |
        RESEARCH_GATE (Human)            |                    |
              |                     [Operator]                |
              v                          |                    |
           READY <-----------------------+                    |
                                         | [Human Gate]       |
                                         v                    |
                                    PRODUCTION                |
                                    (or RESOLVED)             |
                                                              |
        Any state ------- [Circuit Breaker] ------> BLOCKED -+
                                                  (human resolves)
```

**State definitions**:

| State | Meaning | Who sets it |
|-------|---------|-------------|
| `Ready` | Eligible for next pipeline step | Groomer, Operator (on cycle), or human |
| `In Progress` | Actively being worked | crucible.ps1 on session start |
| `Research Gate` | Awaiting human approval of Researcher findings | crucible.ps1 |
| `Ready for Review` | Architect complete; awaiting Reviewer | crucible.ps1 |
| `Ready for Deploy` | Reviewer approved; awaiting Operator | crucible.ps1 |
| `Production` | Merged to main branch | Operator |
| `Resolved` | Closed without a deploy, whatever the item type | Operator |
| `Blocked` | Circuit breaker fired; awaiting human decision | crucible.ps1 |

**Valid transitions** (all others are hard-blocked by crucible.ps1):

```
Ready            -> In Progress        (Crucible on Groomer/Architect session start)
In Progress      -> Research Gate      (Researcher session complete)
In Progress      -> Ready for Review   (Architect session complete)
In Progress      -> Done               (Groomer closure session complete; requires a recorded human decision)
Research Gate    -> In Progress        (human approves Research Gate)
Ready for Review -> Ready for Deploy   (Reviewer APPROVED)
Ready for Deploy -> Production         (Operator merge complete)
Ready for Deploy -> In Progress        (Reviewer sent back to Architect - strike counted)
Ready for Deploy -> In Progress        (Operator Human Gate REJECTED - rework requested)
Any              -> Blocked            (circuit breaker)
Blocked          -> Ready              (human resolution + Crucible -Recover)
```

## 6. Security & Isolation

- **Implementation Worktrees**: Every task MUST run in an isolated `git worktree` at `.crucible/.agent-workspaces/implementation-{id}`.
- **Prompt Injection Defense**: Handoffs and research findings are scanned for patterns (e.g., "ignore previous instructions"). Researcher handoffs trigger an automatic block if patterns are found. As a defense-in-depth measure, all produced research artifacts and session research files are independently scanned; a detector hit in these files when no self-report has been made by the Researcher triggers a block.
- **Research Scope Boundary**: As a defense-in-depth check, modifications during the research phase to tracked files outside `.crucible/research/` and `.crucible/session/` trigger a security warning in the console and event log to surface boundary violations for human review (advisory only, does not block the pipeline).
- **File Affinity**: Groomers define the scope boundary. Specialists must not edit files outside this boundary.
- **No Push/Commit Shortcuts**: Only the Operator may merge to `master` and push to origin.

### 6.1 File Affinity - Design Model & Validation Strength

`file_affinity` is a **forward-looking, deny-by-default allowlist** of the path prefixes a task is permitted to touch. It exists to **confine the blast radius** of an autonomous change (principle of least privilege / capability confinement; same posture as a firewall allowlist or GitHub `CODEOWNERS`).

The blast-radius control is **not the list itself** - it is the **scope gate** that diffs the specialist's actual changes against the list. Enforcement strength is deliberately tiered, and this is settled design (do not re-litigate without a new, named failure mode):

| Check | What it protects | Strength | Why |
|---|---|---|---|
| Actual diff is a subset of `file_affinity` | The real boundary | **Hard, fail-closed** (block) | This is the security property. If scope can't be determined, block. |
| `file_affinity` not *over-broad* vs the spec's Affected Files | Least privilege (minimize blast radius) | **Warn** | Over-breadth is the real blast-radius risk; surface it for narrowing. |
| Declared `file_affinity` paths *exist on disk* | Authoring hygiene (catch typos) | **Warn only - never hard-fail** | See below. |

**Why path-existence is warn-only, by construction:** `file_affinity` is a *scope boundary*, not a *manifest of existing files*. Any task that **creates** a file or package legitimately lists a target that does not exist at grooming time. Hard-failing on non-existence would conflate "boundary" with "manifest" and break every file-creating task - a category error. (`CODEOWNERS` follows the same rule: a pattern matching no files is a warning, never a failure.) A non-existent allowlist entry is also **not a safety issue** - an entry that matches nothing grants nothing; only *over-broad* entries widen blast radius.

**Implication for authors and reviewers:** keep `file_affinity` as **narrow as possible** (least privilege) and **consistent with reality** - a path that doesn't resolve usually means the *real* file is outside the declared scope, which will make the fail-closed gate correctly *block a legitimate edit*. Treat the existence `[WARN]` from `validate-backlog.ps1` as a signal to fix the scope, not noise. (History: finding D46 - `validate-backlog.ps1` warns on non-resolvable `file_affinity` entries, `-ProjectRoot`-aware; intentionally warn, not fail, per the reasoning above.)

## 7. Handoff Validation & Quality Gates

In addition to circuit breakers, `crucible.ps1` enforces runtime validation gates before accepting handoffs:

- **Unchecked task.md Quality Gate**: `crucible.ps1` blocks any handoff where the source specialist's `task.md` still has an item under `## Task List` marked `[ ]` (unchecked) or `[/]` (in progress), or carrying a marker it does not recognize. Items outside that section warn without blocking, and `[-]` marks an item as deliberately skipped. The failure names the offending lines, not only how many there are.
- **Budget Tier Cross-Validation**: `crucible.ps1` reads the backlog spec frontmatter at task initialization and overrides the handoff's `budget_tier` if it mismatches. Specialists cannot escalate their own budget tier.
- **Log-Derived Handoff Count**: `crucible.ps1` counts `session_end` events in the task-scoped pipeline log and overrides the agent-reported `cumulative_handoff_count` if it is lower (preventing budget under-reporting).
- **Scan Limit**: `crucible.ps1` auto-kickoff scans at most 5 items in a single run.
- **Backlog Integrity**: On a `grooming` or `deployment` handoff, `crucible.ps1` runs `validate-backlog.ps1` against the project's backlog. A non-zero exit blocks the handoff (exit 2) with "YOU must fix BACKLOG.md before proceeding."
- **Dev Log Integrity**: On a `deployment` handoff whose target is not `implementation`, and which is not the task's bootstrap handoff, a file must exist at `.crucible/dev-logs/UNPUBLISHED_LOGS.md` and pass `validate-dev-log.ps1`. A missing file or a failed PII/secret scan blocks the handoff (exit 2).
- **Workspace Cleanliness**: Same trigger as Dev Log Integrity. Any untracked or uncommitted path outside `.crucible/`, `.agent-workspaces/`, `.gemini/`, `.antigravitycli/`, `.vscode/`, and `vendor/` blocks the handoff (exit 2).
- **Commit-message encoding** (`commit-msg`, adopters included): `check-mojibake.ps1 -MessageFile` on the message being written. A UTF-8 BOM becomes the first character of the subject and is unfixable once pushed. The check needs no staged tree and runs ahead of both the adopter short-circuit and the merge short-circuit.
- **Assertion-Deletion Gate** (framework repo only; the gate is not part of a bundle and an adopter's hooks do not run it): `check-assertion-deletion.ps1` diffs test files (`*.tests.ps1`) for dropped `Assert-Result` calls, and runs at two points. At `commit-msg` it reads the index and refuses the commit unless the message being written carries a non-empty `Assertions-Removed: <reason>` trailer; merge commits skip this leg, because a merge's first-parent diff restates the merged branch. At `pre-push` it walks every commit in the push range and charges a commit for a name dropped against every parent of that commit, so a merge is charged for a removal that appears on neither parent and not for work already on a parent. The commit-msg leg is where the trailer is a one-line edit for ordinary commits; the pre-push leg is the backstop for removals that reached the range without one.

The Baseline Cleanliness Probe at task start is advisory and does not block. There is no Task Dependency Gate.

## 8. Pipeline Invariants

The state machine in section 5 says which transitions are legal. This section says what
must be true of the repository, the backlog and the session state across every transition,
whichever path reaches it. Each invariant is enforced at one place in the runtime, and a
change that would make it conditional on the path taken is a defect, not a design choice.

A fix that restores one of these is not finished until the invariant is checked where the
state changes, not where the bug was seen. A new gate or a new path through an existing
gate is reviewed against this list before it merges.

| # | Invariant | Enforced where | Record |
|---|---|---|---|
| I1 | What is tested is what merges. The independent checks refuse a task worktree with uncommitted changes, so the merge ships exactly the tree the checks ran on. | verification -> deployment checks, breaker `uncommitted_task_worktree` | item 221 |
| I2 | Nothing deletes uncommitted task work. Cleanup leaves a dirty or locked worktree in place and names its files. `--force` is never the normal path. | `Test-GitDiscardSafe` in `lib/git.ps1`, before discard or before starting an abortable operation; `powershell/tests/git-discard-guard.tests.ps1` (the framework repo's own guard test) enforces calls and reasoned allowances that fail when stale | items 179, 221, 253 |
| I3 | A task is marked terminal only after the action that makes it terminal has succeeded. Finalization and archival run after a successful merge and before any push; a merge that reworks, blocks or fails leaves the row and spec unchanged. | human gate accept | item 222 |
| I4 | Every handoff that reaches a gate was selected and bound to the task once, through the one reader. Recovery, relocation or repair of a handoff file happens before that reader, never after. | handoff preflight, `Restore-MisplacedHandoff` | items 185, 223 |
| I5 | One writer per shared file. A lock is held as an exclusive handle for the whole write and released by closing it; no waiter deletes another holder's lock. | backlog lock, event-log lock | item 224 |
| I6 | Branch, path and directory names come from configuration, never from a built-in list of likely values, and a check that cannot read its input fails closed. | `scripts/crucible_lint.go` (the framework repo's lint, run by its pre-commit hook and CI): `lintConfiguredInputs` over runtime PowerShell, with reasoned allowances that fail when stale | item 244 |
| I7 | A decision is persisted before the action it authorizes runs, so every path that performs the action sees the same recorded decision. | `Write-HumanGateDecision`, called before dispatch by both Human Gate inputs; `Invoke-HumanGateMerge` removes premature accepted or redirected authorization when a merge does not complete | items 226, 242, 251, 265 |
| I8 | An identifier matches exactly or not at all. A lookup by task ID matches the ID cell, not a substring of the row, and a missing row is refused rather than approximated. | `Test-BacklogTaskRow` in `lib/backlog-io.ps1`, the one row matcher that finalization, archival, restore, rejection, status lookup and the premature-status gate call; findings lookup uses `Get-ResearchFindingsArtifact` through the existing `Get-BacklogSpecFiles` filename reader; second readers fail I13's guard | items 227, 245, 250, 257 |
| I9 | A required header or marker counts only in the position the contract names. An example or quotation elsewhere in the document cannot satisfy it. | review header check | item 228 |
| I10 | The first write to a missing state file persists exactly as a write to an existing one would. The missing-file branch builds the same object shape deserialization gives. | session state writer | item 234 |
| I11 | A gate refusal is unconditional. No caller, catch block or configuration can convert a refusal into a pass. | every gate `exit` | item 36 |
| I12 | A check that did not run is reported as NOT RUN, never as passed, and is listed at the gate that would otherwise accept without it. | `Write-CheckNotRun` in `lib/checks-not-run.ps1`, the one reporting point that the isolated checks, the scope gate (empty `file_affinity`, missing affinity script, unreadable research scope) and the integrity gate (no task baseline) write through; a writer replaces only its own check's line, under the task's lock, and a line clears only when that check runs. `Get-ChecksNotRun` feeds the Reviewer prompt, the isolated checks' closing list and the Human Gate menu | items 239, 258 |
| I13 | Each persisted format has one owning reader: BACKLOG.md rows by task ID, spec filenames, research findings artifacts, spec frontmatter fields, the handoff schema, artifact paths, the verification checks block, the project root, the configured `crucible_root`, the bundle directory resolved from it (an absolute value as is, a relative one under the project root; `Resolve-CrucibleBundleRoot`) and the checks-not-run record. A second reader calls the owner instead of parsing the format again. The same table owns general path resolution (`Resolve-PathFromRoot`, rooted values verbatim, relative values joined to the root; the bundle resolver specializes it), filesystem qualification (`Resolve-FilesystemPath`, qualifying provider-dependent inputs through the current PowerShell filesystem drive, including missing paths; audited existing FileSystem `Resolve-Path` results may expose `PathInfo.ProviderPath` through reasoned allowances), path containment (`Test-PathWithinDirectory`, full paths at a separator boundary) and contained-path relativization (`Get-PathRelativeToDirectory`, slicing the same normalized paths, preserving suffix case and trailing separators). Containment and relativization require absolute inputs; a bare prefix cannot count a sibling such as `backlog2` as inside `backlog`. | the owners table in `powershell/tests/format-owners.tests.ps1` (the framework repo's own guard test, not shipped), which fails on a format's signature outside its owner, with reasoned allowances that fail when stale | items 245, 247, 257, 301, 302, 304, 305, 328, 329 |
| I14 | A launch reports one outcome. The Codex launcher decides its STATUS once, from the run's evidence (exit code, transcript tail, the task's pipeline log entries, the final message), and the same record reaches stdout and `codex-launch-status.txt`. A run whose outcome cannot be decided reports LAUNCH_FAILED with the reason, never no STATUS. | `Get-CodexLaunchOutcome` and `Write-CodexLaunchStatus` in `lib/codex-launch-outcome.ps1`; `powershell/tests/codex-launch-outcome.tests.ps1` fails on a STATUS line written anywhere else in the launcher | items 203, 209, 211, 238, 246 |
| I15 | A command that runtime PowerShell prints for one of Crucible's own scripts is built, not written. It names only parameters the target's param block declares, each with its declared kind (switch or value); it carries the companions a parameter needs (`-ProjectRoot` with `-Init`; `-Effort` with a Codex `-Model` outside `-Preflight`); its path is the bundle the caller names, normally the project's configured `crucible_root`, or the `{crucible_root}` placeholder when the project has no config. Each line is quoted for the shell its surrounding text names. A line an agent is told to run through its Bash tool (`next_step.txt`, the session-end command in `task.md`) is POSIX-quoted and starts `pwsh -NoProfile -ExecutionPolicy Bypass -File`; agent instructions without a prescribed shell (the Codex handoff, the task.md isolated-checks/merge-simulation commands and the research gate continuation's validate and advance lines) explicitly select ShellNeutral and start `pwsh -NoProfile -ExecutionPolicy Bypass -File` with literals shared by Bash and PowerShell; an agent command that carries lists, or values no native line passes intact, is written in the direct form into a generated script, and the agent starts that script with the shell-neutral line `New-CrucibleScriptFileCommand` builds (the research gate handoff, `session/<task-id>/research/gate-handoff.ps1`); advice for readers (stop reports, gate menus, refusals, usage, dispatch and update advice) uses the direct `& '<script>' ...` form in a PowerShell 7+ prompt, with single-quoted literals and doubled single quotes, so no native argument passing is involved; `Start-Process -ArgumentList` gets its own encoding. A value no command line carries prints `# (command unavailable: <reason>)` in place of the command, a comment in both shells: a line break or NUL; an empty value or a leading `-` on the native `-File` transports (Bash, ShellNeutral and ArgumentList); an embedded double quote or whitespace with a trailing backslash on ShellNeutral, which older launching PowerShell hosts cannot pass intact; on ShellNeutral, a single quote with an expansion character, a doubled backslash or a trailing backslash in a value that does not start with a letter, digit, underscore or slash (one that does is written as adjacent quoted segments after that character, which both shells join into one argument); the stop-parsing token `--%` on the direct form; and, on a Bash or ShellNeutral line under Windows, a value Git Bash rewrites as a POSIX path (a leading `/` or `@/`, or `name=/...`). Building a command never stops the surface that prints it or changes its exit. A `-Reference` names a script and parameters in prose, with no path, and only from a reviewed list. Commands in shipped documents are not covered (item 275). | `New-CrucibleCommand` in `lib/crucible-command.ps1`, which binds against the target's param block; `powershell/tests/printed-commands.tests.ps1` (the framework repo's own guard test, not shipped) fails on a `<script>.ps1 -<Param>` string, interpolation, concatenation, `-f` format or script-carrying variable in runtime PowerShell outside the builder, binds every builder call statically, checks every caller's explicit transport against the audited shell audience, and keeps `-Reference` calls and allowances to reviewed lists that fail when stale | items 125, 126, 207, 208, 218, 219, 247, 290, 291, 320 |

I13 filesystem qualification rule: call `Resolve-FilesystemPath` for general
provider-dependent inputs, including missing paths, before native IO, git,
containment or relativization. When an existing-path probe already uses
`Resolve-Path`, reading its `PathInfo.ProviderPath` is sanctioned: that property
exposes the FileSystem provider's native path instead of the alias-preserving
`Path`, without adding a second qualification algorithm or resolving again.
Keep the probe's literal or wildcard semantics (archival expands SpecPath once).
This applies only to existing FileSystem results; missing paths and general
qualification still belong to the shared owner. `Convert-Path` and provider
resolution method calls outside that owner still require reasoned guard
allowances. The guard also detects `.ProviderPath` property reads; each audited
existing FileSystem result has a reasoned allowance that fails when stale, and
new reads require review and their own allowance (item 329 cross-review).

How the list is used:

- When a defect is filed, name the invariant it violates. If none fits, that is either a
  new invariant to add here or a defect of a different class. Either way, say which.
- When a fix lands, the regression test exercises the invariant at its enforcement point
  with the path the defect took. A test that pins only the symptom is not a regression for
  the invariant.
- When a change adds a path that reaches an enforcement point, the author lists which
  invariants the new path is covered by and the Reviewer checks it.
- The list grows only by filed defect or by design. It does not grow by restating
  implementation detail.
