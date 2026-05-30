# When To Use Crucible

> *Last refreshed: 2026-05-21*

Crucible is a **multi-specialist agentic harness** for software development. It runs five AI specialists through a deterministic pipeline with hard enforcement gates, schema-validated handoffs, sandboxed code execution per task, and structured observability — all driven by a local PowerShell orchestrator with no SaaS dependency.

Currently field-tested on **Gobot** (a Go-based Telegram bot). The patterns are project-agnostic.

---

## What it is (in one paragraph)

A locally-hosted assembly line for AI coding agents. Five specialists (Researcher → Groomer → Architect → Reviewer → Operator) advance work through a strict pipeline orchestrated by `factory.ps1`. Every transition produces a schema-validated `handoff.json`. The orchestrator independently verifies what each agent claims — re-running tests, scanning for prompt injection, checking artifact existence, enforcing budget ceilings — before allowing the pipeline to advance. Two formal gates (Research Gate, Human Gate) keep a human in the loop at decisions that actually require judgment. Everything else runs deterministically.

---

## Specialist Pipeline

```
RESEARCHER → [RESEARCH GATE] → GROOMER → ARCHITECT → REVIEWER → OPERATOR → [HUMAN GATE] → next
                                              ↑___________________|
                                              (rebase loop on merge conflict)
```

| Specialist | Role | Model tier |
|---|---|---|
| **Researcher** | Explorer & fact-finder. Consumes untrusted external sources. Summarizes in project-neutral prose. | Fast/cost-effective |
| **Groomer** | Technical spec writer & de-risker. Owns backlog lifecycle. Treats Researcher output as untrusted external content. | Fast/cost-effective |
| **Architect** | Implementer. Works inside an isolated git worktree. Bound to declared file_affinity scope. | High-capability |
| **Reviewer** | Quality gate. Runs the 8-step verification checklist. Must approve before Operator merges. | High-capability |
| **Operator** | Deployer. Merges to master, validates health, archives logs, updates backlog. | Fast/cost-effective |

`factory.ps1` automatically assigns the recommended model tier per role.

---

## Core Enforcement Features

### Schema-Validated Handoffs

Every specialist transition writes `.crucible/session/handoffs/{task_id}-{ts}.json`, validated against `handoff.schema.json`. The deterministic generator `new-handoff.ps1` auto-carries `cumulative_handoff_count`, `review_strike_count`, and `cycle_id` from the previous handoff so agents can't lose or fabricate them. Handoffs with duplicate identity keys are marked `superseded`.

### Independent Verification (the harness re-checks the agent)

The factory does not trust the agent's word. It independently re-verifies:

- **Independent test run** — after Reviewer approves, the orchestrator re-runs `<project test command>` inside the worktree. Failures trigger `reviewer_verification_failed`.
- **Artifact integrity gate** — every path in `artifacts[]` must exist and be non-empty. Fabricated paths are a hard block.
- **Budget tier cross-validation** — factory reads the backlog spec frontmatter and overrides the handoff's `budget_tier` if mismatched. Agents cannot self-escalate.
- **Log-derived handoff count** — factory counts `session_end` events and overrides the agent-reported `cumulative_handoff_count` if it's lower. Agents cannot under-report budget usage.
- **Unchecked task.md quality gate** — handoff is blocked if the source `task.md` still has unchecked `[ ]` items.
- **Backlog integrity validator** — runs automatically on Groomer/Operator handoffs.

### Circuit Breakers

