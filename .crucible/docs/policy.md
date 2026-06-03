# Dev Factory Policy (Canonical)

> **Source of Truth**: This file is the authoritative definition of Dev Factory operational policies. Documentation and prompt templates must be synchronized with this file.

## 1. FSM Phase Sequence (The DAG)

The factory operates as a strict Directed Acyclic Graph (DAG). Self-loops and out-of-order transitions are prohibited.

- **grooming** → `implementation` | `research`
- **research** → `grooming`
- **implementation** → `verification`
- **verification** → `deployment` (Approved) | `implementation` (Changes Requested)
- **deployment** → `done` | `grooming` (if production issue threshold met)

## 2. Circuit Breakers

Circuit breakers prevent "infinite loops" and budget escalation by blocking tasks for human intervention.

| Breaker Type | Threshold / Trigger | Action |
|--------------|---------------------|--------|
| **Review Strike Rule** | 3 failed review cycles | BLOCK task; route to Human |
| **Handoff Retry Limit** | > 2 consecutive retries to same phase | BLOCK task; route to Human |
| **Token Budget (Low)** | 6 handoffs | BLOCK task; route to Human |
| **Token Budget (Medium)** | 10 handoffs | BLOCK task; route to Human |
| **Token Budget (High)** | 24 handoffs | BLOCK task; route to Human |
| **Token Budget (Extended)** | 32 handoffs | BLOCK task; route to Human |
| **Merge Conflict** | > 3 rebase attempts | BLOCK task; route to Human |
| **Fabricated Artifacts** | Missing paths in `artifacts` field | BLOCK task; route to Human |
| **Verification Failure** | `go test` fails after verification approval | BLOCK task; route to implementation |
| **Git Hook Bypass** | Reports or references `--no-verify` or equivalent hook bypass | BLOCK task; route to Human |

### 2.1 Budget Overage Protocol

When a circuit breaker for **Token Budget** is triggered:
1. **Mandatory Stop**: The agent MUST NOT proceed, modify the budget tier in the spec, or attempt to bypass the block.
2. **Justification**: The agent MUST provide a concise justification for why the initial budget was insufficient and what remains to be done.
3. **Approval**: A budget increase MUST be explicitly approved by a human. Agents are prohibited from "auto-increasing" or silently adjusting tiers to keep the pipeline moving.

### 2.2 Strike-2 DEGRADED Signal

When `review_strike_count` reaches 2, `factory.ps1` emits a visible DEGRADED warning and logs a `degraded` event. The Architect MUST treat this as a directive to reduce scope — split the task, defer the contentious part, or simplify — rather than attempting a full re-implementation. If the blocker requires human input, escalate before consuming the last strike.

## 3. Human Gates


Transitions across the "Trust Boundary" require a formal human decision.

- **Research Gate**: Researcher findings MUST be presented to and approved by a human before a Groomer spec is written.
- **Human Gate (Operator)**: Every completed task must be accepted by a human.
    - **Outcomes**: `accepted` (approve and pause), `rejected` (rework), `redirected` (approve and jump to a specific task), `abandoned` (do not accept; stop).
    - **Mandate**: Every decision requires a specific, non-placeholder reason.

## 4. Reviewer Verification Checklist (MANDATORY)

A Reviewer MUST verify these 6 steps in order. A failure at any step blocks approval.

1. **Tests pass** — run the project's `verification.full` test command from `.crucible/config.yaml` (e.g. `go test`, `npm test`, `pytest`)
2. **Vet / static analysis passes** — run the project's vet/lint commands from `.crucible/config.yaml` (e.g. `go vet`, `npm run lint`, `cargo clippy`)
3. **Lint passes** — run the project's linter command from `.crucible/config.yaml` (e.g. `golangci-lint`, `ruff`, `eslint`)
4. **Doc-lint passes** — run the project's doc-lint command if defined in `.crucible/config.yaml`
5. **Acceptance Criteria met** (mapped 1:1 to spec)
6. **Scope bounded** (strictly within `file_affinity`)

> The specific commands in steps 1–4 come from the project's `.crucible/config.yaml`, not from Crucible itself. Crucible is language-agnostic; the examples in this repo use Go (`go test`, `go vet`, `golangci-lint`) because the reference application is written in Go.

## 5. Pipeline State Machine

The factory tracks each task through a fixed set of states. Only `factory.ps1` transitions states — specialists never update state directly.

```
                    ┌─────────────────────────────────────────┐
                    │                                         │
         [New item] │                             [Rework]    │
              ↓     │                                ↑        │
           READY ───┤                         READY_FOR_REVIEW│
              │     │                                │        │
         [Groomer]  │                          [Architect]    │
              ↓     │                                │        │
        IN_PROGRESS │                    ┌───────────┘        │
              │     │                    │  [Reviewer: APPROVED]
         [Research] │                    ↓                    │
              ↓     │           READY_FOR_DEPLOY              │
        RESEARCH_GATE (Human)            │                    │
              │                     [Operator]                │
              ↓                          │                    │
           READY ◄───────────────────────┤                    │
                                         │ [Human Gate]       │
                                         ↓                    │
                                    PRODUCTION                │
                                    (or RESOLVED)             │
                                                              │
        Any state ─────── [Circuit Breaker] ──────► BLOCKED ─┘
                                                  (human resolves)
```

