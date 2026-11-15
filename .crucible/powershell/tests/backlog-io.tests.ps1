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
    foreach ($scalar in @('"Ready" # note', "'Ready' # note", 'Ready # note', '"a # b"', "'a # b'")) {
        $results += Run-Test -Name ("Rereview255 quoted scalar: " + $scalar) -Body {
            $path = Join-Path $tempRoot 'rereview255-scalar.md'
            Set-Content -LiteralPath $path -Value ("---`nstatus: " + $scalar + "`n---") -Encoding UTF8
            $expected = if ($scalar -match 'a # b') { 'a # b' } else { 'Ready' }
            Assert-Result 'scalar value preserved without trailing comment' ((Get-BacklogSpecStatus -SpecPath $path) -ceq $expected) $scalar
        }
    }
    foreach ($shape in @('leading-blank', 'no-frontmatter')) {
        $results += Run-Test -Name ("Rereview255 dependencies: " + $shape) -Body {
            $path = Join-Path $tempRoot 'rereview255-dependencies.md'
            $text = if ($shape -eq 'leading-blank') { "`n---`nitem_id: F-1`ndepends_on: [F-2]`n---`ndepends_on: [F-9]" } else { "item_id: F-1`ndepends_on:`n  - F-2" }
            Set-Content -LiteralPath $path -Value $text -Encoding UTF8
            $root = Join-Path $tempRoot ('dependency-gate-' + $shape)
            New-MinimalBacklogTree -Root $root
            New-Item -ItemType Directory -Path (Join-Path $root '.crucible') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root '.crucible/config.yaml') -Value "paths:`n  backlog: ." -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $root 'features/active/F-2.md') -Value "---`nstatus: Ready`n---" -Encoding UTF8
            $runner = Join-Path $root 'gate.ps1'
            $script = @'
