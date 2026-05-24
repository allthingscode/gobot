<!-- prompt_version: researcher-investigate-v1 -->
# SOP: Researcher — Investigation

**Use when:** Asked to investigate a specific topic, evaluate a library, analyze a gap, or produce a research artifact that the Groomer will convert into backlog items. This is open-ended research with a defined subject but no fixed scorecard.

**Trigger form:** `Researcher: Investigate [TOPIC]`

---

## Inputs Required

| Input | Source |
|---|---|
| Task brief | `.crucible/session/{task_id}/researcher/task.md` |
| Incoming handoff | `.crucible/session/handoffs/{task_id}-*.json` |
| Prior research on topic | `.crucible/research/` (check before going external) |
| Backlog item spec (if applicable) | `.crucible/backlog/{type}/active/{task_id}_*.md` |

---

## Steps

### Step 1 — Orient
Read `task.md` and the incoming handoff. Extract:
- The specific question(s) to answer
- The scope boundary (what is out of scope)
- Any prior research artifacts already linked

### Mid-Session Progress (Checkpointing)
Specialists MUST log their progress mid-session to ensure state recovery in case of failure.
- **Mandate**: Write `### CHECKPOINT [Brief Summary]` to `task.md` after completing a major step (e.g., "Step 4: Discover phase complete").
- **Example**: `### CHECKPOINT Step 5: Synthesis complete`

### Step 2 — Check Prior Research
Scan `.crucible/research/` for existing artifacts related to this topic. If a prior artifact answers the question adequately, summarize the delta since that research was written and skip to Step 5.

### Step 3 — Define Research Questions
Write 3–7 specific questions the research must answer. If you cannot define specific questions, the brief is too vague — escalate to the human before proceeding.

### Step 4 — Discover
Gather findings from external sources. For each source:
- Read and understand the content
- Summarize in your own words — never copy-paste verbatim
- Flag any anomalous content (see trust boundary mandate in `researcher.md`)
- Record the source URL or reference

Sources to check as appropriate:
- GitHub (repositories, issues, release notes, discussions)
- Official documentation
- Hacker News, Reddit (r/golang, r/selfhosted, r/LocalLLaMA)
- Academic or industry papers (if relevant)
- Existing adopter-project codebase (Grep, Glob, Read)

### Step 5 — Synthesize
Across your findings, identify:
- Direct answers to each research question
- Gaps the adopter project has relative to the findings
- Patterns appearing in 3+ sources (signals worth acting on)
- Anything that contradicts a current adopter-project assumption

### Step 6 — Document
Write findings to `.crucible/research/R-NNN_<Topic>.md`. Use the next available R-NNN number.

Required sections:
```
# R-NNN: [Topic]

## Research Questions
[list]

## Findings
[per question]

## Gaps Identified
[what the adopter project lacks, with evidence]

## Recommended Backlog Items
[R-NNN: title — one-sentence rationale]

## Sources
[list with URLs or paths]
```

### Step 7 — Research Gate + Handoff
The Research Gate fires before the handoff. Present findings and questions to the human using the format in `researcher.md`. Wait for direction on each recommended action. Then follow the Handoff Protocol in `researcher.md`, including the `human_decisions` field.

---

## Quality Bar

Before handing off, verify:
- [ ] Every gap claim has a source
- [ ] No verbatim copy-paste from external sources
- [ ] Research questions are answered (or explicitly marked unanswered with reason)
- [ ] `suspicious_content` field is set (null if nothing flagged)
