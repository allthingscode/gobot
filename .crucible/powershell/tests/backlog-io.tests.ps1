# Direct tests for the human-gate backlog actions in backlog-io.ps1.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/backlog-io.ps1")
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

function New-SingleItemBacklog {
    param([string]$Root, [string]$ItemId, [string]$Priority, [string]$RelPath, [string]$Title)
    $summaryRows = @("P0", "P1", "P2", "P3") | ForEach-Object {
        if ($_ -eq $Priority) { "| **$_** | 1 | $ItemId |" } else { "| **$_** | 0 | - |" }
    }
    $backlog = Join-Path $Root "BACKLOG.md"
    $content = @(
        "# Backlog",
        "",
        "## Priority Summary",
        "",
        "| Priority | Active Count | Item IDs |",
        "|---|---|---|"
    ) + $summaryRows + @(
        "",
        "**Status Overview**: 1 active items.",
        "",
        "## Active Items",
        "",
        "| ID | Priority | Status | Title | Target |",
        "|---|---|---|---|---|",
        "| [$ItemId]($RelPath) | $Priority | Ready for Deploy | $Title | Operator |"
    )
    Set-Content -LiteralPath $backlog -Value $content -Encoding UTF8
    return $backlog
}

$tempRoot = New-TestFixtureRoot -NameHint "backlog-io-test"