Mandatory limits that prevent runaway processes and budget escalation. See [`docs/policy.md`](policy.md#2-circuit-breakers) §2 for the canonical list of active breaker types, thresholds, and rules.

Every breaker writes a structured blocked-task record to `.crucible/backlog/blocked/{task_id}-{ts}.json` with circuit_breaker type, attempt_count, summary, and required human decision.

### Trust Boundary (Researcher → Groomer)

The Researcher→Groomer transition is treated as a primary trust boundary because Researchers consume untrusted external sources (web, GitHub, docs).

- **Researcher mandate**: never copy-paste external content verbatim. Summarize in project-neutral prose. Flag anomalous instructions ("ignore previous instructions", "you must now do X") in the `suspicious_content` handoff field.
- **Groomer mandate**: treat Researcher output as external content. Paraphrase and validate before drafting specs.
- **Active suspicious_content halt**: `factory.ps1` halts if the field is non-null.
- **Passive injection scan**: even if `suspicious_content` is null, the factory case-insensitively scans the raw handoff JSON for known injection patterns. Researcher handoffs hard-stop on a match; other specialists log and warn.

---

## Isolation Architecture

Two-layer isolation prevents interference between concurrent specialists and ensures deterministic execution:

### 1. Orchestration Layer — `.crucible/session/`
Process metadata, handoff data, agent state. Tracks **what** is being done and **who** is doing it.

```
.crucible/session/
  {task_id}/{role}/task.md        ← specialist scratchpad
  {task_id}/{role}/prompt.md      ← assembled prompt (P-1 architecture)
  {task_id}/pipeline.log.jsonl    ← event log
  global/session_state.json       ← unified state, keyed by task_id
  handoffs/{task_id}-{ts}.json    ← schema-validated handoff records
  archived/                       ← rotated logs
```

### 2. Code Isolation Layer — `.crucible/.agent-workspaces/`
Each Architect runs in its own `git worktree` at `.crucible/.agent-workspaces/implementation-{task_id}/`. Validation runs through `run-isolated-checks.ps1` with task-scoped `GOCACHE`, `GOLANGCI_LINT_CACHE`, `GOTMPDIR`, `TMP`, `TEMP` — so concurrent workspaces never poison each other.

**Rule of thumb**: read instructions from `.crucible/session/`, perform edits in `.crucible/.agent-workspaces/implementation-{task_id}/`.

---

## Parallel Pipeline Operation

The factory supports running multiple backlog items concurrently by scoping all session state to a task ID. Each terminal session manages an independent pipeline instance.

- Per-task worktree, scratchpad, event log, handoffs, and `session_state.tasks.{task_id}.{role}` slot.
- Shared resources (`BACKLOG.md`, `UNPUBLISHED_LOGS.md`) protected via file locks in `.crucible/locks/`.
- **File-Affinity Matrix ({task_id})** — Groomer declares `file_affinity` (package paths/globs). Factory checks every incoming handoff against all in-flight tasks; overlapping scope blocks the handoff before parallel work collides.
- **Merge Simulation ({task_id})** — Operator runs `check-merge-conflicts.ps1` before any real merge. Conflicts route back to Architect as "Ready for Rebase." A `recurring_merge_conflicts` circuit breaker fires after 3 rebases.
- **Task Dependencies ({task_id})** — Specs declare `depends_on: ["{task_id}"]`. Factory enforces dependency satisfaction at the Operator phase; warnings at earlier phases.

---

## Observability

### Structured Event Log
`.crucible/session/{task_id}/pipeline.log.jsonl` — JSONL, one event per line. Auto-written by `factory.ps1` (`session_start`, `session_end`, `degraded`, `circuit_breaker`, `gate_decision`). Queryable with `jq`:

```bash
# Avg phase-open wall time by role
jq -s '[.[] | select(.event == "session_end" and .metrics.phase_wall_seconds != null)] | group_by(.phase)
  | map({phase: .[0].phase, avg: (map(.metrics.phase_wall_seconds) | add / length)})' \
  .crucible/session/{task_id}/pipeline.log.jsonl

# All circuit-breaker events
jq 'select(.event == "circuit_breaker")' .crucible/session/{task_id}/pipeline.log.jsonl

# Tasks over 80% budget
jq 'select(.event == "session_end" and .metrics.budget_pct_used > 80)' ...
```

### Eval Analyzer
`{{crucible_root}}/powershell/analyze-evals.ps1` mines gate decisions and per-task eval records for:
- Gate outcomes (accepted / rejected / redirected / abandoned)
- Tasks that needed multiple review cycles
- Average budget utilization
- DEGRADED event counts
- Operator-captured `ac_verified`, `review_cycles`, `budget_pct_used`

Add `-Json` for machine-readable output. Run quarterly or every 10 completed tasks ({task_id}).

### Prompt Version Tracking
Every prompt template carries `<!-- prompt_version: {role}-v1 -->`. Handoffs include `prompt_version`. Factory validates and displays the version per session for accurate audit trails across template edits.

### Health Check & Auto-Cleanup
- `factory.ps1 -Health` scans for orphaned worktrees, unresolved blocked tasks, stale handoffs (>24h), stale locks (>10m), oversized scratchpads, orphaned gate-pending files, misconfigured worktree `core.hooksPath`.
- `factory.ps1 -Cleanup` dry-runs removal of orphans; `-Cleanup -Force` executes. Synchronizes with `BACKLOG.md` so no active-task data is ever deleted.

---

## Quality Gates

### Reviewer 8-Step Verification (in order, all must pass)

1. Isolated checks pass — `run-isolated-checks.ps1 -TaskId {task_id} -Mode full` exits 0
2. Vet/Lint/Test/Doc parity — `go vet`, `golangci-lint`, `gotestsum`, `go run scripts/doc_lint.go` (matches CI exactly)
3. Acceptance criteria met — every spec checkbox checked
4. Scope bounded — changes limited to spec-named files and declared `file_affinity`
5. No regressions — diff reviewed for behavior changes outside scope
6. No hard mandates violated — AGENTS.md (pure Go, no panic, wrapped errors, slog, etc.)
7. Backlog status updated to `Ready for Deploy` with `target_phase: deployment`
8. Structured `review_report.md` with YAML frontmatter (`review_decision: APPROVED`, `acceptance_criteria_met: true`)

A YAML mismatch hard-blocks the Operator handoff. After step 8, factory **independently** re-runs `go test` (circuit breaker 5).

### CI Parity Rationale
Steps 1–4 mirror exactly the jobs in `.github/workflows/ci.yml`. A change passing the Reviewer checklist locally will also pass GitHub CI. Lint/doc-lint failures discovered only in CI = process violation requiring a circuit-breaker note.

---

## Gates (Human-in-the-Loop)

Two formal gates require human decisions; everything else advances automatically.

### Research Gate (Researcher → Groomer)
Research produces options, not decisions. The Researcher presents findings in a fixed format (summary, recommended actions, questions) and waits for explicit approval before writing the handoff. The Groomer reads `human_decisions.approved` as authoritative scope.

### Human Gate (Operator → next)
After Operator completes, four numbered outcomes:
1. **Accept** — work is good; pause after this item
2. **Reject** — send back for rework
3. **Redirect** — accept this item and route to a specific next item
4. **Abandon** — do not accept; stop the pipeline

Stored in `.crucible/session/global/gate_decisions/` for retrospective analysis.

### Orchestrator Auto-Advance
`-AutoAdvance` flag eliminates confirmation prompts for non-gate transitions (Groomer→Architect, Architect→Reviewer, Reviewer→Operator). Gates always pause regardless.

### Expected Human Interaction Per Tier
| Tier | Budget | Confirmations | Gates | Total |
|---|---|---|---|---|
| Low | 6 handoffs | 3–4 | 1 | ~5–6 |
| Medium | 10 | 5–7 | 1 | ~7–9 |
| High | 16 | 8–12 | 1–2 | ~11–16 |

---

## Context Discipline

### Read-Access Boundaries
Strict per-specialist read rules (full matrix in OPERATING_MANUAL.md):
- Each specialist reads only its own scratchpad, persona/SOP, incoming handoff, and assigned backlog context
- No cross-reading other specialists' scratch directories — prevents context pollution

### Scratchpad Size Limits
- `task.md` (Architect): max ~500 lines — compact when over
- `review_report.md` (Reviewer): max ~300 lines — summarize resolved, keep BLOCKER/CRITICAL outstanding
- Health check flags oversized scratchpads as a context-saturation risk

---

## Anti-Patterns This Prevents

| Failure mode | Mechanism that prevents it |
|---|---|
| Prompt injection from external research | Trust boundary + passive injection scan + suspicious_content escalation |
| Agent claims tests pass; they don't | Independent test re-verification (CB 5) |
| Agent fabricates artifact paths | Artifact integrity gate (CB 6) |
| Agent self-escalates budget | Spec-frontmatter cross-validation (CB 4) |
| Agent under-reports handoff count | Log-derived override (CB 4) |
| Infinite review loop | 3-Strike rule (CB 1) with strike-2 DEGRADED signal |
| Runaway token spend | Per-tier handoff ceiling (CB 4) |
| Parallel tasks colliding on same files | File-affinity matrix ({task_id}) |
| Silent merge conflict at master | Merge simulation + rebase loop ({task_id}) |
| Bypassing pre-commit hooks | `--no-verify` triggers security breaker (CB 8) |
| Context pollution between specialists | Read-access matrix + scratchpad limits |
| Stale lock / orphaned worktrees | Auto-cleanup + health check |
| Lost work in worktree | Architect must commit in worktree (lessons learned 2026-05-07) |
| Untraceable agent behavior over time | Prompt version tracking + JSONL event log |

## Agent-Native Orchestration Model

Unlike traditional multi-agent systems (e.g., CrewAI, LangGraph Cloud, Temporal) that require external databases, Docker containers, API servers, background queue workers, or complex web UI dashboards, Crucible uses a zero-overhead **Agent-Native Orchestration** model:

- **Zero-Infra Overhead (No Docker, No DB, No Python):** There is no database setup, no Docker images to pull, and no Python runtime dependencies to configure. The entire orchestrator runs on native shell commands and local files.
- **Single-Session Interactive Loop:** The orchestration state machine runs entirely within your active, interactive agent coding session (such as Claude Code, Gemini CLI, or Codex). When you run the orchestrator, you don't start external daemon processes or background threads; the parent session guides the entire process.
- **Agent-as-Orchestrator Pattern:** The parent agent session adopts the Strategic Orchestrator role. It leverages the client terminal's native sub-agent tools (`invoke_subagent` or `Agent()`) to spawn ephemeral specialists. This keeps all logic, reasoning, and failure handling within a single interactive chat context.
- **Coprocessor Architecture:** Execution is split cleanly between the LLM and the local filesystem scripts. The agent does what LLMs do best (planning, prompting, reasoning, code review), while a simple local script (`factory.ps1`) does what code does best (git worktree manipulation, schema validation, budget tracking, test runs).
- **Zero-Infrastructure Persistence:** State is stored directly in the workspace directory using simple, schema-validated JSON files (`session_state.json`, `.json` handoffs). If the terminal session is closed or crashes, the state is persisted naturally; restarting the orchestrator simply resumes the state machine from disk.

## Toolchain Requirements

Crucible expects the project to declare its own language toolchain and verification commands in `.crucible/config.yaml`. The reference PowerShell implementation assumes:

- PowerShell for local orchestration.
- Git worktrees for implementation isolation.
- GitHub CLI (`gh`) when autonomous CI diagnostics are enabled.
- `jq` for JSONL log analysis.

---

## Philosophy

**Reliability through constraint enables greater autonomy.**

The factory's hard gates, schema validation, independent verification, and circuit breakers are not bureaucracy — they are the price of trusting agent output. Every constraint exists because something failed without it. The collected enforcement is the reason humans can let the pipeline run unattended for hours and trust what comes out.
