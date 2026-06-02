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
        Write-Host "ERROR: $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        return $false
    }
}

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
        Assert-Result -Name "target is unconditionally grooming" -Condition ($handoff.target_phase -eq "grooming") -FailureMessage "target_phase was not set to grooming"
        Assert-Result -Name "budget_tier is read from spec" -Condition ($handoff.budget_tier -eq "medium") -FailureMessage "budget_tier was not read from spec"
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

    $results += Run-Test -Name "Read-FactoryHandoffContext maps extended budget ceiling" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "extended-budget") -TaskId "F-002X"
        $handoffPath = Join-Path $ctx.HandoffDir "F-002X-20260526T120000Z.json"
        Write-TestHandoff -Path $handoffPath -Values @{
            task_id = "F-002X"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 3
            handoff_retry_count = 0
            review_strike_count = 0
            rebase_count = 0
            budget_tier = "extended"
            reason = "extended budget"
            artifacts = @()
            file_affinity = @()
            prompt_version = "1.0.0"
            session_cycle_id = "cycle-extended"
        }
        $ctx.LatestHandoff = Get-Item $handoffPath

        Read-FactoryHandoffContext -Context $ctx

        Assert-Result -Name "extended ceiling" -Condition ($ctx.Ceiling -eq 32) -FailureMessage "extended budget ceiling was not 32"
        Assert-Result -Name "no invalid tier" -Condition ([string]::IsNullOrWhiteSpace($ctx.InvalidBudgetTier)) -FailureMessage "extended was marked invalid"
    }

    $results += Run-Test -Name "Invalid budget tier is rejected before budget_exceeded breaker" -Body {
        $caseRoot = Join-Path $tempRoot "invalid-budget"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $scriptPath = Join-Path $caseRoot "run-invalid-budget.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        $repoRoot = $caseRoot.Replace("'", "''")
        $script = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    Handoff = [PSCustomObject]@{
        task_id = 'F-INVALID'
        source_phase = 'grooming'
        target_phase = 'implementation'
        cumulative_handoff_count = 5
        handoff_retry_count = 0
        review_strike_count = 0
        rebase_count = 0
        budget_tier = 'standard'
        reason = 'invalid tier'
    }
    Ceiling = `$null
    InvalidBudgetTier = 'standard'
    LogFile = (Join-Path '$repoRoot' 'pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$repoRoot' 'circuit_breakers.jsonl')
    FrameworkPowerShell = (Join-Path '$repoRoot' 'powershell')
    RepoRoot = '$repoRoot'
    WorkspacesDir = (Join-Path '$repoRoot' 'workspaces')
    SessionDir = (Join-Path '$repoRoot' 'session')
}
Invoke-CircuitBreakerGates -Context `$ctx
"@
        $script | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
        $outputText = $output -join "`n"

        Assert-Result -Name "exits 1" -Condition ($exitCode -eq 1) -FailureMessage "expected exit 1, got $exitCode. Output:`n$outputText"
        Assert-Result -Name "invalid tier message" -Condition ($outputText -match "Invalid budget_tier") -FailureMessage "missing invalid tier message. Output:`n$outputText"
        Assert-Result -Name "no budget breaker" -Condition ($outputText -notmatch "budget_exceeded|Token Budget Exceeded") -FailureMessage "invalid tier was reported as budget breaker. Output:`n$outputText"
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

        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
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

        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
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

        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "D35: artifacts resolve from both worktree and repo root" -Condition ($output -match "PASSED_RESOLVED") -FailureMessage ("expected PASSED_RESOLVED, got: " + $output)
    }

    $results += Run-Test -Name "Invoke-HandoffPreflightValidation D19: warn when file_affinity is overbroad relative to spec" -Body {
        $caseRoot = Join-Path $tempRoot "d19-regression"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        
        # Initialize Git repo so that Assert-CrucibleFrameworkIntegrity does not fail
        Push-Location $caseRoot
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            Set-Content -Path "README.md" -Value "# Temp"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }
        
        # 1. Setup mock backlog dir with a spec that has "Affected Files"
        $backlogDir = Join-Path $caseRoot "backlog"
        $activeDir = Join-Path $backlogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        
        $crucibleActiveDir = Join-Path $caseRoot ".crucible/backlog/features/active"
        New-Item -ItemType Directory -Path $crucibleActiveDir -Force | Out-Null

        $specPath = Join-Path $activeDir "F-020_test.md"
        $specPath2 = Join-Path $crucibleActiveDir "F-020_test.md"
        $specContent = @"
---
item_id: "F-020"
status: "Ready"
---
## Affected Files
- ``docs/METRICS.md``
- ``AGENTS.md``
"@
        $specContent | Set-Content -LiteralPath $specPath -Encoding UTF8
        $specContent | Set-Content -LiteralPath $specPath2 -Encoding UTF8

        # 2. Setup mock validate-handoff.ps1 script
        $frameworkDir = Join-Path $caseRoot "powershell"
        New-Item -ItemType Directory -Path $frameworkDir -Force | Out-Null
        @'
