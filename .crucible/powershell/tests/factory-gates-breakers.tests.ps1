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

function Assert-WedgeOutput {
    param(
        [Parameter(Mandatory=$true)][string]$OutputText,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$BreakerCode
    )

    Assert-Result -Name ($BreakerCode + " wedge sentinel") -Condition ($OutputText -match "\[STOP\] HUMAN INTERVENTION REQUIRED") -FailureMessage ("missing stop sentinel. Output:`n" + $OutputText)
    Assert-Result -Name ($BreakerCode + " wedge task") -Condition ($OutputText -match ("TASK:\s+" + [regex]::Escape($TaskId))) -FailureMessage ("missing task line. Output:`n" + $OutputText)
    Assert-Result -Name ($BreakerCode + " wedge code") -Condition ($OutputText -match [regex]::Escape("(" + $BreakerCode + ")")) -FailureMessage ("missing breaker code. Output:`n" + $OutputText)
    Assert-Result -Name ($BreakerCode + " wedge recovery") -Condition ($OutputText -match "(?m)^RECOVERY:\s+\S") -FailureMessage ("missing non-empty recovery line. Output:`n" + $OutputText)
}
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-factory-gates-breakers-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $results += Run-Test -Name "Write-WedgeReport has non-empty recovery for every breaker code" -Body {
        $codes = @(Get-WedgeRecoveryCodes)
        Assert-Result -Name "recovery code table is not empty" -Condition ($codes.Count -gt 0) -FailureMessage "expected at least one recovery code"

        $actualBreakerCodes = @(
            "git_hook_bypass",
            "fabricated_artifacts",
            "scope_violation",
            "artifact_verification_failed",
            "human_escalation",
            "handoff_retry_exceeded",
            "review_stalemate",
            "budget_exceeded",
            "recurring_merge_conflicts",
            "reviewer_verification_failed"
        )
        foreach ($code in $actualBreakerCodes) {
            Assert-Result -Name ("recovery table contains " + $code) -Condition ($codes -contains $code) -FailureMessage ("missing recovery table entry for " + $code)
        }

        foreach ($code in $codes) {
            $lines = @(Get-WedgeReportLines -TaskId "F-WEDGE" -SourcePhase "verification" -TargetPhase "deployment" -BreakerCode $code -Why "unit test")
            $recoveryLines = @($lines | Where-Object { $_ -match "^RECOVERY:" })
            Assert-Result -Name ("single recovery line for " + $code) -Condition ($recoveryLines.Count -eq 1) -FailureMessage ("expected one RECOVERY line for " + $code + ". Lines:`n" + ($lines -join "`n"))
            Assert-Result -Name ("non-empty recovery line for " + $code) -Condition ($recoveryLines[0] -match "^RECOVERY:\s+\S") -FailureMessage ("empty RECOVERY line for " + $code)
            Assert-Result -Name ("task id substituted for " + $code) -Condition ($recoveryLines[0] -notmatch "\{task_id\}") -FailureMessage ("unsubstituted task id in recovery for " + $code + ": " + $recoveryLines[0])
        }
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

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"
        Assert-Result -Name "quality gate exits 2" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit 2, got " + $exitCode + ". Output: " + $output)

        $logFile = Join-Path $caseRoot "session/F-031/pipeline.log.jsonl"
        $logText = Get-Content -LiteralPath $logFile -Raw -Encoding UTF8
        Assert-Result -Name "retry event logged" -Condition ($logText -match '"event":"quality_gate_retry"') -FailureMessage ("missing quality_gate_retry. Log: " + $logText)
        Assert-Result -Name "no circuit breaker event" -Condition ($logText -notmatch '"event":"circuit_breaker"') -FailureMessage ("unexpected circuit_breaker. Log: " + $logText)
        Assert-Result -Name "no breaker history" -Condition (-not (Test-Path -LiteralPath (Join-Path $caseRoot "session/global/circuit_breakers.jsonl"))) -FailureMessage "circuit breaker history should not be written"
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
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -Command @"
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
        $exitCode2 = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -Command @"
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
      command: $pwshCmd -NoProfile -Command exit 1
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

        $exitCode = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -Command @"
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
      command: $pwshCmd -NoProfile -Command exit 1
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

        $exitCode = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -Command @"
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
      command: $pwshCmd -NoProfile -Command exit 0
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

        $exitCode = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -Command @"
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

    $results += Run-Test -Name "D38: No-Code Closure no worktree passes without checks" -Body {
        $caseRoot = Join-Path $tempRoot "d38-test-no-wt"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")

        $logFile = Join-Path $caseRoot "session/F-038/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $caseRoot "session/global/circuit_breakers.jsonl"

        $exitCode = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -Command @"
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

    $results += Run-Test -Name "review_strike_count >= 3 trips the review_stalemate breaker" -Body {
        $caseRoot = Join-Path $tempRoot "review-stalemate"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")

        $logFile = Join-Path $caseRoot "session/F-060/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $caseRoot "session/global/circuit_breakers.jsonl"
        $breakerBacklog = Join-Path $caseRoot "backlog"

        $outputLines = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -Command @"
            Set-Location '$caseRoot'
            `$Quiet = `$true
            `$backlogDir = '$($breakerBacklog.Replace("'", "''"))'
            `$FRAMEWORK_POWERSHELL = '$(Split-Path -Parent $FACTORY_LIB)'
            . '$libPath'
            `$ctx = @{
                RepoRoot = '$caseRoot'
                WorkspacesDir = '$(Join-Path $caseRoot ".crucible/.agent-workspaces")'
                LogFile = '$($logFile.Replace("'", "''"))'
                CircuitBreakerHistoryFile = '$($cbHistoryFile.Replace("'", "''"))'
                FrameworkPowerShell = `$FRAMEWORK_POWERSHELL
                SessionDir = '$(Join-Path $caseRoot "session")'
                BacklogDir = `$backlogDir
                Ceiling = 10
                Handoff = [PSCustomObject]@{
                    task_id = 'F-060'
                    source_phase = 'verification'
                    target_phase = 'implementation'
                    cumulative_handoff_count = 4
                    review_strike_count = 3
                    handoff_retry_count = 0
                    rebase_count = 0
                    budget_tier = 'low'
                    reason = 'Reviewer rejected: acceptance criterion still unmet (review attempt 3/3).'
                }
            }
            Invoke-CircuitBreakerGates -Context `$ctx
"@ 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $outputLines -join "`n"

        Assert-Result -Name "review_stalemate exit code is 2" -Condition ($exitCode -eq 2) -FailureMessage "expected exit code 2, got $exitCode"
        Assert-WedgeOutput -OutputText $outputText -TaskId "F-060" -BreakerCode "review_stalemate"

        $logContent = Get-Content -LiteralPath $logFile -Raw -Encoding UTF8
        Assert-Result -Name "review_stalemate logs circuit_breaker" -Condition ($logContent -match '"event":"circuit_breaker"') -FailureMessage ("expected circuit_breaker event. Log: " + $logContent)
        Assert-Result -Name "review_stalemate notes recorded" -Condition ($logContent -match "Review Stalemate - 3 strikes") -FailureMessage ("expected review-stalemate note. Log: " + $logContent)

        $blockedDir = Join-Path $breakerBacklog "blocked"
        Assert-Result -Name "review_stalemate blocked record written" -Condition (Test-Path -LiteralPath $blockedDir) -FailureMessage "expected blocked record directory"
        $blockedContent = Get-ChildItem -LiteralPath $blockedDir -Filter "F-060-*.json" | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }
        $blockedText = ($blockedContent -join "`n")
        Assert-Result -Name "review_stalemate breaker slug" -Condition ($blockedText -match '"circuit_breaker":\s*"review_stalemate"') -FailureMessage ("expected review_stalemate slug. Record: " + $blockedText)
        Assert-Result -Name "review_stalemate attempt_count 3" -Condition ($blockedText -match '"attempt_count":\s*3') -FailureMessage ("expected attempt_count 3. Record: " + $blockedText)
    }

    $results += Run-Test -Name "backstop: same-phase handoff with retry > 2 trips the handoff_retry_exceeded breaker" -Body {
        $caseRoot = Join-Path $tempRoot "handoff-retry"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")

        $logFile = Join-Path $caseRoot "session/F-061/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $caseRoot "session/global/circuit_breakers.jsonl"
        $breakerBacklog = Join-Path $caseRoot "backlog"

        $outputLines = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -Command @"
            Set-Location '$caseRoot'
            `$Quiet = `$true
            `$backlogDir = '$($breakerBacklog.Replace("'", "''"))'
            `$FRAMEWORK_POWERSHELL = '$(Split-Path -Parent $FACTORY_LIB)'
            . '$libPath'
            `$ctx = @{
                RepoRoot = '$caseRoot'
                WorkspacesDir = '$(Join-Path $caseRoot ".crucible/.agent-workspaces")'
                LogFile = '$($logFile.Replace("'", "''"))'
                CircuitBreakerHistoryFile = '$($cbHistoryFile.Replace("'", "''"))'
                FrameworkPowerShell = `$FRAMEWORK_POWERSHELL
                SessionDir = '$(Join-Path $caseRoot "session")'
                BacklogDir = `$backlogDir
                Ceiling = 10
                Handoff = [PSCustomObject]@{
                    task_id = 'F-061'
                    source_phase = 'implementation'
                    target_phase = 'implementation'
                    cumulative_handoff_count = 4
                    review_strike_count = 0
                    handoff_retry_count = 3
                    rebase_count = 0
                    budget_tier = 'low'
                    reason = 'Specialist re-dispatched into implementation after repeated self-handoffs (retry 3).'
                }
            }
            Invoke-CircuitBreakerGates -Context `$ctx
"@ 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $outputLines -join "`n"

        Assert-Result -Name "handoff_retry_exceeded exit code is 2" -Condition ($exitCode -eq 2) -FailureMessage "expected exit code 2, got $exitCode"
        Assert-WedgeOutput -OutputText $outputText -TaskId "F-061" -BreakerCode "handoff_retry_exceeded"

        $logContent = Get-Content -LiteralPath $logFile -Raw -Encoding UTF8
        Assert-Result -Name "handoff_retry_exceeded logs circuit_breaker" -Condition ($logContent -match '"event":"circuit_breaker"') -FailureMessage ("expected circuit_breaker event. Log: " + $logContent)
        Assert-Result -Name "handoff_retry_exceeded notes recorded" -Condition ($logContent -match "Persistent Task Failure - Retry over 2") -FailureMessage ("expected persistent-failure note. Log: " + $logContent)

        $blockedDir = Join-Path $breakerBacklog "blocked"
        Assert-Result -Name "handoff_retry_exceeded blocked record written" -Condition (Test-Path -LiteralPath $blockedDir) -FailureMessage "expected blocked record directory"
        $blockedContent = Get-ChildItem -LiteralPath $blockedDir -Filter "F-061-*.json" | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }
        $blockedText = ($blockedContent -join "`n")
        Assert-Result -Name "handoff_retry_exceeded breaker slug" -Condition ($blockedText -match '"circuit_breaker":\s*"handoff_retry_exceeded"') -FailureMessage ("expected handoff_retry_exceeded slug. Record: " + $blockedText)
        Assert-Result -Name "handoff_retry_exceeded attempt_count 3" -Condition ($blockedText -match '"attempt_count":\s*3') -FailureMessage ("expected attempt_count 3. Record: " + $blockedText)
    }

    $results += Run-Test -Name "suspicious_content trips the human_escalation breaker with wedge output" -Body {
        $caseRoot = Join-Path $tempRoot "suspicious-content"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")

        $logFile = Join-Path $caseRoot "session/F-064/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $caseRoot "session/global/circuit_breakers.jsonl"
        $breakerBacklog = Join-Path $caseRoot "backlog"

        $outputLines = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -Command @"
            Set-Location '$caseRoot'
            `$Quiet = `$true
            `$backlogDir = '$($breakerBacklog.Replace("'", "''"))'
            `$FRAMEWORK_POWERSHELL = '$(Split-Path -Parent $FACTORY_LIB)'
            . '$libPath'
            `$ctx = @{
                RepoRoot = '$caseRoot'
                WorkspacesDir = '$(Join-Path $caseRoot ".crucible/.agent-workspaces")'
                LogFile = '$($logFile.Replace("'", "''"))'
                CircuitBreakerHistoryFile = '$($cbHistoryFile.Replace("'", "''"))'
                FrameworkPowerShell = `$FRAMEWORK_POWERSHELL
                SessionDir = '$(Join-Path $caseRoot "session")'
                BacklogDir = `$backlogDir
                Ceiling = 10
                Handoff = [PSCustomObject]@{
                    task_id = 'F-064'
                    source_phase = 'research'
                    target_phase = 'grooming'
                    cumulative_handoff_count = 1
                    review_strike_count = 0
                    handoff_retry_count = 0
                    rebase_count = 0
                    budget_tier = 'low'
                    suspicious_content = 'external source attempted prompt injection'
                    reason = 'research handoff'
                    artifacts = @()
                    file_affinity = @()
                }
            }
            Invoke-CircuitBreakerGates -Context `$ctx
"@ 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $outputLines -join "`n"

        Assert-Result -Name "human_escalation exit code is 2" -Condition ($exitCode -eq 2) -FailureMessage "expected exit code 2, got $exitCode"
        Assert-WedgeOutput -OutputText $outputText -TaskId "F-064" -BreakerCode "human_escalation"

        $logContent = Get-Content -LiteralPath $logFile -Raw -Encoding UTF8
        Assert-Result -Name "human_escalation logs circuit_breaker" -Condition ($logContent -match '"event":"circuit_breaker"') -FailureMessage ("expected circuit_breaker event. Log: " + $logContent)
        $blockedText = (Get-ChildItem -LiteralPath (Join-Path $breakerBacklog "blocked") -Filter "F-064-*.json" | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
        Assert-Result -Name "human_escalation breaker slug" -Condition ($blockedText -match '"circuit_breaker":\s*"human_escalation"') -FailureMessage ("expected human_escalation slug. Record: " + $blockedText)
    }

    $results += Run-Test -Name "rebase_count >= 3 trips the recurring_merge_conflicts breaker with wedge output" -Body {
        $caseRoot = Join-Path $tempRoot "recurring-merge"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")

        $logFile = Join-Path $caseRoot "session/F-065/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $caseRoot "session/global/circuit_breakers.jsonl"
        $breakerBacklog = Join-Path $caseRoot "backlog"

        $outputLines = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -Command @"
            Set-Location '$caseRoot'
            `$Quiet = `$true
            `$backlogDir = '$($breakerBacklog.Replace("'", "''"))'
            `$FRAMEWORK_POWERSHELL = '$(Split-Path -Parent $FACTORY_LIB)'
            . '$libPath'
            `$ctx = @{
                RepoRoot = '$caseRoot'
                WorkspacesDir = '$(Join-Path $caseRoot ".crucible/.agent-workspaces")'
                LogFile = '$($logFile.Replace("'", "''"))'
                CircuitBreakerHistoryFile = '$($cbHistoryFile.Replace("'", "''"))'
                FrameworkPowerShell = `$FRAMEWORK_POWERSHELL
                SessionDir = '$(Join-Path $caseRoot "session")'
                BacklogDir = `$backlogDir
                Ceiling = 10
                Handoff = [PSCustomObject]@{
                    task_id = 'F-065'
                    source_phase = 'deployment'
                    target_phase = 'implementation'
                    cumulative_handoff_count = 1
                    review_strike_count = 0
                    handoff_retry_count = 0
                    rebase_count = 3
                    budget_tier = 'low'
                    suspicious_content = ''
                    reason = 'manual conflict persists'
                }
            }
            Invoke-CircuitBreakerGates -Context `$ctx
"@ 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $outputLines -join "`n"

        Assert-Result -Name "recurring_merge_conflicts exit code is 2" -Condition ($exitCode -eq 2) -FailureMessage "expected exit code 2, got $exitCode"
        Assert-WedgeOutput -OutputText $outputText -TaskId "F-065" -BreakerCode "recurring_merge_conflicts"

        $logContent = Get-Content -LiteralPath $logFile -Raw -Encoding UTF8
        Assert-Result -Name "recurring_merge_conflicts logs circuit_breaker" -Condition ($logContent -match '"event":"circuit_breaker"') -FailureMessage ("expected circuit_breaker event. Log: " + $logContent)
        $blockedText = (Get-ChildItem -LiteralPath (Join-Path $breakerBacklog "blocked") -Filter "F-065-*.json" | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
        Assert-Result -Name "recurring_merge_conflicts breaker slug" -Condition ($blockedText -match '"circuit_breaker":\s*"recurring_merge_conflicts"') -FailureMessage ("expected recurring_merge_conflicts slug. Record: " + $blockedText)
    }

    $results += Run-Test -Name "anti-bypass: under-reported cumulative count is overridden from the log and still trips budget_exceeded" -Body {
        $caseRoot = Join-Path $tempRoot "budget-bypass"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")

        $sessionDir = Join-Path $caseRoot "session"
        $handoffDir = Join-Path $sessionDir "handoffs"
        $logFile = Join-Path $sessionDir "F-062/pipeline.log.jsonl"
        New-Item -ItemType Directory -Path $handoffDir, (Split-Path -Parent $logFile) -Force | Out-Null

        # Agent under-reports cumulative_handoff_count = 3 to stay under the low ceiling (10).
        $handoffPath = Join-Path $handoffDir "F-062-20260719T000000000Z.json"
        [ordered]@{
            task_id = "F-062"; source_phase = "grooming"; target_phase = "implementation"
            reason = "Implement"; handoff_retry_count = 0; review_strike_count = 0
            rebase_count = 0; budget_tier = "low"; cumulative_handoff_count = 3
            prompt_version = "v1"; cycle_id = "prod-cycle"; session_cycle_id = "prod-cycle"
            generated_by = "new-handoff.ps1"; tool_version = "1.0.0"
        } | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $handoffPath -Encoding UTF8

        # The pipeline log holds 11 real (non-test-cycle) session_end events for the task.
        1..11 | ForEach-Object {
            $e = @{ event = "session_end"; task_id = "F-062"; phase = "implementation"; cycle_id = "prod-cycle" } | ConvertTo-Json -Compress
            [System.IO.File]::AppendAllText($logFile, $e + "`n")
        }

        $breakerBacklog = Join-Path $caseRoot "backlog"

        $outputLines = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -Command @"
            Set-Location '$caseRoot'
            `$Quiet = `$true
            `$backlogDir = '$($breakerBacklog.Replace("'", "''"))'
            `$FRAMEWORK_POWERSHELL = '$(Split-Path -Parent $FACTORY_LIB)'
            . '$libPath'
            `$ctx = @{
                RepoRoot = '$caseRoot'
                WorkspacesDir = '$(Join-Path $caseRoot ".crucible/.agent-workspaces")'
                LogFile = '$($logFile.Replace("'", "''"))'
                CircuitBreakerHistoryFile = '$(Join-Path $sessionDir "global/circuit_breakers.jsonl")'
                FrameworkPowerShell = `$FRAMEWORK_POWERSHELL
                SessionDir = '$($sessionDir.Replace("'", "''"))'
                BacklogDir = `$backlogDir
                LatestHandoff = (Get-Item -LiteralPath '$($handoffPath.Replace("'", "''"))')
                BudgetCeilings = `$null
                IsBootstrap = `$false
                Handoff = `$null
                CumulativeHandoffCount = 0
                Ceiling = `$null
                BudgetTierKey = ''
                InvalidBudgetTier = ''
                RelativeHandoffPath = `$null
            }
            Read-FactoryHandoffContext -Context `$ctx
            Invoke-CircuitBreakerGates -Context `$ctx
"@ 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $outputLines -join "`n"

        Assert-Result -Name "budget bypass exit code is 2" -Condition ($exitCode -eq 2) -FailureMessage "expected exit code 2, got $exitCode"
        Assert-WedgeOutput -OutputText $outputText -TaskId "F-062" -BreakerCode "budget_exceeded"

        $logContent = Get-Content -LiteralPath $logFile -Raw -Encoding UTF8
        Assert-Result -Name "budget bypass logs circuit_breaker" -Condition ($logContent -match '"event":"circuit_breaker"') -FailureMessage ("expected circuit_breaker event. Log: " + $logContent)
        Assert-Result -Name "budget bypass notes recorded" -Condition ($logContent -match "Token Budget Exceeded - 11 over 10") -FailureMessage ("expected overridden-count note. Log: " + $logContent)

        $blockedDir = Join-Path $breakerBacklog "blocked"
        Assert-Result -Name "budget bypass blocked record written" -Condition (Test-Path -LiteralPath $blockedDir) -FailureMessage "expected blocked record directory"
        $blockedContent = Get-ChildItem -LiteralPath $blockedDir -Filter "F-062-*.json" | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }
        $blockedText = ($blockedContent -join "`n")
        Assert-Result -Name "budget bypass breaker slug" -Condition ($blockedText -match '"circuit_breaker":\s*"budget_exceeded"') -FailureMessage ("expected budget_exceeded slug. Record: " + $blockedText)
        Assert-Result -Name "budget bypass attempt_count 11" -Condition ($blockedText -match '"attempt_count":\s*11') -FailureMessage ("expected overridden attempt_count 11. Record: " + $blockedText)
    }

    $results += Run-Test -Name "anti-bypass: test-cycle session_end events are excluded from the log-derived count" -Body {
        $caseRoot = Join-Path $tempRoot "budget-testcycle"
        $sessionDir = Join-Path $caseRoot "session"
        $handoffDir = Join-Path $sessionDir "handoffs"
        $logFile = Join-Path $sessionDir "F-063/pipeline.log.jsonl"
        New-Item -ItemType Directory -Path $handoffDir, (Split-Path -Parent $logFile) -Force | Out-Null

        $handoffPath = Join-Path $handoffDir "F-063-20260719T000000000Z.json"
        [ordered]@{
            task_id = "F-063"; source_phase = "grooming"; target_phase = "implementation"
            reason = "Implement"; handoff_retry_count = 0; review_strike_count = 0
            rebase_count = 0; budget_tier = "low"; cumulative_handoff_count = 3
            prompt_version = "v1"; cycle_id = "test-cycle"; session_cycle_id = "test-cycle"
            generated_by = "new-handoff.ps1"; tool_version = "1.0.0"
        } | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $handoffPath -Encoding UTF8

        # 11 session_end events, but all tagged test-cycle -> must NOT be counted.
        1..11 | ForEach-Object {
            $e = @{ event = "session_end"; task_id = "F-063"; phase = "implementation"; cycle_id = "test-cycle" } | ConvertTo-Json -Compress
            [System.IO.File]::AppendAllText($logFile, $e + "`n")
        }

        $ctx = @{
            RepoRoot = $caseRoot
            LatestHandoff = (Get-Item -LiteralPath $handoffPath)
            LogFile = $logFile
            BudgetCeilings = $null
            IsBootstrap = $false
            Handoff = $null
            CumulativeHandoffCount = 0
            Ceiling = $null
            BudgetTierKey = ""
            InvalidBudgetTier = ""
            RelativeHandoffPath = $null
        }

        Read-FactoryHandoffContext -Context $ctx

        Assert-Result -Name "test-cycle events do not override reported count" -Condition ($ctx.Handoff.cumulative_handoff_count -eq 3) -FailureMessage ("expected reported count 3 preserved, got " + $ctx.Handoff.cumulative_handoff_count)
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
