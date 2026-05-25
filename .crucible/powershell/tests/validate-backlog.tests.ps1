# Regression tests for powershell/validate-backlog.ps1.
#
# Focus: Check B (Broken Links) must catch missing-file links in the
# scaffold's unified `## Active Items` table, and must not flag links
# inside HTML comments. Historically the broken-links pass was gated on
# legacy `## **Features**` / `## **Bugs**` / `## **Chores**` section
# headers and never triggered on adopters using the scaffolded template.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$SCRIPT = Join-Path $REPO_ROOT "powershell/validate-backlog.ps1"
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
        [string]$Priority = "P2",
        [string]$Title = "Sample",
        [string]$Status = "Ready"
    )
    $full = Join-Path $Root $RelPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
    @"
---
item_id: "$ItemId"
type: "Chore"
status: "$Status"
priority: "$Priority"
target_specialist: "Architect"
created_at: "2026-05-25"
---

# $Title
"@ | Set-Content -LiteralPath $full -Encoding UTF8
}

function Invoke-Validator {
    param([string]$BacklogPath)
    $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT -BacklogPath $BacklogPath 2>&1)
    return @{ ExitCode = $LASTEXITCODE; Output = ($outputLines -join "`n") }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-validate-backlog-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    # --- Test 1: clean tree with one valid link passes ---
    $results += Run-Test -Name "Clean tree with valid Active Items link passes" -Body {
        $root = Join-Path $tempRoot "clean"
        New-MinimalBacklogTree -Root $root
        New-SpecFile -Root $root -RelPath "chores/active/C-001_Hello.md" -ItemId "C-001" -Priority "P2" -Title "Hello"
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | C-001 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-001](chores/active/C-001_Hello.md) | P2 | Ready | Hello | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog
        Assert-Result -Name "clean tree exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
    }

    # --- Test 2 (REGRESSION): missing-file link in `## Active Items` table must fail ---
    $results += Run-Test -Name "REGRESSION: missing-file link in Active Items table is caught" -Body {
        $root = Join-Path $tempRoot "drift"
        New-MinimalBacklogTree -Root $root
        New-SpecFile -Root $root -RelPath "chores/active/C-001_Hello.md" -ItemId "C-001" -Priority "P2" -Title "Hello"
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | C-001 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-001](chores/active/C-001_Hello.md) | P2 | Ready | Hello | Architect |
| [C-999](chores/active/C-999_Ghost.md) | P2 | Ready | Phantom row | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog
        Assert-Result -Name "drift exit non-zero" -Condition ($r.ExitCode -ne 0) -FailureMessage ("expected non-zero exit, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "drift error mentions C-999 path" -Condition ($r.Output -match "C-999_Ghost\.md") -FailureMessage ("expected broken-link error mentioning the missing file. Output: " + $r.Output)
        Assert-Result -Name "drift error labeled broken link" -Condition ($r.Output -match "Broken link") -FailureMessage ("expected 'Broken link' in error output. Output: " + $r.Output)
    }

    # --- Test 3: HTML-commented example link must not be flagged ---
    $results += Run-Test -Name "HTML-commented example link does not produce false positive" -Body {
        $root = Join-Path $tempRoot "templated"
        New-MinimalBacklogTree -Root $root
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 0 | - |
| **P3** | 0 | - |

**Status Overview**: 0 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
<!-- Example active item link: | [F-001](features/active/F-001_example_feature.md) | P1 | Ready | Example | Groomer | -->
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog
        Assert-Result -Name "templated exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0 (commented example link should be skipped), got " + $r.ExitCode + ". Output: " + $r.Output)
    }

    # --- Test 4: Pattern C — row Status=Stub + spec status=Stub passes ---
    $results += Run-Test -Name "Pattern C: row Status=Stub matches spec status=Stub" -Body {
        $root = Join-Path $tempRoot "patternc-ok"
        New-MinimalBacklogTree -Root $root
        New-SpecFile -Root $root -RelPath "chores/active/C-001_Stub_Item.md" -ItemId "C-001" -Priority "P2" -Title "Stub Item" -Status "Stub"
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | C-001 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Status | Title | Target |
|---|---|---|---|
| [C-001](chores/active/C-001_Stub_Item.md) | Stub | Stub Item | Groomer |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog
        Assert-Result -Name "patternc-ok exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
    }

    # --- Test 5 (REGRESSION): row says Stub but spec frontmatter says Ready (mislabeled stub) ---
    $results += Run-Test -Name "REGRESSION: mislabeled stub (row Stub, spec Ready) is caught" -Body {
        $root = Join-Path $tempRoot "patternc-mislabeled"
        New-MinimalBacklogTree -Root $root
        New-SpecFile -Root $root -RelPath "chores/active/C-001_Mislabeled.md" -ItemId "C-001" -Priority "P2" -Title "Mislabeled" -Status "Ready"
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | C-001 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Status | Title | Target |
|---|---|---|---|
| [C-001](chores/active/C-001_Mislabeled.md) | Stub | Mislabeled | Groomer |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog
        Assert-Result -Name "mislabeled exit non-zero" -Condition ($r.ExitCode -ne 0) -FailureMessage ("expected non-zero exit, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "mislabeled error labeled" -Condition ($r.Output -match "Stub-row convention") -FailureMessage ("expected 'Stub-row convention' in output. Output: " + $r.Output)
        Assert-Result -Name "mislabeled mentions Ready" -Condition ($r.Output -match "spec frontmatter status is 'Ready'") -FailureMessage ("expected explanation of the spec's actual status. Output: " + $r.Output)
    }

    # --- Test 6 (REGRESSION): spec says status=Stub but BACKLOG row says Ready (orphan stub) ---
    $results += Run-Test -Name "REGRESSION: orphan stub spec (spec Stub, row Ready) is caught" -Body {
        $root = Join-Path $tempRoot "patternc-orphan"
        New-MinimalBacklogTree -Root $root
        New-SpecFile -Root $root -RelPath "chores/active/C-001_Orphan.md" -ItemId "C-001" -Priority "P2" -Title "Orphan" -Status "Stub"
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | C-001 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Status | Title | Target |
|---|---|---|---|
| [C-001](chores/active/C-001_Orphan.md) | Ready | Orphan | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog
        Assert-Result -Name "orphan exit non-zero" -Condition ($r.ExitCode -ne 0) -FailureMessage ("expected non-zero exit, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "orphan error labeled" -Condition ($r.Output -match "Stub-row convention") -FailureMessage ("expected 'Stub-row convention' in output. Output: " + $r.Output)
        Assert-Result -Name "orphan mentions spec path" -Condition ($r.Output -match "C-001_Orphan\.md") -FailureMessage ("expected the spec path in the error. Output: " + $r.Output)
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
