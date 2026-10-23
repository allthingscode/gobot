# SOP: Specialist Workspace

Read this before writing files in any specialist phase. The phase prompt supplies
the assigned worktree and task paths; the role SOP supplies the permitted outputs.

Claude specialists inherit the orchestrator session directory as their working
directory, not the assigned task worktree. Changing PowerShell location does not
change the process directory used by .NET.

When a task worktree is assigned, for every write use absolute paths under that worktree, including .NET calls such as `[IO.File]::WriteAllText`.

Use absolute adopter paths for file reads and searches when the orchestrator was
opened in the framework checkout. Resolve the task's paths from task.md before
using file tools.

## Pipeline Advancement

At session end, run Crucible yourself via the shell tool using your phase SOP's
advance command; do not ask the human to run it. The phase SOP owns handoff and
output presentation requirements.

## Recovery

When the prompt identifies recovery, re-read the session context and continue from
the last recorded checkpoint. Preserve work already verified as complete.