try {
    # Item 227: prefix IDs and mentions outside the ID cell must not select a row.
    foreach ($linked in @($false, $true)) {
        foreach ($present in @($true, $false)) {
            $results += Run-Test -Name "Finalization exact ID linked=$linked present=$present" -Body {
                $root = Join-Path $tempRoot "exact-id-$linked-$present"
                New-MinimalBacklogTree -Root $root
                New-Item -ItemType Directory -Path (Join-Path $root ".crucible") -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $root ".crucible/config.yaml"), "paths:`n  backlog: .`n", [System.Text.UTF8Encoding]::new($false))
                $idCell = if ($linked) { "[F-1](features/active/F-1_Test.md)" } else { "F-1" }
                $lines = @(
                    "| ID | Status | Title |",
                    "|---|---|---|",
                    "| [F-10](features/active/F-10_Test.md) | Production | F-1 mention |",
                    "| F-2 | Production | F-1 |"
                )
                if ($present) { $lines += "| $idCell | Ready | Target |" }
                Set-Content -LiteralPath (Join-Path $root "BACKLOG.md") -Value $lines -Encoding UTF8
                $details = Get-TaskFinalizationDetails -TaskId "F-1" -ProjectRoot $root
                if ($present) {
                    Assert-Result "exact row status" ($details.BacklogStatus -eq "Ready" -and $details.Error -eq "") "selected another task's status"
                } else {
                    Assert-Result "missing exact row refused" ($details.BacklogStatus -eq "" -and $details.Error -match 'not found') "accepted another task's row"
                }
            }
        }
    }

    # TODO item 197: exercise the moved actions with only their library loaded.
    foreach ($case in @(
        @{ Name = "shipped"; Branch = $true; Phase = "deployment"; Status = "Production" },
        @{ Name = "no-code"; Branch = $false; Phase = "deployment"; Status = "Resolved" },
        @{ Name = "grooming"; Branch = $true; Phase = "grooming"; Status = "Resolved" }
    )) {
        $results += Run-Test -Name ("Human-gate backlog finalization: " + $case.Name) -Body {
            $root = Join-Path $tempRoot ("gate-finalize-" + $case.Name)
            New-MinimalBacklogTree -Root $root
            New-SpecFile -Root $root -RelPath "features/active/F-197_Test.md" -ItemId "F-197" -Type "feature" -Priority "P2" -Title "Test"
            $backlog = New-SingleItemBacklog -Root $root -RelPath "features/active/F-197_Test.md" -ItemId "F-197" -Priority "P2" -Title "Test"
            New-Item -ItemType Directory -Path (Join-Path $root ".crucible") -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root ".crucible/config.yaml"), "paths:`n  backlog: .`n", [System.Text.UTF8Encoding]::new($false))
            $before = Get-TaskFinalizationDetails -TaskId "F-197" -ProjectRoot $root
            $ok = Invoke-HumanGateBacklogFinalization -TaskId "F-197" -ProjectRoot $root -BacklogPath $backlog -HasTaskBranch $case.Branch -SourcePhase $case.Phase
            $after = Get-TaskFinalizationDetails -TaskId "F-197" -ProjectRoot $root
            Assert-Result "finalization returns true" ($ok -eq $true) "expected successful finalization"
            Assert-Result "backlog check sees finalization with explicit context" (-not $before.IsFinalized -and $after.IsFinalized -and $after.BacklogStatus -eq $case.Status) "expected finalized backlog and spec"
            $archived = Join-Path $root "features/archived/F-197_Test.md"
            Assert-Result "active spec moved" ((Test-Path -LiteralPath $archived) -and -not (Test-Path -LiteralPath (Join-Path $root "features/active/F-197_Test.md"))) "expected archive move"
            Assert-Result "terminal status follows branch and phase" ((Get-Content -LiteralPath $archived -Raw) -match ('status: "' + $case.Status + '"')) "unexpected status"
        }
    }

    foreach ($failure in @("missing-spec", "archive-error", "reverify")) {
        $results += Run-Test -Name ("Human-gate backlog finalization refuses: " + $failure) -Body {
            $root = Join-Path $tempRoot ("gate-failure-" + $failure)
            New-MinimalBacklogTree -Root $root
            $backlog = New-SingleItemBacklog -Root $root -RelPath "features/active/F-197_Test.md" -ItemId "F-197" -Priority "P2" -Title "Test"
            New-Item -ItemType Directory -Path (Join-Path $root ".crucible") -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root ".crucible/config.yaml"), "paths:`n  backlog: .`n", [System.Text.UTF8Encoding]::new($false))
            if ($failure -ne "missing-spec") {
                New-SpecFile -Root $root -RelPath "features/active/F-197_Test.md" -ItemId "F-197" -Type "feature" -Priority "P2" -Title "Test" | Out-Null
            }
            if ($failure -eq "archive-error") {
                New-SpecFile -Root $root -RelPath "features/archived/F-197_Test.md" -ItemId "F-197" -Type "feature" -Priority "P2" -Title "Duplicate" | Out-Null
            }
            if ($failure -eq "reverify") {
                function Get-TaskFinalizationDetails {
                    param($TaskId, $ProjectRoot)
                    [pscustomobject]@{ IsFinalized = $false }
                }
            }
            $output = @(Invoke-HumanGateBacklogFinalization -TaskId "F-197" -ProjectRoot $root -BacklogPath $backlog -HasTaskBranch $true 6>&1)
            Assert-Result "failure returns false without exiting caller" ($output[-1] -eq $false) "expected false result"
            Assert-Result "refusal message preserved" (($output -join "`n") -match '\[D44\] STOP:.*refusing to push.*merge remains LOCAL only') ($output -join "`n")
            $expected = switch ($failure) {
                "missing-spec" { "Active spec path not found" }
                "archive-error" { "Archival failed for task" }
                "reverify" { "still not finalized after archival attempt" }
            }
            Assert-Result "failure detail preserved" (($output -join "`n") -match $expected) ($output -join "`n")
        }
    }

    foreach ($state in @("active", "archived")) {
        $results += Run-Test -Name ("Abandoned backlog archival from " + $state) -Body {
            $root = Join-Path $tempRoot ("gate-abandon-" + $state)
            New-MinimalBacklogTree -Root $root
            New-SpecFile -Root $root -RelPath "features/$state/F-197_Test.md" -ItemId "F-197" -Type "feature" -Priority "P2" -Title "Test"
            $backlog = New-SingleItemBacklog -Root $root -RelPath "features/$state/F-197_Test.md" -ItemId "F-197" -Priority "P2" -Title "Test"
            New-Item -ItemType Directory -Path (Join-Path $root ".crucible") -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root ".crucible/config.yaml"), "paths:`n  backlog: .`n", [System.Text.UTF8Encoding]::new($false))
            Invoke-AbandonedBacklogTaskArchive -TaskId "F-197" -ProjectRoot $root
            $archived = Join-Path $root "features/archived/F-197_Test.md"
            Assert-Result "abandon sets archived frontmatter" ((Get-Content -LiteralPath $archived -Raw) -match 'status: "Abandoned"') "expected Abandoned frontmatter"
            Assert-Result "abandon sets archived row" ((Get-Content -LiteralPath $backlog -Raw) -match '\[F-197\]\(features/archived/F-197_Test.md\).*Abandoned') "expected archived Abandoned row"
        }
    }

} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failures = @($results | Where-Object { -not $_ }).Count
if ($failures -gt 0) {
    Write-Host ("{0} test(s) failed." -f $failures) -ForegroundColor Red
    exit 1
}
Write-Host "ALL TESTS PASSED" -ForegroundColor Green
exit 0
