# Tests for factory gate orchestration helpers.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$FACTORY_LIB = Join-Path $REPO_ROOT "powershell/factory-lib.ps1"
$Quiet = $true
. $FACTORY_LIB
$pwshCmd = Get-PwshCommand

$results = @()

function Write-TestHandoff {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][hashtable]$Values
    )

    if (-not $Values.ContainsKey("generated_by")) {
        $Values.generated_by = "new-handoff.ps1"
    }
    if (-not $Values.ContainsKey("tool_version")) {
        $Values.tool_version = "1.0.0"
    }

    $Values | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-TestContext {
    param(
        [Parameter(Mandatory=$true)][string]$TempRoot,
        [string]$TaskId = "F-001"
    )

    $sessionDir = Join-Path $TempRoot "session"
    $handoffDir = Join-Path $sessionDir "handoffs"
    $backlogDir = Join-Path $TempRoot "backlog"
    $frameworkDir = Join-Path $TempRoot "powershell"
    New-Item -ItemType Directory -Path $handoffDir, $backlogDir, $frameworkDir -Force | Out-Null

    return @{
        RepoRoot = $TempRoot
        CrucibleRoot = ".crucible"
        FrameworkPowerShell = $frameworkDir
        SessionDir = $sessionDir
        BacklogDir = $backlogDir
        WorkspacesDir = Join-Path $TempRoot "workspaces"
        HandoffDir = $handoffDir
        PromptLib = Join-Path $TempRoot "prompts"
        LogFile = Join-Path $sessionDir "$TaskId/pipeline.log.jsonl"
        CircuitBreakerHistoryFile = Join-Path $sessionDir "global/circuit_breakers.jsonl"
        TaskId = $TaskId
        Target = "agent"
        Init = $true
        Recover = $false
        Quiet = $true
        AutoAdvance = $false
        GateOutcome = $null
        GateRedirectTarget = $null
        GateReason = $null
        BudgetCeilings = $null
        Ceiling = $null
        BudgetTierKey = ""
        InvalidBudgetTier = ""
        Handoff = $null
        LatestHandoff = $null
        RelativeHandoffPath = $null
        CumulativeHandoffCount = 0
        IsBootstrap = $false
        Transition = $null
        NextFactoryCommand = $null
    }
}
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-factory-gates-completion-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $results += Run-Test -Name "Test-CompletionArtifactGate validates transitions successfully" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "completion-gates") -TaskId "F-004"

        # 1. Grooming to Implementation
        $activeDir = Join-Path $ctx.BacklogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        $specPath = Join-Path $activeDir "F-004_test.md"
        "Spec details" | Set-Content -LiteralPath $specPath -Encoding UTF8

        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-004"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            file_affinity = @()
            commit_hash = ""
        }

        # Test completion gate passes without throwing/exiting when spec exists
        Test-CompletionArtifactGate -Context $ctx

        # 2. Verification to Deployment
        $verifyDir = Join-Path $ctx.SessionDir "F-004/verification"
        New-Item -ItemType Directory -Path $verifyDir -Force | Out-Null
        $reportPath = Join-Path $verifyDir "review_report.md"
        @"
---
review_decision: "APPROVED"
acceptance_criteria_met: true
---
APPROVED. Looks great!
"@ | Set-Content -LiteralPath $reportPath -Encoding UTF8

        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-004"
            source_phase = "verification"
            target_phase = "deployment"
            cumulative_handoff_count = 1
            file_affinity = @()
            commit_hash = ""
        }

        # Test completion gate passes without throwing/exiting when valid report exists
        Test-CompletionArtifactGate -Context $ctx
    }

    $results += Run-Test -Name "Complete-FactorySourceSession separates phase wall time from duration_seconds" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "phase-wall") -TaskId "F-030"
        $taskDir = Join-Path $ctx.SessionDir "F-030/grooming"
        New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
        @"
