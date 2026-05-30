# Tests for factory gate orchestration helpers.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$FACTORY_LIB = Join-Path $REPO_ROOT "powershell/factory-lib.ps1"
$Quiet = $true
. $FACTORY_LIB

$results = @()

function Assert-Result {
    param([string]$Name, [bool]$Condition, [string]$FailureMessage)
    if (-not $Condition) {
        throw ("FAILED: " + $Name + " - " + $FailureMessage)
    }
}

function Run-Test {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ("`nTest: " + $Name) -ForegroundColor Cyan
    try {
        & $Body
        Write-Host "PASSED" -ForegroundColor Green
        return $true
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        return $false
    }
}

function Write-TestHandoff {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][hashtable]$Values
    )

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
        Handoff = $null
        LatestHandoff = $null
        RelativeHandoffPath = $null
        CumulativeHandoffCount = 0
        IsBootstrap = $false
        Transition = $null
        NextFactoryCommand = $null
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-factory-gates-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Resolve-FactoryInputHandoff accepts context and populates latest handoff" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "contract") -TaskId "F-001"
        $handoffPath = Join-Path $ctx.HandoffDir "F-001-20260526T120000Z.json"
        Write-TestHandoff -Path $handoffPath -Values @{
            task_id = "F-001"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            handoff_retry_count = 0
            review_strike_count = 0
            rebase_count = 0
            budget_tier = "low"
            reason = "test"
            artifacts = @()
            file_affinity = @()
            prompt_version = "1.0.0"
            session_cycle_id = "cycle-a"
        }

        Resolve-FactoryInputHandoff -Context $ctx

        Assert-Result -Name "latest populated" -Condition ($null -ne $ctx.LatestHandoff) -FailureMessage "LatestHandoff was not populated"
        Assert-Result -Name "latest file" -Condition ($ctx.LatestHandoff.FullName -eq $handoffPath) -FailureMessage "wrong handoff selected"
    }

    $results += Run-Test -Name "Resolve-FactoryInputHandoff auto-bootstraps from backlog spec" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "bootstrap") -TaskId "B-001"
        $activeDir = Join-Path $ctx.BacklogDir "bugs/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        @"
---
target_phase: verification
budget_tier: medium
---
"@ | Set-Content -LiteralPath (Join-Path $activeDir "B-001_bug.md") -Encoding UTF8

        Resolve-FactoryInputHandoff -Context $ctx

        Assert-Result -Name "bootstrap flag" -Condition ($ctx.IsBootstrap -eq $true) -FailureMessage "IsBootstrap was not set"
        Assert-Result -Name "bootstrap file" -Condition ($null -ne $ctx.LatestHandoff -and (Test-Path -LiteralPath $ctx.LatestHandoff.FullName)) -FailureMessage "bootstrap handoff was not created"
        $handoff = Get-Content -LiteralPath $ctx.LatestHandoff.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Result -Name "target from spec" -Condition ($handoff.target_phase -eq "verification") -FailureMessage "target_phase was not read from spec"
    }

    $results += Run-Test -Name "Read-FactoryHandoffContext maps legacy specialist fields" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "legacy") -TaskId "F-002"
        $handoffPath = Join-Path $ctx.HandoffDir "F-002-20260526T120000Z.json"
        Write-TestHandoff -Path $handoffPath -Values @{
            task_id = "F-002"
            source_specialist = "architect"
            target_specialist = "reviewer"
            cumulative_handoff_count = 2
            handoff_retry_count = 0
            review_strike_count = 0
            rebase_count = 0
            budget_tier = "high"
            reason = "legacy"
            artifacts = @()
            file_affinity = @()
            session_cycle_id = "cycle-b"
        }
        $ctx.LatestHandoff = Get-Item $handoffPath

        Read-FactoryHandoffContext -Context $ctx

        Assert-Result -Name "source mapped" -Condition ($ctx.Handoff.source_phase -eq "implementation") -FailureMessage "source_specialist was not mapped"
        Assert-Result -Name "target mapped" -Condition ($ctx.Handoff.target_phase -eq "verification") -FailureMessage "target_specialist was not mapped"
        Assert-Result -Name "ceiling mapped" -Condition ($ctx.Ceiling -eq 24) -FailureMessage "budget ceiling was not derived"
    }

    $results += Run-Test -Name "Invoke-HandoffPreflightValidation restores cycle id" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "cycle") -TaskId "F-003"
        $handoffPath = Join-Path $ctx.HandoffDir "F-003-20260526T120000Z.json"
        Write-TestHandoff -Path $handoffPath -Values @{
            task_id = "F-003"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            handoff_retry_count = 0
            review_strike_count = 0
            rebase_count = 0
            budget_tier = "low"
            reason = "cycle"
            artifacts = @()
            file_affinity = @()
            prompt_version = "1.0.0"
            cycle_id = "knowncycle"
        }
        @'