param([string]$HandoffFile, [string]$SchemaPath)
Write-Output '{"ok":true}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $frameworkDir "validate-handoff.ps1") -Encoding UTF8

        # 3. Setup context with overbroad file_affinity
        $handoffDir = Join-Path $caseRoot "handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $handoffPath = Join-Path $handoffDir "F-020-20260526T120000Z.json"
        
        $handoffObj = @{
            task_id = "F-020"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            file_affinity = @("cmd/gobot/", "docs/")
            budget_tier = "low"
            reason = "test"
            prompt_version = "1.0.0"
        }
        $handoffObj | ConvertTo-Json -Compress | Set-Content -LiteralPath $handoffPath -Encoding UTF8

        $ctx = @{
            TaskId = "F-020"
            SessionDir = Join-Path $caseRoot "session"
            Init = $false
            Quiet = $true
            RepoRoot = $caseRoot
            BacklogDir = $backlogDir
            HandoffDir = $handoffDir
            LogFile = Join-Path $caseRoot "pipeline.log.jsonl"
            CircuitBreakerHistoryFile = Join-Path $caseRoot "circuit_breakers.jsonl"
            FrameworkPowerShell = $frameworkDir
            CrucibleRoot = "powershell"
            LatestHandoff = Get-Item $handoffPath
            Handoff = [PSCustomObject]$handoffObj
        }

        # Clear log file first
        Set-Content -LiteralPath $ctx.LogFile -Value "" -Encoding UTF8
        
        # Invoke validation - it should warning but not exit
        $origRepoRoot = $REPO_ROOT
        $REPO_ROOT = $caseRoot
        try {
            Invoke-HandoffPreflightValidation -Context $ctx
        } finally {
            $REPO_ROOT = $origRepoRoot
        }
        
        # Verify that warning degraded event is written in log file
        $logContent = Get-Content -LiteralPath $ctx.LogFile -Raw -Encoding UTF8
        Assert-Result -Name "D19 warning logged" -Condition ($logContent -match "Handoff file_affinity contains paths.*not mentioned in spec") -FailureMessage ("expected degraded warning in log, got: " + $logContent)
    }

    $results += Run-Test -Name "Invoke-HumanGate D22 regression: gate push and reset behavior" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "d22-regression"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        
        # 1. Setup a fake git repository structure
        $originRepo = Join-Path $caseRoot "remote_origin"
        $localRepo = Join-Path $caseRoot "local_repo"
        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null
        
        # Initialize origin repo
        git -C $originRepo init --bare --initial-branch=master 2>$null | Out-Null
        
        # Initialize local repo
        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"
        git -C $localRepo remote add origin $originRepo
        
        # Create a commit on origin
        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        git -C $localRepo push -u origin master 2>$null | Out-Null
        
        # 2. Simulate local merge on task branch
        git -C $localRepo checkout -b task/F-999 2>$null | Out-Null
        "feature work" | Set-Content -LiteralPath (Join-Path $localRepo "feature.md") -Encoding UTF8
        git -C $localRepo add feature.md 2>$null | Out-Null
        git -C $localRepo commit -m "feature commit" 2>$null | Out-Null
        
        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo merge --no-edit task/F-999 2>$null | Out-Null
        
        $localCommits = @(git -C $localRepo log origin/master..master --oneline)
        Assert-Result -Name "D22: local master ahead of origin before gate" -Condition ($localCommits.Count -gt 0) -FailureMessage "expected local master to be ahead of origin"
        
        # 3. Setup context structure
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        
        $scriptPath = Join-Path $caseRoot "run-d22.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        
        # Test Case 1: Accepted outcome -> should push changes to origin
        $scriptContentAccept = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'accepted'
    GateReason = 'work looks beautiful'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-999'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
    }
}

Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_ACCEPT"
} catch {
    Write-Host "FAILED: `$_"
} finally {
    Pop-Location
}
"@
        $scriptContentAccept | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        
        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"
        Assert-Result -Name "D22: human gate accepted exits successfully" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)
        
        $behindCommits = @(git -C $localRepo log origin/master..master --oneline)
        Assert-Result -Name "D22: git push succeeded on accept" -Condition ($behindCommits.Count -eq 0) -FailureMessage "origin/master is still behind master after acceptance"
        
        # Test Case 2: Rejected outcome -> should unwind local merge and restore task branch
        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo reset --hard HEAD~1 2>$null | Out-Null
        git -C $originRepo update-ref refs/heads/master HEAD~1 2>$null | Out-Null
        git -C $localRepo fetch origin master 2>$null | Out-Null
        git -C $localRepo merge --no-edit task/F-999 2>$null | Out-Null
        
        $behindCommits2 = @(git -C $localRepo log origin/master..master --oneline)
        Assert-Result -Name "D22: local master ahead before reject" -Condition ($behindCommits2.Count -gt 0) -FailureMessage "expected master to be ahead again"
        
        git -C $localRepo branch -D task/F-999 2>$null | Out-Null
        
        $scriptContentReject = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'rejected'
    GateReason = 'needs rework'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-999'
        source_phase = 'deployment'
        target_phase = 'implementation'
        cumulative_handoff_count = 1
    }
}

Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_REJECT"
} catch {
    Write-Host "FAILED: `$_"
} finally {
    Pop-Location
}
"@
        $scriptContentReject | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        
        $outputLines2 = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $exitCode2 = $LASTEXITCODE
        $output2 = $outputLines2 -join "`n"
        Assert-Result -Name "D22: human gate rejected exits successfully" -Condition ($exitCode2 -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode2 + ". Output: " + $output2)
        
        $behindCommits3 = @(git -C $localRepo log origin/master..master --oneline)
        Assert-Result -Name "D22: local merge was unwound on reject" -Condition ($behindCommits3.Count -eq 0) -FailureMessage "master is still ahead of origin/master after reject"
        
        git -C $localRepo show-ref --quiet refs/heads/task/F-999
        Assert-Result -Name "D22: task branch was restored on reject" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "task branch task/F-999 was not restored"
    }

    $results += Run-Test -Name "Invoke-HumanGate D37: push behavior with benign git stderr and failures" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "d37-testing"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        
        # 1. Setup origin & local repo
        $originRepo = Join-Path $caseRoot "remote_origin"
        $localRepo = Join-Path $caseRoot "local_repo"
        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null
        
        git -C $originRepo init --bare --initial-branch=master 2>$null | Out-Null
        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"
        git -C $localRepo remote add origin $originRepo
        
        # Initial commit
        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        git -C $localRepo push -u origin master 2>$null | Out-Null

        # Setup context structure
        $sessionDir = Join-Path $localRepo ".crucible/session"
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        $pendingFile = Join-Path $sessionDir "F-100/gate_pending.txt"
        $legacyPendingFile = Join-Path $gateDir "gate_decision_F-100_pending.json"
        
        # Helper to re-create pending files
        function Reset-PendingFiles {
            New-Item -ItemType Directory -Path $gateDir, (Join-Path $sessionDir "F-100") -Force | Out-Null
            "pending" | Set-Content -LiteralPath $pendingFile -Encoding UTF8
            "legacy-pending" | Set-Content -LiteralPath $legacyPendingFile -Encoding UTF8
        }
        
        $scriptPath = Join-Path $caseRoot "run-d37.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")

        # Test Case 1: Accept with no-op push
        Reset-PendingFiles
        $scriptAcceptNoOp = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'accepted'
    GateReason = 'verification of acceptance criteria passed'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-100'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_ACCEPT"
} catch {
    Write-Host "FAILED: `$_"
    exit 1
} finally {
    Pop-Location
}
"@
        $scriptAcceptNoOp | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $output = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $output -join "`n"
        
        Assert-Result -Name "D37: no-op accept push exits 0" -Condition ($exitCode -eq 0) -FailureMessage "expected exit code 0, got $exitCode. Output:`n$outputText"
        Assert-Result -Name "D37: new pending file removed" -Condition (-not (Test-Path $pendingFile)) -FailureMessage "new pending file still exists"
        Assert-Result -Name "D37: legacy pending file removed" -Condition (-not (Test-Path $legacyPendingFile)) -FailureMessage "legacy pending file still exists"
        
        # Test Case 2: Redirect with no-op push
        Reset-PendingFiles
        $scriptRedirectNoOp = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'redirected'
    GateReason = 'redirect to new'
    GateRedirectTarget = 'F-101'
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-100'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_REDIRECT"
} catch {
    Write-Host "FAILED: `$_"
    exit 1
} finally {
    Pop-Location
}
"@
        $scriptRedirectNoOp | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $output = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $output -join "`n"
        
        Assert-Result -Name "D37: no-op redirect push exits 0" -Condition ($exitCode -eq 0) -FailureMessage "expected exit code 0, got $exitCode. Output:`n$outputText"
        Assert-Result -Name "D37: redirected new pending file removed" -Condition (-not (Test-Path $pendingFile)) -FailureMessage "new pending file still exists"
        Assert-Result -Name "D37: redirected legacy pending file removed" -Condition (-not (Test-Path $legacyPendingFile)) -FailureMessage "legacy pending file still exists"

        # Test Case 3: Real successful push (1 commit ahead)
        git -C $localRepo checkout master 2>$null | Out-Null
        "update" | Set-Content -LiteralPath (Join-Path $localRepo "update.txt") -Encoding UTF8
        git -C $localRepo add update.txt 2>$null | Out-Null
        git -C $localRepo commit -m "second commit" 2>$null | Out-Null
        
        Reset-PendingFiles
        $scriptRealPush = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'accepted'
    GateReason = 'commit push verification'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-100'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_REAL_PUSH"
} catch {
    Write-Host "FAILED: `$_"
    exit 1
} finally {
    Pop-Location
}
"@
        $scriptRealPush | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $output = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $output -join "`n"
        
        Assert-Result -Name "D37: real successful push exits 0" -Condition ($exitCode -eq 0) -FailureMessage "expected exit code 0, got $exitCode. Output:`n$outputText"
        Assert-Result -Name "D37: real push pending file removed" -Condition (-not (Test-Path $pendingFile)) -FailureMessage "new pending file still exists"
        
        # Verify remote origin now matches local master
        $behindCommits = @(git -C $localRepo log origin/master..master --oneline)
        Assert-Result -Name "D37: push landed on origin" -Condition ($behindCommits.Count -eq 0) -FailureMessage "origin/master did not catch up"

        # Test Case 4: Failing push (invalid remote / remote ref)
        git -C $localRepo remote set-url origin "https://example.invalid/repo.git"
        Reset-PendingFiles
        $scriptFailedPush = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'accepted'
    GateReason = 'this should fail push'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-100'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_UNEXPECTED"
} catch {
    Write-Host "FAILED: `$_"
    exit 1
} finally {
    Pop-Location
}
"@
        $scriptFailedPush | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $output = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $output -join "`n"
        
        # Check that it exited 1 due to push failure
        Assert-Result -Name "D37: failed push exits 1" -Condition ($exitCode -eq 1) -FailureMessage "expected exit code 1, got $exitCode. Output:`n$outputText"
        Assert-Result -Name "D37: failed push keeps pending files" -Condition (Test-Path $pendingFile) -FailureMessage "pending file was cleaned up on failure"

        # Test Case 5: Reject/Abandon branch unwinding
        # Restore a valid remote origin
        git -C $localRepo remote set-url origin $originRepo
        
        # Simulate local merge on task branch
        git -C $localRepo checkout -b task/F-100 2>$null | Out-Null
        "rwork" | Set-Content -LiteralPath (Join-Path $localRepo "rwork.txt") -Encoding UTF8
        git -C $localRepo add rwork.txt 2>$null | Out-Null
        git -C $localRepo commit -m "rework commit" 2>$null | Out-Null
        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo merge --no-edit task/F-100 2>$null | Out-Null
        
        # Remove task branch first to test restoration
        git -C $localRepo branch -D task/F-100 2>$null | Out-Null
        
        Reset-PendingFiles
        $scriptReject = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'rejected'
    GateReason = 'needs rework'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-100'
        source_phase = 'deployment'
        target_phase = 'implementation'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_REJECT"
} catch {
    Write-Host "FAILED: `$_"
    exit 1
} finally {
    Pop-Location
}
"@
        $scriptReject | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $output = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $output -join "`n"
        
        Assert-Result -Name "D37: reject unwinds merge and exits 0" -Condition ($exitCode -eq 0) -FailureMessage "expected exit code 0 on reject, got $exitCode. Output:`n$outputText"
        # Confirm branch task/F-100 exists
        git -C $localRepo show-ref --quiet refs/heads/task/F-100
        Assert-Result -Name "D37: reject restored task branch" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "task/F-100 branch was not restored"
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

    $results += Run-Test -Name "D26: missing artifact recoverable retry first, then hard circuit breaker" -Body {
        $caseRoot = Join-Path $tempRoot "d26-test"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-042"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        
        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-042"
            source_phase = "implementation"
            target_phase = "verification"
            cumulative_handoff_count = 1
            artifacts = @("docs/NON_EXISTENT_FILE.md")
        }

        # First occurrence: should exit 2 with quality_gate_retry logged (not circuit_breaker)
        $exitCode = 0
        $output = powershell.exe -NoProfile -ExecutionPolicy Bypass -Command @"
            `$Quiet = `$true
            `$backlogDir = '$(Join-Path $caseRoot "backlog")'
            `$FRAMEWORK_POWERSHELL = '$(Split-Path -Parent $FACTORY_LIB)'
            . '$libPath'
            `$ctx = @{
                RepoRoot = '$caseRoot'
                WorkspacesDir = '$(Join-Path $caseRoot "workspaces")'
                LogFile = '$($ctx.LogFile.Replace("'", "''"))'
                CircuitBreakerHistoryFile = '$($ctx.CircuitBreakerHistoryFile.Replace("'", "''"))'
                Handoff = [PSCustomObject]@{
                    task_id = 'F-042'
                    source_phase = 'implementation'
                    target_phase = 'verification'
                    cumulative_handoff_count = 1
                    artifacts = @('docs/NON_EXISTENT_FILE.md')
                }
            }
            Invoke-FactoryRuntimeValidation -Context `$ctx
