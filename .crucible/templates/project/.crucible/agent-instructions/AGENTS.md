## Crucible

This project uses Crucible for multi-agent planning, implementation, review, and handoff control.

Before running a Crucible task:

1. Read `.crucible/config.yaml`.
2. Resolve `crucible_root` from that file. In a normal install this is `.crucible`.
3. Read `{{crucible_root}}/docs/operating-manual.md`.
4. Read `{{crucible_root}}/docs/policy.md`.
5. Read the relevant CLI orchestration guide under `{{crucible_root}}/docs/orchestrators/`.

The `.crucible/` directory is the installed Crucible bundle for this project. It includes docs, prompts, personas, SOPs, schemas, runtime scripts, project config, backlog, and runtime state.

Run the installed runtime from the project root:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId <task-id>
```
