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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-factory-gates-integrity-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
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
        git -C $repo config core.autocrlf false | Out-Null
        git -C $repo config core.safecrlf false | Out-Null
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
