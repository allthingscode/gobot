# Tests for Crucible gate orchestration helpers.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$CRUCIBLE_LIB = Join-Path $REPO_ROOT "powershell/crucible-lib.ps1"
$Quiet = $true
. $CRUCIBLE_LIB
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
    $crucibleDir = Join-Path $TempRoot ".crucible"
    New-Item -ItemType Directory -Path $handoffDir, $backlogDir, $frameworkDir, $crucibleDir -Force | Out-Null

    # Invoke-HandoffPreflightValidation runs the framework-integrity gate, which reads a
    # real bundle directory in a real git tree and blocks when it cannot. This context
    # declared CrucibleRoot = ".crucible" without creating it, and passed only because
    # the gate used to report "clean" for a tree it had never read. Same reason
    # crucible-gates-affinity.tests.ps1 inits a repo in its fixtures.
    if (-not (Test-Path -LiteralPath (Join-Path $TempRoot ".git"))) {
        git -C $TempRoot init --quiet | Out-Null
        git -C $TempRoot config user.name "Test" | Out-Null
        git -C $TempRoot config user.email "test@example.com" | Out-Null
        git -C $TempRoot config core.autocrlf false | Out-Null
        git -C $TempRoot config commit.gpgSign false | Out-Null
        "test fixture" | Set-Content -LiteralPath (Join-Path $crucibleDir "README.md") -Encoding UTF8
        git -C $TempRoot add -A | Out-Null
        git -C $TempRoot commit -m "init" --quiet | Out-Null
    }

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
        NextCrucibleCommand = $null
    }
}
$tempRoot = New-TestFixtureRoot -NameHint "crucible-gates-handoff-test"
try {
    $results += Run-Test -Name "Resolve-CrucibleInputHandoff accepts context and populates latest handoff" -Body {
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

        Resolve-CrucibleInputHandoff -Context $ctx

        Assert-Result -Name "latest populated" -Condition ($null -ne $ctx.LatestHandoff) -FailureMessage "LatestHandoff was not populated"
        Assert-Result -Name "latest file" -Condition ($ctx.LatestHandoff.FullName -eq $handoffPath) -FailureMessage "wrong handoff selected"
    }

    $results += Run-Test -Name "Resolve-CrucibleInputHandoff auto-bootstraps from backlog spec" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "bootstrap") -TaskId "B-001"
        $activeDir = Join-Path $ctx.BacklogDir "bugs/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        @"
---
target_phase: verification
budget_tier: medium
---
"@ | Set-Content -LiteralPath (Join-Path $activeDir "B-001_bug.md") -Encoding UTF8

        Resolve-CrucibleInputHandoff -Context $ctx

        Assert-Result -Name "bootstrap flag" -Condition ($ctx.IsBootstrap -eq $true) -FailureMessage "IsBootstrap was not set"
        Assert-Result -Name "bootstrap file" -Condition ($null -ne $ctx.LatestHandoff -and (Test-Path -LiteralPath $ctx.LatestHandoff.FullName)) -FailureMessage "bootstrap handoff was not created"
        $handoff = Get-Content -LiteralPath $ctx.LatestHandoff.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Result -Name "target is unconditionally grooming" -Condition ($handoff.target_phase -eq "grooming") -FailureMessage "target_phase was not set to grooming"
        Assert-Result -Name "budget_tier is read from spec" -Condition ($handoff.budget_tier -eq "medium") -FailureMessage "budget_tier was not read from spec"
    }

    $results += Run-Test -Name "Resolve-CrucibleInputHandoff auto-bootstraps from archived backlog spec" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "bootstrap-archived") -TaskId "C-381"
        $archivedDir = Join-Path $ctx.BacklogDir "chores/archived/2026/07"
        New-Item -ItemType Directory -Path $archivedDir -Force | Out-Null
        @"
