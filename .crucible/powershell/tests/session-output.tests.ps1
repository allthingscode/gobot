# Tests for prompt/session output helpers.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$FACTORY_LIB = Join-Path $REPO_ROOT "powershell/factory-lib.ps1"
$Quiet = $true
. $FACTORY_LIB

if (-not (Get-Command Check-Dependencies -ErrorAction SilentlyContinue)) {
    function Check-Dependencies {
        param([string]$BacklogItemPath, [string]$TargetSpecialist, [string]$TaskId)
    }
}

$results = @()







function New-TestContext {
    param(
        [Parameter(Mandatory=$true)][string]$TempRoot,
        [string]$TaskId = "F-901",
        [string]$TargetPhase = "verification"
    )

    $sessionDir = Join-Path $TempRoot "session"
    $handoffDir = Join-Path $sessionDir "handoffs"
    $backlogDir = Join-Path $TempRoot "backlog"
    $promptDir = Join-Path $TempRoot "prompts"
    $frameworkDir = Join-Path $TempRoot "powershell"
    New-Item -ItemType Directory -Path $handoffDir, $backlogDir, $promptDir, $frameworkDir -Force | Out-Null

    $handoffPath = Join-Path $handoffDir "$TaskId-20260527T120000Z.json"
    "{}" | Set-Content -LiteralPath $handoffPath -Encoding UTF8

    return @{
        RepoRoot = $TempRoot
        CrucibleRoot = ".crucible"
        FrameworkPowerShell = $frameworkDir
        SessionDir = $sessionDir
        BacklogDir = $backlogDir
        WorkspacesDir = Join-Path $TempRoot "workspaces"
        HandoffDir = $handoffDir
        PromptLib = $promptDir
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
        BudgetCeilings = @{ low = 6; medium = 10; high = 24; extended = 32 }
        Ceiling = 6
        Handoff = [PSCustomObject]@{
            task_id = $TaskId
            source_phase = "grooming"
            target_phase = $TargetPhase
            cumulative_handoff_count = 1
            handoff_retry_count = 0
            review_strike_count = 0
            rebase_count = 0
            budget_tier = "low"
            reason = "unit test"
            artifacts = @("artifact.md")
            file_affinity = @("src/")
        }
        LatestHandoff = Get-Item $handoffPath
        RelativeHandoffPath = ".crucible/session/handoffs/" + (Split-Path -Leaf $handoffPath)
        CumulativeHandoffCount = 1
        IsBootstrap = $false
        Transition = "grooming -> verification"
        NextFactoryCommand = "$((Get-PwshCommand)) -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId $TaskId -Quiet"
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-session-output-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Write-NextStep writes expected content with explicit SessionDir" -Body {
        $sessionDir = Join-Path $tempRoot "next-step/session"
        $command = "$((Get-PwshCommand)) -File factory.ps1 -Init -TaskId F-901"

        Write-NextStep -SessionDir $sessionDir -Command $command -TaskId "F-901" -Specialist "verification"

        $file = Join-Path $sessionDir "F-901/verification/next_step.txt"
        Assert-Result -Name "next_step exists" -Condition (Test-Path -LiteralPath $file) -FailureMessage "next_step.txt was not written"
        $content = (Get-Content -LiteralPath $file -Raw -Encoding UTF8) -replace "`r`n", "`n"
        $expected = ("=== SESSION END COMMAND ===`nRun this via Bash tool when your work is complete:`n`n$command`n" + "`n") -replace "`r`n", "`n"
        Assert-Result -Name "next_step content" -Condition ($content -eq $expected) -FailureMessage "next_step.txt content changed"
    }

    $results += Run-Test -Name "New-FactoryPromptText applies replacement map" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "replace") -TaskId "F-902" -TargetPhase "verification"
        @"
