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
Ceiling {budget_ceiling}
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
        Assert-Result -Name "ceiling replaced" -Condition ($text -match "Ceiling 6") -FailureMessage "budget_ceiling was not replaced"
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
    $results += Run-Test -Name "Worktree creation tolerates git stderr under EAP=Stop" -Body {
        # Regression: bare `git worktree add` writes "Preparing worktree" to stderr on success,
        # which under Windows PowerShell 5.1 with EAP=Stop becomes a terminating NativeCommandError
        # and aborted -Init before task.md was written. session-output.ps1 now routes the call
        # through Invoke-GitChecked; this asserts that contract holds (no throw, exit 0, worktree made).
        $repo = Join-Path $tempRoot "wt-stderr"
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        Push-Location $repo
        try {
            git init --quiet
            git config core.autocrlf false
            git config user.email "t@t.t"
            git config user.name "t"
            Set-Content -Path "README.md" -Value "# t" -Encoding UTF8
            git add README.md
            git commit -m "init" --quiet
            $mainBranch = (git rev-parse --abbrev-ref HEAD).Trim()
            $wtPath = Join-Path $repo ".crucible/.agent-workspaces/implementation-F-907"

            $threw = $false
            $eapAtCall = $ErrorActionPreference
            try {
                Invoke-GitChecked { git worktree add $wtPath -b "task/F-907" $mainBranch }
            } catch {
                $threw = $true
            }

            Assert-Result -Name "EAP is Stop at call site" -Condition ($eapAtCall -eq "Stop") -FailureMessage "test must run under EAP=Stop to exercise the regression; was $eapAtCall"
            Assert-Result -Name "did not terminate on git stderr" -Condition (-not $threw) -FailureMessage "Invoke-GitChecked threw on benign git worktree-add stderr"
            Assert-Result -Name "git exit code 0" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "worktree add exit code was $LASTEXITCODE"
            Assert-Result -Name "worktree created" -Condition (Test-Path -LiteralPath $wtPath) -FailureMessage "worktree dir was not created at $wtPath"
        } finally {
            Pop-Location
        }
    }
    $results += Run-Test -Name "session-output routes git worktree add through Invoke-GitChecked" -Body {
        # Binds the call site cross-platform: the suite drives -Init via pwsh-7 child processes,
        # which do not reproduce the PS 5.1 NativeCommandError-on-stderr behavior, so a revert to a
        # bare `git worktree add` would silently pass the runtime test above. This static guard fails
        # on any unwrapped worktree-add line in session-output.ps1.
        $src = Get-Content -LiteralPath (Join-Path $REPO_ROOT "powershell/lib/session-output.ps1")
        $bare = @($src | Where-Object { $_ -match 'git worktree add' -and $_ -notmatch 'Invoke-GitChecked' -and $_.TrimStart() -notmatch '^#' })
        Assert-Result -Name "no unwrapped worktree add" -Condition ($bare.Count -eq 0) -FailureMessage ("found bare git worktree add line(s): " + ($bare -join " | "))
    }
    $results += Run-Test -Name "Groomer target task identification handles R-*, suffixed IDs, and B-*/F-*" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "groomer-target") -TaskId "R-029" -TargetPhase "grooming"
        $ctx.TypeDir = "features"
        $ctx.Handoff.source_phase = "grooming"
        $ctx.Handoff.target_phase = "grooming"

        $featActive = Join-Path $ctx.BacklogDir "features/active"
        $bugActive = Join-Path $ctx.BacklogDir "bugs/active"
        $choreActive = Join-Path $ctx.BacklogDir "chores/active"
        New-Item -ItemType Directory -Path $featActive, $bugActive, $choreActive -Force | Out-Null

        @"
## Priority Summary
| Priority | Active Count | Task IDs |
| **P1** | 1 | R-029 |
| **P2** | 1 | C-305a |
| **P3** | 1 | B-101 |

## Backlog Items
| Task ID | Title | Status |
| [R-029](features/active/R-029_Spec.md) | Quality Audit | Ready |
| [C-305a](chores/active/C-305a_Soak.md) | Soak Test | Ready |
| [B-101](bugs/active/B-101_Fix.md) | Bug Fix | Ready |
"@ | Set-Content -LiteralPath (Join-Path $ctx.BacklogDir "BACKLOG.md") -Encoding UTF8

        @"
---
priority: "P0"
created_at: "2026-08-03"
---
Research spec
"@ | Set-Content -LiteralPath (Join-Path $featActive "R-029_Spec.md") -Encoding UTF8

        @"
---
priority: "P1"
created_at: "2026-08-03"
---
Chore spec
"@ | Set-Content -LiteralPath (Join-Path $choreActive "C-305a_Soak.md") -Encoding UTF8

        @"
---
priority: "P1"
created_at: "2026-08-03"
---
Bug spec
"@ | Set-Content -LiteralPath (Join-Path $bugActive "B-101_Fix.md") -Encoding UTF8

        $oldQuiet = $script:Quiet
        try {
            $script:Quiet = $false
            # Test R-029 confirmation
            $outputR29 = & { Initialize-FactoryTargetSession -Context $ctx } 6>&1 | Out-String
            Assert-Result -Name "R-029 confirmed" -Condition ($outputR29 -match "\[INIT\] Confirmed task: R-029") -FailureMessage "R-029 was not confirmed; output: $outputR29"

            # Test C-305a confirmation (suffixed ID) with backlog having only C-305a
            @"
## Backlog Items
| Task ID | Title | Status |
| [C-305a](chores/active/C-305a_Soak.md) | Soak Test | Ready |
"@ | Set-Content -LiteralPath (Join-Path $ctx.BacklogDir "BACKLOG.md") -Encoding UTF8
            $ctx.TaskId = "C-305a"
            $ctx.Handoff.task_id = "C-305a"
            $outputC305a = & { Initialize-FactoryTargetSession -Context $ctx } 6>&1 | Out-String
            Assert-Result -Name "C-305a confirmed" -Condition ($outputC305a -match "\[INIT\] Confirmed task: C-305a") -FailureMessage "C-305a was not confirmed; output: $outputC305a"

            # Test B-101 confirmation with backlog having only B-101
            @"
## Backlog Items
| Task ID | Title | Status |
| [B-101](bugs/active/B-101_Fix.md) | Bug Fix | Ready |
"@ | Set-Content -LiteralPath (Join-Path $ctx.BacklogDir "BACKLOG.md") -Encoding UTF8
            $ctx.TaskId = "B-101"
            $ctx.Handoff.task_id = "B-101"
            $outputB101 = & { Initialize-FactoryTargetSession -Context $ctx } 6>&1 | Out-String
            Assert-Result -Name "B-101 confirmed" -Condition ($outputB101 -match "\[INIT\] Confirmed task: B-101") -FailureMessage "B-101 was not confirmed; output: $outputB101"
        } finally {
            $script:Quiet = $oldQuiet
        }
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