param([string]$HandoffFile, [string]$SchemaPath)
Write-Output '{"ok":true}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $ctx.FrameworkPowerShell "validate-handoff.ps1") -Encoding UTF8
        $ctx.LatestHandoff = Get-Item $handoffPath
        $ctx.Handoff = Get-Content -LiteralPath $handoffPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $previousCycleId = $env:FACTORY_CYCLE_ID
        try {
            Invoke-HandoffPreflightValidation -Context $ctx
            Assert-Result -Name "cycle restored" -Condition ($env:FACTORY_CYCLE_ID -eq "knowncycle") -FailureMessage "cycle_id was not restored"
        } finally {
            $env:FACTORY_CYCLE_ID = $previousCycleId
        }
    }

    $results += Run-Test -Name "Framework integrity guard flags framework-owned bundle edits only" -Body {
        $repo = Join-Path $tempRoot "framework-integrity"
        $crucible = Join-Path $repo ".crucible"
        New-Item -ItemType Directory -Path (Join-Path $crucible "powershell"), (Join-Path $crucible "session"), (Join-Path $crucible "backlog") -Force | Out-Null
        @'
{
  "adopter_owned_excludes": [
    "config.yaml",
    "backlog/**",
    "session/**",
    "research/**",
    ".gemini/**",
    ".private/**",
    ".agent-workspaces/**"
  ]
}
'@ | Set-Content -LiteralPath (Join-Path $crucible "install-manifest.json") -Encoding UTF8
        "version: 1" | Set-Content -LiteralPath (Join-Path $crucible "config.yaml") -Encoding UTF8
        "framework" | Set-Content -LiteralPath (Join-Path $crucible "powershell/factory.ps1") -Encoding UTF8
        "state" | Set-Content -LiteralPath (Join-Path $crucible "session/state.txt") -Encoding UTF8

        git -C $repo init | Out-Null
        git -C $repo config user.email "test@example.com" | Out-Null
        git -C $repo config user.name "Test User" | Out-Null
        git -C $repo add . | Out-Null
        git -C $repo commit -m "baseline" | Out-Null

        "changed config" | Set-Content -LiteralPath (Join-Path $crucible "config.yaml") -Encoding UTF8
        "changed state" | Set-Content -LiteralPath (Join-Path $crucible "session/state.txt") -Encoding UTF8

        $ctx = New-TestContext -TempRoot $repo -TaskId "F-020"
        $ctx.RepoRoot = $repo
        $ctx.CrucibleRoot = ".crucible"
        $excluded = @(Get-CrucibleFrameworkStatusChanges -Context $ctx)
        Assert-Result -Name "adopter changes excluded" -Condition ($excluded.Count -eq 0) -FailureMessage ("expected no framework changes, got: " + ($excluded -join ", "))

        "changed framework" | Set-Content -LiteralPath (Join-Path $crucible "powershell/factory.ps1") -Encoding UTF8
        $flagged = @(Get-CrucibleFrameworkStatusChanges -Context $ctx)
        Assert-Result -Name "framework change flagged" -Condition (($flagged -join "`n") -match "\.crucible/powershell/factory\.ps1") -FailureMessage ("expected framework file to be flagged, got: " + ($flagged -join ", "))
    }

    $results += Run-Test -Name "Extracted functions enforce required context keys" -Body {
        # Test null context
        try {
            Invoke-FactoryRuntimeValidation -Context $null
            Assert-Result -Name "null context check" -Condition $false -FailureMessage "Did not fail on null context"
        } catch {
            Assert-Result -Name "null context check passed" -Condition ($true) -FailureMessage "Null check failed"
        }

        # Test missing key for Invoke-FactoryRuntimeValidation
        $badCtx = @{ RepoRoot = "foo" }
        try {
            Invoke-FactoryRuntimeValidation -Context $badCtx
            Assert-Result -Name "runtime missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "runtime key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Invoke-FactoryScopeGates
        try {
            Invoke-FactoryScopeGates -Context $badCtx
            Assert-Result -Name "scope missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "scope key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Test-CompletionArtifactGate
        try {
            Test-CompletionArtifactGate -Context $badCtx
            Assert-Result -Name "artifact missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "artifact key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Normalize-FactoryInputState
        try {
            Normalize-FactoryInputState -Context $badCtx
            Assert-Result -Name "normalize missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "normalize key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Invoke-CircuitBreakerGates
        try {
            Invoke-CircuitBreakerGates -Context $badCtx
            Assert-Result -Name "breaker missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "breaker key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Invoke-HumanGate
        try {
            Invoke-HumanGate -Context $badCtx
            Assert-Result -Name "human gate missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "human gate key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Invoke-RepositoryIntegrityGates
        try {
            Invoke-RepositoryIntegrityGates -Context $badCtx
            Assert-Result -Name "integrity gates missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "integrity gates key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Resolve-FactoryTransition
        try {
            Resolve-FactoryTransition -Context $badCtx
            Assert-Result -Name "transition missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "transition key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }
    }

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

    $results += Run-Test -Name "Invoke-CircuitBreakerGates handles non-exiting branches" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "circuit-gates") -TaskId "F-005"
        
        # Set up a degraded situation (strike 2 implementation) which should log and warn but not exit/throw
        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-005"
            source_phase = "verification"
            target_phase = "implementation"
            review_strike_count = 2
            cumulative_handoff_count = 1
            handoff_retry_count = 0
            suspicious_content = ""
            budget_tier = ""
            rebase_count = 0
            reason = "test"
        }
        $ctx.Ceiling = 10
        
        # Test degraded scenario
        Invoke-CircuitBreakerGates -Context $ctx
        
        # Test token budget tier within ceiling
        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-005"
            source_phase = "grooming"
            target_phase = "implementation"
            budget_tier = "low"
            cumulative_handoff_count = 3
            review_strike_count = 0
            handoff_retry_count = 0
            suspicious_content = ""
            rebase_count = 0
            reason = "test"
        }
        $ctx.Ceiling = 6  # Cumulative (3) <= Ceiling (6)
        
        Invoke-CircuitBreakerGates -Context $ctx
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

    $results += Run-Test -Name "Required task checklist failure logs retry event, not circuit breaker" -Body {
        $caseRoot = Join-Path $tempRoot "quality-retry"
        $scriptPath = Join-Path $caseRoot "run-quality-retry.ps1"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")
        @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$sessionDir = Join-Path '$caseRoot' 'session'
`$taskDir = Join-Path `$sessionDir 'F-031/grooming'
New-Item -ItemType Directory -Path `$taskDir -Force | Out-Null
"## Task List`n- [ ] Complete required work" | Set-Content -LiteralPath (Join-Path `$taskDir 'task.md') -Encoding UTF8
`$ctx = @{
    SessionDir = `$sessionDir
    LogFile = Join-Path `$sessionDir 'F-031/pipeline.log.jsonl'
    CircuitBreakerHistoryFile = Join-Path `$sessionDir 'global/circuit_breakers.jsonl'
    Quiet = `$true
    Ceiling = 6
    Handoff = [PSCustomObject]@{
        task_id = 'F-031'
        source_phase = 'grooming'
        target_phase = 'implementation'
        cumulative_handoff_count = 1
        budget_tier = 'low'
    }
}
Write-EventLog -Event 'session_start' -TaskId 'F-031' -Phase 'grooming' -HandoffCount 1 -LogFile `$ctx.LogFile -CircuitBreakerHistoryFile `$ctx.CircuitBreakerHistoryFile
Complete-FactorySourceSession -Context `$ctx
"@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"
        Assert-Result -Name "quality gate exits 2" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit 2, got " + $exitCode + ". Output: " + $output)

        $logFile = Join-Path $caseRoot "session/F-031/pipeline.log.jsonl"
        $logText = Get-Content -LiteralPath $logFile -Raw -Encoding UTF8
        Assert-Result -Name "retry event logged" -Condition ($logText -match '"event":"quality_gate_retry"') -FailureMessage ("missing quality_gate_retry. Log: " + $logText)
        Assert-Result -Name "no circuit breaker event" -Condition ($logText -notmatch '"event":"circuit_breaker"') -FailureMessage ("unexpected circuit_breaker. Log: " + $logText)
        Assert-Result -Name "no breaker history" -Condition (-not (Test-Path -LiteralPath (Join-Path $caseRoot "session/global/circuit_breakers.jsonl"))) -FailureMessage "circuit breaker history should not be written"
    }

    $results += Run-Test -Name "Resolve-FactoryTransition handles valid and invalid transitions" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "routing-gates") -TaskId "F-006"
        
        # Write dummy update_session_state.ps1
        "exit 0" | Set-Content -LiteralPath (Join-Path $ctx.FrameworkPowerShell "update_session_state.ps1") -Encoding UTF8

        # 1. Valid transition: grooming -> implementation (happy path)
        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-006"
            source_phase = "grooming"
            target_phase = "implementation"
        }
        $ctx.NextFactoryCommand = "powershell.exe factory.ps1"
        $ctx.IsBootstrap = $false

        $decision = Resolve-FactoryTransition -Context $ctx
        Assert-Result -Name "happy path ShouldExit" -Condition ($decision.ShouldExit -eq $false) -FailureMessage "ShouldExit was true on valid transition"
        Assert-Result -Name "happy path Transition" -Condition ($decision.Transition -eq "grooming -> implementation") -FailureMessage "Incorrect transition output"
        Assert-Result -Name "happy path NextFactoryCommand" -Condition ($decision.NextFactoryCommand -eq "powershell.exe factory.ps1") -FailureMessage "Incorrect NextFactoryCommand"

        # 2. Invalid transition: implementation -> done
        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-006"
            source_phase = "implementation"
            target_phase = "done"
        }
        $decision = Resolve-FactoryTransition -Context $ctx
        Assert-Result -Name "invalid path ShouldExit" -Condition ($decision.ShouldExit -eq $true) -FailureMessage "ShouldExit was false on invalid transition"
        Assert-Result -Name "invalid path ExitCode" -Condition ($decision.ExitCode -eq 2) -FailureMessage "Incorrect exit code on invalid transition"

        # 3. Done transition: deployment -> done
        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-006"
            source_phase = "deployment"
            target_phase = "done"
        }
        $decision = Resolve-FactoryTransition -Context $ctx
        Assert-Result -Name "done path ShouldExit" -Condition ($decision.ShouldExit -eq $true) -FailureMessage "ShouldExit was false on done transition"
        Assert-Result -Name "done path ExitCode" -Condition ($decision.ExitCode -eq 0) -FailureMessage "Incorrect exit code on done transition"
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
