# Getting Started with Crucible

This walkthrough takes you from a fresh clone to a completed first task. It uses a TypeScript/Node project as the example to show that Crucible is not Go-specific.

For reference documentation, see [operating-manual.md](operating-manual.md). For circuit breaker recovery, see [CIRCUIT_BREAKER_RUNBOOK.md](CIRCUIT_BREAKER_RUNBOOK.md).

---

## Quickstart

Get from clone to a running first task in under 10 minutes.

### Prerequisites
- Windows + PowerShell 5.1+ (current runtime; Go cross-platform rewrite planned)
- Git
- One of: Go, Node, Python, or Rust toolchain (matching the `-Language` flag below)

### Install
1. Clone the Crucible framework repository to a stable directory outside your project (e.g., `C:\src\crucible`):
```powershell
git clone https://github.com/allthingscode/crucible.git C:\src\crucible
cd C:\src\crucible
```
*(Note: The source clone is only needed at install or update time, never at runtime.)*

2. Run the project initializer against your project root:
```powershell
.\powershell\init-project.ps1 -ProjectRoot <your-project-path> -Language <go|node|python|rust> -WithSampleTask -AppendInstructions
```
This scaffolds `.crucible/` into your project, configures verification commands for your language, adds a sample `F-001_Hello_World` task, and appends Crucible instructions to your AGENTS.md/CLAUDE.md/GEMINI.md.

### Run the sample task
```powershell
cd <your-project-path>
.\.crucible\powershell\factory.ps1 -Init -TaskId F-001
```
Follow the prompts. The factory will scaffold a Groomer session and tell you the next agent command.

---


## Prerequisites

- Windows (PowerShell runtime is the current implementation; see [ROADMAP.md](../ROADMAP.md) for the planned cross-platform Go rewrite)
- Git
- PowerShell 5.1+
- Your project's normal build/test toolchain (in this example: Node + npm)

---

## Step 1 — Initialize Crucible in your project

From the Crucible framework directory, run:

```powershell
powershell\init-project.ps1 -ProjectRoot "<project-root>" -ProjectName "My API"
```

This installs a complete, self-contained `.crucible/` bundle into your project. The application must not reference any external directory paths or absolute paths outside the project repository at runtime. Your project tree now has:

```
my-api/
├── .crucible/
│   ├── config.yaml          ← edit this next
│   ├── .gitignore           ← commit this; it separates durable intent from runtime state
│   ├── backlog/
│   │   ├── BACKLOG.md       ← master task index
│   │   ├── features/        ← feature specs go here
│   │   ├── bugs/            ← bug specs go here
│   │   └── chores/          ← chore specs go here
│   └── README.md
└── <your source code>
```

---

## Step 2 — Configure for your project

Open `.crucible/config.yaml` and replace the placeholder commands:

```yaml
project:
  name: My API
  description: A Node/TypeScript REST API.
  default_branch: main

verification:
  quick:
    - name: test
      command: npm test
  full:
    - name: lint
      command: npm run lint
    - name: typecheck
      command: npx tsc --noEmit
    - name: test
      command: npm test

project_mandates:
  - No direct database access outside the repository layer.
  - All public functions must have JSDoc.
  - No console.log in production code; use the logger module.
```

Validate the config from your project root:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".crucible\powershell\validate-config.ps1" -ConfigPath ".crucible\config.yaml"
```

A passing run confirms no placeholder commands remain.

---

## Step 3 — Create your first backlog item

Create `.crucible/backlog/features/F-001_Add_Health_Endpoint.md`:

```markdown
---
item_id: F-001
title: Add Health Endpoint
status: Ready
priority: P1
target_phase: grooming
budget_tier: low
---

## Summary

Add a `GET /health` endpoint that returns `{ status: "ok", version: "<semver>" }`.

## Acceptance Criteria

- [ ] `GET /health` returns HTTP 200
- [ ] Response body matches `{ status: "ok", version: string }`
- [ ] Endpoint is covered by an integration test
- [ ] No authentication required

## Notes

Version should be read from `package.json` at startup.
```

Add it to `.crucible/backlog/BACKLOG.md`:

```markdown
| ID    | Title                  | Status | Priority | Specialist |
|-------|------------------------|--------|----------|------------|
| F-001 | Add Health Endpoint    | Ready  | P1       | Groomer    |
```

---

## Step 4 — Run the factory for the first time

From your project root:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".crucible\powershell\factory.ps1" -Init -TaskId F-001
```

Expected output:

