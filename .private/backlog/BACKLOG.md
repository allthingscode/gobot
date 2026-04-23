# Gobot Strategic Backlog

Master index for the Go-native Strategic Edition agent. This backlog is the single source of truth for all planned features, active bugs, and architectural refactors.

*Last groomed: 2026-04-22 — B-056 (P1) and B-057 (P2) shipped. C-187–C-192 added from R-004/R-006 audit gaps.*

---

## **Prioritization Principles**

All items in this backlog must be prioritized strictly according to the following principles:
1. **Increase Stability:** Fixes for crashes, silent failures, and core reliability issues (e.g., config validation, resource leaks) always take precedence over new features.
2. **Decrease Fragility:** Refactoring brittle systems (e.g., error handling, resource cleanup) and expanding test coverage are prioritized above cosmetic or QoL improvements.
3. **Avoid New Bugs:** Implementation plans must include defensive coding practices and adequate observability (logs, metrics) to prevent the introduction of new regressions.

**Process guidance**: See AGENTS.md and .private/sops/groomer.md for Agent/Groomer workflow.

**Directory Layout**:
- `features/active/` — Active feature work (F-XXX.md)
- `features/archived/` — Completed features
- `bugs/active/` — Active bug fixes (B-XXX.md)
- `bugs/archived/` — Fixed bugs
- `chores/active/` — Active maintenance tasks (C-XXX.md)
- `chores/archived/` — Completed chores
- `blocked/` — Dead-letter holding for blocked tasks (exceeded circuit breakers)
- `../session/global/gate_decisions/` — Human Gate decision records (C-096)
- `BACKLOG.md` — Master index (this file)
- `ARCHIVED.md` — Historical archive table (reference only)

---

## **Active Items**

### **Bugs**

| ID | Title | Priority | Specialist | Status |
|---|---|---|---|---|

### **Chores**

| ID | Title | Priority | Specialist | Status |
|---|---|---|---|---|
| C-183 | Mandate ### CHECKPOINT Pattern in Specialist SOPs | P3 | Groomer | Backlog |
| C-185 | Visual Session Navigator (Dashboard) | P3 | Architect | Backlog |
| C-186 | Improve pre-commit/pre-push checks to catch platform-specific test issues | P2 | Architect | Backlog |
| C-187 | Bring Critical Packages to 80% Test Coverage | P2 | Architect | Backlog |
| C-188 | Replace time.Sleep Poll Patterns in Tests with Channel Synchronization | P3 | Architect | Backlog |
| C-189 | Wrap Bare return err Instances with fmt.Errorf Context | P3 | Architect | Backlog |
| C-190 | Add OTel Spans to Google API and Memory Search Call Paths | P3 | Architect | Backlog |
| C-191 | Publish Binary Size and Idle RSS Baseline in README | P3 | Operator | Backlog |
| C-192 | Document Expected Human Interaction Count per Budget Tier | P3 | Architect | Backlog |
| C-193 | Add Hermes Agent and nanobot to COMPETITOR_WATCHLIST.md | P3 | Groomer | Backlog |

---

## **Priority Summary**

| Priority | Count | Items |
|:---:|:---|:---|
| **P1** | 0 | - |
| **P2** | 2 | C-186, C-187 |
| **P3** | 8 | C-183, C-185, C-188, C-189, C-190, C-191, C-192, C-193 |

**Status Overview**: 10 active items.