"@ 2>&1
        $exitCode = $LASTEXITCODE
        Assert-Result -Name "D26 retry exit code is 2" -Condition ($exitCode -eq 2) -FailureMessage "expected exit code 2, got $exitCode"

        # Check log file
        $logContent = Get-Content -LiteralPath $ctx.LogFile -Raw -Encoding UTF8
        Assert-Result -Name "D26 logs quality_gate_retry" -Condition ($logContent -match "quality_gate_retry") -FailureMessage "expected quality_gate_retry logged"
        Assert-Result -Name "D26 does not log circuit_breaker" -Condition ($logContent -notmatch "circuit_breaker") -FailureMessage "should not log circuit_breaker"

        # Write a session_start to simulate retry session
        $startEvent = @{
            event = "session_start"
            task_id = "F-042"
            phase = "implementation"
            handoff_count = 2
        } | ConvertTo-Json -Compress
        [System.IO.File]::AppendAllText($ctx.LogFile, $startEvent + "`n")

        # Second occurrence: should exit 2 with circuit_breaker logged
        $exitCode2 = powershell.exe -NoProfile -ExecutionPolicy Bypass -Command @"
            `$Quiet = `$true
            `$backlogDir = '$(Join-Path $caseRoot "backlog")'
            `$FRAMEWORK_POWERSHELL = '$(Split-Path -Parent $FACTORY_LIB)'
            . '$libPath'
            `$ctx = @{
                RepoRoot = '$caseRoot'
                WorkspacesDir = '$(Join-Path $caseRoot "workspaces")'
                LogFile = '$($ctx.LogFile.Replace("'", "''"))'
                CircuitBreakerHistoryFile = '$($ctx.CircuitBreakerHistoryFile.Replace("'", "''"))'
                Handoff = [PSCustomObject]@{
                    task_id = 'F-042'
                    source_phase = 'implementation'
                    target_phase = 'verification'
                    cumulative_handoff_count = 2
                    artifacts = @('docs/NON_EXISTENT_FILE.md')
                }
            }
            Invoke-FactoryRuntimeValidation -Context `$ctx
