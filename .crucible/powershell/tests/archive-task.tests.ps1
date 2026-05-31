# Regression tests for powershell/archive-task.ps1.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$SCRIPT = Join-Path $REPO_ROOT "powershell/archive-task.ps1"
$results = @()

function Assert-Result {
    param([string]$Name, [bool]$Condition, [string]$FailureMessage)
    if (-not $Condition) { throw ("FAILED: " + $Name + " - " + $FailureMessage) }
}

function Run-Test {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ("`nTest: " + $Name) -ForegroundColor Cyan
    try { & $Body; Write-Host "PASSED" -ForegroundColor Green; return $true }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red; return $false }
}

function New-MinimalBacklogTree {
    param([string]$Root)
    New-Item -ItemType Directory -Path (Join-Path $Root "features/active")  -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root "features/archived") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root "bugs/active")      -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root "bugs/archived")    -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root "chores/active")    -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root "chores/archived")  -Force | Out-Null
}

function New-SpecFile {
    param(
        [string]$Root,
        [string]$RelPath,
        [string]$ItemId,
        [string]$Type,
        [string]$Priority,
        [string]$Title,
        [string]$Status = "Ready for Deploy"
    )
    $full = Join-Path $Root $RelPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
@"
---
item_id: "$ItemId"
type: "$Type"
status: "$Status"
priority: "$Priority"
target_phase: "deployment"
created_at: "2026-05-25"
---

# $Title
"@ | Set-Content -LiteralPath $full -Encoding UTF8
}

function Invoke-ArchiveTask {
    param([string]$BacklogPath, [string]$SpecPath)
    $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT -BacklogPath $BacklogPath -SpecPath $SpecPath 2>&1)
    return @{ ExitCode = $LASTEXITCODE; Output = ($outputLines -join "`n") }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-archive-task-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Archives chore with Resolved frontmatter and BACKLOG row" -Body {
        $root = Join-Path $tempRoot "chore"
        New-MinimalBacklogTree -Root $root
        $activeRel = "chores/active/C-101_Close_The_Loop.md"
        $archivedRel = "chores/archived/C-101_Close_The_Loop.md"
        New-SpecFile -Root $root -RelPath $activeRel -ItemId "C-101" -Type "Chore" -Priority "P2" -Title "Close The Loop"
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | C-101 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-101]($activeRel) | P2 | Ready for Deploy | Close The Loop | Operator |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-ArchiveTask -BacklogPath $backlog -SpecPath (Join-Path $root $activeRel)
        $archivedPath = Join-Path $root $archivedRel
        $specContent = Get-Content -LiteralPath $archivedPath -Raw
        $backlogContent = Get-Content -LiteralPath $backlog -Raw
        Assert-Result -Name "chore archive exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "chore active removed" -Condition (-not (Test-Path -LiteralPath (Join-Path $root $activeRel))) -FailureMessage "active chore spec still exists"
        Assert-Result -Name "chore archived exists" -Condition (Test-Path -LiteralPath $archivedPath) -FailureMessage "archived chore spec not found"
        Assert-Result -Name "chore status resolved" -Condition ($specContent -match 'status:\s*"Resolved"') -FailureMessage ("expected Resolved frontmatter. Content: " + $specContent)
        Assert-Result -Name "chore backlog row resolved" -Condition ($backlogContent -match '\[C-101\]\(chores/archived/C-101_Close_The_Loop\.md\)\s*\|\s*P2\s*\|\s*Resolved') -FailureMessage ("expected archived Resolved BACKLOG row. Content: " + $backlogContent)
    }

    $results += Run-Test -Name "Archives feature with Production frontmatter and BACKLOG row" -Body {
        $root = Join-Path $tempRoot "feature"
        New-MinimalBacklogTree -Root $root
        $activeRel = "features/active/F-201_Ship_Feature.md"
        $archivedRel = "features/archived/F-201_Ship_Feature.md"
        New-SpecFile -Root $root -RelPath $activeRel -ItemId "F-201" -Type "Feature" -Priority "P1" -Title "Ship Feature"
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 1 | F-201 |
| **P2** | 0 | - |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [F-201]($activeRel) | P1 | Ready for Deploy | Ship Feature | Operator |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-ArchiveTask -BacklogPath $backlog -SpecPath (Join-Path $root "features/active/F-201_*.md")
        $archivedPath = Join-Path $root $archivedRel
        $specContent = Get-Content -LiteralPath $archivedPath -Raw
        $backlogContent = Get-Content -LiteralPath $backlog -Raw
        Assert-Result -Name "feature archive exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "feature status production" -Condition ($specContent -match 'status:\s*"Production"') -FailureMessage ("expected Production frontmatter. Content: " + $specContent)
        Assert-Result -Name "feature backlog row production" -Condition ($backlogContent -match '\[F-201\]\(features/archived/F-201_Ship_Feature\.md\)\s*\|\s*P1\s*\|\s*Production') -FailureMessage ("expected archived Production BACKLOG row. Content: " + $backlogContent)
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failures = @($results | Where-Object { -not $_ }).Count
if ($failures -gt 0) {
    Write-Host ("`n{0} test(s) failed." -f $failures) -ForegroundColor Red
    exit 1
}
Write-Host "`nALL TESTS PASSED" -ForegroundColor Green
exit 0
