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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-factory-gates-breakers-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
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

    $results += Run-Test -Name "D38: Pattern C no worktree passes without checks" -Body {
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
