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
| `review_report_format` | `warned` | The review report had no YAML header; a plain-text APPROVED report was accepted. |
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
| `claude` (and `agent`) | opus | sonnet | haiku |
| `codex` | gpt-6.1-sol | gpt-6.1-sol | gpt-6-luna |
| `antigravity` | Gemini 3.1 Pro (High) | Gemini 3.8 Flash (High) | Gemini 3.8 Flash (Medium) |
| `grok` | inherit | inherit | inherit |

For a Codex target Crucible also prints a reasoning effort.  `models.effort.codex.<tier>` in `config.yaml` overrides it.

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
