. (Join-Path $PSScriptRoot "injection-detector.ps1")
. (Join-Path $PSScriptRoot "backlog-io.ps1")

$script:WEDGE_RECOVERY_BY_CODE = @{
    human_escalation = "Review the flagged external source or handoff content, make a human allow/block decision, archive the blocked record, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    handoff_retry_exceeded = "Follow docs/circuit-breaker-runbook.md section 'Breaker 3 - Handoff Retry Limit', archive the blocked record, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    review_stalemate = "Follow docs/circuit-breaker-runbook.md section 'Breaker 1 - Review Stalemate (3-Strike Rule)', archive the blocked record, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    budget_exceeded = "Approve a budget_tier escalation, reduce scope, or abandon per docs/circuit-breaker-runbook.md section 'Breaker 4 - Token Budget Exceeded'; after the human decision, run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    recurring_merge_conflicts = "Follow docs/circuit-breaker-runbook.md section 'Breaker 7 - Recurring Merge Conflicts', archive the blocked record, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    reviewer_verification_failed = "Follow docs/circuit-breaker-runbook.md section 'Breaker 5 - Reviewer Verification Failure'; route the exact failing check back to Reviewer or Architect, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    git_hook_bypass = "Follow docs/circuit-breaker-runbook.md section 'Breaker 8 - Git Hook Bypass Attempt'; fix the hook failure without bypassing hooks, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    fabricated_artifacts = "Follow docs/circuit-breaker-runbook.md section 'Breaker 6 - Fabricated Artifacts'; create the missing artifact or correct the handoff JSON, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    scope_violation = "Follow docs/circuit-breaker-runbook.md section 'Breaker 9 - Scope Boundary Violation'; expand file_affinity or revert out-of-scope edits, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    artifact_verification_failed = "Inspect completion artifacts and gate decision state, correct the artifact or decision record, then run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id} -Recover"
    missing_isolated_checks_script = "Restore powershell/run-isolated-checks.ps1 from the Crucible bundle, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    missing_required_field = "Correct the handoff JSON to include the required field, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    invalid_field = "Correct the invalid handoff field according to schemas/handoff.schema.json, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    invalid_json = "Fix the handoff JSON syntax or restore the schema file, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    invalid_transition = "Correct source_phase and target_phase to an allowed pipeline transition, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    invalid_budget_tier = "Set budget_tier to one of: low, medium, high, extended; then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    budget_tier_mismatch = "Make the handoff budget_tier match the spec frontmatter, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
    missing_artifact = "Create the missing artifact or correct the handoff artifact path, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId {task_id}"
}

$script:WEDGE_GUARD_NAME_BY_CODE = @{
    human_escalation = "Human Escalation"
    handoff_retry_exceeded = "Handoff Retry Limit"
    review_stalemate = "Review Stalemate"
    budget_exceeded = "Token Budget Enforcement"
    recurring_merge_conflicts = "Recurring Merge Conflicts"
    reviewer_verification_failed = "Reviewer Verification Failure"
    git_hook_bypass = "Git Hook Bypass Prevention"
    fabricated_artifacts = "Artifact Integrity Gate"
    scope_violation = "Scope Boundary Gate"
    artifact_verification_failed = "Completion Artifact Verification"
    missing_isolated_checks_script = "Isolated Checks Script Required"
    missing_required_field = "Preflight Validation"
    invalid_field = "Preflight Validation"
    invalid_json = "Preflight Validation"
    invalid_transition = "Preflight Validation"
    invalid_budget_tier = "Budget Tier Validation"
    budget_tier_mismatch = "Budget Tier Validation"
    missing_artifact = "Preflight Validation"
}

function Get-WedgeRecoveryCodes {
    return [string[]]($script:WEDGE_RECOVERY_BY_CODE.Keys | Sort-Object)
}

function Get-WedgeRecovery {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$BreakerCode,
        [AllowEmptyString()][string]$TaskId = "",
        [AllowEmptyString()][string]$RecoveryOverride = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($RecoveryOverride)) {
        return $RecoveryOverride
    }

    $code = ""
    if ($null -ne $BreakerCode) {
        $code = $BreakerCode.Trim()
    }

    $recovery = ""
    if (-not [string]::IsNullOrWhiteSpace($code) -and $script:WEDGE_RECOVERY_BY_CODE.ContainsKey($code)) {
        $recovery = [string]$script:WEDGE_RECOVERY_BY_CODE[$code]
    } else {
        $recovery = "No automated recovery is defined. Read docs/circuit-breaker-runbook.md and choose a human resolution before rerunning factory.ps1."
    }

    $replacementTaskId = "{task_id}"
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $replacementTaskId = $TaskId
    }
    return $recovery.Replace("{task_id}", $replacementTaskId)
}

function Get-WedgeBreakerName {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$BreakerCode)

    $code = ""
    if ($null -ne $BreakerCode) {
        $code = $BreakerCode.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($code) -and $script:WEDGE_GUARD_NAME_BY_CODE.ContainsKey($code)) {
        return [string]$script:WEDGE_GUARD_NAME_BY_CODE[$code]
    }
    if ([string]::IsNullOrWhiteSpace($code)) {
        return "Factory Gate"
    }
    return ($code -replace "_", " ")
}

function Get-WedgeReportLines {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SourcePhase,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$TargetPhase,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$BreakerCode,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Why,
        [AllowEmptyString()][string]$RecoveryOverride = ""
    )

    $guardName = Get-WedgeBreakerName -BreakerCode $BreakerCode
    $recovery = Get-WedgeRecovery -BreakerCode $BreakerCode -TaskId $TaskId -RecoveryOverride $RecoveryOverride
    $whyLine = $Why
    if ([string]::IsNullOrWhiteSpace($whyLine)) {
        $whyLine = "No reason supplied."
    }
    $whyLine = $whyLine -replace '[\r\n]+', ' '
    $recovery = $recovery -replace '[\r\n]+', ' '

    return @(
        "",
        "[STOP] HUMAN INTERVENTION REQUIRED",
        ("TASK:     " + $TaskId),
        ("PHASE:    " + $SourcePhase + " -> " + $TargetPhase),
        ("HALTED BY: " + $guardName + " (" + $BreakerCode + ")"),
        ("WHY:      " + $whyLine),
        ("RECOVERY: " + $recovery)
    )
}

function Write-WedgeReport {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SourcePhase,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$TargetPhase,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$BreakerCode,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Why,
        [AllowEmptyString()][string]$RecoveryOverride = ""
    )

    $lines = Get-WedgeReportLines -TaskId $TaskId -SourcePhase $SourcePhase -TargetPhase $TargetPhase -BreakerCode $BreakerCode -Why $Why -RecoveryOverride $RecoveryOverride
    foreach ($line in $lines) {
        if ($line -match "^\[STOP\]") {
            Write-Host $line -ForegroundColor Red
        } elseif ($line -match "^RECOVERY:") {
            Write-Host $line -ForegroundColor Cyan
        } else {
            Write-Host $line -ForegroundColor Yellow
        }
    }
}

function Get-RootRelativePath {
    # Cross-platform relative path of $Path under $Root. Avoids [System.Uri]/MakeRelativeUri:
    # on Linux an absolute path (e.g. /tmp/x) has no drive letter, so [System.Uri] treats it
    # as a relative URI and MakeRelativeUri throws "not supported for a relative URI".
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path
    )
    $normRoot = $Root.TrimEnd("\", "/").Replace("\", "/")
    $normPath = $Path.Replace("\", "/")
    if ($normPath.Equals($normRoot, [System.StringComparison]::Ordinal)) { return "" }
    $prefix = $normRoot + "/"
    if ($normPath.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
        return $normPath.Substring($prefix.Length)
    }
    return $normPath
}

function Get-StrayFileClassification {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$RepoRoot
    )
    $fullPath = Join-Path $RepoRoot $Path
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return "SURFACE, do not delete"
    }

    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        return "SURFACE, do not delete"
    }

    try {
        $item = Get-Item -LiteralPath $fullPath
        if ($item.Length -eq 0) {
            return "safe-to-remove (zero-byte)"
        }
    } catch {}

    $fileName = Split-Path $Path -Leaf
    if ($fileName -match '\.(tmp|temp|bak|log)$' -or ($fileName -match 'diagnostic' -and $fileName -match '\.txt$')) {
        return "safe-to-remove (known scratch pattern)"
    }

    return "SURFACE, do not delete"
}

function Test-AffectedPathCandidate {
    param(
        [AllowNull()][string]$Candidate,
        [string]$RepoRoot = ""
    )

    $trimChars = [char[]](96, 39, 34, 32)

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $false
    }

    $value = $Candidate.Trim()
    $value = $value.Trim($trimChars)

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }

    if ($value -match '^(https?|file)://') {
        return $false
    }

    if ($value -match '\s' -or $value -match ':') {
        return $false
    }

    # Harden candidate matching: must contain slash, have valid extension, or exist on disk
    if ($value -match '[/\\]' -or $value -match '\.[A-Za-z0-9]{2,4}$') {
        return ($value -match '^[A-Za-z0-9._/@*?+\-\\]+$')
    }

    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $fullPath = Join-Path $RepoRoot $value
        if (Test-Path -LiteralPath $fullPath) {
            return ($value -match '^[A-Za-z0-9._/@*?+\-\\]+$')
        }
    }

    return $false
}

function Add-AffectedPathCandidate {
    param(
        [System.Collections.ArrayList]$Candidates,
        [AllowNull()][string]$Candidate,
        [string]$RepoRoot = ""
    )

    if (Test-AffectedPathCandidate -Candidate $Candidate -RepoRoot $RepoRoot) {
        $trimChars = [char[]](96, 39, 34, 32)
        [void]$Candidates.Add($Candidate.Trim().Trim($trimChars))
    }
}

function Move-TaskHandoffsToArchive {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$SessionDir,
        [Parameter(Mandatory=$true)][string]$Timestamp
    )

    $handoffDir = Join-Path $SessionDir "handoffs"
    if (-not (Test-Path -LiteralPath $handoffDir)) {
        return @()
    }

    $handoffFiles = @(Get-ChildItem -LiteralPath $handoffDir -Filter ($TaskId + "-*.json") -File -ErrorAction SilentlyContinue)
    if ($handoffFiles.Count -eq 0) {
        return @()
    }

    $archiveDir = Join-Path $handoffDir "archived"
    if (-not (Test-Path -LiteralPath $archiveDir)) {
        New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null
    }

    $archived = @()
    foreach ($file in $handoffFiles) {
        $destPath = Join-Path $archiveDir $file.Name
        if (Test-Path -LiteralPath $destPath) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $ext = [System.IO.Path]::GetExtension($file.Name)
            $destPath = Join-Path $archiveDir ($base + "-" + $Timestamp + $ext)
        }
        Move-Item -LiteralPath $file.FullName -Destination $destPath -Force
        $archived += $destPath
    }

    return [string[]]$archived
}

