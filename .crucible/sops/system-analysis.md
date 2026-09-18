# SOP: Full System Analysis

**Use when:** You want a structured review of the current state of the adopter project and Crucible, followed by a direction conversation and new backlog items.

**Trigger:** Read this document and follow it top to bottom. Each phase has a single kick-off command.

**Estimated time:** 1-2 hours total (mostly unattended agent time). Three human checkpoints.

---

## Overview

```
Phase 0 -> answer 4 questions (5 min)
Phase 1 -> project audit (the framework audit is maintainer-only)
Phase 2 -> direction conversation (15 min)
Phase 3 -> groomer creates backlog items (run, walk away)
```

---

## Phase 0 - Direction Context (Human)

Before any audit runs, capture the current context. Answer these four questions in your next message or in a scratch file. The researcher agent will read them if you include them in the trigger prompt.

1. **Priority lens** - What matters most right now? Pick one or two: stability/reliability, shipping new features, cutting agent cost, developer experience, competitive positioning.

2. **Constraints** - Any areas that are off-limits this cycle? (e.g., "don't touch the spawn system, it just shipped", "no new dependencies")

3. **Forcing function** - Is there a deadline, upcoming milestone, or external pressure shaping what should land next?

4. **Hypothesis** - What do you *think* the biggest gap is right now? The audits will validate or disprove it.

Write these down - you'll reference them again in Phase 2.

---

## Phase 1a - Framework Audit (Crucible maintainers only)

The Crucible framework audit is run from a Crucible checkout, not from your project. It
rates Crucible and routes its recommendations to Crucible's own owners, so its SOP and
scorecard are not part of your bundle. See `CONTRIBUTING.md` in the Crucible repository.

**If you are an adopter, skip to Phase 1b.** Phase 2 then reads the one report you have.
If the project audit surfaces something that is Crucible's fault rather than your
project's, file it upstream - that is the useful path, and it is faster than auditing a
framework you did not write.

---

## Phase 1b - Adopter-Project Audit

Adopters start here.

```
agent "Researcher: Audit [project name]"
```

The agent reads `.crucible/sops/research-audit-project.md` and the project's scorecard (e.g. `.crucible/standards/scorecard-{project}.md`), audits all categories (including live competitor discovery), and writes a report to `.crucible/research/`.

**Research Gate fires at the end of this session.** Same as above - respond before the agent exits.

---

## Phase 2 - Direction Conversation (Human + Claude)

After the Research Gate has fired and you've approved/deferred/rejected each recommendation, open a new conversation and run this:

```
Read the audit reports from .crucible/research/ (R-NNN files from today).
Then ask me the Direction Questions below and wait for my answers before doing anything else.
```

**Direction Questions** (the agent asks these, you answer):

1. Do the audit findings match your Phase 0 hypothesis, or did something surprise you?
2. Given the approved recommendations from the gate, what is the single most important theme to address this cycle?
3. Are there any approved items you want to hold - not reject, but park for a later cycle?
4. Any items that should be combined into one backlog item rather than filed separately?
5. Is there anything the audits missed that you want added regardless?

After you answer, the agent consolidates into a prioritized list of items ready for the Groomer.

---

## Phase 3 - Backlog Creation

```
agent "Groomer: Create backlog items from today's analysis. Read the audit reports in .crucible/research/ dated today and the approved items from the research gate handoffs."
```

The Groomer creates well-formed backlog items following the standard format. It will not prioritize or interpret - only spec what was approved in Phase 2.

---

## Completion Checklist

- [ ] Phase 0 answers captured before audits started
- [ ] Framework audit report written to `docs/audits/` in the Crucible repo (maintainers only)
- [ ] Adopter-project audit report written to `.crucible/research/`
- [ ] Every Research Gate responded to (approved/deferred/rejected per item)
- [ ] Direction conversation completed (5 questions answered)
- [ ] Backlog items created by Groomer
- [ ] Registry updated: `.crucible/sops/registry.md` -> add run date and outcome