## Task List
- [x] Complete required work
"@ | Set-Content -LiteralPath (Join-Path $taskDir "task.md") -Encoding UTF8

        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-030"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            budget_tier = "low"
        }
        $ctx.Ceiling = 6
        Write-EventLog -Event "session_start" -TaskId "F-030" -Phase "grooming" -HandoffCount 1 -LogFile $ctx.LogFile -CircuitBreakerHistoryFile $ctx.CircuitBreakerHistoryFile

        Complete-FactorySourceSession -Context $ctx

        $entries = @(Get-Content -LiteralPath $ctx.LogFile -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
        $sessionEnd = @($entries | Where-Object { $_.event -eq "session_end" })[-1]
        Assert-Result -Name "no top-level duration" -Condition (-not $sessionEnd.PSObject.Properties["duration_seconds"]) -FailureMessage ("duration_seconds should not be populated: " + ($sessionEnd | ConvertTo-Json -Compress))
        Assert-Result -Name "phase wall metric" -Condition ($null -ne $sessionEnd.metrics.PSObject.Properties["phase_wall_seconds"]) -FailureMessage ("phase_wall_seconds missing: " + ($sessionEnd | ConvertTo-Json -Compress))
    }

    $results += Run-Test -Name "Test-CompletionArtifactGate D21 regression: YAML parsing and quote relaxation" -Body {
        $caseRoot = Join-Path $tempRoot "d21-regression"
        $scriptPath = Join-Path $caseRoot "run-d21.ps1"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")
        @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$sessionDir = Join-Path '$caseRoot' 'session'
`$verifyDir = Join-Path `$sessionDir 'F-004/verification'
New-Item -ItemType Directory -Path `$verifyDir -Force | Out-Null
`$reportPath = Join-Path `$verifyDir 'review_report.md'

`$ctx = @{
    BacklogDir = Join-Path '$caseRoot' 'backlog'
    SessionDir = `$sessionDir
    LogFile = Join-Path `$sessionDir 'F-004/pipeline.log.jsonl'
    CircuitBreakerHistoryFile = Join-Path `$sessionDir 'global/circuit_breakers.jsonl'
    RepoRoot = '$caseRoot'
    WorkspacesDir = Join-Path '$caseRoot' 'workspaces'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-004'
        source_phase = 'verification'
        target_phase = 'deployment'
        cumulative_handoff_count = 1
        file_affinity = @()
        commit_hash = 'dummy_hash'
    }
}

# Sub-test 1: unquoted APPROVED and true
`$yaml = "---`nreview_decision: APPROVED`nacceptance_criteria_met: true`n---`nAPPROVED. Unquoted values work!"
`$yaml | Set-Content -LiteralPath `$reportPath -Encoding UTF8

Test-CompletionArtifactGate -Context `$ctx
# Verify that no fallback degraded log is written
`$logContent = if (Test-Path `$ctx.LogFile) { Get-Content -LiteralPath `$ctx.LogFile -Raw -Encoding UTF8 } else { "" }
if (`$logContent -match "accepted plain-text APPROVED") {
    Write-Host "FAILED_FALLBACK"
} else {
    Write-Host "PASSED_UNQUOTED"
}

# Sub-test 2: YAML CHANGES_REQUESTED with APPROVED in prose - should block (exit 1)
try {
    `$yaml2 = "---`nreview_decision: CHANGES_REQUESTED`nacceptance_criteria_met: false`n---`nProse has APPROVED somewhere in it."
    `$yaml2 | Set-Content -LiteralPath `$reportPath -Encoding UTF8

    Test-CompletionArtifactGate -Context `$ctx
    Write-Host "FAILED_SHOULD_HAVE_BLOCKED"
} catch {
    Write-Host "PASSED_BLOCKED"
}
"@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "D21: unquoted YAML parses without fallback warning" -Condition ($output -match "PASSED_UNQUOTED") -FailureMessage ("expected PASSED_UNQUOTED, got: " + $output)
        Assert-Result -Name "D21: CHANGES_REQUESTED YAML blocks even if APPROVED in prose" -Condition ($output -match "PASSED_BLOCKED") -FailureMessage ("expected PASSED_BLOCKED, got: " + $output)
    }

    $results += Run-Test -Name "Invoke-FactoryRuntimeValidation D20 regression: artifact resolution inside worktree" -Body {
        $caseRoot = Join-Path $tempRoot "d20-regression"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $workspacesDir = Join-Path $caseRoot "workspaces"
        $wtPath = Join-Path $workspacesDir "implementation-F-009"
        $wtArtifactDir = Join-Path $wtPath "docs"
        New-Item -ItemType Directory -Path $wtArtifactDir -Force | Out-Null

        # Create artifact in worktree but NOT in repo root
        $artFile = Join-Path $wtArtifactDir "METRICS.md"
        "Metric details" | Set-Content -LiteralPath $artFile -Encoding UTF8

        $ctx = @{
            RepoRoot = $caseRoot
            WorkspacesDir = $workspacesDir
            LogFile = Join-Path $caseRoot "pipeline.log.jsonl"
            CircuitBreakerHistoryFile = Join-Path $caseRoot "circuit_breakers.jsonl"
            Handoff = [PSCustomObject]@{
                task_id = "F-009"
                source_phase = "implementation"
                target_phase = "verification"
                cumulative_handoff_count = 1
                file_affinity = @()
                artifacts = @("docs/METRICS.md")
            }
        }

        $scriptPath = Join-Path $caseRoot "run-d20.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    RepoRoot = '$caseRoot'
    WorkspacesDir = '$workspacesDir'
    LogFile = Join-Path '$caseRoot' 'pipeline.log.jsonl'
    CircuitBreakerHistoryFile = Join-Path '$caseRoot' 'circuit_breakers.jsonl'
    Handoff = [PSCustomObject]@{
        task_id = 'F-009'
        source_phase = 'implementation'
        target_phase = 'verification'
        cumulative_handoff_count = 1
        file_affinity = @()
        artifacts = @('docs/METRICS.md')
    }
}

try {
    Invoke-FactoryRuntimeValidation -Context `$ctx
    Write-Host "PASSED_RESOLVED"
} catch {
    Write-Host "FAILED_ERROR: `$(_)"
}
"@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "D20: artifacts resolve relative to implementation worktree path" -Condition ($output -match "PASSED_RESOLVED") -FailureMessage ("expected PASSED_RESOLVED, got: " + $output)
    }

    $results += Run-Test -Name "Invoke-FactoryRuntimeValidation D35 regression: artifact resolution checks both worktree and repo root" -Body {
        $caseRoot = Join-Path $tempRoot "d35-regression"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $workspacesDir = Join-Path $caseRoot "workspaces"
        $wtPath = Join-Path $workspacesDir "implementation-F-009"
        $wtArtifactDir = Join-Path $wtPath "docs"
        New-Item -ItemType Directory -Path $wtArtifactDir -Force | Out-Null

        # Artifact A in worktree
        $artFileA = Join-Path $wtArtifactDir "METRICS.md"
        "Metric details" | Set-Content -LiteralPath $artFileA -Encoding UTF8

        # Artifact B in repo root
        $repoArtifactDir = Join-Path $caseRoot ".crucible/session/F-009/verification"
        New-Item -ItemType Directory -Path $repoArtifactDir -Force | Out-Null
        $artFileB = Join-Path $repoArtifactDir "review_report.md"
        "Review report content" | Set-Content -LiteralPath $artFileB -Encoding UTF8

        $scriptPath = Join-Path $caseRoot "run-d35.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    RepoRoot = '$caseRoot'
    WorkspacesDir = '$workspacesDir'
    LogFile = Join-Path '$caseRoot' 'pipeline.log.jsonl'
    CircuitBreakerHistoryFile = Join-Path '$caseRoot' 'circuit_breakers.jsonl'
    Handoff = [PSCustomObject]@{
        task_id = 'F-009'
        source_phase = 'implementation'
        target_phase = 'verification'
        cumulative_handoff_count = 1
        file_affinity = @()
        artifacts = @('docs/METRICS.md', '.crucible/session/F-009/verification/review_report.md')
    }
}

try {
    Invoke-FactoryRuntimeValidation -Context `$ctx
    Write-Host "PASSED_RESOLVED"
} catch {
    Write-Host "FAILED_ERROR: `$(_)"
}
"@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "D35: artifacts resolve from both worktree and repo root" -Condition ($output -match "PASSED_RESOLVED") -FailureMessage ("expected PASSED_RESOLVED, got: " + $output)
    }

    $results += Run-Test -Name "Complete-FactorySourceSession duration anomaly logic" -Body {
        # Test 1: Excessive duration (5 hours ago) - should NOT generate excessive_duration anomaly
        $caseRoot = Join-Path $tempRoot "excessive-dur"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-040"
        $taskDir = Join-Path $ctx.SessionDir "F-040/grooming"
        New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
        "## Task List`n- [x] Done" | Set-Content -LiteralPath (Join-Path $taskDir "task.md") -Encoding UTF8

        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-040"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            budget_tier = "low"
        }
        $ctx.Ceiling = 6

        # Write session_start with timestamp 5 hours in the past
        $pastTime = [DateTime]::UtcNow.AddHours(-5).ToString("o")
        $startEvent = @{
            event = "session_start"
            timestamp = $pastTime
            task_id = "F-040"
            phase = "grooming"
            handoff_count = 1
        } | ConvertTo-Json -Compress
        $startEvent | Set-Content -LiteralPath $ctx.LogFile -Encoding UTF8

        Complete-FactorySourceSession -Context $ctx

        $entries = @(Get-Content -LiteralPath $ctx.LogFile -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
        $sessionEnd = @($entries | Where-Object { $_.event -eq "session_end" })[-1]
        $anomalyVal1 = if ($sessionEnd.metrics.PSObject.Properties["duration_anomaly"]) { $sessionEnd.metrics.duration_anomaly } else { $null }
        Assert-Result -Name "no excessive_duration anomaly" -Condition ($null -eq $anomalyVal1) -FailureMessage ("expected no duration anomaly for >4h wall time, got: " + $anomalyVal1)

        # Test 2: Negative duration (start in future) - should generate negative_duration anomaly
        $caseRoot2 = Join-Path $tempRoot "negative-dur"
        New-Item -ItemType Directory -Path $caseRoot2 -Force | Out-Null
        $ctx2 = New-TestContext -TempRoot $caseRoot2 -TaskId "F-041"
        $taskDir2 = Join-Path $ctx2.SessionDir "F-041/grooming"
        New-Item -ItemType Directory -Path $taskDir2 -Force | Out-Null
        "## Task List`n- [x] Done" | Set-Content -LiteralPath (Join-Path $taskDir2 "task.md") -Encoding UTF8

        $ctx2.Handoff = [PSCustomObject]@{
            task_id = "F-041"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            budget_tier = "low"
        }
        $ctx2.Ceiling = 6

        # Write session_start with timestamp 1 hour in the future
        $futureTime = [DateTime]::UtcNow.AddHours(1).ToString("o")
        $startEvent2 = @{
            event = "session_start"
            timestamp = $futureTime
            task_id = "F-041"
            phase = "grooming"
            handoff_count = 1
        } | ConvertTo-Json -Compress
        $startEvent2 | Set-Content -LiteralPath $ctx2.LogFile -Encoding UTF8

        Complete-FactorySourceSession -Context $ctx2

        $entries2 = @(Get-Content -LiteralPath $ctx2.LogFile -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
        $sessionEnd2 = @($entries2 | Where-Object { $_.event -eq "session_end" })[-1]
        $anomalyVal2 = if ($sessionEnd2.metrics.PSObject.Properties["duration_anomaly"]) { $sessionEnd2.metrics.duration_anomaly } else { $null }
        Assert-Result -Name "negative_duration anomaly detected" -Condition ($anomalyVal2 -eq "negative_duration") -FailureMessage ("expected negative_duration anomaly, got: " + $anomalyVal2)
    }

    $results += Run-Test -Name "D25: absolute worktree path normalized to repo-root-relative" -Body {
        $caseRoot = Join-Path $tempRoot "d25-test"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-043"

        $workspacesDir = Join-Path $caseRoot "workspaces"
        $wtPath = Join-Path $workspacesDir "implementation-F-043"
        $wtArtifactDir = Join-Path $wtPath "docs"
        New-Item -ItemType Directory -Path $wtArtifactDir -Force | Out-Null
        $artFile = Join-Path $wtArtifactDir "METRICS.md"
        "Metric details" | Set-Content -LiteralPath $artFile -Encoding UTF8

        # Create dummy handoff file containing absolute worktree path
        $handoffDir = Join-Path $caseRoot "handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $handoffPath = Join-Path $handoffDir "F-043-20260530T120000Z.json"

        $handoffObj = @{
            task_id = "F-043"
            source_phase = "implementation"
            target_phase = "verification"
            cumulative_handoff_count = 1
            reason = "test normalization"
            artifacts = @($artFile.Replace("\", "/"))
        }
        $handoffObj | ConvertTo-Json | Set-Content -LiteralPath $handoffPath -Encoding UTF8

        $ctx.LatestHandoff = Get-Item $handoffPath
        $ctx.Handoff = [PSCustomObject]$handoffObj
        $ctx.WorkspacesDir = $workspacesDir
        $ctx.RepoRoot = $caseRoot

        # Run normalization
        Normalize-FactoryInputState -Context $ctx

        # Verify handoff file on disk is normalized to relative
        $savedHandoff = Get-Content $handoffPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $savedArtifact = $savedHandoff.artifacts[0]
        Assert-Result -Name "D25 normalized to relative" -Condition ($savedArtifact -eq "docs/METRICS.md") -FailureMessage "expected docs/METRICS.md, got $savedArtifact"
    }

    $results += Run-Test -Name "Checklist gate STOP does not emit degraded event and is actionable" -Body {
        $caseRoot = Join-Path $tempRoot "checklist-actionable-test"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $scriptPath = Join-Path $caseRoot "run-checklist-test.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")

        $handoffDir = Join-Path $caseRoot "session/handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $logFile = Join-Path $caseRoot "session/F-099/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $caseRoot "session/global/circuit_breakers.jsonl"

        @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    RepoRoot = '$caseRoot'
    SessionDir = Join-Path '$caseRoot' 'session'
    LogFile = '$logFile'
    CircuitBreakerHistoryFile = '$cbHistoryFile'
    TaskId = 'F-099'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-099'
        source_phase = 'grooming'
        target_phase = 'implementation'
        cumulative_handoff_count = 1
        budget_tier = 'low'
    }
    Ceiling = 6
}
`$taskDir = Join-Path `$ctx.SessionDir "F-099/grooming"
New-Item -ItemType Directory -Path `$taskDir -Force | Out-Null
'## Task List
- [ ] Required unchecked item 1
' | Set-Content -LiteralPath (Join-Path `$taskDir "task.md") -Encoding UTF8