<!-- prompt_version: 9.9.9 -->
Task {task_id}
Worktree {worktree}
Reason {handoff_reason}
Handoff {handoff_file}
Session {session_dir}
Type {type}
Artifacts {artifacts_list}
Strikes {strike_count}
Count {handoff_count}
Remaining {budget_remaining}
{context_block}
{prev_session_summary}
{rebase_section}
{context_bundle_path}
"@ | Set-Content -LiteralPath (Join-Path $ctx.PromptLib "verification_prompt.md") -Encoding UTF8

        $text = New-FactoryPromptText -Context $ctx

        Assert-Result -Name "task replaced" -Condition ($text -match "Task F-902") -FailureMessage "task id was not replaced"
        Assert-Result -Name "reason replaced" -Condition ($text -match "Reason unit test") -FailureMessage "handoff reason was not replaced"
        Assert-Result -Name "type replaced" -Condition ($text -match "Type features") -FailureMessage "type dir was not replaced"
        Assert-Result -Name "version captured" -Condition ($ctx.PromptVersion -eq "9.9.9") -FailureMessage "prompt version was not captured"
    }

    $results += Run-Test -Name "New-FactoryPromptText substitutes PowerShell host for non-Windows prompts" -Body {
        $oldPlatformMock = $script:MockPlatformIsWindows
        $oldPwshMock = $script:MockPwshCommandExists
        try {
            $script:MockPlatformIsWindows = $false
            $script:MockPwshCommandExists = $true
            $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "pwsh-host") -TaskId "F-906" -TargetPhase "verification"
            @"
Run powershell.exe -ExecutionPolicy Bypass -File {{crucible_root}}/powershell/factory.ps1 -Init -TaskId {task_id}
"@ | Set-Content -LiteralPath (Join-Path $ctx.PromptLib "verification_prompt.md") -Encoding UTF8

            $text = New-FactoryPromptText -Context $ctx

            Assert-Result -Name "pwsh rendered" -Condition ($text -match "\bpwsh\b") -FailureMessage "non-Windows prompt did not render pwsh: $text"
            Assert-Result -Name "windows host removed" -Condition (-not $text.Contains("powershell.exe")) -FailureMessage "non-Windows prompt still contains powershell.exe: $text"
        } finally {
            $script:MockPlatformIsWindows = $oldPlatformMock
            $script:MockPwshCommandExists = $oldPwshMock
        }
    }

    $results += Run-Test -Name "New-FactoryPromptText exits on unresolved placeholders" -Body {
        $caseRoot = Join-Path $tempRoot "unresolved"
        $script = @"
`$ErrorActionPreference = 'Stop'
`$REPO_ROOT = '$($REPO_ROOT.Replace("'", "''"))'
`$Quiet = `$true
. (Join-Path `$REPO_ROOT 'powershell/factory-lib.ps1')
`$root = '$($caseRoot.Replace("'", "''"))'
`$session = Join-Path `$root 'session'
`$handoffs = Join-Path `$session 'handoffs'
`$prompts = Join-Path `$root 'prompts'
New-Item -ItemType Directory -Path `$handoffs,`$prompts -Force | Out-Null
`$handoffPath = Join-Path `$handoffs 'F-903-20260527T120000Z.json'
'{}' | Set-Content -LiteralPath `$handoffPath -Encoding UTF8
'Task {task_id} {missing_token}' | Set-Content -LiteralPath (Join-Path `$prompts 'verification_prompt.md') -Encoding UTF8
`$ctx = @{
    RepoRoot = `$root; CrucibleRoot = '.crucible'; FrameworkPowerShell = (Join-Path `$root 'powershell')
    SessionDir = `$session; BacklogDir = (Join-Path `$root 'backlog'); WorkspacesDir = (Join-Path `$root 'workspaces')
    HandoffDir = `$handoffs; PromptLib = `$prompts; LogFile = (Join-Path `$session 'F-903/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path `$session 'global/circuit_breakers.jsonl'); TaskId = 'F-903'; Target = 'agent'
    Init = `$true; Recover = `$false; Quiet = `$true; AutoAdvance = `$false; BudgetCeilings = @{ low = 6 }; Ceiling = 6
    Handoff = [PSCustomObject]@{ task_id = 'F-903'; source_phase = 'grooming'; target_phase = 'verification'; cumulative_handoff_count = 1; handoff_retry_count = 0; review_strike_count = 0; rebase_count = 0; budget_tier = 'low'; reason = 'unit test'; artifacts = @(); file_affinity = @() }
    LatestHandoff = (Get-Item `$handoffPath); RelativeHandoffPath = '.crucible/session/handoffs/F-903-20260527T120000Z.json'
    CumulativeHandoffCount = 1; IsBootstrap = `$false; Transition = 'grooming -> verification'; NextFactoryCommand = 'next'
}
New-FactoryPromptText -Context `$ctx
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1
        Assert-Result -Name "exit code" -Condition ($LASTEXITCODE -eq 1) -FailureMessage "unresolved placeholder did not exit 1; output: $($output | Out-String)"
        Assert-Result -Name "message" -Condition (($output | Out-String) -match "unresolved placeholders") -FailureMessage "unresolved placeholder message changed"
    }

    $results += Run-Test -Name "Write-FactoryCiStatusBanner uses no-gh fallback" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "ci") -TaskId "F-904" -TargetPhase "verification"
        $ctx.PromptFilePath = Join-Path $ctx.SessionDir "F-904/verification/prompt.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $ctx.PromptFilePath) -Force | Out-Null
        $oldPath = $env:PATH
        $oldQuiet = $Quiet
        try {
            $env:PATH = ""
            $script:Quiet = $false
            $output = & { Write-FactoryCiStatusBanner -Context $ctx } 6>&1 | Out-String
            Assert-Result -Name "fallback output" -Condition ($output -match "\[CI\] WARN: gh not found - cannot check CI status") -FailureMessage "no-gh fallback message missing"
        } finally {
            $env:PATH = $oldPath
            $script:Quiet = $oldQuiet
        }
    }

    $results += Run-Test -Name "Initialize-FactoryTargetSession writes task and context files" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "target") -TaskId "F-905" -TargetPhase "verification"
        $ctx.TypeDir = "features"
        $activeDir = Join-Path $ctx.BacklogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        @"
---
budget_tier: "low"
---
Spec body
"@ | Set-Content -LiteralPath (Join-Path $activeDir "F-905_spec.md") -Encoding UTF8
        $env:FACTORY_CYCLE_ID = "testcycle"

        Initialize-FactoryTargetSession -Context $ctx

        $taskFile = Join-Path $ctx.SessionDir "F-905/verification/task.md"
        $contextFile = Join-Path $ctx.SessionDir "F-905/verification/context.md"
        Assert-Result -Name "task exists" -Condition (Test-Path -LiteralPath $taskFile) -FailureMessage "task.md was not written"
        Assert-Result -Name "context exists" -Condition (Test-Path -LiteralPath $contextFile) -FailureMessage "context.md was not written"
        $task = Get-Content -LiteralPath $taskFile -Raw -Encoding UTF8
        $context = Get-Content -LiteralPath $contextFile -Raw -Encoding UTF8
        Assert-Result -Name "task content" -Condition ($task -match "Task: F-905" -and $task -match "Phase: verification") -FailureMessage "task.md content changed"
        Assert-Result -Name "context content" -Condition ($context -match "Context Bundle: F-905" -and $context -match "Phase: verification") -FailureMessage "context.md content changed"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed session-output test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll session-output tests passed." -ForegroundColor Green
exit 0
