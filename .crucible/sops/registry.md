# Runbook Registry

Human-initiated SOPs and procedures.

**How to use:** Copy the trigger from the table below and paste it into a Claude Code chat. The trigger explicitly names the SOP file so the agent always knows what to do - no guessing from context.

The short phrases in `prompts/README.md` (`Researcher: Audit [project name]`, and so on) are human shorthand for the same procedures. They are not an alternative routing table. The trigger column in this registry, and each SOP's **Trigger form:** line, are what to paste when the agent must load a specific file.

**Pipeline FSM phase SOPs** (`research.md`, `implementation.md`, `grooming.md`, `deployment.md`, `verification.md`) are NOT listed here - `crucible.ps1` routes to those automatically. `research.md` is the root SOP and routes to task-type-specific sub-SOPs.

---

## Routine Runbooks

| name | title | frequency | trigger (paste into Claude) | last_run | outcome |
|---|---|---|---|---|---|
| health-check | System Health Check | daily | `Follow the procedure in .crucible/sops/health-check.md` | | |
| grooming | Backlog Grooming Session | weekly | `Follow the procedure in .crucible/sops/grooming.md - Runbook Mode` | 2026-04-22 | success |
| eval-analysis | Quarterly Eval Analysis | quarterly (or every 10 tasks) | `Work the next item` (pick {task_id} from backlog) | | |

---

## Ad-hoc Procedures

| name | title | trigger (paste into Claude) | last_run | outcome |
|---|---|---|---|---|
| system-analysis | Full System Analysis | `Read .crucible/sops/system-analysis.md and start at Phase 0` | | |
| research-audit-project | Adopter-Project Quality Audit | `You are the Researcher. Follow .crucible/sops/research-audit-project.md` | | |
| research-investigate | Ad-hoc Investigation | `You are the Researcher. Follow .crucible/sops/research-investigate.md - topic: [TOPIC]` | | |