---
target_phase: deployment
budget_tier: high
---
"@ | Set-Content -LiteralPath (Join-Path $archivedDir "C-381_stale_spec.md") -Encoding UTF8

        Resolve-CrucibleInputHandoff -Context $ctx

        Assert-Result -Name "bootstrap flag for archived spec" -Condition ($ctx.IsBootstrap -eq $true) -FailureMessage "IsBootstrap was not set for archived spec"
        Assert-Result -Name "bootstrap file created for archived spec" -Condition ($null -ne $ctx.LatestHandoff -and (Test-Path -LiteralPath $ctx.LatestHandoff.FullName)) -FailureMessage "bootstrap handoff was not created for archived spec"
        $handoff = Get-Content -LiteralPath $ctx.LatestHandoff.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Result -Name "budget_tier read from archived spec" -Condition ($handoff.budget_tier -eq "high") -FailureMessage "budget_tier was not read from archived spec"
    }

    $results += Run-Test -Name "Resolve-CrucibleInputHandoff names the missing spec when there is no handoff and no spec" -Body {
        $caseRoot = Join-Path $tempRoot "no-spec"
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "R-033"
        $scriptPath = Join-Path $caseRoot "run-no-spec.ps1"
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
        $script = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    TaskId = 'R-033'
    HandoffDir = '$($ctx.HandoffDir.Replace("'", "''"))'
    BacklogDir = '$($ctx.BacklogDir.Replace("'", "''"))'
    Quiet = `$true
    IsBootstrap = `$false
    LatestHandoff = `$null
    LogFile = '$($ctx.LogFile.Replace("'", "''"))'
    CircuitBreakerHistoryFile = '$($ctx.CircuitBreakerHistoryFile.Replace("'", "''"))'
}
Resolve-CrucibleInputHandoff -Context `$ctx
"@
        $script | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & $pwshCmd -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
        $outputText = $output -join "`n"

        Assert-Result -Name "exits 1" -Condition ($exitCode -eq 1) -FailureMessage "expected exit 1, got $exitCode. Output:`n$outputText"
        Assert-Result -Name "names the missing spec" -Condition ($outputText -match "no backlog spec found for TaskId: R-033") -FailureMessage "missing spec wording. Output:`n$outputText"
        Assert-Result -Name "names where it looked" -Condition ($outputText -match [regex]::Escape("R-033_*.md") -and $outputText -match [regex]::Escape((Join-Path $ctx.BacklogDir "features/active"))) -FailureMessage "missing search locations. Output:`n$outputText"
        Assert-Result -Name "says -Init bootstraps once the spec exists" -Condition ($outputText -match "rerun crucible\.ps1 -Init -TaskId R-033") -FailureMessage "missing -Init guidance. Output:`n$outputText"
        Assert-Result -Name "writes no handoff" -Condition (@(Get-ChildItem -Path $ctx.HandoffDir -Filter "R-033-*" -ErrorAction SilentlyContinue).Count -eq 0) -FailureMessage "a handoff was written without a spec"
    }

    $results += Run-Test -Name "Resolve-CrucibleInputHandoff resolves latest handoff from archived handoffs folder" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "handoff-archived") -TaskId "C-381"
        $archivedHandoffDir = Join-Path $ctx.HandoffDir "archived"
        New-Item -ItemType Directory -Path $archivedHandoffDir -Force | Out-Null
        $handoffPath = Join-Path $archivedHandoffDir "C-381-20260731T100000Z.json"
        Write-TestHandoff -Path $handoffPath -Values @{
            task_id = "C-381"
            source_phase = "verification"
            target_phase = "deployment"
            cumulative_handoff_count = 3
            budget_tier = "low"
            reason = "deploy init test"
            session_cycle_id = "cycle-c"
        }

        Resolve-CrucibleInputHandoff -Context $ctx

        Assert-Result -Name "archived handoff resolved" -Condition ($null -ne $ctx.LatestHandoff -and $ctx.LatestHandoff.FullName -eq $handoffPath) -FailureMessage "archived handoff was not resolved"
    }

    $results += Run-Test -Name "Read-CrucibleHandoffContext maps legacy specialist fields" -Body {
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

        Read-CrucibleHandoffContext -Context $ctx

        Assert-Result -Name "source mapped" -Condition ($ctx.Handoff.source_phase -eq "implementation") -FailureMessage "source_specialist was not mapped"
        Assert-Result -Name "target mapped" -Condition ($ctx.Handoff.target_phase -eq "verification") -FailureMessage "target_specialist was not mapped"
        Assert-Result -Name "ceiling mapped" -Condition ($ctx.Ceiling -eq 28) -FailureMessage "budget ceiling was not derived"
    }

    $results += Run-Test -Name "Read-CrucibleHandoffContext maps extended budget ceiling" -Body {
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

        Read-CrucibleHandoffContext -Context $ctx

        Assert-Result -Name "extended ceiling" -Condition ($ctx.Ceiling -eq 40) -FailureMessage "extended budget ceiling was not 40"
        Assert-Result -Name "no invalid tier" -Condition ([string]::IsNullOrWhiteSpace($ctx.InvalidBudgetTier)) -FailureMessage "extended was marked invalid"
    }

    $results += Run-Test -Name "Invalid budget tier is rejected before budget_exceeded breaker" -Body {
        $caseRoot = Join-Path $tempRoot "invalid-budget"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $scriptPath = Join-Path $caseRoot "run-invalid-budget.ps1"
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
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
            $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
        $outputText = $output -join "`n"

        Assert-Result -Name "exits 1" -Condition ($exitCode -eq 1) -FailureMessage "expected exit 1, got $exitCode. Output:`n$outputText"
        Assert-Result -Name "invalid tier message" -Condition ($outputText -match "Invalid budget_tier") -FailureMessage "missing invalid tier message. Output:`n$outputText"
        Assert-Result -Name "invalid tier wedge sentinel" -Condition ($outputText -match "\[STOP\] HUMAN INTERVENTION REQUIRED") -FailureMessage "missing wedge sentinel. Output:`n$outputText"
        Assert-Result -Name "invalid tier wedge code" -Condition ($outputText -match [regex]::Escape("(invalid_budget_tier)")) -FailureMessage "missing invalid_budget_tier wedge code. Output:`n$outputText"
        Assert-Result -Name "invalid tier wedge recovery" -Condition ($outputText -match "(?m)^RECOVERY:\s+\S") -FailureMessage "missing recovery line. Output:`n$outputText"
        Assert-Result -Name "no budget breaker" -Condition ($outputText -notmatch "budget_exceeded|Token Budget Exceeded") -FailureMessage "invalid tier was reported as budget breaker. Output:`n$outputText"
    }

    $results += Run-Test -Name "Invalid transition emits wedge output with valid transition guidance" -Body {
        $caseRoot = Join-Path $tempRoot "invalid-transition"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-BADTRANS"
        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-BADTRANS"
            source_phase = "grooming"
            target_phase = "deployment"
            cumulative_handoff_count = 1
            handoff_retry_count = 0
            review_strike_count = 0
            rebase_count = 0
            budget_tier = "low"
            reason = "invalid transition"
        }

        $script:InvalidTransitionResult = $null
        $outputLines = @(& {
            $script:InvalidTransitionResult = Resolve-CrucibleTransition -Context $ctx
        } 6>&1)
        $transitionResult = $script:InvalidTransitionResult
        $script:InvalidTransitionResult = $null
        $outputText = ($outputLines | ForEach-Object { [string]$_ }) -join "`n"

        Assert-Result -Name "invalid transition should exit" -Condition ($transitionResult.ShouldExit -eq $true) -FailureMessage "expected ShouldExit true"
        Assert-Result -Name "invalid transition exit code" -Condition ($transitionResult.ExitCode -eq 2) -FailureMessage ("expected exit 2, got " + $transitionResult.ExitCode)
        Assert-Result -Name "invalid transition wedge sentinel" -Condition ($outputText -match "\[STOP\] HUMAN INTERVENTION REQUIRED") -FailureMessage ("missing wedge sentinel. Output:`n" + $outputText)
        Assert-Result -Name "invalid transition wedge code" -Condition ($outputText -match [regex]::Escape("(invalid_transition)")) -FailureMessage ("missing invalid_transition wedge code. Output:`n" + $outputText)
        Assert-Result -Name "invalid transition why" -Condition ($outputText -match [regex]::Escape("grooming -> deployment")) -FailureMessage ("missing invalid transition detail. Output:`n" + $outputText)
        Assert-Result -Name "invalid transition guidance" -Condition ($outputText -match [regex]::Escape("grooming -> implementation | research | verification | done")) -FailureMessage ("missing valid transition guidance. Output:`n" + $outputText)
        Assert-Result -Name "invalid transition recovery" -Condition ($outputText -match "(?m)^RECOVERY:\s+\S") -FailureMessage ("missing recovery line. Output:`n" + $outputText)
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

        $previousCycleId = $env:CRUCIBLE_CYCLE_ID
        try {
            Invoke-HandoffPreflightValidation -Context $ctx
            Assert-Result -Name "cycle restored" -Condition ($env:CRUCIBLE_CYCLE_ID -eq "knowncycle") -FailureMessage "cycle_id was not restored"
        } finally {
            $env:CRUCIBLE_CYCLE_ID = $previousCycleId
        }
    }

    $results += Run-Test -Name "Invoke-HandoffPreflightValidation emits wedge report on reason_code failure" -Body {
        $caseRoot = Join-Path $tempRoot "preflight-fail"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $scriptPath = Join-Path $caseRoot "run-preflight-fail.ps1"
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
        $script = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$sessionDir = Join-Path '$caseRoot' 'session'
`$handoffDir = Join-Path `$sessionDir 'handoffs'
`$frameworkDir = Join-Path '$caseRoot' 'powershell'
`$crucibleDir = Join-Path '$caseRoot' '.crucible'
New-Item -ItemType Directory -Path `$handoffDir, `$frameworkDir, `$crucibleDir -Force | Out-Null
# The framework-integrity gate inside preflight reads a real bundle in a real git
# tree and blocks when it cannot; it used to report "clean" for a tree it never read.
git -C '$caseRoot' init --quiet | Out-Null
git -C '$caseRoot' config user.name 'Test' | Out-Null
git -C '$caseRoot' config user.email 'test@example.com' | Out-Null
git -C '$caseRoot' config core.autocrlf false | Out-Null
git -C '$caseRoot' config commit.gpgSign false | Out-Null
'fixture' | Set-Content -LiteralPath (Join-Path `$crucibleDir 'README.md') -Encoding UTF8
git -C '$caseRoot' add -A | Out-Null
git -C '$caseRoot' commit -m 'init' --quiet | Out-Null
`$handoffPath = Join-Path `$handoffDir 'F-PRE-20260526T120000Z.json'
@{
    task_id = 'F-PRE'
    source_phase = 'grooming'
    target_phase = 'implementation'
    cumulative_handoff_count = 1
    handoff_retry_count = 0
    review_strike_count = 0
    rebase_count = 0
    budget_tier = 'low'
    reason = 'preflight'
    artifacts = @()
    file_affinity = @()
    prompt_version = '1.0.0'
    generated_by = 'new-handoff.ps1'
    tool_version = '1.0.0'
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath `$handoffPath -Encoding UTF8
@'
param([string]`$HandoffFile, [string]`$SchemaPath)
Write-Output '{"ok":false,"reason_code":"invalid_field","message":"Handoff contains an invalid field."}'
exit 1
'@ | Set-Content -LiteralPath (Join-Path `$frameworkDir 'validate-handoff.ps1') -Encoding UTF8
`$ctx = @{
    RepoRoot = '$caseRoot'
    CrucibleRoot = '.crucible'
    FrameworkPowerShell = `$frameworkDir
    SessionDir = `$sessionDir
    HandoffDir = `$handoffDir
    LogFile = (Join-Path `$sessionDir 'F-PRE/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path `$sessionDir 'global/circuit_breakers.jsonl')
    TaskId = 'F-PRE'
    Init = `$true
    Quiet = `$true
    LatestHandoff = (Get-Item -LiteralPath `$handoffPath)
    Handoff = (Get-Content -LiteralPath `$handoffPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}