```
[FACTORY] Validating environment...
[FACTORY] No incoming handoff found for F-001. Bootstrapping Groomer session.
[FACTORY] Scaffolded: .crucible\session\F-001\grooming\task.md
[FACTORY] Scaffolded: .crucible\session\F-001\grooming\prompt.md

[NEXT SESSION COMMAND]
Start a Groomer agent session. Tell it:
  Groomer: F-001 — read and follow all instructions in .crucible\session\F-001\grooming\prompt.md
  Recommended model: fast/cost-effective
```

---

## Step 5 — Run the Groomer

Open an AI agent session (Claude Code, Gemini CLI, Codex, etc.) in your project directory. Paste the command the factory produced:

```
Groomer: F-001 — read and follow all instructions in .crucible\session\F-001\grooming\prompt.md
```

The Groomer will:
1. Read your backlog item and config
2. Write a detailed technical spec with implementation strategy and file scope
3. Write `.crucible\session\handoffs\F-001-{timestamp}.json`
4. Run `factory.ps1 -Init -TaskId F-001`
5. Present the factory output to you

You'll see something like:

```
### GROOMER TASK COMPLETE

- Item: F-001 - Add Health Endpoint
- Status: Ready for Implementation
- Artifacts: .crucible/backlog/features/F-001_Add_Health_Endpoint.md (updated)
- Next Priority: F-001 → Architect

[NEXT SESSION COMMAND]
Architect: F-001 — read and follow all instructions in .crucible\session\F-001\architect\prompt.md
Recommended model: high-capability
```

Confirm with "go" (or "go" in a new session if you prefer a fresh context).

---

## Step 6 — Run the Architect

Paste the command in an agent session:

```
Architect: F-001 — read and follow all instructions in .crucible\session\F-001\architect\prompt.md
```

The Architect will:
1. Read the Groomer's spec
2. Implement the code inside an isolated git worktree at `.crucible\.agent-workspaces\architect-F-001\`
3. Run your verification commands (`npm test`, etc.) inside the worktree
4. Commit the changes inside the worktree
5. Write the handoff and run the factory

You confirm, then run the Reviewer.

---

## Step 7 — Reviewer and Operator

Each runs the same pattern: paste the factory-generated command, agent does its work, presents the next command, you confirm.

The **Reviewer** checks the Architect's work against your spec and runs `npm test`, `npm run lint`, `npx tsc --noEmit`. If anything fails, it routes back to the Architect with a strike. After 3 strikes the task blocks and requires human intervention (see [CIRCUIT_BREAKER_RUNBOOK.md](CIRCUIT_BREAKER_RUNBOOK.md)).

The **Operator** merges the worktree branch to `main`, cleans up the worktree, updates the backlog to `Production`, and presents the **Human Gate**:

```
1) Accept     — work looks good; pause after this item
2) Reject     — something is wrong, rework
3) Redirect   — accept this item and go work on a specific item next
4) Abandon    — do not accept; stop the pipeline
```

Reply with a number. The cycle is complete.

---

## What each `.crucible/` directory holds

| Path | What's in it | Commit? |
|------|-------------|---------|
| `.crucible/config.yaml` | Your project's config | Yes |
| `.crucible/.gitignore` | Separates durable vs. runtime state | Yes |
| `.crucible/docs/` | Installed manuals and policies | Yes |
| `.crucible/personas/` | Installed specialist identities | Yes |
| `.crucible/sops/` | Installed specialist workflows | Yes |
| `.crucible/prompts/` | Installed prompt templates | Yes |
| `.crucible/schemas/` | Installed validation schemas | Yes |
| `.crucible/powershell/` | Installed runtime scripts | Yes |
| `.crucible/backlog/` | Specs and BACKLOG.md | Project choice |
| `.crucible/session/` | Agent scratchpads, handoffs, logs | No (runtime state) |
| `.crucible/.agent-workspaces/` | Git worktrees | No (runtime state) |
| `.crucible/locks/` | Shared file locks | No |

---

## Common first-run issues

**`validate-config.ps1` fails with "placeholder commands found"**
Replace every `replace-with-...` value in `config.yaml` with your actual commands.

**Factory says "no handoff found, bootstrapping"**
That's normal on a first run. The factory creates the Groomer session automatically.

**Agent can't find `prompt.md`**
Make sure the agent's working directory is your project root where the installed `.crucible/` lives.

**Worktree already exists error**
Run `powershell\factory.ps1 -Health` to find and clean up orphaned worktrees from previous runs.

---

## Keeping your bundle up to date

When you want to pull improvements from the upstream Crucible source into your project, see [updating.md](updating.md) for the selective-copy workflow.
