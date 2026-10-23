# Handoff intake: everything that turns an on-disk handoff into validated in-memory state
# before any gate decides anything. Selection, misplaced-file recovery, the one reader that
# binds the handoff to the task, schema and binding preflight, and input normalization.
#
# Enforced here: I4. Restore-MisplacedHandoff runs before Read-CrucibleHandoffContext, the one
# reader, so a recovered file gets the same task binding, counts and ceiling as any other
# selection. docs/policy.md section 8.
#
# Loaded by crucible-gates.ps1. The functions it calls from that file (Get-RootRelativePath,
# Add-AffectedPathCandidate, Assert-CrucibleFrameworkIntegrity) and from
# crucible-gates-breakers.ps1 resolve at call time, so it is not loadable on its own.
. (Join-Path $PSScriptRoot "platform.ps1")
. (Join-Path $PSScriptRoot "injection-detector.ps1")
. (Join-Path $PSScriptRoot "backlog-io.ps1")
. (Join-Path $PSScriptRoot "crucible-context.ps1")
. (Join-Path $PSScriptRoot "worktree.ps1")
. (Join-Path $PSScriptRoot "crucible-gates-wedge-report.ps1")

function Resolve-CrucibleInputHandoff {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-CrucibleContextKeys -Context $Context `
        -RequiredKeys @("TaskId", "HandoffDir", "BacklogDir", "Quiet") `
        -NonNullKeys @("LogFile", "CircuitBreakerHistoryFile")

    $TaskId = $Context.TaskId
    $HANDOFF_DIR = $Context.HandoffDir
    $backlogDir = $Context.BacklogDir
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile
    $Quiet = [bool]$Context.Quiet

    if (-not (Test-Path $HANDOFF_DIR)) {
        New-Item -ItemType Directory -Path $HANDOFF_DIR -Force | Out-Null
    }

    Mark-DuplicateHandoffsAsSuperseded -TaskId $TaskId -HandoffDir $HANDOFF_DIR

    if (-not [string]::IsNullOrEmpty($TaskId)) {
        # Scoped: find the latest non-superseded handoff for THIS task only
        $taskCandidates = @(Get-ChildItem -Path $HANDOFF_DIR -Filter ($TaskId + "-*.json"))
        $taskCandidates = @(Sort-HandoffFiles -Files $taskCandidates)
        $latestHandoff = $null
        foreach ($candidate in $taskCandidates) {
            try {
                $candidateObj = Get-Content -Path $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not ($candidateObj.PSObject.Properties["superseded"] -and $candidateObj.superseded -eq $true)) {
                    $latestHandoff = $candidate
                    break
                }
            } catch {
                Write-Quiet ("[HANDOFF] Warning: Could not parse candidate handoff: " + $candidate.Name) -ForegroundColor Yellow
            }
        }
        if (-not $latestHandoff) {
            # Check archived handoffs directory before auto-bootstrapping
            $archivedHandoffDir = Join-Path $HANDOFF_DIR "archived"
            if (Test-Path -LiteralPath $archivedHandoffDir) {
                $archivedCandidates = @(Get-ChildItem -Path $archivedHandoffDir -Filter ($TaskId + "-*.json"))
                $archivedCandidates = @(Sort-HandoffFiles -Files $archivedCandidates)
                foreach ($candidate in $archivedCandidates) {
                    try {
                        $candidateObj = Get-Content -Path $candidate.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                        if (-not ($candidateObj.PSObject.Properties["superseded"] -and $candidateObj.superseded -eq $true)) {
                            $latestHandoff = $candidate
                            break
                        }
                    } catch {
                        Write-Quiet ("[HANDOFF] Warning: Could not parse archived candidate handoff: " + $candidate.Name) -ForegroundColor Yellow
                    }
                }
            }
        }
        if (-not $latestHandoff) {
            # Auto-bootstrap initial tasks
            $specPath = Get-BacklogItemPathForTaskProjectRoot -Task $TaskId -ProjectRoot $(if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { "" })
            if (([string]::IsNullOrWhiteSpace($specPath) -or -not (Test-Path $specPath)) -and -not [string]::IsNullOrWhiteSpace($backlogDir)) {
                $typeDir = if ($TaskId -match "^F-") {
                    "features"
                } elseif ($TaskId -match "^B-") {
                    "bugs"
                } elseif ($TaskId -match "^C-") {
                    "chores"
                } else {
                    ""
                }
                $typeDirs = if ([string]::IsNullOrWhiteSpace($typeDir)) {
                    @("features", "bugs", "chores")
                } else {
                    @($typeDir)
                }
                foreach ($dir in $typeDirs) {
                    $activeMatch = Get-BacklogSpecFiles -Task $TaskId -Directory (Join-Path $backlogDir ($dir + "/active")) | Select-Object -First 1
                    if ($null -ne $activeMatch) {
                        $specPath = $activeMatch.FullName
                        break
                    }
                    $rootMatch = Get-BacklogSpecFiles -Task $TaskId -Directory (Join-Path $backlogDir $dir) | Select-Object -First 1
                    if ($null -ne $rootMatch) {
                        $specPath = $rootMatch.FullName
                        break
                    }
                    $archivedMatch = Get-BacklogSpecFiles -Task $TaskId -Directory (Join-Path $backlogDir ($dir + "/archived")) -Recurse | Select-Object -First 1
                    if ($null -ne $archivedMatch) {
                        $specPath = $archivedMatch.FullName
                        break
                    }
                }
            }
            if ($specPath -and (Test-Path $specPath)) {
                $targetPhase = "grooming"
                $budgetTier = "low"

                # Read budget_tier from frontmatter
                $frontmatter = Get-Content -LiteralPath $specPath -Head 20
                foreach ($line in $frontmatter) {
                    if ($line -match '^\s*budget_tier:\s*"?(\w+)"?\s*$') {
                        $budgetTier = $matches[1].ToLowerInvariant()
                    }
                }

                $timestamp = Get-UtcFileTimestamp
                $bootstrapFile = Join-Path $HANDOFF_DIR "$TaskId-$timestamp.json"
                $bootstrapBaseCommit = $null
                if (Test-Path .git) {
                    try {
                        $commit = (git rev-parse HEAD 2>$null)
                        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($commit)) {
                            $bootstrapBaseCommit = $commit.Trim()
                        }
                    } catch {}
                }

                $bootstrapHandoff = [ordered]@{
                    task_id                  = $TaskId
                    source_phase             = "deployment"
                    target_phase             = $targetPhase
                    cumulative_handoff_count = 1
                    handoff_retry_count      = 0
                    review_strike_count      = 0
                    rebase_count             = 0
                    budget_tier              = $budgetTier
                    reason                   = "Initial task bootstrap"
                    artifacts                = @()
                    file_affinity            = @()
                    prompt_version           = "1.0.0"
                    session_cycle_id         = "initial"
                    commit_hash              = $null
                    base_commit              = $bootstrapBaseCommit
                    generated_by             = "new-handoff.ps1"
                    tool_version             = "1.0.0"
                }
                # Log session_start for operator bootstrap to prevent "missing_start_event" anomaly
                Write-EventLog -Event "session_start" -TaskId $TaskId -Phase "deployment" -HandoffCount 1 -CycleId "initial" -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                [System.IO.File]::WriteAllText(
                    $bootstrapFile,
                    ($bootstrapHandoff | ConvertTo-Json -Depth 12),
                    (New-Object System.Text.UTF8Encoding $false)
                )

                $latestHandoff = Get-Item $bootstrapFile
                $Context.IsBootstrap = $true
                Write-Quiet "[INIT] No handoff found for task $TaskId; auto-bootstrapped initial handoff from deployment to $targetPhase at $bootstrapFile" -ForegroundColor Green
            } else {
                # With no handoff, the spec is what -Init needs; naming only the handoff
                # sent R-033 down a hand-written bootstrap instead.
                Write-Host ("Error: No active (non-superseded) handoff and no backlog spec found for TaskId: " + $TaskId) -ForegroundColor Red
                if ([string]::IsNullOrWhiteSpace($backlogDir)) {
                    Write-Host "No backlog directory is configured, so no spec could be searched for." -ForegroundColor Red
                } else {
                    $searched = @(foreach ($dir in $typeDirs) {
                        foreach ($sub in @("$dir/active", $dir, "$dir/archived (recursive)")) {
                            "  " + (Join-Path $backlogDir $sub)
                        }
                    })
                    Write-Host ("Looked for " + $TaskId + "_*.md or " + $TaskId + ".md in:") -ForegroundColor Red
                    $searched | ForEach-Object { Write-Host $_ -ForegroundColor Red }
                }
                $bootstrapParameters = [ordered]@{ Init = $true; TaskId = $TaskId; ProjectRoot = (Get-RecoveryProjectRoot -Context $Context) }
                $bootstrapCommand = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters $bootstrapParameters -CrucibleRoot (Get-RecoveryCrucibleRoot -Context $Context) -Invoker "pwsh -ExecutionPolicy Bypass -File"
                $bootstrapReference = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters $bootstrapParameters -Reference
                Write-Host ("Write the spec there, then rerun " + $bootstrapReference + "; it bootstraps the task from the spec. Command: " + $bootstrapCommand) -ForegroundColor Red
                exit 1
            }
        }
    } else {
        # Unscoped: legacy behavior - pick globally newest handoff
        $latestHandoff = Get-ChildItem -Path $HANDOFF_DIR -Filter "*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }

    if (-not $latestHandoff) {
        Write-Host "Error: No handoff.json found in $HANDOFF_DIR" -ForegroundColor Red
        exit 1
    }

    $Context.LatestHandoff = $latestHandoff
}