function Resolve-FactoryInputHandoff {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

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
            $specPath = Get-BacklogItemPathForTask -Task $TaskId
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
                    $activeMatch = Get-ChildItem -Path (Join-Path $backlogDir ($dir + "/active")) -Filter ($TaskId + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($null -ne $activeMatch) {
                        $specPath = $activeMatch.FullName
                        break
                    }
                    $rootMatch = Get-ChildItem -Path (Join-Path $backlogDir $dir) -Filter ($TaskId + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($null -ne $rootMatch) {
                        $specPath = $rootMatch.FullName
                        break
                    }
                    $archivedMatch = Get-ChildItem -Path (Join-Path $backlogDir ($dir + "/archived")) -Filter ($TaskId + "_*.md") -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
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

                $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
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
                Write-Host ("Error: No active (non-superseded) handoff found for TaskId: " + $TaskId) -ForegroundColor Red
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

function Test-CrucibleAdopterOwnedPath {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][string[]]$AdopterOwnedExcludes
    )

    $normalized = $RelativePath.Replace("\", "/").TrimStart("/")
    foreach ($exclude in $AdopterOwnedExcludes) {
        $pattern = $exclude.Replace("\", "/").TrimStart("/")
        if ($pattern.EndsWith("/**")) {
            $prefix = $pattern.Substring(0, $pattern.Length - 3).TrimEnd("/")
            if ($normalized -eq $prefix -or $normalized.StartsWith($prefix + "/")) {
                return $true
            }
        } elseif ($normalized -eq $pattern) {
            return $true
        }
    }

    return $false
}

function Get-CrucibleFrameworkStatusChanges {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    $repoRoot = $Context.RepoRoot
    $crucibleRoot = $Context.CrucibleRoot
    if ([string]::IsNullOrWhiteSpace($repoRoot) -or [string]::IsNullOrWhiteSpace($crucibleRoot)) {
        return @()
    }

    $cruciblePath = if ([System.IO.Path]::IsPathRooted($crucibleRoot)) {
        $crucibleRoot
    } else {
        Join-Path $repoRoot $crucibleRoot
    }
    if (-not (Test-Path -LiteralPath $cruciblePath)) {
        return @()
    }

    $manifestPath = Join-Path $cruciblePath "install-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        $manifestPath = Join-Path $repoRoot "install-manifest.json"
    }

    $adopterOwnedExcludes = @("config.yaml", "backlog/**", "session/**", "research/**", ".gemini/**", ".private/**", ".agent-workspaces/**")
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($manifest.PSObject.Properties["adopter_owned_excludes"] -and $null -ne $manifest.adopter_owned_excludes) {
                $adopterOwnedExcludes = @($manifest.adopter_owned_excludes)
            }
        } catch {
            Write-Quiet ("[INTEGRITY] Warning: Could not parse install manifest at " + $manifestPath + "; using built-in adopter-owned excludes.") -ForegroundColor Yellow
        }
    }

    $statusLines = @(git -C $repoRoot status --porcelain -- $crucibleRoot 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    $changes = @()
    $cruciblePrefix = $crucibleRoot.Replace("\", "/").TrimEnd("/") + "/"
    foreach ($line in $statusLines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) { continue }
        $statusCode = $line.Substring(0, 2)
        $pathText = $line.Substring(3).Trim()
        if ($pathText -match ' -> ') {
            $pathText = ($pathText -split ' -> ')[-1].Trim()
        }
        $pathText = $pathText.Trim('"').Replace("\", "/")
        if (-not $pathText.StartsWith($cruciblePrefix)) { continue }

        $relative = $pathText.Substring($cruciblePrefix.Length)
        if ([string]::IsNullOrWhiteSpace($relative)) {
            continue
        }
        if (Test-CrucibleAdopterOwnedPath -RelativePath $relative -AdopterOwnedExcludes $adopterOwnedExcludes) {
            continue
        }

        $changes += ("$statusCode $pathText")
    }

    return @($changes)
}

function Assert-CrucibleFrameworkIntegrity {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    $changes = @(Get-CrucibleFrameworkStatusChanges -Context $Context)
    if ($changes.Count -eq 0) {
        return
    }

    $handoff = $Context.Handoff
    $joined = $changes -join ", "
    Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "factory" `
        -Outcome "framework_integrity_violation" -Notes ("Framework-owned .crucible files changed before handoff: " + $joined) `
        -LogFile $Context.LogFile -CircuitBreakerHistoryFile $Context.CircuitBreakerHistoryFile

    Write-Host "`n[CIRCUIT BREAKER] Framework integrity violation detected." -ForegroundColor Red
    Write-Host "Specialists may not modify framework-owned files under .crucible/." -ForegroundColor Red
    foreach ($change in $changes) {
        Write-Host ("  - " + $change) -ForegroundColor Yellow
    }
    Write-Host "`n[STOP] Revert framework-owned bundle edits or commit a deliberate bundle update before continuing." -ForegroundColor Red
    exit 2
}

function Read-FactoryHandoffContext {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

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
    $logDerivedCount = 0
    if (Test-Path $LOG_FILE) {
        Get-Content $LOG_FILE -Encoding UTF8 | ForEach-Object {
            try {
                $cleanedLine = $_ -replace "^$([char]0xFEFF)", ""
                $entry = $cleanedLine | ConvertFrom-Json
                if ($entry.task_id -eq $handoff.task_id -and $entry.event -eq "session_end" -and $entry.cycle_id -ne "test-cycle") { $logDerivedCount++ }
            } catch {}
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
    $resolvedRoot = (Resolve-Path -LiteralPath $Context.RepoRoot).Path.TrimEnd("\", "/")
    $resolvedPath = (Resolve-Path -LiteralPath $handoffFile).Path
    $Context.RelativeHandoffPath = Get-RootRelativePath -Root $resolvedRoot -Path $resolvedPath
}

function Invoke-HandoffPreflightValidation {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    $TaskId = $Context.TaskId
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

    # Agents sometimes write handoff.json to local session paths instead of $HANDOFF_DIR.
    # Scan known misplaced locations and warn if any are newer than the handoff we found.
    if (-not [string]::IsNullOrEmpty($TaskId)) {
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
                if ($mpItem.LastWriteTime -gt $latestHandoff.LastWriteTime) {
                    Write-Host "[WARN] Misplaced handoff at $mp (newer than active handoff) - agent wrote to wrong location. Auto-recovering by moving to handoffs directory." -ForegroundColor Yellow
                    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
                    $newPath = Join-Path $HANDOFF_DIR "$TaskId-$timestamp.json"
                    Move-Item -Path $mp -Destination $newPath -Force
                    $latestHandoff = Get-Item $newPath
                    $handoffFile = $latestHandoff.FullName
                    $handoffRaw = Get-Content $handoffFile -Raw -Encoding UTF8
                    $handoff = $handoffRaw | ConvertFrom-Json
                    $Context.LatestHandoff = $latestHandoff
                    $Context.Handoff = $handoff
                    $resolvedRoot = (Resolve-Path -LiteralPath $Context.RepoRoot).Path.TrimEnd("\", "/")
                    $resolvedPath = (Resolve-Path -LiteralPath $handoffFile).Path
                    $Context.RelativeHandoffPath = Get-RootRelativePath -Root $resolvedRoot -Path $resolvedPath
                }
            }
        }
    }

    $preflightScript = "$FRAMEWORK_POWERSHELL/validate-handoff.ps1"
    if (-not (Test-Path $preflightScript)) {
        $missingReasonCode = "missing_required_field"
        $handoffFileName = Split-Path -Leaf $handoffFile
        Write-EventLog -Event "preflight_failed" -TaskId $handoff.task_id -Specialist "factory" `
            -Outcome $missingReasonCode -Notes ("reason_code=" + $missingReasonCode + "; handoff_file=" + $handoffFileName + "; message=Validator script missing") `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
        Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode $missingReasonCode `
            -Why ("reason_code=" + $missingReasonCode + "; handoff_file=" + $handoffFileName + "; message=Validator script missing: powershell/validate-handoff.ps1") `
            -RecoveryOverride ("Restore powershell/validate-handoff.ps1 from the Crucible bundle, then rerun: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId " + $handoff.task_id)
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
            Write-EventLog -Event "preflight_failed" -TaskId $handoff.task_id -Specialist "factory" `
                -Outcome $reasonCode -Notes ("reason_code=" + $reasonCode + "; handoff_file=" + $handoffFileName + "; message=" + $errorMessage) `
                -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode $reasonCode `
                -Why ("reason_code=" + $reasonCode + "; handoff_file=" + $handoffFileName + "; message=" + $errorMessage)
            exit 2
        }
    }

    # D19: Cross-check file_affinity in handoff against spec's affected files section
    if ($handoff.psobject.Properties["file_affinity"] -and $handoff.file_affinity -ne $null -and @($handoff.file_affinity).Count -gt 0) {
        $specFile = Get-BacklogItemPathForTask -Task $handoff.task_id
        if ($specFile -and (Test-Path $specFile)) {
            $specContent = Get-Content $specFile -Raw -Encoding UTF8
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
            
            if ($hasAffectedSection) {
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
                        Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist "factory" `
                            -Outcome "warned" -Notes "Handoff file_affinity contains paths ($joinedOverbroad) not mentioned in spec ($joinedSpec)" `
                            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                    }
                }
            } else {
                # Parse frontmatter from spec content
                $specLines = $specContent -split '\r?\n'
                $frontmatterLines = @()
                $foundEnd = $false
                if ($specLines.Count -ge 2 -and $specLines[0].Trim() -eq "---") {
                    for ($i = 1; $i -lt $specLines.Count; $i++) {
                        if ($specLines[$i].Trim() -eq "---") {
                            $foundEnd = $true
                            break
                        }
                        $frontmatterLines += $specLines[$i]
                    }
                }
                
                $frontmatterAffinity = @()
                if ($foundEnd) {
                    $inAffinityBlock = $false
                    for ($i = 0; $i -lt $frontmatterLines.Count; $i++) {
                        $line = $frontmatterLines[$i]
                        if ($line -match '^\s*file_affinity:\s*(.*)$') {
                            $rest = $Matches[1].Trim()
                            if ($rest -match '^\[(.*)\]$') {
                                $items = $Matches[1] -split ','
                                foreach ($item in $items) {
                                    $clean = $item.Trim().Trim('"' + "'")
                                    if (-not [string]::IsNullOrWhiteSpace($clean)) {
                                        $frontmatterAffinity += $clean
                                    }
                                }
                                $inAffinityBlock = $false
                            } else {
                                $inAffinityBlock = $true
                            }
                            continue
                        }
                        if ($inAffinityBlock) {
                            if ($line -match '^\s*-\s*(.*)$') {
                                $item = $Matches[1].Trim().Trim('"' + "'")
                                if (-not [string]::IsNullOrWhiteSpace($item)) {
                                    $frontmatterAffinity += $item
                                }
                            } elseif ($line.Trim() -eq "" -or $line -match '^\s*#') {
                                continue
                            } else {
                                $inAffinityBlock = $false
                            }
                        }
                    }
                }
                
                if (@($frontmatterAffinity).Count -gt 0) {
                    $specTopLevels = @()
                    foreach ($p in $frontmatterAffinity) {
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
                            Write-Host "[WARN] Handoff file_affinity ($joinedOverbroad) lists top-level directories absent from the spec's frontmatter file_affinity ($joinedSpec)." -ForegroundColor Yellow
                            Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist "factory" `
                                -Outcome "warned" -Notes "Handoff file_affinity contains paths ($joinedOverbroad) not mentioned in spec frontmatter ($joinedSpec)" `
                                -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                        } else {
                            Write-Host "[INFO] Handoff file_affinity validated against spec's frontmatter file_affinity." -ForegroundColor Green
                        }
                    } else {
                        # Frontmatter parsed but has no valid top-level directories - fall through to the warning
                        Write-Host "[WARN] Spec file does not declare an 'Affected Files' or 'Affected Packages' section. File affinity cannot be validated." -ForegroundColor Yellow
                        Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist "factory" `
                            -Outcome "warned" -Notes "Spec file does not declare an affected files/packages section to validate file_affinity against." `
                            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                    }
                } else {
                    # D23: Spec has no affected-files/packages section to validate file_affinity against
                    Write-Host "[WARN] Spec file does not declare an 'Affected Files' or 'Affected Packages' section. File affinity cannot be validated." -ForegroundColor Yellow
                    Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist "factory" `
                        -Outcome "warned" -Notes "Spec file does not declare an affected files/packages section to validate file_affinity against." `
                        -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                }
            }
        }
    }

    # Construct the standard session-end command. Use absolute paths so orchestrators can drive
    # specialists from outside the adopter repository without depending on their current directory.
    $resolvedCrucibleRoot = if ([System.IO.Path]::IsPathRooted($crucibleRoot)) { $crucibleRoot } else { Join-Path $Context.RepoRoot $crucibleRoot }
    $pwshCmd = Get-PwshCommand
    $Context.NextFactoryCommand = "$pwshCmd -ExecutionPolicy Bypass -File `"$resolvedCrucibleRoot/powershell/factory.ps1`" -Init -TaskId $($handoff.task_id) -ProjectRoot `"$($Context.RepoRoot)`" -Quiet"

    if ($handoff.psobject.Properties["cycle_id"] -and -not [string]::IsNullOrEmpty($handoff.cycle_id)) {
        $env:FACTORY_CYCLE_ID = $handoff.cycle_id
    } elseif ($handoff.psobject.Properties["session_cycle_id"] -and -not [string]::IsNullOrEmpty($handoff.session_cycle_id)) {
        $env:FACTORY_CYCLE_ID = $handoff.session_cycle_id
    } else {
        $env:FACTORY_CYCLE_ID = [System.Guid]::NewGuid().ToString("N").Substring(0, 8)
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
                if ($content.PSObject.Properties["session_cycle_id"] -and $content.session_cycle_id -ne $env:FACTORY_CYCLE_ID) {
                    $staleTaskHandoffs += $file
                }
            } catch {}
        }
        if ($staleTaskHandoffs.Count -gt 0) {
            Write-Quiet ("[HANDOFF] Warning: Found $($staleTaskHandoffs.Count) previous handoff files for $($handoff.task_id) that may be stale.") -ForegroundColor Yellow
        }
    }
}

function Complete-FactorySourceSession {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    $sessionDir = $Context.SessionDir
    $handoff = $Context.Handoff
    $ceiling = $Context.Ceiling
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile
    $Quiet = [bool]$Context.Quiet

    $lastEnd = Get-LastEntry -TaskId $handoff.task_id -Specialist $handoff.source_phase -Event "session_end" -LogFile $LOG_FILE
    $lastEndHandoffCount = if ($lastEnd -and $lastEnd.PSObject.Properties['handoff_count']) { $lastEnd.handoff_count } else { 0 }
    if (-not $lastEnd -or $lastEndHandoffCount -lt $handoff.cumulative_handoff_count) {
        # Quality gates for closing out the source session run BEFORE session_end
        # is recorded. A failing gate exits 2 without logging session_end, so a
        # re-run re-enters this block and re-evaluates the gate. If session_end were
        # written first, a re-run would find it already logged, skip this whole
        # block (handoff_count guard), and bypass the gate entirely.

        # Deployment encoding & integrity guards
        if ($handoff.source_phase -eq "deployment" -or $handoff.target_phase -eq "deployment") {
            $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
            $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $repoRoot
            $backlogPath = Join-Path $backlogDir "BACKLOG.md"

            # Auto-reconcile active spec link if spec is in active/ but BACKLOG.md has archived link (e.g. from worktree merge)
            if (-not [string]::IsNullOrEmpty($handoff.task_id) -and (Test-Path -LiteralPath $backlogPath)) {
                $archiveLibPath = Join-Path $PSScriptRoot "archive-task.ps1"
                if (Test-Path -LiteralPath $archiveLibPath) { . $archiveLibPath }
                if (Get-Command "Get-TaskFinalizationDetails" -ErrorAction SilentlyContinue) {
                    $specInfo = Get-TaskFinalizationDetails -TaskId $handoff.task_id -ProjectRoot $repoRoot
                    if ($specInfo.SpecExistsInActive -and -not $specInfo.SpecExistsInArchived -and -not [string]::IsNullOrEmpty($specInfo.SpecPathInActive)) {
                        $fileName = Split-Path -Leaf $specInfo.SpecPathInActive
                        $typeDir = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $specInfo.SpecPathInActive))
                        $activeRel = "$typeDir/active/$fileName".Replace("\", "/")
                        $archivedRel = "$typeDir/archived/$fileName".Replace("\", "/")
                        $blContent = [System.IO.File]::ReadAllText($backlogPath, [System.Text.Encoding]::UTF8)
                        if ($blContent.Contains("]($archivedRel)")) {
                            Invoke-WithBacklogLock -BacklogPath $backlogPath -ScriptBlock {
                                $blLines = [System.IO.File]::ReadAllLines($backlogPath, [System.Text.Encoding]::UTF8)
                                for ($i = 0; $i -lt $blLines.Count; $i++) {
                                    if ($blLines[$i].Contains("]($archivedRel)")) {
                                        $blLines[$i] = $blLines[$i].Replace("]($archivedRel)", "]($activeRel)")
                                    }
                                }
                                [System.IO.File]::WriteAllText($backlogPath, (($blLines) -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
                            }
                        }
                    }
                }
            }

            if (Test-Path -LiteralPath $backlogPath) {
                $bytes = [System.IO.File]::ReadAllBytes($backlogPath)
                $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
                $rawText = [System.Text.Encoding]::UTF8.GetString($bytes)
                $hasMojibake = $false
                # Mojibake marker list is intentionally best-effort and mirrors check-mojibake convention
                $mojibakeMarkers = @(
                    ([string]::Concat([char]0x00E2, [char]0x2020, [char]0x2019)),
                    ([string]::Concat([char]0x00E2, [char]0x20AC, [char]0x201D)),
                    ([string]::Concat([char]0x00E2, [char]0x20AC, [char]0x201C)),
                    ([string]::Concat([char]0x00E2, [char]0x20AC, [char]0x0153)),
                    ([string]::Concat([char]0x00E2, [char]0x20AC, [char]0x2122)),
                    ([string]::Concat([char]0x00C3, [char]0x00A2, [char]0x00E2))
                )
                foreach ($m in $mojibakeMarkers) {
                    if ($rawText.Contains($m)) {
                        $hasMojibake = $true
                        break
                    }
                }
                if (-not $hasMojibake -and $rawText.Contains([char]0xFFFD)) {
                    $hasMojibake = $true
                }
                if ($hasBom -or $hasMojibake) {
                    Write-Host "[STOP] Quality gate failed: BACKLOG.md encoding corruption detected (BOM or mojibake)." -ForegroundColor Red
                    Write-Host "Please fix BACKLOG.md encoding to UTF-8 without BOM before proceeding." -ForegroundColor Red
                    Write-EventLog -Event "quality_gate_retry" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                        -Outcome "retry_required" -Notes "BACKLOG.md encoding corruption detected" `
                        -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                    exit 2
                }

                # Premature Production/Resolved status guard (F12)
                if ($handoff.source_phase -eq "deployment" -and -not [string]::IsNullOrEmpty($handoff.task_id)) {
                    $gateAlreadyPassed = $false
                    if (-not [string]::IsNullOrEmpty($sessionDir)) {
                        $GATE_DIR = Join-Path $sessionDir "global/gate_decisions"
                        if (Test-Path $GATE_DIR) {
                            $decisions = @(Get-ChildItem -Path $GATE_DIR -Filter ($handoff.task_id + "-*.json") |
                                Where-Object { $_.Name -notmatch "gate_decision_.*_pending.json" } |
                                Sort-Object LastWriteTime -Descending)
                            if ($decisions.Count -gt 0) {
                                try {
                                    $latestDecision = Get-Content $decisions[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                                    $advancingOutcomes = @("accepted", "redirected")
                                    if ($advancingOutcomes -contains $latestDecision.outcome) {
                                        $gateAlreadyPassed = $true
                                    }
                                } catch {}
                            }
                        }
                    }
                    if (-not $gateAlreadyPassed) {
                        $isPremature = $false
                        $statusLines = $rawText -split "`r?`n"
                        $matchingRowIdx = -1
                        for ($i = 0; $i -lt $statusLines.Count; $i++) {
                            $line = $statusLines[$i]
                            if ($line -match '^\s*\|' -and $line -notmatch '^\s*\|\s*(\*\*P[0-3]\*\*|Priority)\s*\|' -and $line -match ('\b' + [regex]::Escape($handoff.task_id) + '\b')) {
                                $matchingRowIdx = $i
                                break
                            }
                        }

                        if (-not (Get-Command "Get-MarkdownTableStatusColumn" -ErrorAction SilentlyContinue)) {
                            $archiveLibPath = Join-Path $PSScriptRoot "archive-task.ps1"
                            if (Test-Path -LiteralPath $archiveLibPath) { . $archiveLibPath }
                        }

                        if ($matchingRowIdx -ge 0 -and (Get-Command "Get-MarkdownTableStatusColumn" -ErrorAction SilentlyContinue)) {
                            $statusColIdx = Get-MarkdownTableStatusColumn -Lines ([string[]]$statusLines) -RowIndex $matchingRowIdx
                            if ($statusColIdx -ge 0) {
                                $rowText = $statusLines[$matchingRowIdx]
                                $cells = @($rowText.Trim().Trim("|").Split("|") | ForEach-Object { $_.Trim() })
                                if ($statusColIdx -lt $cells.Count) {
                                    if ($cells[$statusColIdx] -match '\b(?:Production|Resolved)\b') {
                                        $isPremature = $true
                                    }
                                }
                            } else {
                                if ($rawText -match '(?m)^\s*\|.*?\b' + [regex]::Escape($handoff.task_id) + '\b.*?\b(?:Production|Resolved)\b.*?\|') {
                                    $isPremature = $true
                                }
                            }
                        } else {
                            if ($rawText -match '(?m)^\s*\|.*?\b' + [regex]::Escape($handoff.task_id) + '\b.*?\b(?:Production|Resolved)\b.*?\|') {
                                $isPremature = $true
                            }
                        }

                        if ($isPremature) {
                            Write-Host ("[STOP] Quality gate failed: Task " + $handoff.task_id + " is marked Production or Resolved in BACKLOG.md prior to human gate approval.") -ForegroundColor Red
                            Write-Host "Revert BACKLOG.md status to an Active status (e.g. Ready for Deploy or In Progress) before proceeding." -ForegroundColor Red
                            Write-EventLog -Event "quality_gate_retry" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                                -Outcome "retry_required" -Notes "Premature Production status in BACKLOG.md" `
                                -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                            exit 2
                        }
                    }
                }
            }
        }

        # Promote the deployment checklist item to a real gate: the BACKLOG.md entry shows Production/Resolved
        if ($handoff.source_phase -eq "deployment" -and $handoff.target_phase -eq "done" -and -not [string]::IsNullOrEmpty($handoff.task_id)) {
            $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
            $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $repoRoot
            $backlogPath = Join-Path $backlogDir "BACKLOG.md"
            if (Test-Path -LiteralPath $backlogPath) {
                $backlogContent = Get-Content -LiteralPath $backlogPath -Raw -Encoding UTF8
                if ($backlogContent -match [regex]::Escape($handoff.task_id)) {
                    # Determine if the human gate has already passed.
                    # We only enforce this finalization gate when transitioning to done (which requires the gate to have passed).
                    $gateAlreadyPassed = $false
                    if (-not [string]::IsNullOrEmpty($sessionDir)) {
                        $GATE_DIR = Join-Path $sessionDir "global/gate_decisions"
                        if (Test-Path $GATE_DIR) {
                            $decisions = @(Get-ChildItem -Path $GATE_DIR -Filter ($handoff.task_id + "-*.json") |
                                Where-Object { $_.Name -notmatch "gate_decision_.*_pending.json" } |
                                Sort-Object LastWriteTime -Descending)
                            if ($decisions.Count -gt 0) {
                                try {
                                    $latestDecision = Get-Content $decisions[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                                    $advancingOutcomes = @("accepted", "redirected")
                                    if ($advancingOutcomes -contains $latestDecision.outcome) {
                                        $gateAlreadyPassed = $true
                                    }
                                } catch {}
                            }
                        }
                    }

                    if ($gateAlreadyPassed) {
                        $finalization = Get-TaskFinalizationDetails -TaskId $handoff.task_id -ProjectRoot $repoRoot
                        if (-not $finalization.IsFinalized) {
                            Write-Host ("[STOP] Quality gate failed: deployment did not finalize the backlog: " + $handoff.task_id + " is still not terminal/archived. Run archive-task.ps1.") -ForegroundColor Red
                            Write-EventLog -Event "quality_gate_retry" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                                -Outcome "retry_required" -Notes "Deployment backlog finalization gate failed" `
                                -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                            exit 2
                        }
                    }
                }
            }
        }

        # A-4: Task.md quality gate (required checklist section only)
        $taskMdPath = if (-not [string]::IsNullOrEmpty($handoff.task_id)) {
            Join-Path $sessionDir ("$($handoff.task_id)/$($handoff.source_phase)/task.md")
        } else {
            Join-Path $sessionDir ("$($handoff.source_phase)/task.md")
        }
        if (Test-Path $taskMdPath) {
            $checklistGate = Get-TaskChecklistGateResult -TaskMdPath $taskMdPath -RequiredSectionHeader "## Task List"
            $requiredUncheckedCount = $checklistGate.RequiredUnchecked.Count
            $optionalUncheckedCount = $checklistGate.OptionalUnchecked.Count
            $requiredMalformedCount = $checklistGate.RequiredMalformed.Count
            $requiredFailureCount = $requiredUncheckedCount + $requiredMalformedCount

            # Deterministic output ordering: required failures first, optional warnings second.
            if ($requiredFailureCount -gt 0) {
                if ($requiredUncheckedCount -gt 0) {
                    Write-Quiet ("[WARN] Required checklist has " + $requiredUncheckedCount + " unchecked item(s) for " + $handoff.source_phase + ".") -ForegroundColor Yellow
                }
                if ($requiredMalformedCount -gt 0) {
                    Write-Quiet ("[WARN] Required checklist has " + $requiredMalformedCount + " malformed checklist line(s) for " + $handoff.source_phase + ".") -ForegroundColor Yellow
                }
            }

            if ($optionalUncheckedCount -gt 0) {
                Write-Quiet ("[WARN] Optional checklist has " + $optionalUncheckedCount + " unchecked item(s) for " + $handoff.source_phase + " (non-blocking).") -ForegroundColor Yellow
            }

            if ($requiredMalformedCount -gt 0 -or $optionalUncheckedCount -gt 0) {
                Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                    -Outcome "warned" -Notes ("Task checklist summary: required_unchecked=" + $requiredUncheckedCount + "; required_malformed=" + $requiredMalformedCount + "; optional_unchecked=" + $optionalUncheckedCount) `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            }

            if ($requiredFailureCount -gt 0) {
                Write-EventLog -Event "quality_gate_retry" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                    -Outcome "retry_required" -Notes ("Required task.md checklist quality gate failed: unchecked=" + $requiredUncheckedCount + "; malformed=" + $requiredMalformedCount) `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                Write-Host ("[STOP] Quality gate failed: " + $handoff.source_phase + " has required checklist issues (unchecked: " + $requiredUncheckedCount + ", malformed: " + $requiredMalformedCount + "). Complete required Task List items before handoff.") -ForegroundColor Red
                Write-Host "Tick the required ## Task List checkboxes in task.md, then re-run factory.ps1 -Init -TaskId $($handoff.task_id)." -ForegroundColor Red
                exit 2
            }
        }

        # All source-session quality gates passed: record session_end exactly once.
        # Compute duration from the source specialist's session_start or recovery_start.
        $lastStart = Get-LastEntry -TaskId $handoff.task_id -Specialist $handoff.source_phase -Event "session_start" -LogFile $LOG_FILE
        $lastRecovery = Get-LastEntry -TaskId $handoff.task_id -Specialist $handoff.source_phase -Event "recovery_start" -LogFile $LOG_FILE

        $effectiveStart = $null
        if ($lastStart -and $lastRecovery) {
            if ([DateTimeOffset]::Parse($lastStart.timestamp) -gt [DateTimeOffset]::Parse($lastRecovery.timestamp)) {
                $effectiveStart = $lastStart
            } else {
                $effectiveStart = $lastRecovery
            }
        } else {
            $effectiveStart = if ($lastStart) { $lastStart } else { $lastRecovery }
        }

        $duration = 0
        $anomaly = $null
        if ($effectiveStart) {
            $startTime = [DateTimeOffset]::Parse($effectiveStart.timestamp).UtcDateTime
            $duration = [int](([DateTime]::UtcNow - $startTime).TotalSeconds)

            # Guard rails for missing/out-of-order events
            if ($duration -lt 0) {
                $anomaly = "negative_duration"
                $duration = 0
            }
        } else {
            $anomaly = "missing_start_event"
        }

        # This is phase-open wall time, not specialist active work time. Keep it out of the
        # top-level duration_seconds field so eval consumers do not treat idle time as runtime.
        $pctUsed = if ($ceiling -gt 0) { [math]::Min(100, [math]::Round(($handoff.cumulative_handoff_count / $ceiling) * 100)) } else { 0 }
        $metricsBlock = @{
            phase_wall_seconds = $duration
            budget_tier      = $handoff.budget_tier
            budget_ceiling   = $ceiling
            handoff_count    = $handoff.cumulative_handoff_count
            budget_pct_used  = $pctUsed
        }
        if ($anomaly) { $metricsBlock.duration_anomaly = $anomaly }

        Write-EventLog -Event "session_end" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
            -Outcome "success" `
            -Notes ("Handoff to " + $handoff.target_phase) `
            -HandoffCount $handoff.cumulative_handoff_count `
            -Metrics $metricsBlock `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
    }
}

if (-not (Get-Command Get-PrimaryBranchName -ErrorAction SilentlyContinue)) {
    function Get-PrimaryBranchName {
        git show-ref --verify --quiet refs/heads/main
        if ($LASTEXITCODE -eq 0) { return "main" }
        return "master"
    }
}

function Invoke-FactoryRuntimeValidation {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    if ($null -eq $Context) {
        throw "FactoryContext is null."
    }
    $requiredKeys = @("Handoff", "LogFile", "CircuitBreakerHistoryFile")
    foreach ($key in $requiredKeys) {
        if (-not $Context.ContainsKey($key) -or $null -eq $Context[$key]) {
            throw "Required key '$key' is missing from FactoryContext."
        }
    }

    $handoff = $Context.Handoff
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile

    # Git Hook Bypass Prevention
    $handoffSecurityText = Get-HandoffTextForSecurityScan -HandoffObj $handoff
    if ($handoffSecurityText -match '(?i)(^|\s)--no-verify(\s|$)' -or $handoffSecurityText -match '(?i)\bno[- ]verify\b') {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
            -Outcome "git_hook_bypass" -Notes "Handoff reported or referenced a git hook bypass attempt."
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "git_hook_bypass" -AttemptCount $handoff.cumulative_handoff_count `
            -LastSpecialist $handoff.source_phase -Summary "Handoff reported or referenced use of --no-verify, which bypasses required git hooks."
        Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "git_hook_bypass" `
            -Why "Git hook bypass attempt detected. '--no-verify' and equivalent hook bypasses require human review. Fix the hook failure instead of bypassing it."
        exit 2
    }

    # A-3: Verify listed artifacts actually exist
    if ($handoff.psobject.Properties["artifacts"] -and $handoff.artifacts -ne $null) {
        $missingArtifacts = @()

        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
        $workspacesDir = if ($Context.ContainsKey("WorkspacesDir")) { $Context.WorkspacesDir } else { Get-ConfiguredPath -Key "workspaces" -ProjectRoot $repoRoot }
        $wtPath = Resolve-ImplementationWorktreePath -TaskId $handoff.task_id -WorkspacesDir $workspacesDir
        $baseArtifactDir = if (Test-Path $wtPath) { $wtPath } else { $repoRoot }

        foreach ($artifact in $handoff.artifacts) {
            if ([string]::IsNullOrWhiteSpace($artifact)) { continue }

            $exists = $false
            $matchedPath = $null
            foreach ($base in @($wtPath, $repoRoot)) {
                if ([string]::IsNullOrWhiteSpace($base)) { continue }
                $candidate = if ([System.IO.Path]::IsPathRooted($artifact)) { $artifact } else { Join-Path $base $artifact }
                if (Test-Path $candidate) {
                    $exists = $true
                    $matchedPath = $candidate
                    break
                }
            }

            if (-not $exists) {
                if ($artifact -match '(?i)[/\\]active[/\\]') {
                    $archivedArtifact = $artifact -replace '(?i)([/\\])active([/\\])', '${1}archived${2}'
                    foreach ($base in @($wtPath, $repoRoot)) {
                        if ([string]::IsNullOrWhiteSpace($base)) { continue }
                        $candidate = if ([System.IO.Path]::IsPathRooted($archivedArtifact)) { $archivedArtifact } else { Join-Path $base $archivedArtifact }
                        if (Test-Path $candidate) {
                            $exists = $true
                            $matchedPath = $candidate
                            break
                        } else {
                            $leaf = Split-Path -Leaf $candidate
                            $parentDir = Split-Path -Parent $candidate
                            if (Test-Path -LiteralPath $parentDir) {
                                $match = Get-ChildItem -Path $parentDir -Filter $leaf -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                                if ($null -ne $match) {
                                    $exists = $true
                                    $matchedPath = $match.FullName
                                    break
                                }
                            }
                        }
                    }
                }
            }

            if (-not $exists) {
                # Check if the artifact exists on the task branch
                $taskBranchName = "task/$($handoff.task_id)"
                # First check if the branch itself exists
                git show-ref --quiet "refs/heads/$taskBranchName"
                if ($LASTEXITCODE -eq 0) {
                    # Avoid backslashes in git paths, replace them with forward slashes
                    $gitArtifactPath = $artifact.Replace('\', '/')
                    # Check if file exists in the branch
                    $previousPreference = $ErrorActionPreference
                    $ErrorActionPreference = "Continue"
                    git cat-file -e "$($taskBranchName):$($gitArtifactPath)" 2>$null
                    $gitExistsCode = $LASTEXITCODE
                    $ErrorActionPreference = $previousPreference
                    if ($gitExistsCode -eq 0) {
                        $exists = $true
                        # Check if empty in git
                        $gitSizeStr = (git cat-file -s "$($taskBranchName):$($gitArtifactPath)" 2>$null)
                        $gitSize = 0
                        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrEmpty($gitSizeStr)) {
                            [int]::TryParse($gitSizeStr, [ref]$gitSize) | Out-Null
                        }
                        if ($gitSize -eq 0) {
                            Write-Host "[WARN] Artifact is empty on branch $($taskBranchName): $artifact" -ForegroundColor Yellow
                        }
                    }
                }
            }

            if (-not $exists) {
                Write-Host "[WARN] Artifact listed in handoff does not exist: $artifact" -ForegroundColor Yellow
                $missingArtifacts += $artifact
            } elseif ($null -ne $matchedPath -and (Get-Item $matchedPath).Length -eq 0) {
                Write-Host "[WARN] Artifact is empty: $artifact" -ForegroundColor Yellow
            }
        }
        if ($missingArtifacts.Count -gt 0) {
            $joined = ($missingArtifacts -join ", ")

            # Check if this is a retry (prior missing-artifact quality_gate_retry in event log)
            $hasPriorRetry = $false
            if (Test-Path $LOG_FILE) {
                $lines = @(Get-Content $LOG_FILE -Tail 200 -Encoding UTF8)
                for ($i = $lines.Length - 1; $i -ge 0; $i--) {
                    try {
                        $cleanedLine = $lines[$i] -replace "^$([char]0xFEFF)", ""
                        $entry = $cleanedLine | ConvertFrom-Json
                        $logPhase = if ($entry.PSObject.Properties["phase"]) { $entry.phase } else { $entry.specialist }
                        if ($entry.task_id -eq $handoff.task_id -and $logPhase -eq "factory") {
                            continue
                        }
                        if ($entry.task_id -eq $handoff.task_id -and $logPhase -ne $handoff.source_phase) {
                            break
                        }
                        if ($entry.task_id -eq $handoff.task_id -and $logPhase -eq $handoff.source_phase -and $entry.event -eq "session_end" -and $entry.outcome -eq "success") {
                            break
                        }
                        if ($entry.task_id -eq $handoff.task_id -and $logPhase -eq $handoff.source_phase -and $entry.event -eq "quality_gate_retry" -and $entry.notes -like "*artifact*") {
                            $hasPriorRetry = $true
                            break
                        }
                    } catch { continue }
                }
            }

            if ($hasPriorRetry) {
                Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                    -Outcome "blocked" -Notes ("Fabricated artifact path(s) in handoff: " + $joined)
                Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "fabricated_artifacts" -AttemptCount $handoff.cumulative_handoff_count `
                    -LastSpecialist $handoff.source_phase -Summary ("Handoff listed artifact paths that do not exist: " + $joined) -Artifacts $missingArtifacts
                Write-Host "[STOP] Artifact integrity gate failed. Fabricated artifact paths must be corrected before handoff can proceed." -ForegroundColor Red
                exit 2
            } else {
                Write-EventLog -Event "quality_gate_retry" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                    -Outcome "retry_required" -Notes ("Required artifact missing: " + $joined) `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                Write-Host "[STOP] Artifact integrity gate failed: some artifact paths do not exist (missing: $joined)." -ForegroundColor Red
                Write-Host "Please ensure the files exist in the implementation worktree or repo root and are spelled correctly before handoff." -ForegroundColor Red
                exit 2
            }
        }
    }

    # Verify session_cycle_id matches live cycle when present.
    # Presence requirements are enforced by validate-handoff.ps1 + handoff.schema.json.
    if ($handoff.psobject.Properties["session_cycle_id"] -and -not [string]::IsNullOrEmpty($handoff.session_cycle_id)) {
        if ($handoff.session_cycle_id -ne $env:FACTORY_CYCLE_ID) {
            Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                -Outcome "warned" -Notes "session_cycle_id mismatch - agent may not have read task.md"
            Write-Host ("[STOP] session_cycle_id mismatch for $($handoff.source_phase). Expected: $($env:FACTORY_CYCLE_ID), Got: $($handoff.session_cycle_id)") -ForegroundColor Red
            Write-Host "       All specialists must read task.md and echo its Cycle ID before handing off." -ForegroundColor Red
            exit 2
        } else {
            Write-Quiet ("[OK] session_cycle_id verified.") -ForegroundColor DarkGray
        }
    }
}

function Invoke-FactoryScopeGates {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    if ($null -eq $Context) {
        throw "FactoryContext is null."
    }
    $requiredKeys = @("Handoff", "FrameworkPowerShell", "LogFile", "CircuitBreakerHistoryFile", "BacklogDir", "WorkspacesDir")
    foreach ($key in $requiredKeys) {
        if (-not $Context.ContainsKey($key) -or $null -eq $Context[$key]) {
            throw "Required key '$key' is missing from FactoryContext."
        }
    }

    $handoff = $Context.Handoff
    $FRAMEWORK_POWERSHELL = $Context.FrameworkPowerShell
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile
    $backlogDir = $Context.BacklogDir
    $workspacesDir = $Context.WorkspacesDir

    # --- 2.1 File Affinity Conflict Check ---
    if ($handoff.psobject.Properties["file_affinity"] -and $handoff.file_affinity -ne $null -and @($handoff.file_affinity).Count -gt 0) {
        $affinityScript = "$FRAMEWORK_POWERSHELL/check-file-affinity.ps1"
        if (Test-Path $affinityScript) {
            & $affinityScript -TaskId $handoff.task_id -Affinity $handoff.file_affinity
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Error: File affinity overlap detected with another active task." -ForegroundColor Red
                Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "factory" `
                    -Outcome "file_affinity_conflict" -Notes "Handoff blocked due to overlapping file affinity."
                exit 1
            }
        }
    }

    # --- 2.1b Architect Scope Boundary Check ---
    if ($handoff.source_phase -eq "implementation" -and $handoff.target_phase -eq "verification") {
        $wtPath = Resolve-ImplementationWorktreePath -TaskId $handoff.task_id
        if (Test-Path $wtPath) {
            $declaredAffinity = @()
            if ($handoff.psobject.Properties["file_affinity"] -and $null -ne $handoff.file_affinity) {
                $declaredAffinity = @($handoff.file_affinity)
            }

            $outOfScopeFiles = @()
            if (@($declaredAffinity).Count -gt 0) {
                $outOfScopeFiles = @(Get-OutOfScopeImplementationFiles -WorktreePath $wtPath -TaskId $handoff.task_id -FileAffinity $declaredAffinity)
            } else {
                Write-Host "[ADVISORY] No file_affinity declared; scope check skipped." -ForegroundColor Yellow
            }
            if ($outOfScopeFiles.Count -gt 0) {
                $joined = ($outOfScopeFiles -join ", ")
                Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "factory" `
                    -Outcome "scope_violation" -Notes ("Architect modified files outside file_affinity: " + $joined)
                Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "scope_violation" -AttemptCount $handoff.cumulative_handoff_count `
                    -LastSpecialist $handoff.source_phase -Summary ("Architect modified files outside declared file_affinity: " + $joined) -Artifacts $outOfScopeFiles
                Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "scope_violation" `
                    -Why ("Scope boundary violation detected. Out-of-scope files: " + $joined + ". Expand file_affinity or revert out-of-scope changes.")
                exit 2
            }
        }
    }

    # --- 2.1c Research Scope Boundary Check ---
    if ($handoff.source_phase -eq "research" -and $handoff.target_phase -eq "grooming") {
        $repoRoot = if ($Context.ContainsKey("RepoRoot") -and $null -ne $Context["RepoRoot"]) { $Context["RepoRoot"] } else { (Get-Location).Path }
        try {
            $statusLines = @(git -C $repoRoot status --porcelain 2>$null)
            $modifiedFiles = @()
            foreach ($line in $statusLines) {
                if ($line -match '^.{2}\s+(.*)$') {
                    $filePath = $Matches[1].Trim()
                    if ($filePath.StartsWith('"') -and $filePath.EndsWith('"')) {
                        $filePath = $filePath.Substring(1, $filePath.Length - 2)
                    }
                    $normalizedPath = $filePath.Replace("\", "/")
                    
                    $isAllowed = $false
                    foreach ($prefix in @(".crucible/research/", ".crucible/session/")) {
                        if ($normalizedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $isAllowed = $true
                            break
                        }
                    }
                    
                    if (-not $isAllowed) {
                        $modifiedFiles += $normalizedPath
                    }
                }
            }
            if ($modifiedFiles.Count -gt 0) {
                $joined = ($modifiedFiles -join ", ")
                Write-EventLog -Event "security_warning" -TaskId $handoff.task_id -Specialist "factory" `
                    -Outcome "warned" -Notes ("research_scope_violation: " + $joined)
                
                Write-Quiet "`n[SECURITY WARNING] Research phase modified files outside the read-only boundary:" -ForegroundColor Yellow
                foreach ($file in $modifiedFiles) {
                    Write-Quiet "  - $file" -ForegroundColor Yellow
                }
                Write-Quiet "  Note: The Researcher is expected to write files only under `.crucible/research/`." -ForegroundColor Yellow
            }
        } catch {
            # Skip silently, never throw from the gate
        }
    }
}

function Test-CompletionArtifactGate {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    if ($null -eq $Context) {
        throw "FactoryContext is null."
    }
    $requiredKeys = @("Handoff", "BacklogDir", "SessionDir", "LogFile", "CircuitBreakerHistoryFile", "RepoRoot", "WorkspacesDir")
    foreach ($key in $requiredKeys) {
        if (-not $Context.ContainsKey($key) -or $null -eq $Context[$key]) {
            throw "Required key '$key' is missing from FactoryContext."
        }
    }

    $handoff = $Context.Handoff
    $backlogDir = $Context.BacklogDir
    $sessionDir = $Context.SessionDir
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile
    $workspacesDir = $Context.WorkspacesDir

    if (-not [string]::IsNullOrEmpty($handoff.task_id)) {
        $verificationPassed = $true
        $errorMsg = ""
        $transition = "$($handoff.source_phase.ToLower()) -> $($handoff.target_phase.ToLower())"
        
        switch ($transition) {
            "grooming -> implementation" {
                $specFile = Get-BacklogItemPathForTask -Task $handoff.task_id
                if ([string]::IsNullOrEmpty($specFile) -or -not (Test-Path $specFile)) {
                    $errorMsg = "Mandatory spec file for $($handoff.task_id) not found.`nExpected pattern: $($backlogDir)/{features,bugs,chores}/active/$($handoff.task_id)_*.md`nTip: filename must be {TASK_ID}_{slug}.md (underscore separator)."
                }
            }
            "implementation -> verification" {
                $wtPath = Resolve-ImplementationWorktreePath -TaskId $handoff.task_id
                if (Test-Path $wtPath) {
                    $branchCheck = git -C $wtPath branch --show-current 2>&1
                    if ($branchCheck -ne "task/$($handoff.task_id)") {
                        $verificationPassed = $false
                        $errorMsg = "Architect worktree is not on mandatory task branch 'task/$($handoff.task_id)' (found '$branchCheck')."
                    } else {
                        $mainBranch = Get-PrimaryBranchName
                        $commits = git -C $wtPath log "$mainBranch..task/$($handoff.task_id)" --oneline 2>&1
                        if ([string]::IsNullOrWhiteSpace($commits) -or $commits -match "fatal") {
                            # Workaround for factory tasks (ignored files in .crucible/ cannot be committed easily)
                            $status = git status --ignored --porcelain .crucible/ 2>&1
                            if ([string]::IsNullOrWhiteSpace($status)) {
                                $verificationPassed = $false
                                $errorMsg = "No commits found on branch 'task/$($handoff.task_id)' and no local changes detected in .crucible/."
                            }
                        }
                    }
                }
            }
            "verification -> deployment" {
                $reportPath = Join-Path $sessionDir "$($handoff.task_id)/verification/review_report.md"
                if (-not (Test-Path $reportPath)) {
                    $verificationPassed = $false
                    $errorMsg = "Mandatory review_report.md not found."
                } else {
                    $content = Get-Content $reportPath -Raw -Encoding UTF8
                    if ($content -notmatch "APPROVED") {
                        $verificationPassed = $false
                        $errorMsg = "Review report must contain 'APPROVED' for transition to Operator."
                    } else {
                        # Regex uses [\r\n]+ to handle both Windows (\r\n) and Unix (\n) line endings.
                        if ($content -match "(?sm)^\s*---\s*[\r\n]+(.*)[\r\n]+\s*---") {
                            $yaml = $matches[1]
                            $decision = ""
                            if ($yaml -match '(?m)^\s*review_decision:\s*["'']?(APPROVED|CHANGES_REQUESTED|BLOCKED)["'']?\s*$') { $decision = $matches[1] }

                            if ($decision -ne "APPROVED") {
                                $verificationPassed = $false
                                $errorMsg = "Review report YAML 'review_decision' must be 'APPROVED' (found '$decision')."
                            }

                            if ($yaml -match '(?m)^\s*acceptance_criteria_met:\s*["'']?false["'']?\s*$' -or $yaml -notmatch '(?m)^\s*acceptance_criteria_met:\s*["'']?true["'']?\s*$') {
                                 $verificationPassed = $false
                                 $errorMsg = "Review report YAML must have 'acceptance_criteria_met: true'."
                            }
                        } else {
                            # Plain-text APPROVED without YAML frontmatter: warn but accept.
                            # "APPROVED" presence was already confirmed above; don't hard-block on formatting.
                            Write-Host "[WARN] Review report has no YAML frontmatter (review_decision: APPROVED). Accepted on plain-text APPROVED - Reviewer MUST use YAML format going forward." -ForegroundColor Yellow
                            Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist "factory" `
                                -Outcome "warned" -Notes "Review report missing YAML header - accepted plain-text APPROVED"
                        }
                    }
                }
            }
            "deployment -> grooming" {
                # Two distinct triggers share this edge:
                #   1. Dependency-blocked at Step 1 (pre-merge): commit_hash must be absent
                #   2. Production incident (post-deploy): commit_hash required + merge checks
                $hasCommitHash = ($handoff.psobject.Properties["commit_hash"] -and -not [string]::IsNullOrWhiteSpace($handoff.commit_hash))
                if ($hasCommitHash) {
                    # Incident-shaped: commit_hash is populated -> must be a real merged commit
                    $previousPreference = $ErrorActionPreference
                    $ErrorActionPreference = "Continue"
                    $commitExists = git rev-parse --verify "$($handoff.commit_hash)^{commit}" 2>$null
                    $commitExistsExitCode = $LASTEXITCODE
                    $ErrorActionPreference = $previousPreference
                    if ($commitExistsExitCode -ne 0 -or $commitExists -match "fatal") {
                        $verificationPassed = $false
                        $errorMsg = "Incident handoff: commit hash $($handoff.commit_hash) does not exist."
                    } else {
                        $mainBranch = Get-PrimaryBranchName
                        git merge-base --is-ancestor $($handoff.commit_hash) $mainBranch 2>$null
                        if ($LASTEXITCODE -ne 0) {
                            $verificationPassed = $false
                            $errorMsg = "Incident handoff: commit $($handoff.commit_hash) is not merged into $mainBranch."
                        } else {
                            # Reject baseline commits (same check as deployment -> done)
                            $baseCommit = $null
                            if ($handoff.psobject.Properties["base_commit"] -and -not [string]::IsNullOrWhiteSpace($handoff.base_commit)) {
                                $baseCommit = [string]$handoff.base_commit
                            } else {
                                $taskBranchRef = "task/$($handoff.task_id)"
                                git show-ref --verify --quiet "refs/heads/$taskBranchRef" 2>$null
                                if ($LASTEXITCODE -eq 0) {
                                    $mbOut = (git merge-base $mainBranch $taskBranchRef 2>$null)
                                    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($mbOut)) {
                                        $baseCommit = $mbOut.Trim()
                                    }
                                }
                            }
                            if (-not [string]::IsNullOrWhiteSpace($baseCommit)) {
                                git merge-base --is-ancestor $($handoff.commit_hash) $baseCommit 2>$null
                                if ($LASTEXITCODE -eq 0) {
                                    $verificationPassed = $false
                                    $errorMsg = "Incident handoff: commit $($handoff.commit_hash) is a baseline commit and does not identify the bad deploy."
                                }
                            }
                        }
                    }
                }
                # Dependency-blocked shape: commit_hash absent -> no checks needed, pass through
            }
            "deployment -> done" {
                # No-Code Closure detection: research/grooming tasks with no code changes
                # have no task branch and no merge to prove. The exemption must be
                # *proven* from observable facts, not asserted by the handoff.
                $isNoCodeClosure = $false
                $noCodeClosureRepoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
                $noCodeClosureSpecPath = Get-BacklogItemPathForTaskProjectRoot -Task $handoff.task_id -ProjectRoot $noCodeClosureRepoRoot
                if (-not [string]::IsNullOrEmpty($noCodeClosureSpecPath) -and (Test-Path -LiteralPath $noCodeClosureSpecPath)) {
                    $noCodeClosureSpecText = Get-Content -LiteralPath $noCodeClosureSpecPath -Raw -Encoding UTF8
                    $isExplicitResearchOrGroomingType = ($noCodeClosureSpecText -match '(?im)^\s*type:\s*["'']?(?:research|grooming)["'']?\s*$')
                    $isResearchTaskId = ($handoff.task_id -match '(?i)^R-')
                    $noCommitHashClaimed = (-not $handoff.psobject.Properties["commit_hash"] -or [string]::IsNullOrWhiteSpace($handoff.commit_hash))
                    $qualifiesForNoCodeClosure = (($isExplicitResearchOrGroomingType -or $isResearchTaskId) -and $noCommitHashClaimed)

                    if ($qualifiesForNoCodeClosure) {
                        $taskBranchRef = "task/$($handoff.task_id)"
                        git show-ref --verify --quiet "refs/heads/$taskBranchRef" 2>$null
                        if ($LASTEXITCODE -ne 0) {
                            # No task branch exists and no commit_hash claimed -> No-Code Closure proven
                            $isNoCodeClosure = $true
                            Write-Host "[INFO] No-Code Closure detected for $($handoff.task_id): research/grooming spec with no task branch and no commit_hash. Merge verification skipped." -ForegroundColor Cyan
                        }
                    }
                }

                if (-not $isNoCodeClosure) {
                    if (-not $handoff.psobject.Properties["commit_hash"] -or [string]::IsNullOrWhiteSpace($handoff.commit_hash)) {
                        $verificationPassed = $false
                        $errorMsg = "Handoff is missing 'commit_hash' metadata. Merge to master/main is mandatory. If this is a research/grooming task with no code changes (No-Code Closure), ensure the spec has 'type: research' in its frontmatter or uses an R-* task ID with no task branch."
                    } else {
                        $previousPreference = $ErrorActionPreference
                        $ErrorActionPreference = "Continue"
                        $commitExists = git rev-parse --verify "$($handoff.commit_hash)^{commit}" 2>$null
                        $commitExistsExitCode = $LASTEXITCODE
                        $ErrorActionPreference = $previousPreference
                        if ($commitExistsExitCode -ne 0 -or $commitExists -match "fatal") {
                            $verificationPassed = $false
                            $errorMsg = "Commit hash $($handoff.commit_hash) specified in handoff does not exist."
                        } else {
                            $mainBranch = Get-PrimaryBranchName

                            $gatePassed = $false
                            $GATE_DIR = Join-Path $sessionDir "global/gate_decisions"
                            if (Test-Path $GATE_DIR) {
                                $decisions = @(Get-ChildItem -Path $GATE_DIR -Filter ($handoff.task_id + "-*.json") |
                                    Where-Object { $_.Name -notmatch "gate_decision_.*_pending.json" } |
                                    Sort-Object LastWriteTime -Descending)
                                if ($decisions.Count -gt 0) {
                                    try {
                                        $latestDecision = Get-Content $decisions[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                                        $advancingOutcomes = @("accepted", "redirected")
                                        if ($advancingOutcomes -contains $latestDecision.outcome) {
                                            $gatePassed = $true
                                        }
                                    } catch {}
                                }
                            }

                            if ($gatePassed) {
                                git merge-base --is-ancestor $($handoff.commit_hash) $mainBranch 2>$null
                                if ($LASTEXITCODE -ne 0) {
                                    $verificationPassed = $false
                                    $errorMsg = "Commit $($handoff.commit_hash) is not merged into $mainBranch."
                                } else {
                                    $baseCommit = $null
                                    if ($handoff.psobject.Properties["base_commit"] -and -not [string]::IsNullOrWhiteSpace($handoff.base_commit)) {
                                        $baseCommit = [string]$handoff.base_commit
                                    } else {
                                        $taskBranchRef = "task/$($handoff.task_id)"
                                        git show-ref --verify --quiet "refs/heads/$taskBranchRef" 2>$null
                                        if ($LASTEXITCODE -eq 0) {
                                            $mbOut = (git merge-base $mainBranch $taskBranchRef 2>$null)
                                            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($mbOut)) {
                                                $baseCommit = $mbOut.Trim()
                                            }
                                        }
                                    }

                                    if ([string]::IsNullOrWhiteSpace($baseCommit)) {
                                        $verificationPassed = $false
                                        $errorMsg = "Merge verification failed: cannot resolve base commit via base_commit property or task/$($handoff.task_id) branch merge-base. If this is a No-Code Closure (research/grooming, no code), the task branch should not exist and the spec should have 'type: research'."
                                    } else {
                                        git merge-base --is-ancestor $($handoff.commit_hash) $baseCommit 2>$null
                                        if ($LASTEXITCODE -eq 0) {
                                            $verificationPassed = $false
                                            $errorMsg = "Commit $($handoff.commit_hash) is a baseline commit on $mainBranch and does not represent new merged work."
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (-not $verificationPassed) {
            Write-Host "`nError: Completion artifact verification failed for transition $transition" -ForegroundColor Red
            Write-Host "Reason: $errorMsg" -ForegroundColor Red
            Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "factory" `
                -Outcome "artifact_verification_failed" -Notes ("Artifact verification failed: " + $errorMsg)
            Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "artifact_verification_failed" -AttemptCount $handoff.cumulative_handoff_count `
                -LastSpecialist $handoff.source_phase -Summary $errorMsg
            exit 1
        }
    }
}

function Normalize-FactoryInputState {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    if ($null -eq $Context) {
        throw "FactoryContext is null."
    }
    $requiredKeys = @("Handoff", "LatestHandoff", "SessionDir", "Recover", "FrameworkPowerShell", "LogFile", "CircuitBreakerHistoryFile")
    foreach ($key in $requiredKeys) {
        if (-not $Context.ContainsKey($key) -or $null -eq $Context[$key]) {
            throw "Required key '$key' is missing from FactoryContext."
        }
    }

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
        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
        $workspacesDir = if ($Context.ContainsKey("WorkspacesDir")) { $Context.WorkspacesDir } else { Get-ConfiguredPath -Key "workspaces" -ProjectRoot $repoRoot }
        $wtPath = Resolve-ImplementationWorktreePath -TaskId $handoff.task_id -WorkspacesDir $workspacesDir

        $resolvedWtPath = if (Test-Path $wtPath) { (Resolve-Path $wtPath).Path } else { $wtPath }
        $resolvedRepoRoot = if (Test-Path $repoRoot) { (Resolve-Path $repoRoot).Path } else { $repoRoot }

        $normalizedArtifacts = @()
        foreach ($art in $handoff.artifacts) {
            if ([string]::IsNullOrWhiteSpace($art)) { continue }
            $fullArtPath = $art
            if (-not [System.IO.Path]::IsPathRooted($art)) {
                $wtCheck = Join-Path $resolvedWtPath $art
                if (Test-Path $wtCheck) {
                    $fullArtPath = (Resolve-Path $wtCheck).Path
                } else {
                    $repoCheck = Join-Path $resolvedRepoRoot $art
                    if (Test-Path $repoCheck) {
                        $fullArtPath = (Resolve-Path $repoCheck).Path
                    }
                }
            } else {
                if (Test-Path $art) {
                    $fullArtPath = (Resolve-Path $art).Path
                }
            }

            $relPath = $art
            if ([System.IO.Path]::IsPathRooted($fullArtPath)) {
                if ($fullArtPath.StartsWith($resolvedWtPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $relPath = $fullArtPath.Substring($resolvedWtPath.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar).TrimStart([System.IO.Path]::AltDirectorySeparatorChar)
                } elseif ($fullArtPath.StartsWith($resolvedRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $relPath = $fullArtPath.Substring($resolvedRepoRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar).TrimStart([System.IO.Path]::AltDirectorySeparatorChar)
                }
            } else {
                $wtRelPattern = "(\.crucible/)?\.agent-workspaces/implementation-[^/]+/(.+)"
                if ($relPath.Replace("\", "/") -match $wtRelPattern) {
                    $relPath = $Matches[2]
                }
            }

            $relPath = $relPath.Replace("\", "/").Trim()
            while ($relPath.StartsWith("./")) {
                $relPath = $relPath.Substring(2)
            }
            $relPath = $relPath.TrimStart("/")

            if (-not [string]::IsNullOrWhiteSpace($relPath)) {
                $normalizedArtifacts += $relPath
            }
        }

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
            Write-EventLog -Event "security_warning" -TaskId $handoff.task_id -Specialist $handoff.source_phase -Outcome "warned" -Notes ("Injection pattern detected: " + $match.RuleId)
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
        $staleLocks = Get-ChildItem -Path $LOCK_DIR -Filter ("*" + $handoff.task_id + "*" + $handoff.target_phase + "*")
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
        if ((Test-Path $staleTask) -and (-not $Recover)) {
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
        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
        $updateJson = @{ status = "recovering" } | ConvertTo-Json -Compress
        & "$FRAMEWORK_POWERSHELL/update-session-state.ps1" -Specialist $handoff.target_phase -TaskId $handoff.task_id -UpdateJson $updateJson -Merge $true -ProjectRoot $repoRoot

        # Log recovery_start for recoverable sessions.
        Write-EventLog -Event "recovery_start" -TaskId $handoff.task_id -Phase $handoff.target_phase -Notes "Recovering from: $recoveryMarker"
    }

    $validPhases = @($script:FACTORY_PHASES)
    if ($validPhases -notcontains $handoff.source_phase) {
        Write-Host ("Error: Invalid source_phase " + $handoff.source_phase) -ForegroundColor Red
        exit 1
    }
    if ($validPhases -notcontains $handoff.target_phase -and $handoff.target_phase -ne "done") {
        Write-Host ("Error: Invalid target_phase " + $handoff.target_phase) -ForegroundColor Red
        exit 1
    }
}

function Invoke-CircuitBreakerGates {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    if ($null -eq $Context) {
        throw "FactoryContext is null."
    }
    $requiredKeys = @("Handoff", "Ceiling", "LogFile", "CircuitBreakerHistoryFile", "FrameworkPowerShell", "RepoRoot", "WorkspacesDir")
    foreach ($key in $requiredKeys) {
        if (-not $Context.ContainsKey($key)) {
            throw "Required key '$key' is missing from FactoryContext."
        }
    }

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
        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
        if ($repoRoot -and (Test-Path -LiteralPath $repoRoot)) {
            $repoRoot = (Resolve-Path -LiteralPath $repoRoot).Path
        }
        
        $crucibleRoot = ".crucible"
        $configPath = Join-Path $repoRoot ".crucible/config.yaml"
        if (Test-Path -LiteralPath $configPath) {
            try {
                $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
                if ($content -match '(?m)^crucible_root:\s*["'']?([^"''\r\n]+)["'']?\s*$') {
                    $crucibleRoot = $Matches[1].Trim()
                }
            } catch {}
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
                        } catch {}
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
                                $detectedFile = ".crucible/session/$($handoff.task_id)/research/task.md"
                            }
                            $detectedRule = $m.RuleId
                            break
                        }
                    }
                } catch {}
            }
        }

        if ($hasBlockMatch) {
            if ($null -eq $handoff.psobject.Properties["suspicious_content"] -or $handoff.suspicious_content -eq "") {
                $distinctNotes = "researcher_silent_detector_hit: ${detectedFile}:$detectedRule"
                $summaryMsg = "Silent injection match in ${detectedFile}: $detectedRule (researcher silent detector hit)"

                Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "blocked" -Notes $distinctNotes
                Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "human_escalation" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist $handoff.source_phase -Summary $summaryMsg
                Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "human_escalation" `
                    -Why ($summaryMsg + ". Reason: Silent corroboration.") `
                    -RecoveryOverride ("Review external sources before continuing. File: " + $detectedFile + "; Rule: " + $detectedRule + ". Then archive the blocked record and run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId " + $handoff.task_id + " -Recover")
                exit 2
            }
        }
    }

    # Suspicious Content (Prompt Injection Defense - {task_id})
    if ($null -ne $handoff.psobject.Properties["suspicious_content"] -and $null -ne $handoff.suspicious_content -and $handoff.suspicious_content -ne "") {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "blocked" -Notes ("Suspicious Content Flagged: " + $handoff.suspicious_content)
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "human_escalation" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist $handoff.source_phase -Summary ("Suspicious content flagged in handoff: " + $handoff.suspicious_content)
        Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "human_escalation" `
            -Why ("Suspicious Content detected. Suspicious content flagged in handoff: " + $handoff.suspicious_content) `
            -RecoveryOverride ("Review external sources before continuing. Then archive the blocked record and run: powershell.exe -ExecutionPolicy Bypass -File `".crucible/powershell/factory.ps1`" -Init -TaskId " + $handoff.task_id + " -Recover")
        exit 2
    }

    # Handoff Retry Limit (defense-in-depth backstop).
    # No same-phase (X -> X) transition exists in validate-handoff.ps1's $validTransitions
    # map, so a schema-valid handoff can never satisfy source_phase == target_phase. This
    # guard only fires if a same-phase handoff bypasses validation and reaches the breaker
    # with retry > 2 -- an otherwise-impossible state we block rather than run. Persistent
    # re-review failure is covered live by the review_stalemate breaker below.
    if ($handoff.handoff_retry_count -gt 2 -and $handoff.source_phase -eq $handoff.target_phase) {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "blocked" -Notes "Persistent Task Failure - Retry over 2"
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "handoff_retry_exceeded" -AttemptCount $handoff.handoff_retry_count -LastSpecialist $handoff.target_phase -Summary "Persistent Task Failure - Retry over 2"
        Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "handoff_retry_exceeded" `
            -Why ("Task " + $handoff.task_id + " has been handed off to " + $handoff.target_phase + " " + $handoff.handoff_retry_count + " times. Reason: " + $handoff.reason)
        exit 2
    }

    # Review Strike-2 DEGRADED Warning
    if ($handoff.review_strike_count -eq 2 -and $handoff.target_phase -eq "implementation") {
        Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist $handoff.target_phase `
            -Outcome "warned" -Notes "Review strike 2 of 3: Architect should reduce scope"
        Write-Quiet ("`n[DEGRADED] Task " + $handoff.task_id + " has failed review twice.") -ForegroundColor Yellow
        Write-Quiet "  Strike count: 2 of 3. One more failure will BLOCK this task." -ForegroundColor Yellow
        Write-Quiet "  Architect DIRECTIVE: Do not attempt a full re-implementation." -ForegroundColor White
        Write-Quiet "  Consider: splitting the task, deferring the contentious part, or simplifying scope." -ForegroundColor White
    }

    # Review 3-Strike Rule
    if ($handoff.review_strike_count -ge 3) {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "blocked" -Notes "Review Stalemate - 3 strikes"
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "review_stalemate" -AttemptCount $handoff.review_strike_count -LastSpecialist $handoff.target_phase -Summary "Review Stalemate - 3 strikes"
        Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "review_stalemate" `
            -Why ("Task " + $handoff.task_id + " has failed review " + $handoff.review_strike_count + " times. Reason: " + $handoff.reason)
        exit 2
    }

    # Token Budget Enforcement
    if ($handoff.budget_tier) {
        if (-not [string]::IsNullOrWhiteSpace($invalidBudgetTier)) {
            Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "invalid_budget_tier" `
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
            Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "budget_exceeded" -Notes ("Token Budget Exceeded - " + $handoff.cumulative_handoff_count + " over " + $effectiveCeiling)
            Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "budget_exceeded" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist $handoff.source_phase -Summary ("Token Budget Exceeded - " + $handoff.cumulative_handoff_count + " over " + $effectiveCeiling)
            Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "budget_exceeded" `
                -Why ("Task " + $handoff.task_id + " has reached " + $handoff.cumulative_handoff_count + " handoffs. Ceiling: " + $effectiveCeiling + " for tier " + $handoff.budget_tier + " (base " + $ceiling + " + " + $rebaseCycles + " rebase cycle(s)). Reason: " + $handoff.reason)
            exit 2
        }
    }

    # Recurring Merge Conflicts
    if ($handoff.psobject.Properties["rebase_count"] -and $handoff.rebase_count -ge 3) {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "blocked" -Notes "Recurring Merge Conflicts - 3 strikes"
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "recurring_merge_conflicts" -AttemptCount $handoff.rebase_count -LastSpecialist $handoff.target_phase -Summary "Recurring Merge Conflicts - 3 strikes. Task requires manual intervention."
        Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "recurring_merge_conflicts" `
            -Why ("Task " + $handoff.task_id + " has been rebased " + $handoff.rebase_count + " times and still conflicts.")
        exit 2
    }

    # A-2: Independent isolated test verification before accepting APPROVED ({task_id}, {task_id})
    if ($handoff.source_phase -eq "verification" -and $handoff.target_phase -eq "deployment") {
        $wtPath = Resolve-ImplementationWorktreePath -TaskId $handoff.task_id
        $isolatedChecksScript = "$FRAMEWORK_POWERSHELL/run-isolated-checks.ps1"
        if (Test-Path $wtPath) {
            if (-not (Test-Path $isolatedChecksScript)) {
                Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "missing_isolated_checks_script" `
                    -Why ("Missing isolated checks script: " + $isolatedChecksScript)
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
                if (Test-Path $LOG_FILE) {
                    $lines = @(Get-Content $LOG_FILE -Tail 200 -Encoding UTF8)
                    for ($i = $lines.Length - 1; $i -ge 0; $i--) {
                        try {
                            $cleanedLine = $lines[$i] -replace "^$([char]0xFEFF)", ""
                            $entry = $cleanedLine | ConvertFrom-Json
                            $logPhase = if ($entry.PSObject.Properties["phase"]) { $entry.phase } else { $entry.specialist }
                             if ($entry.task_id -eq $handoff.task_id -and $logPhase -eq "factory") {
                                 continue
                             }
                             if ($entry.task_id -eq $handoff.task_id -and $logPhase -ne $handoff.source_phase) {
                                break
                            }
                            if ($entry.task_id -eq $handoff.task_id -and $logPhase -eq $handoff.source_phase -and $entry.event -eq "session_end" -and $entry.outcome -eq "success") {
                                $entryHandoffCount = if ($entry.PSObject.Properties["handoff_count"]) { $entry.handoff_count } else { 0 }
                                if ($entryHandoffCount -lt $handoff.cumulative_handoff_count) {
                                    break
                                }
                            }
                            if ($entry.task_id -eq $handoff.task_id -and $logPhase -eq $handoff.source_phase -and $entry.event -eq "quality_gate_retry" -and $entry.notes -like "*verification*check*") {
                                $hasPriorRetry = $true
                                break
                            }
                        } catch { continue }
                    }
                }

                if ($hasPriorRetry) {
                    Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "factory" -Outcome "reviewer_verification_failed" -Notes "Independent verification failed after Reviewer APPROVED again: $failedCheck"
                    Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "reviewer_verification_failed" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist "verification" -Summary "Verification command failed in worktree after Reviewer self-reported APPROVED: $failedCheck"
                    $reviewerVerificationWhy = "Independent verification check failed on retry: " + $failedCheck + ". Route back to Architect."
                    if ($testOutput) {
                        $testOutputSummary = (($testOutput | ForEach-Object { [string]$_ }) -join " ")
                        $reviewerVerificationWhy = "Independent verification check failed on retry: " + $failedCheck + ". Check output: " + $testOutputSummary + ". Route back to Architect."
                    }
                    Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "reviewer_verification_failed" `
                        -Why $reviewerVerificationWhy
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
            Write-EventLog -Event "verified" -TaskId $handoff.task_id -Specialist "factory" -Outcome "tests_passed" -Notes "Independent isolated verification passed before Operator handoff"
        } else {
            Write-Quiet "[VERIFY] WARN: Worktree not found at $wtPath - skipping independent test verification." -ForegroundColor Yellow
        }
    }
}

function Invoke-GitChecked {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $stdout = @()
        $stderr = @()
        
        $pipeline = & $ScriptBlock 2>&1
        
        foreach ($item in $pipeline) {
            if ($item -is [System.Management.Automation.ErrorRecord]) {
                $stderr += $item.ToString()
            } else {
                $stdout += $item
            }
        }
        
        $exitCode = $LASTEXITCODE
        
        if ($stderr.Count -gt 0) {
            $errMessage = $stderr -join "`n"
            if ($exitCode -eq 0) {
                Write-Quiet $errMessage.Trim()
            } else {
                Write-Error -Message $errMessage.Trim() -ErrorAction Continue
            }
        }
        
        if ($stdout.Count -gt 0) {
            $stdout
        }
    } finally {
        $ErrorActionPreference = $prevEAP
        $global:LASTEXITCODE = $exitCode
    }
}

function Invoke-HumanGateMerge {
    # Merges task/$TaskId into $PrimaryBranch at the accept gate. A clean merge returns
    # "merged". On conflict it NEVER leaves the tree mid-merge: it aborts, then attempts
    # to auto-rebase the task branch onto the advanced primary branch inside its worktree.
    # A clean rebase (git resolved non-overlapping changes) is re-validated and the merge
    # retried -> "merged". A genuine same-line conflict cannot be resolved mechanically, so
    # the branch is left intact and the task is routed back to implementation via a
    # sanctioned re-entry handoff with rebase_count bumped -> "rework". Once rebase_count
    # would exceed MaxRebaseAttempts the recurring-conflict circuit breaker trips ->
    # "breaker". Any unexpected post-rebase failure also routes to "rework".
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$PrimaryBranch,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        $Handoff = $null,
        [int]$MaxRebaseAttempts = 3,
        [string]$CheckScript = "",
        [string]$HandoffScript = ""
    )

    if ([string]::IsNullOrEmpty($CheckScript)) {
        $CheckScript = Join-Path (Split-Path -Parent $PSScriptRoot) "run-isolated-checks.ps1"
    }
    if ([string]::IsNullOrEmpty($HandoffScript)) {
        $HandoffScript = Join-Path (Split-Path -Parent $PSScriptRoot) "new-handoff.ps1"
    }

    # The CLI gate persists an "accepted" decision BEFORE calling this action (the
    # reject path's rework handoff depends on that ordering). When an accepted merge
    # does not complete -- it routes to rework or trips the breaker -- that premature
    # "accepted" record must be removed, or the deployment->done completion guard will
    # see it on the next run and block the retry (commit not merged into primary).
    $removePrematureAccept = {
        try {
            $sessDir = Get-ConfiguredPath -Key "session" -ProjectRoot $ProjectRoot
            $gdDir = Join-Path $sessDir "global/gate_decisions"
            if (Test-Path $gdDir) {
                $candidates = @(Get-ChildItem -Path $gdDir -Filter ($TaskId + "-*.json") -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending)
                foreach ($f in $candidates) {
                    try {
                        $d = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                        if ($d.outcome -eq "accepted") {
                            Remove-Item -Path $f.FullName -Force
                            Write-Quiet "[HUMAN GATE] Removed premature 'accepted' gate decision $($f.Name) (merge did not complete)."
                            break
                        }
                    } catch {}
                }
            }
        } catch {}
    }

    Write-Quiet "[HUMAN GATE] Merging branch task/$TaskId into $PrimaryBranch..."
    Invoke-GitChecked { git checkout $PrimaryBranch } | Out-Null
    Invoke-GitChecked { git merge --no-ff --no-edit "task/$TaskId" } | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return "merged"
    }

    # Conflict: restore the tree first so the adopter is never left mid-merge.
    Write-Host "[HUMAN GATE] task/$TaskId conflicts with $PrimaryBranch; aborting merge and attempting auto-rebase..." -ForegroundColor Yellow
    Invoke-GitChecked { git merge --abort } | Out-Null

    $currentRebase = 0
    if ($null -ne $Handoff -and $Handoff.PSObject.Properties["rebase_count"]) {
        $currentRebase = [int]$Handoff.rebase_count
    }
    $nextRebase = $currentRebase + 1

    if ($nextRebase -gt $MaxRebaseAttempts) {
        Write-EventLog -Event "circuit_breaker" -TaskId $TaskId -Specialist "deployment" -Outcome "blocked" -Notes "Recurring Merge Conflicts - $MaxRebaseAttempts strikes at human gate"
        if (Get-Command Write-BlockedTaskRecord -ErrorAction SilentlyContinue) {
            Write-BlockedTaskRecord -TaskId $TaskId -CircuitBreaker "recurring_merge_conflicts" -AttemptCount $currentRebase -LastSpecialist "deployment" -Summary "Recurring Merge Conflicts at human gate. Manual conflict resolution required."
        }
        Write-WedgeReport -TaskId $TaskId -SourcePhase "deployment" -TargetPhase "deployment" -BreakerCode "recurring_merge_conflicts" `
            -Why "Recurring Merge Conflicts: task/$TaskId rebased $currentRebase time(s) and still conflicts with $PrimaryBranch. Reduce scope or resolve the conflict manually."
        & $removePrematureAccept
        return "breaker"
    }

    $workspacesDir = Get-ConfiguredPath -Key "workspaces" -ProjectRoot $ProjectRoot
    $wtPath = Resolve-ImplementationWorktreePath -TaskId $TaskId -WorkspacesDir $workspacesDir

    $rebaseClean = $false
    if (Test-Path $wtPath) {
        Write-Quiet "[HUMAN GATE] Rebasing task/$TaskId onto $PrimaryBranch in $wtPath..."
        # EAP guard: PS 5.1 wraps a native command's stderr as a terminating
        # ErrorRecord under 'Stop'. git rebase writes progress/conflict text to
        # stderr, so run it under Continue and gate purely on the exit code.
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $rebaseOut = & git -C $wtPath rebase $PrimaryBranch 2>&1
            $rebaseExit = $LASTEXITCODE
            foreach ($line in @($rebaseOut)) { Write-Quiet ([string]$line) }
            if ($rebaseExit -eq 0) {
                $rebaseClean = $true
            } else {
                & git -C $wtPath rebase --abort 2>&1 | Out-Null
            }
        } finally {
            $ErrorActionPreference = $prevEAP
        }
    }

    if ($rebaseClean) {
        Write-Quiet "[HUMAN GATE] Auto-rebase clean; re-running isolated checks before merge..."
        $checksOk = $true
        if (Test-Path $CheckScript) {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CheckScript -TaskId $TaskId -Mode full -ProjectRoot $ProjectRoot | Out-Null
            if ($LASTEXITCODE -ne 0) { $checksOk = $false }
        }
        if ($checksOk) {
            Invoke-GitChecked { git checkout $PrimaryBranch } | Out-Null
            Invoke-GitChecked { git merge --no-ff --no-edit "task/$TaskId" } | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Quiet "[HUMAN GATE] Auto-rebase resolved the conflict; merge succeeded."
                return "merged"
            }
            Invoke-GitChecked { git merge --abort } | Out-Null
            Write-Host "[HUMAN GATE] Post-rebase merge still failed unexpectedly; routing to rework." -ForegroundColor Yellow
        } else {
            Write-Host "[HUMAN GATE] Isolated checks failed after rebase; routing to rework." -ForegroundColor Yellow
        }
    }

    # Genuine conflict (or post-rebase failure): route back to implementation for a
    # specialist to rebase and resolve. Leave $PrimaryBranch clean and unpushed.
    Invoke-GitChecked { git checkout $PrimaryBranch } | Out-Null
    $reason = "Rebase conflict: task/$TaskId no longer applies cleanly onto $PrimaryBranch (rebase attempt $nextRebase/$MaxRebaseAttempts). Rebase onto $PrimaryBranch in the worktree, resolve conflicts, and re-run the pipeline."
    Write-Host "[HUMAN GATE] $reason" -ForegroundColor Yellow

    if (-not (Test-Path $wtPath)) {
        Invoke-GitChecked { git worktree prune } | Out-Null
        Invoke-GitChecked { git worktree add $wtPath "task/$TaskId" } | Out-Null
    }

    if (Test-Path $HandoffScript) {
        $sessionCycleId = ""
        $artifacts = @()
        if ($null -ne $Handoff) {
            if ($Handoff.PSObject.Properties["session_cycle_id"]) {
                $sessionCycleId = $Handoff.session_cycle_id
            } elseif ($Handoff.PSObject.Properties["cycle_id"]) {
                $sessionCycleId = $Handoff.cycle_id
            }
            if ($Handoff.PSObject.Properties["artifacts"]) {
                $artifacts = $Handoff.artifacts
            }
        }
        $handoffParams = @{
            TaskId      = $TaskId
            Source      = "deployment"
            Target      = "implementation"
            Reason      = $reason
            RebaseCount = $nextRebase
            ProjectRoot = $ProjectRoot
        }
        if (-not [string]::IsNullOrEmpty($sessionCycleId)) {
            $handoffParams["SessionCycleId"] = $sessionCycleId
        }
        if ($artifacts.Count -gt 0) {
            $handoffParams["Artifacts"] = @($artifacts)
        }
        & $HandoffScript @handoffParams | Out-Null
    }
    & $removePrematureAccept
    return "rework"
}

function Get-BacklogItemPathForTaskProjectRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [string]$ProjectRoot = ""
    )

    $typeDir = if ($Task -match "^F-") {
        "features"
    } elseif ($Task -match "^B-") {
        "bugs"
    } elseif ($Task -match "^C-") {
        "chores"
    } else {
        ""
    }

    $typeDirs = if ([string]::IsNullOrWhiteSpace($typeDir)) {
        @("features", "bugs", "chores")
    } else {
        @($typeDir)
    }

    $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $ProjectRoot
    foreach ($dir in $typeDirs) {
        $activeMatch = Get-ChildItem -Path (Join-Path $backlogDir ($dir + "/active")) -Filter ($Task + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $activeMatch) {
            return $activeMatch.FullName
        }

        $rootMatch = Get-ChildItem -Path (Join-Path $backlogDir $dir) -Filter ($Task + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $rootMatch) {
            return $rootMatch.FullName
        }

        $archivedMatch = Get-ChildItem -Path (Join-Path $backlogDir ($dir + "/archived")) -Filter ($Task + "_*.md") -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $archivedMatch) {
            return $archivedMatch.FullName
        }
    }

    return ""
}

function Get-TaskFinalizationDetails {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$ProjectRoot = ""
    )

    $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $ProjectRoot
    $backlogPath = Join-Path $backlogDir "BACKLOG.md"

    $result = [ordered]@{
        IsFinalized = $false
        BacklogStatus = ""
        SpecExistsInActive = $false
        SpecPathInActive = ""
        SpecExistsInArchived = $false
        SpecPathInArchived = ""
        SpecStatusMatches = $false
        Error = ""
    }

    if (-not (Test-Path -LiteralPath $backlogPath)) {
        $result.Error = "BACKLOG.md not found at $backlogPath"
        return [pscustomobject]$result
    }

    # Load archive-task helper if not loaded
    $archiveLibPath = Join-Path $PSScriptRoot "archive-task.ps1"
    if (-not (Get-Command "Get-MarkdownTableStatusColumn" -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath $archiveLibPath) {
            . $archiveLibPath
        } else {
            throw "archive-task helper not found at $archiveLibPath"
        }
    }

    # 1. Search spec paths first
    $typeDirs = @("features", "bugs", "chores")
    foreach ($dir in $typeDirs) {
        $activeMatch = Get-ChildItem -Path (Join-Path $backlogDir ($dir + "/active")) -Filter ($TaskId + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $activeMatch) {
            $result.SpecExistsInActive = $true
            $result.SpecPathInActive = $activeMatch.FullName
        }

        $archivedMatch = Get-ChildItem -Path (Join-Path $backlogDir ($dir + "/archived")) -Filter ($TaskId + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $archivedMatch) {
            $result.SpecExistsInArchived = $true
            $result.SpecPathInArchived = $archivedMatch.FullName
        }
    }

    # 2. Parse BACKLOG.md to find status of TaskId (ignoring Priority Summary table rows)
    $lines = [System.IO.File]::ReadAllLines($backlogPath, [System.Text.Encoding]::UTF8)
    $taskRowIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*\|' -and $line -notmatch '^\s*\|\s*(\*\*P[0-3]\*\*|Priority)\s*\|' -and $line -match [regex]::Escape($TaskId)) {
            $taskRowIndex = $i
            break
        }
    }

    if ($taskRowIndex -lt 0) {
        $result.Error = "TaskId $TaskId not found in BACKLOG.md item tables."
        return [pscustomobject]$result
    }

    # Locate Status column index using table header helper
    $statusColIndex = Get-MarkdownTableStatusColumn -Lines ([string[]]$lines) -RowIndex $taskRowIndex
    if ($statusColIndex -ge 0) {
        $cells = @($lines[$taskRowIndex].Trim().Trim("|").Split("|") | ForEach-Object { $_.Trim() })
        if ($cells.Count -gt $statusColIndex) {
            $result.BacklogStatus = $cells[$statusColIndex]
        }
    }

    if ([string]::IsNullOrEmpty($result.BacklogStatus)) {
        $result.Error = "Unable to determine Status for task $TaskId in BACKLOG.md"
        return [pscustomobject]$result
    }

    # 3. Check frontmatter status matches and status is terminal
    $isTerminalStatus = ($result.BacklogStatus -ieq "Production" -or $result.BacklogStatus -ieq "Resolved")
    
    $specToRead = if ($result.SpecExistsInArchived) { $result.SpecPathInArchived } else { $result.SpecPathInActive }
    $specStatus = ""
    if (-not [string]::IsNullOrEmpty($specToRead) -and (Test-Path -LiteralPath $specToRead)) {
        $fmStr = [string](Get-Content -LiteralPath $specToRead -Head 15 -Encoding UTF8)
        if ($fmStr -match 'status:\s*["'']?([^"''\s\r\n]+)"?') {
            $specStatus = $matches[1]
        }
    }

    $result.SpecStatusMatches = ($specStatus -ieq $result.BacklogStatus)
    $result.IsFinalized = ($isTerminalStatus -and $result.SpecExistsInArchived -and -not $result.SpecExistsInActive -and $result.SpecStatusMatches)

    return [pscustomobject]$result
}

function Restore-BacklogTask {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$ProjectRoot = "",
        [string]$ActiveStatus = "In Progress"
    )
    $resolvedProjectRoot = if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $ProjectRoot
    } else {
        $repoRootVar = Get-Variable -Name "REPO_ROOT" -ErrorAction SilentlyContinue
        if ($null -ne $repoRootVar) { $repoRootVar.Value } else { (Get-Location).Path }
    }
    
    $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $resolvedProjectRoot
    $backlogPath = Join-Path $backlogDir "BACKLOG.md"
    if (-not (Test-Path -LiteralPath $backlogPath)) { return }

    # Find the spec (either in archived/ or active/)
    $typeDirs = @("features", "bugs", "chores")
    $specPath = ""
    $type = ""
    $isArchived = $false
    foreach ($dir in $typeDirs) {
        $archivedMatch = Get-ChildItem -Path (Join-Path $backlogDir ($dir + "/archived")) -Filter ($TaskId + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $archivedMatch) {
            $specPath = $archivedMatch.FullName
            $type = $dir
            $isArchived = $true
            break
        }
        $activeMatch = Get-ChildItem -Path (Join-Path $backlogDir ($dir + "/active")) -Filter ($TaskId + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $activeMatch) {
            $specPath = $activeMatch.FullName
            $type = $dir
            $isArchived = $false
            break
        }
    }

    if ([string]::IsNullOrEmpty($specPath)) { return }

    $fileName = Split-Path -Leaf $specPath
    $activeDir = Join-Path $backlogDir "$type/active"
    if (-not (Test-Path $activeDir)) {
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
    }
    $activeSpecPath = Join-Path $activeDir $fileName
    if ($isArchived) {
        Move-Item -LiteralPath $specPath -Destination $activeSpecPath -Force
    }

    # Restore frontmatter status
    $archiveLibPath = Join-Path $PSScriptRoot "archive-task.ps1"
    if (-not (Get-Command "Set-BacklogSpecFrontmatterStatus" -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath $archiveLibPath) { . $archiveLibPath }
    }
    if (Get-Command "Set-BacklogSpecFrontmatterStatus" -ErrorAction SilentlyContinue) {
        Set-BacklogSpecFrontmatterStatus -Path $activeSpecPath -Status $ActiveStatus
    }

    # Restore and normalize BACKLOG.md row
    $relativeActive = "$type/active/$fileName".Replace("\", "/")
    $relativeArchived = "$type/archived/$fileName".Replace("\", "/")
    
    Invoke-WithBacklogLock -BacklogPath $backlogPath -ScriptBlock {
        $rawLines = [System.IO.File]::ReadAllLines($backlogPath, [System.Text.Encoding]::UTF8)
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $rawLines) { [void]$lines.Add($line) }

        # 1. Find and extract row matching TaskId (ignoring Priority Summary table rows)
        $matchingIndexes = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^\s*\|' -and $line -notmatch '^\s*\|\s*(\*\*P[0-3]\*\*|Priority)\s*\|' -and $line -match ('\b' + [regex]::Escape($TaskId) + '\b')) {
                $matchingIndexes += $i
            }
        }
        $matchingRow = ""
        if ($matchingIndexes.Count -gt 0) {
            $matchingRow = $lines[$matchingIndexes[0]]
            for ($d = $matchingIndexes.Count - 1; $d -ge 0; $d--) {
                $lines.RemoveAt($matchingIndexes[$d])
            }
        } else {
            $matchingRow = "| [$TaskId]($relativeActive) | P2 | $ActiveStatus | $TaskId | Operator |"
        }

        # 2. Remove bespoke sections like ## Production Items
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match '^\s*##\s+Production\s+Items') {
                $removeCount = 1
                while (($i + $removeCount) -lt $lines.Count -and $lines[$i + $removeCount] -notmatch '^\s*##\s+') {
                    $removeCount++
                }
                for ($r = 0; $r -lt $removeCount; $r++) {
                    $lines.RemoveAt($i)
                }
            }
        }

        # 3. Update row link: convert /archived/ link to /active/ link
        $matchingRow = $matchingRow -replace '/archived/', '/active/'
        if (-not $matchingRow.Contains("]($relativeActive)")) {
            $matchingRow = $matchingRow -replace '\]\([^)]*' + [regex]::Escape($TaskId) + '[^)]*\)', "]($relativeActive)"
        }

        # 4. Re-insert row under correct active section (after table separator)
        $targetHeader = switch ($type) {
            "features" { "## Features" }
            "bugs"     { "## Bugs" }
            "chores"   { "## Chores" }
            default    { "## Features" }
        }

        $mainIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq $targetHeader -or $lines[$i].Trim() -eq "## Active Items") {
                $insertIdx = $i + 1
                while ($insertIdx -lt $lines.Count -and ($lines[$insertIdx] -match '^\s*\|' -or [string]::IsNullOrWhiteSpace($lines[$insertIdx]))) {
                    if ($lines[$insertIdx] -match '^\s*\|') {
                        $insertIdx++
                        if ($insertIdx -lt $lines.Count -and $lines[$insertIdx] -match '^\s*\|?\s*:?-{3,}:?\s*') {
                            $insertIdx++
                        }
                        break
                    }
                    $insertIdx++
                }
                $lines.Insert($insertIdx, $matchingRow)
                $mainIdx = $insertIdx
                break
            }
        }
        if ($mainIdx -lt 0) {
            [void]$lines.Add($matchingRow)
            $mainIdx = $lines.Count - 1
        }

        $lineArray = [string[]]$lines.ToArray()
        if (-not (Get-Command "Get-MarkdownTableStatusColumn" -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath $archiveLibPath) { . $archiveLibPath }
        }
        if (Get-Command "Get-MarkdownTableStatusColumn" -ErrorAction SilentlyContinue) {
            $statusColumn = Get-MarkdownTableStatusColumn -Lines $lineArray -RowIndex $mainIdx
            if ($statusColumn -ge 0) {
                $cells = [System.Collections.Generic.List[string]]::new()
                foreach ($cell in $lines[$mainIdx].Trim().Trim("|").Split("|")) {
                    [void]$cells.Add($cell.Trim())
                }
                if ($statusColumn -lt $cells.Count) {
                    $cells[$statusColumn] = $ActiveStatus
                    $lines[$mainIdx] = "| " + (($cells.ToArray()) -join " | ") + " |"
                }
            }
        }

        [System.IO.File]::WriteAllText($backlogPath, (($lines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    }

    # Reconcile Priority-Summary and validate
    $validateScript = Join-Path (Split-Path -Parent $PSScriptRoot) "validate-backlog.ps1"
    if (Test-Path $validateScript) {
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $validateScript -FixSummary -ProjectRoot $resolvedProjectRoot | Out-Null
    }
}

function Invoke-HumanGateAction {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Outcome,
        [string]$ProjectRoot = "",
        [string]$SourcePhase = "deployment",
        [string]$GateReason = ""
    )
    $primaryBranch = Get-PrimaryBranchName
    $resolvedProjectRoot = if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $ProjectRoot
    } else {
        $repoRootVar = Get-Variable -Name "REPO_ROOT" -ErrorAction SilentlyContinue
        if ($null -ne $repoRootVar) { $repoRootVar.Value } else { (Get-Location).Path }
    }

    if ($Outcome -eq "accepted" -or $Outcome -eq "redirected") {

        $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $resolvedProjectRoot
        $backlogPath = Join-Path $backlogDir "BACKLOG.md"

        $finalizationOk = $true
        if (Test-Path -LiteralPath $backlogPath) {
            $backlogContent = Get-Content -LiteralPath $backlogPath -Raw -Encoding UTF8
            if ($backlogContent -match [regex]::Escape($TaskId)) {
                $finalization = Get-TaskFinalizationDetails -TaskId $TaskId -ProjectRoot $resolvedProjectRoot
                if (-not $finalization.IsFinalized) {
                    Write-Host "`n[D44] INFO: Task $TaskId was not explicitly finalized before accept/push. Auto-finalizing fallback now..." -ForegroundColor Yellow

                    # Locate active spec
                    $activeSpecPath = Get-BacklogItemPathForTaskProjectRoot -Task $TaskId -ProjectRoot $resolvedProjectRoot
                    if ([string]::IsNullOrEmpty($activeSpecPath) -or -not (Test-Path -LiteralPath $activeSpecPath)) {
                        Write-Host "[D44] ERROR: Active spec path not found for task $TaskId. Auto-finalization failed." -ForegroundColor Red
                        $finalizationOk = $false
                    } elseif ($activeSpecPath -match '(?i)[/\\]archived[/\\]') {
                        Write-Host "[D44] INFO: Task spec for $TaskId is already archived at $activeSpecPath." -ForegroundColor Green
                    } else {
                        # Load archive-task helper
                        $archiveLibPath = Join-Path $PSScriptRoot "archive-task.ps1"
                        if (-not (Get-Command "Invoke-BacklogTaskArchive" -ErrorAction SilentlyContinue)) {
                            if (Test-Path -LiteralPath $archiveLibPath) {
                                . $archiveLibPath
                            } else {
                                throw "archive-task helper not found at $archiveLibPath"
                            }
                        }

                        # Perform archival
                        try {
                            $archiveParams = @{
                                BacklogPath = $backlogPath
                                SpecPath = $activeSpecPath
                            }
                            if ($SourcePhase -eq "grooming") {
                                $archiveParams["Status"] = "Resolved"
                            }
                            $archiveResult = Invoke-BacklogTaskArchive @archiveParams
                            Write-Host ("[D44] SUCCESS: Auto-archived task as {0} (status {1}): {2}" -f $archiveResult.Type, $archiveResult.Status, $archiveResult.ArchivedRelPath) -ForegroundColor Green
                        } catch {
                            Write-Host ("[D44] ERROR: Archival failed for task $TaskId. Error: " + $_.Exception.Message) -ForegroundColor Red
                            $finalizationOk = $false
                        }

                        # Re-verify after archiving
                        if ($finalizationOk) {
                            $reverify = Get-TaskFinalizationDetails -TaskId $TaskId -ProjectRoot $resolvedProjectRoot
                            if (-not $reverify.IsFinalized) {
                                Write-Host "[D44] ERROR: Task $TaskId is still not finalized after archival attempt. Details: $($reverify | ConvertTo-Json -Compress)" -ForegroundColor Red
                                $finalizationOk = $false
                            }
                        }
                    }
                }
            }
        }

        if (-not $finalizationOk) {
            Write-Host "[D44] STOP: Auto-finalization failed for $TaskId; refusing to push. The merge remains LOCAL only. Run archive-task.ps1 for $TaskId, then re-run the gate with -GateOutcome accepted." -ForegroundColor Red
            
            $logVar = Get-Variable -Name "LOG_FILE" -ErrorAction SilentlyContinue
            $resolvedLogFile = if ($null -ne $logVar) { $logVar.Value } else { $null }

            if (-not [string]::IsNullOrEmpty($resolvedLogFile)) {
                try {
                    $cbVar = Get-Variable -Name "CB_HISTORY_FILE" -ErrorAction SilentlyContinue
                    $resolvedCBHistoryFile = if ($null -ne $cbVar) { $cbVar.Value } else { $null }
                    
                    Write-EventLog -Event "quality_gate_retry" -TaskId $TaskId -Phase "deployment" `
                        -Outcome "retry_required" -Notes "Auto-finalization failed at human gate; push withheld" `
                        -LogFile $resolvedLogFile -CircuitBreakerHistoryFile $resolvedCBHistoryFile
                } catch {
                    Write-Host "[D44] WARNING: Failed to write quality_gate_retry event: $_" -ForegroundColor Yellow
                }
            }
            exit 2
        }

        if ($SourcePhase -ne "grooming") {
            $hasTaskBranch = $false
            git show-ref --quiet "refs/heads/task/$TaskId"
            if ($LASTEXITCODE -eq 0) {
                $hasTaskBranch = $true
            }
            if ($hasTaskBranch) {
                $gateHandoff = $null
                $ghVar = Get-Variable -Name "handoff" -ErrorAction SilentlyContinue
                if ($null -ne $ghVar) { $gateHandoff = $ghVar.Value }
                $mergeResult = Invoke-HumanGateMerge -TaskId $TaskId -PrimaryBranch $primaryBranch -ProjectRoot $resolvedProjectRoot -Handoff $gateHandoff
                if ($mergeResult -eq "rework") {
                    # Auto-rebase hit a genuine conflict; task routed back to implementation.
                    # Repo is clean and unpushed. Exit 3 signals "not shipped, rework queued".
                    Write-Host "[HUMAN GATE] task/$TaskId routed back to implementation for rebase-conflict rework. Nothing was pushed; re-run the pipeline to resolve." -ForegroundColor Cyan
                    exit 3
                } elseif ($mergeResult -eq "breaker") {
                    exit 2
                } elseif ($mergeResult -ne "merged") {
                    Write-Host "[ERROR] git merge --no-ff --no-edit task/$TaskId failed!" -ForegroundColor Red
                    exit 1
                }
            }

            $autoPushVal = Get-ConfiguredReview -Key "auto_push" -ProjectRoot $resolvedProjectRoot
            $autoPush = $false
            if ($autoPushVal -eq "true") {
                $autoPush = $true
            }
            $requireGreenCiVal = Get-ConfiguredReview -Key "require_green_ci" -ProjectRoot $resolvedProjectRoot
            $requireGreenCi = $false
            if ($requireGreenCiVal -eq "true") {
                $requireGreenCi = $true
            }
            $ciTimeoutVal = Get-ConfiguredReview -Key "ci_timeout_minutes" -ProjectRoot $resolvedProjectRoot
            $ciTimeoutMinutes = 20
            if (-not [string]::IsNullOrWhiteSpace($ciTimeoutVal)) {
                $parsedTimeout = 0
                if ([int]::TryParse($ciTimeoutVal, [ref]$parsedTimeout) -and $parsedTimeout -ge 0) {
                    $ciTimeoutMinutes = $parsedTimeout
                }
            }
            $ciQueuedGraceVal = Get-ConfiguredReview -Key "ci_queued_grace_minutes" -ProjectRoot $resolvedProjectRoot
            $ciQueuedGraceMinutes = 15
            if (-not [string]::IsNullOrWhiteSpace($ciQueuedGraceVal)) {
                $parsedGrace = 0
                if ([int]::TryParse($ciQueuedGraceVal, [ref]$parsedGrace) -and $parsedGrace -ge 0) {
                    $ciQueuedGraceMinutes = $parsedGrace
                }
            }
            $ciRequiredChecks = Get-ConfiguredReview -Key "ci_required_checks" -ProjectRoot $resolvedProjectRoot
            $ciPostPushWatchVal = Get-ConfiguredReview -Key "ci_post_push_watch" -ProjectRoot $resolvedProjectRoot
            $ciPostPushWatch = ($ciPostPushWatchVal -eq "true")
            $mergedSha = (git rev-parse HEAD 2>$null).Trim()

            if ($autoPush) {
                $remotes = @(Invoke-GitChecked { git remote 2>$null })
                if ($remotes -contains "origin") {
                    if ($requireGreenCi) {
                        $ciStagingPrefixVal = Get-ConfiguredReview -Key "ci_staging_branch_prefix" -ProjectRoot $resolvedProjectRoot
                        $ciStagingPrefix = "crucible-ci"
                        if (-not [string]::IsNullOrWhiteSpace($ciStagingPrefixVal)) {
                            $ciStagingPrefix = $ciStagingPrefixVal.TrimEnd('/')
                        }
                        $stagingBranch = "$ciStagingPrefix/$TaskId"

                        Write-Host ("[HUMAN GATE] Publishing CI staging ref origin/" + $stagingBranch + "...") -ForegroundColor Cyan
                        Invoke-GitChecked { git push origin ("$mergedSha" + ":refs/heads/" + $stagingBranch) --force }
                        if ($LASTEXITCODE -ne 0) {
                            Write-Host ("[ERROR] Failed to publish CI staging ref " + $stagingBranch + ". Please check network/credentials.") -ForegroundColor Red
                            exit 1
                        }

                        $watchScript = Join-Path (Split-Path -Parent $PSScriptRoot) "watch-adopter-ci.ps1"
                        Write-Host ("[HUMAN GATE] Watching origin CI for " + $mergedSha + " on staging ref " + $stagingBranch + " before finalizing...") -ForegroundColor Cyan
                        $watchCmdArgs = @("-Commit", $mergedSha, "-TimeoutMinutes", $ciTimeoutMinutes, "-QueuedGraceMinutes", $ciQueuedGraceMinutes, "-CrucibleRoot", $resolvedProjectRoot)
                        if (-not [string]::IsNullOrWhiteSpace($ciRequiredChecks)) {
                            $watchCmdArgs += @("-RequiredJobs", $ciRequiredChecks)
                        }
                        $ciOutput = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $watchScript @watchCmdArgs 2>&1)
                        $ciExitCode = $LASTEXITCODE
                        foreach ($line in $ciOutput) {
                            Write-Host $line
                        }

                        if ($ciExitCode -eq 0) {
                            Write-Quiet "[HUMAN GATE] Pushing merged changes to origin/$primaryBranch..."
                            Invoke-GitChecked { git push origin $primaryBranch }
                            if ($LASTEXITCODE -ne 0) {
                                Write-Host "[ERROR] git push failed. Please check network/credentials or run manually." -ForegroundColor Red
                                exit 1
                            }
                            Invoke-GitChecked { git push origin --delete $stagingBranch }

                            if ($ciPostPushWatch) {
                                Write-Host ("[HUMAN GATE] Watching origin CI post-push on " + $primaryBranch + " for " + $mergedSha + "...") -ForegroundColor Cyan
                                $postPushOutput = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $watchScript @watchCmdArgs 2>&1)
                                $postPushExitCode = $LASTEXITCODE
                                foreach ($line in $postPushOutput) {
                                    Write-Host $line
                                }
                                if ($postPushExitCode -eq 1) {
                                    Write-Host ("[CI WATCH] STATUS=POST_PUSH_RED: Commit " + $mergedSha + " passed staging CI but failed branch CI on " + $primaryBranch + "!") -ForegroundColor Red
                                    Write-EventLog -Event "post_push_ci_red" -TaskId $TaskId -Specialist "factory" -Outcome "warning" -Notes ("Commit " + $mergedSha + " failed post-push branch CI.")
                                } elseif ($postPushExitCode -eq 5) {
                                    Write-Host ("[CI WATCH] STATUS=POST_PUSH_MISSING_REQUIRED_JOBS: Commit " + $mergedSha + " branch CI run is missing required jobs (" + $ciRequiredChecks + ")!") -ForegroundColor Red
                                    Write-EventLog -Event "post_push_ci_missing_required_jobs" -TaskId $TaskId -Specialist "factory" -Outcome "warning" -Notes ("Post-push branch CI for " + $mergedSha + " missing required jobs: " + $ciRequiredChecks)
                                }
                            }
                        } elseif ($ciExitCode -eq 1) {
                            Invoke-GitChecked { git push origin --delete $stagingBranch }
                            Write-Host ("[HUMAN GATE] CI is RED for " + $mergedSha + "; task " + $TaskId + " is NOT done and master was NOT published (still local only). Fix forward and re-run the gate.") -ForegroundColor Red
                            exit 1
                        } elseif ($ciExitCode -eq 5) {
                            Invoke-GitChecked { git push origin --delete $stagingBranch }
                            Write-Host ("[HUMAN GATE] MISSING_REQUIRED_JOBS: Staging CI run for " + $mergedSha + " is missing required jobs (" + $ciRequiredChecks + "); refusing to publish master. Fix CI config/workflow and re-run the gate.") -ForegroundColor Red
                            Write-EventLog -Event "ci_missing_required_jobs" -TaskId $TaskId -Specialist "factory" -Outcome "blocked" -Notes ("Staging CI run for " + $mergedSha + " missing required jobs: " + $ciRequiredChecks)
                            exit 1
                        } else {
                            # Rationale: Only a CONFIRMED RED withholds the master push; inconclusive CI (timeout, CI_NOT_STARTED, NO_RUNS)
                            # still finalizes-with-warning so an infrastructure stall does not wedge the pipeline (F1/F2 stance).
                            Write-Quiet "[HUMAN GATE] Pushing merged changes to origin/$primaryBranch..."
                            Invoke-GitChecked { git push origin $primaryBranch }
                            if ($LASTEXITCODE -ne 0) {
                                Write-Host "[ERROR] git push failed. Please check network/credentials or run manually." -ForegroundColor Red
                                exit 1
                            }

                            if ($ciExitCode -eq 2) {
                                Write-Host ("[HUMAN GATE] CI did not finish before timeout for " + $mergedSha + "; finalizing while CI continues.") -ForegroundColor Yellow
                                $originUrl = (git remote get-url origin 2>$null)
                                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($originUrl)) {
                                    $originText = ([string]$originUrl).Trim()
                                    $actionsUrl = ""
                                    if ($originText -match '^git@github\.com:([^/]+/[^/]+?)(\.git)?$') {
                                        $actionsUrl = "https://github.com/" + $Matches[1] + "/actions"
                                    } elseif ($originText -match '^https://github\.com/([^/]+/[^/]+?)(\.git)?/?$') {
                                        $actionsUrl = "https://github.com/" + $Matches[1] + "/actions"
                                    } else {
                                        $actionsUrl = $originText
                                    }
                                    Write-Host ("[HUMAN GATE] CI run URL: " + $actionsUrl) -ForegroundColor Yellow
                                }
                            } elseif ($ciExitCode -eq 4) {
                                Write-Host ("[HUMAN GATE] CI never left GitHub's queue for " + $mergedSha + " (no runner assigned within the grace window). This is likely a runner-availability outage, NOT a slow build. Finalizing, but re-check CI - and consider re-running the workflow - before treating " + $TaskId + " as shipped.") -ForegroundColor Yellow
                                $originUrl = (git remote get-url origin 2>$null)
                                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($originUrl)) {
                                    $originText = ([string]$originUrl).Trim()
                                    $actionsUrl = ""
                                    if ($originText -match '^git@github\.com:([^/]+/[^/]+?)(\.git)?$') {
                                        $actionsUrl = "https://github.com/" + $Matches[1] + "/actions"
                                    } elseif ($originText -match '^https://github\.com/([^/]+/[^/]+?)(\.git)?/?$') {
                                        $actionsUrl = "https://github.com/" + $Matches[1] + "/actions"
                                    } else {
                                        $actionsUrl = $originText
                                    }
                                    Write-Host ("[HUMAN GATE] CI run URL: " + $actionsUrl) -ForegroundColor Yellow
                                }
                            } elseif ($ciExitCode -eq 3) {
                                Write-Host ("[HUMAN GATE] CI could not be confirmed for " + $mergedSha + ": no workflow runs registered within the grace window. Finalizing, but verify CI manually before treating " + $TaskId + " as shipped.") -ForegroundColor Yellow
                            }

                            Invoke-GitChecked { git push origin --delete $stagingBranch }
                        }
                    } else {
                        Write-Quiet "[HUMAN GATE] Pushing merged changes to origin/$primaryBranch..."
                        Invoke-GitChecked { git push origin $primaryBranch }
                        if ($LASTEXITCODE -ne 0) {
                            Write-Host "[ERROR] git push failed. Please check network/credentials or run manually." -ForegroundColor Red
                            exit 1
                        }
                    }
                } else {
                    Write-Quiet "[HUMAN GATE] No remote 'origin' configured. Skipping git push."
                }
            } else {
                Write-Host "[HUMAN GATE] Refusing to push; merge remains LOCAL only." -ForegroundColor Yellow
                if ($requireGreenCi) {
                    Write-Host "[HUMAN GATE] Verify adopter CI for the merge commit BEFORE pushing:" -ForegroundColor Yellow
                    Write-Host ("  pwsh -File .crucible/powershell/watch-adopter-ci.ps1 -Commit " + $mergedSha) -ForegroundColor Cyan
                }
                Write-Host "Run the following command to publish:" -ForegroundColor Yellow
                Write-Host "  git push origin $primaryBranch" -ForegroundColor Cyan
            }

            $workspacesDir = Get-ConfiguredPath -Key "workspaces" -ProjectRoot $resolvedProjectRoot
            $wtPath = Resolve-ImplementationWorktreePath -TaskId $TaskId -WorkspacesDir $workspacesDir
            if (Test-Path $wtPath) {
                Write-Quiet "[HUMAN GATE] Removing implementation worktree at $wtPath..."
                Invoke-GitChecked { git worktree prune }
                if (Test-Path $wtPath) {
                    try {
                        $null = git worktree remove --force $wtPath 2>$null
                        if (Test-Path $wtPath) {
                            Write-Host "[HUMAN GATE] Worktree at $wtPath is locked (likely a gopls/test handle); left in place. Run 'git worktree prune' later to reclaim it." -ForegroundColor Yellow
                        }
                    } catch {
                        if (Test-Path $wtPath) {
                            Write-Host "[HUMAN GATE] Worktree at $wtPath is locked (likely a gopls/test handle); left in place. Run 'git worktree prune' later to reclaim it." -ForegroundColor Yellow
                        }
                    }
                }
            }
            if ($hasTaskBranch) {
                Write-Quiet "[HUMAN GATE] Deleting task branch task/$TaskId..."
                Invoke-GitChecked { git branch -d "task/$TaskId" }
            }
        }

        $sessionDir = Join-Path $resolvedProjectRoot ".crucible/session"
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")

        # Move pipeline log to archived if it exists
        $pipelineLogPath = Join-Path $sessionDir "$TaskId/pipeline.log.jsonl"
        if (Test-Path -LiteralPath $pipelineLogPath) {
            $archivedDir = Join-Path $sessionDir "archived"
            if (-not (Test-Path $archivedDir)) {
                New-Item -ItemType Directory -Force -Path $archivedDir | Out-Null
            }
            $destPath = Join-Path $archivedDir "pipeline-$TaskId-$timestamp.log.jsonl"
            Move-Item -LiteralPath $pipelineLogPath -Destination $destPath -Force
            Write-Quiet "[HUMAN GATE] Archived pipeline log to $destPath"
        }

        $archivedHandoffs = @(Move-TaskHandoffsToArchive -TaskId $TaskId -SessionDir $sessionDir -Timestamp $timestamp)
        if ($archivedHandoffs.Count -gt 0) {
            Write-Quiet ("[HUMAN GATE] Archived " + $archivedHandoffs.Count + " handoff file(s) for " + $TaskId)
        }

        # Prune the finalized task from session_state.json so -Status does not render it
        # as a ghost "In Progress" entry. The deployment/grooming done-handoff path prunes
        # via the same call; the accept finalize path must too, otherwise a task archived
        # here (and later invisible to the backlog parser) falls through to "In Progress".
        try {
            $updateStateScript = Join-Path (Split-Path -Parent $PSScriptRoot) "update-session-state.ps1"
            & $updateStateScript -Specialist done -TaskId $TaskId -UpdateJson "{}" -Merge $false -ProjectRoot $resolvedProjectRoot | Out-Null
        } catch {
            Write-Quiet ("[HUMAN GATE] Could not prune session state for " + $TaskId + ": " + $_.Exception.Message)
        }
    } elseif ($Outcome -eq "rejected" -or $Outcome -eq "abandoned") {
        if ($SourcePhase -ne "grooming") {
            if ($Outcome -eq "rejected") {
                # Restore backlog state if it was archived
                Restore-BacklogTask -TaskId $TaskId -ProjectRoot $resolvedProjectRoot -ActiveStatus "In Progress"
            } elseif ($Outcome -eq "abandoned") {
                # Archive the abandoned task as Abandoned
                $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $resolvedProjectRoot
                $backlogPath = Join-Path $backlogDir "BACKLOG.md"
                if (Test-Path -LiteralPath $backlogPath) {
                    $activeSpecPath = Get-BacklogItemPathForTaskProjectRoot -Task $TaskId -ProjectRoot $resolvedProjectRoot
                    if (-not [string]::IsNullOrEmpty($activeSpecPath) -and (Test-Path -LiteralPath $activeSpecPath) -and ($activeSpecPath -match '(?i)[/\\]active[/\\]')) {
                        $archiveLibPath = Join-Path $PSScriptRoot "archive-task.ps1"
                        if (-not (Get-Command "Invoke-BacklogTaskArchive" -ErrorAction SilentlyContinue)) {
                            if (Test-Path -LiteralPath $archiveLibPath) { . $archiveLibPath }
                        }
                        if (Get-Command "Invoke-BacklogTaskArchive" -ErrorAction SilentlyContinue) {
                            try {
                                $archiveResult = Invoke-BacklogTaskArchive -BacklogPath $backlogPath -SpecPath $activeSpecPath -Status "Abandoned"
                                Write-Host ("[D57] SUCCESS: Auto-archived abandoned task as $($archiveResult.Type) (status Abandoned): $($archiveResult.ArchivedRelPath)") -ForegroundColor Green
                            } catch {
                                Write-Host ("[D57] WARNING: Failed to archive abandoned task: " + $_.Exception.Message) -ForegroundColor Yellow
                            }
                        }
                    } else {
                        # If it was already archived (legacy flow), set frontmatter and BACKLOG.md row to Abandoned
                        $typeDirs = @("features", "bugs", "chores")
                        foreach ($dir in $typeDirs) {
                            $archivedMatch = Get-ChildItem -Path (Join-Path $backlogDir ($dir + "/archived")) -Filter ($TaskId + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
                            if ($null -ne $archivedMatch) {
                                $archiveLibPath = Join-Path $PSScriptRoot "archive-task.ps1"
                                if (-not (Get-Command "Set-BacklogSpecFrontmatterStatus" -ErrorAction SilentlyContinue)) {
                                    if (Test-Path -LiteralPath $archiveLibPath) { . $archiveLibPath }
                                }
                                if (Get-Command "Set-BacklogSpecFrontmatterStatus" -ErrorAction SilentlyContinue) {
                                    Set-BacklogSpecFrontmatterStatus -Path $archivedMatch.FullName -Status "Abandoned"
                                }
                                $relativeArchived = "$dir/archived/$($archivedMatch.Name)"
                                $lines = [System.Collections.Generic.List[string]]::new()
                                foreach ($line in [System.IO.File]::ReadAllLines($backlogPath, [System.Text.Encoding]::UTF8)) {
                                    [void]$lines.Add($line)
                                }
                                $archivedLink = $relativeArchived.Replace("\", "/")
                                $rowIndex = -1
                                for ($i = 0; $i -lt $lines.Count; $i++) {
                                    if ($lines[$i].Contains("]($archivedLink)")) {
                                        $rowIndex = $i
                                        break
                                    }
                                }
                                if ($rowIndex -ge 0) {
                                    $lineArray = [string[]]$lines.ToArray()
                                    if (-not (Get-Command "Get-MarkdownTableStatusColumn" -ErrorAction SilentlyContinue)) {
                                        if (Test-Path -LiteralPath $archiveLibPath) { . $archiveLibPath }
                                    }
                                    if (Get-Command "Get-MarkdownTableStatusColumn" -ErrorAction SilentlyContinue) {
                                        $statusColumn = Get-MarkdownTableStatusColumn -Lines $lineArray -RowIndex $rowIndex
                                        if ($statusColumn -ge 0) {
                                            $cells = [System.Collections.Generic.List[string]]::new()
                                            foreach ($cell in $lines[$rowIndex].Trim().Trim("|").Split("|")) {
                                                [void]$cells.Add($cell.Trim())
                                            }
                                            if ($statusColumn -lt $cells.Count) {
                                                $cells[$statusColumn] = "Abandoned"
                                                $lines[$rowIndex] = "| " + (($cells.ToArray()) -join " | ") + " |"
                                                Invoke-WithBacklogLock -BacklogPath $backlogPath -ScriptBlock {
                                                    [System.IO.File]::WriteAllText($backlogPath, (($lines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
                                                }
                                            }
                                        }
                                    }
                                }
                                break
                            }
                        }
                    }
                }
            }

            $currentHead = (Invoke-GitChecked { git rev-parse HEAD }).Trim()
            $parents = (Invoke-GitChecked { git log --pretty=%P -n 1 $currentHead }).Trim()
            $parentList = @(if ([string]::IsNullOrWhiteSpace($parents)) { } else { $parents -split '\s+' })

            # Only unwind a local merge if the gate actually advanced $primaryBranch
            # beyond origin. In the review-before-merge flow the task branch is not
            # merged until accept, so on reject/abandon there is typically nothing to
            # unwind -- a blind reset would discard unrelated, already-pushed history
            # (e.g. the previously-accepted task), resetting $primaryBranch to a stale
            # reflog entry.
            $primaryAhead = $false
            git rev-parse --verify --quiet "origin/$primaryBranch" > $null 2>&1
            if ($LASTEXITCODE -eq 0) {
                $aheadCount = (Invoke-GitChecked { git rev-list --count "origin/$primaryBranch..$primaryBranch" }).Trim()
                if ($aheadCount -match '^\d+$' -and [int]$aheadCount -gt 0) { $primaryAhead = $true }
            } elseif ($parentList.Count -ge 2) {
                # No origin tracking ref to compare against: only unwind a genuine merge commit.
                $primaryAhead = $true
            }

            if ($primaryAhead) {
                $resetTarget = "origin/$primaryBranch"

                # Derive pre-merge tip using reflog as primary defense in depth (for both merge and FF)
                $reflogTip = (Invoke-GitChecked { git rev-parse --verify --quiet "${primaryBranch}@{1}" 2>$null }).Trim()
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($reflogTip)) {
                    # Verify that $reflogTip is indeed an ancestor of $currentHead
                    git merge-base --is-ancestor $reflogTip $currentHead 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        $resetTarget = $reflogTip
                    }
                }

                # If reflog check failed or wasn't ancestor, fall back to parent checking for merge commits
                if ($resetTarget -eq "origin/$primaryBranch" -and $parentList.Count -ge 2) {
                    $resetTarget = $parentList[0]
                }

                if ($resetTarget -eq "origin/$primaryBranch") {
                    Write-Quiet "[HUMAN GATE] Unwinding local merge. Resetting $primaryBranch to origin/$primaryBranch..."
                } else {
                    Write-Quiet "[HUMAN GATE] Unwinding local merge. Resetting $primaryBranch to pre-merge tip ($resetTarget)..."
                }

                Invoke-GitChecked { git checkout $primaryBranch }
                Invoke-GitChecked { git reset --hard $resetTarget }
            } else {
                Write-Quiet "[HUMAN GATE] No local merge to unwind ($primaryBranch is not ahead of origin/$primaryBranch); leaving $primaryBranch untouched."
                Invoke-GitChecked { git checkout $primaryBranch }
            }

            if ($Outcome -eq "rejected") {
                Invoke-GitChecked { git show-ref --quiet "refs/heads/task/$TaskId" }
                if ($LASTEXITCODE -ne 0) {
                    if ($parentList.Count -ge 2) {
                        Invoke-GitChecked { git branch "task/$TaskId" $parentList[1] }
                    } else {
                        Invoke-GitChecked { git branch "task/$TaskId" $currentHead }
                    }
                    Write-Quiet "[HUMAN GATE] Restored task branch task/$TaskId"
                }

                # Auto-recreate the implementation worktree from the restored branch
                $workspacesDir = Get-ConfiguredPath -Key "workspaces" -ProjectRoot $resolvedProjectRoot
                $wtPath = Resolve-ImplementationWorktreePath -TaskId $TaskId -WorkspacesDir $workspacesDir
                
                # Prune stale worktrees first
                Invoke-GitChecked { git worktree prune }

                if (-not (Test-Path $wtPath)) {
                    Invoke-GitChecked { git worktree add $wtPath "task/$TaskId" }
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "Warning: Failed to recreate implementation worktree at $wtPath" -ForegroundColor Yellow
                    } else {
                        $prev = $ErrorActionPreference
                        $ErrorActionPreference = 'Continue'
                        $hasWorktreeConfig = (git config extensions.worktreeConfig 2>$null) -eq "true"
                        $ErrorActionPreference = $prev
                        if (-not $hasWorktreeConfig) {
                            Invoke-GitChecked { git config extensions.worktreeConfig true }
                        }
                        $adopterHook = Join-Path $PSScriptRoot "..\..\scripts\hooks\architect"
                        $repoHook = Join-Path $resolvedProjectRoot "scripts/hooks/architect"
                        $hookDir = if (Test-Path $adopterHook) { $adopterHook } else { $repoHook }
                        if (-not (Test-Path $hookDir)) {
                            New-Item -ItemType Directory -Force -Path $hookDir | Out-Null
                        }
                        Invoke-GitChecked { git -C $wtPath config --worktree core.hooksPath $hookDir }
                        Write-Quiet "[HUMAN GATE] Recreated implementation worktree at $wtPath"
                    }
                }

                # Check if the task is present in the backlog before running new-handoff.ps1
                $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $resolvedProjectRoot
                $backlogPath = Join-Path $backlogDir "BACKLOG.md"
                $hasTaskInBacklog = $false
                if (Test-Path -LiteralPath $backlogPath) {
                    try {
                        $backlogContent = Get-Content -LiteralPath $backlogPath -Raw -Encoding UTF8
                        if ($backlogContent -match [regex]::Escape($TaskId)) {
                            $hasTaskInBacklog = $true
                        }
                    } catch {}
                }

                if ($hasTaskInBacklog) {
                    # Calculate next strike count
                    $nextStrike = 1
                    $handoffVar = Get-Variable -Name "handoff" -ErrorAction SilentlyContinue
                    $activeHandoff = $null
                    if ($null -ne $handoffVar -and $null -ne $handoffVar.Value) {
                        $activeHandoff = $handoffVar.Value
                        if ($activeHandoff.PSObject.Properties["review_strike_count"]) {
                            $nextStrike = [int]$activeHandoff.review_strike_count + 1
                        }
                    }

                    # Write a sanctioned re-entry handoff into implementation
                    $generatorScript = Join-Path (Split-Path -Parent $PSScriptRoot) "new-handoff.ps1"
                    if (Test-Path $generatorScript) {
                        $reasonMsg = if ([string]::IsNullOrWhiteSpace($GateReason)) { "Deployment rejected. Rework requested." } else { "Deployment rejected: $GateReason" }
                        Write-Quiet "[HUMAN GATE] Generating sanctioned re-entry handoff targeting implementation..."
                        
                        # Extract values from current handoff
                        $sessionCycleId = ""
                        $artifacts = @()
                        if ($null -ne $activeHandoff) {
                            if ($activeHandoff.PSObject.Properties["session_cycle_id"]) {
                                $sessionCycleId = $activeHandoff.session_cycle_id
                            } elseif ($activeHandoff.PSObject.Properties["cycle_id"]) {
                                $sessionCycleId = $activeHandoff.cycle_id
                            }
                            if ($activeHandoff.PSObject.Properties["artifacts"]) {
                                $artifacts = $activeHandoff.artifacts
                            }
                        }

                        $handoffParams = @{
                            TaskId = $TaskId
                            Source = "deployment"
                            Target = "implementation"
                            Reason = $reasonMsg
                            ReviewStrikeCount = $nextStrike
                            ProjectRoot = $resolvedProjectRoot
                        }
                        if (-not [string]::IsNullOrEmpty($sessionCycleId)) {
                            $handoffParams["SessionCycleId"] = $sessionCycleId
                        }
                        if ($artifacts.Count -gt 0) {
                            $handoffParams["Artifacts"] = @($artifacts)
                        }
                        
                        & $generatorScript @handoffParams
                    }
                } else {
                    Write-Quiet "[HUMAN GATE] Task $TaskId not found in backlog; skipping handoff generation."
                }
            }
        }
    }
}

function Get-GateReviewRange {
    # Computes the base..branch commit range the Human Gate shows for visual/text
    # review. The branch endpoint is the task branch TIP (the actual reviewed work),
    # not the handoff's commit_hash -- that is the stale bootstrap-era HEAD recorded
    # when the task was first created, before any implementation commit. The base
    # endpoint is the MERGE-BASE of the primary branch and the task branch, not the
    # primary-branch tip: when the primary branch has advanced past where the task
    # was cut, its tip skews the diff (wrong direction / unrelated commits) and omits
    # the task's own changes. Falls back to the legacy (primary-tip..commit_hash)
    # behavior only when no task branch exists (e.g. factory tasks whose changes are
    # not carried on a task branch).
    param(
        [Parameter(Mandatory = $true)][string]$PrimaryBranch,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$CommitHash = ""
    )

    $branchRef = "task/$TaskId"
    $baseSha = ""
    $branchSha = ""

    git show-ref --quiet "refs/heads/$branchRef"
    if ($LASTEXITCODE -eq 0) {
        $branchSha = (git rev-parse $branchRef 2>$null).Trim()
        $mergeBase = (git merge-base $PrimaryBranch $branchRef 2>$null).Trim()
        if (-not [string]::IsNullOrEmpty($mergeBase)) { $baseSha = $mergeBase }
    }

    if ([string]::IsNullOrEmpty($branchSha)) { $branchSha = $CommitHash }
    if ([string]::IsNullOrEmpty($baseSha)) {
        $baseSha = (git rev-parse $PrimaryBranch 2>$null).Trim()
    }

    return @{ BaseSha = $baseSha; BranchSha = $branchSha }
}

function Get-ResearchMisrouteAdvisory {
    # Neutral defense-in-depth advisory. A grooming -> done closure of a task that
    # looks like research (type: Research, or a populated ## Open Questions section)
    # with NO research handoff or artifact anywhere in its lineage is a strong
    # premature-closure signal (see the R-018 dogfood misroute). Returns a warning
    # string when that pattern holds, else $null. Never blocks; legitimately obsolete
    # research tasks can still be closed.
    param(
        [Parameter(Mandatory = $true)]$Handoff,
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [string]$ProjectRoot = ""
    )
    try {
        $specPath = Get-BacklogItemPathForTaskProjectRoot -Task $Handoff.task_id -ProjectRoot $ProjectRoot
        if ([string]::IsNullOrEmpty($specPath) -or -not (Test-Path -LiteralPath $specPath)) { return $null }
        $specText = Get-Content -LiteralPath $specPath -Raw -Encoding UTF8

        $isResearchType = ($specText -match '(?im)^\s*type:\s*["'']?research["'']?\s*$')

        $hasOpenQuestions = $false
        if ($specText -match '(?ims)^#{1,6}\s*Open Questions\s*\r?\n(.*?)(?:^#{1,6}\s|\Z)') {
            foreach ($line in ($Matches[1] -split "\r?\n")) {
                $t = $line.Trim()
                if ($t -ne "" -and $t -notmatch '^#{1,6}\s' -and $t -notmatch '^(?:-\s*)?_?None\b') {
                    $hasOpenQuestions = $true
                    break
                }
            }
        }

        if (-not $isResearchType -and -not $hasOpenQuestions) { return $null }

        $hasResearchLineage = $false
        $handoffDir = $Context.HandoffDir
        if (-not [string]::IsNullOrEmpty($handoffDir) -and (Test-Path $handoffDir)) {
            $handoffFiles = @(Get-ChildItem -Path $handoffDir -Filter ($Handoff.task_id + "-*.json") -ErrorAction SilentlyContinue)
            foreach ($file in $handoffFiles) {
                try {
                    $hObj = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($hObj.source_phase -eq "research" -or $hObj.target_phase -eq "research") {
                        $hasResearchLineage = $true
                        break
                    }
                } catch {}
            }
        }
        if (-not $hasResearchLineage) {
            $crucibleRoot = if ($Context.ContainsKey("CrucibleRoot")) { $Context.CrucibleRoot } else { "" }
            if (-not [string]::IsNullOrEmpty($crucibleRoot)) {
                $resolvedCrucibleRoot = if ([System.IO.Path]::IsPathRooted($crucibleRoot)) { $crucibleRoot } else { Join-Path $ProjectRoot $crucibleRoot }
                $researchDir = Join-Path $resolvedCrucibleRoot "research"
                if (Test-Path -LiteralPath $researchDir) {
                    $artifact = Get-ChildItem -LiteralPath $researchDir -Filter ($Handoff.task_id + "*.md") -File -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($artifact) { $hasResearchLineage = $true }
                }
            }
        }

        if ($hasResearchLineage) { return $null }

        $signal = if ($isResearchType) { "type: Research" } else { "a populated ## Open Questions section" }
        return "Task $($Handoff.task_id) has $signal but is closing grooming -> done with no research handoff or artifact in its lineage. If research was expected, this may be a premature closure - confirm before accepting."
    } catch {
        return $null
    }
}

function Invoke-HumanGate {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    if ($null -eq $Context) {
        throw "FactoryContext is null."
    }
    $requiredKeys = @("Handoff", "IsBootstrap", "SessionDir", "GateOutcome", "GateReason", "GateRedirectTarget", "CrucibleRoot", "Quiet")
    foreach ($key in $requiredKeys) {
        if (-not $Context.ContainsKey($key)) {
            throw "Required key '$key' is missing from FactoryContext."
        }
    }

    $handoff = $Context.Handoff
    $isBootstrap = [bool]$Context.IsBootstrap
    $sessionDir = $Context.SessionDir
    $GateOutcome = $Context.GateOutcome
    $GateReason = $Context.GateReason
    $GateRedirectTarget = $Context.GateRedirectTarget
    $crucibleRoot = $Context.CrucibleRoot
    $Quiet = [bool]$Context.Quiet
    $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }

    $taskBranchExists = $false
    $isGit = $false
    $checkDir = $repoRoot
    while (-not [string]::IsNullOrEmpty($checkDir)) {
        if (Test-Path -LiteralPath (Join-Path $checkDir ".git")) {
            $isGit = $true
            break
        }
        $parent = Split-Path -Parent $checkDir
        if ($parent -eq $checkDir -or [string]::IsNullOrEmpty($parent)) { break }
        $checkDir = $parent
    }
    if ($isGit) {
        git -C $repoRoot show-ref --verify --quiet "refs/heads/task/$($handoff.task_id)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $taskBranchExists = $true
        }
    }

    # Resolve a concrete review pointer for a No-Code Closure. Prefer a
    # findings/.md artifact named in the handoff; else the newest research/.md file
    # matching the task id; else fall back to the archived spec.
    $noCodeClosureReviewDoc = ""
    $reviewDocCandidates = @()
    if ($handoff.PSObject.Properties["artifacts"] -and $handoff.artifacts) {
        foreach ($artifact in $handoff.artifacts) {
            if ($artifact -and ([string]$artifact -match '\.md$')) { $reviewDocCandidates += [string]$artifact }
        }
    }
    $noCodeClosureReviewDoc = $reviewDocCandidates | Where-Object { $_ -match '(?i)findings' } | Select-Object -First 1
    if ([string]::IsNullOrEmpty($noCodeClosureReviewDoc)) {
        $noCodeClosureReviewDoc = $reviewDocCandidates | Select-Object -First 1
    }
    if ([string]::IsNullOrEmpty($noCodeClosureReviewDoc) -and -not [string]::IsNullOrEmpty($crucibleRoot)) {
        $noCodeClosureResearchDir = Join-Path $repoRoot (Join-Path $crucibleRoot "research")
        if (Test-Path -LiteralPath $noCodeClosureResearchDir) {
            $noCodeClosureFound = Get-ChildItem -LiteralPath $noCodeClosureResearchDir -Filter "$($handoff.task_id)*.md" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($noCodeClosureFound) {
                $noCodeClosureReviewDoc = ((Join-Path $crucibleRoot "research") + "/" + $noCodeClosureFound.Name) -replace '\\', '/'
            }
        }
    }
    $noCodeClosureReviewHint = if (-not [string]::IsNullOrEmpty($noCodeClosureReviewDoc)) {
        "No-Code Closure - no code diff; review $noCodeClosureReviewDoc + filed stubs"
    } else {
        "No-Code Closure - no code diff; review the archived spec + filed stubs"
    }

    # --- 3a. Human Gate ---
    $isGroomingClosure = ($handoff.source_phase -eq "grooming" -and $handoff.target_phase -eq "done")
    if ($isGroomingClosure) {
        $researchMisrouteAdvisory = Get-ResearchMisrouteAdvisory -Handoff $handoff -Context $Context -ProjectRoot $repoRoot
        if (-not [string]::IsNullOrEmpty($researchMisrouteAdvisory)) {
            Write-Host ("[ADVISORY] " + $researchMisrouteAdvisory) -ForegroundColor Yellow
        }
    }
    $shouldRunHumanGate = $false
    if ($handoff.source_phase -eq "deployment") {
        if (-not [string]::IsNullOrEmpty($GateOutcome)) {
            $shouldRunHumanGate = -not $isBootstrap
        } else {
            $shouldRunHumanGate = -not $isBootstrap -and $handoff.target_phase -eq "done"
        }
    } elseif ($isGroomingClosure) {
        # Check if research gate approved it
        $researchGateApproved = $false
        $handoffDir = $Context.HandoffDir
        if (-not [string]::IsNullOrEmpty($handoffDir) -and (Test-Path $handoffDir)) {
            $handoffFiles = @(Get-ChildItem -Path $handoffDir -Filter ($handoff.task_id + "-*.json") -ErrorAction SilentlyContinue)
            foreach ($file in $handoffFiles) {
                try {
                    $hObj = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($hObj.source_phase -eq "research" -and $hObj.human_decisions -and $hObj.human_decisions.approved -and $hObj.human_decisions.approved.Count -gt 0) {
                        $researchGateApproved = $true
                        break
                    }
                } catch {}
            }
        }
        $shouldRunHumanGate = -not $researchGateApproved
    }

    if ($shouldRunHumanGate) {
        $GATE_DIR = Join-Path $sessionDir "global/gate_decisions"
        if (-not (Test-Path $GATE_DIR)) {
            New-Item -ItemType Directory -Force -Path $GATE_DIR | Out-Null
        }

        $GATE_PENDING_FILE = Join-Path $sessionDir ($handoff.task_id + "/gate_pending.txt")
        $pendingDir = Split-Path -Parent $GATE_PENDING_FILE
        if (-not (Test-Path $pendingDir)) {
            New-Item -ItemType Directory -Force -Path $pendingDir | Out-Null
        }
        $validOutcomes = @("accepted", "rejected", "redirected", "abandoned")
        $lowSignalGateReasons = @(
            "n/a", "na", "none", "ok", "looks good", "looks good.",
            "approved", "accept", "accepted", "done", "ship it", "auto"
        )

        # Cycle that this gate is firing in. An advancing decision is only honored
        # as "already passed" on a re-run within the SAME cycle, so a stale accept
        # from a prior cycle cannot silently bypass a fresh human gate encounter.
        $currentGateCycle = if ($handoff.PSObject.Properties["session_cycle_id"] -and -not [string]::IsNullOrEmpty($handoff.session_cycle_id)) {
            [string]$handoff.session_cycle_id
        } elseif (-not [string]::IsNullOrEmpty($env:FACTORY_CYCLE_ID)) {
            [string]$env:FACTORY_CYCLE_ID
        } else {
            ""
        }

        # --- Handle automated gate outcome from CLI flag ---
        if (-not [string]::IsNullOrEmpty($GateOutcome)) {
            # Support numeric mapping (1-4)
            if ($GateOutcome -match '^[1-4]$') {
                $map = @{ "1"="accepted"; "2"="rejected"; "3"="redirected"; "4"="abandoned" }
                $GateOutcome = $map[$GateOutcome]
            }

            if ($validOutcomes -notcontains $GateOutcome) {
                Write-Host ("Error: Invalid -GateOutcome: " + $GateOutcome) -ForegroundColor Red
                exit 1
            }

            $trimmedGateReason = if ([string]::IsNullOrWhiteSpace($GateReason)) { "" } else { (ConvertTo-AsciiSafeText -Text $GateReason).Trim() }
            $normalizedGateReason = $trimmedGateReason.ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($trimmedGateReason) -or ($lowSignalGateReasons -contains $normalizedGateReason)) {
                Write-Host "Error: -GateReason is required and must be specific (not placeholder text like 'ok' or 'n/a')." -ForegroundColor Red
                exit 1
            }
            
            $primaryBranch = Get-PrimaryBranchName
            $gateHandoffCommit = if ($handoff.PSObject.Properties["commit_hash"]) { $handoff.commit_hash } else { "" }
            $gateRange = Get-GateReviewRange -PrimaryBranch $primaryBranch -TaskId $handoff.task_id -CommitHash $gateHandoffCommit
            $baseSha = $gateRange.BaseSha
            $branchSha = $gateRange.BranchSha

            $decision = [ordered]@{
                task_id = $handoff.task_id
                backlog_item = $handoff.task_id
                gate_fired_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                outcome = $GateOutcome
                reason = $trimmedGateReason
                rework_requested = ($GateOutcome -eq "rejected")
                redirect_target = $GateRedirectTarget
                session_cycle_id = $currentGateCycle
                base_sha = $baseSha
                branch_sha = $branchSha
            }
            
            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
            $archivePath = Join-Path $GATE_DIR ($handoff.task_id + "-" + $timestamp + ".json")
            $decision | ConvertTo-Json | Set-Content -Path $archivePath -Encoding UTF8
            Write-Host ("`n[HUMAN GATE] Decision recorded via CLI flag: " + $GateOutcome) -ForegroundColor Green
            Write-Host ("Reason: " + $trimmedGateReason) -ForegroundColor Gray

            # Execute push or reset based on automated CLI decision. An accepted merge
            # that conflicts routes to rework and removes this premature decision itself
            # (see Invoke-HumanGateMerge) so a non-completed accept cannot block a retry.
            Invoke-HumanGateAction -TaskId $handoff.task_id -Outcome $GateOutcome -ProjectRoot $repoRoot -SourcePhase $handoff.source_phase -GateReason $trimmedGateReason

            if ($GateOutcome -eq "abandoned") {
                Write-Host "[ABANDONED] Pipeline stopped per human request." -ForegroundColor Gray
                exit 0
            }
            
            # Cleanup pending files
            if (Test-Path $GATE_PENDING_FILE) { Remove-Item $GATE_PENDING_FILE -Force }
            $legacyPending = Join-Path $GATE_DIR ("gate_decision_" + $handoff.task_id + "_pending.json")
            if (Test-Path $legacyPending) { Remove-Item $legacyPending -Force }
            Write-Host "[HUMAN GATE] Session complete. Start the next task explicitly when ready." -ForegroundColor Gray
            exit 0
        } else {
            $gateAlreadyPassed = $false
            
            # Check for already completed decisions for this task
            $decisions = @(Get-ChildItem -Path $GATE_DIR -Filter ($handoff.task_id + "-*.json") |
                Where-Object { $_.Name -notmatch "gate_decision_.*_pending.json" } |
                Sort-Object LastWriteTime -Descending)

            if ($decisions.Count -gt 0) {
                try {
                    $latestDecision = Get-Content $decisions[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    # Only outcomes that advance the pipeline bypass the gate.
                    # "rejected" and "abandoned" require a fresh human decision on the reworked item.
                    $advancingOutcomes = @("accepted", "redirected")
                    if ($advancingOutcomes -contains $latestDecision.outcome) {
                        # Scope the bypass to the current cycle: an advancing decision
                        # only counts as "already passed" if it was recorded in the same
                        # cycle as this handoff. A stale accept from a prior cycle (e.g. a
                        # re-opened task or a rework re-entry) must NOT auto-advance; the
                        # human is re-prompted. Unstamped (legacy) decisions fail safe the
                        # same way. Empty current cycle also fails safe (re-prompt).
                        $decisionCycle = if ($latestDecision.PSObject.Properties["session_cycle_id"]) { [string]$latestDecision.session_cycle_id } else { "" }
                        if (-not [string]::IsNullOrEmpty($currentGateCycle) -and $decisionCycle -eq $currentGateCycle) {
                            $gateAlreadyPassed = $true
                        }
                    }
                } catch {
                    Write-Quiet ("[GATE] Warning: Could not parse gate decision file " + $decisions[0].Name) -ForegroundColor Yellow
                }
            }

            if (-not $gateAlreadyPassed) {
                $gateTemplatePath = Join-Path $GATE_DIR ("gate_decision_" + $handoff.task_id + "_pending.json")
                
                # Cross-validation: Archive legacy pending gate files
                $otherPending = @()
                    
                $legacyTemplate = Join-Path $GATE_DIR "gate_decision_template.json"
                if (Test-Path $legacyTemplate) { $otherPending += Get-Item $legacyTemplate }
                    
                foreach ($stale in $otherPending) {
                    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
                    $staleArchive = Join-Path $GATE_DIR ($stale.BaseName + "-stale-" + $timestamp + ".json")
                    Write-Quiet ("[GATE] Warning: Found legacy template file. Archiving to: $($staleArchive)") -ForegroundColor Yellow
                    Move-Item -Path $stale.FullName -Destination $staleArchive -Force
                }
                
                if (Test-Path $gateTemplatePath) {
                    try {
                        $gateData = Get-Content $gateTemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                        if ([string]::IsNullOrWhiteSpace($gateData.outcome) -or $gateData.outcome -eq "accepted | rejected | redirected | abandoned") {
                            Write-Host "`n[HUMAN GATE] Action Required: Please complete the gate decision." -ForegroundColor Yellow
                            Write-Host ("File: " + $gateTemplatePath) -ForegroundColor White
                            
                            $primaryBranch = Get-PrimaryBranchName
                            $autoPushVal = Get-ConfiguredReview -Key "auto_push" -ProjectRoot $repoRoot
                            $autoPush = $false
                            if ($autoPushVal -eq "true") {
                                $autoPush = $true
                            }
                            $acceptDesc = if ($autoPush) {
                                "work looks good; merges to $primaryBranch and pushes to origin; pause after this item"
                            } else {
                                "work looks good; merges to $primaryBranch (local only); pause after this item"
                            }

                            $baseSha = ""
                            $branchSha = ""
                            if ($gateData.PSObject.Properties["base_sha"]) { $baseSha = $gateData.base_sha }
                            if ($gateData.PSObject.Properties["branch_sha"]) { $branchSha = $gateData.branch_sha }
                            if ([string]::IsNullOrEmpty($baseSha) -or [string]::IsNullOrEmpty($branchSha)) {
                                $primaryBranch = Get-PrimaryBranchName
                                $gateHandoffCommit = if ($handoff.PSObject.Properties["commit_hash"]) { $handoff.commit_hash } else { "" }
                                $gateRange = Get-GateReviewRange -PrimaryBranch $primaryBranch -TaskId $handoff.task_id -CommitHash $gateHandoffCommit
                                $baseSha = $gateRange.BaseSha
                                $branchSha = $gateRange.BranchSha
                            }

                            $workspacesDir = if ($Context.ContainsKey("WorkspacesDir")) { $Context.WorkspacesDir } else { Get-ConfiguredPath -Key "workspaces" -ProjectRoot $repoRoot }
                            $wtPath = Join-Path $workspacesDir ("implementation-" + $handoff.task_id)
                            $wtPathDisplay = $wtPath -replace '\\', '/'

                            $diffTool = Get-ConfiguredReview -Key "diff_tool" -ProjectRoot $repoRoot
                            $editor = Get-ConfiguredReview -Key "editor" -ProjectRoot $repoRoot

                            $diffToolCommand = ""
                            $editorOpenCommand = ""

                            if (![string]::IsNullOrEmpty($diffTool)) {
                                $resolvedDiffTool = Get-ConfiguredEditorCommand -EditorOrToolName $diffTool
                                $taskSessionDir = Join-Path $sessionDir $handoff.task_id
                                if (-not (Test-Path $taskSessionDir)) {
                                    New-Item -ItemType Directory -Force -Path $taskSessionDir | Out-Null
                                }
                                $helperScriptPath = Join-Path $taskSessionDir "review-diff.ps1"
                                $resolvedDiffToolEscaped = $resolvedDiffTool -replace '"', '`"'
                                $scriptContent = @"
`$left = `$args[0]
`$right = `$args[1]
`$tmp = Join-Path `$env:TEMP "crucible-review/$($handoff.task_id)"
if (-not (Test-Path `$tmp)) { New-Item -ItemType Directory -Path `$tmp -Force | Out-Null }
`$leftCopy = Join-Path `$tmp ("left_" + (Split-Path -Leaf `$left))
`$rightCopy = Join-Path `$tmp ("right_" + (Split-Path -Leaf `$right))
Copy-Item `$left `$leftCopy -Force
Copy-Item `$right `$rightCopy -Force
& "$resolvedDiffToolEscaped" --diff `$leftCopy `$rightCopy
"@
                                try {
                                    $scriptContent | Set-Content -LiteralPath $helperScriptPath -Encoding UTF8
                                } catch {}

                                $helperScriptPathDisplay = $helperScriptPath -replace '\\', '/'
                                $pwshCmd = Get-PwshCommand
                                $diffToolCommand = "git -C `"$repoRoot`" difftool -y --extcmd=`"$pwshCmd -NoProfile -ExecutionPolicy Bypass -File \`"$helperScriptPathDisplay\`"`" $baseSha..$branchSha"
                            }

                            $editorToUse = if (![string]::IsNullOrEmpty($editor)) { $editor } else { $diffTool }
                            if (![string]::IsNullOrEmpty($editorToUse)) {
                                $resolvedEditor = Get-ConfiguredEditorCommand -EditorOrToolName $editorToUse
                                $editorOpenCommand = "& `"$resolvedEditor`" `"$wtPathDisplay`""
                            }

                            Write-Host "`n[HUMAN GATE] Visual review options:" -ForegroundColor Yellow
                            if ($taskBranchExists) {
                                if (-not [string]::IsNullOrEmpty($diffToolCommand)) {
                                    Write-Host "  - Launch visual diff tool (per-file):" -ForegroundColor Yellow
                                    Write-Host "    $diffToolCommand" -ForegroundColor Cyan
                                }
                                Write-Host "  - Command-line text diff:" -ForegroundColor Yellow
                                Write-Host "    git -C `"$repoRoot`" diff $baseSha..$branchSha" -ForegroundColor Cyan
                                Write-Host "  - Open the worktree folder in your editor:" -ForegroundColor Yellow
                                if (-not [string]::IsNullOrEmpty($editorOpenCommand)) {
                                    Write-Host "    $editorOpenCommand" -ForegroundColor Cyan
                                } else {
                                    Write-Host "    $wtPathDisplay" -ForegroundColor Cyan
                                }
                            } else {
                                Write-Host "  - $noCodeClosureReviewHint" -ForegroundColor Cyan
                            }

                            # Write machine-readable signal file
                            $menu = "[HUMAN GATE] Task $($handoff.task_id) complete. Present this menu to the human:`n`n" +
                                    "  1) Accept     - $acceptDesc`n" +
                                    "  2) Reject     - something is wrong, send back for rework`n" +
                                    "  3) Redirect   - accept this item and work on a specific item next (ask which one)`n" +
                                    "  4) Abandon    - do not accept; stop the pipeline entirely`n`n" +
                                    "Review options:`n"
                            if ($taskBranchExists) {
                                if (-not [string]::IsNullOrEmpty($diffToolCommand)) {
                                    $menu += "  - Launch visual diff tool (per-file):`n" +
                                             "    $diffToolCommand`n"
                                }
                                $menu += "  - Command-line text diff:`n" +
                                         "    git -C `"$repoRoot`" diff $baseSha..$branchSha`n" +
                                         "  - Open the worktree folder in your editor:`n"
                                if (-not [string]::IsNullOrEmpty($editorOpenCommand)) {
                                    $menu += "    $editorOpenCommand`n`n"
                                } else {
                                    $menu += "    $wtPathDisplay`n`n"
                                }
                            } else {
                                $menu += "  - $noCodeClosureReviewHint`n`n"
                            }
                            $menu += "Gate fired. Run factory.ps1 -Init -TaskId $($handoff.task_id) -GateOutcome <choice> [-GateReason `"Reason`"] to record the decision."
                            $menu | Set-Content -Path $GATE_PENDING_FILE -Encoding UTF8
                            
                            # Construct gate-specific command for next_step.txt
                            $pwshCmd = Get-PwshCommand
                            $gateCommand = "$pwshCmd -ExecutionPolicy Bypass -File `"$crucibleRoot/powershell/factory.ps1`" -Init -TaskId $($handoff.task_id) -GateOutcome accepted -GateReason `"<one concrete quality reason>`" -Quiet"
                            Write-NextStep -SessionDir $sessionDir -Command $gateCommand -TaskId $handoff.task_id -Specialist $handoff.source_phase
                            
                            exit 0
                        } else {
                            # Execute push or reset based on manual decision
                            Invoke-HumanGateAction -TaskId $handoff.task_id -Outcome $gateData.outcome -ProjectRoot $repoRoot -SourcePhase $handoff.source_phase -GateReason $gateData.reason

                            # Archive the decision, stamping the firing cycle so a
                            # same-cycle re-run is recognized as already-passed while a
                            # later cycle is not (see gateAlreadyPassed scoping above).
                            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
                            $archivePath = Join-Path $GATE_DIR ($handoff.task_id + "-" + $timestamp + ".json")
                            $gateData | Add-Member -NotePropertyName "session_cycle_id" -NotePropertyValue $currentGateCycle -Force
                            $gateData | ConvertTo-Json | Set-Content -Path $archivePath -Encoding UTF8
                            Remove-Item -Path $gateTemplatePath -Force
                            Write-Host ("`n[HUMAN GATE] Decision recorded: " + $gateData.outcome) -ForegroundColor Green
                            
                            # Cleanup machine-readable signal
                            if (Test-Path $GATE_PENDING_FILE) { Remove-Item $GATE_PENDING_FILE -Force }

                            if ($gateData.outcome -eq "rejected" -or $gateData.outcome -eq "abandoned") {
                                exit 0
                            }
                        }
                    } catch {
                        Write-Host "Error parsing gate decision template." -ForegroundColor Red
                        exit 1
                    }
                } else {
                    # Create template and exit
                    $primaryBranch = Get-PrimaryBranchName
                    $autoPushVal = Get-ConfiguredReview -Key "auto_push" -ProjectRoot $repoRoot
                    $autoPush = $false
                    if ($autoPushVal -eq "true") {
                        $autoPush = $true
                    }
                    $acceptDesc = if ($autoPush) {
                        "work looks good; merges to $primaryBranch and pushes to origin; pause after this item"
                    } else {
                        "work looks good; merges to $primaryBranch (local only); pause after this item"
                    }
                    $gateHandoffCommit = if ($handoff.PSObject.Properties["commit_hash"]) { $handoff.commit_hash } else { "" }
                    $gateRange = Get-GateReviewRange -PrimaryBranch $primaryBranch -TaskId $handoff.task_id -CommitHash $gateHandoffCommit
                    $baseSha = $gateRange.BaseSha
                    $branchSha = $gateRange.BranchSha

                    $template = [ordered]@{
                        task_id = $handoff.task_id
                        backlog_item = $handoff.task_id
                        gate_fired_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                        outcome = "accepted | rejected | redirected | abandoned"
                        reason = "Brief human description of why"
                        rework_requested = $false
                        redirect_target = $null
                        base_sha = $baseSha
                        branch_sha = $branchSha
                    }
                    $template | ConvertTo-Json | Set-Content -Path $gateTemplatePath -Encoding UTF8
                    
                    $workspacesDir = if ($Context.ContainsKey("WorkspacesDir")) { $Context.WorkspacesDir } else { Get-ConfiguredPath -Key "workspaces" -ProjectRoot $repoRoot }
                    $wtPath = Join-Path $workspacesDir ("implementation-" + $handoff.task_id)
                    $wtPathDisplay = $wtPath -replace '\\', '/'

                    $diffTool = Get-ConfiguredReview -Key "diff_tool" -ProjectRoot $repoRoot
                    $editor = Get-ConfiguredReview -Key "editor" -ProjectRoot $repoRoot

                    $diffToolCommand = ""
                    $editorOpenCommand = ""

                    if (![string]::IsNullOrEmpty($diffTool)) {
                        $resolvedDiffTool = Get-ConfiguredEditorCommand -EditorOrToolName $diffTool
                        $taskSessionDir = Join-Path $sessionDir $handoff.task_id
                        if (-not (Test-Path $taskSessionDir)) {
                            New-Item -ItemType Directory -Force -Path $taskSessionDir | Out-Null
                        }
                        $helperScriptPath = Join-Path $taskSessionDir "review-diff.ps1"
                        $resolvedDiffToolEscaped = $resolvedDiffTool -replace '"', '`"'
                        $scriptContent = @"
`$left = `$args[0]
`$right = `$args[1]
`$tmp = Join-Path `$env:TEMP "crucible-review/$($handoff.task_id)"
if (-not (Test-Path `$tmp)) { New-Item -ItemType Directory -Path `$tmp -Force | Out-Null }
`$leftCopy = Join-Path `$tmp ("left_" + (Split-Path -Leaf `$left))
`$rightCopy = Join-Path `$tmp ("right_" + (Split-Path -Leaf `$right))
Copy-Item `$left `$leftCopy -Force
Copy-Item `$right `$rightCopy -Force
& "$resolvedDiffToolEscaped" --diff `$leftCopy `$rightCopy
"@
                        try {
                            $scriptContent | Set-Content -LiteralPath $helperScriptPath -Encoding UTF8
                        } catch {}

                        $helperScriptPathDisplay = $helperScriptPath -replace '\\', '/'
                        $pwshCmd = Get-PwshCommand
                        $diffToolCommand = "git -C `"$repoRoot`" difftool -y --extcmd=`"$pwshCmd -NoProfile -ExecutionPolicy Bypass -File \`"$helperScriptPathDisplay\`"`" $baseSha..$branchSha"
                    }

                    $editorToUse = if (![string]::IsNullOrEmpty($editor)) { $editor } else { $diffTool }
                    if (![string]::IsNullOrEmpty($editorToUse)) {
                        $resolvedEditor = Get-ConfiguredEditorCommand -EditorOrToolName $editorToUse
                        $editorOpenCommand = "& `"$resolvedEditor`" `"$wtPathDisplay`""
                    }

                    Write-Host "`n[HUMAN GATE] Visual review options:" -ForegroundColor Yellow
                    if ($taskBranchExists) {
                        if (-not [string]::IsNullOrEmpty($diffToolCommand)) {
                            Write-Host "  - Launch visual diff tool (per-file):" -ForegroundColor Yellow
                            Write-Host "    $diffToolCommand" -ForegroundColor Cyan
                        }
                        Write-Host "  - Command-line text diff:" -ForegroundColor Yellow
                        Write-Host "    git -C `"$repoRoot`" diff $baseSha..$branchSha" -ForegroundColor Cyan
                        Write-Host "  - Open the worktree folder in your editor:" -ForegroundColor Yellow
                        if (-not [string]::IsNullOrEmpty($editorOpenCommand)) {
                            Write-Host "    $editorOpenCommand" -ForegroundColor Cyan
                        } else {
                            Write-Host "    $wtPathDisplay" -ForegroundColor Cyan
                        }
                    } else {
                        Write-Host "  - $noCodeClosureReviewHint" -ForegroundColor Cyan
                    }

                    # Write machine-readable signal file
                    $menu = "[HUMAN GATE] Task $($handoff.task_id) complete. Present this menu to the human:`n`n" +
                            "  1) Accept     - $acceptDesc`n" +
                            "  2) Reject     - something is wrong, send back for rework`n" +
                            "  3) Redirect   - accept this item and work on a specific item next (ask which one)`n" +
                            "  4) Abandon    - do not accept; stop the pipeline entirely`n`n" +
                            "Review options:`n"
                    if ($taskBranchExists) {
                        if (-not [string]::IsNullOrEmpty($diffToolCommand)) {
                            $menu += "  - Launch visual diff tool (per-file):`n" +
                                     "    $diffToolCommand`n"
                        }
                        $menu += "  - Command-line text diff:`n" +
                                 "    git -C `"$repoRoot`" diff $baseSha..$branchSha`n" +
                                 "  - Open the worktree folder in your editor:`n"
                        if (-not [string]::IsNullOrEmpty($editorOpenCommand)) {
                            $menu += "    $editorOpenCommand`n`n"
                        } else {
                            $menu += "    $wtPathDisplay`n`n"
                        }
                    } else {
                        $menu += "  - $noCodeClosureReviewHint`n`n"
                    }
                    $menu += "Gate fired. Run factory.ps1 -Init -TaskId $($handoff.task_id) -GateOutcome <choice> [-GateReason `"Reason`"] to record the decision."
                    $menu | Set-Content -Path $GATE_PENDING_FILE -Encoding UTF8

                    Write-Host "`n[HUMAN GATE] Task $($handoff.task_id) complete. Present this menu to the human:" -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "  1) Accept     - $acceptDesc" -ForegroundColor Cyan
                    Write-Host "  2) Reject     - something is wrong, send back for rework" -ForegroundColor Cyan
                    Write-Host "  3) Redirect   - accept this item and work on a specific item next (ask which one)" -ForegroundColor Cyan
                    Write-Host "  4) Abandon    - do not accept; stop the pipeline entirely" -ForegroundColor Cyan
                    Write-Host ""
                    Write-Host "[NEXT SESSION COMMAND] Run the following command:" -ForegroundColor Magenta
                    Write-Host "1. Show the menu above to the human and ask them to reply with 1, 2, 3, or 4." -ForegroundColor White
                    Write-Host "2. Map their choice to the outcome: 1=accepted 2=rejected 3=redirected 4=abandoned." -ForegroundColor White
                    Write-Host "3. Execute the gate recording command using -GateOutcome <choice> (e.g. -GateOutcome accepted)." -ForegroundColor White
                    Write-Host "4. Stop after recording the decision unless the human explicitly starts another task." -ForegroundColor White
                    
                    # Construct gate-specific command for next_step.txt
                    $pwshCmd = Get-PwshCommand
                    $gateCommand = "$pwshCmd -ExecutionPolicy Bypass -File `"$crucibleRoot/powershell/factory.ps1`" -Init -TaskId $($handoff.task_id) -GateOutcome accepted -GateReason `"<one concrete quality reason>`" -Quiet"
                    Write-NextStep -SessionDir $sessionDir -Command $gateCommand -TaskId $handoff.task_id -Specialist $handoff.source_phase
                    
                    exit 0
                }
            } else {
                # Cleanup machine-readable signal
                if (Test-Path $GATE_PENDING_FILE) { Remove-Item $GATE_PENDING_FILE -Force }
            }
        }
    }
}

function Invoke-RepositoryIntegrityGates {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    if ($null -eq $Context) {
        throw "FactoryContext is null."
    }
    $requiredKeys = @("Handoff", "IsBootstrap", "Quiet", "FrameworkPowerShell", "SessionDir", "LogFile", "CircuitBreakerHistoryFile")
    foreach ($key in $requiredKeys) {
        if (-not $Context.ContainsKey($key)) {
            throw "Required key '$key' is missing from FactoryContext."
        }
    }

    $handoff = $Context.Handoff
    $isBootstrap = [bool]$Context.IsBootstrap
    $Quiet = [bool]$Context.Quiet
    $FRAMEWORK_POWERSHELL = $Context.FrameworkPowerShell
    $sessionDir = $Context.SessionDir
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile
    $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }

    # --- 3a. Baseline Cleanliness Probe at Task START ---
    # Runs when a fresh task enters its first phase (grooming) via factory.ps1 -Init.
    $Init = if ($Context.ContainsKey("Init")) { [bool]$Context.Init } else { $false }
    if ($Init -and $handoff.target_phase -eq "grooming") {
        $rawStatus = git status --porcelain 2>&1
        $strayFiles = @()
        foreach ($line in $rawStatus) {
            if ($line.Length -lt 3) { continue }
            $statusCode = $line.Substring(0, 2)
            $path = $line.Substring(3).Trim()
            # Catch untracked (??) AND uncommitted modifications/additions/deletions in the main working tree.
            # The worktree lives under .agent-workspaces/ and is excluded, so these are always main-repo changes.
            $isStray = ($statusCode -match '\?') -or ($statusCode.Trim() -match '^[MADRCUT]')
            if ($isStray) {
                $ignored = $path -match '^(\.crucible[/\\]|\.agent-workspaces[/\\]|\.gemini[/\\]|\.antigravitycli[/\\]|\.vscode[/\\]|vendor[/\\])'
                if (-not $ignored) { $strayFiles += "$statusCode $path" }
            }
        }
        if ($strayFiles.Count -gt 0) {
            Write-Host "`n[ADVISORY] Pre-existing untracked files detected at task start:" -ForegroundColor Yellow
            foreach ($f in $strayFiles) {
                $status = $f.Substring(0, 2)
                $filePath = $f.Substring(3)
                $classification = Get-StrayFileClassification -Path $filePath -RepoRoot $repoRoot
                Write-Host "  - $f [$classification]" -ForegroundColor Yellow
            }
            Write-Host "These files are not part of the active task but may block deployment later. STASH or SURFACE them before final handoff.`n" -ForegroundColor Yellow
            
            Write-EventLog -Event "workspace_baseline" -TaskId $handoff.task_id -Phase $handoff.target_phase -Outcome "warned" -Notes ("Pre-existing stray files: " + ($strayFiles -join ", ")) -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
        } else {
            Write-Quiet "[WORKSPACE] Clean at baseline." -ForegroundColor Green
        }
    }

    # --- 3b. Backlog Integrity Gate ---
    # Run automatically when Groomer or Operator hands off (they own BACKLOG.md).
    if ($handoff.source_phase -eq "grooming" -or $handoff.source_phase -eq "deployment") {
        Write-Quiet "`n[BACKLOG] Running backlog integrity check..." -ForegroundColor Cyan
        try {
            $result = & "$FRAMEWORK_POWERSHELL/validate-backlog.ps1" -FixSummary -Quiet:$Quiet -ProjectRoot $repoRoot 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[BACKLOG] VALIDATION FAILED:" -ForegroundColor Red
                $result | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Red }
                Write-Host "`n[STOP] [NEXT SESSION COMMAND]: YOU must fix BACKLOG.md before proceeding." -ForegroundColor Red
                Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.source_phase -Outcome "blocked" -Notes "Backlog validation failed before handoff" -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                exit 2
            }
            Write-Quiet "[BACKLOG] Validation passed." -ForegroundColor Green
        } catch {
            Write-Host ("[BACKLOG] Validation script error: " + $_) -ForegroundColor Red
            exit 1
        }
    }

    # --- 3c. Dev Log Integrity Gate ---
    # Run automatically when Operator hands off to ensure Dev Logs are clean before next cycle.
    if ($handoff.source_phase -eq "deployment" -and $handoff.target_phase -ne "implementation" -and $handoff.task_id -notmatch '^C-FACTORY-' -and -not $isBootstrap) {
        Write-Quiet "`n[DEV LOG] Running Dev Log security validation..." -ForegroundColor Cyan
        $devLogPath = Join-Path $sessionDir "../dev-logs/UNPUBLISHED_LOGS.md"
        if (-not (Test-Path $devLogPath)) {
            Write-Host "[DEV LOG] VALIDATION FAILED: $devLogPath does not exist." -ForegroundColor Red
            Write-Host "`n[STOP] [NEXT SESSION COMMAND]: YOU must create the Dev Log before proceeding." -ForegroundColor Red
            exit 2
        }
        
        & "$FRAMEWORK_POWERSHELL/validate-dev-log.ps1" -FileToPublish $devLogPath
        if ($LASTEXITCODE -ne 0) {
            Write-Host "`n[STOP] [NEXT SESSION COMMAND]: YOU must fix the Dev Log PII/secrets before proceeding." -ForegroundColor Red
            Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.source_phase -Outcome "blocked" -Notes "Dev Log validation failed before handoff" -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            exit 2
        }
    }

    # --- 3d. Workspace Cleanliness Gate ---
    # Block Operator handoff if untracked files exist outside of private/ignored dirs.
    if ($handoff.source_phase -eq "deployment" -and $handoff.target_phase -ne "implementation" -and $handoff.task_id -notmatch '^C-FACTORY-' -and -not $isBootstrap) {
        $rawStatus = git status --porcelain 2>&1
        $strayFiles = @()
        foreach ($line in $rawStatus) {
            if ($line.Length -lt 3) { continue }
            $statusCode = $line.Substring(0, 2)
            $path = $line.Substring(3).Trim()
            # Catch untracked (??) AND uncommitted modifications/additions/deletions in the main working tree.
            # The worktree lives under .agent-workspaces/ and is excluded, so these are always main-repo changes.
            $isStray = ($statusCode -match '\?') -or ($statusCode.Trim() -match '^[MADRCUT]')
            if ($isStray) {
                $ignored = $path -match '^(\.crucible[/\\]|\.agent-workspaces[/\\]|\.gemini[/\\]|\.antigravitycli[/\\]|\.vscode[/\\]|vendor[/\\])'
                if (-not $ignored) { $strayFiles += "$statusCode $path" }
            }
        }
        if ($strayFiles.Count -gt 0) {
            Write-Host "`n[STOP] Workspace is not clean. The following untracked/uncommitted changes exist outside of private/ignored directories:" -ForegroundColor Red
            foreach ($f in $strayFiles) {
                $status = $f.Substring(0, 2)
                $filePath = $f.Substring(3)
                $classification = Get-StrayFileClassification -Path $filePath -RepoRoot $repoRoot
                Write-Host "  - $f [$classification]" -ForegroundColor Yellow
            }
            Write-Host "`nSTASH or SURFACE untracked non-private files. Require human confirmation before deleting anything that is not obviously empty/scratch (marked as safe-to-remove). Never blanket-delete." -ForegroundColor Red
            Write-Host "After resolving, re-run factory.ps1 -Init -TaskId $($handoff.task_id)" -ForegroundColor Red
            Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.source_phase -Outcome "blocked" -Notes ("Stray untracked files: " + ($strayFiles -join ", ")) -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            exit 2
        }
        Write-Quiet "[WORKSPACE] Clean - no stray untracked files." -ForegroundColor Green
    }

    # --- 3e. Task Dependency Gate ---
}

