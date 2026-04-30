# Gobot Strategic Backlog

Master index for the Go-native Strategic Edition agent. This backlog is the single source of truth for all planned features, active bugs, and architectural refactors.


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
| B-060 | Doctor Race Test Around Browser Lookup | P1 | Architect | Planning |

### **Features**
| ID | Title | Priority | Specialist | Status |
|---|---|---|---|---|
| F-128 | Comprehensive Google Cloud Setup Guide | P2 | Researcher | Planning |
| F-129 | Security & Secrets Management Guide | P2 | Researcher | Planning |
| F-130 | Deployment & Persistence Guide | P2 | Researcher | Planning |
| F-133 | Automatic Workspace Initialization | P2 | Architect | Planning |

### **Chores**
| ID | Title | Priority | Specialist | Status |
|---|---|---|---|---|
| C-211 | Go Version Compatibility Audit | P1 | Groomer | Production |

---

## **Priority Summary**

| Priority | Count | Items |
|:---:|:---|:---|
| **P0** | 0 | - |
| **P1** | 2 | B-060, C-211 |
| **P2** | 4 | F-128, F-129, F-130, F-133 |
| **P3** | 0 | - |

**Status Overview**: 6 active items.