"@ 2>&1
        $exitCode2 = $LASTEXITCODE
        Assert-Result -Name "D26 retry block exit code is 2" -Condition ($exitCode2 -eq 2) -FailureMessage "expected exit code 2, got $exitCode2"

        # Check circuit breaker history and log
        $logContent2 = Get-Content -LiteralPath $ctx.LogFile -Raw -Encoding UTF8
        Assert-Result -Name "D26 logs circuit_breaker on retry" -Condition ($logContent2 -match "circuit_breaker") -FailureMessage "expected circuit_breaker logged on retry"
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

    $results += Run-Test -Name "D23: warning degraded event on missing affected files/packages section in spec" -Body {
        $caseRoot = Join-Path $tempRoot "d23-test"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-044"

        # Initialize Git repo so that Assert-CrucibleFrameworkIntegrity does not fail
        Push-Location $caseRoot
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            Set-Content -Path "README.md" -Value "# Temp"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        # Setup spec file with NO affected section
        $backlogDir = Join-Path $caseRoot ".crucible/backlog"
        $activeDir = Join-Path $backlogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        $specPath = Join-Path $activeDir "F-044_test.md"
        $specContent = @"
---
item_id: "F-044"
status: "Ready"
---
## Title
No affected files list here.
"@
        $specContent | Set-Content -LiteralPath $specPath -Encoding UTF8

        # Create mock validate-handoff.ps1
        $frameworkDir = Join-Path $caseRoot "powershell"
        New-Item -ItemType Directory -Path $frameworkDir -Force | Out-Null
        @'
param([string]$HandoffFile, [string]$SchemaPath)
Write-Output '{"ok":true}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $frameworkDir "validate-handoff.ps1") -Encoding UTF8

        # Setup handoff file on disk and set LatestHandoff
        $handoffDir = Join-Path $caseRoot "handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $handoffPath = Join-Path $handoffDir "F-044-20260530T120000Z.json"
        
        $handoffObj = @{
            task_id = "F-044"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            file_affinity = @("cmd/")
            budget_tier = "low"
            reason = "test"
            prompt_version = "1.0.0"
        }
        $handoffObj | ConvertTo-Json -Compress | Set-Content -LiteralPath $handoffPath -Encoding UTF8

        $ctx.TaskId = "F-044"
        $ctx.BacklogDir = $backlogDir
        $ctx.FrameworkPowerShell = $frameworkDir
        $ctx.LatestHandoff = Get-Item $handoffPath
        $ctx.Handoff = [PSCustomObject]$handoffObj

        $origRepoRoot = $REPO_ROOT
        $REPO_ROOT = $caseRoot
        try {
            Invoke-HandoffPreflightValidation -Context $ctx
        } finally {
            $REPO_ROOT = $origRepoRoot
        }

        # Check log file for degraded warning event
        $logContent = Get-Content -LiteralPath $ctx.LogFile -Raw -Encoding UTF8
        Assert-Result -Name "D23 warning logged" -Condition ($logContent -match "Spec file does not declare an affected files/packages section") -FailureMessage "expected spec missing affected warning in log"
    }

    $results += Run-Test -Name "D22 follow-up: unwind merge resets to pre-merge tip, preserving unrelated commit" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "d22-followup"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        
        $originRepo = Join-Path $caseRoot "remote_origin"
        $localRepo = Join-Path $caseRoot "local_repo"
        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null
        
        git -C $originRepo init --bare --initial-branch=master 2>$null | Out-Null
        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"
        git -C $localRepo remote add origin $originRepo
        
        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        git -C $localRepo push -u origin master 2>$null | Out-Null
        
        # Create an unrelated local commit on master that is unpushed
        "unrelated" | Set-Content -LiteralPath (Join-Path $localRepo "unrelated.md") -Encoding UTF8
        git -C $localRepo add unrelated.md 2>$null | Out-Null
        git -C $localRepo commit -m "unrelated commit" 2>$null | Out-Null
        $unrelatedHash = (git -C $localRepo rev-parse HEAD).Trim()

        # Create and commit on a task branch
        git -C $localRepo checkout -b task/F-998 origin/master 2>$null | Out-Null
        "feature work" | Set-Content -LiteralPath (Join-Path $localRepo "feature.md") -Encoding UTF8
        git -C $localRepo add feature.md 2>$null | Out-Null
        git -C $localRepo commit -m "feature commit" 2>$null | Out-Null
        
        # Merge task branch into master (where master has the unrelated commit)
        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo merge --no-edit task/F-998 2>$null | Out-Null
        
        # Set up human gate decision folder
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        # Run unwind human gate rejected
        $scriptPath = Join-Path $caseRoot "run-d22-followup.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        $scriptReject = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'rejected'
    GateReason = 'unwind test'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-998'
        source_phase = 'deployment'
        target_phase = 'implementation'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
} catch {}
finally {
    Pop-Location
}
"@
        $scriptReject | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $null = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1

        # Check that master head has been reset back to $unrelatedHash, NOT origin/master!
        $currentHead = (git -C $localRepo rev-parse HEAD).Trim()
        Assert-Result -Name "D22 follow-up: master reset back to unrelated commit" -Condition ($currentHead -eq $unrelatedHash) -FailureMessage "expected master HEAD to be $unrelatedHash, got $currentHead"
    }

    $results += Run-Test -Name "D31: missing optional counters defaulted without StrictMode crash" -Body {
        $frameworkDir = Join-Path $tempRoot "powershell"
        $sessionDir = Join-Path $tempRoot "session"
        # Setup context
        $ctx = New-TestContext -TempRoot $tempRoot -TaskId "F-310"
        # Create a handoff lacking optional counters
        $handoffPath = Join-Path $ctx.HandoffDir "F-310-20260526T120000Z.json"
        $base = @{
            task_id = "F-310"
            source_phase = "grooming"
            target_phase = "implementation"
            budget_tier = "low"
            reason = "test"
            prompt_version = "1.0.0"
        }
        Write-TestHandoff -Path $handoffPath -Values $base

        $ctx.LatestHandoff = Get-Item $handoffPath

        # Check Read-FactoryHandoffContext completes without StrictMode crash and defaults are applied
        Read-FactoryHandoffContext -Context $ctx

        Assert-Result -Name "D31: review_strike_count defaulted to 0" -Condition ($ctx.Handoff.review_strike_count -eq 0) -FailureMessage "review_strike_count should be 0"
        Assert-Result -Name "D31: rebase_count defaulted to 0" -Condition ($ctx.Handoff.rebase_count -eq 0) -FailureMessage "rebase_count should be 0"
        Assert-Result -Name "D31: handoff_retry_count defaulted to 0" -Condition ($ctx.Handoff.handoff_retry_count -eq 0) -FailureMessage "handoff_retry_count should be 0"
        Assert-Result -Name "D31: cumulative_handoff_count defaulted to 1" -Condition ($ctx.Handoff.cumulative_handoff_count -eq 1) -FailureMessage "cumulative_handoff_count should be 1"

        # Check Invoke-CircuitBreakerGates completes without StrictMode crash
        $ctx.Ceiling = 10
        $ctx.LogFile = Join-Path $tempRoot "logs/pipeline.log.jsonl"
        $ctx.CircuitBreakerHistoryFile = Join-Path $tempRoot "logs/circuit_breakers.jsonl"
        $ctx.FrameworkPowerShell = $frameworkDir
        $ctx.RepoRoot = $tempRoot
        $ctx.WorkspacesDir = Join-Path $tempRoot "workspaces"
        $ctx.SessionDir = $sessionDir

        Invoke-CircuitBreakerGates -Context $ctx
        # If we got here without throwing an exception, D31 check succeeded!
    }

    $results += Run-Test -Name "D30: handoff selection is robust to timestamp inversion" -Body {
        # Create two handoffs for same task.
        # Handoff 1: earlier timestamp but later FSM phase (verification->deployment)
        # Handoff 2: later timestamp but earlier FSM phase (implementation->verification)
        $handoffDirForD30 = Join-Path $tempRoot "d30-handoffs"
        New-Item -ItemType Directory -Path $handoffDirForD30 -Force | Out-Null
        
        $path1 = Join-Path $handoffDirForD30 "F-300-20260526T120000Z.json"
        $val1 = @{
            task_id = "F-300"
            source_phase = "verification"
            target_phase = "deployment"
            cumulative_handoff_count = 3
            budget_tier = "low"
            reason = "test-later-phase"
            prompt_version = "1.0.0"
        }
        $val1 | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path1 -Encoding UTF8

        $path2 = Join-Path $handoffDirForD30 "F-300-20260526T130000Z.json"
        $val2 = @{
            task_id = "F-300"
            source_phase = "implementation"
            target_phase = "verification"
            cumulative_handoff_count = 2
            budget_tier = "low"
            reason = "test-earlier-phase"
            prompt_version = "1.0.0"
        }
        $val2 | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path2 -Encoding UTF8

        $files = @(Get-Item $path1, $path2)
        $sorted = Sort-HandoffFiles -Files $files

        Assert-Result -Name "D30 Winner is path1" -Condition ($sorted[0].FullName -eq $path1) -FailureMessage ("Expected path1 to be sorted first, got " + $sorted[0].Name)
    }

    $results += Run-Test -Name "D38: Verification check failure logs quality_gate_retry on first run" -Body {
        $caseRoot = Join-Path $tempRoot "d38-test-fail-first"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")

        # Set up mock config.yaml under $caseRoot
        $crucibleDir = Join-Path $caseRoot ".crucible"
        New-Item -ItemType Directory -Path $crucibleDir -Force | Out-Null
        $configContent = @"
project_name: "D38 App"
verification:
  full:
    - name: failing-lint
      command: cmd.exe /c exit 1
"@
        [System.IO.File]::WriteAllText((Join-Path $crucibleDir "config.yaml"), $configContent)

        # Set up worktree containing same config.yaml
        $wtPath = Join-Path $caseRoot ".crucible/.agent-workspaces/implementation-F-038"
        $wtCrucibleDir = Join-Path $wtPath ".crucible"
        New-Item -ItemType Directory -Path $wtCrucibleDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $wtCrucibleDir "config.yaml"), $configContent)
        
        Push-Location $wtPath
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            git checkout -b task/F-038 --quiet
            Set-Content -Path "README.md" -Value "# Temp"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        $logFile = Join-Path $caseRoot "session/F-038/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $caseRoot "session/global/circuit_breakers.jsonl"

        $exitCode = powershell.exe -NoProfile -ExecutionPolicy Bypass -Command @"
            Set-Location '$caseRoot'
            `$Quiet = `$true
            `$backlogDir = '$(Join-Path $caseRoot "backlog")'
            `$FRAMEWORK_POWERSHELL = '$(Split-Path -Parent $FACTORY_LIB)'
            . '$libPath'
            `$ctx = @{
                RepoRoot = '$caseRoot'
                WorkspacesDir = '$(Join-Path $caseRoot ".crucible/.agent-workspaces")'
                LogFile = '$($logFile.Replace("'", "''"))'
                CircuitBreakerHistoryFile = '$($cbHistoryFile.Replace("'", "''"))'
                FrameworkPowerShell = `$FRAMEWORK_POWERSHELL
                SessionDir = '$(Join-Path $caseRoot "session")'
                Ceiling = 10
                Handoff = [PSCustomObject]@{
                    task_id = 'F-038'
                    source_phase = 'verification'
                    target_phase = 'deployment'
                    cumulative_handoff_count = 1
                    budget_tier = 'low'
                    reason = 'test'
                }
            }
            Invoke-CircuitBreakerGates -Context `$ctx
"@ 2>&1
        $exitCode = $LASTEXITCODE

        Assert-Result -Name "D38 first failure exit code is 2" -Condition ($exitCode -eq 2) -FailureMessage "expected exit code 2, got $exitCode"

        # Check log file for quality_gate_retry
        $logContent = Get-Content -LiteralPath $logFile -Raw -Encoding UTF8
        Assert-Result -Name "D38 logs quality_gate_retry" -Condition ($logContent -match "quality_gate_retry") -FailureMessage "expected quality_gate_retry logged"
        Assert-Result -Name "D38 contains failed check name" -Condition ($logContent -match "failing-lint") -FailureMessage "expected notes to name failing-lint"
        Assert-Result -Name "D38 does not log circuit_breaker" -Condition ($logContent -notmatch "circuit_breaker") -FailureMessage "should not log circuit_breaker yet"
    }

    $results += Run-Test -Name "D38: Verification check failure trips circuit breaker on retry" -Body {
        $caseRoot = Join-Path $tempRoot "d38-test-fail-second"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")

        # Set up mock config.yaml under $caseRoot
        $crucibleDir = Join-Path $caseRoot ".crucible"
        New-Item -ItemType Directory -Path $crucibleDir -Force | Out-Null
        $configContent = @"
project_name: "D38 App"
verification:
  full:
    - name: failing-lint
      command: cmd.exe /c exit 1
"@
        [System.IO.File]::WriteAllText((Join-Path $crucibleDir "config.yaml"), $configContent)

        # Set up worktree containing same config.yaml
        $wtPath = Join-Path $caseRoot ".crucible/.agent-workspaces/implementation-F-038"
        $wtCrucibleDir = Join-Path $wtPath ".crucible"
        New-Item -ItemType Directory -Path $wtCrucibleDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $wtCrucibleDir "config.yaml"), $configContent)
        
        Push-Location $wtPath
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            git checkout -b task/F-038 --quiet
            Set-Content -Path "README.md" -Value "# Temp"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        $logFile = Join-Path $caseRoot "session/F-038/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $caseRoot "session/global/circuit_breakers.jsonl"

        # Pre-seed log with the quality_gate_retry event from the first attempt
        $retryEvent = @{
            event = "quality_gate_retry"
            task_id = "F-038"
            phase = "verification"
            handoff_count = 1
            notes = "Verification check failed in worktree: failing-lint"
        } | ConvertTo-Json -Compress
        New-Item -ItemType File -Path $logFile -Force | Out-Null
        [System.IO.File]::AppendAllText($logFile, $retryEvent + "`n")

        # Also write a session_start to simulate the second session
        $startEvent = @{
            event = "session_start"
            task_id = "F-038"
            phase = "verification"
            handoff_count = 2
        } | ConvertTo-Json -Compress
        [System.IO.File]::AppendAllText($logFile, $startEvent + "`n")

        $exitCode = powershell.exe -NoProfile -ExecutionPolicy Bypass -Command @"
            Set-Location '$caseRoot'
            `$Quiet = `$true
            `$backlogDir = '$(Join-Path $caseRoot "backlog")'
            `$FRAMEWORK_POWERSHELL = '$(Split-Path -Parent $FACTORY_LIB)'
            . '$libPath'
            `$ctx = @{
                RepoRoot = '$caseRoot'
                WorkspacesDir = '$(Join-Path $caseRoot ".crucible/.agent-workspaces")'
                LogFile = '$($logFile.Replace("'", "''"))'
                CircuitBreakerHistoryFile = '$($cbHistoryFile.Replace("'", "''"))'
                FrameworkPowerShell = `$FRAMEWORK_POWERSHELL
                SessionDir = '$(Join-Path $caseRoot "session")'
                Ceiling = 10
                Handoff = [PSCustomObject]@{
                    task_id = 'F-038'
                    source_phase = 'verification'
                    target_phase = 'deployment'
                    cumulative_handoff_count = 2
                    budget_tier = 'low'
                    reason = 'test'
                }
            }
            Invoke-CircuitBreakerGates -Context `$ctx
"@ 2>&1
        $exitCode = $LASTEXITCODE

        Assert-Result -Name "D38 second failure exit code is 2" -Condition ($exitCode -eq 2) -FailureMessage "expected exit code 2, got $exitCode"

        # Check log file for circuit_breaker
        $logContent = Get-Content -LiteralPath $logFile -Raw -Encoding UTF8
        Assert-Result -Name "D38 logs circuit_breaker" -Condition ($logContent -match "circuit_breaker") -FailureMessage "expected circuit_breaker logged"
    }

    $results += Run-Test -Name "D38: Verification checks green passes" -Body {
        $caseRoot = Join-Path $tempRoot "d38-test-pass"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")

        # Set up mock config.yaml under $caseRoot
        $crucibleDir = Join-Path $caseRoot ".crucible"
        New-Item -ItemType Directory -Path $crucibleDir -Force | Out-Null
        $configContent = @"
project_name: "D38 App"
verification:
  full:
    - name: passing-lint
      command: cmd.exe /c exit 0
"@
        [System.IO.File]::WriteAllText((Join-Path $crucibleDir "config.yaml"), $configContent)

        # Set up worktree containing same config.yaml
        $wtPath = Join-Path $caseRoot ".crucible/.agent-workspaces/implementation-F-038"
        $wtCrucibleDir = Join-Path $wtPath ".crucible"
        New-Item -ItemType Directory -Path $wtCrucibleDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $wtCrucibleDir "config.yaml"), $configContent)
        
        Push-Location $wtPath
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            git checkout -b task/F-038 --quiet
            Set-Content -Path "README.md" -Value "# Temp"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        $logFile = Join-Path $caseRoot "session/F-038/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $caseRoot "session/global/circuit_breakers.jsonl"

        $exitCode = powershell.exe -NoProfile -ExecutionPolicy Bypass -Command @"
            Set-Location '$caseRoot'
            `$Quiet = `$true
            `$backlogDir = '$(Join-Path $caseRoot "backlog")'
            `$FRAMEWORK_POWERSHELL = '$(Split-Path -Parent $FACTORY_LIB)'
            . '$libPath'
            `$ctx = @{
                RepoRoot = '$caseRoot'
                WorkspacesDir = '$(Join-Path $caseRoot ".crucible/.agent-workspaces")'
                LogFile = '$($logFile.Replace("'", "''"))'
                CircuitBreakerHistoryFile = '$($cbHistoryFile.Replace("'", "''"))'
                FrameworkPowerShell = `$FRAMEWORK_POWERSHELL
                SessionDir = '$(Join-Path $caseRoot "session")'
                Ceiling = 10
                Handoff = [PSCustomObject]@{
                    task_id = 'F-038'
                    source_phase = 'verification'
                    target_phase = 'deployment'
                    cumulative_handoff_count = 1
                    budget_tier = 'low'
                    reason = 'test'
                }
            }
            Invoke-CircuitBreakerGates -Context `$ctx
"@ 2>&1
        $exitCode = $LASTEXITCODE

        Assert-Result -Name "D38 success exit code is 0" -Condition ($exitCode -eq 0) -FailureMessage "expected exit code 0, got $exitCode"
    }

    $results += Run-Test -Name "D38: Pattern C no worktree passes without checks" -Body {
        $caseRoot = Join-Path $tempRoot "d38-test-no-wt"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")

        $logFile = Join-Path $caseRoot "session/F-038/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $caseRoot "session/global/circuit_breakers.jsonl"

        $exitCode = powershell.exe -NoProfile -ExecutionPolicy Bypass -Command @"
            Set-Location '$caseRoot'
            `$Quiet = `$true
            `$backlogDir = '$(Join-Path $caseRoot "backlog")'
            `$FRAMEWORK_POWERSHELL = '$(Split-Path -Parent $FACTORY_LIB)'
            . '$libPath'
            `$ctx = @{
                RepoRoot = '$caseRoot'
                WorkspacesDir = '$(Join-Path $caseRoot ".crucible/.agent-workspaces")'
                LogFile = '$($logFile.Replace("'", "''"))'
                CircuitBreakerHistoryFile = '$($cbHistoryFile.Replace("'", "''"))'
                FrameworkPowerShell = `$FRAMEWORK_POWERSHELL
                SessionDir = '$(Join-Path $caseRoot "session")'
                Ceiling = 10
                Handoff = [PSCustomObject]@{
                    task_id = 'F-038'
                    source_phase = 'verification'
                    target_phase = 'deployment'
                    cumulative_handoff_count = 1
                    budget_tier = 'low'
                    reason = 'test'
                }
            }
            Invoke-CircuitBreakerGates -Context `$ctx
"@ 2>&1
        $exitCode = $LASTEXITCODE

        Assert-Result -Name "D38 no-worktree exit code is 0" -Condition ($exitCode -eq 0) -FailureMessage "expected exit code 0, got $exitCode"
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
