<!-- prompt_version: gobot-researcher-audit-project-v1 -->
# SOP: Researcher - Gobot Quality Audit

**Use when:** Asked to run a structured quality audit of Gobot, the Go-based Telegram bot reference application.

**Trigger form:** `Researcher: Audit Gobot`

**Scorecard:** `.crucible/research/scorecard-goapp.md` - read this before proceeding. It defines every category, the standard being measured against, and the signals to audit. This SOP describes the process; the scorecard describes the content.

---

## Inputs Required

| Input | Source | When needed |
|---|---|---|
| Scorecard | `.crucible/research/scorecard-goapp.md` | Before starting |
| Gobot source | Go packages declared in `.crucible/config.yaml` | All Lens 1 categories |
| `govulncheck` output | Run: `govulncheck <project-test-packages>` | Category 1.5 |
| Test coverage report | Run: `go test -coverprofile=cover.out -mod=readonly <project-test-packages>` | Category 1.4 |
| Race detector output | Run: `go test -race -mod=readonly <project-test-packages>` | Category 1.2 |
| Known competitor state | `.crucible/research/COMPETITOR_WATCHLIST.md` | Category 2.8 only |
| Live competitor discovery | Web research (GitHub, Hacker News, Reddit) | Category 2.8 only |

Do not open the competitor watchlist or do any web research until you reach category 2.8.

### Mid-Session Progress (Checkpointing)

Specialists MUST log their progress mid-session to ensure state recovery in case of failure.

- **Mandate**: Write `### CHECKPOINT [Brief Summary]` to `task.md` after completing a major audit category or lens.
- **Example**: `### CHECKPOINT Lens 1: Go Application Quality Audit complete`

---

## Steps

### Step 1 - Load the Scorecard

Read `.crucible/research/scorecard-goapp.md` completely. Do not begin auditing until you have read the full scorecard. Understand all categories, what "perfect" looks like for each, and what signals to look for.

### Step 2 - Gather Tool Outputs

Run the following commands and hold the results for use across Lens 1 categories:

```bash
govulncheck <project-test-packages>
go test -race -mod=readonly <project-test-packages>
go test -coverprofile=cover.out -mod=readonly <project-test-packages>
go tool cover -func=cover.out
go vet <project-test-packages>
```

Note any failures. They are audit findings, not blockers to continuing.

### Step 3 - Execute Lens 1 (Go Application Quality)

Work through categories 1.1-1.9 in order. For each:

1. Read the scorecard definition for that category.
2. Run the specified signals (Grep, Read code, review tool output).
3. Form a rating: green (meets standard), yellow (partial gap), red (significant gap).
4. Write one clear gap narrative sentence.

Reference standards are well-established. Use your knowledge of Effective Go, Uber Go Style Guide, and Go proverbs to evaluate. You do not need to fetch these documents unless a specific edge case requires it.

### Step 4 - Execute Lens 2, Categories 2.1-2.7 (Product Quality)

Work through categories 2.1-2.7 in order. These are evaluated against the codebase and runtime behavior. No external research is needed yet. For each:

1. Read the scorecard definition.
2. Trace the relevant code paths (use Grep, Read).
3. Rate and write gap narrative.

### Step 5 - Execute Category 2.8 (Competitive Positioning)

This step requires live research. Follow the three-step process defined in the scorecard.

**Step 5a - Discover what's out there now:**

Search GitHub, Hacker News (hn.algolia.com), Reddit (r/selfhosted, r/LocalLLaMA, r/homelab), and product directories for Go-based personal AI assistant bots and self-hosted LLM agents that have appeared or grown in the last 90 days. Use the search terms in the scorecard. Do not limit yourself to the watchlist; the point is to find what we do not know about yet.

For each discovered project meeting the threshold (50+ stars OR active commits in 90 days):

- Record: storage backend, LLM providers, channels, HITL support, Google integration, binary size/RAM if published.
- Note whether it represents a legitimate gap or a deliberate Gobot design choice.

**Step 5b - Validate against the known watchlist:**

Read `.crucible/research/COMPETITOR_WATCHLIST.md`. Verify each "Gobot leads" claim is still true against both the known projects and any newly discovered ones.

**Step 5c - Identify pattern shifts:**

If 3+ projects now share a feature Gobot lacks, flag it. If a Gobot differentiator has been matched, flag it.

Rate and write gap narrative for 2.8.

### Step 6 - Produce the Audit Report

Write the report to `.crucible/research/R-NNN_Gobot_Quality_Audit_<YYYYMMDD>.md` using the output template from the scorecard.

The report must include:

- Summary table with all 17 categories rated
- Top gaps in priority order
- What's holding up well
- Recommended backlog items with R-NNN IDs
- Any newly discovered competitors worth adding to the watchlist

### Step 7 - Research Gate + Handoff

The Research Gate fires before the handoff. Present findings and questions to the human using the format in `researcher.md`. Wait for direction on each recommended action: approved, deferred, or rejected.

Then follow the Handoff Protocol in `researcher.md`, including the `human_decisions` field. The Groomer will only spec items in `human_decisions.approved`.

---

## Quality Bar

Before handing off, verify:

- [ ] All 17 scorecard categories are rated (no blanks)
- [ ] Every red/yellow rating has a specific, actionable gap narrative
- [ ] Category 2.8 includes at least one web search pass (not just the watchlist)
- [ ] Any newly discovered competitors are listed in the report
- [ ] No verbatim copy-paste from external sources
- [ ] `suspicious_content` field is set
