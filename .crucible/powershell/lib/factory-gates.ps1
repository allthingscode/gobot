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
                $currentCommit = ""
                if (Test-Path .git) {
                    try {
                        $currentCommit = (git rev-parse HEAD 2>$null).Trim()
                    } catch {}
                }
                if (-not $currentCommit) {
                    $currentCommit = "0000000000000000000000000000000000000000"
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
                    commit_hash              = $currentCommit
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
    $rootUri = [System.Uri]($resolvedRoot + [System.IO.Path]::DirectorySeparatorChar)
    $pathUri = [System.Uri]$resolvedPath
    $Context.RelativeHandoffPath = [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace("\", "/")
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
                    $rootUri = [System.Uri]($resolvedRoot + [System.IO.Path]::DirectorySeparatorChar)
                    $pathUri = [System.Uri]$resolvedPath
                    $Context.RelativeHandoffPath = [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace("\", "/")
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
        Write-Host "`n[PREFLIGHT VALIDATION FAILED]" -ForegroundColor Red
        Write-Host ("reason_code=" + $missingReasonCode) -ForegroundColor Yellow
        Write-Host ("handoff_file=" + $handoffFileName) -ForegroundColor Yellow
        Write-Host "message=Validator script missing: powershell/validate-handoff.ps1" -ForegroundColor Yellow
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
            Write-Host "`n[PREFLIGHT VALIDATION FAILED]" -ForegroundColor Red
            Write-Host ("reason_code=" + $reasonCode) -ForegroundColor Yellow
            Write-Host ("handoff_file=" + $handoffFileName) -ForegroundColor Yellow
            Write-Host ("message=" + $errorMessage) -ForegroundColor Yellow
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
            $affectedMatches = [regex]::Matches($specContent, '(?ism)^##+\s+[^\r\n]*affected[^\r\n]*\r?\n(.*?)(\r?\n##+\s+|\z)')
            if ($affectedMatches.Count -gt 0) {
                $bodies = @()
                foreach ($m in $affectedMatches) {
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
                $mentionedPaths = @()
                $backtickMatches = [regex]::Matches($affectedSection, '`([^`\r\n]+)`')
                foreach ($m in $backtickMatches) {
                    $mentionedPaths += $m.Groups[1].Value.Trim()
                }
                $listMatches = [regex]::Matches($affectedSection, '(?m)^\s*-\s+([^\r\n]+)')
                foreach ($m in $listMatches) {
                    $val = $m.Groups[1].Value.Trim() -replace '`','' -replace '\*',''
                    $mentionedPaths += $val
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
                # D23: Spec has no affected-files/packages section to validate file_affinity against
                Write-Host "[WARN] Spec file does not declare an 'Affected Files' or 'Affected Packages' section. File affinity cannot be validated." -ForegroundColor Yellow
                Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist "factory" `
                    -Outcome "warned" -Notes "Spec file does not declare an affected files/packages section to validate file_affinity against." `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            }
        }
    }

    # Construct the standard session-end command. Use absolute paths so orchestrators can drive
    # specialists from outside the adopter repository without depending on their current directory.
    $resolvedCrucibleRoot = if ([System.IO.Path]::IsPathRooted($crucibleRoot)) { $crucibleRoot } else { Join-Path $Context.RepoRoot $crucibleRoot }
    $Context.NextFactoryCommand = "powershell.exe -ExecutionPolicy Bypass -File `"$resolvedCrucibleRoot/powershell/factory.ps1`" -Init -TaskId $($handoff.task_id) -ProjectRoot `"$($Context.RepoRoot)`" -Quiet"

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
        $allTaskHandoffs = @(Sort-HandoffFiles -Files $allTaskHandoffs)
        if ($allTaskHandoffs.Count -gt 1) {
            Write-Quiet ("[HANDOFF] Warning: Found $($allTaskHandoffs.Count - 1) previous handoff files for $($handoff.task_id) that may be stale.") -ForegroundColor Yellow
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

            if ($requiredFailureCount -gt 0 -or $optionalUncheckedCount -gt 0) {
                Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                    -Outcome "warned" -Notes ("Task checklist summary: required_unchecked=" + $requiredUncheckedCount + "; required_malformed=" + $requiredMalformedCount + "; optional_unchecked=" + $optionalUncheckedCount) `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            }

            if ($requiredFailureCount -gt 0) {
                Write-EventLog -Event "quality_gate_retry" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                    -Outcome "retry_required" -Notes ("Required task.md checklist quality gate failed: unchecked=" + $requiredUncheckedCount + "; malformed=" + $requiredMalformedCount) `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                Write-Host ("[STOP] Quality gate failed: " + $handoff.source_phase + " has required checklist issues (unchecked: " + $requiredUncheckedCount + ", malformed: " + $requiredMalformedCount + "). Complete required Task List items before handoff.") -ForegroundColor Red
                exit 2
            }
        }
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
        Write-Host "`n[CIRCUIT BREAKER] Git hook bypass attempt detected." -ForegroundColor Red
        Write-Host "  '--no-verify' and equivalent hook bypasses require human review." -ForegroundColor Red
        Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED. Fix the hook failure instead of bypassing it." -ForegroundColor Red
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
                Write-Host "[WARN] Artifact listed in handoff does not exist: $artifact" -ForegroundColor Yellow
                $missingArtifacts += $artifact
            } elseif ((Get-Item $matchedPath).Length -eq 0) {
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

            $outOfScopeFiles = @(Get-OutOfScopeImplementationFiles -WorktreePath $wtPath -TaskId $handoff.task_id -FileAffinity $declaredAffinity)
            if ($outOfScopeFiles.Count -gt 0) {
                $joined = ($outOfScopeFiles -join ", ")
                Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "factory" `
                    -Outcome "scope_violation" -Notes ("Architect modified files outside file_affinity: " + $joined)
                Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "scope_violation" -AttemptCount $handoff.cumulative_handoff_count `
                    -LastSpecialist $handoff.source_phase -Summary ("Architect modified files outside declared file_affinity: " + $joined) -Artifacts $outOfScopeFiles
                Write-Host "`n[CIRCUIT BREAKER] Scope boundary violation detected." -ForegroundColor Red
                Write-Host ("  Out-of-scope files: " + $joined) -ForegroundColor Red
                Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED. Expand file_affinity or revert out-of-scope changes." -ForegroundColor Red
                exit 2
            }
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
                # Workaround for factory tasks (restricted folders like .crucible/ cannot be committed)
                $isFactoryTask = $false
                if ($handoff.psobject.Properties["file_affinity"]) {
                    foreach ($aff in $handoff.file_affinity) {
                        if ($aff -match '^\.crucible/|\.gemini/|\.antigravitycli/|\.agent-workspaces/') { $isFactoryTask = $true; break }
                    }
                }

                if (-not $isFactoryTask) {
                    if (-not $handoff.psobject.Properties["commit_hash"] -or [string]::IsNullOrWhiteSpace($handoff.commit_hash)) {
                        $verificationPassed = $false
                        $errorMsg = "Handoff is missing 'commit_hash' metadata. Merge to master/main is mandatory."
                    } else {
                        $previousPreference = $ErrorActionPreference
                        $ErrorActionPreference = "Continue"
                        $commitExists = git rev-parse --verify "$($handoff.commit_hash)^{commit}" 2>&1
                        $commitExistsExitCode = $LASTEXITCODE
                        $ErrorActionPreference = $previousPreference
                        if ($commitExistsExitCode -ne 0 -or $commitExists -match "fatal") {
                            $verificationPassed = $false
                            $errorMsg = "Commit hash $($handoff.commit_hash) specified in handoff does not exist."
                        } else {
                            $mainBranch = Get-PrimaryBranchName

                            git merge-base --is-ancestor $($handoff.commit_hash) $mainBranch 2>&1
                            if ($LASTEXITCODE -ne 0) {
                                $verificationPassed = $false
                                $errorMsg = "Commit $($handoff.commit_hash) is not merged into $mainBranch."
                            }
                        }
                    }
                }
            }
            "deployment -> done" {
                # Workaround for factory tasks (restricted folders like .crucible/ cannot be committed)
                $isFactoryTask = $false
                if ($handoff.psobject.Properties["file_affinity"]) {
                    foreach ($aff in $handoff.file_affinity) {
                        if ($aff -match '^\.crucible/|\.gemini/|\.antigravitycli/|\.agent-workspaces/') { $isFactoryTask = $true; break }
                    }
                }

                if (-not $isFactoryTask) {
                    if (-not $handoff.psobject.Properties["commit_hash"] -or [string]::IsNullOrWhiteSpace($handoff.commit_hash)) {
                        $verificationPassed = $false
                        $errorMsg = "Handoff is missing 'commit_hash' metadata. Merge to master/main is mandatory."
                    } else {
                        $previousPreference = $ErrorActionPreference
                        $ErrorActionPreference = "Continue"
                        $commitExists = git rev-parse --verify "$($handoff.commit_hash)^{commit}" 2>&1
                        $commitExistsExitCode = $LASTEXITCODE
                        $ErrorActionPreference = $previousPreference
                        if ($commitExistsExitCode -ne 0 -or $commitExists -match "fatal") {
                            $verificationPassed = $false
                            $errorMsg = "Commit hash $($handoff.commit_hash) specified in handoff does not exist."
                        } else {
                            $mainBranch = Get-PrimaryBranchName

                            git merge-base --is-ancestor $($handoff.commit_hash) $mainBranch 2>&1
                            if ($LASTEXITCODE -ne 0) {
                                $verificationPassed = $false
                                $errorMsg = "Commit $($handoff.commit_hash) is not merged into $mainBranch."
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
    $handoff.reason = $handoff.reason -replace '[\r\n]+', ' ' -replace '"', "'" -replace '[#*`]', ''
    $handoff.reason = $handoff.reason.Trim()
    if ($handoff.reason.Length -gt 250) {
        $handoff.reason = $handoff.reason.Substring(0, 247) + "..."
    }

    # --- 2b. Passive Injection Pattern Scan ---
    $injectionPatterns = @(
        "ignore previous instructions",
        "ignore all previous",
        "disregard your instructions",
        "you must now",
        "new instruction:",
        "forget everything",
        "act as if",
        "pretend you are",
        "your new role is",
        "system prompt override"
    )

    $handoffRawLower = $handoffRaw.ToLower()
    $detectedPatterns = @()
    foreach ($pattern in $injectionPatterns) {
        if ($handoffRawLower.Contains($pattern.ToLower())) {
            $detectedPatterns += $pattern
        }
    }

    if ($detectedPatterns.Count -gt 0) {
        foreach ($detected in $detectedPatterns) {
            Write-EventLog -Event "security_warning" -TaskId $handoff.task_id -Specialist $handoff.source_phase -Outcome "warned" -Notes ("Injection pattern detected: " + $detected)
            Write-Quiet "`n[SECURITY WARNING] Potential injection pattern detected in handoff from $($handoff.source_phase)." -ForegroundColor Yellow
            Write-Quiet ("Pattern matched: " + $detected) -ForegroundColor Yellow
            Write-Quiet ("Review handoff file: " + $handoffFile) -ForegroundColor White
        }

        if ($handoff.source_phase -eq "research") {
            Write-Host "`n[STOP] Researcher handoffs with injection patterns require human review before proceeding." -ForegroundColor Red
            exit 2
        }
        Write-Quiet "[WARN] Proceeding - non-Researcher source. Human should review console output above.`n" -ForegroundColor Yellow
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
        & "$FRAMEWORK_POWERSHELL/update_session_state.ps1" -Specialist $handoff.target_phase -TaskId $handoff.task_id -UpdateJson $updateJson -Merge $true -ProjectRoot $repoRoot

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
    # Suspicious Content (Prompt Injection Defense - {task_id})
    if ($null -ne $handoff.psobject.Properties["suspicious_content"] -and $null -ne $handoff.suspicious_content -and $handoff.suspicious_content -ne "") {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "blocked" -Notes ("Suspicious Content Flagged: " + $handoff.suspicious_content)
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "human_escalation" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist $handoff.source_phase -Summary ("Suspicious content flagged in handoff: " + $handoff.suspicious_content)
        Write-Quiet "`n[CIRCUIT BREAKER] Suspicious Content detected." -ForegroundColor Yellow
        Write-Quiet "The Researcher specialist has flagged anomalous external instructions."
        Write-Quiet ("Details: " + $handoff.suspicious_content)
        Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED. Review external sources." -ForegroundColor Red
        exit 2
    }

    # Handoff Retry Limit
    if ($handoff.handoff_retry_count -gt 2 -and $handoff.source_phase -eq $handoff.target_phase) {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "blocked" -Notes "Persistent Task Failure - Retry over 2"
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "handoff_retry_exceeded" -AttemptCount $handoff.handoff_retry_count -LastSpecialist $handoff.target_phase -Summary "Persistent Task Failure - Retry over 2"
        Write-Quiet "`n[CIRCUIT BREAKER] Persistent Task Failure detected." -ForegroundColor Yellow
        Write-Quiet ("Task " + $handoff.task_id + " has been handed off to " + $handoff.target_phase + " " + $handoff.handoff_retry_count + " times.")
        Write-Quiet ("Reason: " + $handoff.reason)
        Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED." -ForegroundColor Red
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
        Write-Quiet "`n[CIRCUIT BREAKER] Review Stalemate detected." -ForegroundColor Yellow
        Write-Quiet ("Task " + $handoff.task_id + " has failed review " + $handoff.review_strike_count + " times.")
        Write-Quiet ("Reason: " + $handoff.reason)
        Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED." -ForegroundColor Red
        exit 2
    }

    # Token Budget Enforcement
    if ($handoff.budget_tier) {
        if (-not [string]::IsNullOrWhiteSpace($invalidBudgetTier)) {
            Write-Host ("Error: Invalid budget_tier '" + $handoff.budget_tier + "'. Allowed values: " + ((Get-BudgetTierList) -join ", ")) -ForegroundColor Red
            exit 1
        }

        if ($handoff.cumulative_handoff_count -gt $ceiling) {
            Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "budget_exceeded" -Notes ("Token Budget Exceeded - " + $handoff.cumulative_handoff_count + " over " + $ceiling)
            Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "budget_exceeded" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist $handoff.source_phase -Summary ("Token Budget Exceeded - " + $handoff.cumulative_handoff_count + " over " + $ceiling)
            Write-Quiet "`n[CIRCUIT BREAKER] Token Budget Exceeded." -ForegroundColor Yellow
            Write-Quiet ("Task " + $handoff.task_id + " has reached " + $handoff.cumulative_handoff_count + " handoffs. Ceiling: " + $ceiling + " for tier " + $handoff.budget_tier)
            Write-Quiet ("Reason: " + $handoff.reason)
            Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED. Review costs before continuing." -ForegroundColor Red
            exit 2
        }
    }

    # Recurring Merge Conflicts
    if ($handoff.psobject.Properties["rebase_count"] -and $handoff.rebase_count -ge 3) {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_phase -Outcome "blocked" -Notes "Recurring Merge Conflicts - 3 strikes"
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "recurring_merge_conflicts" -AttemptCount $handoff.rebase_count -LastSpecialist $handoff.target_phase -Summary "Recurring Merge Conflicts - 3 strikes. Task requires manual intervention."
        Write-Quiet "`n[CIRCUIT BREAKER] Recurring Merge Conflicts detected." -ForegroundColor Yellow
        Write-Quiet ("Task " + $handoff.task_id + " has been rebased " + $handoff.rebase_count + " times and still conflicts.")
        Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED. Reduce scope or resolve manually." -ForegroundColor Red
        exit 2
    }

    # A-2: Independent isolated test verification before accepting APPROVED ({task_id}, {task_id})
    if ($handoff.source_phase -eq "verification" -and $handoff.target_phase -eq "deployment") {
        $wtPath = Resolve-ImplementationWorktreePath -TaskId $handoff.task_id
        $isolatedChecksScript = "$FRAMEWORK_POWERSHELL/run-isolated-checks.ps1"
        if (Test-Path $wtPath) {
            if (-not (Test-Path $isolatedChecksScript)) {
                Write-Host ("`n[CIRCUIT BREAKER] Missing isolated checks script: " + $isolatedChecksScript) -ForegroundColor Red
                Write-Host "[STOP] HUMAN INTERVENTION REQUIRED. Restore script and rerun." -ForegroundColor Red
                exit 2
            }
            Write-Quiet "`n[VERIFY] Running independent isolated full verification in worktree before accepting APPROVED..." -ForegroundColor Cyan
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $testOutput = & powershell.exe -ExecutionPolicy Bypass -File $isolatedChecksScript -TaskId $handoff.task_id -Mode full 2>&1
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
                    Write-Host "`n[CIRCUIT BREAKER] Independent verification check failed on retry: $failedCheck" -ForegroundColor Red
                    if ($testOutput) {
                        Write-Host "  Check output:" -ForegroundColor Yellow
                        $testOutput | ForEach-Object { Write-Host ("    " + $_) }
                    }
                    Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED. Route back to Architect." -ForegroundColor Red
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

function Invoke-HumanGateAction {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Outcome
    )
    $primaryBranch = Get-PrimaryBranchName
    if ($Outcome -eq "accepted" -or $Outcome -eq "redirected") {
        $remotes = @(Invoke-GitChecked { git remote 2>$null })
        if ($remotes -contains "origin") {
            Write-Quiet "[HUMAN GATE] Pushing merged changes to origin/$primaryBranch..."
            Invoke-GitChecked { git push origin $primaryBranch }
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[ERROR] git push failed. Please check network/credentials or run manually." -ForegroundColor Red
                exit 1
            }
        } else {
            Write-Quiet "[HUMAN GATE] No remote 'origin' configured. Skipping git push."
        }
    } elseif ($Outcome -eq "rejected" -or $Outcome -eq "abandoned") {
        $currentHead = (Invoke-GitChecked { git rev-parse HEAD }).Trim()
        $parents = (Invoke-GitChecked { git log --pretty=%P -n 1 $currentHead }).Trim()
        $parentList = @(if ([string]::IsNullOrWhiteSpace($parents)) { } else { $parents -split '\s+' })

        $resetTarget = "origin/$primaryBranch"
        if ($parentList.Count -ge 2) {
            $resetTarget = $parentList[0]
            Write-Quiet "[HUMAN GATE] Unwinding local merge. Resetting $primaryBranch to pre-merge tip ($resetTarget)..."
        } else {
            Write-Quiet "[HUMAN GATE] Unwinding local merge. Resetting $primaryBranch to origin/$primaryBranch..."
        }

        Invoke-GitChecked { git checkout $primaryBranch }
        Invoke-GitChecked { git reset --hard $resetTarget }
        
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
        }
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

    # --- 3a. Human Gate ---
    if ($handoff.source_phase -eq "deployment" -and -not $isBootstrap) {
        $GATE_DIR = Join-Path $sessionDir "global/gate_decisions"
        if (-not (Test-Path $GATE_DIR)) {
            New-Item -ItemType Directory -Force -Path $GATE_DIR | Out-Null
        }

        $GATE_PENDING_FILE = Join-Path $sessionDir ($handoff.task_id + "/gate_pending.txt")
        $validOutcomes = @("accepted", "rejected", "redirected", "abandoned")
        $lowSignalGateReasons = @(
            "n/a", "na", "none", "ok", "looks good", "looks good.",
            "approved", "accept", "accepted", "done", "ship it", "auto"
        )
        
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

            $trimmedGateReason = if ([string]::IsNullOrWhiteSpace($GateReason)) { "" } else { $GateReason.Trim() }
            $normalizedGateReason = $trimmedGateReason.ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($trimmedGateReason) -or ($lowSignalGateReasons -contains $normalizedGateReason)) {
                Write-Host "Error: -GateReason is required and must be specific (not placeholder text like 'ok' or 'n/a')." -ForegroundColor Red
                exit 1
            }
            
            $decision = [ordered]@{
                task_id = $handoff.task_id
                backlog_item = $handoff.task_id
                gate_fired_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                outcome = $GateOutcome
                reason = $trimmedGateReason
                rework_requested = ($GateOutcome -eq "rejected")
                redirect_target = $GateRedirectTarget
            }
            
            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
            $archivePath = Join-Path $GATE_DIR ($handoff.task_id + "-" + $timestamp + ".json")
            $decision | ConvertTo-Json | Set-Content -Path $archivePath -Encoding UTF8
            Write-Host ("`n[HUMAN GATE] Decision recorded via CLI flag: " + $GateOutcome) -ForegroundColor Green
            Write-Host ("Reason: " + $trimmedGateReason) -ForegroundColor Gray

            # Execute push or reset based on automated CLI decision
            Invoke-HumanGateAction -TaskId $handoff.task_id -Outcome $GateOutcome

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
                        $gateAlreadyPassed = $true
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
                            
                            # Write machine-readable signal file
                            $menu = "[HUMAN GATE] Task $($handoff.task_id) complete. Present this menu to the human:`n`n" +
                                    "  1) Accept     - work looks good; pause after this item`n" +
                                    "  2) Reject     - something is wrong, send back for rework`n" +
                                    "  3) Redirect   - accept this item and work on a specific item next (ask which one)`n" +
                                    "  4) Abandon    - do not accept; stop the pipeline entirely`n`n" +
                                    "Gate fired. Run factory.ps1 -Init -TaskId $($handoff.task_id) -GateOutcome <choice> [-GateReason `"Reason`"] to record the decision."
                            $menu | Set-Content -Path $GATE_PENDING_FILE -Encoding UTF8
                            
                            # Construct gate-specific command for next_step.txt
                            $gateCommand = "powershell.exe -ExecutionPolicy Bypass -File `"$crucibleRoot/powershell/factory.ps1`" -Init -TaskId $($handoff.task_id) -GateOutcome accepted -Quiet"
                        Write-NextStep -SessionDir $sessionDir -Command $gateCommand -TaskId $handoff.task_id -Specialist $handoff.source_phase
                            
                            exit 0
                        } else {
                            # Execute push or reset based on manual decision
                            Invoke-HumanGateAction -TaskId $handoff.task_id -Outcome $gateData.outcome

                            # Archive the decision
                            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
                            $archivePath = Join-Path $GATE_DIR ($handoff.task_id + "-" + $timestamp + ".json")
                            Move-Item -Path $gateTemplatePath -Destination $archivePath -Force
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
                    $template = [ordered]@{
                        task_id = $handoff.task_id
                        backlog_item = $handoff.task_id
                        gate_fired_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                        outcome = "accepted | rejected | redirected | abandoned"
                        reason = "Brief human description of why"
                        rework_requested = $false
                        redirect_target = $null
                    }
                    $template | ConvertTo-Json | Set-Content -Path $gateTemplatePath -Encoding UTF8
                    
                    # Write machine-readable signal file
                    $menu = "[HUMAN GATE] Task $($handoff.task_id) complete. Present this menu to the human:`n`n" +
                            "  1) Accept     - work looks good; pause after this item`n" +
                            "  2) Reject     - something is wrong, send back for rework`n" +
                            "  3) Redirect   - accept this item and work on a specific item next (ask which one)`n" +
                            "  4) Abandon    - do not accept; stop the pipeline entirely`n`n" +
                            "Gate fired. Run factory.ps1 -Init -TaskId $($handoff.task_id) -GateOutcome <choice> [-GateReason `"Reason`"] to record the decision."
                    $menu | Set-Content -Path $GATE_PENDING_FILE -Encoding UTF8

                    Write-Host "`n[HUMAN GATE] Task $($handoff.task_id) complete. Present this menu to the human:" -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "  1) Accept     - work looks good; pause after this item" -ForegroundColor Cyan
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
                    $gateCommand = "powershell.exe -ExecutionPolicy Bypass -File `"$crucibleRoot/powershell/factory.ps1`" -Init -TaskId $($handoff.task_id) -GateOutcome accepted -Quiet"
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
    if ($handoff.source_phase -eq "deployment" -and $handoff.task_id -notmatch '^C-FACTORY-' -and -not $isBootstrap) {
        Write-Quiet "`n[DEV LOG] Running Dev Log security validation..." -ForegroundColor Cyan
        $devLogPath = Join-Path $sessionDir "../dev-logs/UNPUBLISHED_LOGS.md"
        if (-not (Test-Path $devLogPath)) {
            Write-Host "[DEV LOG] VALIDATION FAILED: $devLogPath does not exist." -ForegroundColor Red
            Write-Host "`n[STOP] [NEXT SESSION COMMAND]: YOU must create the Dev Log before proceeding." -ForegroundColor Red
            exit 2
        }
        
        & "$FRAMEWORK_POWERSHELL/validate_dev_log.ps1" -FileToPublish $devLogPath
        if ($LASTEXITCODE -ne 0) {
            Write-Host "`n[STOP] [NEXT SESSION COMMAND]: YOU must fix the Dev Log PII/secrets before proceeding." -ForegroundColor Red
            Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.source_phase -Outcome "blocked" -Notes "Dev Log validation failed before handoff" -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            exit 2
        }
    }

    # --- 3d. Workspace Cleanliness Gate ---
    # Block Operator handoff if untracked files exist outside of private/ignored dirs.
    if ($handoff.source_phase -eq "deployment" -and $handoff.task_id -notmatch '^C-FACTORY-' -and -not $isBootstrap) {
        $rawStatus = git status --porcelain 2>&1
        $strayFiles = @()
        foreach ($line in $rawStatus) {
            if ($line.Length -lt 3) { continue }
            $statusCode = $line.Substring(0, 2)
            $path = $line.Substring(3).Trim()
            # Catch untracked () AND uncommitted modifications/additions/deletions in the main working tree.
            # The worktree lives under .agent-workspaces/ and is excluded, so these are always main-repo changes.
            $isStray = ($statusCode -match '\') -or ($statusCode.Trim() -match '^[MADRCUT]')
            if ($isStray) {
                $ignored = $path -match '^(\.crucible[/\\]|\.agent-workspaces[/\\]|\.gemini[/\\]|\.antigravitycli[/\\]|\.vscode[/\\]|vendor[/\\])'
                if (-not $ignored) { $strayFiles += "$statusCode $path" }
            }
        }
        if ($strayFiles.Count -gt 0) {
            Write-Host "`n[STOP] Workspace is not clean. The following untracked files must be removed before handoff:" -ForegroundColor Red
            foreach ($f in $strayFiles) { Write-Host "  - $f" -ForegroundColor Yellow }
            Write-Host "`nDelete or move these files, then re-run factory.ps1 -Init -TaskId $($handoff.task_id)" -ForegroundColor Red
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

    $validTransitions = @{
        grooming       = @("implementation", "research", "verification")
        implementation = @("verification")
        verification   = @("deployment", "implementation")
        deployment     = @("grooming", "done")
        research       = @("grooming")
    }

    Write-Quiet ("[DEBUG] Transition: $($handoff.source_phase) -> $($handoff.target_phase)") -ForegroundColor DarkGray
    if (-not $validTransitions[$handoff.source_phase].Contains($handoff.target_phase)) {
        $transitionMsg = $handoff.source_phase + " -> " + $handoff.target_phase
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Phase $handoff.source_phase `
            -Outcome "blocked" -Notes ("Invalid DAG transition: " + $transitionMsg) `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
        Write-Host ("`n[CIRCUIT BREAKER] Invalid pipeline transition: " + $transitionMsg) -ForegroundColor Red
        Write-Host "Valid transitions:" -ForegroundColor Yellow
        $validTransitions.GetEnumerator() | ForEach-Object {
            $msg = "  $($_.Key) -> $($_.Value -join ' | ')"
            Write-Host $msg -ForegroundColor Yellow
        }
        Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED. Fix the handoff's target_phase field." -ForegroundColor Red
        
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
        Write-Host "`n====================================================" -ForegroundColor Green
        Write-Host "Pipeline Complete: Task $($handoff.task_id) is resolved!" -ForegroundColor Green
        Write-Host "====================================================`n" -ForegroundColor Green

        # Update state to remove the completed task
        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
        & "$FRAMEWORK_POWERSHELL/update_session_state.ps1" -Specialist done -TaskId $handoff.task_id -UpdateJson "{}" -Merge $false -ProjectRoot $repoRoot

        # Log session_end/pipeline_complete
        Write-EventLog -Event "session_end" -TaskId $handoff.task_id -Phase "deployment" -Notes "Pipeline complete" `
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