param($FrameworkRoot, $ProjectRoot, $SpecPath)
$Quiet = $true
. (Join-Path $FrameworkRoot 'powershell/crucible-lib.ps1')
$source = [IO.File]::ReadAllText((Join-Path $FrameworkRoot 'powershell/crucible.ps1'))
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Check-Dependencies' }, $true)
. ([scriptblock]::Create($function.Extent.Text))
$backlogDir = $ProjectRoot
Check-Dependencies -BacklogItemPath $SpecPath -TargetSpecialist deployment -TaskId F-1
exit 0
'@
            [IO.File]::WriteAllText($runner, $script, [Text.UTF8Encoding]::new($false))
            $output = @(Invoke-ExternalCommand -AsLines { & (Get-PwshCommand) -NoProfile -File $runner $REPO_ROOT $root $path 2>&1 }) -join "`n"
            Assert-Result 'deployment blocks unmet dependency' ($LASTEXITCODE -eq 2 -and $output.Contains('Unsatisfied dependencies detected') -and $output.Contains('F-2')) $output
            Assert-Result 'identity recognizes same spec shape' ((Get-SpecIdentity -SpecPath $path).item_id -eq 'F-1') $text
            Assert-Result 'unmet dependency retained for deployment gate' ((@(Get-SpecDependencies -SpecPath $path) -join ',') -eq 'F-2') $text
        }
    }
    $results += Run-Test -Name "Review255 dependencies stop at the frontmatter boundary" -Body {
        $path = Join-Path $tempRoot "review255-dependencies.md"
        foreach ($text in @("---`nitem_id: F-1`n---`n    depends_on: [F-9]", ("# Body`n" + ("body`n" * 30) + "    depends_on: [F-9]"))) {
            Set-Content -LiteralPath $path -Value $text -Encoding UTF8
            Assert-Result "body dependencies ignored" (@(Get-SpecDependencies -SpecPath $path).Count -eq 0) "body code became a dependency"
        }
        Set-Content -LiteralPath $path -Value "---`ndepends_on:`n  - F-2`n---`n    depends_on: [F-9]" -Encoding UTF8
        Assert-Result "frontmatter dependencies retained" ((@(Get-SpecDependencies -SpecPath $path) -join ',') -eq 'F-2') "frontmatter dependency lost"
    }

    $results += Run-Test -Name "Review255 unquoted scalar comments are stripped and quoted hashes retained" -Body {
        $path = Join-Path $tempRoot "review255-comments.md"
        Set-Content -LiteralPath $path -Value "---`nbudget_tier: low # cheap`npriority: P2 # normal`nstatus: 'Ready # literal'`n---" -Encoding UTF8
        Assert-Result "budget comment stripped" ((Get-SpecBudgetTier -SpecPath $path) -eq 'low') "comment leaked into tier"
        Assert-Result "priority comment stripped" ((Get-SpecIdentity -SpecPath $path).priority -eq 'P2') "comment leaked into priority"
        Assert-Result "quoted hash retained" ((Get-BacklogSpecStatus -SpecPath $path) -eq 'Ready # literal') "quoted text changed"
    }

    $results += Run-Test -Name "Item255 finalization reads status beyond the old joined-line limit" -Body {
        $root = Join-Path $tempRoot "item255-finalization"
        New-MinimalBacklogTree -Root $root
        New-Item -ItemType Directory -Force -Path (Join-Path $root ".crucible") | Out-Null
        Set-Content -LiteralPath (Join-Path $root ".crucible/config.yaml") -Value "paths:`n  backlog: ." -Encoding UTF8
        $rel = "features/archived/F-255_Test.md"
        $backlog = New-SingleItemBacklog -Root $root -ItemId "F-255" -Priority "P2" -RelPath $rel -Title "Test"
        Set-Content -LiteralPath $backlog -Value ((Get-Content -LiteralPath $backlog -Raw).Replace("Ready for Deploy", "Production")) -Encoding UTF8
        $padding = (1..20 | ForEach-Object { "note_" + $_ + ": value" }) -join "`n"
        Set-Content -LiteralPath (Join-Path $root $rel) -Value ("---`n" + $padding + "`nstatus: 'Production'`n---") -Encoding UTF8
        $details = Get-TaskFinalizationDetails -TaskId "F-255" -ProjectRoot $root
        Assert-Result "late status finalizes" $details.IsFinalized ($details | Out-String)
    }

    $results += Run-Test -Name "Item255 filename owner accepts paths and decodes only spec names" -Body {
        Assert-Result "bare ID decoded" ((Get-BacklogSpecFiles -SpecPath "features/active/F-255.md" -DecodeId) -eq "F-255") "bare ID not decoded"
        Assert-Result "slug decoded" ((Get-BacklogSpecFiles -SpecPath "features/active/F-255_a_b.md" -DecodeId) -eq "F-255") "slug not decoded"
        Assert-Result "non markdown rejected" (-not (Get-BacklogSpecFiles -Task "F-255" -SpecPath "F-255_notes.txt")) "accepted non-spec"
        Assert-Result "prefix rejected" (-not (Get-BacklogSpecFiles -Task "F-25" -SpecPath "F-255.md")) "accepted prefix ID"
    }

    $results += Run-Test -Name "Item255 path status reads the complete frontmatter and refuses missing paths" -Body {
        $path = Join-Path $tempRoot "item255-status.md"
        $padding = (1..35 | ForEach-Object { "note_" + $_ + ": value" }) -join "`n"
        Set-Content -LiteralPath $path -Value ("---`n" + $padding + "`nstatus: 'Ready for Deploy'`n---") -Encoding UTF8
        Assert-Result "late quoted status" ((Get-BacklogSpecStatus -SpecPath $path) -eq "Ready for Deploy") "status truncated or quote retained"
        $refused = $false
        try { Get-BacklogSpecStatus -SpecPath ($path + ".missing") | Out-Null } catch { $refused = $true }
        Assert-Result "missing path refused" $refused "missing spec silently defaulted"
    }

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
            $output = @(Invoke-ExternalCommand -AsLines { Invoke-HumanGateBacklogFinalization -TaskId "F-197" -ProjectRoot $root -BacklogPath $backlog -HasTaskBranch $true 6>&1 })
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

    $results += Run-Test -Name "Human-gate backlog finalization refuses a missing BACKLOG.md" -Body {
        $root = Join-Path $tempRoot "gate-nobacklog"
        New-MinimalBacklogTree -Root $root
        New-SpecFile -Root $root -RelPath "features/active/F-1_Test.md" -ItemId "F-1" -Type "feature" -Priority "P2" -Title "Test" | Out-Null
        $backlog = Join-Path $root "BACKLOG.md"
        if (Test-Path -LiteralPath $backlog) { Remove-Item -LiteralPath $backlog -Force }
        $output = @(Invoke-ExternalCommand -AsLines { Invoke-HumanGateBacklogFinalization -TaskId "F-1" -ProjectRoot $root -BacklogPath $backlog -HasTaskBranch $true 6>&1 })
        $text = $output -join "`n"
        Assert-Result "missing BACKLOG.md returns false" ($output[-1] -eq $false) $text
        Assert-Result "refusal names the path and remedy" ($text -match "BACKLOG\.md is missing at .*BACKLOG\.md" -and $text -match "Restore BACKLOG\.md with an exact row for F-1" -and $text -match "STOP:.*refusing to push") $text
        Assert-Result "spec left active" (Test-Path -LiteralPath (Join-Path $root "features/active/F-1_Test.md")) "the spec was archived without a backlog"
    }

    foreach ($rowCase in @("prefix-only", "prose-only")) {
        $results += Run-Test -Name ("Human-gate backlog finalization refuses a missing exact row: " + $rowCase) -Body {
            $root = Join-Path $tempRoot ("gate-norow-" + $rowCase)
            New-MinimalBacklogTree -Root $root
            New-SpecFile -Root $root -RelPath "features/active/F-1_Test.md" -ItemId "F-1" -Type "feature" -Priority "P2" -Title "Test" | Out-Null
            $other = if ($rowCase -eq "prefix-only") { "| F-10 | Ready | Other |" } else { "| F-20 | Ready | Replaces F-1 |" }
            $backlog = Join-Path $root "BACKLOG.md"
            [System.IO.File]::WriteAllText($backlog, ("| ID | Status | Title |`n|---|---|---|`n" + $other + "`n"), [System.Text.UTF8Encoding]::new($false))
            New-Item -ItemType Directory -Path (Join-Path $root ".crucible") -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root ".crucible/config.yaml"), "paths:`n  backlog: .`n", [System.Text.UTF8Encoding]::new($false))
            $output = @(Invoke-ExternalCommand -AsLines { Invoke-HumanGateBacklogFinalization -TaskId "F-1" -ProjectRoot $root -BacklogPath $backlog -HasTaskBranch $true 6>&1 })
            $text = $output -join "`n"
            Assert-Result "missing exact row returns false" ($output[-1] -eq $false) $text
            Assert-Result "refusal names the exact row and remedy" ($text -match 'no exact row for F-1' -and $text -match 'Repair the row in BACKLOG.md' -and $text -match 'STOP:.*refusing to push') $text
            Assert-Result "spec left active" (Test-Path -LiteralPath (Join-Path $root "features/active/F-1_Test.md")) "the spec was archived without a row"
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
