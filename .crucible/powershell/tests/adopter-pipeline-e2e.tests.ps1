# End-to-end integration tests that drive the REAL crucible.ps1 -Init entrypoint
# through the back half of the pipeline. Where adopter-bootstrap.tests.ps1 stops at
# scaffolding the first implementation phase, this exercises the deployment -> done
# human gate through the genuine router + gate chain - the integration surface where
# the session_end and stale-accept gate bypasses both lived. Locks the cycle-scoped
# human-gate behavior at the entrypoint level, not just the unit (Invoke-HumanGate)
# level.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/time.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/config-helpers.ps1")
$INIT_SCRIPT = Join-Path $REPO_ROOT "powershell/init-project.ps1"
$CRUCIBLE_SCRIPT = Join-Path $REPO_ROOT "powershell/crucible.ps1"
$NEWHANDOFF_SCRIPT = Join-Path $REPO_ROOT "powershell/new-handoff.ps1"

$results = @()










# Stand up a fully-initialized adopter project with a deployment -> done handoff
# already queued, so a single crucible.ps1 -Init reaches the human gate.
# Stand up a fully-initialized adopter project with one active feature spec
# registered in BACKLOG.md. Returns the project root. Shared by all pipeline tests.
function New-AdopterProject {
    param([string]$Root, [string]$TaskId, [string]$Title, [string]$Status, [string]$StatusTarget)

    $slug = $Title.Replace(" ", "_")
    $projectRoot = Join-Path $Root "app"

    . (Join-Path $PSScriptRoot "_fixtures.ps1")
    $sharedFixture = Get-SharedAdopterFixture
    Copy-Item -Path $sharedFixture -Destination $projectRoot -Recurse

    $srcDir = Join-Path $projectRoot "src"
    New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
    Set-Content -Path (Join-Path $srcDir "feature.txt") -Value "work product"
    # The Operator writes the dev log before the deployment -> done handoff, and the
    # dev-log check runs ahead of the Human Gate.
    $devLogsDir = Join-Path $projectRoot ".crucible/dev-logs"
    New-Item -ItemType Directory -Path $devLogsDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $devLogsDir "UNPUBLISHED_LOGS.md"), "## $TaskId`nValid dev log entry.`n", [System.Text.UTF8Encoding]::new($false))

    Push-Location $projectRoot
    try {
        git config user.name "Test User"
        git config user.email "test@example.com"
        # init-project generates .claude/agents/crucible-*.md at the project root (item 213),
        # which an adopter commits with the scaffold; the cleanliness gate flags it otherwise.
        git add src/feature.txt .crucible/dev-logs/UNPUBLISHED_LOGS.md .claude/agents
        git commit -m "add feature.txt" --quiet
    } finally {
        Pop-Location
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
# subsequent crucible.ps1 -Init processes it as the latest pending handoff. $Extra
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

    $handoffDir = Join-Path (Get-ConfiguredPath -Key "session" -ProjectRoot $ProjectRoot) "handoffs"
    New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
    $ts = Get-UtcFileTimestampMs
    $path = Join-Path $handoffDir ($TaskId + "-" + $ts + ".json")
    ($h | ConvertTo-Json -Depth 12) | Set-Content -Path $path -Encoding UTF8
    return $path
}

# Simulate the source-phase agent completing its task.md checklist before handoff.
# The checklist quality gate blocks a transition while required items remain
# unchecked, so each phase must be "done" before it hands off.
function Complete-PhaseChecklist {
    param([string]$ProjectRoot, [string]$TaskId, [string]$Phase)
    $taskMd = Join-Path (Get-ConfiguredPath -Key "session" -ProjectRoot $ProjectRoot) ($TaskId + "/" + $Phase + "/task.md")
    if (Test-Path -LiteralPath $taskMd) {
        $content = Get-Content -LiteralPath $taskMd -Raw -Encoding UTF8
        $content = $content -replace '(?m)^(\s*[-*]\s*)\[ \]', '${1}[x]'
        [System.IO.File]::WriteAllText($taskMd, $content, [System.Text.UTF8Encoding]::new($false))
    }
}

