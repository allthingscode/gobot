# Quickstart

Get from clone to a running first task in under 10 minutes.

## Prerequisites
- Windows + PowerShell 5.1+ (current runtime; Go cross-platform rewrite planned)
- Git
- One of: Go, Node, Python, or Rust toolchain (matching the `-Language` flag below)

## Install
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

## Run the sample task
```powershell
cd <your-project-path>
.\.crucible\powershell\factory.ps1 -Init -TaskId F-001
```
Follow the prompts. The factory will scaffold a Groomer session and tell you the next agent command.

## Next steps
- For the full walkthrough of one task end-to-end, see [GET_STARTED.md](GET_STARTED.md).
- For the workflow loop and gates, see [cheat-sheet.md](cheat-sheet.md).
- For full reference docs, see [operating-manual.md](operating-manual.md).
- For pulling upstream changes into your installed bundle later, see [updating.md](updating.md).
