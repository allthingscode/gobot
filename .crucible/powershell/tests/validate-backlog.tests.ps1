# Regression tests for powershell/validate-backlog.ps1.
#
# Focus: Check B (Broken Links) must catch missing-file links in the
# scaffold's unified `## Active Items` table, and must not flag links
# inside HTML comments. Historically the broken-links pass was gated on
# legacy `## **Features**` / `## **Bugs**` / `## **Chores**` section
# headers and never triggered on adopters using the scaffolded template.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$SCRIPT = Join-Path $REPO_ROOT "powershell/validate-backlog.ps1"
$results = @()







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
        [string]$Status = "Ready",
        [string[]]$FileAffinity = @(),
        [string]$BudgetTier = "",
        [string]$Type = "Chore"
    )
    $full = Join-Path $Root $RelPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
    
    $affinityBlock = ""
    if ($FileAffinity.Count -gt 0) {
        $affinityBlock = "`nfile_affinity:`n" + (($FileAffinity | ForEach-Object { "  - " + $_ }) -join "`n")
    }
    
    $budgetBlock = ""
    if ($BudgetTier) {
        $budgetBlock = "`nbudget_tier: `"$BudgetTier`""
    }
    
    @"
---
item_id: "$ItemId"
type: "$Type"
status: "$Status"
priority: "$Priority"$affinityBlock$budgetBlock
target_phase: "implementation"
created_at: "2026-05-25"
---

# $Title
"@ | Set-Content -LiteralPath $full -Encoding UTF8
}

function Invoke-Validator {
    param([string]$BacklogPath, [string]$ProjectRoot = "")
    $cmdArgs = @("-BacklogPath", $BacklogPath)
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $cmdArgs += @("-ProjectRoot", $ProjectRoot)
    }
    $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $SCRIPT @cmdArgs 2>&1)
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

    # --- Test 4: Stub-Only Close-Out - row Status=Stub + spec status=Stub passes ---
    $results += Run-Test -Name "Stub-Only Close-Out: row Status=Stub matches spec status=Stub" -Body {
        $root = Join-Path $tempRoot "stub-only-closeout-ok"
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
        Assert-Result -Name "stub-only-closeout-ok exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
    }

    # --- Test 5 (REGRESSION): row says Stub but spec frontmatter says Ready (mislabeled stub) ---
    $results += Run-Test -Name "REGRESSION: mislabeled stub (row Stub, spec Ready) is caught" -Body {
        $root = Join-Path $tempRoot "stub-only-closeout-mislabeled"
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
        $root = Join-Path $tempRoot "stub-only-closeout-orphan"
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

    # --- Test 7 (REGRESSION): stale archived spec status is repaired when a non-first BACKLOG row is terminal ---
    $results += Run-Test -Name "REGRESSION: stale archived status is repaired from non-first terminal BACKLOG row" -Body {
        $root = Join-Path $tempRoot "archived-stale-terminal"
        New-MinimalBacklogTree -Root $root
        $specPath = Join-Path $root "chores/archived/C-304_Multi_Model_Routing_Audit.md"
        New-SpecFile -Root $root -RelPath "chores/archived/C-303_Previous_Resolved.md" -ItemId "C-303" -Priority "P2" -Title "Previous Resolved" -Status "Resolved"
        New-SpecFile -Root $root -RelPath "chores/archived/C-304_Multi_Model_Routing_Audit.md" -ItemId "C-304" -Priority "P2" -Title "Multi Model Routing Audit" -Status "Ready for Deploy"
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
| [C-303](chores/archived/C-303_Previous_Resolved.md) | P2 | Resolved | Previous Resolved | Operator |
| [C-304](chores/archived/C-304_Multi_Model_Routing_Audit.md) | P2 | Resolved | Multi Model Routing Audit | Operator |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog
        $updated = Get-Content -LiteralPath $specPath -Raw
        Assert-Result -Name "stale terminal exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0 after auto-repair, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "stale terminal repaired" -Condition ($updated -match 'status:\s*"Resolved"') -FailureMessage ("expected archived spec status to be repaired to Resolved. Content: " + $updated)
        Assert-Result -Name "stale terminal output warns" -Condition ($r.Output -match "Repaired archived spec status") -FailureMessage ("expected repair warning in output. Output: " + $r.Output)
    }

    # --- Test 8: stale archived spec status still fails when BACKLOG row is not terminal ---
    $results += Run-Test -Name "Archived stale status fails when BACKLOG row is not terminal" -Body {
        $root = Join-Path $tempRoot "archived-stale-nonterminal"
        New-MinimalBacklogTree -Root $root
        New-SpecFile -Root $root -RelPath "chores/archived/C-305_Still_In_Flight.md" -ItemId "C-305" -Priority "P2" -Title "Still In Flight" -Status "Ready for Deploy"
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
| [C-305](chores/archived/C-305_Still_In_Flight.md) | P2 | Ready for Deploy | Still In Flight | Operator |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog
        Assert-Result -Name "stale nonterminal exit non-zero" -Condition ($r.ExitCode -ne 0) -FailureMessage ("expected non-zero exit, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "stale nonterminal error" -Condition ($r.Output -match "Archived file has incorrect status") -FailureMessage ("expected archived status error. Output: " + $r.Output)
    }

    # --- Test 9: archived file with missing status remains malformed and fails ---
    $results += Run-Test -Name "Archived file with missing status frontmatter is caught" -Body {
        $root = Join-Path $tempRoot "archived-missing-status"
        New-MinimalBacklogTree -Root $root
        $specPath = Join-Path $root "features/archived/F-101_Missing_Status.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $specPath) -Force | Out-Null
@"
---
item_id: "F-101"
type: "Feature"
priority: "P1"
target_phase: "done"
---

# Missing Status
"@ | Set-Content -LiteralPath $specPath -Encoding UTF8
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
| [F-101](features/archived/F-101_Missing_Status.md) | P1 | Production | Missing Status | Operator |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog
        Assert-Result -Name "missing status exit non-zero" -Condition ($r.ExitCode -ne 0) -FailureMessage ("expected non-zero exit, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "missing status error" -Condition ($r.Output -match "missing status frontmatter") -FailureMessage ("expected missing status error. Output: " + $r.Output)
    }

    # --- Test 9: mojibake detection in BACKLOG.md fails validation ---
    $results += Run-Test -Name "Mojibake detection in BACKLOG.md fails validation" -Body {
        $root = Join-Path $tempRoot "mojibake"
        New-MinimalBacklogTree -Root $root
        New-SpecFile -Root $root -RelPath "chores/active/C-001_Hello.md" -ItemId "C-001" -Priority "P2" -Title "Hello"
        $backlog = Join-Path $root "BACKLOG.md"
        $dirtyText = "bad " + [char]0x00C3 + [char]0x00A9 + " marker"
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
| [C-001](chores/active/C-001_Hello.md) | P2 | Ready | $dirtyText | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog
        Assert-Result -Name "mojibake exit non-zero" -Condition ($r.ExitCode -ne 0) -FailureMessage ("expected non-zero exit, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "mojibake error message" -Condition ($r.Output -match "Mojibake detected in BACKLOG.md") -FailureMessage ("expected mojibake detection message. Output: " + $r.Output)
    }

    # --- Test 10: file_affinity path-existence check ---
    $results += Run-Test -Name "file_affinity validation: valid, wildcard, and nonexistent paths" -Body {
        $root = Join-Path $tempRoot "affinity-validation"
        New-MinimalBacklogTree -Root $root
        
        # Create some real project files
        $projDir = Join-Path $root "internal/doctor"
        New-Item -ItemType Directory -Path $projDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $projDir "helper.go") -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $root "root_script.ps1") -Force | Out-Null
        
        # Case A: Clean spec with valid file, directory, and wildcard affinities
        New-SpecFile -Root $root -RelPath "chores/active/C-001_Good_Affinity.md" -ItemId "C-001" -Priority "P2" -Title "Good Affinity" -FileAffinity @(
            "internal/doctor",
            "root_script.ps1",
            "internal/doctor/*.go"
        )
        
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
| [C-001](chores/active/C-001_Good_Affinity.md) | P2 | Ready | Good Affinity | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        # Run validation - should PASS
        $r = Invoke-Validator -BacklogPath $backlog -ProjectRoot $root
        Assert-Result -Name "good affinity passes" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)

        # Case B: Spec with a nonexistent literal path
        New-SpecFile -Root $root -RelPath "chores/active/C-002_Bad_Affinity.md" -ItemId "C-002" -Priority "P2" -Title "Bad Affinity" -FileAffinity @(
            "internal/doctor",
            "scripts/nonexistent.ps1"
        )
        
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 2 | C-001, C-002 |
| **P3** | 0 | - |

**Status Overview**: 2 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-001](chores/active/C-001_Good_Affinity.md) | P2 | Ready | Good Affinity | Architect |
| [C-002](chores/active/C-002_Bad_Affinity.md) | P2 | Ready | Bad Affinity | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        # Run validation - should PASS with warning
        $r = Invoke-Validator -BacklogPath $backlog -ProjectRoot $root
        Assert-Result -Name "bad affinity warning passes" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0 (warn-only), got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "bad affinity warning contains spec path" -Condition ($r.Output.Contains("C-002_Bad_Affinity.md")) -FailureMessage ("expected warning message referencing the bad spec file. Output: " + $r.Output)
        Assert-Result -Name "bad affinity warning contains bad path" -Condition ($r.Output.Contains("scripts/nonexistent.ps1")) -FailureMessage ("expected warning message referencing the bad path. Output: " + $r.Output)

        # Case C: Spec with a wildcard pattern matching nothing
        New-SpecFile -Root $root -RelPath "chores/active/C-002_Bad_Affinity.md" -ItemId "C-002" -Priority "P2" -Title "Bad Affinity" -FileAffinity @(
            "internal/doctor/*.py"
        )
        # Run validation - should PASS with warning
        $r = Invoke-Validator -BacklogPath $backlog -ProjectRoot $root
        Assert-Result -Name "bad wildcard warning passes" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0 (warn-only), got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "bad wildcard warning message" -Condition ($r.Output.Contains("internal/doctor/*.py")) -FailureMessage ("expected warning message referencing the bad wildcard path. Output: " + $r.Output)
    }

    # --- Test 11: file_affinity is ProjectRoot-aware from different CWD ---
    $results += Run-Test -Name "file_affinity validation: ProjectRoot-aware from foreign CWD" -Body {
        $root = Join-Path $tempRoot "project-root-aware"
        New-MinimalBacklogTree -Root $root
        
        # Create a real project file
        New-Item -ItemType File -Path (Join-Path $root "valid_root_file.ps1") -Force | Out-Null
        
        # Spec with file_affinity referencing the root file
        New-SpecFile -Root $root -RelPath "chores/active/C-001_Root_Aware.md" -ItemId "C-001" -Priority "P2" -Title "Root Aware" -FileAffinity @(
            "valid_root_file.ps1"
        )
        
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
| [C-001](chores/active/C-001_Root_Aware.md) | P2 | Ready | Root Aware | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        # Switch CWD to a completely different folder
        $foreignDir = Join-Path $tempRoot "foreign-cwd"
        New-Item -ItemType Directory -Path $foreignDir -Force | Out-Null
        
        $origCwd = (Get-Location).Path
        try {
            # Set CWD to foreign directory
            Set-Location -LiteralPath $foreignDir
            
            # Run validator, passing -ProjectRoot targeting $root
            $r = Invoke-Validator -BacklogPath $backlog -ProjectRoot $root
            Assert-Result -Name "resolves correctly from foreign CWD" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
        } finally {
            Set-Location -LiteralPath $origCwd
        }
    }

    # --- Test 12: budget_tier validation: valid, absent, and invalid values ---
    $results += Run-Test -Name "budget_tier validation: valid, absent, and invalid values" -Body {
        $root = Join-Path $tempRoot "budget-tier-validation"
        New-MinimalBacklogTree -Root $root
        
        # Spec with valid budget_tier
        New-SpecFile -Root $root -RelPath "chores/active/C-001_Good_Budget.md" -ItemId "C-001" -Priority "P2" -Title "Good Budget" -BudgetTier "low"
        # Spec with absent budget_tier (should be OK)
        New-SpecFile -Root $root -RelPath "chores/active/C-002_Absent_Budget.md" -ItemId "C-002" -Priority "P2" -Title "Absent Budget"
        
        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 2 | C-001, C-002 |
| **P3** | 0 | - |

**Status Overview**: 2 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-001](chores/active/C-001_Good_Budget.md) | P2 | Ready | Good Budget | Architect |
| [C-002](chores/active/C-002_Absent_Budget.md) | P2 | Ready | Absent Budget | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        # Run validation - should PASS
        $r = Invoke-Validator -BacklogPath $backlog -ProjectRoot $root
        Assert-Result -Name "good and absent budget tiers pass" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)

        # Spec with invalid budget_tier
        New-SpecFile -Root $root -RelPath "chores/active/C-003_Bad_Budget.md" -ItemId "C-003" -Priority "P2" -Title "Bad Budget" -BudgetTier "small"

        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 3 | C-001, C-002, C-003 |
| **P3** | 0 | - |

**Status Overview**: 3 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-001](chores/active/C-001_Good_Budget.md) | P2 | Ready | Good Budget | Architect |
| [C-002](chores/active/C-002_Absent_Budget.md) | P2 | Ready | Absent Budget | Architect |
| [C-003](chores/active/C-003_Bad_Budget.md) | P2 | Ready | Bad Budget | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        # Run validation - should FAIL
        $r = Invoke-Validator -BacklogPath $backlog -ProjectRoot $root
        Assert-Result -Name "invalid budget tier fails" -Condition ($r.ExitCode -ne 0) -FailureMessage ("expected exit non-zero, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "invalid budget tier error message" -Condition ($r.Output -match "Invalid budget_tier.*'small'") -FailureMessage ("expected invalid budget tier error referencing 'small'. Output: " + $r.Output)
    }

    # --- Test 13: a 'budget_tier' documentation comment must not false-positive ---
    $results += Run-Test -Name "budget_tier comment line does not false-positive" -Body {
        $root = Join-Path $tempRoot "budget-tier-comment"
        New-MinimalBacklogTree -Root $root

        $spec = Join-Path $root "chores/active/C-010_Commented_Budget.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $spec) -Force | Out-Null
@"
---
item_id: "C-010"
type: "Chore"
status: "Ready"
priority: "P2"
# budget_tier: The token budget category (low, medium, high, extended)
budget_tier: "low"
target_phase: "implementation"
created_at: "2026-05-25"
---

# C-010 Commented Budget
"@ | Set-Content -LiteralPath $spec -Encoding UTF8

        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | C-010 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-010](chores/active/C-010_Commented_Budget.md) | P2 | Ready | Commented Budget | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog -ProjectRoot $root
        Assert-Result -Name "comment line does not trip budget_tier check" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "no spurious budget_tier error" -Condition (-not ($r.Output -match "Invalid budget_tier")) -FailureMessage ("expected no budget_tier error from a comment line. Output: " + $r.Output)
    }

    # --- Test 14: valid type lowercase bare -> passes ---
    $results += Run-Test -Name "valid type lowercase bare passes" -Body {
        $root = Join-Path $tempRoot "type-valid-bare"
        New-MinimalBacklogTree -Root $root

        $spec = Join-Path $root "chores/active/C-011_Type_Bare.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $spec) -Force | Out-Null
@"
---
item_id: "C-011"
type: chore
status: "Ready"
priority: "P2"
target_phase: "implementation"
created_at: "2026-05-25"
---

# C-011 Type Bare
"@ | Set-Content -LiteralPath $spec -Encoding UTF8

        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | C-011 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-011](chores/active/C-011_Type_Bare.md) | P2 | Ready | Type Bare | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog -ProjectRoot $root
        Assert-Result -Name "bare type exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
    }

    # --- Test 15: valid type quoted capitalized -> passes ---
    $results += Run-Test -Name "valid type quoted capitalized passes" -Body {
        $root = Join-Path $tempRoot "type-valid-quoted"
        New-MinimalBacklogTree -Root $root
        New-SpecFile -Root $root -RelPath "chores/active/C-012_Type_Quoted.md" -ItemId "C-012" -Priority "P2" -Title "Type Quoted" -Type "Research"

        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | C-012 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-012](chores/active/C-012_Type_Quoted.md) | P2 | Ready | Type Quoted | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog -ProjectRoot $root
        Assert-Result -Name "quoted type exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
    }

    # --- Test 16: invalid type value -> ERROR, non-zero exit ---
    $results += Run-Test -Name "invalid type value is caught" -Body {
        $root = Join-Path $tempRoot "type-invalid"
        New-MinimalBacklogTree -Root $root
        New-SpecFile -Root $root -RelPath "chores/active/C-013_Type_Bad.md" -ItemId "C-013" -Priority "P2" -Title "Type Bad" -Type "epic"

        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | C-013 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-013](chores/active/C-013_Type_Bad.md) | P2 | Ready | Type Bad | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog -ProjectRoot $root
        Assert-Result -Name "invalid type exit non-zero" -Condition ($r.ExitCode -ne 0) -FailureMessage ("expected non-zero exit, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "invalid type error message" -Condition ($r.Output -match "Invalid type.*'epic'") -FailureMessage ("expected invalid type error referencing 'epic'. Output: " + $r.Output)
        Assert-Result -Name "invalid type lists allowed" -Condition ($r.Output -match "feature, bug, chore, research") -FailureMessage ("expected allowed values in error. Output: " + $r.Output)
    }

    # --- Test 17: missing type -> WARN, exit code 0 ---
    $results += Run-Test -Name "missing type produces warning but passes" -Body {
        $root = Join-Path $tempRoot "type-missing"
        New-MinimalBacklogTree -Root $root

        $spec = Join-Path $root "chores/active/C-014_Type_Missing.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $spec) -Force | Out-Null
@"
---
item_id: "C-014"
status: "Ready"
priority: "P2"
target_phase: "implementation"
created_at: "2026-05-25"
---

# C-014 Type Missing
"@ | Set-Content -LiteralPath $spec -Encoding UTF8

        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | C-014 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-014](chores/active/C-014_Type_Missing.md) | P2 | Ready | Type Missing | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog -ProjectRoot $root
        Assert-Result -Name "missing type exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "missing type warns" -Condition ($r.Output -match '\[WARN\]') -FailureMessage ("expected [WARN] in output. Output: " + $r.Output)
        Assert-Result -Name "missing type message" -Condition ($r.Output -match "Missing type") -FailureMessage ("expected 'Missing type' in output. Output: " + $r.Output)
    }

    # --- Test 18: type documentation comment above real declaration -> real declaration wins ---
    $results += Run-Test -Name "type comment line does not false-positive" -Body {
        $root = Join-Path $tempRoot "type-comment"
        New-MinimalBacklogTree -Root $root

        $spec = Join-Path $root "chores/active/C-020_Commented_Type.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $spec) -Force | Out-Null
@"
---
item_id: "C-020"
# type: feature|bug|chore|research
type: "Chore"
status: "Ready"
priority: "P2"
target_phase: "implementation"
created_at: "2026-05-25"
---

# C-020 Commented Type
"@ | Set-Content -LiteralPath $spec -Encoding UTF8

        $backlog = Join-Path $root "BACKLOG.md"
@"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | C-020 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [C-020](chores/active/C-020_Commented_Type.md) | P2 | Ready | Commented Type | Architect |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog -ProjectRoot $root
        Assert-Result -Name "comment line does not trip type check" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "no spurious type error" -Condition (-not ($r.Output -match "Invalid type")) -FailureMessage ("expected no type error from a comment line. Output: " + $r.Output)
    }

    # --- Test 19: archived spec with invalid type -> not flagged ---
    $results += Run-Test -Name "archived spec with invalid type is not flagged" -Body {
        $root = Join-Path $tempRoot "type-archived"
        New-MinimalBacklogTree -Root $root
        New-SpecFile -Root $root -RelPath "chores/archived/C-021_Archived_Type.md" -ItemId "C-021" -Priority "P2" -Title "Archived Type" -Status "Resolved" -Type "epic"

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
| [C-021](chores/archived/C-021_Archived_Type.md) | P2 | Resolved | Archived Type | Operator |
"@ | Set-Content -LiteralPath $backlog -Encoding UTF8

        $r = Invoke-Validator -BacklogPath $backlog -ProjectRoot $root
        Assert-Result -Name "archived invalid type exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "archived no type error" -Condition (-not ($r.Output -match "Invalid type")) -FailureMessage ("expected no type error for archived spec. Output: " + $r.Output)
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