function Resolve-FactoryTransition {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    if ($null -eq $Context) {
        throw "FactoryContext is null."
    }
    $requiredKeys = @("Handoff", "IsBootstrap", "SessionDir", "FrameworkPowerShell", "NextFactoryCommand", "Quiet", "LogFile", "CircuitBreakerHistoryFile")
    foreach ($key in $requiredKeys) {
        if (-not $Context.ContainsKey($key)) {
            throw "Required key '$key' is missing from FactoryContext."
        }
    }

    $handoff = $Context.Handoff
    $isBootstrap = [bool]$Context.IsBootstrap
    $sessionDir = $Context.SessionDir
    $FRAMEWORK_POWERSHELL = $Context.FrameworkPowerShell
    $nextFactoryCmd = $Context.NextFactoryCommand
    $Quiet = [bool]$Context.Quiet
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile

    $isRework = Test-DeploymentReworkReentry -Handoff $handoff -SessionDir $sessionDir
    $validTransitions = Get-PipelineValidTransitions -DeploymentRework $isRework

    Write-Quiet ("[DEBUG] Transition: $($handoff.source_phase) -> $($handoff.target_phase)") -ForegroundColor DarkGray
    if (-not $validTransitions[$handoff.source_phase].Contains($handoff.target_phase)) {
        $transitionMsg = $handoff.source_phase + " -> " + $handoff.target_phase
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Phase $handoff.source_phase `
            -Outcome "blocked" -Notes ("Invalid DAG transition: " + $transitionMsg) `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
        $validTransitionSummary = @()
        $validTransitions.GetEnumerator() | ForEach-Object {
            $validTransitionSummary += ($_.Key + " -> " + ($_.Value -join " | "))
        }
        Write-WedgeReport -TaskId $handoff.task_id -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "invalid_transition" `
            -Why ("Invalid pipeline transition: " + $transitionMsg) `
            -RecoveryOverride ("Fix the handoff's target_phase field. Valid transitions: " + ($validTransitionSummary -join "; "))
        
        return @{
            ShouldExit = $true
            ExitCode = 2
            Reason = ""
            Transition = $null
            NextFactoryCommand = $null
            IsBootstrap = $false
        }
    }

    if ($handoff.target_phase -eq "done") {
        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }

        if ($handoff.source_phase -eq "grooming") {
            # Check if Research Gate approved it or Human Gate approved it
            $gateAlreadyPassed = $false
            
            # Check Research Gate approval first
            $researchGateApproved = $false
            $handoffDir = $Context.HandoffDir
            if (-not [string]::IsNullOrEmpty($handoffDir) -and (Test-Path $handoffDir)) {
                $handoffFiles = @(Get-ChildItem -Path $handoffDir -Filter ($handoff.task_id + "-*.json") -ErrorAction SilentlyContinue)
                foreach ($file in $handoffFiles) {
                    try {
                        $hObj = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                        if ($hObj.source_phase -eq "research" -and $hObj.human_decisions -and $hObj.human_decisions.approved -and $hObj.human_decisions.approved.Count -gt 0) {
                            $researchGateApproved = $true
                            break
                        }
                    } catch {}
                }
            }
            
            if ($researchGateApproved) {
                $gateAlreadyPassed = $true
            } else {
                # Check if Human Gate already passed
                if (-not [string]::IsNullOrEmpty($sessionDir)) {
                    $GATE_DIR = Join-Path $sessionDir "global/gate_decisions"
                    if (Test-Path $GATE_DIR) {
                        $decisions = @(Get-ChildItem -Path $GATE_DIR -Filter ($handoff.task_id + "-*.json") |
                            Where-Object { $_.Name -notmatch "gate_decision_.*_pending.json" } |
                            Sort-Object LastWriteTime -Descending)
                        if ($decisions.Count -gt 0) {
                            try {
                                $latestDecision = Get-Content $decisions[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                                $advancingOutcomes = @("accepted", "redirected")
                                if ($advancingOutcomes -contains $latestDecision.outcome) {
                                    $gateAlreadyPassed = $true
                                }
                            } catch {}
                        }
                    }
                }
            }
            
            if (-not $gateAlreadyPassed) {
                Write-Host "[STOP] Refusing grooming closure: no recorded human decision (Research Gate approval or Human Gate acceptance) found for task $($handoff.task_id)." -ForegroundColor Red
                return @{
                    ShouldExit = $true
                    ExitCode = 2
                    Reason = "Refusing grooming closure: no recorded human decision found."
                    Transition = $null
                    NextFactoryCommand = $null
                    IsBootstrap = $false
                }
            }

            # Auto-finalize if not already finalized
            $finalization = Get-TaskFinalizationDetails -TaskId $handoff.task_id -ProjectRoot $repoRoot
            if (-not $finalization.IsFinalized) {
                Write-Host "[D49] Auto-finalizing grooming closure task $($handoff.task_id)..." -ForegroundColor Cyan
                $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $repoRoot
                $backlogPath = Join-Path $backlogDir "BACKLOG.md"
                $activeSpecPath = Get-BacklogItemPathForTaskProjectRoot -Task $handoff.task_id -ProjectRoot $repoRoot
                
                if ([string]::IsNullOrEmpty($activeSpecPath) -or -not (Test-Path -LiteralPath $activeSpecPath)) {
                    throw "Active spec path not found for task $($handoff.task_id) during auto-finalization."
                }
                
                if ($activeSpecPath -match '(?i)[/\\]active[/\\]') {
                    # Load archive-task helper
                    $archiveLibPath = Join-Path $PSScriptRoot "archive-task.ps1"
                    if (-not (Get-Command "Invoke-BacklogTaskArchive" -ErrorAction SilentlyContinue)) {
                        if (Test-Path -LiteralPath $archiveLibPath) {
                            . $archiveLibPath
                        } else {
                            throw "archive-task helper not found at $archiveLibPath"
                        }
                    }
                    
                    $archiveResult = Invoke-BacklogTaskArchive -BacklogPath $backlogPath -SpecPath $activeSpecPath -Status Resolved
                    Write-Host ("[D49] SUCCESS: Auto-archived task as {0} (status {1}): {2}" -f $archiveResult.Type, $archiveResult.Status, $archiveResult.ArchivedRelPath) -ForegroundColor Green
                }
            }
        }

        Write-Host "`n====================================================" -ForegroundColor Green
        Write-Host "Pipeline Complete: Task $($handoff.task_id) is resolved!" -ForegroundColor Green
        Write-Host "====================================================`n" -ForegroundColor Green

        # Update state to remove the completed task
        & "$FRAMEWORK_POWERSHELL/update-session-state.ps1" -Specialist done -TaskId $handoff.task_id -UpdateJson "{}" -Merge $false -ProjectRoot $repoRoot

        # Log session_end/pipeline_complete
        $logPhase = if ($handoff.source_phase -eq "grooming") { "grooming" } else { "deployment" }
        Write-EventLog -Event "session_end" -TaskId $handoff.task_id -Phase $logPhase -Notes "Pipeline complete" `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
 
        # Cleanup any pending human gate files
        $GATE_PENDING_FILE = Join-Path $sessionDir ($handoff.task_id + "/gate_pending.txt")
        if (Test-Path $GATE_PENDING_FILE) { Remove-Item $GATE_PENDING_FILE -Force }

        return @{
            ShouldExit = $true
            ExitCode = 0
            Reason = ""
            Transition = $null
            NextFactoryCommand = $null
            IsBootstrap = $false
        }
    }

    # Warn on concurrent Groomer dispatch - parallel Groomers write to the shared BACKLOG.md without locking (Fix 11)
    if ($handoff.target_phase -eq "grooming") {
        $otherGroomerSessions = @(Get-ChildItem -Path $sessionDir -Recurse -Filter "task.md" -ErrorAction SilentlyContinue |
            Where-Object {
                $fullName = $_.FullName
                # 1. Exclude anything under session/archived/
                if ($fullName -match "[/\\]archived[/\\]") {
                    return $false
                }
                # 2. Match only grooming/task.md
                if ($fullName -notmatch "[/\\]grooming[/\\]task\.md$") {
                    return $false
                }
                # 3. Exclude current task ID
                if ($fullName -match [regex]::Escape($handoff.task_id)) {
                    return $false
                }
                # 4. Exclude tasks whose BACKLOG row is terminal (Production/Resolved)
                $otherTaskId = Split-Path -Parent (Split-Path -Parent $fullName) | Split-Path -Leaf
                if ([string]::IsNullOrWhiteSpace($otherTaskId)) {
                    return $false
                }

                $bDir = if ($Context.ContainsKey("BacklogDir")) { $Context.BacklogDir } else { "" }
                if ([string]::IsNullOrWhiteSpace($bDir)) {
                    $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
                    $bDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $repoRoot
                }

                $dependencySources = @(
                    @{ Path = Join-Path $bDir "BACKLOG.md"; Name = "BACKLOG.md" },
                    @{ Path = Join-Path $bDir "ARCHIVED.md"; Name = "ARCHIVED.md" }
                )

                $depStatus = ""
                $found = $false
                foreach ($source in $dependencySources) {
                    if (-not (Test-Path $source.Path)) { continue }
                    $lines = Get-Content -Path $source.Path -Encoding UTF8
                    $statusColumnIndex = -1
                    $escapedDep = [regex]::Escape($otherTaskId)
                    
                    foreach ($line in $lines) {
                        if ($line -match '^\|\s*ID\s*\|') {
                            $headerCols = ($line -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne "" }
                            $statusColumnIndex = [Array]::IndexOf($headerCols, "Status")
                            continue
                        }
                        if ($line -match '^\|\s*[-: ]+\|') { continue }
                        
                        if ($line -match "^\|\s*(:?\[$escapedDep\]\([^)]+\)|$escapedDep)\s*\|") {
                            $rowCols = ($line -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne "" }
                            if ($statusColumnIndex -ge 0 -and $statusColumnIndex -lt $rowCols.Count) {
                                $depStatus = $rowCols[$statusColumnIndex]
                            } elseif ($rowCols.Count -gt 0) {
                                $depStatus = $rowCols[$rowCols.Count - 1]
                            }
                            $found = $true
                            break
                        }
                    }
                    if ($found) { break }
                }

                if ($found -and -not [string]::IsNullOrWhiteSpace($depStatus)) {
                    $statusNormalized = $depStatus.Trim().ToLowerInvariant()
                    if ($statusNormalized -eq "production" -or $statusNormalized -eq "resolved") {
                        return $false
                    }
                }
                return $true
            })
        if ($otherGroomerSessions.Count -gt 0) {
            Write-Host "[WARN] Another Groomer task.md detected - running concurrent Groomers risks BACKLOG.md corruption:" -ForegroundColor Yellow
            $otherGroomerSessions | ForEach-Object { Write-Host "  - $($_.FullName)" -ForegroundColor Yellow }
            $otherGroomerSessions | ForEach-Object { Write-Host "  Proceed only after confirming the other session is fully complete." -ForegroundColor Yellow }
        }
    }

    return @{
        ShouldExit = $false
        ExitCode = 0
        Reason = ""
        Transition = "$($handoff.source_phase) -> $($handoff.target_phase)"
        NextFactoryCommand = $nextFactoryCmd
        IsBootstrap = $isBootstrap
    }
}
