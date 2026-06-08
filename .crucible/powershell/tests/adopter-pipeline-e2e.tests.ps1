# End-to-end integration tests that drive the REAL factory.ps1 -Init entrypoint
# through the back half of the pipeline. Where adopter-bootstrap.tests.ps1 stops at
# scaffolding the first implementation phase, this exercises the deployment -> done
# human gate through the genuine router + gate chain - the integration surface where
# the session_end and stale-accept gate bypasses both lived. Locks the cycle-scoped
# human-gate behavior at the entrypoint level, not just the unit (Invoke-HumanGate)
# level.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$INIT_SCRIPT = Join-Path $REPO_ROOT "powershell/init-project.ps1"
$FACTORY_SCRIPT = Join-Path $REPO_ROOT "powershell/factory.ps1"
$NEWHANDOFF_SCRIPT = Join-Path $REPO_ROOT "powershell/new-handoff.ps1"

$results = @()

function Assert-Result {
    param([string]$Name, [bool]$Condition, [string]$FailureMessage)
    if (-not $Condition) { throw ("FAILED: " + $Name + " - " + $FailureMessage) }
}

function Invoke-ExternalCommand {
    param([Parameter(Mandatory=$true)][scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Command 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [PSCustomObject]@{ Output = $output; ExitCode = $exitCode }
}

function Run-Test {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ("`nTest: " + $Name) -ForegroundColor Cyan
    try {
        & $Body
        Write-Host "PASSED" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "EXCEPTION OCCURRED: $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        return $false
    }
}

# Stand up a fully-initialized adopter project with a deployment -> done handoff
# already queued, so a single factory.ps1 -Init reaches the human gate.
# Stand up a fully-initialized adopter project with one active feature spec
# registered in BACKLOG.md. Returns the project root. Shared by all pipeline tests.
function New-AdopterProject {
    param([string]$Root, [string]$TaskId, [string]$Title, [string]$Status, [string]$StatusTarget)

    $slug = $Title.Replace(" ", "_")
    $projectRoot = Join-Path $Root "app"
    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

    Push-Location $projectRoot
    try {
        git init --quiet
        git config user.name "Test User"
        git config user.email "test@example.com"
        Set-Content -Path "README.md" -Value "# App"
        New-Item -ItemType Directory -Path "src" -Force | Out-Null
        Set-Content -Path "src/feature.txt" -Value "work product"
        git add -A
        git commit -m "initial commit" --quiet
    } finally {
        Pop-Location
    }

    $initCmd = Invoke-ExternalCommand {
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $INIT_SCRIPT `
            -ProjectRoot $projectRoot -ProjectName "App" -Quiet
    }
    if ($initCmd.ExitCode -ne 0) {
        throw ("init-project failed (" + $initCmd.ExitCode + "): " + ($initCmd.Output -join "`n"))
    }

    # Make verification commands cheap and replace the engineering-rules placeholder.
    $configPath = Join-Path $projectRoot ".crucible/config.yaml"
    $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $cfg = $cfg.Replace("replace-with-project-quick-test-command", "echo quick")
    $cfg = $cfg.Replace("replace-with-project-full-test-command", "echo full")
    $cfg = $cfg.Replace("Replace with project-specific engineering rules.", "Rules updated.")
    $cfg | Out-File -LiteralPath $configPath -Encoding UTF8

    # Active spec for the task (present so the router can resolve it).
    $specPath = Join-Path $projectRoot (".crucible/backlog/features/active/" + $TaskId + "_" + $slug + ".md")
    $spec = @"
---
item_id: $TaskId
title: $Title
status: $Status
priority: P1
target_phase: grooming
budget_tier: low
---

## Summary
A pipeline task.
"@
    Set-Content -LiteralPath $specPath -Value $spec -Encoding UTF8

    # Register the task in BACKLOG.md so new-handoff can resolve it and archival can
    # parse the row. The row must go AFTER the table separator (not between header and
    # separator) or Get-MarkdownTableStatusColumn cannot locate the Status column.
    $backlogFile = Join-Path $projectRoot ".crucible/backlog/BACKLOG.md"
    $backlogLines = Get-Content -LiteralPath $backlogFile -Encoding UTF8
    $newBacklogLines = @()
    $seenHeader = $false
    $inserted = $false
    foreach ($line in $backlogLines) {
        $newBacklogLines += $line
        if ($line -match '^\s*\|\s*ID\s*\|') { $seenHeader = $true; continue }
        if ($seenHeader -and -not $inserted -and $line -match '^\s*\|?\s*:?-{3,}') {
            $newBacklogLines += ("| [{0}](features/active/{0}_{1}.md) | P1 | {2} | {3} | {4} |" -f $TaskId, $slug, $Status, $Title, $StatusTarget)
            $inserted = $true
        }
    }
    [System.IO.File]::WriteAllText($backlogFile, (($newBacklogLines) -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

    return $projectRoot
}

# Write a schema-valid handoff JSON straight into the bundle's handoffs dir, so a
# subsequent factory.ps1 -Init processes it as the latest pending handoff. $Extra
# supplies the per-transition required fields (artifacts, reviewer_checks_passed,
# commit_hash, file_affinity, etc.).
function Write-PipelineHandoff {
    param([string]$ProjectRoot, [string]$TaskId, [string]$Source, [string]$Target, [string]$Cycle, [int]$Count, [hashtable]$Extra)

    $h = [ordered]@{
        task_id                  = $TaskId
        source_phase             = $Source
        target_phase             = $Target
        reason                   = ("E2E transition " + $Source + " -> " + $Target)
        handoff_retry_count      = 0
        review_strike_count      = 0
        rebase_count             = 0
        budget_tier              = "low"
        cumulative_handoff_count = $Count
        prompt_version           = "1.0.0"
        session_cycle_id         = $Cycle
        cycle_id                 = $null
        file_affinity            = @("src/")
        generated_by             = "new-handoff.ps1"
        tool_version             = "1.0.0"
    }
    if ($null -ne $Extra) {
        foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }
    }

    $handoffDir = Join-Path $ProjectRoot ".crucible/session/handoffs"
    New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
    $ts = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    $path = Join-Path $handoffDir ($TaskId + "-" + $ts + ".json")
    ($h | ConvertTo-Json -Depth 12) | Set-Content -Path $path -Encoding UTF8
    return $path
}

# Simulate the source-phase agent completing its task.md checklist before handoff.
# The checklist quality gate blocks a transition while required items remain
# unchecked, so each phase must be "done" before it hands off.
function Complete-PhaseChecklist {
    param([string]$ProjectRoot, [string]$TaskId, [string]$Phase)
    $taskMd = Join-Path $ProjectRoot (".crucible/session/" + $TaskId + "/" + $Phase + "/task.md")
    if (Test-Path -LiteralPath $taskMd) {
        $content = Get-Content -LiteralPath $taskMd -Raw -Encoding UTF8
        $content = $content -replace '(?m)^(\s*[-*]\s*)\[ \]', '${1}[x]'
        [System.IO.File]::WriteAllText($taskMd, $content, [System.Text.UTF8Encoding]::new($false))
    }
}

# Build the deployment-gate fixture: an adopter project with a deployment -> done
# handoff already queued, so a single factory.ps1 -Init reaches the human gate.
function New-DeploymentGateFixture {
    param([string]$Root, [string]$Cycle)

    $projectRoot = New-AdopterProject -Root $Root -TaskId "F-900" -Title "Ship It" -Status "Ready for Deploy" -StatusTarget "Operator"

    Push-Location $projectRoot
    try {
        $head = (git rev-parse HEAD).Trim()
        $hCmd = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $NEWHANDOFF_SCRIPT `
                -TaskId "F-900" -Source "deployment" -Target "done" `
                -Reason "Operator completed merge; ready to finalize" `
                -CommitHash $head -SessionCycleId $Cycle -ProjectRoot $projectRoot
        }
        if ($hCmd.ExitCode -ne 0) {
            throw ("new-handoff failed (" + $hCmd.ExitCode + "): " + ($hCmd.Output -join "`n"))
        }
    } finally {
        Pop-Location
    }

    return $projectRoot
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-pipeline-e2e-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$savedCycleEnv = $env:FACTORY_CYCLE_ID
try {
    $results += Run-Test -Name "factory -Init drives a deployment->done handoff to the human gate" -Body {
        $cycle = "cycle-e2e-1"
        $env:FACTORY_CYCLE_ID = $cycle
        $projectRoot = New-DeploymentGateFixture -Root (Join-Path $tempRoot "t1") -Cycle $cycle

        $gateRun = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT `
                -Init -TaskId "F-900" -ProjectRoot $projectRoot -Quiet
        }
        Assert-Result -Name "gate run exits 0 (awaiting human decision)" -Condition ($gateRun.ExitCode -eq 0) `
            -FailureMessage ("expected exit 0, got " + $gateRun.ExitCode + ". Output: " + ($gateRun.Output -join "`n"))

        $pendingFile = Join-Path $projectRoot ".crucible/session/F-900/gate_pending.txt"
        Assert-Result -Name "human gate fired (pending file created)" -Condition (Test-Path -LiteralPath $pendingFile) `
            -FailureMessage ("expected gate_pending.txt at " + $pendingFile + ". Output: " + ($gateRun.Output -join "`n"))
    }

    $results += Run-Test -Name "Recording accepted stamps the gate decision with the firing cycle" -Body {
        $cycle = "cycle-e2e-2"
        $env:FACTORY_CYCLE_ID = $cycle
        $projectRoot = New-DeploymentGateFixture -Root (Join-Path $tempRoot "t2") -Cycle $cycle

        $acceptRun = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT `
                -Init -TaskId "F-900" -ProjectRoot $projectRoot -Quiet `
                -GateOutcome "accepted" -GateReason "verified locally and ready to ship"
        }
        Assert-Result -Name "accept run exits 0" -Condition ($acceptRun.ExitCode -eq 0) `
            -FailureMessage ("expected exit 0, got " + $acceptRun.ExitCode + ". Output: " + ($acceptRun.Output -join "`n"))

        $gateDir = Join-Path $projectRoot ".crucible/session/global/gate_decisions"
        $decisions = @(Get-ChildItem -Path $gateDir -Filter "F-900-*.json" -ErrorAction SilentlyContinue)
        Assert-Result -Name "an archived gate decision was written" -Condition ($decisions.Count -ge 1) `
            -FailureMessage ("expected an F-900-*.json decision under " + $gateDir + ". Output: " + ($acceptRun.Output -join "`n"))

        $decision = Get-Content -LiteralPath $decisions[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Result -Name "decision outcome is accepted" -Condition ($decision.outcome -eq "accepted") `
            -FailureMessage ("expected outcome accepted, got " + $decision.outcome)
        Assert-Result -Name "decision is stamped with the firing cycle" -Condition ($decision.PSObject.Properties["session_cycle_id"] -and $decision.session_cycle_id -eq $cycle) `
            -FailureMessage ("expected session_cycle_id '" + $cycle + "', got '" + $decision.session_cycle_id + "'")

        # Accept drives the back half to completion: the active spec is archived
        # (task reaches done). Proves the real entrypoint finalizes, not just gates.
        $activeSpec = Join-Path $projectRoot ".crucible/backlog/features/active/F-900_Ship_It.md"
        Assert-Result -Name "active spec archived after accept (task finalized)" -Condition (-not (Test-Path -LiteralPath $activeSpec)) `
            -FailureMessage ("expected active spec to be archived/removed after accept, but it still exists at " + $activeSpec + ". Output: " + ($acceptRun.Output -join "`n"))
    }

    $results += Run-Test -Name "Drives the front half: grooming -> implementation -> verification -> deployment" -Body {
        $cycle = "cycle-e2e-front"
        $env:FACTORY_CYCLE_ID = $cycle
        $task = "F-700"
        $projectRoot = New-AdopterProject -Root (Join-Path $tempRoot "t4") -TaskId $task -Title "Front Half" -Status "Ready" -StatusTarget "Groomer"

        $checks = @("tests_pass","vet_pass","acceptance_criteria_met","scope_bounded","no_regressions","no_hard_mandates_violated")
        $artifacts = @("src/feature.txt")

        # Each step: an agent emits a handoff for the next transition, then factory.ps1
        # -Init processes it through the real router + gates and scaffolds the target
        # phase. Required per-transition fields come straight from handoff.schema.json.
        $transitions = @(
            @{ Source = "grooming";       Target = "implementation"; Count = 1; Extra = @{ artifacts = $artifacts; file_affinity = @("src/") } },
            @{ Source = "implementation"; Target = "verification";   Count = 2; Extra = @{ artifacts = $artifacts } },
            @{ Source = "verification";   Target = "deployment";     Count = 3; Extra = @{ artifacts = $artifacts; reviewer_checks_passed = $checks } }
        )

        foreach ($t in $transitions) {
            Complete-PhaseChecklist -ProjectRoot $projectRoot -TaskId $task -Phase $t.Source

            # Simulate the Reviewer's mandatory completion artifact before the
            # verification -> deployment handoff (review_report.md must say APPROVED).
            if ($t.Source -eq "verification") {
                $vdir = Join-Path $projectRoot (".crucible/session/" + $task + "/verification")
                New-Item -ItemType Directory -Path $vdir -Force | Out-Null
                $report = "---`nreview_decision: APPROVED`nacceptance_criteria_met: true`n---`n`n# Review Report`n`nAPPROVED. All checks passed.`n"
                [System.IO.File]::WriteAllText((Join-Path $vdir "review_report.md"), $report, [System.Text.UTF8Encoding]::new($false))
            }

            Write-PipelineHandoff -ProjectRoot $projectRoot -TaskId $task -Source $t.Source -Target $t.Target -Cycle $cycle -Count $t.Count -Extra $t.Extra | Out-Null

            $run = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT `
                    -Init -TaskId $task -ProjectRoot $projectRoot -Quiet
            }
            $label = ($t.Source + " -> " + $t.Target)
            Assert-Result -Name ("transition accepted: " + $label) -Condition ($run.ExitCode -eq 0) `
                -FailureMessage ("expected exit 0 for " + $label + ", got " + $run.ExitCode + ". Output: " + ($run.Output -join "`n"))

            $targetPrompt = Join-Path $projectRoot (".crucible/session/" + $task + "/" + $t.Target + "/prompt.md")
            Assert-Result -Name ("target phase scaffolded: " + $t.Target) -Condition (Test-Path -LiteralPath $targetPrompt) `
                -FailureMessage ("expected " + $t.Target + "/prompt.md to be scaffolded for " + $label + ". Output: " + ($run.Output -join "`n"))
        }
    }
}
finally {
    $env:FACTORY_CYCLE_ID = $savedCycleEnv
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
