# Dev Factory — Quick Start Cheat Sheet

This document summarizes the **Human <-> Agent** loop for the robust orchestration protocol.

---

## The Workflow Loop

| Step | Who | Action | Purpose |
| :--- | :--- | :--- | :--- |
| **1. Start** | **Human** | Gives directive ("Orchestrate {task_id}") | Human provides intent; agent initializes the pipeline. |
| **2. Init** | **Orchestrator** | Runs `factory.ps1 -Init` | Scaffolds the task worktree and instructions. |
| **3. Work** | **Specialist** | (via `invoke_agent`) | Sub-agent executes the specific role (Groomer, Architect, etc.) |
| **4. Verify** | **Orchestrator** | Checks task.md & handoff | Orchestrator confirms checkpoints/AC are met before proceeding. |
| **5. Gate** | **Human** | Approve Findings/Merge | Human provides sign-off at mandatory protocol gates. |

---

## Your Role as the Human

Your role is to provide **high-level direction and approval**. You are the "Pilot in Command."
*   **Give intent**: Say things like "Groom {task_id}", "Work the next item", or "Start on C-XXX". The agent handles all mechanics — running scripts, writing handoffs, scaffolding sessions.
*   **Confirm at each handoff**: After each specialist finishes, the agent presents a summary of what was done and the assembled next-step prompt. You say "go" to continue (in this session or another), or redirect as needed.
*   **Hard gate at Operator**: The final mandatory approval before code reaches master.
*   **You choose the model**: The agent tells you which model is recommended for the next step. You can run it here or take the prompt to a different session.
*   **No File Editing**: You should **never** be required to edit a JSON file, a Markdown spec, or any project file. If an agent asks you to do this, remind them it's their job.
*   **No Script Execution**: You should **never** be required to run a PowerShell or Bash script. The agent invokes `factory.ps1` via its Bash tool automatically.

---

## Specialist Roles (The Personas)

| Role | Responsibility | Output |
| :--- | :--- | :--- |
| **Orchestrator** | **Parent/Controller.** Does NO coding or spec writing. Dispatches sub-agents, verifies handoffs, and enforces gates. | *Sub-agent calls* |
| **Researcher** | Explorer & Fact-Finder. Investigates vague problems using external sources. | *Findings* |
| **Groomer** | Technical Spec Writer. De-risks the task by defining AC, scope, and implementation strategy. | *Detailed Spec* |
| **Architect** | Implementer. Performs the coding in an isolated worktree. | *Code & Tests* |
| **Reviewer** | Quality Gate. Validates Architect's work against the spec and project mandates. | *Approval/Strike* |
| **Operator** | Deployment & Health. Merges code to master and performs final cleanup. | *Git Commit* |

### Initial Task Bootstrapping

When starting a task from the backlog using `factory.ps1 -Init -TaskId {id}`, if no active session folder exists, the factory automatically bootstraps the task:
*   It parses the task's frontmatter in the backlog spec file (`{task_id}_{title}.md`) to read `budget_tier`.
*   It always book-ends the task into the `grooming` phase first, regardless of `target_specialist`. Every backlog item enters the pipeline at grooming; the research phase is reached afterward via the `grooming -> research` transition, when the Groomer (or human) determines investigation is needed.
*   It automatically generates an initial book-end handoff from `deployment` to `grooming`, scaffolds the workspace directories, and prepares the Groomer prompt.

---

## The Human Gates (Where you step in)

1.  **Research Gate**: research -> grooming. You MUST approve the researcher's findings and select which "path" to take before the Groomer starts.
2.  **Human Gate**: deployment -> pause. Mandatory final approval of the implemented work; choose Redirect only when you want the pipeline to continue to a specific next item.
3.  **Circuit Breaker Gate**: If a task fails verification 3 times or exceeds its token budget, the pipeline blocks. You decide whether to reduce scope, abandon, or provide new direction.

---

## Your "Power Commands"