function Restore-MisplacedHandoff {
    # Agents sometimes write handoff.json to local session paths instead of the handoff
    # directory. Move a misplaced file that is newer than the selected handoff into place and
    # select it. This runs before Read-CrucibleHandoffContext so the recovered file gets the
    # same task binding check, counts and ceiling as any other selection. Item 223.
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-CrucibleContextKeys -Context $Context -RequiredKeys @("TaskId", "SessionDir", "HandoffDir") `
        -NonNullKeys @("LatestHandoff")

    $TaskId = $Context.TaskId
    if ([string]::IsNullOrEmpty($TaskId)) { return }
    $sessionDir = $Context.SessionDir
    $misplacedPaths = @(
        (Join-Path $sessionDir "$TaskId/handoff.json"),
        (Join-Path $sessionDir "$TaskId/architect/handoff.json"),
        (Join-Path $sessionDir "$TaskId/reviewer/handoff.json"),
        (Join-Path $sessionDir "$TaskId/operator/handoff.json"),
        (Join-Path $sessionDir "$TaskId/groomer/handoff.json")
    )
    foreach ($mp in $misplacedPaths) {
        if (Test-Path $mp) {
            $mpItem = Get-Item $mp
            if ($mpItem.LastWriteTime -gt $Context.LatestHandoff.LastWriteTime) {
                Write-Host "[WARN] Misplaced handoff at $mp (newer than active handoff) - agent wrote to wrong location. Auto-recovering by moving to handoffs directory." -ForegroundColor Yellow
                $timestamp = Get-UtcFileTimestamp
                $newPath = Join-Path $Context.HandoffDir "$TaskId-$timestamp.json"
                Move-Item -Path $mp -Destination $newPath -Force
                $Context.LatestHandoff = Get-Item $newPath
            }
        }
    }
}

function Read-CrucibleHandoffContext {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    # No CircuitBreakerHistoryFile: this function reads the pipeline log and writes no
    # event, so requiring the breaker path would be a contract it never exercises.
    Assert-CrucibleContextKeys -Context $Context -RequiredKeys @("BudgetCeilings") `
        -NonNullKeys @("LatestHandoff", "LogFile")

    $latestHandoff = $Context.LatestHandoff
    $handoffFile = $latestHandoff.FullName
    $budgetCeilings = $Context.BudgetCeilings
    if ($null -eq $budgetCeilings) {
        $budgetCeilings = Get-BudgetCeilings
    }
    $ceiling = $null
    $invalidBudgetTier = ""
    $tierKey = ""
    $LOG_FILE = $Context.LogFile

    try {
        $handoffRaw = Get-Content $handoffFile -Raw -Encoding UTF8
        $handoff = $handoffRaw | ConvertFrom-Json

        # Default missing optional counters to prevent StrictMode crash (Part C)
        foreach ($counter in @("review_strike_count", "rebase_count", "handoff_retry_count", "cumulative_handoff_count")) {
            if ($null -eq $handoff.PSObject.Properties[$counter]) {
                $defaultVal = if ($counter -eq "cumulative_handoff_count") { 1 } else { 0 }
                $handoff | Add-Member -MemberType NoteProperty -Name $counter -Value $defaultVal -Force
            }
        }

        # legacy compat read of pre-rename event log / handoff
        if (-not $handoff.PSObject.Properties["source_phase"] -and $handoff.PSObject.Properties["source_specialist"]) {
            $legacy = $handoff.source_specialist.ToLowerInvariant()
            $phase = if ($legacy -eq "groomer") { "grooming" }
                     elseif ($legacy -eq "architect") { "implementation" }
                     elseif ($legacy -eq "reviewer") { "verification" }
                     elseif ($legacy -eq "operator") { "deployment" }
                     elseif ($legacy -eq "researcher") { "research" }
                     else { $legacy }
            $handoff | Add-Member -MemberType NoteProperty -Name "source_phase" -Value $phase -Force
        }
        # legacy compat read of pre-rename event log / handoff
        if (-not $handoff.PSObject.Properties["target_phase"] -and $handoff.PSObject.Properties["target_specialist"]) {
            $legacy = $handoff.target_specialist.ToLowerInvariant()
            $phase = if ($legacy -eq "groomer") { "grooming" }
                     elseif ($legacy -eq "architect") { "implementation" }
                     elseif ($legacy -eq "reviewer") { "verification" }
                     elseif ($legacy -eq "operator") { "deployment" }
                     elseif ($legacy -eq "researcher") { "research" }
                     elseif ($legacy -eq "done") { "done" }
                     else { $legacy }
            $handoff | Add-Member -MemberType NoteProperty -Name "target_phase" -Value $phase -Force
        }

        if (-not $handoff.PSObject.Properties["prompt_version"]) {
            $handoff | Add-Member -MemberType NoteProperty -Name "prompt_version" -Value "1.0.0" -Force
        }

        $Context.IsBootstrap = ($handoff.psobject.Properties["reason"] -and $handoff.reason -eq "Initial task bootstrap") -and ($handoff.psobject.Properties["cumulative_handoff_count"] -and $handoff.cumulative_handoff_count -eq 1)
    } catch {
        Write-Host "Error: Failed to parse handoff file $handoffFile" -ForegroundColor Red
        Write-Host $_.Exception.Message
        exit 1
    }

    # The handoff is chosen by its filename, but everything after this routes, merges and
    # logs by the task_id inside it, so the two must name the same task. Item 185.
    $selectedTaskId = if ($Context.ContainsKey("TaskId")) { [string]$Context.TaskId } else { "" }
    $handoffTaskId = if ($handoff.PSObject.Properties["task_id"]) { ([string]$handoff.task_id).Trim() } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($selectedTaskId) -and $handoffTaskId -ne $selectedTaskId.Trim()) {
        Write-Host ("[STOP] Handoff $handoffFile was selected for task $selectedTaskId but its task_id is '" + $handoffTaskId + "'.") -ForegroundColor Red
        Write-Host "       A handoff must be filed under its own task. Remove or move the file, then rerun." -ForegroundColor Red
        exit 2
    }

    # Compute $ceiling unconditionally so prompt assembly never shows "unknown" on re-runs (Fix 8)
    if ($handoff.psobject.Properties["budget_tier"] -and $handoff.budget_tier) {
        $tierKey = ([string]$handoff.budget_tier).Trim().ToLowerInvariant()
        if ($budgetCeilings.ContainsKey($tierKey)) {
            $ceiling = $budgetCeilings[$tierKey]
        } else {
            $invalidBudgetTier = $tierKey
        }
    }

    # Server-side handoff count - agent-reported values cannot be trusted for circuit breakers (Fix 2)
    # A line that will not parse is a session_end this scan may never see, so the result is a
    # lower bound rather than a count, and the override below can fail to fire. Carry the miss
    # count out instead of absorbing it; Invoke-CircuitBreakerGates decides whether the gap is
    # wide enough to change the ceiling answer. Blank lines are skipped before the parse:
    # ConvertFrom-Json rejects an empty string, and under $ErrorActionPreference = "Stop" that
    # reaches the catch, so a log ending in a stray newline would otherwise report a miss and
    # spend a task's remaining headroom on its own formatting.
    $logDerivedCount = 0
    $logParseFailureCount = 0
    if (Test-Path $LOG_FILE) {
        Get-Content $LOG_FILE -Encoding UTF8 | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) {
                try {
                    $cleanedLine = $_ -replace "^$([char]0xFEFF)", ""
                    $entry = $cleanedLine | ConvertFrom-Json
                    if ($entry.task_id -eq $handoff.task_id -and $entry.event -eq "session_end" -and $entry.cycle_id -ne "test-cycle") { $logDerivedCount++ }
                } catch {
                    $logParseFailureCount++
                }
            }
        }
    }
    if ($logDerivedCount -gt [int]$handoff.cumulative_handoff_count) {
        Write-Host "[WARN] Agent-reported cumulative_handoff_count ($($handoff.cumulative_handoff_count)) < log-derived count ($logDerivedCount). Overriding to prevent budget bypass." -ForegroundColor Yellow
        $handoff.cumulative_handoff_count = $logDerivedCount
    }

    $Context.Handoff = $handoff
    $Context.BudgetCeilings = $budgetCeilings
    $Context.Ceiling = $ceiling
    $Context.BudgetTierKey = $tierKey
    $Context.InvalidBudgetTier = $invalidBudgetTier
    $Context.CumulativeHandoffCount = [int]$handoff.cumulative_handoff_count
    $Context.HandoffLogParseFailureCount = $logParseFailureCount
    $resolvedRoot = (Resolve-Path -LiteralPath $Context.RepoRoot).Path.TrimEnd("\", "/")
    $resolvedPath = (Resolve-Path -LiteralPath $handoffFile).Path
    $Context.RelativeHandoffPath = Get-RootRelativePath -Root $resolvedRoot -Path $resolvedPath
}

