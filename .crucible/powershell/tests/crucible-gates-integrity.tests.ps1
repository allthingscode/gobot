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
        NextCrucibleCommand = $null
    }
}
$tempRoot = New-TestFixtureRoot -NameHint "crucible-gates-integrity-test"
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
        "framework" | Set-Content -LiteralPath (Join-Path $crucible "powershell/crucible.ps1") -Encoding UTF8
        "state" | Set-Content -LiteralPath (Join-Path $crucible "session/state.txt") -Encoding UTF8

        git -C $repo init | Out-Null
        git -C $repo config user.email "test@example.com" | Out-Null
        git -C $repo config user.name "Test User" | Out-Null
        git -C $repo config core.autocrlf false | Out-Null
        git -C $repo config core.safecrlf false | Out-Null
        git -C $repo add . | Out-Null
        git -C $repo commit -m "baseline" | Out-Null
        $baseSha = (git -C $repo rev-parse HEAD).Trim()

        "changed config" | Set-Content -LiteralPath (Join-Path $crucible "config.yaml") -Encoding UTF8
        "changed state" | Set-Content -LiteralPath (Join-Path $crucible "session/state.txt") -Encoding UTF8

        $ctx = New-TestContext -TempRoot $repo -TaskId "F-020"
        $ctx.RepoRoot = $repo
        $ctx.CrucibleRoot = ".crucible"
        $ctx.Handoff = [pscustomobject]@{ task_id = "F-020"; base_commit = $baseSha }
        $excluded = @(Get-CrucibleFrameworkStatusChanges -Context $ctx)
        Assert-Result -Name "adopter changes excluded" -Condition ($excluded.Count -eq 0) -FailureMessage ("expected no framework changes, got: " + ($excluded -join ", "))

        "changed framework" | Set-Content -LiteralPath (Join-Path $crucible "powershell/crucible.ps1") -Encoding UTF8
        $flagged = @(Get-CrucibleFrameworkStatusChanges -Context $ctx)
        Assert-Result -Name "framework change flagged" -Condition (($flagged -join "`n") -match "\.crucible/powershell/crucible.ps1") -FailureMessage ("expected framework file to be flagged, got: " + ($flagged -join ", "))
    }

    function New-IntegrityRepo {
        param([Parameter(Mandatory=$true)][string]$Path)

        $crucible = Join-Path $Path ".crucible"
        New-Item -ItemType Directory -Path (Join-Path $crucible "powershell"), (Join-Path $crucible "backlog") -Force | Out-Null
        "framework" | Set-Content -LiteralPath (Join-Path $crucible "powershell/crucible.ps1") -Encoding UTF8
        "item" | Set-Content -LiteralPath (Join-Path $crucible "backlog/F-001.md") -Encoding UTF8
        git -C $Path init | Out-Null
        git -C $Path config user.email "test@example.com" | Out-Null
        git -C $Path config user.name "Test User" | Out-Null
        git -C $Path config core.autocrlf false | Out-Null
        git -C $Path config core.safecrlf false | Out-Null
        git -C $Path add . | Out-Null
        git -C $Path commit -m "baseline" | Out-Null
        return (git -C $Path rev-parse HEAD).Trim()
    }

    $results += Run-Test -Name "A framework edit committed during the task is flagged" -Body {
        # The evasion this leg closes: edit a vendored framework file, commit it, and the
        # working tree is clean again. The old gate read only `git status`, so it passed -
        # and its own remediation text told the specialist to commit.
        $repo = Join-Path $tempRoot "integrity-committed"
        $baseSha = New-IntegrityRepo -Path $repo

        "tampered" | Set-Content -LiteralPath (Join-Path $repo ".crucible/powershell/crucible.ps1") -Encoding UTF8
        "groomed" | Set-Content -LiteralPath (Join-Path $repo ".crucible/backlog/F-001.md") -Encoding UTF8
        git -C $repo add . | Out-Null
        git -C $repo commit -m "specialist edits a vendored framework file" | Out-Null

        $worktree = @(git -C $repo status --porcelain)
        Assert-Result -Name "working tree is clean" -Condition ($worktree.Count -eq 0) -FailureMessage ("fixture is not clean, so this would pass for the wrong reason: " + ($worktree -join ", "))

        $ctx = New-TestContext -TempRoot $repo -TaskId "F-030"
        $ctx.RepoRoot = $repo
        $ctx.CrucibleRoot = ".crucible"
        $ctx.Handoff = [pscustomobject]@{ task_id = "F-030"; base_commit = $baseSha }

        $flagged = @(Get-CrucibleFrameworkStatusChanges -Context $ctx)
        $joined = ($flagged -join "`n")
        Assert-Result -Name "committed framework edit flagged" -Condition ($joined -match "committed \.crucible/powershell/crucible.ps1") -FailureMessage ("expected the committed framework edit to be flagged, got: " + $joined)
        Assert-Result -Name "committed adopter edit not flagged" -Condition ($joined -notmatch "backlog/F-001\.md") -FailureMessage ("adopter-owned backlog edit must stay excluded on the committed leg too, got: " + $joined)
    }

    $results += Run-Test -Name "The task branch merge-base is the baseline when the handoff has none" -Body {
        $repo = Join-Path $tempRoot "integrity-mergebase"
        $null = New-IntegrityRepo -Path $repo
        git -C $repo branch -m master | Out-Null
        git -C $repo checkout -b "task/F-031" | Out-Null

        "tampered on the task branch" | Set-Content -LiteralPath (Join-Path $repo ".crucible/powershell/crucible.ps1") -Encoding UTF8
        git -C $repo add . | Out-Null
        git -C $repo commit -m "framework edit on the task branch" | Out-Null

        $ctx = New-TestContext -TempRoot $repo -TaskId "F-031"
        $ctx.RepoRoot = $repo
        $ctx.CrucibleRoot = ".crucible"
        # No base_commit, so resolution has to fall through to the task branch merge-base.
        $ctx.Handoff = [pscustomobject]@{ task_id = "F-031" }

        $flagged = @(Get-CrucibleFrameworkStatusChanges -Context $ctx)
        Assert-Result -Name "merge-base baseline flags the edit" -Condition (($flagged -join "`n") -match "committed \.crucible/powershell/crucible.ps1") -FailureMessage ("expected the task-branch edit to be flagged, got: " + ($flagged -join ", "))
    }

    $results += Run-Test -Name "An unresolvable task baseline is counted as unverifiable, not passed" -Body {
        # base_commit is optional and nullable in handoff.schema.json, so a handoff
        # without one on a task with no task/<id> branch is a legitimate shape - and
        # this gate runs on every Crucible invocation, including the first bootstrap.
        # Failing here would block valid pipelines. The committed leg is skipped and
        # reported on the degraded/unverifiable channel so it is counted, not silent.
        $repo = Join-Path $tempRoot "integrity-nobase"
        $null = New-IntegrityRepo -Path $repo

        "tampered" | Set-Content -LiteralPath (Join-Path $repo ".crucible/powershell/crucible.ps1") -Encoding UTF8
        git -C $repo add . | Out-Null
        git -C $repo commit -m "framework edit with no baseline to compare against" | Out-Null

        $ctx = New-TestContext -TempRoot $repo -TaskId "F-032"
        $ctx.RepoRoot = $repo
        $ctx.CrucibleRoot = ".crucible"
        $ctx.Handoff = $null

        $changes = @(Get-CrucibleFrameworkStatusChanges -Context $ctx)
        Assert-Result -Name "no baseline does not block" -Condition ($changes.Count -eq 0) -FailureMessage ("expected the working-tree leg to report nothing, got: " + ($changes -join ", "))
        Assert-Result -Name "missing baseline is recorded on the context" -Condition ($ctx.ContainsKey("FrameworkIntegrityBaseline") -and $null -eq $ctx["FrameworkIntegrityBaseline"]) -FailureMessage "expected FrameworkIntegrityBaseline to be recorded as null so the caller can report the unrun leg"

        Assert-CrucibleFrameworkIntegrity -Context $ctx

        $logFile = $ctx.LogFile
        $logged = if (Test-Path -LiteralPath $logFile) { Get-Content -LiteralPath $logFile -Raw } else { "" }
        Assert-Result -Name "unverifiable gate is logged with a kind" -Condition ($logged -match "framework_integrity_no_baseline" -and $logged -match '"outcome":"unverifiable"') -FailureMessage ("expected a degraded/unverifiable event naming the kind, got: " + $logged)
    }

    $results += Run-Test -Name "A tree the integrity check cannot read is reported, not passed" -Body {
        # Each case below used to return an empty array, which is the same value the
        # function returns for a genuinely clean tree. The circuit breaker therefore
        # reported a passing integrity check on a tree it had never looked at.
        $unreadable = Join-Path $tempRoot "integrity-unreadable"
        New-Item -ItemType Directory -Path (Join-Path $unreadable ".crucible/powershell") -Force | Out-Null
        "framework" | Set-Content -LiteralPath (Join-Path $unreadable ".crucible/powershell/crucible.ps1") -Encoding UTF8

        $cases = @(
            @{ Name = "blank RepoRoot"; Ctx = @{ RepoRoot = ""; CrucibleRoot = ".crucible" }; Expect = "Context.RepoRoot is empty" },
            @{ Name = "blank CrucibleRoot"; Ctx = @{ RepoRoot = $unreadable; CrucibleRoot = "" }; Expect = "Context.CrucibleRoot is empty" },
            @{ Name = "missing bundle"; Ctx = @{ RepoRoot = $unreadable; CrucibleRoot = ".no-such-bundle" }; Expect = "no Crucible bundle at" },
            # Not a git repository, so git status exits non-zero. Before the fix this
            # surfaced as a raw "fatal: not a git repository" NativeCommandError under
            # the $ErrorActionPreference = "Stop" that crucible.ps1 sets, so asserting on
            # the gate's own wording is what separates a verdict from a crash.
            @{ Name = "git status fails"; Ctx = @{ RepoRoot = $unreadable; CrucibleRoot = ".crucible" }; Expect = "'git status' exited" }
        )

        foreach ($case in $cases) {
            $thrown = ""
            try {
                $null = @(Get-CrucibleFrameworkStatusChanges -Context $case.Ctx)
            } catch {
                $thrown = $_.Exception.Message
            }
            Assert-Result -Name ($case.Name + " throws") -Condition ($thrown -ne "") -FailureMessage ("expected " + $case.Name + " to throw, but it returned without error")
            Assert-Result -Name ($case.Name + " names the reason") -Condition ($thrown -match [regex]::Escape($case.Expect)) -FailureMessage ("expected message matching '" + $case.Expect + "', got: " + $thrown)
        }
    }

    $results += Run-Test -Name "The circuit breaker blocks when the integrity check cannot run" -Body {
        $unreadable = Join-Path $tempRoot "integrity-breaker"
        New-Item -ItemType Directory -Path (Join-Path $unreadable ".crucible/powershell") -Force | Out-Null
        "framework" | Set-Content -LiteralPath (Join-Path $unreadable ".crucible/powershell/crucible.ps1") -Encoding UTF8

        # Run in a child process because the gate blocks with exit 2, and match
        # crucible.ps1:112 so the preference under test is the production one.
        $driver = Join-Path $tempRoot "breaker-driver.ps1"
        $driverText = @"
`$Quiet = `$true
. (Join-Path '$REPO_ROOT' 'powershell/crucible-lib.ps1')
`$ErrorActionPreference = 'Stop'
Assert-CrucibleFrameworkIntegrity -Context @{
    RepoRoot = '$unreadable'
    CrucibleRoot = '.crucible'
    TaskId = 'F-021'
    LogFile = (Join-Path '$unreadable' 'session/F-021/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$unreadable' 'session/global/circuit_breakers.jsonl')
    Handoff = `$null
}
Write-Host 'GATE PASSED WITHOUT CHECKING'
exit 0
"@
        [System.IO.File]::WriteAllText($driver, $driverText, (New-Object System.Text.UTF8Encoding($false)))

        $run = Invoke-ExternalCommand { & $pwshCmd -NoProfile -ExecutionPolicy Bypass -File $driver }
        $output = ($run.Output -join "`n")
        Assert-Result -Name "breaker exits 2" -Condition ($run.ExitCode -eq 2) -FailureMessage ("expected exit 2, got " + $run.ExitCode + ". Output: " + $output)
        Assert-Result -Name "breaker names the failure" -Condition ($output -match "integrity check could not run") -FailureMessage ("expected the check-could-not-run message, got: " + $output)
        Assert-Result -Name "breaker did not pass" -Condition ($output -notmatch "GATE PASSED WITHOUT CHECKING") -FailureMessage "the gate returned instead of blocking"

        $cbHistory = Join-Path $unreadable "session/global/circuit_breakers.jsonl"
        Assert-Result -Name "breaker is recorded distinctly" -Condition ((Test-Path -LiteralPath $cbHistory) -and ((Get-Content -LiteralPath $cbHistory -Raw) -match "framework_integrity_check_failed")) -FailureMessage "expected a framework_integrity_check_failed circuit-breaker event, distinct from a real violation"
    }

    $results += Run-Test -Name "Extracted functions enforce required context keys" -Body {
        # Test null context
        try {
            Invoke-CrucibleRuntimeValidation -Context $null
            Assert-Result -Name "null context check" -Condition $false -FailureMessage "Did not fail on null context"
        } catch {
            Assert-Result -Name "null context check passed" -Condition ($true) -FailureMessage "Null check failed"
        }

        # Test missing key for Invoke-CrucibleRuntimeValidation
        $badCtx = @{ RepoRoot = "foo" }
        try {
            Invoke-CrucibleRuntimeValidation -Context $badCtx
            Assert-Result -Name "runtime missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "runtime key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Invoke-CrucibleScopeGates
        try {
            Invoke-CrucibleScopeGates -Context $badCtx
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

        # Test missing key for Normalize-CrucibleInputState
        try {
            Normalize-CrucibleInputState -Context $badCtx
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

        # Test missing key for Resolve-CrucibleTransition
        try {
            Resolve-CrucibleTransition -Context $badCtx
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
    Write-Host ("`n$failed Crucible gate test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll Crucible gate tests passed." -ForegroundColor Green
exit 0
