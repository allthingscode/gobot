# The circuit breakers: the checks that stop a transition whatever the handoff claims, from
# budget, strike and rebase ceilings to the independent verification run.
#
# Enforced here: I1 (the uncommitted_task_worktree breaker refuses a task worktree with
# uncommitted changes before the independent checks run, so what is tested is what merges)
# and I11 for every breaker, each an exit. docs/policy.md section 8.
#
# Loaded by crucible-gates.ps1. The functions it calls from that file (Get-RootRelativePath,
# Assert-CodeTaskWorktree) resolve at call time, so it is not loadable on its own.
. (Join-Path $PSScriptRoot "platform.ps1")
. (Join-Path $PSScriptRoot "injection-detector.ps1")
. (Join-Path $PSScriptRoot "crucible-context.ps1")
. (Join-Path $PSScriptRoot "worktree.ps1")
. (Join-Path $PSScriptRoot "crucible-gates-wedge-report.ps1")

function Invoke-CircuitBreakerGates {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-CrucibleContextKeys -Context $Context `
        -RequiredKeys @("Handoff", "Ceiling", "FrameworkPowerShell", "RepoRoot", "WorkspacesDir") `
        -NonNullKeys @("LogFile", "CircuitBreakerHistoryFile")

    $handoff = $Context.Handoff
    # Default missing optional counters to prevent StrictMode crash (Part C)
    foreach ($counter in @("review_strike_count", "rebase_count", "handoff_retry_count", "cumulative_handoff_count")) {
        if ($null -eq $handoff.PSObject.Properties[$counter]) {
            $defaultVal = if ($counter -eq "cumulative_handoff_count") { 1 } else { 0 }
            $handoff | Add-Member -MemberType NoteProperty -Name $counter -Value $defaultVal -Force
        }
    }
    $ceiling = $Context.Ceiling
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile
    $FRAMEWORK_POWERSHELL = $Context.FrameworkPowerShell
    $workspacesDir = $Context.WorkspacesDir
    $sessionDir = $Context.SessionDir
    $invalidBudgetTier = ""
    if ($Context.ContainsKey("InvalidBudgetTier") -and -not [string]::IsNullOrWhiteSpace([string]$Context.InvalidBudgetTier)) {
        $invalidBudgetTier = [string]$Context.InvalidBudgetTier
    } elseif ($handoff.PSObject.Properties["budget_tier"] -and $handoff.budget_tier -and $null -eq $ceiling) {
        $invalidBudgetTier = ([string]$handoff.budget_tier).Trim().ToLowerInvariant()
    }

    # --- 3. Circuit Breakers ---
    # Scan research findings/artifacts (RH2)
    if ($handoff.source_phase -eq "research") {
        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { Resolve-ConfigProjectRoot }
        if ($repoRoot -and (Test-Path -LiteralPath $repoRoot)) {
            $repoRoot = (Resolve-Path -LiteralPath $repoRoot).Path
        }
        
        $crucibleRoot = ".crucible"
        $configPath = Join-Path $repoRoot ".crucible/config.yaml"
        $configUnreadable = $false
        $configReadError = ""
        if (Test-Path -LiteralPath $configPath) {
            try {
                $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
                if ($content -match '(?m)^crucible_root:\s*["'']?([^"''\r\n]+)["'']?\s*$') {
                    $crucibleRoot = $Matches[1].Trim()
                }
            } catch {
                $configUnreadable = $true
                $configReadError = $_.Exception.Message
            }
        }
        $researchDir = Join-Path $repoRoot (Join-Path $crucibleRoot "research")

        $handoffText = ""
        if ($Context.ContainsKey("LatestHandoff") -and $null -ne $Context["LatestHandoff"]) {
            $handoffFile = $Context["LatestHandoff"].FullName
            if (Test-Path -LiteralPath $handoffFile) {
                $handoffText = Get-Content $handoffFile -Raw -Encoding UTF8
            }
        }
        if ([string]::IsNullOrEmpty($handoffText)) {
            $handoffText = $handoff | ConvertTo-Json -Depth 100
        }

        $detectedFile = ""
        $detectedRule = ""
        $hasBlockMatch = $false
        $scanFailed = $false
        $scanFailedFile = ""
        $scanFailedError = ""
        $scanFailureKind = ""

        # Scan handoff text
        $handoffMatches = Get-InjectionMatches -Text $handoffText
        foreach ($m in $handoffMatches) {
            if ($m.Severity -eq "block") {
                $hasBlockMatch = $true
                $detectedFile = "handoff"
                $detectedRule = $m.RuleId
                break
            }
        }

        # Scan the configured research root; fallback after a config read failure
        # would leave its artifacts unchecked. Preserve any injection already found
        # in the handoff: it outranks config failure and requires a blocked-task record.
        if ($configUnreadable -and -not $hasBlockMatch) {
            $scanFailed = $true
            $scanFailureKind = "config"
            $scanFailedFile = ".crucible/config.yaml"
            $scanFailedError = $configReadError
            $detectedFile = $scanFailedFile
            $detectedRule = ""
            $hasBlockMatch = $true
        }

        # Scan artifacts
        if (-not $hasBlockMatch -and $null -ne $handoff.artifacts) {
            foreach ($art in $handoff.artifacts) {
                if ([string]::IsNullOrWhiteSpace($art)) { continue }
                $fullPath = Join-Path $repoRoot $art
                if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                    $resolvedPath = (Resolve-Path -LiteralPath $fullPath).Path
                    $resolvedResearchDir = $researchDir
                    if (Test-Path -LiteralPath $researchDir) {
                        $resolvedResearchDir = (Resolve-Path -LiteralPath $researchDir).Path
                    }
                    if ($resolvedPath.StartsWith($resolvedResearchDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                        try {
                            $artContent = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8
                            $artMatches = Get-InjectionMatches -Text $artContent
                            foreach ($m in $artMatches) {
                                if ($m.Severity -eq "block") {
                                    $hasBlockMatch = $true
                                    $detectedFile = $art
                                    $detectedRule = $m.RuleId
                                    break
                                }
                            }
                        } catch {
                            $scanFailed = $true
                            $scanFailureKind = "research_input"
                            $scanFailedFile = $art
                            $scanFailedError = $_.Exception.Message
                            $detectedFile = $scanFailedFile
                            $detectedRule = ""
                            $hasBlockMatch = $true
                        }
                    }
                }
                if ($hasBlockMatch) { break }
            }
        }

        # Scan session research task.md
        if (-not $hasBlockMatch -and -not [string]::IsNullOrEmpty($sessionDir)) {
            $sessionTaskMd = Join-Path $sessionDir "$($handoff.task_id)/research/task.md"
            if (Test-Path -LiteralPath $sessionTaskMd -PathType Leaf) {
                try {
                    $taskContent = Get-Content -LiteralPath $sessionTaskMd -Raw -Encoding UTF8
                    $taskMatches = Get-InjectionMatches -Text $taskContent
                    foreach ($m in $taskMatches) {
                        if ($m.Severity -eq "block") {
                            $hasBlockMatch = $true
                            $detectedFile = Get-RootRelativePath -Root $repoRoot -Path $sessionTaskMd
                            if ([string]::IsNullOrEmpty($detectedFile)) {
                                $detectedFile = $sessionTaskMd
                            }
                            $detectedRule = $m.RuleId
                            break
                        }
                    }
                } catch {
                    $scanFailed = $true
                    $scanFailureKind = "research_input"
                    $scanFailedFile = Get-RootRelativePath -Root $repoRoot -Path $sessionTaskMd
                    if ([string]::IsNullOrEmpty($scanFailedFile)) {
                        $scanFailedFile = $sessionTaskMd
                    }
                    $scanFailedError = $_.Exception.Message
                    $detectedFile = $scanFailedFile
                    $detectedRule = ""
                    $hasBlockMatch = $true
                }
            }
        }

        if ($hasBlockMatch) {
            if ($null -eq $handoff.psobject.Properties["suspicious_content"] -or $handoff.suspicious_content -eq "") {
                if ($scanFailed) {
                    if ($scanFailureKind -eq "config") {
                        $distinctNotes = "researcher_config_unreadable: $scanFailedFile"
                        $summaryMsg = "Could not determine the configured research directory because $scanFailedFile could not be read: $scanFailedError. Research input cannot be scanned without it."
                        $wedgeWhy = $summaryMsg + " Reason: Configuration read failure."
                        $recoveryOverride = "Restore read access to " + $scanFailedFile + ", verify the configured research directory, archive the blocked record, then run: pwsh -ExecutionPolicy Bypass -File `".crucible/powershell/crucible.ps1`" -Init -TaskId " + $handoff.task_id + " -ProjectRoot `"{project_root}`" -Recover"
                    } else {
                        $distinctNotes = "researcher_artifact_unscannable: $scanFailedFile"
                        $summaryMsg = "Could not scan $scanFailedFile for prompt injection: $scanFailedError. Unscannable research input is treated as a block."
                        $wedgeWhy = $summaryMsg + " Reason: Scan failure."
                        $recoveryOverride = "Review external sources before continuing. File: " + $scanFailedFile + "; Scan failure: " + $scanFailedError + ". Then archive the blocked record and run: pwsh -ExecutionPolicy Bypass -File `".crucible/powershell/crucible.ps1`" -Init -TaskId " + $handoff.task_id + " -ProjectRoot `"{project_root}`" -Recover"
                    }
                } else {
                    $distinctNotes = "researcher_silent_detector_hit: ${detectedFile}:$detectedRule"
                    $summaryMsg = "Silent injection match in ${detectedFile}: $detectedRule (researcher silent detector hit)"
                    $wedgeWhy = $summaryMsg + ". Reason: Silent corroboration."
                    $recoveryOverride = "Review external sources before continuing. File: " + $detectedFile + "; Rule: " + $detectedRule + ". Then archive the blocked record and run: pwsh -ExecutionPolicy Bypass -File `".crucible/powershell/crucible.ps1`" -Init -TaskId " + $handoff.task_id + " -ProjectRoot `"{project_root}`" -Recover"
                }

                Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "blocked" -Notes $distinctNotes `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "human_escalation" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist $handoff.source_phase -Summary $summaryMsg
                Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "human_escalation" `
                    -Why $wedgeWhy `
                    -RecoveryOverride $recoveryOverride
                exit 2
            }
        }
    }

    # Suspicious Content (Prompt Injection Defense - {task_id})
    if ($null -ne $handoff.psobject.Properties["suspicious_content"] -and $null -ne $handoff.suspicious_content -and $handoff.suspicious_content -ne "") {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "blocked" -Notes ("Suspicious Content Flagged: " + $handoff.suspicious_content) `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "human_escalation" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist $handoff.source_phase -Summary ("Suspicious content flagged in handoff: " + $handoff.suspicious_content)
        Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "human_escalation" `
            -Why ("Suspicious Content detected. Suspicious content flagged in handoff: " + $handoff.suspicious_content) `
            -RecoveryOverride ("Review external sources before continuing. Then archive the blocked record and run: pwsh -ExecutionPolicy Bypass -File `".crucible/powershell/crucible.ps1`" -Init -TaskId " + $handoff.task_id + " -ProjectRoot `"{project_root}`" -Recover")
        exit 2
    }

    # Handoff Retry Limit (defense-in-depth backstop).
    # No same-phase (X -> X) transition exists in validate-handoff.ps1's $validTransitions
    # map, so a schema-valid handoff can never satisfy source_phase == target_phase. This
    # guard only fires if a same-phase handoff bypasses validation and reaches the breaker
    # with retry > 2 -- an otherwise-impossible state we block rather than run. Persistent
    # re-review failure is covered live by the review_stalemate breaker below.
    if ($handoff.handoff_retry_count -gt 2 -and $handoff.source_phase -eq $handoff.target_phase) {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "blocked" -Notes "Persistent Task Failure - Retry over 2" `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "handoff_retry_exceeded" -AttemptCount $handoff.handoff_retry_count -LastSpecialist $handoff.target_phase -Summary "Persistent Task Failure - Retry over 2"
        Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "handoff_retry_exceeded" `
            -Why ("Task " + $handoff.task_id + " has been handed off to " + $handoff.target_phase + " " + $handoff.handoff_retry_count + " times. Reason: " + $handoff.reason)
        exit 2
    }

    # Review Strike-2 DEGRADED Warning
    if ($handoff.review_strike_count -eq 2 -and $handoff.target_phase -eq "implementation") {
        Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist $handoff.target_phase `
            -Outcome "warned" -Kind "review_strike_2" -Notes "Review strike 2 of 3: Architect should reduce scope" `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
        Write-Quiet ("`n[DEGRADED] Task " + $handoff.task_id + " has failed review twice.") -ForegroundColor Yellow
        Write-Quiet "  Strike count: 2 of 3. One more failure will BLOCK this task." -ForegroundColor Yellow
        Write-Quiet "  Architect DIRECTIVE: Do not attempt a full re-implementation." -ForegroundColor White
        Write-Quiet "  Consider: splitting the task, deferring the contentious part, or simplifying scope." -ForegroundColor White
    }

    # Review 3-Strike Rule
    if ($handoff.review_strike_count -ge 3) {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "blocked" -Notes "Review Stalemate - 3 strikes" `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "review_stalemate" -AttemptCount $handoff.review_strike_count -LastSpecialist $handoff.target_phase -Summary "Review Stalemate - 3 strikes"
        Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "review_stalemate" `
            -Why ("Task " + $handoff.task_id + " has failed review " + $handoff.review_strike_count + " times. Reason: " + $handoff.reason)
        exit 2
    }

    # The server-side handoff count that guards this ceiling is a lower bound whenever the
    # pipeline log had lines it could not parse. Say so on every run, whether or not the gap
    # changes the answer below: a count that silently skipped its evidence is exactly the
    # shape this ceiling exists to catch.
    $handoffLogParseFailureCount = 0
    if ($Context.ContainsKey("HandoffLogParseFailureCount")) {
        $handoffLogParseFailureCount = [int]$Context.HandoffLogParseFailureCount
    }
    if ($handoffLogParseFailureCount -gt 0) {
        Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist $handoff.target_phase `
            -Outcome "unverifiable" -Kind "unreadable_handoff_history" `
            -Notes ("Server-side handoff count skipped " + $handoffLogParseFailureCount + " unparseable pipeline-log line(s); the count is a lower bound.") `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
    }

    # Token Budget Enforcement
    if ($handoff.budget_tier) {
        if (-not [string]::IsNullOrWhiteSpace($invalidBudgetTier)) {
            Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "invalid_budget_tier" `
                -Why ("Invalid budget_tier '" + $handoff.budget_tier + "'. Allowed values: " + ((Get-BudgetTierList) -join ", "))
            exit 1
        }

        # Framework-forced rebase-conflict rework cycles are not quality churn; grant
        # the task headroom per rebase_count so a line collision cannot trip the budget
        # breaker on an otherwise-clean task (see Get-RebaseCycleAllowance).
        $effectiveCeiling = $ceiling
        $rebaseCycles = 0
        if ($handoff.PSObject.Properties["rebase_count"] -and
            [int]::TryParse([string]$handoff.rebase_count, [ref]$rebaseCycles) -and $rebaseCycles -gt 0) {
            $allowance = if (Get-Command Get-RebaseCycleAllowance -ErrorAction SilentlyContinue) { Get-RebaseCycleAllowance } else { 5 }
            $effectiveCeiling = $ceiling + ($rebaseCycles * $allowance)
        }

        if ($handoff.cumulative_handoff_count -gt $effectiveCeiling) {
            Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "budget_exceeded" -Notes ("Token Budget Exceeded - " + $handoff.cumulative_handoff_count + " over " + $effectiveCeiling) `
                -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "budget_exceeded" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist $handoff.source_phase -Summary ("Token Budget Exceeded - " + $handoff.cumulative_handoff_count + " over " + $effectiveCeiling)
            Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "budget_exceeded" `
                -Why ("Task " + $handoff.task_id + " has reached " + $handoff.cumulative_handoff_count + " handoffs. Ceiling: " + $effectiveCeiling + " for tier " + $handoff.budget_tier + " (base " + $ceiling + " + " + $rebaseCycles + " rebase cycle(s)). Reason: " + $handoff.reason)
            exit 2
        } elseif ($handoffLogParseFailureCount -gt 0 -and
                  ([int]$handoff.cumulative_handoff_count + $handoffLogParseFailureCount) -gt $effectiveCeiling) {
            # Counted handoffs are under the ceiling, but not by more than the number of lines
            # the count could not read. Each unreadable line may be a session_end, so passing
            # here would be asserting a budget check that the evidence does not support.
            $unreadableHandoffReason = "Handoff count is unverifiable: " + $handoffLogParseFailureCount + " unparseable pipeline-log line(s) could each hide a session_end, and " + $handoff.cumulative_handoff_count + " counted handoff(s) plus those lines would exceed the ceiling of " + $effectiveCeiling + "."
            Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "unreadable_handoff_history" -Notes $unreadableHandoffReason `
                -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "unreadable_handoff_history" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist $handoff.source_phase -Summary $unreadableHandoffReason
            Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "unreadable_handoff_history" `
                -Why $unreadableHandoffReason
            exit 2
        }
    }

    # Recurring Merge Conflicts
    if ($handoff.psobject.Properties["rebase_count"] -and $handoff.rebase_count -ge 3) {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "blocked" -Notes "Recurring Merge Conflicts - 3 strikes" `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "recurring_merge_conflicts" -AttemptCount $handoff.rebase_count -LastSpecialist $handoff.target_phase -Summary "Recurring Merge Conflicts - 3 strikes. Task requires manual intervention."
        Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "recurring_merge_conflicts" `
            -Why ("Task " + $handoff.task_id + " has been rebased " + $handoff.rebase_count + " times and still conflicts.")
        exit 2
    }

    # A-2: Independent isolated test verification before accepting APPROVED ({task_id}, {task_id})
    if ($handoff.source_phase -eq "verification" -and $handoff.target_phase -eq "deployment") {
        $wtPath = Resolve-ImplementationWorktreePath -TaskId $handoff.task_id
        $isolatedChecksScript = "$FRAMEWORK_POWERSHELL/run-isolated-checks.ps1"
        Assert-CodeTaskWorktree -Context $Context -TaskId $handoff.task_id -WorktreePath $wtPath -Check "independent verification"
        if (Test-Path $wtPath) {
            if (-not (Test-Path $isolatedChecksScript)) {
                Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "missing_isolated_checks_script" `
                    -Why ("Missing isolated checks script: " + $isolatedChecksScript)
                exit 2
            }
            # The checks run on the worktree's files but the merge ships only its commits, so
            # an uncommitted edit would be tested and then never merged. Item 221.
            $uncommitted = @()
            try {
                $uncommitted = @(Get-WorktreeUncommittedPaths -WorktreePath $wtPath)
            } catch {
                $uncommitted = @("(unreadable: " + $_.Exception.Message + ")")
            }
            if ($uncommitted.Count -gt 0) {
                $joined = ($uncommitted -join "; ")
                Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "crucible" -Outcome "uncommitted_task_worktree" -Notes ("Uncommitted changes in task worktree: " + $joined) `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "uncommitted_task_worktree" `
                    -Why ("The task worktree " + $wtPath + " has uncommitted changes: " + $joined + ". The independent checks would test them, but the merge ships only commits on task/" + $handoff.task_id + ". Commit them there or discard them, then rerun crucible.ps1 -Init.")
                exit 2
            }
            Write-Quiet "`n[VERIFY] Running independent isolated full verification in worktree before accepting APPROVED..." -ForegroundColor Cyan
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $testOutput = & (Get-PwshCommand) -ExecutionPolicy Bypass -File $isolatedChecksScript -TaskId $handoff.task_id -Mode full 2>&1
            } finally {
                $ErrorActionPreference = $previousPreference
            }
            if ($LASTEXITCODE -ne 0) {
                # Identify which named check failed (e.g. golangci-lint)
                $failedCheck = "unknown"
                if ($testOutput) {
                    foreach ($line in $testOutput) {
                        if ($line -match "Check failed:\s*(.+)") {
                            $failedCheck = $Matches[1].Trim()
                            break
                        }
                    }
                }

                # Check if this is a retry (prior quality_gate_retry in event log)
                $hasPriorRetry = $false
                $retryHistoryParseFailureCount = 0
                if (Test-Path $LOG_FILE) {
                    $lines = @(Get-Content $LOG_FILE -Tail 200 -Encoding UTF8)
                    for ($i = $lines.Length - 1; $i -ge 0; $i--) {
                        # A blank line is formatting, not a miss - see the matching skip in
                        # Invoke-CrucibleRuntimeValidation.
                        if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
                        try {
                            $cleanedLine = $lines[$i] -replace "^$([char]0xFEFF)", ""
                            $entry = $cleanedLine | ConvertFrom-Json
                            $logPhase = Get-EntryPhase $entry
                             if ($entry.task_id -eq $handoff.task_id -and $logPhase -eq "crucible") {
                                 continue
                             }
                             if ($entry.task_id -eq $handoff.task_id -and $logPhase -ne $handoff.source_phase) {
                                break
                            }
                            if ($entry.task_id -eq $handoff.task_id -and $logPhase -eq $handoff.source_phase -and $entry.event -eq "session_end" -and $entry.PSObject.Properties["outcome"] -and $entry.outcome -eq "success") {
                                $entryHandoffCount = if ($entry.PSObject.Properties["handoff_count"]) { $entry.handoff_count } else { 0 }
                                if ($entryHandoffCount -lt $handoff.cumulative_handoff_count) {
                                    break
                                }
                            }
                            if ($entry.task_id -eq $handoff.task_id -and $logPhase -eq $handoff.source_phase -and $entry.event -eq "quality_gate_retry" -and $entry.PSObject.Properties["notes"] -and $entry.notes -like "*verification*check*") {
                                $hasPriorRetry = $true
                                break
                            }
                        } catch {
                            $retryHistoryParseFailureCount += 1
                            continue
                        }
                    }
                }

                if ($retryHistoryParseFailureCount -gt 0) {
                    Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                        -Outcome "warned" -Kind "unreadable_retry_history" -Notes ("Retry history scan skipped " + $retryHistoryParseFailureCount + " unparseable line(s).") `
                        -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                }

                if ($hasPriorRetry) {
                    Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "crucible" -Outcome "reviewer_verification_failed" -Notes "Independent verification failed after Reviewer APPROVED again: $failedCheck" `
                        -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                    Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "reviewer_verification_failed" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist "verification" -Summary "Verification command failed in worktree after Reviewer self-reported APPROVED: $failedCheck"
                    $reviewerVerificationWhy = "Independent verification check failed on retry: " + $failedCheck + ". Route back to Architect."
                    if ($testOutput) {
                        $testOutputSummary = (($testOutput | ForEach-Object { [string]$_ }) -join " ")
                        $reviewerVerificationWhy = "Independent verification check failed on retry: " + $failedCheck + ". Check output: " + $testOutputSummary + ". Route back to Architect."
                    }
                    Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "reviewer_verification_failed" `
                        -Why $reviewerVerificationWhy
                    exit 2
                } elseif ($retryHistoryParseFailureCount -gt 0) {
                    $unreadableRetryHistoryReason = "Retry history is unreadable: " + $retryHistoryParseFailureCount + " unparseable line(s) prevented determining whether this is a repeat independent-verification failure."
                    Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "crucible" -Outcome "unreadable_retry_history" -Notes $unreadableRetryHistoryReason `
                        -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                    Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "unreadable_retry_history" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist "verification" -Summary $unreadableRetryHistoryReason
                    Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "unreadable_retry_history" `
                        -Why $unreadableRetryHistoryReason
                    exit 2
                } else {
                    Write-EventLog -Event "quality_gate_retry" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                        -Outcome "retry_required" -Notes ("Verification check failed in worktree: " + $failedCheck) `
                        -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                    Write-Host "[STOP] Verification quality gate failed: $failedCheck exits non-zero." -ForegroundColor Red
                    if ($testOutput) {
                        Write-Host "  Check output:" -ForegroundColor Yellow
                        $testOutput | ForEach-Object { Write-Host ("    " + $_) }
                    }
                    Write-Host "Please fix the failing check in the implementation worktree and re-submit the verification handoff." -ForegroundColor Red
                    exit 2
                }
            }
            Write-Quiet "[VERIFY] isolated verification passed independently. APPROVED handoff accepted." -ForegroundColor Green
            Write-EventLog -Event "verified" -TaskId $handoff.task_id -Specialist "crucible" -Outcome "tests_passed" -Notes "Independent isolated verification passed before Operator handoff" `
                -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
        } else {
            Write-Quiet "[VERIFY] No task/$($handoff.task_id) branch and no worktree: no code to verify independently." -ForegroundColor DarkGray
        }
    }
}