function Invoke-HandoffPreflightValidation {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-CrucibleContextKeys -Context $Context `
        -RequiredKeys @("TaskId", "SessionDir", "HandoffDir", "CrucibleRoot", "Init", "Quiet", "LatestHandoff") `
        -NonNullKeys @("FrameworkPowerShell", "LogFile", "CircuitBreakerHistoryFile")

    $sessionDir = $Context.SessionDir
    $HANDOFF_DIR = $Context.HandoffDir
    $FRAMEWORK_POWERSHELL = $Context.FrameworkPowerShell
    $crucibleRoot = $Context.CrucibleRoot
    $Init = [bool]$Context.Init
    $Quiet = [bool]$Context.Quiet
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile
    $latestHandoff = $Context.LatestHandoff
    $handoff = $Context.Handoff
    $handoffFile = $latestHandoff.FullName

    Assert-CrucibleFrameworkIntegrity -Context $Context


    $preflightScript = "$FRAMEWORK_POWERSHELL/validate-handoff.ps1"
    if (-not (Test-Path $preflightScript)) {
        $missingReasonCode = "missing_required_field"
        $handoffFileName = Split-Path -Leaf $handoffFile
        Write-EventLog -Event "preflight_failed" -TaskId $handoff.task_id -Specialist "crucible" `
            -Outcome $missingReasonCode -Notes ("reason_code=" + $missingReasonCode + "; handoff_file=" + $handoffFileName + "; message=Validator script missing") `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
        Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode $missingReasonCode `
            -Why ("reason_code=" + $missingReasonCode + "; handoff_file=" + $handoffFileName + "; message=Validator script missing: powershell/validate-handoff.ps1") `
            -RecoveryOverride ("Restore powershell/validate-handoff.ps1 from the Crucible bundle, then rerun: " + (New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters ([ordered]@{ Init = $true; TaskId = $handoff.task_id; ProjectRoot = (Get-RecoveryProjectRoot -Context $Context) }) -CrucibleRoot (Get-RecoveryCrucibleRoot -Context $Context) -Invoker "pwsh -ExecutionPolicy Bypass -File"))
        exit 2
    }

    $preflightRaw = & $preflightScript -HandoffFile $handoffFile -SchemaPath (Join-Path (Split-Path -Parent $FRAMEWORK_POWERSHELL) "schemas/handoff.schema.json") 2>&1
    $preflightExit = $LASTEXITCODE
    $preflightResult = $null
    try {
        $preflightResult = ($preflightRaw | Out-String).Trim() | ConvertFrom-Json
    } catch {
        $preflightResult = $null
    }

    $preflightOk = $false
    if ($null -ne $preflightResult -and $preflightResult.PSObject.Properties["ok"]) {
        $preflightOk = [bool]$preflightResult.ok
    }

    if ($preflightExit -ne 0 -or -not $preflightOk) {
        $reasonCode = "missing_required_field"
        $errorMessage = "Preflight validation failed."
        if ($null -ne $preflightResult) {
            if ($preflightResult.PSObject.Properties["reason_code"] -and -not [string]::IsNullOrWhiteSpace([string]$preflightResult.reason_code)) {
                $reasonCode = [string]$preflightResult.reason_code
            }
            if ($preflightResult.PSObject.Properties["message"] -and -not [string]::IsNullOrWhiteSpace([string]$preflightResult.message)) {
                $errorMessage = [string]$preflightResult.message
            }
        }

        $allowRuntimeCommitHashVerification = $false
        if ($handoff.source_phase -eq "deployment" -and
            $reasonCode -eq "missing_required_field" -and
            $errorMessage -match "commit_hash") {
            $allowRuntimeCommitHashVerification = $true
        }

        if ($allowRuntimeCommitHashVerification) {
            Write-Quiet "[PREFLIGHT] Deferring operator commit_hash enforcement to merge-verification gate." -ForegroundColor DarkGray
        } else {
            $handoffFileName = Split-Path -Leaf $handoffFile
            Write-EventLog -Event "preflight_failed" -TaskId $handoff.task_id -Specialist "crucible" `
                -Outcome $reasonCode -Notes ("reason_code=" + $reasonCode + "; handoff_file=" + $handoffFileName + "; message=" + $errorMessage) `
                -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode $reasonCode `
                -Why ("reason_code=" + $reasonCode + "; handoff_file=" + $handoffFileName + "; message=" + $errorMessage)
            exit 2
        }
    }

    # D19: Cross-check file_affinity in handoff against spec's affected files section
    if ($handoff.psobject.Properties["file_affinity"] -and $handoff.file_affinity -ne $null -and @($handoff.file_affinity).Count -gt 0) {
        $specFile = Get-BacklogItemPathForTaskProjectRoot -Task $handoff.task_id -ProjectRoot $Context.RepoRoot
        if ($specFile -and (Test-Path $specFile)) {
            $specContent = Get-Content $specFile -Raw -Encoding UTF8
            # The frontmatter is the one record of scope, so it is checked first and at path
            # granularity. The prose section is the fallback for specs without it, and only
            # its top-level directories can be trusted from free text.
            $frontmatterAffinity = @(Get-SpecFrontmatterAffinity -SpecContent $specContent)
            $hasAffectedSection = $false
            $affectedSection = ""
            $affectedMatches = [regex]::Matches($specContent, '(?ism)^##+\s+[^\r\n]*(?:affected|scope)[^\r\n]*\r?\n(.*?)(?=\r?\n##+\s+|\z)')
            if ($affectedMatches.Count -gt 0) {
                $bodies = @()
                foreach ($m in $affectedMatches) {
                    $headingLine = ($m.Value -split '\r?\n')[0]
                    if ($headingLine -match 'out\s*-\s*of\s*-\s*scope' -or $headingLine -match 'out\s+of\s+scope') {
                        continue
                    }
                    $body = $m.Groups[1].Value
                    if (-not [string]::IsNullOrWhiteSpace($body)) {
                        $bodies += $body
                    }
                }
                if ($bodies.Count -gt 0) {
                    $affectedSection = $bodies -join "`n"
                    $hasAffectedSection = $true
                }
            }

            if ($frontmatterAffinity.Count -gt 0) {
                $widened = @(Get-AffinityWidening -Affinity @($handoff.file_affinity) -Declared $frontmatterAffinity)
                if ($widened.Count -gt 0) {
                    $joinedWidened = $widened -join ", "
                    $joinedSpec = $frontmatterAffinity -join ", "
                    Write-Host "[WARN] Handoff file_affinity ($joinedWidened) is not covered by the spec's frontmatter file_affinity ($joinedSpec). The frontmatter is the record of scope: add the widened paths to file_affinity in $specFile, or narrow the handoff." -ForegroundColor Yellow
                    Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist "crucible" `
                        -Outcome "warned" -Kind "file_affinity_scope" -Notes "Handoff file_affinity contains paths ($joinedWidened) not covered by spec frontmatter ($joinedSpec)" `
                        -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                } else {
                    Write-Host "[INFO] Handoff file_affinity validated against spec's frontmatter file_affinity." -ForegroundColor Green
                }
            } elseif ($hasAffectedSection) {
                $mentionedPaths = New-Object System.Collections.ArrayList
                $backtickMatches = [regex]::Matches($affectedSection, '`([^`\r\n]+)`')
                foreach ($m in $backtickMatches) {
                    Add-AffectedPathCandidate -Candidates $mentionedPaths -Candidate $m.Groups[1].Value -RepoRoot $Context.RepoRoot
                }
                $listMatches = [regex]::Matches($affectedSection, '(?m)^\s*-\s+([^\r\n]+)')
                foreach ($m in $listMatches) {
                    $val = $m.Groups[1].Value.Trim() -replace '`','' -replace '\*',''
                    Add-AffectedPathCandidate -Candidates $mentionedPaths -Candidate $val -RepoRoot $Context.RepoRoot
                }

                $specTopLevels = @()
                foreach ($p in $mentionedPaths) {
                    $parts = $p -split '[/\\]'
                    if ($parts.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($parts[0])) {
                        $specTopLevels += $parts[0].Trim()
                    }
                }
                $specTopLevels = @($specTopLevels | Select-Object -Unique)

                if ($specTopLevels.Count -gt 0) {
                    $overbroad = @()
                    foreach ($aff in @($handoff.file_affinity)) {
                        $affTrimmed = $aff.Trim().Trim('/') -split '[/\\]'
                        if ($affTrimmed.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($affTrimmed[0])) {
                            $top = $affTrimmed[0]
                            if ($top -match '\.[A-Za-z0-9]{2,4}$') {
                                continue
                            }
                            if ($specTopLevels -notcontains $top) {
                                $overbroad += $aff
                            }
                        }
                    }

                    if ($overbroad.Count -gt 0) {
                        $joinedOverbroad = $overbroad -join ", "
                        $joinedSpec = $specTopLevels -join ", "
                        Write-Host "[WARN] Handoff file_affinity ($joinedOverbroad) lists top-level directories absent from the spec's 'affected files' section ($joinedSpec)." -ForegroundColor Yellow
                        Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist "crucible" `
                            -Outcome "warned" -Kind "file_affinity_scope" -Notes "Handoff file_affinity contains paths ($joinedOverbroad) not mentioned in spec ($joinedSpec)" `
                            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                    }
                }
            } else {
                # D23: Spec has no affected-files/packages section to validate file_affinity against
                Write-Host "[WARN] Spec file does not declare an 'Affected Files' or 'Affected Packages' section. File affinity cannot be validated." -ForegroundColor Yellow
                Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist "crucible" `
                    -Outcome "unverifiable" -Kind "file_affinity_unverifiable" -Notes "Spec file does not declare an affected files/packages section to validate file_affinity against." `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            }
        }
    }

    # Construct the standard session-end command. Use absolute paths so orchestrators can drive
    # specialists from outside the adopter repository without depending on their current directory.
    $resolvedCrucibleRoot = if ([System.IO.Path]::IsPathRooted($crucibleRoot)) { $crucibleRoot } else { Join-Path $Context.RepoRoot $crucibleRoot }
    $pwshCmd = Get-PwshCommand
    $Context.NextCrucibleCommand = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters ([ordered]@{ Init = $true; TaskId = $handoff.task_id; ProjectRoot = $Context.RepoRoot; Quiet = $true }) -CrucibleRoot $resolvedCrucibleRoot -Transport Bash -Invoker ($pwshCmd + " -NoProfile -ExecutionPolicy Bypass -File")

    # Read the expected cycle from the source task.md, not the handoff being checked,
    # so a handoff cannot validate its own session_cycle_id. Item 186.
    $sourceTaskMd = Join-Path $sessionDir ([string]$handoff.task_id + "/" + [string]$handoff.source_phase + "/task.md")
    $issuedCycleId = ""
    if (Test-Path -LiteralPath $sourceTaskMd) {
        $cycleLine = @(Get-Content -LiteralPath $sourceTaskMd -Encoding UTF8 -TotalCount 10 | Where-Object { $_ -match '^Cycle ID:\s*(\S+)\s*$' } | Select-Object -First 1)
        if ($cycleLine.Count -gt 0 -and $cycleLine[0] -match '^Cycle ID:\s*(\S+)\s*$') { $issuedCycleId = $matches[1] }
    }
    if (-not [string]::IsNullOrEmpty($issuedCycleId)) {
        $env:CRUCIBLE_CYCLE_ID = $issuedCycleId
    } elseif ($handoff.psobject.Properties["cycle_id"] -and -not [string]::IsNullOrEmpty($handoff.cycle_id)) {
        $env:CRUCIBLE_CYCLE_ID = $handoff.cycle_id
    } elseif ($handoff.psobject.Properties["session_cycle_id"] -and -not [string]::IsNullOrEmpty($handoff.session_cycle_id)) {
        $env:CRUCIBLE_CYCLE_ID = $handoff.session_cycle_id
    } else {
        $env:CRUCIBLE_CYCLE_ID = [System.Guid]::NewGuid().ToString("N").Substring(0, 8)
    }

    if ($Init) {
        # 1. Check for stale gate pending files for OTHER tasks
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        if (Test-Path $gateDir) {
            $otherPending = Get-ChildItem -Path $gateDir -Filter "gate_decision_*_pending.json" |
                Where-Object { $_.Name -notmatch ("gate_decision_" + [regex]::Escape($handoff.task_id) + "_pending\.json") }

            foreach ($stale in $otherPending) {
                if ($stale.Name -match 'gate_decision_([A-Z0-9\-]+)_pending\.json') {
                    $otherTaskId = $matches[1]
                    Write-Quiet ("[GATE] Warning: Stale gate pending file detected for $($otherTaskId). Run -Cleanup to preview cleanup or -Cleanup -Force to remove it.") -ForegroundColor Yellow
                }
            }
        }

        $allTaskHandoffs = @(Get-ChildItem -Path $HANDOFF_DIR -Filter ($handoff.task_id + "-*.json"))
        $staleTaskHandoffs = @()
        foreach ($file in $allTaskHandoffs) {
            try {
                $content = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($content.PSObject.Properties["session_cycle_id"] -and $content.session_cycle_id -ne $env:CRUCIBLE_CYCLE_ID) {
                    $staleTaskHandoffs += $file
                }
            } catch {}
        }
        if ($staleTaskHandoffs.Count -gt 0) {
            Write-Quiet ("[HANDOFF] Warning: Found $($staleTaskHandoffs.Count) previous handoff files for $($handoff.task_id) that may be stale.") -ForegroundColor Yellow
        }
    }
}

