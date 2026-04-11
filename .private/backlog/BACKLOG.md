# Gobot Strategic Backlog

Master index for the Go-native Strategic Edition agent. This backlog is the single source of truth for all planned features, active bugs, and architectural refactors.

*Last groomed: 2026-04-10 — F-025 triaged and Ready; F-030 updated to Planning.*

---

## **Prioritization Principles**

All items in this backlog must be prioritized strictly according to the following principles:
1. **Increase Stability:** Fixes for crashes, silent failures, and core reliability issues (e.g., config validation, resource leaks) always take precedence over new features.
2. **Decrease Fragility:** Refactoring brittle systems (e.g., error handling, resource cleanup) and expanding test coverage are prioritized above cosmetic or QoL improvements.
3. **Avoid New Bugs:** Implementation plans must include defensive coding practices and adequate observability (logs, metrics) to prevent the introduction of new regressions.

**Process guidance**: See AGENTS.md and .private/personas/groomer.md for Agent/Groomer workflow.

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
- `ARCHIVED.md` — Historical archive table (reference only, see Features/Bugs/Chores sections for current state)

---

## **Features**

| ID | Title | Category | Status | Specialist | Priority |
|:---|:---|:---:|:---:|:---:|:---|
| F-030 | [Vector/Semantic Memory Layer](features/archived/F-030_Vector_Semantic_Memory.md) | Feature | Resolved | Architect | P3 |
| F-062 | [Dev Logs via GitHub Discussions](features/active/F-062_Dev_Logs_via_GitHub_Discussions.md) | Documentation | Draft | Draft | P3 |
| F-071 | [Cross-Session Memory Namespace](features/archived/F-071_Cross_Session_Memory_Namespace.md) | Memory | Resolved | Architect | P3 |
| F-072 | [Web Management Dashboard](features/active/F-072_Web_Dashboard.md) | Feature | Draft | Draft | P3 |
| F-073 | [Multi-User Workspace Isolation](features/active/F-073_Multi_User_Workspace_Isolation.md) | Feature | Draft | Draft | P3 |
| F-078 | [Community Health Files (CONTRIBUTING + SECURITY + CoC)](features/active/F-078_Community_Health_Files.md) | Documentation | Draft | Draft | P3 |
| F-082 | [Formalized Session State Graph](features/active/F-082_Formalized_Session_State_Graph.md) | Feature | Draft | Draft | P3 |
| F-083 | [Email Template Separation](features/active/F-083_Email_Template_Separation.md) | Feature | Draft | Architect | P3 |

---

## **Chores**

| ID | Title | Category | Status | Specialist | Priority |
|:---|:---|:---:|:---:|:---:|:---|

---

## **Bugs**

| ID | Title | Category | Status | Specialist | Priority |
|:---|:---|:---:|:---:|:---:|:---|

---

## **Priority Summary (Hardening First)**

| Priority | Count | Items |
|:---:|:---|:---|
| **P1** | 0 | |
| **P2** | 0 | |
| **P3** | 6 | F-062, F-072, F-073, F-078, F-082, F-083 |

**Factory Reliability Sprint (Phase 1)**: Complete.
**Factory Production Hardening (Phase 2)**: Complete.
**Factory Production Hardening (Phase 3)**: Complete.
**Factory Observability & Reliability Hardening (Phase 4)**: Complete.

**Recommended next items**: **F-083** (P3 Email Template Separation).

---

## **Archived**

Archived items have been reorganized by type:
- **Features:** `features/archived/` (81 completed items)
- **Bugs:** `bugs/archived/` (43 completed items)
- **Chores:** `chores/archived/` (72 completed items)

See `ARCHIVED.md` for the legacy index (deprecated as of 2026-04-06).