Invoke-HandoffPreflightValidation -Context `$ctx
"@
        $script | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
        $outputText = $output -join "`n"

        Assert-Result -Name "preflight wedge exits 2" -Condition ($exitCode -eq 2) -FailureMessage "expected exit 2, got $exitCode. Output:`n$outputText"
        Assert-Result -Name "preflight wedge sentinel" -Condition ($outputText -match "\[STOP\] HUMAN INTERVENTION REQUIRED") -FailureMessage "missing wedge sentinel. Output:`n$outputText"
        Assert-Result -Name "preflight wedge code" -Condition ($outputText -match [regex]::Escape("(invalid_field)")) -FailureMessage "missing invalid_field wedge code. Output:`n$outputText"
        Assert-Result -Name "preflight wedge recovery" -Condition ($outputText -match "(?m)^RECOVERY:\s+\S") -FailureMessage "missing recovery line. Output:`n$outputText"
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

        # Check Read-CrucibleHandoffContext completes without StrictMode crash and defaults are applied
        Read-CrucibleHandoffContext -Context $ctx

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

    $results += Run-Test -Name "Handoff preflight stale check only warns on prior cycle handoffs" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "stale-handoff-suppress") -TaskId "F-905"
        $ctx.Init = $true
        $ctx.Quiet = $false

        # Write first handoff for this cycle
        $handoffPath1 = Join-Path $ctx.HandoffDir "F-905-20260526T120000Z.json"
        Write-TestHandoff -Path $handoffPath1 -Values @{
            task_id = "F-905"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            handoff_retry_count = 0
            review_strike_count = 0
            rebase_count = 0
            budget_tier = "low"
            reason = "test1"
            artifacts = @()
            file_affinity = @()
            prompt_version = "1.0.0"
            session_cycle_id = "cycle-current"
        }
        $ctx.LatestHandoff = Get-Item $handoffPath1
        $ctx.Handoff = Get-Content -LiteralPath $handoffPath1 -Raw -Encoding UTF8 | ConvertFrom-Json

        # Write second handoff for the same cycle
        $handoffPath2 = Join-Path $ctx.HandoffDir "F-905-20260526T130000Z.json"
        Write-TestHandoff -Path $handoffPath2 -Values @{
            task_id = "F-905"
            source_phase = "implementation"
            target_phase = "verification"
            cumulative_handoff_count = 2
            handoff_retry_count = 0
            review_strike_count = 0
            rebase_count = 0
            budget_tier = "low"
            reason = "test2"
            artifacts = @()
            file_affinity = @()
            prompt_version = "1.0.0"
            session_cycle_id = "cycle-current"
        }

        # Mock validate-handoff.ps1
        @'