# A lock belongs to a task and phase only when both appear in its name as whole
# identifiers, task first. A bare substring match let F-1 delete F-10's locks. Item 282.
function Test-LockNameForTaskPhase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Phase)) { return $false }
    $pattern = '(?<![A-Za-z0-9])' + [regex]::Escape($TaskId) + '(?![A-Za-z0-9]|\.[0-9]).*(?<![A-Za-z0-9])' + [regex]::Escape($Phase) + '(?![A-Za-z0-9])'
    return ($Name -match $pattern)
}

function Normalize-CrucibleInputState {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-CrucibleContextKeys -Context $Context -RequiredKeys @() `
        -NonNullKeys @("Handoff", "LatestHandoff", "SessionDir", "Recover", "FrameworkPowerShell", "LogFile", "CircuitBreakerHistoryFile")

    $handoff = $Context.Handoff
    $latestHandoff = $Context.LatestHandoff
    $sessionDir = $Context.SessionDir
    $Recover = [bool]$Context.Recover
    $FRAMEWORK_POWERSHELL = $Context.FrameworkPowerShell
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile

    $handoffFile = $latestHandoff.FullName
    $handoffRaw = Get-Content $handoffFile -Raw -Encoding UTF8

    # --- Artifact Path Normalization (D25) ---
    if ($handoff.psobject.Properties["artifacts"] -and $null -ne $handoff.artifacts -and @($handoff.artifacts).Count -gt 0) {
        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { Resolve-ConfigProjectRoot }
        $workspacesDir = if ($Context.ContainsKey("WorkspacesDir")) { $Context.WorkspacesDir } else { Get-ConfiguredPath -Key "workspaces" -ProjectRoot $repoRoot }
        $wtPath = Resolve-ImplementationWorktreePath -TaskId $handoff.task_id -WorkspacesDir $workspacesDir

        $normalizedArtifacts = @(Normalize-HandoffArtifactPaths -Artifacts $handoff.artifacts -WorktreePath $wtPath -ProjectRoot $repoRoot)

        $originalArtifacts = @($handoff.artifacts)
        $hasChanged = $false
        if ($originalArtifacts.Count -ne $normalizedArtifacts.Count) {
            $hasChanged = $true
        } else {
            for ($k = 0; $k -lt $originalArtifacts.Count; $k++) {
                if ($originalArtifacts[$k] -ne $normalizedArtifacts[$k]) {
                    $hasChanged = $true
                    break
                }
            }
        }

        if ($hasChanged) {
            $handoff.artifacts = [string[]]$normalizedArtifacts
            # Serialize cleanly with no unrolling/scalar conversions (explicitly cast $handoff if needed)
            $handoffJson = $handoff | ConvertTo-Json -Depth 100
            [System.IO.File]::WriteAllText($handoffFile, $handoffJson, (New-Object System.Text.UTF8Encoding $false))
        }
    }

    # --- 2a. Sanitize Inputs ---
    # Prevent prompt injection or confusing formatting in the reason
    $handoff.reason = ConvertTo-AsciiSafeText -Text $handoff.reason
    $handoff.reason = $handoff.reason -replace '[\r\n]+', ' ' -replace '"', "'" -replace '[#*`]', ''
    $handoff.reason = $handoff.reason.Trim()
    if ($handoff.reason.Length -gt 250) {
        $handoff.reason = $handoff.reason.Substring(0, 247) + "..."
    }

    # --- 2b. Passive Injection Pattern Scan ---
    $detectedMatches = Get-InjectionMatches -Text $handoffRaw
    if ($detectedMatches.Count -gt 0) {
        foreach ($match in $detectedMatches) {
            Write-EventLog -Event "security_warning" -TaskId $handoff.task_id -Specialist $handoff.source_phase -Outcome "warned" -Notes ("Injection pattern detected: " + $match.RuleId) `
                -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            Write-Quiet "`n[SECURITY WARNING] Potential injection pattern detected in handoff from $($handoff.source_phase)." -ForegroundColor Yellow
            Write-Quiet ("Pattern matched: " + $match.RuleId) -ForegroundColor Yellow
            Write-Quiet ("Review handoff file: " + $handoffFile) -ForegroundColor White
        }

        # Only block-severity matches hard-stop a research handoff. warn-severity rules
        # (FP-prone heuristics like base64/act-as) must not hard-block legitimate research;
        # they warn and proceed, consistent with the artifact scan below.
        $blockMatches = @($detectedMatches | Where-Object { $_.Severity -eq "block" })
        if ($handoff.source_phase -eq "research" -and $blockMatches.Count -gt 0) {
            Write-Host "`n[STOP] Researcher handoffs with injection patterns require human review before proceeding." -ForegroundColor Red
            exit 2
        }
        Write-Quiet "[WARN] Proceeding - human should review console output above.`n" -ForegroundColor Yellow
    }

    # --- 2c. State Sanitization ---
    # Clear stale locks and scratchpads for the target phase to prevent "zombie state"
    $LOCK_DIR = ".crucible/locks"
    if (Test-Path $LOCK_DIR) {
        $staleLocks = @(Get-ChildItem -Path $LOCK_DIR -File | Where-Object { Test-LockNameForTaskPhase -Name $_.Name -TaskId $handoff.task_id -Phase $handoff.target_phase })
        if ($staleLocks) {
            Write-Quiet ("[CLEANUP] Removing stale locks for " + $handoff.task_id + " " + $handoff.target_phase + "...") -ForegroundColor Cyan
            $staleLocks | Remove-Item -Force
        }
    }

    if (-not [string]::IsNullOrEmpty($Context.TaskId)) {
        $targetDir = Join-Path $sessionDir ($Context.TaskId + "/" + $handoff.target_phase)
    } else {
        $targetDir = Join-Path $sessionDir $handoff.target_phase
    }

    if (Test-Path $targetDir) {
        $staleTask = Join-Path $targetDir "task.md"
        # A rerun on the handoff that created this session must keep task.md: it may hold
        # checkpoints, and the recreate step runs only after minutes of isolated verification.
        $ownedByThisHandoff = $false
        if (Test-Path $staleTask) {
            $handoffLine = Select-String -Path $staleTask -Pattern '^Handoff:\s+(\S+)' -List -Encoding UTF8
            if ($handoffLine -and (Split-Path $handoffLine.Matches[0].Groups[1].Value -Leaf) -eq $latestHandoff.Name) {
                $ownedByThisHandoff = $true
            }
        }
        if ($ownedByThisHandoff) {
            Write-Quiet ("[INIT] Keeping task.md for " + $handoff.target_phase + ": it was created from this handoff.") -ForegroundColor Gray
        } elseif ((Test-Path $staleTask) -and (-not $Recover)) {
            Write-Quiet ("[CLEANUP] Removing stale task.md for " + $handoff.target_phase + "...") -ForegroundColor Cyan
            Remove-Item $staleTask -Force
        }
    }

    # --- 2d. Recovery Mode Logic ---
    $recoveryMarker = "unknown"
    if ($Recover) {
        if ([string]::IsNullOrEmpty($Context.TaskId)) {
            Write-Host "`n[ERROR] -Recover requires -TaskId." -ForegroundColor Red
            exit 1
        }

        $targetDir = Join-Path $sessionDir ($Context.TaskId + "/" + $handoff.target_phase)
        $taskFile = Join-Path $targetDir "task.md"

        if (-not (Test-Path $taskFile)) {
            Write-Host "`n[ERROR] -Recover failed: task.md not found at $taskFile" -ForegroundColor Red
            exit 1
        }

        Write-Quiet "[RECOVERY] Scanning $taskFile for progress..." -ForegroundColor Cyan
        $taskContent = Get-Content $taskFile -Raw -Encoding UTF8
        
        # Check for CHECKPOINT
        $checkpointMatches = [regex]::Matches($taskContent, '### CHECKPOINT\s+(\w+)')
        if ($checkpointMatches.Count -gt 0) {
            $recoveryMarker = $checkpointMatches[$checkpointMatches.Count - 1].Groups[1].Value
        } else {
            # Check for last completed item
            $taskMatches = [regex]::Matches($taskContent, '(?m)^\s*-\s*\[x\]\s*(.+)')
            if ($taskMatches.Count -gt 0) {
                $recoveryMarker = $taskMatches[$taskMatches.Count - 1].Groups[1].Value.Trim()
            }
        }

        Write-Quiet "[RECOVERY] Last progress: $recoveryMarker" -ForegroundColor Green

        # Update state to 'recovering'
        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { Resolve-ConfigProjectRoot }
        $updateJson = @{ status = "recovering" } | ConvertTo-Json -Compress
        & "$FRAMEWORK_POWERSHELL/update-session-state.ps1" -Specialist $handoff.target_phase -TaskId $handoff.task_id -UpdateJson $updateJson -Merge $true -ProjectRoot $repoRoot

        # Log recovery_start for recoverable sessions.
        Write-EventLog -Event "recovery_start" -TaskId $handoff.task_id -Phase $handoff.target_phase -Notes "Recovering from: $recoveryMarker" `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
    }

    $validPhases = @($script:CRUCIBLE_PHASES)
    if ($validPhases -notcontains $handoff.source_phase) {
        Write-Host ("Error: Invalid source_phase " + $handoff.source_phase) -ForegroundColor Red
        exit 1
    }
    if ($validPhases -notcontains $handoff.target_phase -and $handoff.target_phase -ne "done") {
        Write-Host ("Error: Invalid target_phase " + $handoff.target_phase) -ForegroundColor Red
        exit 1
    }
}