Write-EventLog -Event "session_start" -TaskId "F-099" -Phase "grooming" -HandoffCount 1 -LogFile `$ctx.LogFile -CircuitBreakerHistoryFile `$ctx.CircuitBreakerHistoryFile

Complete-FactorySourceSession -Context `$ctx
"@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $output = $outputLines -join "`n"
        $exitCode = $LASTEXITCODE

        Assert-Result -Name "checklist gate exited with 2" -Condition ($exitCode -eq 2) -FailureMessage "expected exit code 2, got $exitCode. Output: $output"
        Assert-Result -Name "checklist STOP message is actionable" -Condition ($output -match "Tick the required ## Task List checkboxes") -FailureMessage "expected actionable message, got: $output"

        # Check log file
        $logExists = Test-Path $logFile
        Assert-Result -Name "log file exists" -Condition $logExists -FailureMessage "log file was not created"
        if ($logExists) {
            $entries = @(Get-Content -LiteralPath $logFile -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
            $degradedCount = @($entries | Where-Object { $_.event -eq "degraded" }).Count
            $retryCount = @($entries | Where-Object { $_.event -eq "quality_gate_retry" }).Count
            Assert-Result -Name "checklist retry event logged" -Condition ($retryCount -eq 1) -FailureMessage "expected 1 retry event, got $retryCount"
            Assert-Result -Name "no degraded event for pure checklist ordering slip" -Condition ($degradedCount -eq 0) -FailureMessage "expected 0 degraded events, got $degradedCount"
        }
    }

    $results += Run-Test -Name "Workspace cleanliness gate: start-phase probe and deploy-phase block with classification" -Body {
        $caseRoot = Join-Path $tempRoot "cleanliness-integration-test"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        # Setup mock backlog directory structure under .crucible/
        $backlogDir = Join-Path $caseRoot ".crucible/backlog"
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/active") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/archived") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "bugs/active") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "bugs/archived") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "chores/active") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "chores/archived") -Force | Out-Null

        # Create a spec file for F-100
        $specPath = Join-Path $backlogDir "features/active/F-100_test.md"
        @"