param([string]$HandoffFile, [string]$SchemaPath)
Write-Output '{"ok":true}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $ctx.FrameworkPowerShell "validate-handoff.ps1") -Encoding UTF8

        # Shadow Write-Quiet to collect warnings
        $script:warnMessages = @()
        function Write-Quiet {
            param($Message, $ForegroundColor)
            $script:warnMessages += $Message
        }

        # Run with current cycle ID matching handoffs - should NOT warn
        $previousCycleId = $env:CRUCIBLE_CYCLE_ID
        $env:CRUCIBLE_CYCLE_ID = "cycle-current"
        
        try {
            $ErrorActionPreference = "Continue"
            Invoke-HandoffPreflightValidation -Context $ctx
        } finally {
            $env:CRUCIBLE_CYCLE_ID = $previousCycleId
        }

        $warnText = $script:warnMessages -join "`n"
        Assert-Result -Name "no warn on current cycle handoffs" -Condition ($warnText -notmatch "Found \d+ previous handoff files.*may be stale") -FailureMessage "warned about current cycle handoffs. Warnings:`n$warnText"

        # Now write a handoff with a different (stale) cycle ID
        $handoffPathStale = Join-Path $ctx.HandoffDir "F-905-20260526T110000Z.json"
        Write-TestHandoff -Path $handoffPathStale -Values @{
            task_id = "F-905"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            handoff_retry_count = 0
            review_strike_count = 0
            rebase_count = 0
            budget_tier = "low"
            reason = "teststale"
            artifacts = @()
            file_affinity = @()
            prompt_version = "1.0.0"
            session_cycle_id = "cycle-old"
        }

        # Reset warning collection
        $script:warnMessages = @()

        # Run again with current cycle ID - should warn about the stale cycle handoff
        $env:CRUCIBLE_CYCLE_ID = "cycle-current"
        try {
            $ErrorActionPreference = "Continue"
            Invoke-HandoffPreflightValidation -Context $ctx
        } finally {
            $env:CRUCIBLE_CYCLE_ID = $previousCycleId
        }

        $warnTextStale = $script:warnMessages -join "`n"
        Assert-Result -Name "warn on old cycle handoffs" -Condition ($warnTextStale -match "Found 1 previous handoff files for F-905 that may be stale") -FailureMessage "did not warn about stale cycle handoff. Warnings:`n$warnTextStale"
    }

} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed Crucible gate test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll Crucible gate tests passed." -ForegroundColor Green
exit 0
