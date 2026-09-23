# Grok TUI Strategic Orchestrator Protocol

This document defines **Grok TUI / Grok Build-specific** mechanics for Crucible pipeline orchestration. Read `.crucible/docs/orchestrator.md` and `.crucible/sops/orchestrator.md` first - the persona establishes who you are, the SOP defines the loop and gate protocols. This document covers only how to invoke sub-agents and run Crucible commands in a Grok session.

> **Invocation.** Commands use `pwsh` (PowerShell 7+). Windows PowerShell 5.1 is not supported.

## The "Orchestrate" Directive

When the human says `"Orchestrate {TASK_ID}"` or `"Orchestrate the next task in the backlog"`, this Grok session adopts the **Strategic Orchestrator** persona. The current session is the controller. It does not become Groomer, Architect, Reviewer, Operator, or Researcher.

## Adapter Boundary

`.crucible/sops/orchestrator.md` remains the canonical, platform-neutral SOP. Keep Grok tool mappings in this file. If a rule applies to every runtime, update the SOP.

## Workspace vs Adopter (D48)

A Grok session may be opened on the Crucible framework repo while the task targets an adopter (for example gobot). Built-in file tools then resolve against the framework tree.

Before the first `crucible.ps1 -Init`:

1. Read the adopter's `.crucible/config.yaml` (absolute path) and capture `crucible_root`.
2. Pass `-ProjectRoot` set to the adopter root on every Crucible script.
3. Set `cwd` on every `spawn_subagent` to that adopter root.
4. Specialists must use absolute adopter paths.

Do not dogfood against `examples/gobot`. That tree is a byte-identical mirror, not an install. Do not install a `.crucible/` into the framework repo.

## Sub-Agent Invocation

Grok's `spawn_subagent` tool is the native specialist mechanism.

- Groomer, Architect, Reviewer, Operator: `subagent_type` `general-purpose`.
- Researcher: `subagent_type` `explore` (read-only tools; that is the trust boundary).
- Do not use `plan` for a pipeline specialist.
- Do not pass `isolation: "worktree"`. Crucible owns task worktrees under `.crucible/.agent-workspaces/`.
- Do not pass orchestrator session history. The specialist prompt is a file pointer, not a briefing.

`spawn_subagent` returns immediately (`background` defaults to true). Wait with `get_command_or_subagent_output` until that specialist finishes. Do not dispatch the next phase while one is running.

Do not pass Claude or Codex model slugs (`sonnet`, `opus`, `gpt-5.5`) as `model`. Omit `model` so the child inherits this session, or pass `grok-4.6` / `grok-4.5` only when the human asked. There is no `models.targets.grok` row yet; native Grok specialists do not read `[RECOMMENDED MODEL]` from `-Target claude` or `-Target codex`.

### Default Specialist Target: Native Grok

In this operating configuration, **Grok is the orchestrator and Grok `spawn_subagent` runs specialist work**. Fall back to the Codex launcher (see below) only when the human asks for Codex on a phase, or when a native dispatch cannot run. The orchestrator itself stays Grok.

### Standard Specialist Dispatch (Groomer, Architect, Reviewer, Operator)

```
spawn_subagent({
  subagent_type: "general-purpose",
  cwd: "{adopter project root}",
  description: "{Phase} session for {task_id}",
  prompt: `{Role}: {task_id} - read and follow all instructions in
.crucible/session/{task_id}/{phase}/prompt.md

Follow your SOP checkpoint mandate: append \`### CHECKPOINT [brief summary]\`
to task.md after each major phase. Do not write the final handoff until all
required task checklist items are complete.

After writing handoff JSON, run:
  pwsh -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/crucible.ps1" -Init -TaskId {task_id} -ProjectRoot "{adopter project root}" -Quiet

Report the Crucible output verbatim. Stop after reporting. Do not spawn successor agents.`
})
```

Then wait on the returned subagent id. After it completes, follow `.crucible/sops/orchestrator.md` Step 5, then Step 6.

### Researcher Dispatch

Same prompt shape, but `subagent_type: "explore"` and `prompt.md` under `research/`.

### Bootstrap: Groomer Selects Next Item

When no task ID is known (human said "Orchestrate the next task in the backlog"):

```
spawn_subagent({
  subagent_type: "general-purpose",
  cwd: "{adopter project root}",
  description: "Groomer bootstrap - select next backlog item",
  prompt: `Groomer: Next Item

Read AGENTS.md, <crucible_root>/docs/operating-manual.md, <crucible_root>/personas/groomer.md, and
.crucible/sops/grooming.md. Select the next eligible backlog item. Once you have
selected a task ID, create your scratchpad at
.crucible/session/<selected_task_id>/grooming/task.md (create the directory if
needed) and use it for all ### CHECKPOINT entries throughout your session.

Write or update the item's spec, write the grooming -> implementation handoff, then run:

  pwsh -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/crucible.ps1" -Init -TaskId <selected_task_id> -ProjectRoot "{adopter project root}" -Quiet

Do not write the handoff until required checklist items are complete. Stop after
Crucible output is produced. Report the selected task ID and Crucible output verbatim.`
})
```

Wait for the sub-agent to return. Read the reported task ID. Ask the human for confirmation before dispatching the Architect.

## Optional: Codex as a Specialist Under Grok

A phase may still run as a Codex specialist. Do not use a Grok `spawn_subagent` for that phase. Use the Crucible launcher:

```
pwsh -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/launch-codex-specialist.ps1" -Preflight -Model {model}
```

Proceed only on `[CODEX PREFLIGHT] PASS`. Then:

```
pwsh -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/launch-codex-specialist.ps1" `
  -TaskId {task_id} -Phase {phase} -Model {model} -Effort {effort} `
  -WorkingDir {adopter-or-worktree}
```

