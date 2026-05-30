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