These are invoked **by the agent**, not by you. Listed here for reference only.

*   **`"Orchestrate the next task in the backlog."`**: High-level directive to drive a task through the pipeline using isolated sub-agents. All orchestrators share the same meta-role definition (`docs/orchestrator.md`) and SOP (`sops/orchestrator.md`). Tool-specific mechanics: Claude Code → `docs/orchestrators/claude.md`; Antigravity CLI → `docs/orchestrators/antigravity.md`; Codex CLI → `docs/orchestrators/codex.md`.
*   **`factory.ps1 -Init -TaskId {task_id}`**: Dual-purpose — at session START it validates the incoming handoff and scaffolds the workspace; at session END it routes the pipeline to the next specialist. Run by agent via Bash after every handoff.
*   **`factory.ps1 -Init -TaskId {task_id} -AutoAdvance`**: Orchestrator mode — emits `[AUTO-ADVANCE]` for non-gate transitions so the orchestrator chains specialists without waiting for human confirmation. Gate transitions (Researcher→Groomer, Operator→*) always pause.
*   **`factory.ps1 -Health`**: System health check — orphaned worktrees, stale locks, blocked tasks, oversized scratchpads. The only command that does not require `-TaskId`.
*   **`factory-status.ps1`**: Real-time pipeline dashboard — shows in-flight tasks, durations, and health stats.
*   **`factory.ps1 -Doctor`** (or `factory-doctor.ps1`): Readiness check. In an installed bundle it verifies your config parses, the bundle resolves, a PowerShell host is available, the factory scripts are intact, and the tools your `verification` commands call are on PATH — exits non-zero only on a critical failure. Go / `golangci-lint` / `gh` are advisory for adopters (they matter only for the optional GitHub deployment gate).
*   **`git worktree list`**: See which tasks currently have isolated workspaces.
 
**Agent bash invocation** (how agents run the script from a bash shell; use `powershell.exe` on Windows, `pwsh` on Linux/macOS):
```bash
powershell.exe -ExecutionPolicy Bypass \
  -File "{{crucible_root}}/powershell/factory.ps1" -Init -Target agent -TaskId {task_id}
# -Target: agent (default) | claude | codex | antigravity
```

---

## Running Multiple Tasks in Parallel

**You cannot just open a second terminal and expect it to pick up a different task automatically.**
Each task must be groomed first so it has its own handoff file.

| Phase | Rule |
| :--- | :--- |
| **Grooming** | Sequential only — one Groomer at a time (both write to `BACKLOG.md`) |
| **Architect onward** | Fully parallel — each terminal is independent |
| **File Affinity** | `factory.ps1` prevents parallel execution if two tasks edit the same packages. |

### Correct Procedure

**1. Groom each task first (one at a time):**

Tell the agent: `"Groom {task_id}"` — wait for it to finish, then: `"Groom {task_id}"`

Grooming must be sequential because both write to `BACKLOG.md`.

**2. Then run both in parallel — each in its own chat session:**

Open two chat sessions. In each, tell the agent: `"Start Architect on {task_id}"` / `"Start Architect on {task_id}"`. Each agent runs `factory.ps1 -Init -TaskId {id}` and chains forward automatically through Architect → Reviewer → Operator.

**3. Human Gate fires for each pipeline independently.** Approve each one when it arrives.

---

## Pro-Tips for Humans

*   **Don't skip Grooming**: If you send an Architect straight to a vague task, they might hallucinate. Let a Groomer "de-risk" it first.
*   **Trust the JSON**: If the orchestrator script fails, the agent made a mistake in their handoff data. Tell the *same* agent to "Fix your handoff JSON."
*   **Check the Worktree**: If you're an Architect, you **must** be inside `.agent-workspaces/architect-C-XXX/` to do your work. The script will tell you this path.
*   **Minimalist Prompts**: The final command is short because the agent pulls all the details (Reason, artifacts, status) directly from the `handoff.json` and `task.md` files.
