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
        [string[]]$FileAffinity = @()
    )
    $full = Join-Path $Root $RelPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
    
    $affinityBlock = ""
    if ($FileAffinity.Count -gt 0) {
        $affinityBlock = "`nfile_affinity:`n" + (($FileAffinity | ForEach-Object { "  - " + $_ }) -join "`n")
    }
    
    @"
---
item_id: "$ItemId"
type: "Chore"
status: "$Status"
priority: "$Priority"$affinityBlock
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

    # --- Test 4: Pattern C - row Status=Stub + spec status=Stub passes ---
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
