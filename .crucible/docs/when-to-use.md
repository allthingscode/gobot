# When To Use Crucible

> Decision guide: when Crucible is worth the ceremony, and when it is not.

This doc exists to help you decide. It deliberately does not restate the mechanics -
[why-crucible.md](why-crucible.md) has the pitch and the mental model,
[policy.md](policy.md) is canonical for gates and circuit breakers, and
[operating-manual.md](operating-manual.md) has the full workflow. Numbers and
thresholds live there, not here, so this page cannot drift out of sync with them.

---

## The one question

Crucible's whole reason to exist is that it does not take an agent's word for
anything. It re-runs the tests itself, checks that claimed artifacts exist, and
refuses to close a task whose commit it cannot prove landed. That machinery costs you
time and interruptions.

So the decision reduces to one question:

> **What does it cost me if an agent tells me something is done, and it isn't?**

If the answer is "I'd notice immediately and just re-run it," use a plain agent
session. If the answer is "it would reach a real branch, a real user, or a real
audit," the enforcement is worth what it costs.

Everything below is an elaboration of that question.

---

## Good fit

- **Shipping to a repo you actually care about.** The merge is proven, not asserted.
- **Multi-step work that outlives one context window.** State is on disk, so a
  crashed or compacted session resumes rather than restarts.
- **Work you will have to justify later.** Every phase transition leaves a
  schema-validated record and a structured event log. "Why is this in main?" has an
  answer that is not someone's memory.
- **Tasks where scope creep is the real risk.** Declared `file_affinity` bounds what
  the implementer is allowed to touch, and edits outside it trip a breaker.
- **Running agents with long leash.** The value of hard limits scales with how little
  you are watching. If you intend to supervise every diff personally, you are already
  the enforcement layer.
- **Work that consumes untrusted external input.** Research is treated as a trust
  boundary with prompt-injection scanning, rather than pasted into the next prompt.

## Poor fit

This is the half that matters most, and the half most tools skip.

- **One-off scripts, spikes, throwaway prototypes.** The ceremony is pure overhead.
  Open an agent session.
- **Exploration, where you do not yet know what you want.** Crucible wants a spec with
  acceptance criteria up front. If you are still deciding what to build, it fights you.
- **Anything needing fast iteration cycles.** Each phase is a separate dispatch with
  validation between. That is the point, and it is slower than typing at an agent.
- **Trivial or mechanical changes** - a typo, a version bump, a rename. The pipeline
  costs more than the change.
- **Emergencies.** A production incident at 2am is not the time for a five-phase
  pipeline with a human gate. Fix it, then let Crucible handle the follow-up hardening.
- **Projects without git.** Worktree isolation is load-bearing, not decorative.
- **Teams wanting a shared dashboard or assignment queue.** Crucible is single-session
  and local-first by design; a GUI is an explicit non-goal (see
  [ROADMAP.md](../ROADMAP.md)).
- **If you will not run PowerShell.** The runtime is PowerShell (5.1 on Windows, `pwsh`
  7+ on Linux/macOS). There is no other implementation today.

---

## What it actually costs you

Stated plainly, so the trade is visible:

- **Human interruptions.** Every task hits at least one mandatory human gate, plus
  confirmations at non-gate transitions unless you pass `-AutoAdvance`. Budget tiers
  cap total handoffs per task; the current ceilings are in
  [policy.md](policy.md#2-circuit-breakers).
- **Wall-clock time.** Phases are serialized and each one re-validates the last.
- **Spec discipline up front.** A task without acceptance criteria will not get
  through grooming cleanly.
- **A bundle in your repo.** The installed `.crucible/` is yours to own, edit, and
  commit. That is the design (same model as shadcn/ui), but it is real surface area.
- **Maturity.** Crucible is a personal high-trust harness, primarily field-tested on
  one project ([examples/gobot](../examples/gobot), a Go service). The runtime is
  language-agnostic through `config.yaml` and ships presets for Go, Node, Python, and
  Rust, but you should expect to be an early adopter rather than a customer.

---

## How it compares

Category-level, because the specific tools move faster than this page can. The useful
question is not "which is best" but "which axis do I need."

| Category | Examples | Where it wins | Where Crucible differs |
|---|---|---|---|
| A plain agent session | Claude Code, Codex, Gemini CLI, Cursor | Fastest path from idea to diff; zero setup | No enforcement. The agent's report *is* the result |
| Multi-agent frameworks | LangGraph, CrewAI, AutoGen | General-purpose; you compose any workflow | They give you the graph; you still write the verification. Crucible ships opinionated software-delivery enforcement |
| Hosted autonomous coding agents | the "assign it a ticket" category | Convenience, team visibility, no local setup | You generally cannot inspect or modify the enforcement. Crucible's gates are files in your repo you can read and edit |
| Durable workflow engines | Temporal, Airflow | Real execution guarantees at scale | Infrastructure to run, and agnostic about code review and merge discipline |
| CI + human code review | what you already have | Mature, trusted, team-wide | Catches problems *after* the branch exists. Crucible enforces during the loop. **These are complements, not substitutes** |

**The axis Crucible is actually different on:** independent, post-hoc verification of
agent claims inside the development loop, where the enforcement itself is auditable and
version-controlled alongside your code.

Two honest caveats about that claim:

1. **"No Docker, no database, no Python" is a real convenience, not a differentiator.**
   Plenty of tools are lightweight. It lowers the cost of adopting Crucible; it is not
   the reason to.
2. **Crucible does not replace human review or CI.** It reduces how much you have to
   verify by hand. Treating it as a substitute for either is a misuse - see
   [ROADMAP.md](../ROADMAP.md) non-goals.

---

## Still not sure

The cheapest way to answer this is not to read more. Run
[get-started.md](get-started.md) against a real project and give it one small,
genuine task - something you would otherwise hand to an agent directly. About ten
minutes of setup, one task through five phases.

You will know within one cycle whether the enforcement feels like a seatbelt or a
straitjacket. That answer is project-specific and no doc can give it to you.

---

## Where the details live

| Question | Doc |
|---|---|
| What is this and why does it exist? | [why-crucible.md](why-crucible.md) |
| How do I install it? | [bootstrap.md](bootstrap.md), [get-started.md](get-started.md) |
| What are the gates and breakers, exactly? | [policy.md](policy.md) |
| What is the full workflow? | [operating-manual.md](operating-manual.md) |
| What can I configure? | [config-reference.md](config-reference.md) |
| Where is it going, and what will it never do? | [ROADMAP.md](../ROADMAP.md) |
