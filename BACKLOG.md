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
- `features/active/` â€” Active feature work (F-XXX.md)
- `features/archived/` â€” Completed features
- `bugs/active/` â€” Active bug fixes (B-XXX.md)
- `bugs/archived/` â€” Fixed bugs
- `chores/active/` â€” Active maintenance tasks (C-XXX.md)
- `chores/archived/` â€” Completed chores
- `blocked/` â€” Dead-letter holding for blocked tasks (exceeded circuit breakers)
- `../session/global/gate_decisions/` â€” Human Gate decision records (C-096)
- `BACKLOG.md` â€” Master index (this file)
- `ARCHIVED.md` â€” Historical archive table (reference only)

---

## **Active Items**

### **Bugs**

| ID | Title | Priority | Specialist | Status |
|---|---|---|---|---|

### **Features**
| ID | Title | Priority | Specialist | Status |
|---|---|---|---|---|

### **Chores**
| ID | Title | Priority | Specialist | Status |
|---|---|---|---|---|
| C-209 | Isolate Concurrent Test Execution | Production |

---

## **Priority Summary**

| Priority | Count | Items |
|:---:|:---|:---|
| **P1** | 1 | C-209 |
| **P2** | 0 | - |
| **P3** | 0 | - |

**Status Overview**: 1 active item.












