# Why Crucible

> An agentic software-development harness that trusts agents the way a compiler trusts source code: assume nothing, verify everything, fail loud.

This is the one-page answer to "what is Crucible and why would I use it." For the
hands-on walkthrough see [get-started.md](get-started.md); for the full operating
rules see [operating-manual.md](operating-manual.md) and [policy.md](policy.md).

---

## The problem

Most agentic coding tools optimize for velocity. Agents are very good at producing
*plausible* work and not yet good at producing *trustworthy* work without external
enforcement. "The agent said the tests passed" and "the tests actually passed" are
different signals, and a velocity-first tool quietly treats them as the same one.

That gap is where bad merges, fabricated results, and silent scope creep live.

## The core idea

Crucible optimizes for **trust**, not speed. It is the enforcement layer around the
agents. The orchestrator validates every claim, isolates every change, and re-runs
verification itself rather than taking an agent's word for anything. "Trust me" is
not a verification strategy.

## How it thinks: five specialists, one deterministic pipeline

Work moves through five phases, each executed by a single-purpose specialist persona.
Phase names drive the runtime; persona names describe the actor doing the work.

| Persona    | Phase          | Produces                                                  |
|------------|----------------|-----------------------------------------------------------|
| Researcher | research       | External findings, with untrusted-input handling          |
| Groomer    | grooming       | Backlog hygiene, task DAG, dependency analysis            |
| Architect  | implementation | Code changes, in an isolated git worktree                 |
| Reviewer   | verification   | Quality findings against schema-defined criteria          |
| Operator   | deployment     | Merge, deploy, post-deploy verification                   |

The **Orchestrator** is not a sixth specialist. It is the meta-role adopted by
whatever AI session drives the pipeline. It dispatches each specialist as a sub-agent,
validates the handoff between phases, enforces gates, and stops at the human gates.
The legal phase transitions form a small state machine - see
[operating-manual.md](operating-manual.md) for the full FSM.

## What actually makes it different

- **Independent verification.** The orchestrator re-runs tests and checks itself,
  post-hoc, instead of trusting the specialist's report. A claimed pass that is not a
  real pass gets caught.
- **Worktree isolation.** Every implementation runs in a dedicated git worktree, never
  in the main checkout. A failed or abandoned task cannot corrupt the working tree.
- **Schema-validated handoffs.** Each phase transition emits a structured artifact that
  is validated before the next persona runs. Malformed or fabricated handoffs are
  rejected, not propagated.
- **Circuit breakers with hard limits.** Runaway review loops, fabricated artifacts,
  budget overrun, scope violations, hook-bypass attempts, and recurring merge conflicts
  all trip a breaker that halts the pipeline and pages a human.
- **Trust boundaries.** External research is treated as untrusted input, with explicit
  prompt-injection awareness, so the web cannot quietly steer a build.
- **Human gates.** Deployment-to-done and research sign-off pause for an explicit human
  decision. The orchestrator never crosses a gate on the human's behalf.
- **Zero-infra, single-session.** No database, no Docker, no Python, no background
  daemon. It runs entirely inside your interactive agent chat (Claude Code, Gemini CLI,
  Codex). State is plain files on disk; a local script (`factory.ps1`) acts as the
  deterministic coprocessor that drives the state machine.

## Enforcement proofs

Every circuit breaker named above is backed by a negative-path test that deliberately
trips it. If the test passes, the breaker is wired; if it fails, the breaker is broken.
The proofs live in `powershell/tests/` and run under `powershell/run-all-tests.ps1`.
See the README's "Enforcement Proofs" table for the breaker-to-test mapping.

## When to use it

Use Crucible when correctness and auditability matter more than raw speed: shipping to
a real repo, multi-step changes that need review, or any workflow where an unverified
agent claim is unacceptable. For a one-off script or a throwaway prototype, the
ceremony is not worth it - reach for a plain agent session instead. See
[when-to-use.md](when-to-use.md) for the longer decision guide.

## Where to go next

- [get-started.md](get-started.md) - clone to first completed task in ~10 minutes.
- [cheat-sheet.md](cheat-sheet.md) - the one-page Human/Agent loop.
- [operating-manual.md](operating-manual.md) - the full workflow and FSM.
- [policy.md](policy.md) - the canonical gates and circuit-breaker rules.
- [README.md](README.md) - the docs index / map of everything.