---
item_id: "F-100"
type: "Feature"
status: "Ready"
priority: "P2"
target_phase: "implementation"
created_at: "2026-06-18"
---
# F-100 Test
"@ | Set-Content -LiteralPath $specPath -Encoding UTF8

        # Create BACKLOG.md
        $backlogFile = Join-Path $backlogDir "BACKLOG.md"
        @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | F-100 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [F-100](features/active/F-100_test.md) | P2 | Ready | Test | Architect |
"@ | Set-Content -LiteralPath $backlogFile -Encoding UTF8

        # Setup mock dev-logs directory
        $devLogsDir = Join-Path $caseRoot "dev-logs"
        New-Item -ItemType Directory -Path $devLogsDir -Force | Out-Null
        "## F-100`nSome valid dev log entry without secrets" | Set-Content -Path (Join-Path $devLogsDir "UNPUBLISHED_LOGS.md") -Encoding UTF8

        # Initialize a real git repo
        $originalLocation = (Get-Location).Path
        try {
            Set-Location $caseRoot
            & git init -q
            & git config user.name "Crucible Test"
            & git config user.email "test@crucible.local"
            "initial" | Set-Content -Path "dummy.txt" -Encoding UTF8
            & git add dummy.txt
            & git commit -m "initial commit" -q
        } finally {
            Set-Location $originalLocation
        }

        # Create untracked files
        # empty.tmp: zero-byte scratch file
        $null | Set-Content -Path (Join-Path $caseRoot "empty.tmp")
        # real.go: real source file with content
        "package main" | Set-Content -Path (Join-Path $caseRoot "real.go") -Encoding UTF8

        $scriptPath = Join-Path $caseRoot "run-cleanliness-test.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        $logFile = Join-Path $caseRoot "session/F-100/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $caseRoot "session/global/circuit_breakers.jsonl"

        # Part 1: Start-phase probe (grooming, Init = true)
        @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    RepoRoot = '$caseRoot'
    SessionDir = Join-Path '$caseRoot' 'session'
    LogFile = '$logFile'
    CircuitBreakerHistoryFile = '$cbHistoryFile'
    TaskId = 'F-100'
    Quiet = `$true
    Init = `$true
    IsBootstrap = `$true
    FrameworkPowerShell = '$($REPO_ROOT.Replace("'", "''"))/powershell'
    Handoff = [PSCustomObject]@{
        task_id = 'F-100'
        source_phase = 'deployment'
        target_phase = 'grooming'
        cumulative_handoff_count = 1
        budget_tier = 'low'
    }
}

Push-Location '$caseRoot'
try {
    Invoke-RepositoryIntegrityGates -Context `$ctx
    Write-Host "PROBE_SUCCESS"
} finally {
    Pop-Location
}
"@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $output = $outputLines -join "`n"
        $exitCode = $LASTEXITCODE

        Assert-Result -Name "probe exits with 0" -Condition ($exitCode -eq 0 -and $output -match "PROBE_SUCCESS") -FailureMessage "expected probe success, got code $exitCode. Output: $output"
        Assert-Result -Name "probe outputs advisory" -Condition ($output -match "Pre-existing untracked files detected") -FailureMessage "expected advisory warning, got: $output"
        Assert-Result -Name "probe classifies empty.tmp" -Condition ($output -match "empty.tmp \[safe-to-remove") -FailureMessage "expected classification for empty.tmp, got: $output"
        Assert-Result -Name "probe classifies real.go" -Condition ($output -match "real.go \[SURFACE, do not delete\]") -FailureMessage "expected classification for real.go, got: $output"

        # Check log file for workspace_baseline event
        $logExists = Test-Path $logFile
        Assert-Result -Name "log file exists after probe" -Condition $logExists -FailureMessage "log file was not created by probe"
        if ($logExists) {
            $entries = @(Get-Content -LiteralPath $logFile -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
            $baselineEvent = @($entries | Where-Object { $_.event -eq "workspace_baseline" })[-1]
            Assert-Result -Name "workspace_baseline event logged" -Condition ($null -ne $baselineEvent) -FailureMessage "expected workspace_baseline event"
            Assert-Result -Name "baseline event contains pre-existing stray files" -Condition ($baselineEvent.notes -match "empty.tmp" -and $baselineEvent.notes -match "real.go") -FailureMessage ("expected stray files in notes, got: " + $baselineEvent.notes)
        }

        # Part 2: Deploy-phase cleanliness gate (deployment, target done, Init = false)
        # Re-create script to run deploy cleanliness gate
        @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    RepoRoot = '$caseRoot'
    SessionDir = Join-Path '$caseRoot' 'session'
    LogFile = '$logFile'
    CircuitBreakerHistoryFile = '$cbHistoryFile'
    TaskId = 'F-100'
    Quiet = `$true
    Init = `$false
    IsBootstrap = `$false
    FrameworkPowerShell = '$($REPO_ROOT.Replace("'", "''"))/powershell'
    Handoff = [PSCustomObject]@{
        task_id = 'F-100'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
        budget_tier = 'low'
    }
}