Resolve `{model}` / `{effort}` with `crucible.ps1 -Init -Target codex`. Trust `[CODEX SPECIALIST] STATUS=SUCCESS` plus the SOP Step 5 checks; never record `STATUS=LAUNCH_FAILED` as a review verdict. Full launcher rules (including the no-hand-holding rule for `prompt.md`) live in `docs/orchestrators/claude.md` ("Dispatching a Codex Specialist") and `docs/orchestrators/codex.md`.

## Running Crucible Commands

```powershell
pwsh -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/crucible.ps1" -Init -TaskId {task_id} -ProjectRoot "{adopter project root}" -Quiet
```

On Windows, invoke `pwsh` directly. Do not wrap the call in `powershell.exe`, and do not look up `powershell.exe` on PATH.

### When the terminal is cmd.exe

cmd.exe strips only plain double quotes. Any other quoting reaches `pwsh` as part of the path. `pwsh` then exits 64 with "The argument '...' is not recognized as the name of a script file", even though the file exists. These forms fail that way:

- Backslash-escaped quotes: `pwsh -File \"C:\gobot\.crucible\powershell\crucible.ps1\"`. Some tool layers add the backslashes themselves.
- Single quotes: `pwsh -File 'C:\gobot\.crucible\powershell\crucible.ps1'`.
- A quoted path that ends in a backslash: `"C:\gobot\"`. The backslash escapes the closing quote, so the rest of the line joins the path. This applies to `-ProjectRoot` as well.

If exit 64 appears, drop the quotes. Set the working directory to the adopter root, pass `-File` a relative path, and pass the absolute adopter root to `-ProjectRoot` unquoted with no trailing backslash:

```
pwsh -ExecutionPolicy Bypass -File .crucible/powershell/crucible.ps1 -Init -TaskId {task_id} -ProjectRoot {adopter project root} -Quiet
```

Keep `-ProjectRoot` absolute. Some code paths join a relative root against the current directory, so `.` is only safe while nothing changes directory. If the adopter root contains a space, it cannot go unquoted. Put the command in a `.cmd` wrapper in the adopter root, quote the root inside the wrapper, and run the wrapper.

The orchestrator runs `crucible.ps1 -Init` at two points per specialist cycle:

1. Before dispatch - to verify the previous handoff and assemble the next prompt
2. After the specialist returns - to advance the pipeline and detect gates

## After Each Sub-Agent Returns

Follow `.crucible/sops/orchestrator.md` **Step 5** (verify specialist output and track budget), then **Step 6** (run Crucible and check for gates). A gate signal at `.crucible/session/{task_id}/gate_pending.txt` goes straight to the Gate Protocol before anything else.

Point at Step 5; do not re-inline it.

## Human Confirmation Model

Before every specialist dispatch, present the status report format defined in `.crucible/sops/orchestrator.md` Step 3. The human is the Pilot in Command. Do not dispatch until the human confirms with an explicit "go" or redirect.

## Gate and Failure Protocols

All gate presentation formats and the failure decision tree are in `.crucible/sops/orchestrator.md`. Follow them exactly.

After recording a Human Gate decision via `crucible.ps1 -GateOutcome`, stop. Do not spawn another specialist. Do not run `crucible.ps1 -Init` looking for the next prompt.

A task that merges code to trunk is not done until adopter CI for the merge commit reports `[CI WATCH] STATUS=GREEN`. After any push of accepted task work, run `{{crucible_root}}/powershell/watch-adopter-ci.ps1 -Commit <merge-sha>`.

The orchestrator MUST NOT complete specialist work to keep the loop moving.

## Status

**Status**: ACTIVE
**Owner**: Grok TUI Agent
