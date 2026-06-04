# Regression tests for powershell/archive-task.ps1.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$SCRIPT = Join-Path $REPO_ROOT "powershell/archive-task.ps1"
$LIB = Join-Path $REPO_ROOT "powershell/lib/archive-task.ps1"
$results = @()
. $LIB

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
    param([string]$BacklogPath, [string]$SpecPath, [string]$Status)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $cmdArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $SCRIPT, "-BacklogPath", $BacklogPath, "-SpecPath", $SpecPath)
        if (-not [string]::IsNullOrEmpty($Status)) {
            $cmdArgs += @("-Status", $Status)
        }
        $outputLines = @(powershell.exe @cmdArgs 2>&1)
        return @{ ExitCode = $LASTEXITCODE; Output = ($outputLines -join "`n") }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-archive-task-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Status-column resolver handles non-first rows and table boundaries" -Body {
        $lines = @(
            "# Backlog",
            "",
            "| ID | Status | Title |",
            "|---|---|---|",
            "| [C-100](chores/active/C-100_First.md) | Ready | First |",
            "| [C-101](chores/active/C-101_Second.md) | Ready for Deploy | Second |",
            "",
            "| ID | Title |",
            "|---|---|",
            "| [C-200](chores/active/C-200_No_Status.md) | No Status Column |"
        )

        $statusColumn = Get-MarkdownTableStatusColumn -Lines $lines -RowIndex 5
        $boundaryStatusColumn = Get-MarkdownTableStatusColumn -Lines $lines -RowIndex 9
        Assert-Result -Name "non-first row status column" -Condition ($statusColumn -eq 1) -FailureMessage ("expected Status column index 1, got " + $statusColumn)
        Assert-Result -Name "boundary does not bind prior table" -Condition ($boundaryStatusColumn -eq -1) -FailureMessage ("expected no Status column across table boundary, got " + $boundaryStatusColumn)
    }

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
| [C-100](chores/active/C-100_Previous.md) | P2 | Ready | Previous | Operator |
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

    $results += Run-Test -Name "Rollback restores active spec when BACKLOG row has no Status column" -Body {
        $root = Join-Path $tempRoot "rollback-no-status"
        New-MinimalBacklogTree -Root $root
        $activeRel = "chores/active/C-150_No_Status_Column.md"
        $archivedRel = "chores/archived/C-150_No_Status_Column.md"
        New-SpecFile -Root $root -RelPath $activeRel -ItemId "C-150" -Type "Chore" -Priority "P2" -Title "No Status Column"
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Active Items

| ID | Status | Title | Target |
|---|---|---|---|
| [C-149](chores/active/C-149_Previous.md) | Ready | Previous | Operator |

## Other Items

| ID | Priority | Title | Target |
|---|---|---|---|
| [C-150]($activeRel) | P2 | No Status Column | Operator |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-ArchiveTask -BacklogPath $backlog -SpecPath (Join-Path $root $activeRel)
        Assert-Result -Name "rollback exit non-zero" -Condition ($r.ExitCode -ne 0) -FailureMessage ("expected non-zero exit, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "rollback active restored" -Condition (Test-Path -LiteralPath (Join-Path $root $activeRel)) -FailureMessage "active spec was not restored"
        Assert-Result -Name "rollback archived absent" -Condition (-not (Test-Path -LiteralPath (Join-Path $root $archivedRel))) -FailureMessage "archived spec remained after failure"
        Assert-Result -Name "rollback error mentions status column" -Condition ($r.Output -match "Unable to locate Status column") -FailureMessage ("expected status-column error. Output: " + $r.Output)
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

    $results += Run-Test -Name "Archives feature as Resolved via explicit -Status Resolved" -Body {
        $root = Join-Path $tempRoot "feature-resolved-explicit"
        New-MinimalBacklogTree -Root $root
        $activeRel = "features/active/F-202_Close_No_Build.md"
        $archivedRel = "features/archived/F-202_Close_No_Build.md"
        New-SpecFile -Root $root -RelPath $activeRel -ItemId "F-202" -Type "Feature" -Priority "P1" -Title "Close No Build"
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [F-202]($activeRel) | P1 | Ready for Deploy | Close No Build | Operator |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-ArchiveTask -BacklogPath $backlog -SpecPath (Join-Path $root "features/active/F-202_*.md") -Status "Resolved"
        $archivedPath = Join-Path $root $archivedRel
        $specContent = Get-Content -LiteralPath $archivedPath -Raw
        $backlogContent = Get-Content -LiteralPath $backlog -Raw
        Assert-Result -Name "feature status resolved explicit" -Condition ($specContent -match 'status:\s*"Resolved"') -FailureMessage ("expected Resolved frontmatter. Content: " + $specContent)
        Assert-Result -Name "feature backlog row resolved explicit" -Condition ($backlogContent -match '\[F-202\]\(features/archived/F-202_Close_No_Build\.md\)\s*\|\s*P1\s*\|\s*Resolved') -FailureMessage ("expected archived Resolved BACKLOG row. Content: " + $backlogContent)
    }

    $results += Run-Test -Name "Archives feature honoring existing Resolved frontmatter status when -Status is omitted" -Body {
        $root = Join-Path $tempRoot "feature-resolved-honor"
        New-MinimalBacklogTree -Root $root
        $activeRel = "features/active/F-203_Honor_Status.md"
        $archivedRel = "features/archived/F-203_Honor_Status.md"
        New-SpecFile -Root $root -RelPath $activeRel -ItemId "F-203" -Type "Feature" -Priority "P1" -Title "Honor Status" -Status "Resolved"
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [F-203]($activeRel) | P1 | Resolved | Honor Status | Operator |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-ArchiveTask -BacklogPath $backlog -SpecPath (Join-Path $root "features/active/F-203_*.md")
        $archivedPath = Join-Path $root $archivedRel
        $specContent = Get-Content -LiteralPath $archivedPath -Raw
        $backlogContent = Get-Content -LiteralPath $backlog -Raw
        Assert-Result -Name "feature status resolved honored" -Condition ($specContent -match 'status:\s*"Resolved"') -FailureMessage ("expected Resolved frontmatter. Content: " + $specContent)
        Assert-Result -Name "feature backlog row resolved honored" -Condition ($backlogContent -match '\[F-203\]\(features/archived/F-203_Honor_Status\.md\)\s*\|\s*P1\s*\|\s*Resolved') -FailureMessage ("expected archived Resolved BACKLOG row. Content: " + $backlogContent)
    }

    $results += Run-Test -Name "Reconciles Priority Summary on multi-item bucket archive" -Body {
        $root = Join-Path $tempRoot "multi-item-reconcile"
        New-MinimalBacklogTree -Root $root
        $activeRel1 = "chores/active/C-305_Soak.md"
        $activeRel2 = "chores/active/C-305a_Execute_Soak.md"
        New-SpecFile -Root $root -RelPath $activeRel1 -ItemId "C-305" -Type "Chore" -Priority "P1" -Title "Author Soak Plan"
        New-SpecFile -Root $root -RelPath $activeRel2 -ItemId "C-305a" -Type "Chore" -Priority "P1" -Title "Execute Soak Plan"
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 2 | C-305, C-305a |
| **P2** | 0 | - |
| **P3** | 0 | - |

**Status Overview**: 2 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-305]($activeRel1) | P1 | Ready for Deploy | Author Soak Plan | Operator |
| [C-305a]($activeRel2) | P1 | Ready for Deploy | Execute Soak Plan | Operator |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        # Archive one item: C-305
        $r = Invoke-ArchiveTask -BacklogPath $backlog -SpecPath (Join-Path $root $activeRel1)
        Assert-Result -Name "archive multi-item exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
        
        # Verify BACKLOG content: Count updated to 1, C-305 removed, C-305a remains, status overview updated to 1
        $backlogContent = Get-Content -LiteralPath $backlog -Raw
        Assert-Result -Name "reconciled P1 count" -Condition ($backlogContent -match '\|\s*\*\*P1\*\*\s*\|\s*1\s*\|\s*C-305a\s*\|') -FailureMessage ("expected reconciled P1 row. Content: " + $backlogContent)
        Assert-Result -Name "reconciled Status Overview" -Condition ($backlogContent -match '\*\*Status Overview\*\*:\s*1\s*active\s*items\.') -FailureMessage ("expected Status Overview 1. Content: " + $backlogContent)
        
        # Validate backlog passes validation using validate-backlog.ps1 check
        $validateScript = Join-Path $REPO_ROOT "powershell/validate-backlog.ps1"
        $validateOutput = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validateScript -BacklogPath $backlog -ProjectRoot $root 2>&1)
        Assert-Result -Name "validate-backlog exit 0 post-archive" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected validation success, output: " + ($validateOutput -join "`n"))
    }

    $results += Run-Test -Name "Reconciles Priority Summary when archiving the sole item in a bucket" -Body {
        $root = Join-Path $tempRoot "sole-item-reconcile"
        New-MinimalBacklogTree -Root $root
        $activeRel = "chores/active/C-305_Soak.md"
        New-SpecFile -Root $root -RelPath $activeRel -ItemId "C-305" -Type "Chore" -Priority "P1" -Title "Author Soak Plan"
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 1 | C-305 |
| **P2** | 0 | - |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-305]($activeRel) | P1 | Ready for Deploy | Author Soak Plan | Operator |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        # Archive the sole item: C-305
        $r = Invoke-ArchiveTask -BacklogPath $backlog -SpecPath (Join-Path $root $activeRel)
        Assert-Result -Name "archive sole-item exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
        
        # Verify BACKLOG content: Count updated to 0, Item IDs set to -, status overview updated to 0
        $backlogContent = Get-Content -LiteralPath $backlog -Raw
        Assert-Result -Name "reconciled P1 count zero" -Condition ($backlogContent -match '\|\s*\*\*P1\*\*\s*\|\s*0\s*\|\s*-\s*\|') -FailureMessage ("expected reconciled empty P1 row. Content: " + $backlogContent)
        Assert-Result -Name "reconciled Status Overview zero" -Condition ($backlogContent -match '\*\*Status Overview\*\*:\s*0\s*active\s*items\.') -FailureMessage ("expected Status Overview 0. Content: " + $backlogContent)

        # Validate backlog passes validation using validate-backlog.ps1 check
        $validateScript = Join-Path $REPO_ROOT "powershell/validate-backlog.ps1"
        $validateOutput = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validateScript -BacklogPath $backlog -ProjectRoot $root 2>&1)
        Assert-Result -Name "validate-backlog exit 0 post-archive sole" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected validation success, output: " + ($validateOutput -join "`n"))
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