Push-Location '$caseRoot'
try {
    Invoke-RepositoryIntegrityGates -Context `$ctx
    Write-Host "DEPLOY_SUCCESS_SHOULD_HAVE_BLOCKED"
} finally {
    Pop-Location
}
"@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outputLines2 = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $output2 = $outputLines2 -join "`n"
        $exitCode2 = $LASTEXITCODE

        Assert-Result -Name "deploy gate blocks with 2" -Condition ($exitCode2 -eq 2) -FailureMessage "expected exit code 2, got $exitCode2. Output: $output2"
        Assert-Result -Name "deploy gate output contains STOP message" -Condition ($output2 -match "Workspace is not clean") -FailureMessage "expected stop message, got: $output2"
        Assert-Result -Name "deploy gate output contains remedy" -Condition ($output2 -match "STASH or SURFACE untracked non-private files") -FailureMessage "expected remedy instructions, got: $output2"
        Assert-Result -Name "deploy gate classifies empty.tmp" -Condition ($output2 -match "empty.tmp \[safe-to-remove") -FailureMessage "expected classification for empty.tmp, got: $output2"
        Assert-Result -Name "deploy gate classifies real.go" -Condition ($output2 -match "real.go \[SURFACE, do not delete\]") -FailureMessage "expected classification for real.go, got: $output2"
    }

} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed factory gate test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll factory gate tests passed." -ForegroundColor Green
exit 0
