<!-- prompt_version: research-audit-framework-v1 -->
# SOP: Researcher — Crucible Framework Quality Audit

**Use when:** Asked to run a structured quality audit of the Crucible multi-agent framework.

**Trigger form:** `Researcher: Audit Crucible`

**Scorecard:** `.crucible/research/scorecard-framework.md` — read this before proceeding. It defines every category, the standard being measured against, and the signals to audit. This SOP describes the process; the scorecard describes the content.

**Near-term success criteria:** The audit is not evaluating whether the framework is fully autonomous. It is evaluating whether handoffs and human interaction steps are reliable, straightforward, and free of surprises. Weight your findings accordingly.

---

## Inputs Required

| Input | Source | When needed |
|---|---|---|
| Scorecard | `.crucible/research/scorecard-framework.md` | Before starting |
| Operating manual | `{{crucible_root}}/docs/operating-manual.md` | All internal categories |
| Factory script | `{{crucible_root}}/powershell/factory.ps1` | Category 4 |
| Recent handoff files | `.crucible/session/handoffs/` (last 3–5 files) | Categories 1, 6 |
| Recent session task files | `.crucible/session/` (last completed task) | Categories 2, 3, 6, 7 |
| Backlog | `{{backlog_dir}}/BACKLOG.md` | Category 8 |
| Specialist prompt definitions | `{{crucible_root}}/prompts/`, `{{crucible_root}}/personas/`, and `{{crucible_root}}/sops/` | Categories 3, 6 |
| SOPs directory | `.crucible/sops/` | Category 3 |
- Live framework research | Web (GitHub, docs, release notes) | Category 10 only |

Do not do any external web research until you reach category 10.

### Mid-Session Progress (Checkpointing)
Specialists MUST log their progress mid-session to ensure state recovery in case of failure.
- **Mandate**: Write `### CHECKPOINT [Brief Summary]` to `task.md` after completing a major audit category or group.
- **Example**: `### CHECKPOINT Categories 1-4 Internal Audit complete`

---

## Steps

### Step 1 — Load the Scorecard
Read `.crucible/research/scorecard-framework.md` completely before beginning. Understand all 10 categories, the near-term success criteria, and what each rating means.

### Step 2 — Load Internal Documents
Read the following in parallel — you will reference them throughout the audit:
- `{{crucible_root}}/docs/operating-manual.md`
- `.crucible/personas/researcher.md` (and other personas as needed per category)
- `{{crucible_root}}/powershell/factory.ps1` (skim for structure, not line-by-line)
- The 3 most recent handoff files in `.crucible/session/handoffs/`
- The most recently completed task's `task.md`

### Step 3 — Execute Categories 1–9 (Internal Audit)
Work through categories 1–9 in order. All of these are evaluated against internal documents and observable system behavior — no external research. For each:
1. Read the scorecard definition for that category
2. Examine the relevant files (operating manual, handoffs, scripts, prompts)
3. Run the specified audit signals
4. Rate: green (meets standard), yellow (partial gap), red (significant gap)
5. Write one clear gap narrative

**Category 4 note:** To audit factory.ps1 reliability, review the script for error handling patterns and silent failure risks. Do not execute destructive factory operations — review the code and run only `-Health` or `-Init` with a test task ID if safe to do so.

**Category 8 note:** Read `BACKLOG.md` and compare status dates against recent git commits to verify hygiene.

### Step 4 — Execute Category 10 (Live Framework Research)
This is the live research phase. For each of the six reference products defined in the scorecard (LangGraph, CrewAI, AutoGen, AgenticGoKit, Rivet, OpenHands):

1. Fetch current documentation, GitHub README, and recent release notes
2. Answer the five questions from the scorecard for that product:
   - How does it handle handoffs? Is state explicit or implicit?
   - How does it define and enforce specialist/role boundaries?
   - What does its human-in-the-loop protocol look like?
   - How does it recover from agent failure or bad output?
   - What observability does it provide during a session?
3. Compare each answer to the Crucible framework's current approach (from what you read in Step 2)
4. Note: where is the framework ahead? where is it behind? where is the gap deliberate?

Build the gap table from scratch — do not pre-fill it from training knowledge. These frameworks evolve rapidly.

After covering the six named products, do a brief scan for any new multi-agent development frameworks that have gained significant traction in the last 6 months (GitHub star growth, Hacker News mentions, industry coverage). Add any worth tracking to the report.

### Step 5 — Produce the Audit Report
Write the report to `.crucible/research/R-NNN_Crucible_Quality_Audit_<YYYYMMDD>.md` using the output template from the scorecard.

The report must include:
- Summary table with all 10 categories rated
- Top gaps in priority order (weighted toward handoff reliability and human interaction clarity)
- What's working well
- Recommended actions (with clear owner: Human, Groomer, or Architect)
- Patterns to adopt from reference frameworks
- Patterns consciously rejected (with rationale)

### Step 6 — Research Gate + Handoff
The Research Gate fires before the handoff. Present findings and questions to the human using the format in `researcher.md`. Wait for direction on each recommended action (approved / deferred / rejected). Then follow the Handoff Protocol in `researcher.md`, including the `human_decisions` field. The Groomer will only spec items in `human_decisions.approved`.

---

## Quality Bar

Before handing off, verify:
- [ ] All 10 scorecard categories are rated (no blanks)
- [ ] Every red/yellow rating has a specific, actionable gap narrative
- [ ] Category 10 includes live research for all six named frameworks (not training knowledge alone)
- [ ] The gap table in the report is built from fresh research, not pre-populated
- [ ] Recommendations are prioritized toward the near-term goal: handoff reliability and human gate clarity
- [ ] No verbatim copy-paste from external sources
- [ ] `suspicious_content` field is set
