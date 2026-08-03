# Getting Started with Crucible

This walkthrough takes you from a fresh clone to a completed first task. It uses a TypeScript/Node project as the example to show that Crucible is not Go-specific.

For reference documentation, see [operating-manual.md](operating-manual.md). For circuit breaker recovery, see [circuit-breaker-runbook.md](circuit-breaker-runbook.md).

---

## Quickstart

Get from clone to a running first task in under 10 minutes.

### Prerequisites
- A PowerShell host: Windows PowerShell 5.1 (built into Windows, the field-tested default) **or** [PowerShell 7+ (`pwsh`)](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) on Windows, Linux, or macOS
- Git
- One of: Go, Node, Python, or Rust toolchain (matching the `-Language` flag below)

> **Running the commands below.** On Windows, run the `.ps1` scripts directly as shown. On Linux/macOS, prefix the script path with `pwsh` (e.g. `pwsh ./powershell/init-project.ps1 ...`). Forward-slash paths work on every platform.

### Install
1. Clone the Crucible framework repository to a stable directory outside your project (e.g., `C:/src/crucible` on Windows, `~/src/crucible` on Linux/macOS):
```powershell
git clone https://github.com/allthingscode/crucible.git crucible
cd crucible
```
*(Note: The source clone is only needed at install or update time, never at runtime.)*

2. Run the project initializer against your project root:
```powershell
./powershell/init-project.ps1 -ProjectRoot <your-project-path> -Language <go|node|python|rust> -WithSampleTask -AppendInstructions
```
This scaffolds `.crucible/` into your project, configures verification commands for your language, adds a sample `F-001_Hello_World` task, and appends Crucible instructions to your AGENTS.md/CLAUDE.md/GEMINI.md.

### Run the sample task
Commit the scaffold first so the factory does not flag the new instruction files as untracked:

```powershell
git add .crucible AGENTS.md CLAUDE.md GEMINI.md
git commit -m "Add Crucible scaffold"
```

```powershell
cd <your-project-path>
./.crucible/powershell/factory.ps1 -Init -TaskId F-001
```
Follow the prompts. The factory will scaffold a Groomer session and tell you the next agent command.

Expected output excerpt:

```
[INIT] No handoff found for task F-001; auto-bootstrapped initial handoff from deployment to grooming at <abs path>/.crucible/session/handoffs/F-001-...
...
[CI] status unavailable (no GitHub remote, or gh could not reach the repo) - skipping
[NEXT SESSION COMMAND] Run the following command:

agent "Groomer: F-001 - read and follow all instructions in <abs path>/.crucible/session/F-001/grooming/prompt.md"
[RECOMMENDED MODEL] sonnet - dispatch the specialist sub-agent with this model.
```

The factory also echoes the full assembled prompt and a CI banner; copy the `agent "..."` line when starting the Groomer.

---


## Prerequisites

- A PowerShell host: Windows PowerShell 5.1 (Windows) or [PowerShell 7+ (`pwsh`)](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) (Windows, Linux, or macOS). The runtime is CI-verified on Windows and Linux; macOS is supported via `pwsh`. See [ROADMAP.md](../ROADMAP.md) for the planned Go rewrite.
- Git
- Your project's normal build/test toolchain (in this example: Node + npm)

---

## Step 1 - Initialize Crucible in your project

This section authors a second task by hand; if you ran the Quickstart above you already have F-001 - use F-002 here.

From the Crucible framework directory, run:

```powershell
./powershell/init-project.ps1 -ProjectRoot "<project-root>" -ProjectName "My API"
```

This installs a complete, self-contained `.crucible/` bundle into your project. The application must not reference any external directory paths or absolute paths outside the project repository at runtime. Your project tree now has:

```
my-api/
|-- .crucible/
|   |-- config.yaml          # edit this next
|   |-- .gitignore           # commit this; it separates durable intent from runtime state
|   |-- backlog/
|   |   |-- BACKLOG.md       # master task index
|   |   |-- features/        # feature specs go here
|   |   |-- bugs/            # bug specs go here
|   |   `-- chores/          # chore specs go here
|   `-- README.md
`-- <your source code>
```

Commit the scaffold before running the factory:

```powershell
git add .crucible
git commit -m "Add Crucible scaffold"
```

---

## Step 2 - Configure for your project

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
powershell.exe -ExecutionPolicy Bypass -File ".crucible/powershell/validate-config.ps1" -ConfigPath ".crucible/config.yaml"
```
*(Linux/macOS: replace `powershell.exe` with `pwsh`.)*

