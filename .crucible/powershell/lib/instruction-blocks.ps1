# Idempotent instruction-block management for adopter root instruction files.
# Owns the sentinel markers, canonical block content, and append/detect logic.

$SENTINEL_START = "<!-- crucible-instructions-start -->"
$SENTINEL_END   = "<!-- crucible-instructions-end -->"

function Get-CrucibleBlock {
    <#
    .SYNOPSIS
        Returns a hashtable mapping filenames to their canonical Crucible block content.
        Content matches docs/agent-instructions.md and is wrapped with sentinel markers.
    #>
    if (-not (Get-Command Get-PwshCommand -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot "platform.ps1")
    }
    $pwshCmd = Get-PwshCommand

    $agentsBody = @'
## Crucible

This project uses Crucible for multi-agent planning, implementation, review, and handoff control.

Before running a Crucible task:

1. Read `.crucible/config.yaml`.
2. Resolve `crucible_root` from that file. `crucible_root` defaults to `.crucible` but adopters may configure a different bundle directory.
3. Read `{{crucible_root}}/docs/operating-manual.md`.
4. Read `{{crucible_root}}/docs/policy.md`.
5. Read the relevant CLI orchestration guide under `{{crucible_root}}/docs/orchestrators/`.

The `.crucible/` directory is the installed Crucible bundle for this project. It includes docs, prompts, personas, SOPs, schemas, runtime scripts, project config, backlog, and runtime state.

Commit durable Crucible files:

- `.crucible/config.yaml`
- `.crucible/.gitignore`
- `.crucible/README.md`
- `.crucible/docs/`
- `.crucible/personas/`
- `.crucible/sops/`
- `.crucible/prompts/`
- `.crucible/schemas/`
- `.crucible/powershell/`
- `.crucible/agent-instructions/`

Do not commit runtime data:

- `.crucible/session/`
- `.crucible/.agent-workspaces/`
- `.crucible/locks/`
- `.crucible/tmp/`
- `.crucible/cache/`
- generated logs, JSONL files, handoffs, and eval output

Run the installed runtime from the project root:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "{{crucible_root}}/powershell/factory.ps1" -Init -TaskId <task-id>
```
'@ -replace 'powershell.exe', $pwshCmd

    $claudeBody = @'
# Claude Instructions

Read `AGENTS.md` first.

For Crucible work, read `.crucible/config.yaml`, resolve `crucible_root`, then follow:

- `{{crucible_root}}/docs/operating-manual.md`
- `{{crucible_root}}/docs/policy.md`
- `{{crucible_root}}/docs/orchestrators/claude.md`
'@

    $geminiBody = @'
# Gemini Instructions

Read `AGENTS.md` first.

For Crucible work, read `.crucible/config.yaml`, resolve `crucible_root`, then follow:

- `{{crucible_root}}/docs/operating-manual.md`
- `{{crucible_root}}/docs/policy.md`
- `{{crucible_root}}/docs/orchestrators/gemini.md`
'@

    return @{
        "AGENTS.md" = $SENTINEL_START + "`n" + $agentsBody + "`n" + $SENTINEL_END
        "CLAUDE.md" = $SENTINEL_START + "`n" + $claudeBody + "`n" + $SENTINEL_END
        "GEMINI.md" = $SENTINEL_START + "`n" + $geminiBody + "`n" + $SENTINEL_END
    }
}

function Test-SentinelState {
    <#
    .SYNOPSIS
        Examines a file for sentinel marker state.
    .OUTPUTS
        "None"    - no markers found.
        "Intact"  - matched start/end pair (start before end).
        "Corrupt" - only one marker present, or end appears before start.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return "None"
    }

    $content = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
    $hasStart = $content.Contains($SENTINEL_START)
    $hasEnd   = $content.Contains($SENTINEL_END)

    if (-not $hasStart -and -not $hasEnd) {
        return "None"
    }

    if ($hasStart -and $hasEnd) {
        $startIdx = $content.IndexOf($SENTINEL_START)
        $endIdx   = $content.IndexOf($SENTINEL_END)
        if ($startIdx -lt $endIdx) {
            return "Intact"
        }
        return "Corrupt"
    }

    # Only one marker present
    return "Corrupt"
}

function Add-CrucibleInstructionBlock {
    <#
    .SYNOPSIS
        Idempotently appends a Crucible instruction block to a single file.
    .DESCRIPTION
        - File missing   - creates it with the sentinel-wrapped block.
        - Intact markers - skips with informational message.
        - Corrupt        - throws a terminating error.
        - No markers     - appends block to end of existing content.
    .OUTPUTS
        "Created", "Skipped", or throws on corrupt.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string]$FileName,
        [Parameter(Mandatory=$true)][string]$BlockContent,
        [Parameter(Mandatory=$false)][switch]$Quiet
    )

    $state = Test-SentinelState -FilePath $FilePath

    switch ($state) {
        "Intact" {
            if (-not $Quiet) {
                Write-Host "  [SKIP] $FileName - Crucible block already present." -ForegroundColor DarkGray
            }
            return "Skipped"
        }
        "Corrupt" {
            throw "Crucible sentinel markers in $FileName are corrupted (mismatched start/end). Fix or remove the markers manually before re-running."
        }
        "None" {
            if (Test-Path -LiteralPath $FilePath) {
                # Append to existing file, preserving all existing content
                $existing = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
                # Ensure we start on a new line with a blank separator
                $separator = "`n`n"
                if ($existing.EndsWith("`n`n")) {
                    $separator = ""
                } elseif ($existing.EndsWith("`n")) {
                    $separator = "`n"
                }
                $newContent = $existing + $separator + $BlockContent + "`n"
                [System.IO.File]::WriteAllText($FilePath, $newContent, [System.Text.UTF8Encoding]::new($false))
                if (-not $Quiet) {
                    Write-Host "  [APPEND] $FileName - Crucible block appended." -ForegroundColor Green
                }
                return "Created"
            } else {
                # Create new file with just the block
                $newContent = $BlockContent + "`n"
                $parentDir = Split-Path -Parent $FilePath
                if (-not (Test-Path -LiteralPath $parentDir)) {
                    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
                }
                [System.IO.File]::WriteAllText($FilePath, $newContent, [System.Text.UTF8Encoding]::new($false))
                if (-not $Quiet) {
                    Write-Host "  [CREATE] $FileName - created with Crucible block." -ForegroundColor Green
                }
                return "Created"
            }
        }
    }
}

function Install-CrucibleInstructions {
    <#
    .SYNOPSIS
        Appends Crucible instruction blocks to all three root instruction files.
    .OUTPUTS
        A hashtable with per-file results: "Created", "Skipped", or the function throws on corrupt markers.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$false)][switch]$Quiet
    )

    $blocks = Get-CrucibleBlock
    $summary = @{}

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "[CRUCIBLE] Appending instruction blocks..." -ForegroundColor Cyan
    }

    foreach ($fileName in @("AGENTS.md", "CLAUDE.md", "GEMINI.md")) {
        $filePath = Join-Path $ProjectRoot $fileName
        $result = Add-CrucibleInstructionBlock `
            -FilePath $filePath `
            -FileName $fileName `
            -BlockContent $blocks[$fileName] `
            -Quiet:$Quiet
        $summary[$fileName] = $result
    }

    if (-not $Quiet) {
        Write-Host ""
    }

    return $summary
}
