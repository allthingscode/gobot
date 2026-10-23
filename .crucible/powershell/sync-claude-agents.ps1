[CmdletBinding()]
param(
    # The project whose .claude/agents/ receives the crucible-*.md files.
    [string]$ProjectRoot = "",
    # Report missing or stale files and exit 1 without writing anything.
    [switch]$Check
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/config-helpers.ps1")
. (Join-Path $PSScriptRoot "lib/claude-agents.ps1")

$root = Resolve-ConfigProjectRoot -ProjectRoot $ProjectRoot
$dir = Get-ClaudeAgentsDir -ProjectRoot $root

if ($Check) {
    $drift = @(Get-ClaudeAgentDrift -ProjectRoot $root)
    if ($drift.Count -eq 0) {
        Write-Host "[CLAUDE AGENTS] up to date in $dir"
        exit 0
    }
    foreach ($item in $drift) {
        Write-Host ("[CLAUDE AGENTS] " + $item.Status + ": " + $item.Name) -ForegroundColor Yellow
    }
    Write-Host ("[CLAUDE AGENTS] regenerate with: " + (Get-ClaudeAgentRegenerateCommand -ProjectRoot $root)) -ForegroundColor Yellow
    exit 1
}

$warning = Get-ClaudeAgentIgnoreWarning -ProjectRoot $root
if ($warning) { Write-Warning $warning }
$written = @(Write-ClaudeAgentDefinitions -ProjectRoot $root)
foreach ($path in $written) {
    Write-Host ("[CLAUDE AGENTS] wrote " + $path)
}
exit 0