A passing run confirms no placeholder commands remain.

---

## Step 3 - Create your backlog item

Create `.crucible/backlog/features/active/F-002_Add_Health_Endpoint.md`:

```markdown
---
item_id: F-002
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
| F-002 | Add Health Endpoint    | Ready  | P1       | Groomer    |
```

---

## Step 4 - Run the factory for the task

From your project root:

```powershell
./.crucible/powershell/factory.ps1 -Init -TaskId F-002
```
*(Linux/macOS: prefix the script path with `pwsh`.)*

Expected output excerpt:

```
[INIT] No handoff found for task F-002; auto-bootstrapped initial handoff from deployment to grooming at <abs path>/.crucible/session/handoffs/F-002-...
...
[CI] status unavailable (no GitHub remote, or gh could not reach the repo) - skipping
[NEXT SESSION COMMAND] Run the following command:

agent "Groomer: F-002 - read and follow all instructions in <abs path>/.crucible/session/F-002/grooming/prompt.md"
[RECOMMENDED MODEL] sonnet - dispatch the specialist sub-agent with this model.
```

The factory also echoes the full assembled prompt and a CI banner; copy the `agent "..."` line when starting the Groomer.

---

## Step 5 - Run the Groomer

Open an AI agent session (Claude Code, Gemini CLI, Codex, etc.) in your project directory. Paste the command the factory produced:

```
agent "Groomer: F-002 - read and follow all instructions in <abs path>/.crucible/session/F-002/grooming/prompt.md"
```

The Groomer will:
1. Read your backlog item and config
2. Write a detailed technical spec with implementation strategy and file scope
3. Write `.crucible/session/handoffs/F-002-{timestamp}.json`
4. Run `factory.ps1 -Init -TaskId F-002`
5. Present the factory output to you

You'll see something like:

```
### GROOMER TASK COMPLETE

- Item: F-002 - Add Health Endpoint
- Status: Ready for Implementation
- Artifacts: .crucible/backlog/features/active/F-002_Add_Health_Endpoint.md (updated)
- Next Priority: F-002 -> Architect

[NEXT SESSION COMMAND]
agent "Architect: F-002 - read and follow all instructions in <abs path>/.crucible/session/F-002/implementation/prompt.md"
[RECOMMENDED MODEL] sonnet - dispatch the specialist sub-agent with this model.
```

Confirm with "go" (or "go" in a new session if you prefer a fresh context).

---

## Step 6 - Run the Architect

Paste the command in an agent session:

```
agent "Architect: F-002 - read and follow all instructions in <abs path>/.crucible/session/F-002/implementation/prompt.md"
```

The Architect will:
1. Read the Groomer's spec
2. Implement the code inside an isolated git worktree at `.crucible/.agent-workspaces/implementation-F-002/`
3. Run your verification commands (`npm test`, etc.) inside the worktree
4. Commit the changes inside the worktree
5. Write the handoff and run the factory

You confirm, then run the Reviewer.

---

## Step 7 - Reviewer and Operator

Each runs the same pattern: paste the factory-generated command, agent does its work, presents the next command, you confirm.

The **Reviewer** checks the Architect's work against your spec and runs `npm test`, `npm run lint`, `npx tsc --noEmit`. If anything fails, it routes back to the Architect with a strike. After 3 strikes the task blocks and requires human intervention (see [circuit-breaker-runbook.md](circuit-breaker-runbook.md)).

The **Operator** merges the worktree branch to `main`, cleans up the worktree, updates the backlog to `Production`, and presents the **Human Gate**:

```
1) Accept     - work looks good; pause after this item
2) Reject     - something is wrong, rework
3) Redirect   - accept this item and go work on a specific item next
4) Abandon    - do not accept; stop the pipeline
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
Run `./powershell/factory.ps1 -Health` to find orphaned worktrees from previous runs, then `./powershell/factory.ps1 -Cleanup` to preview cleanup or `./powershell/factory.ps1 -Cleanup -Force` to execute it.

---

## Keeping your bundle up to date

When you want to pull improvements from the upstream Crucible source into your project, see [updating.md](updating.md) for the selective-copy workflow.
