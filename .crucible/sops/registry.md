# Runbook Registry

Human-initiated SOPs and procedures.

**How to use:** Copy the trigger from the table below and paste it into a Claude Code chat. The trigger explicitly names the SOP file so the agent always knows what to do — no guessing from context.

**Pipeline specialist SOPs** (`researcher.md`, `architect.md`, `groomer.md`, `operator.md`, `reviewer.md`) are NOT listed here — `factory.ps1` routes to those automatically. `researcher.md` is the root SOP and routes to task-type-specific sub-SOPs.

---

## Routine Runbooks

| name | title | frequency | trigger (paste into Claude) | last_run | outcome |
|---|---|---|---|---|---|
| health-check | System Health Check | daily | `Follow the procedure in .crucible/sops/health-check.md` | | |
| grooming | Backlog Grooming Session | weekly | `Follow the procedure in .crucible/sops/grooming.md` | 2026-04-22 | success |
| doc-lint | Doc Lint & Bug Filing | ad-hoc | `Follow the procedure in .crucible/sops/doc-lint.md` | 2026-04-22 | success |
| eval-analysis | Quarterly Eval Analysis | quarterly (or every 10 tasks) | `Work the next item` (pick {task_id} from backlog) | | |

---

## Ad-hoc Procedures

| name | title | trigger (paste into Claude) | last_run | outcome |
|---|---|---|---|---|
| system-analysis | Full System Analysis | `Read .crucible/sops/system-analysis.md and start at Phase 0` | | |
| researcher-audit-factory | Dev Factory Quality Audit | `You are the Researcher. Follow .crucible/sops/researcher-audit-factory.md` | | |
| researcher-audit-project | Adopter-Project Quality Audit | `You are the Researcher. Follow .crucible/sops/researcher-audit-project.md` | | |
| researcher-investigate | Ad-hoc Investigation | `You are the Researcher. Follow .crucible/sops/researcher-investigate.md — topic: [TOPIC]` | | |