# Build the deployment-gate fixture: an adopter project with a deployment -> done
# handoff already queued, so a single crucible.ps1 -Init reaches the human gate.
function New-DeploymentGateFixture {
    param([string]$Root, [string]$Cycle)

    $projectRoot = New-AdopterProject -Root $Root -TaskId "F-900" -Title "Ship It" -Status "Ready for Deploy" -StatusTarget "Operator"

    Push-Location $projectRoot
    try {
        $head = (Invoke-ExternalCommand -AsLines { git rev-parse HEAD }).Trim()
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

$tempRoot = New-TestFixtureRoot -NameHint "pipeline-e2e"

$savedCycleEnv = $env:CRUCIBLE_CYCLE_ID
try {
    $results += Run-Test -Name "crucible -Init drives a deployment->done handoff to the human gate" -Body {
        $cycle = "cycle-e2e-1"
        $env:CRUCIBLE_CYCLE_ID = $cycle
        $projectRoot = New-DeploymentGateFixture -Root (Join-Path $tempRoot "t1") -Cycle $cycle

        $gateRun = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CRUCIBLE_SCRIPT `
                -Init -TaskId "F-900" -ProjectRoot $projectRoot -Quiet
        }
        Assert-Result -Name "gate run exits 0 (awaiting human decision)" -Condition ($gateRun.ExitCode -eq 0) `
            -FailureMessage ("expected exit 0, got " + $gateRun.ExitCode + ". Output: " + ($gateRun.Output -join "`n"))

        $pendingFile = Join-Path $projectRoot ".crucible/session/F-900/gate_pending.txt"
        Assert-Result -Name "human gate fired (pending file created)" -Condition (Test-Path -LiteralPath $pendingFile) `
            -FailureMessage ("expected gate_pending.txt at " + $pendingFile + ". Output: " + ($gateRun.Output -join "`n"))
    }

    $results += Run-Test -Name "bundle entrypoint derives project root from script location, not cwd" -Body {
        # Regression: crucible.ps1 used to default -ProjectRoot to the caller's cwd, so an
        # orchestrator running the gate from a different checkout silently targeted the wrong
        # repo ("No active handoff"). The bundle's own entrypoint must resolve its project from
        # $PSScriptRoot (<root>/.crucible/powershell) regardless of where it is invoked.
        $cycle = "cycle-e2e-derive"
        $env:CRUCIBLE_CYCLE_ID = $cycle
        $projectRoot = New-DeploymentGateFixture -Root (Join-Path $tempRoot "t-derive") -Cycle $cycle
        $bundleCrucible = Join-Path $projectRoot ".crucible/powershell/crucible.ps1"

        # cwd is deliberately an UNRELATED directory with no .crucible/. If root fell back to
        # cwd, Crucible would find no F-900 handoff and exit 1 with no gate fired here.
        Push-Location $tempRoot
        try {
            $gateRun = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $bundleCrucible `
                    -Init -TaskId "F-900" -Quiet
            }
        } finally {
            Pop-Location
        }

        Assert-Result -Name "derive run exits 0" -Condition ($gateRun.ExitCode -eq 0) `
            -FailureMessage ("expected exit 0, got " + $gateRun.ExitCode + ". Output: " + ($gateRun.Output -join "`n"))

        $pendingFile = Join-Path $projectRoot ".crucible/session/F-900/gate_pending.txt"
        Assert-Result -Name "gate fired in the script-derived project (not cwd)" -Condition (Test-Path -LiteralPath $pendingFile) `
            -FailureMessage ("expected gate_pending.txt at " + $pendingFile + " proving root derived from script location. Output: " + ($gateRun.Output -join "`n"))

        $cwdCrucible = Join-Path $tempRoot ".crucible"
        Assert-Result -Name "no .crucible leaked into cwd" -Condition (-not (Test-Path -LiteralPath $cwdCrucible)) `
            -FailureMessage ("Crucible wrote a .crucible under cwd " + $tempRoot + ", meaning it still resolved root from cwd")
    }

    $results += Run-Test -Name "bundle new-handoff derives project root from script location, not cwd" -Body {
        # Regression: new-handoff.ps1 used to default the project root to the caller's cwd and
        # threw "current working directory is not a valid Crucible project" when the orchestrator
        # bootstrapped a handoff from another checkout (the crucible repo dispatching into an
        # adopter). The bundle's own new-handoff must resolve its project from $PSScriptRoot
        # (<root>/.crucible/powershell) regardless of where it is invoked.
        $cycle = "cycle-nh-derive"
        $env:CRUCIBLE_CYCLE_ID = $cycle
        $projectRoot = New-DeploymentGateFixture -Root (Join-Path $tempRoot "t-nh-derive") -Cycle $cycle
        $bundleNewHandoff = Join-Path $projectRoot ".crucible/powershell/new-handoff.ps1"
        $head = (Invoke-ExternalCommand -AsLines { git -C $projectRoot rev-parse HEAD }).Trim()

        # cwd is deliberately an UNRELATED directory with no .crucible/. If root fell back to
        # cwd, new-handoff would throw the invalid-project error and exit non-zero.
        Push-Location $tempRoot
        try {
            $hRun = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $bundleNewHandoff `
                    -TaskId "F-900" -Source "grooming" -Target "implementation" `
                    -Reason "derive-check bootstrap" -SessionCycleId $cycle -CycleId "initial" `
                    -CommitHash $head
            }
        } finally {
            Pop-Location
        }

        Assert-Result -Name "derive run exits 0" -Condition ($hRun.ExitCode -eq 0) `
            -FailureMessage ("expected exit 0, got " + $hRun.ExitCode + ". Output: " + ($hRun.Output -join "`n"))

        # The handoff must land in the SCRIPT-derived project, proving root != cwd. Distinguish
        # it from the fixture's deployment->done handoff by the grooming->implementation transition.
        $handoffDir = Join-Path $projectRoot ".crucible/session/handoffs"
        $handoffs = @(Get-ChildItem -Path $handoffDir -Filter "F-900-*.json" -ErrorAction SilentlyContinue)
        $groomHandoff = $handoffs | Where-Object {
            $j = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $j.target_phase -eq "implementation"
        }
        Assert-Result -Name "handoff written into the script-derived project (not cwd)" -Condition ($null -ne $groomHandoff) `
            -FailureMessage ("expected a grooming->implementation F-900 handoff under " + $handoffDir + " proving root derived from script location. Output: " + ($hRun.Output -join "`n"))

        $cwdCrucible = Join-Path $tempRoot ".crucible"
        Assert-Result -Name "no .crucible leaked into cwd" -Condition (-not (Test-Path -LiteralPath $cwdCrucible)) `
            -FailureMessage ("new-handoff wrote a .crucible under cwd " + $tempRoot + ", meaning it still resolved root from cwd")
    }

    $results += Run-Test -Name "Recording accepted stamps the gate decision with the firing cycle" -Body {
        $cycle = "cycle-e2e-2"
        $env:CRUCIBLE_CYCLE_ID = $cycle
        $projectRoot = New-DeploymentGateFixture -Root (Join-Path $tempRoot "t2") -Cycle $cycle

        $handoffDir = Join-Path $projectRoot ".crucible/session/handoffs"
        $otherTaskHandoff = Join-Path $handoffDir "F-901-20260615T120000Z.json"
        '{"task_id":"F-901","source_phase":"grooming","target_phase":"implementation"}' |
            Set-Content -LiteralPath $otherTaskHandoff -Encoding UTF8

        $acceptRun = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CRUCIBLE_SCRIPT `
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

        $activeHandoffs = @(Get-ChildItem -LiteralPath $handoffDir -Filter "F-900-*.json" -ErrorAction SilentlyContinue)
        $archivedHandoffDir = Join-Path $handoffDir "archived"
        $archivedHandoffs = @(Get-ChildItem -LiteralPath $archivedHandoffDir -Filter "F-900-*.json" -ErrorAction SilentlyContinue)
        Assert-Result -Name "accepted task handoffs archived" -Condition ($activeHandoffs.Count -eq 0 -and $archivedHandoffs.Count -ge 1) `
            -FailureMessage ("expected F-900 handoffs archived and removed from active handoff dir. Output: " + ($acceptRun.Output -join "`n"))
        Assert-Result -Name "other task handoff preserved" -Condition (Test-Path -LiteralPath $otherTaskHandoff) `
            -FailureMessage "expected unrelated F-901 handoff to remain active"
    }

    $results += Run-Test -Name "TODO 192: refused reasons preserve the gate; a corrected file accepts" -Body {
        # TODO item 192: a task branch and active spec make merge and archive observable.
        # A correction must work on the same pending file without rebuilding the gate.
        $cycle = "cycle-e2e-reason"
        $env:CRUCIBLE_CYCLE_ID = $cycle
        $projectRoot = New-DeploymentGateFixture -Root (Join-Path $tempRoot "reason") -Cycle $cycle
        $baseSha = (Invoke-ExternalCommand -AsLines { git -C $projectRoot rev-parse HEAD }).Trim()
        git -C $projectRoot branch task/F-900
        $gateDir = Join-Path $projectRoot ".crucible/session/global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $pendingPath = Join-Path $gateDir "gate_decision_F-900_pending.json"
        $activeSpec = Join-Path $projectRoot ".crucible/backlog/features/active/F-900_Ship_It.md"
        $specBefore = Get-Content -LiteralPath $activeSpec -Raw
        $backlogPath = Join-Path $projectRoot ".crucible/backlog/BACKLOG.md"
        $backlogBefore = Get-Content -LiteralPath $backlogPath | Where-Object { $_ -match '\[F-900\]' }

        foreach ($entryPath in @("CLI", "file")) {
            foreach ($reason in @("", "ok")) {
                $pendingJson = @{ task_id = "F-900"; outcome = "accepted"; reason = $reason } | ConvertTo-Json
                Set-Content -LiteralPath $pendingPath -Value $pendingJson -Encoding UTF8
                $gateArgs = if ($entryPath -eq "CLI") { @("-GateOutcome", "accepted", "-GateReason", $reason) } else { @() }
                $run = Invoke-ExternalCommand {
                    & (Get-PwshCommand) -NoProfile -File $CRUCIBLE_SCRIPT -Init -TaskId "F-900" -ProjectRoot $projectRoot -Quiet @gateArgs
                }
                $text = $run.Output -join "`n"
                $guidance = if ($entryPath -eq "CLI") { "-GateReason is required" } else { '"reason" in .+ is required' }
                Assert-Result -Name "$entryPath refuses '$reason'" -Condition ($run.ExitCode -eq 1 -and $text -match $guidance) `
                    -FailureMessage ("expected exit 1 with reason guidance, got " + $run.ExitCode + ". Output: " + $text)
                Assert-Result -Name "$entryPath preserves pending JSON" `
                    -Condition ((Test-Path -LiteralPath $pendingPath) -and (Get-Content -LiteralPath $pendingPath -Raw).TrimEnd() -eq $pendingJson.TrimEnd()) `
                    -FailureMessage "pending decision changed"
                $decisions = @(Get-ChildItem -LiteralPath $gateDir -Filter "F-900-*.json")
                Assert-Result -Name "$entryPath records no decision" -Condition ($decisions.Count -eq 0) -FailureMessage "refused decision recorded"
                Assert-Result -Name "$entryPath leaves spec and backlog intact" `
                    -Condition ((Test-Path -LiteralPath $activeSpec) -and (Get-Content -LiteralPath $activeSpec -Raw) -eq $specBefore -and (Get-Content -LiteralPath $backlogPath | Where-Object { $_ -match '\[F-900\]' }) -eq $backlogBefore) `
                    -FailureMessage "refused decision archived or finalized the task"
                git -C $projectRoot show-ref --verify --quiet refs/heads/task/F-900
                Assert-Result -Name "$entryPath leaves task branch intact" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "task branch removed"
                Assert-Result -Name "$entryPath leaves primary branch intact" `
                    -Condition ((Invoke-ExternalCommand -AsLines { git -C $projectRoot rev-parse master }).Trim() -eq $baseSha -and $text -notmatch '\[MERGE\]') `
                    -FailureMessage "refused decision attempted a merge"
            }
        }

        $validReason = "Looks good. I see nothing concerning."
        @{ task_id = "F-900"; outcome = "accepted"; reason = $validReason } | ConvertTo-Json |
            Set-Content -LiteralPath $pendingPath -Encoding UTF8
        $run = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -File $CRUCIBLE_SCRIPT -Init -TaskId "F-900" -ProjectRoot $projectRoot -Quiet
        }
        $text = $run.Output -join "`n"
        Assert-Result -Name "corrected file accepts" -Condition ($run.ExitCode -eq 0 -and $text -match "Decision recorded: accepted") `
            -FailureMessage ("expected exit 0 recording accepted, got " + $run.ExitCode + ". Output: " + $text)
        $decisions = @(Get-ChildItem -LiteralPath $gateDir -Filter "F-900-*.json")
        Assert-Result -Name "corrected decision archived once" -Condition ($decisions.Count -eq 1) -FailureMessage "expected one recorded decision"
        $decision = Get-Content -LiteralPath $decisions[0].FullName -Raw | ConvertFrom-Json
        Assert-Result -Name "valid reason and cycle recorded" -Condition ($decision.reason -eq $validReason -and $decision.session_cycle_id -eq $cycle) `
            -FailureMessage "recorded reason or cycle changed"
        Assert-Result -Name "accepted task archived and pending file removed" `
            -Condition (-not (Test-Path -LiteralPath $activeSpec) -and -not (Test-Path -LiteralPath $pendingPath)) `
            -FailureMessage "corrected decision failed to archive the task or clean up the pending file"
    }

    $results += Run-Test -Name "Drives the front half: grooming -> implementation -> verification -> deployment" -Body {
        $cycle = "cycle-e2e-front"
        $env:CRUCIBLE_CYCLE_ID = $cycle
        $task = "F-700"
        $projectRoot = New-AdopterProject -Root (Join-Path $tempRoot "t4") -TaskId $task -Title "Front Half" -Status "Ready" -StatusTarget "Groomer"

        $checks = @("tests_pass","vet_pass","acceptance_criteria_met","scope_bounded","no_regressions","no_hard_mandates_violated")
        $artifacts = @("src/feature.txt")

        # Each step: an agent emits a handoff for the next transition, then crucible.ps1
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
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CRUCIBLE_SCRIPT `
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



    $results += Run-Test -Name "Acceptance archives custom session logs and handoffs (item 188)" -Body {
        $cycle = "cycle-custom-archive"
        $env:CRUCIBLE_CYCLE_ID = $cycle
        $projectRoot = New-DeploymentGateFixture -Root (Join-Path $tempRoot "custom-archive") -Cycle $cycle
        $configPath = Join-Path $projectRoot ".crucible/config.yaml"
        $cfg = (Get-Content $configPath -Raw) + "`npaths:`n  session: .crucible/custom session`n"
        [System.IO.File]::WriteAllText($configPath, $cfg, [System.Text.UTF8Encoding]::new($false))
        $session = Join-Path $projectRoot ".crucible/custom session"
        Move-Item -LiteralPath (Join-Path $projectRoot ".crucible/session") -Destination $session
        New-Item -ItemType Directory -Path (Join-Path $session "F-900") -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $session "F-900/pipeline.log.jsonl"), "", [System.Text.UTF8Encoding]::new($false))
        $run = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -File $CRUCIBLE_SCRIPT -Init -TaskId F-900 -ProjectRoot $projectRoot -Quiet -GateOutcome accepted -GateReason "verified archival under configured session"
        }
        Assert-Result -Name "accept succeeds" -Condition ($run.ExitCode -eq 0) -FailureMessage ($run.Output -join "`n")
        Assert-Result -Name "custom pipeline log archived" -Condition (@(Get-ChildItem (Join-Path $session "archived") -Filter 'pipeline-F-900-*.log.jsonl' -ErrorAction SilentlyContinue).Count -gt 0) -FailureMessage "pipeline log not archived"
        Assert-Result -Name "custom handoff archived" -Condition (@(Get-ChildItem (Join-Path $session "handoffs/archived") -Filter 'F-900-*.json' -ErrorAction SilentlyContinue).Count -eq 1) -FailureMessage "handoff not archived"
        Assert-Result -Name "no default session" -Condition (-not (Test-Path (Join-Path $projectRoot ".crucible/session"))) -FailureMessage "created default session"
    }

    $results += Run-Test -Name "Custom workspaces and session complete one task end to end (item 188)" -Body {
        $cycle = "cycle-e2e-custom-paths"
        $env:CRUCIBLE_CYCLE_ID = $cycle
        $task = "F-188"
        $projectRoot = New-AdopterProject -Root (Join-Path $tempRoot "custom-paths") -TaskId $task -Title "Custom Paths" -Status "Ready" -StatusTarget "Groomer"
        $configPath = Join-Path $projectRoot ".crucible/config.yaml"
        $cfg = Get-Content -LiteralPath $configPath -Raw
        $cfg += "`npaths:`n  session: runtime state`n  workspaces: task worktrees`n"
        [System.IO.File]::WriteAllText($configPath, $cfg, [System.Text.UTF8Encoding]::new($false))
        $session = Join-Path $projectRoot "runtime state"
        $worktree = Join-Path $projectRoot "task worktrees/implementation-$task"
        # Runtime paths belong to the adopter; keep the custom paths out of its work product.
        [System.IO.File]::AppendAllText((Join-Path $projectRoot ".gitignore"), "`n/runtime state/`n/task worktrees/`n", [System.Text.UTF8Encoding]::new($false))
        git -C $projectRoot add .gitignore .crucible
        git -C $projectRoot commit -m "configure runtime paths" --quiet
        $artifacts = @("src/feature.txt")
        $checks = @("tests_pass", "vet_pass", "acceptance_criteria_met", "scope_bounded", "no_regressions", "no_hard_mandates_violated")
        $transitions = @(
            @{ Source = "grooming"; Target = "implementation"; Extra = @{ artifacts = $artifacts; file_affinity = @("src/") } },
            @{ Source = "implementation"; Target = "verification"; Extra = @{ artifacts = $artifacts } },
            @{ Source = "verification"; Target = "deployment"; Extra = @{ artifacts = $artifacts; reviewer_checks_passed = $checks } }
        )
        $count = 0
        foreach ($t in $transitions) {
            $count++
            Complete-PhaseChecklist -ProjectRoot $projectRoot -TaskId $task -Phase $t.Source
            if ($t.Source -eq "verification") {
                [System.IO.File]::WriteAllText((Join-Path $session "$task/verification/review_report.md"), "---`nreview_decision: APPROVED`nacceptance_criteria_met: true`n---`nApproved.`n", [System.Text.UTF8Encoding]::new($false))
            }
            Write-PipelineHandoff -ProjectRoot $projectRoot -TaskId $task -Source $t.Source -Target $t.Target -Cycle $cycle -Count $count -Extra $t.Extra | Out-Null
            $run = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -File $CRUCIBLE_SCRIPT -Init -TaskId $task -ProjectRoot $projectRoot -Quiet
            }
            Assert-Result -Name ("custom transition " + $t.Target) -Condition ($run.ExitCode -eq 0) -FailureMessage ($run.Output -join "`n")
            Assert-Result -Name "custom phase prompt" -Condition (Test-Path (Join-Path $session "$task/$($t.Target)/prompt.md")) -FailureMessage "phase prompt missing"
            $taskText = Get-Content (Join-Path $session "$task/$($t.Target)/task.md") -Raw
            Assert-Result -Name "resolved handoff uses custom session" -Condition ($taskText.Contains((Join-Path $session "handoffs"))) -FailureMessage $taskText
            if ($t.Target -eq "implementation") {
                Assert-Result -Name "Init created custom worktree" -Condition (Test-Path $worktree) -FailureMessage "worktree missing: $worktree"
                $check = Invoke-ExternalCommand {
                    & (Get-PwshCommand) -NoProfile -File (Join-Path $REPO_ROOT "powershell/run-isolated-checks.ps1") -TaskId $task -Mode full -ProjectRoot $projectRoot
                }
                Assert-Result -Name "isolated checks found custom worktree" -Condition ($check.ExitCode -eq 0) -FailureMessage ($check.Output -join "`n")
            }
            if ($t.Target -eq "verification") {
                Assert-Result -Name "verification checklist uses assigned worktree" -Condition ($taskText.Contains("Enter worktree $worktree")) -FailureMessage $taskText
                $promptText = Get-Content (Join-Path $session "$task/verification/prompt.md") -Raw
                Assert-Result -Name "prompt has no default runtime roots" -Condition ($promptText -notmatch '\.crucible/(session|\.agent-workspaces)') -FailureMessage $promptText
            }
        }
        Complete-PhaseChecklist -ProjectRoot $projectRoot -TaskId $task -Phase "deployment"
        $head = (Invoke-ExternalCommand -AsLines { git -C $projectRoot rev-parse HEAD }).Trim()
        Write-PipelineHandoff -ProjectRoot $projectRoot -TaskId $task -Source "deployment" -Target "done" -Cycle $cycle -Count 4 -Extra @{ commit_hash = $head; artifacts = $artifacts } | Out-Null
        $accept = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -File $CRUCIBLE_SCRIPT -Init -TaskId $task -ProjectRoot $projectRoot -Quiet -GateOutcome accepted -GateReason "checked custom paths and accepted work"
        }
        Assert-Result -Name "accept completes task" -Condition ($accept.ExitCode -eq 0) -FailureMessage ($accept.Output -join "`n")
        Assert-Result -Name "pipeline log archived under custom session" -Condition (@(Get-ChildItem (Join-Path $session "archived") -Filter "pipeline-$task-*.log.jsonl" -ErrorAction SilentlyContinue).Count -gt 0) -FailureMessage "pipeline log not archived"
        Assert-Result -Name "handoffs archived under custom session" -Condition (@(Get-ChildItem (Join-Path $session "handoffs/archived") -Filter "$task-*.json" -ErrorAction SilentlyContinue).Count -eq 4) -FailureMessage "handoffs not archived"
        foreach ($default in @(".crucible/session", ".crucible/.agent-workspaces")) {
            Assert-Result -Name ("no default " + $default) -Condition (-not (Test-Path (Join-Path $projectRoot $default))) -FailureMessage "created $default"
        }
    }

    $results += Run-Test -Name "A code task whose worktree is gone is stopped, not passed unchecked" -Body {
        # Item 187: with the task branch present but its worktree removed, the scope check
        # and the independent verification used to skip with a warning.
        $cycle = "cycle-e2e-wt"
        $env:CRUCIBLE_CYCLE_ID = $cycle
        $task = "F-702"
        $projectRoot = New-AdopterProject -Root (Join-Path $tempRoot "t6") -TaskId $task -Title "Worktree Gone" -Status "Ready" -StatusTarget "Groomer"
        $artifacts = @("src/feature.txt")

        Write-PipelineHandoff -ProjectRoot $projectRoot -TaskId $task -Source "grooming" -Target "implementation" -Cycle $cycle -Count 1 `
            -Extra @{ artifacts = $artifacts; file_affinity = @("src/") } | Out-Null
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CRUCIBLE_SCRIPT -Init -TaskId $task -ProjectRoot $projectRoot -Quiet }
        Assert-Result -Name "grooming -> implementation accepted" -Condition ($run.ExitCode -eq 0) `
            -FailureMessage ("expected exit 0, got " + $run.ExitCode + ". Output: " + ($run.Output -join "`n"))

        git -C $projectRoot rev-parse --verify --quiet "refs/heads/task/$task" *> $null
        Assert-Result -Name "task branch created" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "expected -Init to create task/$task"
        $wt = @(Invoke-ExternalCommand -AsLines { git -C $projectRoot worktree list --porcelain } | Where-Object { $_ -like "worktree *" } | ForEach-Object { $_.Substring(9) } | Where-Object { $_ -match [regex]::Escape($task) })
        Assert-Result -Name "task worktree created" -Condition ($wt.Count -eq 1) -FailureMessage ("expected one worktree for " + $task + ", got: " + ($wt -join ", "))
        Remove-Item -LiteralPath $wt[0] -Recurse -Force

        Complete-PhaseChecklist -ProjectRoot $projectRoot -TaskId $task -Phase "implementation"
        Write-PipelineHandoff -ProjectRoot $projectRoot -TaskId $task -Source "implementation" -Target "verification" -Cycle $cycle -Count 2 `
            -Extra @{ artifacts = $artifacts } | Out-Null
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CRUCIBLE_SCRIPT -Init -TaskId $task -ProjectRoot $projectRoot -Quiet }
        $text = $run.Output -join "`n"
        Assert-Result -Name "missing worktree stops the handoff" -Condition ($run.ExitCode -eq 2 -and $text -match "task/$task exists but its worktree .* is missing") `
            -FailureMessage ("expected exit 2 naming the missing worktree, got " + $run.ExitCode + ". Output: " + $text)
        Assert-Result -Name "recovery is named" -Condition ($text -match "git worktree add") -FailureMessage ("expected the recreate command. Output: " + $text)
    }

    $results += Run-Test -Name "A handoff that names a cycle other than the one task.md issued is refused" -Body {
        # Item 186: the expected cycle used to be read from the incoming handoff itself, so
        # setting cycle_id and session_cycle_id to the same stale value always passed.
        $cycle = "cycle-e2e-issued"
        $env:CRUCIBLE_CYCLE_ID = $cycle
        $task = "F-701"
        $projectRoot = New-AdopterProject -Root (Join-Path $tempRoot "t5") -TaskId $task -Title "Cycle Check" -Status "Ready" -StatusTarget "Groomer"
        $artifacts = @("src/feature.txt")

        Write-PipelineHandoff -ProjectRoot $projectRoot -TaskId $task -Source "grooming" -Target "implementation" -Cycle $cycle -Count 1 `
            -Extra @{ artifacts = $artifacts; file_affinity = @("src/") } | Out-Null
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CRUCIBLE_SCRIPT -Init -TaskId $task -ProjectRoot $projectRoot -Quiet }
        Assert-Result -Name "grooming -> implementation accepted" -Condition ($run.ExitCode -eq 0) `
            -FailureMessage ("expected exit 0, got " + $run.ExitCode + ". Output: " + ($run.Output -join "`n"))

        Complete-PhaseChecklist -ProjectRoot $projectRoot -TaskId $task -Phase "implementation"
        Write-PipelineHandoff -ProjectRoot $projectRoot -TaskId $task -Source "implementation" -Target "verification" -Cycle "cycle-stale" -Count 2 `
            -Extra @{ artifacts = $artifacts; cycle_id = "cycle-stale" } | Out-Null
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CRUCIBLE_SCRIPT -Init -TaskId $task -ProjectRoot $projectRoot -Quiet }
        $text = $run.Output -join "`n"
        Assert-Result -Name "forged cycle refused" -Condition ($run.ExitCode -eq 2 -and $text -match "session_cycle_id mismatch.*Expected: $cycle, Got: cycle-stale") `
            -FailureMessage ("expected exit 2 naming the issued and the forged cycle, got " + $run.ExitCode + ". Output: " + $text)
    }
}
finally {
    $env:CRUCIBLE_CYCLE_ID = $savedCycleEnv
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