**State definitions**:

| State | Meaning | Who sets it |
|-------|---------|-------------|
| `Ready` | Eligible for next pipeline step | Groomer, Operator (on cycle), or human |
| `In Progress` | Actively being worked | factory.ps1 on session start |
| `Research Gate` | Awaiting human approval of Researcher findings | factory.ps1 |
| `Ready for Review` | Architect complete; awaiting Reviewer | factory.ps1 |
| `Ready for Deploy` | Reviewer approved; awaiting Operator | factory.ps1 |
| `Production` | Merged to main branch | Operator |
| `Resolved` | Chore/bug closed without a deploy | Operator |
| `Blocked` | Circuit breaker fired; awaiting human decision | factory.ps1 |

**Valid transitions** (all others are hard-blocked by factory.ps1):

```
Ready            → In Progress        (factory on Groomer/Architect session start)
In Progress      → Research Gate      (Researcher session complete)
In Progress      → Ready for Review   (Architect session complete)
Research Gate    → In Progress        (human approves Research Gate)
Ready for Review → Ready for Deploy   (Reviewer APPROVED)
Ready for Deploy → Production         (Operator merge complete)
Ready for Deploy → In Progress        (Reviewer sent back to Architect — strike counted)
Any              → Blocked            (circuit breaker)
Blocked          → Ready              (human resolution + factory -Recover)
```

## 6. Security & Isolation

- **Implementation Worktrees**: Every task MUST run in an isolated `git worktree` at `.crucible/.agent-workspaces/implementation-{id}`.
- **Prompt Injection Defense**: Handoffs are scanned for patterns (e.g., "ignore previous instructions"). Researcher handoffs trigger an automatic block if patterns are found.
- **File Affinity**: Groomers define the scope boundary. Specialists must not edit files outside this boundary.
- **No Push/Commit Shortcuts**: Only the Operator may merge to `master` and push to origin.

### 6.1 File Affinity — Design Model & Validation Strength

`file_affinity` is a **forward-looking, deny-by-default allowlist** of the path prefixes a task is permitted to touch. It exists to **confine the blast radius** of an autonomous change (principle of least privilege / capability confinement; same posture as a firewall allowlist or GitHub `CODEOWNERS`).

The blast-radius control is **not the list itself** — it is the **scope gate** that diffs the specialist's actual changes against the list. Enforcement strength is deliberately tiered, and this is settled design (do not re-litigate without a new, named failure mode):

| Check | What it protects | Strength | Why |
|---|---|---|---|
| Actual diff ⊆ `file_affinity` | The real boundary | **Hard, fail-closed** (block) | This is the security property. If scope can't be determined, block. |
| `file_affinity` not *over-broad* vs the spec's Affected Files | Least privilege (minimize blast radius) | **Warn** | Over-breadth is the real blast-radius risk; surface it for narrowing. |
| Declared `file_affinity` paths *exist on disk* | Authoring hygiene (catch typos) | **Warn only — never hard-fail** | See below. |

**Why path-existence is warn-only, by construction:** `file_affinity` is a *scope boundary*, not a *manifest of existing files*. Any task that **creates** a file or package legitimately lists a target that does not exist at grooming time. Hard-failing on non-existence would conflate "boundary" with "manifest" and break every file-creating task — a category error. (`CODEOWNERS` follows the same rule: a pattern matching no files is a warning, never a failure.) A non-existent allowlist entry is also **not a safety issue** — an entry that matches nothing grants nothing; only *over-broad* entries widen blast radius.

**Implication for authors and reviewers:** keep `file_affinity` as **narrow as possible** (least privilege) and **consistent with reality** — a path that doesn't resolve usually means the *real* file is outside the declared scope, which will make the fail-closed gate correctly *block a legitimate edit*. Treat the existence `[WARN]` from `validate-backlog.ps1` as a signal to fix the scope, not noise. (History: finding D46 — `validate-backlog.ps1` warns on non-resolvable `file_affinity` entries, `-ProjectRoot`-aware; intentionally warn, not fail, per the reasoning above.)

## 7. Handoff Validation & Quality Gates

In addition to circuit breakers, `factory.ps1` enforces runtime validation gates before accepting handoffs:

- **Unchecked task.md Quality Gate**: `factory.ps1` blocks any handoff where the source specialist's `task.md` still contains unchecked `- [ ]` items.
- **Budget Tier Cross-Validation**: `factory.ps1` reads the backlog spec frontmatter at task initialization and overrides the handoff's `budget_tier` if it mismatches. Specialists cannot escalate their own budget tier.
- **Log-Derived Handoff Count**: `factory.ps1` counts `session_end` events in the task-scoped pipeline log and overrides the agent-reported `cumulative_handoff_count` if it is lower (preventing budget under-reporting).
- **Scan Limit**: `factory.ps1` auto-kickoff scans at most 5 items in a single run.
