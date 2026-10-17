. (Join-Path $PSScriptRoot "platform.ps1")
. (Join-Path $PSScriptRoot "injection-detector.ps1")
. (Join-Path $PSScriptRoot "backlog-io.ps1")
. (Join-Path $PSScriptRoot "crucible-context.ps1")
. (Join-Path $PSScriptRoot "git.ps1")
. (Join-Path $PSScriptRoot "worktree.ps1")
. (Join-Path $PSScriptRoot "crucible-gates-wedge-report.ps1")
. (Join-Path $PSScriptRoot "no-code-closure.ps1")

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
                Write-Host ("Write the spec there, then rerun crucible.ps1 -Init -TaskId " + $TaskId + "; it bootstraps the task from the spec.") -ForegroundColor Red
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

function Get-CrucibleFrameworkOwnedRelativePath {
    # Returns the repo-relative path when $PathText names a framework-owned file inside
    # the bundle, or $null when it is outside the bundle or adopter-owned. Shared by the
    # working-tree and committed legs so one exclusion rule governs both.
    param(
        [Parameter(Mandatory=$true)][string]$PathText,
        [Parameter(Mandatory=$true)][string]$CruciblePrefix,
        [Parameter(Mandatory=$true)][string[]]$AdopterOwnedExcludes
    )

    $normalized = $PathText.Trim()
    if ($normalized -match ' -> ') {
        $normalized = ($normalized -split ' -> ')[-1].Trim()
    }
    $normalized = $normalized.Trim('"').Replace("\", "/")
    if (-not $normalized.StartsWith($CruciblePrefix)) { return $null }

    $relative = $normalized.Substring($CruciblePrefix.Length)
    if ([string]::IsNullOrWhiteSpace($relative)) { return $null }
    if (Test-CrucibleAdopterOwnedPath -RelativePath $relative -AdopterOwnedExcludes $AdopterOwnedExcludes) { return $null }

    return $normalized
}

function Resolve-CrucibleIntegrityBase {
    # Resolve the task baseline in merge-path order: handoff base_commit, then the
    # task branch's merge-base with the primary branch, so both gates agree on scope.
    # Return $null when neither resolves: base_commit is optional and bootstrap may
    # have no task branch. The caller must report an unverifiable gate, not a clean pass.
    param(
        [Parameter(Mandatory=$true)][string]$RepoRoot,
        [Parameter(Mandatory=$false)]$Handoff = $null,
        [Parameter(Mandatory=$false)][string]$TaskId = ""
    )

    if ($null -ne $Handoff -and $Handoff.PSObject.Properties["base_commit"] -and -not [string]::IsNullOrWhiteSpace([string]$Handoff.base_commit)) {
        return ([string]$Handoff.base_commit).Trim()
    }

    $resolvedTaskId = $TaskId
    if ([string]::IsNullOrWhiteSpace($resolvedTaskId) -and $null -ne $Handoff -and $Handoff.PSObject.Properties["task_id"]) {
        $resolvedTaskId = [string]$Handoff.task_id
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedTaskId)) {
        $branchRef = "task/$resolvedTaskId"
        $mergeBase = ""
        $mergeBaseExit = 1
        # Resolved against $RepoRoot, not the process working directory: this gate is a
        # function of the repo it was handed, not of wherever the caller is standing.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        git -C $RepoRoot show-ref --verify --quiet ("refs/heads/" + $branchRef) 2>$null
        $hasBranch = ($LASTEXITCODE -eq 0)
        if ($hasBranch) {
            $primaryBranch = Get-ConfiguredPrimaryBranch -ProjectRoot $RepoRoot
            $mergeBase = (git -C $RepoRoot merge-base $primaryBranch $branchRef 2>$null)
            $mergeBaseExit = $LASTEXITCODE
        }
        $ErrorActionPreference = $previousPreference

        if ($hasBranch -and $mergeBaseExit -eq 0 -and -not [string]::IsNullOrWhiteSpace($mergeBase)) {
            return ([string]$mergeBase).Trim()
        }
    }

    return $null
}

function Get-CrucibleFrameworkStatusChanges {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    # Throw on every read failure. An empty array means the tree was read and no
    # framework-owned files changed; unreadable evidence cannot count as clean. Item 35.
    $repoRoot = $Context.RepoRoot
    $crucibleRoot = $Context.CrucibleRoot
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        throw "Framework integrity check cannot run: Context.RepoRoot is empty."
    }
    if ([string]::IsNullOrWhiteSpace($crucibleRoot)) {
        throw "Framework integrity check cannot run: Context.CrucibleRoot is empty."
    }

    $cruciblePath = if ([System.IO.Path]::IsPathRooted($crucibleRoot)) {
        $crucibleRoot
    } else {
        Join-Path $repoRoot $crucibleRoot
    }
    if (-not (Test-Path -LiteralPath $cruciblePath)) {
        throw ("Framework integrity check cannot run: no Crucible bundle at " + $cruciblePath + ". Re-run init-project.ps1, or correct crucible_root in .crucible/config.yaml.")
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

    # Relax "Stop" so native stderr cannot throw before the exit-code guard runs.
    # Keep stderr separate: 2>&1 would corrupt column-parsed porcelain output. Item 35.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $statusLines = @(git -C $repoRoot status --porcelain -- $crucibleRoot 2>$null)
    $statusExit = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    if ($statusExit -ne 0) {
        throw ("Framework integrity check cannot run: 'git status' exited " + $statusExit + " in " + $repoRoot + ". The gate cannot confirm that framework-owned files are unmodified.")
    }

    # Diff against the task baseline as well as the working tree to catch committed
    # bundle edits while allowing pre-existing adopter customization; provenance
    # comparison would incorrectly flag that customization.
    $handoff = if ($Context.ContainsKey("Handoff")) { $Context.Handoff } else { $null }
    $contextTaskId = if ($Context.ContainsKey("TaskId")) { [string]$Context.TaskId } else { "" }
    $baseCommit = Resolve-CrucibleIntegrityBase -RepoRoot $repoRoot -Handoff $handoff -TaskId $contextTaskId
    # Recorded on the context so the caller can report an unrun leg. $null here means
    # the committed leg was skipped, which is a narrower check than this gate claims to
    # perform and must not be reported as a clean pass.
    $Context["FrameworkIntegrityBaseline"] = $baseCommit

    $diffLines = @()
    if ($null -ne $baseCommit) {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $diffLines = @(git -C $repoRoot diff --name-only ($baseCommit + "..HEAD") -- $crucibleRoot 2>$null)
        $diffExit = $LASTEXITCODE
        $ErrorActionPreference = $previousPreference
        if ($diffExit -ne 0) {
            throw ("Framework integrity check cannot run: 'git diff " + $baseCommit + "..HEAD' exited " + $diffExit + " in " + $repoRoot + ". The gate cannot confirm that framework-owned files are unmodified.")
        }
    }

    $cruciblePrefix = $crucibleRoot.Replace("\", "/").TrimEnd("/") + "/"
    $flagged = [ordered]@{}

    foreach ($line in $statusLines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) { continue }
        $statusCode = $line.Substring(0, 2)
        $owned = Get-CrucibleFrameworkOwnedRelativePath -PathText $line.Substring(3) -CruciblePrefix $cruciblePrefix -AdopterOwnedExcludes $adopterOwnedExcludes
        if ($null -eq $owned) { continue }
        $flagged[$owned] = $statusCode
    }

    foreach ($line in $diffLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $owned = Get-CrucibleFrameworkOwnedRelativePath -PathText $line -CruciblePrefix $cruciblePrefix -AdopterOwnedExcludes $adopterOwnedExcludes
        if ($null -eq $owned) { continue }
        if ($flagged.Contains($owned)) {
            $flagged[$owned] = ($flagged[$owned] + "+committed")
        } else {
            $flagged[$owned] = "committed"
        }
    }

    $changes = @()
    foreach ($path in $flagged.Keys) {
        $changes += ($flagged[$path] + " " + $path)
    }

    return @($changes)
}

function Assert-CrucibleFrameworkIntegrity {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    # A check that could not run is not a check that passed. Both outcomes stop the
    # pipeline; they are kept apart so the event log and the operator can tell a real
    # violation from a broken environment, and so the remediation text differs.
    try {
        $changes = @(Get-CrucibleFrameworkStatusChanges -Context $Context)
    } catch {
        $reason = $_.Exception.Message
        $failTaskId = if ($Context.ContainsKey("TaskId") -and -not [string]::IsNullOrWhiteSpace($Context.TaskId)) { $Context.TaskId } else { "unknown" }
        # The verdict is already decided by the time we get here, and the operator needs
        # to read the reason. A context too malformed to name a log file must not turn
        # that message into a second, less useful crash - so logging is best-effort and
        # the block below is not.
        try {
            Write-EventLog -Event "circuit_breaker" -TaskId $failTaskId -Specialist "crucible" `
                -Outcome "framework_integrity_check_failed" -Notes $reason `
                -LogFile $Context.LogFile -CircuitBreakerHistoryFile $Context.CircuitBreakerHistoryFile
        } catch {
            Write-Host ("[CIRCUIT BREAKER] Could not write the integrity-check event: " + $_.Exception.Message) -ForegroundColor DarkYellow
        }

        Write-Host "`n[CIRCUIT BREAKER] Framework integrity check could not run." -ForegroundColor Red
        Write-Host ("  " + $reason) -ForegroundColor Yellow
        Write-Host "`n[STOP] Resolve the condition above and re-run. This gate does not pass on a tree it cannot read." -ForegroundColor Red
        exit 2
    }

    # A gate that could only check half of what it claims is reported on the channel
    # built for exactly that - degraded/unverifiable with a machine-readable kind - so
    # analyze-evals.ps1 counts it under enforcement_coverage instead of it passing as a
    # clean check. This fires before the early return below: "nothing changed in the
    # working tree" is not the same statement as "nothing changed during this task".
    if ($Context.ContainsKey("FrameworkIntegrityBaseline") -and $null -eq $Context["FrameworkIntegrityBaseline"]) {
        $degradedTaskId = if ($Context.ContainsKey("TaskId") -and -not [string]::IsNullOrWhiteSpace($Context.TaskId)) { $Context.TaskId } else { "unknown" }
        try {
            Write-EventLog -Event "degraded" -TaskId $degradedTaskId -Specialist "crucible" `
                -Outcome "unverifiable" -Kind "framework_integrity_no_baseline" `
                -Notes "No task baseline (handoff carries no base_commit and no task branch merge-base resolves); only the working tree was checked." `
                -LogFile $Context.LogFile -CircuitBreakerHistoryFile $Context.CircuitBreakerHistoryFile
        } catch {
            Write-Quiet ("[INTEGRITY] Could not record the unverifiable-baseline event: " + $_.Exception.Message) -ForegroundColor DarkYellow
        }
        Write-Quiet "[INTEGRITY] No task baseline resolved; only the working tree was checked. A framework edit committed during this task would not be seen." -ForegroundColor Yellow
    }

    if ($changes.Count -eq 0) {
        return
    }

    $handoff = $Context.Handoff
    $joined = $changes -join ", "
    Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "crucible" `
        -Outcome "framework_integrity_violation" -Notes ("Framework-owned .crucible files changed before handoff: " + $joined) `
        -LogFile $Context.LogFile -CircuitBreakerHistoryFile $Context.CircuitBreakerHistoryFile

    Write-Host "`n[CIRCUIT BREAKER] Framework integrity violation detected." -ForegroundColor Red
    Write-Host "Specialists may not modify framework-owned files under .crucible/." -ForegroundColor Red
    foreach ($change in $changes) {
        Write-Host ("  - " + $change) -ForegroundColor Yellow
    }
    # Committed bundle edits are flagged too. Clear deliberate updates by re-baselining
    # the task onto them so the handoff records the decision.
    Write-Host "`n[STOP] Revert the framework-owned edits above before continuing." -ForegroundColor Red
    Write-Host "       If this was a deliberate bundle update, commit it and re-baseline the task onto that commit:" -ForegroundColor Red
    Write-Host ("         pwsh -ExecutionPolicy Bypass -File `".crucible/powershell/new-handoff.ps1`" -TaskId " + $handoff.task_id + " -Rebaseline -BaseCommit <commit-of-the-bundle-update> -ProjectRoot `"" + (Get-RecoveryProjectRoot -Context $Context) + "`"") -ForegroundColor Red
    Write-Host "       This carries the incoming handoff forward with only base_commit changed. It does not count against the handoff budget." -ForegroundColor Red
    exit 2
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
            -RecoveryOverride ("Restore powershell/validate-handoff.ps1 from the Crucible bundle, then rerun: pwsh -ExecutionPolicy Bypass -File `".crucible/powershell/crucible.ps1`" -Init -TaskId " + $handoff.task_id + " -ProjectRoot `"{project_root}`"")
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
    $Context.NextCrucibleCommand = "$pwshCmd -ExecutionPolicy Bypass -File `"$resolvedCrucibleRoot/powershell/crucible.ps1`" -Init -TaskId $($handoff.task_id) -ProjectRoot `"$($Context.RepoRoot)`" -Quiet"

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

function Complete-CrucibleSourceSession {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-CrucibleContextKeys -Context $Context -RequiredKeys @("Ceiling", "Quiet") `
        -NonNullKeys @("SessionDir", "Handoff", "LogFile", "CircuitBreakerHistoryFile")

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
                    $gateDecisionUnreadable = $false
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
                                } catch {
                                    # A decision exists but will not parse, so gate state is
                                    # unknown. Enforce as though it passed: this flag only ever
                                    # turns an additional check on, so the reading that skips it
                                    # is the one an unreadable file cannot justify. If the
                                    # backlog is genuinely finalized this still advances.
                                    $gateAlreadyPassed = $true
                                    $gateDecisionUnreadable = $true
                                }
                            }
                        }
                    }

                    if ($gateDecisionUnreadable) {
                        Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                            -Outcome "unverifiable" -Kind "unreadable_gate_decision" `
                            -Notes "The latest gate decision would not parse; the backlog finalization gate was enforced without confirming the human gate passed." `
                            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
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
                    -Outcome "warned" -Kind "task_checklist" -Notes ("Task checklist summary: required_unchecked=" + $requiredUncheckedCount + "; required_malformed=" + $requiredMalformedCount + "; optional_unchecked=" + $optionalUncheckedCount) `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            }

            if ($requiredFailureCount -gt 0) {
                Write-EventLog -Event "quality_gate_retry" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                    -Outcome "retry_required" -Notes ("Required task.md checklist quality gate failed: unchecked=" + $requiredUncheckedCount + "; malformed=" + $requiredMalformedCount) `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                Write-Host ("[STOP] Quality gate failed: " + $handoff.source_phase + " has required checklist issues (unchecked: " + $requiredUncheckedCount + ", malformed: " + $requiredMalformedCount + "). Complete required Task List items before handoff.") -ForegroundColor Red

                # Name offending lines: a count alone cannot tell the specialist which boxes to fix. Item 59.
                $checklistOffenders = @()
                foreach ($uncheckedEntry in $checklistGate.RequiredUnchecked) {
                    $checklistOffenders += [pscustomobject]@{ line = $uncheckedEntry.line; kind = "unchecked"; text = $uncheckedEntry.text }
                }
                foreach ($malformedEntry in $checklistGate.RequiredMalformed) {
                    $checklistOffenders += [pscustomobject]@{ line = $malformedEntry.line; kind = "malformed"; text = $malformedEntry.text }
                }
                $checklistOffenders = @($checklistOffenders | Sort-Object line)
                # Bound the list so a pathological task.md cannot bury the following instruction.
                $checklistListLimit = 20
                foreach ($offender in @($checklistOffenders | Select-Object -First $checklistListLimit)) {
                    Write-Host ("  task.md:" + $offender.line + " (" + $offender.kind + ") " + $offender.text) -ForegroundColor Red
                }
                if ($checklistOffenders.Count -gt $checklistListLimit) {
                    Write-Host ("  ... and " + ($checklistOffenders.Count - $checklistListLimit) + " more.") -ForegroundColor Red
                }
                Write-Host "Tick the required ## Task List checkboxes in task.md, then re-run crucible.ps1 -Init -TaskId $($handoff.task_id) -ProjectRoot `"$(Get-RecoveryProjectRoot -Context $Context)`"." -ForegroundColor Red
                exit 2
            }
        }

        # All source-session quality gates passed: record session_end exactly once.
        # Compute duration from the source specialist's session_start or recovery_start.
        $lastStart = Get-LastEntry -TaskId $handoff.task_id -Specialist $handoff.source_phase -Event "session_start" -LogFile $LOG_FILE
        $lastRecovery = Get-LastEntry -TaskId $handoff.task_id -Specialist $handoff.source_phase -Event "recovery_start" -LogFile $LOG_FILE

        $effectiveStart = $null
        if ($lastStart -and $lastRecovery) {
            if ((ConvertFrom-IsoTimestamp -Value $lastStart.timestamp) -gt (ConvertFrom-IsoTimestamp -Value $lastRecovery.timestamp)) {
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
            $startTime = (ConvertFrom-IsoTimestamp -Value $effectiveStart.timestamp).UtcDateTime
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
        # top-level duration_seconds field so eval consumers do not treat idle time as runtime,
        # and let Get-PhaseDurationMetrics decide whether a span that long can be reported as
        # wall time at all - a session resumed the next day cannot.
        $pctUsed = if ($ceiling -gt 0) { [math]::Min(100, [math]::Round(($handoff.cumulative_handoff_count / $ceiling) * 100)) } else { 0 }
        $metricsBlock = @{
            budget_tier      = $handoff.budget_tier
            budget_ceiling   = $ceiling
            handoff_count    = $handoff.cumulative_handoff_count
            budget_pct_used  = $pctUsed
        }
        foreach ($durationMetric in (Get-PhaseDurationMetrics -ElapsedSeconds $duration -Anomaly $anomaly).GetEnumerator()) {
            $metricsBlock[$durationMetric.Key] = $durationMetric.Value
        }

        Write-EventLog -Event "session_end" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
            -Outcome "success" `
            -Notes ("Handoff to " + $handoff.target_phase) `
            -HandoffCount $handoff.cumulative_handoff_count `
            -Metrics $metricsBlock `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
    }
}

function Invoke-CrucibleRuntimeValidation {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-CrucibleContextKeys -Context $Context -RequiredKeys @() `
        -NonNullKeys @("Handoff", "LogFile", "CircuitBreakerHistoryFile")

    $handoff = $Context.Handoff
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile

    # Git Hook Bypass Prevention
    $handoffSecurityText = Get-HandoffTextForSecurityScan -HandoffObj $handoff
    # Scans handoff text only. An on-disk bypass record must never feed this breaker:
    # nothing in the pipeline clears such a file, so one bypass would wedge every later
    # task in the repo, and adopters cannot produce it at all (the Linux leg is a
    # framework-dev tool, excluded from the install manifest).
    if ($handoffSecurityText -match '(?i)(^|\s)--no-verify(\s|$)' -or $handoffSecurityText -match '(?i)\bno[- ]verify\b' -or $handoffSecurityText -match '(?i)CRUCIBLE_BYPASS_LINUX_LEG') {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
            -Outcome "git_hook_bypass" -Notes "Handoff reported or referenced a git hook bypass attempt." `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "git_hook_bypass" -AttemptCount $handoff.cumulative_handoff_count `
            -LastSpecialist $handoff.source_phase -Summary "Handoff reported or referenced use of --no-verify or CRUCIBLE_BYPASS_LINUX_LEG, which bypass required git hooks."
        Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "git_hook_bypass" `
            -Why "Git hook bypass attempt detected. '--no-verify' and CRUCIBLE_BYPASS_LINUX_LEG require human review. Fix the hook failure or complete Linux leg verification instead of bypassing it."
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
            $quotedMissing = @($missingArtifacts | Where-Object { $_ -match "[`"']" -or $_ -ne $_.Trim() })
            if ($quotedMissing.Count -gt 0) {
                Write-Host ("[HINT] These artifact paths carry quote characters or surrounding whitespace, so the file may exist under the unquoted name: " + (($quotedMissing | ForEach-Object { "[" + $_ + "]" }) -join ", ") + ". The quotes reached new-handoff.ps1 as part of the path; write the handoff again with the paths unquoted.") -ForegroundColor Yellow
            }

            # Check if this is a retry (prior missing-artifact quality_gate_retry in event log)
            $hasPriorRetry = $false
            $retryHistoryParseFailureCount = 0
            if (Test-Path $LOG_FILE) {
                $lines = @(Get-Content $LOG_FILE -Tail 200 -Encoding UTF8)
                for ($i = $lines.Length - 1; $i -ge 0; $i--) {
                    # A blank line is formatting, not a miss. ConvertFrom-Json rejects an empty
                    # string and $ErrorActionPreference = "Stop" turns that into a throw, so
                    # without this skip a log ending in a stray newline reaches the fail-closed
                    # branch below and blocks a task that did nothing wrong.
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
                            break
                        }
                        if ($entry.task_id -eq $handoff.task_id -and $logPhase -eq $handoff.source_phase -and $entry.event -eq "quality_gate_retry" -and $entry.PSObject.Properties["notes"] -and $entry.notes -like "*artifact*") {
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
                Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                    -Outcome "blocked" -Notes ("Fabricated artifact path(s) in handoff: " + $joined) `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "fabricated_artifacts" -AttemptCount $handoff.cumulative_handoff_count `
                    -LastSpecialist $handoff.source_phase -Summary ("Handoff listed artifact paths that do not exist: " + $joined) -Artifacts $missingArtifacts
                Write-Host "[STOP] Artifact integrity gate failed. Fabricated artifact paths must be corrected before handoff can proceed." -ForegroundColor Red
                exit 2
            } elseif ($retryHistoryParseFailureCount -gt 0) {
                $unreadableRetryHistoryReason = "Retry history is unreadable: " + $retryHistoryParseFailureCount + " unparseable line(s) prevented determining whether this is a repeat artifact-integrity failure."
                Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                    -Outcome "unreadable_retry_history" -Notes $unreadableRetryHistoryReason `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "unreadable_retry_history" -AttemptCount $handoff.cumulative_handoff_count `
                    -LastSpecialist $handoff.source_phase -Summary $unreadableRetryHistoryReason -Artifacts $missingArtifacts
                Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "unreadable_retry_history" `
                    -Why $unreadableRetryHistoryReason
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
        if ($handoff.session_cycle_id -ne $env:CRUCIBLE_CYCLE_ID) {
            Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                -Outcome "warned" -Kind "session_cycle_id_mismatch" -Notes "session_cycle_id mismatch - agent may not have read task.md" `
                -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            Write-Host ("[STOP] session_cycle_id mismatch for $($handoff.source_phase). Expected: $($env:CRUCIBLE_CYCLE_ID), Got: $($handoff.session_cycle_id)") -ForegroundColor Red
            Write-Host "       All specialists must read task.md and echo its Cycle ID before handing off." -ForegroundColor Red
            exit 2
        } else {
            Write-Quiet ("[OK] session_cycle_id verified.") -ForegroundColor DarkGray
        }
    }
}

function Invoke-CrucibleScopeGates {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-CrucibleContextKeys -Context $Context -RequiredKeys @() `
        -NonNullKeys @("Handoff", "FrameworkPowerShell", "LogFile", "CircuitBreakerHistoryFile", "BacklogDir", "WorkspacesDir")

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
                Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "crucible" `
                    -Outcome "file_affinity_conflict" -Notes "Handoff blocked due to overlapping file affinity." `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                exit 1
            }
        }
    }

    # --- 2.1b Architect Scope Boundary Check ---
    if ($handoff.source_phase -eq "implementation" -and $handoff.target_phase -eq "verification") {
        $wtPath = Resolve-ImplementationWorktreePath -TaskId $handoff.task_id
        Assert-CodeTaskWorktree -Context $Context -TaskId $handoff.task_id -WorktreePath $wtPath -Check "scope check"
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
                Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "crucible" `
                    -Outcome "scope_violation" -Notes ("Architect modified files outside file_affinity: " + $joined) `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "scope_violation" -AttemptCount $handoff.cumulative_handoff_count `
                    -LastSpecialist $handoff.source_phase -Summary ("Architect modified files outside declared file_affinity: " + $joined) -Artifacts $outOfScopeFiles
                Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "scope_violation" `
                    -Why ("Scope boundary violation detected. Out-of-scope files: " + $joined + ". Expand file_affinity or revert out-of-scope changes.")
                exit 2
            }
        }
    }

    # --- 2.1c Research Scope Boundary Check ---
    if ($handoff.source_phase -eq "research" -and $handoff.target_phase -eq "grooming") {
        $repoRoot = if ($Context.ContainsKey("RepoRoot") -and $null -ne $Context["RepoRoot"]) { $Context["RepoRoot"] } else { (Get-Location).Path }
        try {
            # Files, not collapsed directories, so a new stub is judged by its own name.
            $statusLines = @(git -C $repoRoot status --porcelain --untracked-files=all 2>$null)
            $filingScope = Get-ResearchGateFilingScope -TaskId $handoff.task_id -RepoRoot $repoRoot
            $modifiedFiles = @()
            foreach ($line in $statusLines) {
                if ($line -match '^.{2}\s+(.*)$') {
                    $filePath = $Matches[1].Trim()
                    if ($filePath.StartsWith('"') -and $filePath.EndsWith('"')) {
                        $filePath = $filePath.Substring(1, $filePath.Length - 2)
                    }
                    $normalizedPath = $filePath.Replace("\", "/")
                    
                    $isAllowed = $false
                    foreach ($prefix in @(".crucible/research/", ((Get-RootRelativePath -Root $repoRoot -Path (Get-ConfiguredPath -Key "session" -ProjectRoot $repoRoot)).TrimEnd("/") + "/"))) {
                        if ($normalizedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $isAllowed = $true
                            break
                        }
                    }
                    
                    if (-not $isAllowed -and $null -ne $filingScope) {
                        $isAllowed = Test-ResearchGateFilingPath -Scope $filingScope -RelativePath $normalizedPath
                    }

                    if (-not $isAllowed) {
                        $modifiedFiles += $normalizedPath
                    }
                }
            }
            if ($modifiedFiles.Count -gt 0) {
                $joined = ($modifiedFiles -join ", ")
                Write-EventLog -Event "security_warning" -TaskId $handoff.task_id -Specialist "crucible" `
                    -Outcome "warned" -Notes ("research_scope_violation: " + $joined) `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                
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

# After a recorded Research Gate the filing pass writes each approved stub, their BACKLOG.md
# rows and the task's own status. The orchestrator writes the gate record, so it, not the
# specialist's handoff, says which stubs those are. Returns $null when no gate was recorded.
# Item 230.
function Get-ResearchGateFilingScope {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$RepoRoot
    )
    $gateDir = Join-Path (Get-ConfiguredPath -Key "session" -ProjectRoot $RepoRoot) "global/research_gate"
    if (-not (Test-Path -LiteralPath $gateDir)) { return $null }
    $record = Get-ChildItem -LiteralPath $gateDir -Filter ($TaskId + "-*.json") -File |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $record) { return $null }
    $decision = Get-Content -LiteralPath $record.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $approved = @()
    if ($decision.PSObject.Properties["approved"]) { $approved = @($decision.approved | ForEach-Object { [string]$_ }) }
    $backlogRel = (Get-RootRelativePath -Root $RepoRoot -Path (Get-ConfiguredPath -Key "backlog" -ProjectRoot $RepoRoot)).TrimEnd("/") + "/"
    return [pscustomobject]@{ BacklogPrefix = $backlogRel; Ids = @($approved + $TaskId) }
}

function Test-ResearchGateFilingPath {
    param(
        [Parameter(Mandatory=$true)]$Scope,
        [Parameter(Mandatory=$true)][string]$RelativePath
    )
    if (-not $RelativePath.StartsWith($Scope.BacklogPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    $inBacklog = $RelativePath.Substring($Scope.BacklogPrefix.Length)
    if ($inBacklog -ieq "BACKLOG.md") { return $true }
    $leaf = Split-Path -Leaf $inBacklog
    foreach ($id in $Scope.Ids) {
        if ($leaf -ieq ($id + ".md") -or $leaf.StartsWith($id + "_", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-CompletionArtifactGate {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-CrucibleContextKeys -Context $Context -RequiredKeys @() `
        -NonNullKeys @("Handoff", "BacklogDir", "SessionDir", "LogFile", "CircuitBreakerHistoryFile", "RepoRoot", "WorkspacesDir")

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
                $specFile = Get-BacklogItemPathForTaskProjectRoot -Task $handoff.task_id -ProjectRoot $Context.RepoRoot
                if ([string]::IsNullOrEmpty($specFile) -or -not (Test-Path $specFile)) {
                    $verificationPassed = $false
                    $errorMsg = "Mandatory spec file for $($handoff.task_id) not found.`nExpected paths: $($backlogDir)/{features,bugs,chores}/active/$($handoff.task_id)_<slug>.md or $($backlogDir)/{features,bugs,chores}/active/$($handoff.task_id).md`nFix: create or rename the spec to one of these paths before retrying the handoff."
                }
            }
            "implementation -> verification" {
                $wtPath = Resolve-ImplementationWorktreePath -TaskId $handoff.task_id
                if (Test-Path $wtPath) {
                    $branchRes = Invoke-Git -Directory $wtPath branch --show-current
                    $branchCheck = $branchRes.Raw.Trim()
                    if ($branchRes.ExitCode -ne 0 -or $branchCheck -ne "task/$($handoff.task_id)") {
                        $verificationPassed = $false
                        $errorMsg = "Architect worktree is not on mandatory task branch 'task/$($handoff.task_id)' (found '$branchCheck')."
                    } else {
                        $mainBranch = Get-ConfiguredPrimaryBranch
                        $commitsRes = Invoke-Git -Directory $wtPath log "$mainBranch..task/$($handoff.task_id)" --oneline
                        if ($commitsRes.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($commitsRes.Raw)) {
                            # Workaround for Crucible's own tasks (ignored files in .crucible/ cannot be committed easily)
                            $statusRes = Invoke-Git status --ignored --porcelain .crucible/
                            if ($statusRes.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($statusRes.Raw)) {
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
                        # Item 228: only the first frontmatter block can establish review approval.
                        if ($content -match "(?sm)\A---[ \t]*\r?\n(.*?)^---[ \t]*\r?$") {
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
                            # Item 216: prose approval cannot establish the required review fields.
                            $verificationPassed = $false
                            $errorMsg = "Review report is missing the required YAML header. Add YAML frontmatter delimited by '---' with 'review_decision: APPROVED' and 'acceptance_criteria_met: true' to review_report.md, then retry the handoff."
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
                        $mainBranch = Get-ConfiguredPrimaryBranch
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
                # No-Code Closure: no task branch means no merge to prove for research or
                # grooming. Share the decision with validate-handoff.ps1 so both use the
                # same evidence and the accepted handoff can be written. Item 72.
                $noCodeClosureRepoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
                $noCodeClosureCommitHash = if ($handoff.psobject.Properties["commit_hash"]) { [string]$handoff.commit_hash } else { "" }
                $isNoCodeClosure = Test-NoCodeClosure -TaskId ([string]$handoff.task_id) -CommitHash $noCodeClosureCommitHash -ProjectRoot $noCodeClosureRepoRoot
                if ($isNoCodeClosure) {
                    Write-Host "[INFO] No-Code Closure detected for $($handoff.task_id): research/grooming spec with no task branch and no commit_hash. Merge verification skipped." -ForegroundColor Cyan
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
                            $mainBranch = Get-ConfiguredPrimaryBranch

                            $gatePassed = $false
                            $gateDecisionUnreadable = $false
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
                                    } catch {
                                        # Same reading as the finalization gate in
                                        # Complete-CrucibleSourceSession: an unreadable decision
                                        # leaves gate state unknown, and the branch this flag
                                        # guards is the entire merge verification. Skipping it
                                        # would let a commit reach done unverified, so enforce.
                                        $gatePassed = $true
                                        $gateDecisionUnreadable = $true
                                    }
                                }
                            }

                            if ($gateDecisionUnreadable) {
                                Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist "crucible" `
                                    -Outcome "unverifiable" -Kind "unreadable_gate_decision" `
                                    -Notes "The latest gate decision would not parse; merge verification was enforced without confirming the human gate passed." `
                                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
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
            Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "crucible" `
                -Outcome "artifact_verification_failed" -Notes ("Artifact verification failed: " + $errorMsg) `
                -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "artifact_verification_failed" -AttemptCount $handoff.cumulative_handoff_count `
                -LastSpecialist $handoff.source_phase -Summary $errorMsg
            exit 1
        }
    }
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
        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
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
        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
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
        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
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

function Assert-CodeTaskWorktree {
    # A task/<id> branch requires scope checks and independent verification in its
    # worktree; a missing directory must not bypass them. No branch means no code. Item 187.
    param(
        [Parameter(Mandatory=$true)][hashtable]$Context,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$WorktreePath,
        [Parameter(Mandatory=$true)][string]$Check
    )
    $repoRoot = if ($Context.ContainsKey("RepoRoot") -and $null -ne $Context["RepoRoot"]) { $Context["RepoRoot"] } else { (Get-Location).Path }
    git -C $repoRoot rev-parse --verify --quiet "refs/heads/task/$TaskId" *> $null
    if ($LASTEXITCODE -ne 0) { return }
    if (Test-Path -LiteralPath $WorktreePath) {
        $wtBranch = (git -C $WorktreePath symbolic-ref --short -q HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and ([string]$wtBranch).Trim() -eq "task/$TaskId") { return }
        Write-Host "[STOP] $WorktreePath does not have task/$TaskId checked out, so the $Check cannot run against this task's code." -ForegroundColor Red
    } else {
        Write-Host "[STOP] task/$TaskId exists but its worktree $WorktreePath is missing, so the $Check cannot run." -ForegroundColor Red
    }
    Write-Host "       Recreate it, then rerun crucible.ps1:" -ForegroundColor Red
    Write-Host "         git worktree prune" -ForegroundColor Red
    Write-Host "         git worktree add `"$WorktreePath`" task/$TaskId" -ForegroundColor Red
    exit 2
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
        # Declare the circuit-breaker destination explicitly; dynamic scope can
        # silently misfile the operator's failure record. Item 16.
        [Parameter(Mandatory = $true)][string]$LogFile,
        [Parameter(Mandatory = $true)][string]$CircuitBreakerHistoryFile,
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
            if (Test-Path -LiteralPath $gdDir -ErrorAction Stop) {
                $candidates = @(Get-ChildItem -LiteralPath $gdDir -Filter ($TaskId + "-*.json") -ErrorAction Stop |
                    Sort-Object LastWriteTime -Descending)
                foreach ($f in $candidates) {
                    try {
                        $d = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                    } catch {
                        Write-Quiet "[HUMAN GATE] Warning: Could not inspect gate decision $($f.Name) while removing premature acceptance: $($_.Exception.Message)" -ForegroundColor Yellow
                        continue
                    }
                    if ($d.outcome -eq "accepted") {
                        try {
                            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                        } catch {
                            throw ("Could not inspect or remove premature accepted gate decisions before returning the merge outcome: " + $_.Exception.Message)
                        }
                        Write-Quiet "[HUMAN GATE] Removed premature 'accepted' gate decision $($f.Name) (merge did not complete)."
                        break
                    }
                }
            }
        } catch {
            throw ("Could not inspect or remove premature accepted gate decisions before returning the merge outcome: " + $_.Exception.Message)
        }
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
        Write-EventLog -Event "circuit_breaker" -TaskId $TaskId -Specialist "deployment" -Outcome "blocked" -Notes "Recurring Merge Conflicts - $MaxRebaseAttempts strikes at human gate" `
            -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
        if (Get-Command Write-BlockedTaskRecord -ErrorAction SilentlyContinue) {
            Write-BlockedTaskRecord -TaskId $TaskId -CircuitBreaker "recurring_merge_conflicts" -AttemptCount $currentRebase -LastSpecialist "deployment" -Summary "Recurring Merge Conflicts at human gate. Manual conflict resolution required."
        }
        Write-WedgeReport -TaskId $TaskId -ProjectRoot $ProjectRoot -SourcePhase "deployment" -TargetPhase "deployment" -BreakerCode "recurring_merge_conflicts" `
            -Why "Recurring Merge Conflicts: task/$TaskId rebased $currentRebase time(s) and still conflicts with $PrimaryBranch. Reduce scope or resolve the conflict manually."
        & $removePrematureAccept
        return "breaker"
    }

    $workspacesDir = Get-ConfiguredPath -Key "workspaces" -ProjectRoot $ProjectRoot
    $wtPath = Resolve-ImplementationWorktreePath -TaskId $TaskId -WorkspacesDir $workspacesDir

    $rebaseClean = $false
    if (Test-Path $wtPath) {
        Write-Quiet "[HUMAN GATE] Rebasing task/$TaskId onto $PrimaryBranch in $wtPath..."
        $rebaseRes = Invoke-Git -Directory $wtPath rebase $PrimaryBranch
        foreach ($line in $rebaseRes.Lines) { Write-Quiet $line }
        if ($rebaseRes.ExitCode -eq 0) {
            $rebaseClean = $true
        } else {
            Invoke-Git -Directory $wtPath rebase --abort | Out-Null
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

function Get-ActionsUrlFromOriginUrl {
    # Maps a GitHub remote (SSH or HTTPS, with or without .git) to its Actions page.
    # An unrecognized remote is handed back unchanged rather than guessed at, so the
    # operator sees a real URL or the literal remote, never a fabricated one.
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$OriginUrl)

    $originText = ([string]$OriginUrl).Trim()
    if ($originText -match '^git@github\.com:([^/]+/[^/]+?)(\.git)?$') {
        return "https://github.com/" + $Matches[1] + "/actions"
    }
    if ($originText -match '^https://github\.com/([^/]+/[^/]+?)(\.git)?/?$') {
        return "https://github.com/" + $Matches[1] + "/actions"
    }
    return $originText
}

function Write-GateCiRunUrl {
    # Emitted when CI could not be confirmed before finalizing, so the human has a
    # place to go and check. A missing or unreadable origin is not worth failing the
    # gate over: the advisory is simply omitted.
    $originUrl = (git remote get-url origin 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($originUrl)) {
        Write-Host ("[HUMAN GATE] CI run URL: " + (Get-ActionsUrlFromOriginUrl -OriginUrl $originUrl)) -ForegroundColor Yellow
    }
}

function Get-HumanGateOutcomes {
    # The one list. Invoke-HumanGate validates -GateOutcome against it and
    # Invoke-HumanGateAction names it when it refuses one. A second copy is how a
    # value comes to pass one check and match no dispatch arm.
    return @("accepted", "rejected", "redirected", "abandoned")
}

function Get-LowSignalGateReasons {
    # Exact phrases only, compared after trim and lowercase. A stock phrase with
    # more words ("Looks good. I see nothing concerning.") is the human's reason
    # and is recorded. sops/deployment.md and prompts/deployment_prompt.md list
    # these; gate-reason-rule.tests.ps1 keeps them in step. Item 144.
    return @(
        "n/a", "na", "none", "ok", "looks good", "looks good.",
        "approved", "accept", "accepted", "done", "ship it", "auto"
    )
}

function Test-GateReasonRefused {
    param([string]$Reason)
    if ([string]::IsNullOrWhiteSpace($Reason)) { return $true }
    $normalized = (ConvertTo-AsciiSafeText -Text $Reason).Trim().ToLowerInvariant()
    if ($normalized -eq "") { return $true }
    return ((Get-LowSignalGateReasons) -contains $normalized)
}

function Assert-GateReason {
    # TODO item 192: check both input paths before recording or acting on a decision.
    # A refusal names where the reason came from, so a human who filled the pending file is
    # not told to pass a CLI flag they never used.
    param([string]$Reason, [string]$DecisionFile = "")
    if (Test-GateReasonRefused -Reason $Reason) {
        $stock = (Get-LowSignalGateReasons) -join ", "
        if ([string]::IsNullOrWhiteSpace($DecisionFile)) {
            Write-Host ("Error: -GateReason is required and cannot be only a stock phrase (" + $stock + ").") -ForegroundColor Red
        } else {
            Write-Host ("Error: the `"reason`" in " + $DecisionFile + " is required and cannot be only a stock phrase (" + $stock + ").") -ForegroundColor Red
            Write-Host "       Write one concrete reason for the decision in that file, then rerun crucible.ps1. Nothing was recorded." -ForegroundColor Red
        }
        exit 1
    }
}

function Invoke-HumanGateAction {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Outcome,
        # Require declared event destinations so caller scope cannot misroute or
        # suppress circuit-breaker and CI-verification records. Item 16.
        [Parameter(Mandatory=$true)][string]$LogFile,
        [Parameter(Mandatory=$true)][string]$CircuitBreakerHistoryFile,
        [string]$ProjectRoot = "",
        [string]$SourcePhase = "deployment",
        [string]$GateReason = ""
    )
    $primaryBranch = Get-ConfiguredPrimaryBranch
    $resolvedProjectRoot = if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $ProjectRoot
    } else {
        $repoRootVar = Get-Variable -Name "REPO_ROOT" -ErrorAction SilentlyContinue
        if ($null -ne $repoRootVar) { $repoRootVar.Value } else { (Get-Location).Path }
    }

    if ($Outcome -eq "accepted" -or $Outcome -eq "redirected") {
        Invoke-HumanGateAcceptRedirect -TaskId $TaskId -Outcome $Outcome -LogFile $LogFile `
            -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile -ProjectRoot $resolvedProjectRoot `
            -PrimaryBranch $primaryBranch -SourcePhase $SourcePhase
    } elseif ($Outcome -eq "rejected" -or $Outcome -eq "abandoned") {
        Invoke-HumanGateRejectAbandon -TaskId $TaskId -Outcome $Outcome -ProjectRoot $resolvedProjectRoot `
            -PrimaryBranch $primaryBranch -SourcePhase $SourcePhase -GateReason $GateReason
    } else {
        # Reject unknown outcomes before side effects so a typo cannot pass the gate;
        # keep the pending file for the operator to correct. Item 38.
        throw ("Unrecognized gate outcome '" + $Outcome + "'. Expected one of: " + ((Get-HumanGateOutcomes) -join ", ") + ".")
    }
}

function Invoke-HumanGateAcceptRedirect {
    # Finalize human-approved work: backlog, merge, CI verification, worktree and
    # branch cleanup, archival and session-state pruning.
    # Event destinations are mandatory here because this arm writes events; the
    # reject/abandon arm does not need them. Item 14.
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Outcome,
        [Parameter(Mandatory=$true)][string]$LogFile,
        [Parameter(Mandatory=$true)][string]$CircuitBreakerHistoryFile,
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$PrimaryBranch,
        [string]$SourcePhase = "deployment"
    )

    $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $ProjectRoot
    $backlogPath = Join-Path $backlogDir "BACKLOG.md"

    # Read once, above the merge and archival, and used twice. The merge already decides whether
    # this task shipped code by asking whether it has a branch to merge; the archival needs
    # the same fact to record Production rather than Resolved, and reading it in two places
    # is how the two answers come to disagree.
    $hasTaskBranch = $false
    git show-ref --quiet "refs/heads/task/$TaskId"
    if ($LASTEXITCODE -eq 0) {
        $hasTaskBranch = $true
    }

    if ($SourcePhase -ne "grooming") {
        if ($hasTaskBranch) {
            $gateHandoff = $null
            $ghVar = Get-Variable -Name "handoff" -ErrorAction SilentlyContinue
            if ($null -ne $ghVar) { $gateHandoff = $ghVar.Value }
            $mergeResult = Invoke-HumanGateMerge -TaskId $TaskId -PrimaryBranch $PrimaryBranch -ProjectRoot $ProjectRoot -Handoff $gateHandoff `
        -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
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
    }

    # Archive only after the merge succeeded and before any push: Production means merged, and
    # a merge that routes to rework must leave the spec active. Item 222.
    # TODO item 197: keep the refusal decision here; archival returns its result.
    $finalizationOk = Invoke-HumanGateBacklogFinalization -TaskId $TaskId -ProjectRoot $ProjectRoot `
        -BacklogPath $backlogPath -HasTaskBranch $hasTaskBranch -SourcePhase $SourcePhase

    if (-not $finalizationOk) {
        try {
            Write-EventLog -Event "quality_gate_retry" -TaskId $TaskId -Phase "deployment" `
                -Outcome "retry_required" -Notes "Auto-finalization failed at human gate; push withheld" `
                -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
        } catch {
            Write-Host "[D44] WARNING: Failed to write quality_gate_retry event: $_" -ForegroundColor Yellow
        }
        exit 2
    }

    if ($SourcePhase -ne "grooming") {
        $autoPushVal = Get-ConfiguredReview -Key "auto_push" -ProjectRoot $ProjectRoot
        $autoPush = $false
        if ($autoPushVal -eq "true") {
            $autoPush = $true
        }
        $requireGreenCiVal = Get-ConfiguredReview -Key "require_green_ci" -ProjectRoot $ProjectRoot
        $requireGreenCi = $false
        if ($requireGreenCiVal -eq "true") {
            $requireGreenCi = $true
        }
        $ciTimeoutVal = Get-ConfiguredReview -Key "ci_timeout_minutes" -ProjectRoot $ProjectRoot
        $ciTimeoutMinutes = 20
        if (-not [string]::IsNullOrWhiteSpace($ciTimeoutVal)) {
            $parsedTimeout = 0
            if ([int]::TryParse($ciTimeoutVal, [ref]$parsedTimeout) -and $parsedTimeout -ge 0) {
                $ciTimeoutMinutes = $parsedTimeout
            }
        }
        $ciQueuedGraceVal = Get-ConfiguredReview -Key "ci_queued_grace_minutes" -ProjectRoot $ProjectRoot
        $ciQueuedGraceMinutes = 15
        if (-not [string]::IsNullOrWhiteSpace($ciQueuedGraceVal)) {
            $parsedGrace = 0
            if ([int]::TryParse($ciQueuedGraceVal, [ref]$parsedGrace) -and $parsedGrace -ge 0) {
                $ciQueuedGraceMinutes = $parsedGrace
            }
        }
        $ciRequiredChecks = Get-ConfiguredReview -Key "ci_required_checks" -ProjectRoot $ProjectRoot
        $ciPostPushWatchVal = Get-ConfiguredReview -Key "ci_post_push_watch" -ProjectRoot $ProjectRoot
        $ciPostPushWatch = ($ciPostPushWatchVal -eq "true")
        $mergedSha = (git rev-parse HEAD 2>$null).Trim()

        if ($autoPush) {
            $remotes = @(Invoke-GitChecked { git remote 2>$null })
            if ($remotes -contains "origin") {
                if ($requireGreenCi) {
                    $ciStagingPrefixVal = Get-ConfiguredReview -Key "ci_staging_branch_prefix" -ProjectRoot $ProjectRoot
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
                    $watchCmdArgs = @("-Commit", $mergedSha, "-TimeoutMinutes", $ciTimeoutMinutes, "-QueuedGraceMinutes", $ciQueuedGraceMinutes, "-CrucibleRoot", $ProjectRoot)
                    if (-not [string]::IsNullOrWhiteSpace($ciRequiredChecks)) {
                        $watchCmdArgs += @("-RequiredJobs", $ciRequiredChecks)
                    }
                    $ciOutput = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $watchScript @watchCmdArgs 2>&1)
                    $ciExitCode = $LASTEXITCODE
                    foreach ($line in $ciOutput) {
                        Write-Host $line
                    }

                    if ($ciExitCode -eq 0) {
                        Write-Quiet "[HUMAN GATE] Pushing merged changes to origin/$PrimaryBranch..."
                        Invoke-GitChecked { git push origin $PrimaryBranch }
                        if ($LASTEXITCODE -ne 0) {
                            Write-Host "[ERROR] git push failed. Please check network/credentials or run manually." -ForegroundColor Red
                            exit 1
                        }
                        Invoke-GitChecked { git push origin --delete $stagingBranch }

                        if ($ciPostPushWatch) {
                            Write-Host ("[HUMAN GATE] Watching origin CI post-push on " + $PrimaryBranch + " for " + $mergedSha + "...") -ForegroundColor Cyan
                            $postPushOutput = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $watchScript @watchCmdArgs 2>&1)
                            $postPushExitCode = $LASTEXITCODE
                            foreach ($line in $postPushOutput) {
                                Write-Host $line
                            }
                            if ($postPushExitCode -eq 1) {
                                Write-Host ("[CI WATCH] STATUS=POST_PUSH_RED: Commit " + $mergedSha + " passed staging CI but failed branch CI on " + $PrimaryBranch + "!") -ForegroundColor Red
                                try {
                                    Write-EventLog -Event "post_push_ci_red" -TaskId $TaskId -Specialist "crucible" -Outcome "warning" -Notes ("Commit " + $mergedSha + " failed post-push branch CI.") `
                                        -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
                                } catch {
                                    Write-Host "[HUMAN GATE] WARNING: Failed to write post_push_ci_red event: $_" -ForegroundColor Yellow
                                }
                            } elseif ($postPushExitCode -eq 5) {
                                Write-Host ("[CI WATCH] STATUS=POST_PUSH_MISSING_REQUIRED_JOBS: Commit " + $mergedSha + " branch CI run is missing required jobs (" + $ciRequiredChecks + ")!") -ForegroundColor Red
                                try {
                                    Write-EventLog -Event "post_push_ci_missing_required_jobs" -TaskId $TaskId -Specialist "crucible" -Outcome "warning" -Notes ("Post-push branch CI for " + $mergedSha + " missing required jobs: " + $ciRequiredChecks) `
                                        -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
                                } catch {
                                    Write-Host "[HUMAN GATE] WARNING: Failed to write post_push_ci_missing_required_jobs event: $_" -ForegroundColor Yellow
                                }
                            }
                        }
                    } elseif ($ciExitCode -eq 1) {
                        Invoke-GitChecked { git push origin --delete $stagingBranch }
                        Write-Host ("[HUMAN GATE] CI is RED for " + $mergedSha + "; task " + $TaskId + " is NOT done and master was NOT published (still local only). Fix forward and re-run the gate.") -ForegroundColor Red
                        exit 1
                    } elseif ($ciExitCode -eq 5) {
                        Invoke-GitChecked { git push origin --delete $stagingBranch }
                        Write-Host ("[HUMAN GATE] MISSING_REQUIRED_JOBS: Staging CI run for " + $mergedSha + " is missing required jobs (" + $ciRequiredChecks + "); refusing to publish master. Fix CI config/workflow and re-run the gate.") -ForegroundColor Red
                        try {
                            Write-EventLog -Event "ci_missing_required_jobs" -TaskId $TaskId -Specialist "crucible" -Outcome "blocked" -Notes ("Staging CI run for " + $mergedSha + " missing required jobs: " + $ciRequiredChecks) `
                                -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
                        } catch {
                            Write-Host "[HUMAN GATE] WARNING: Failed to write ci_missing_required_jobs event: $_" -ForegroundColor Yellow
                        }
                        exit 1
                    } elseif ($ciExitCode -notin @(2, 3, 4)) {
                        Invoke-GitChecked { git push origin --delete $stagingBranch }
                        Write-Host ("[HUMAN GATE] CI_CHECK_FAILED: Could not verify CI for " + $mergedSha + " (exit code " + $ciExitCode + "); refusing to publish " + $PrimaryBranch + " because require_green_ci is enabled. Fix gh CLI authentication/permissions or network and re-run the gate.") -ForegroundColor Red
                        try {
                            Write-EventLog -Event "ci_check_failed" -TaskId $TaskId -Specialist "crucible" -Outcome "blocked" -Notes ("Could not verify CI for " + $mergedSha + ": watch-adopter-ci exited with code " + $ciExitCode) `
                                -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
                        } catch {
                            Write-Host "[HUMAN GATE] WARNING: Failed to write ci_check_failed event: $_" -ForegroundColor Yellow
                        }
                        exit 1
                    } else {
                        # Rationale: Only a CONFIRMED RED or API/tool failure withholds the master push; genuine inconclusive CI (timeout, CI_NOT_STARTED, NO_RUNS)
                        # still finalizes-with-warning so an infrastructure stall does not wedge the pipeline (F1/F2 stance).
                        Write-Quiet "[HUMAN GATE] Pushing merged changes to origin/$PrimaryBranch..."
                        Invoke-GitChecked { git push origin $PrimaryBranch }
                        if ($LASTEXITCODE -ne 0) {
                            Write-Host "[ERROR] git push failed. Please check network/credentials or run manually." -ForegroundColor Red
                            exit 1
                        }

                        if ($ciExitCode -eq 2) {
                            Write-Host ("[HUMAN GATE] CI did not finish before timeout for " + $mergedSha + "; finalizing while CI continues.") -ForegroundColor Yellow
                            Write-GateCiRunUrl
                        } elseif ($ciExitCode -eq 4) {
                            Write-Host ("[HUMAN GATE] CI never left GitHub's queue for " + $mergedSha + " (no runner assigned within the grace window). This is likely a runner-availability outage, NOT a slow build. Finalizing, but re-check CI - and consider re-running the workflow - before treating " + $TaskId + " as shipped.") -ForegroundColor Yellow
                            Write-GateCiRunUrl
                        } elseif ($ciExitCode -eq 3) {
                            Write-Host ("[HUMAN GATE] CI could not be confirmed for " + $mergedSha + ": no workflow runs registered within the grace window. Finalizing, but verify CI manually before treating " + $TaskId + " as shipped.") -ForegroundColor Yellow
                        }

                        Invoke-GitChecked { git push origin --delete $stagingBranch }
                    }
                } else {
                    Write-Quiet "[HUMAN GATE] Pushing merged changes to origin/$PrimaryBranch..."
                    Invoke-GitChecked { git push origin $PrimaryBranch }
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
            Write-Host "Run the following command to publish:" -ForegroundColor Yellow
            Write-Host "  git push origin $PrimaryBranch" -ForegroundColor Cyan
            if ($requireGreenCi) {
                Write-Host "[HUMAN GATE] After that push, watch adopter CI for the merge commit:" -ForegroundColor Yellow
                Write-Host ("  pwsh -File .crucible/powershell/watch-adopter-ci.ps1 -Commit " + $mergedSha) -ForegroundColor Cyan
            }
        }

        $worktreeRemoved = Remove-ImplementationWorktree -TaskId $TaskId -ProjectRoot $ProjectRoot
        if ($hasTaskBranch -and $worktreeRemoved) {
            Write-Quiet "[HUMAN GATE] Deleting task branch task/$TaskId..."
            Invoke-GitChecked { git branch -d "task/$TaskId" }
        }
    }

    # Item 188: acceptance archives the same session used by the pipeline.
    $sessionDir = Get-ConfiguredPath -Key "session" -ProjectRoot $ProjectRoot
    $timestamp = Get-UtcFileTimestamp

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
        & $updateStateScript -Specialist done -TaskId $TaskId -UpdateJson "{}" -Merge $false -ProjectRoot $ProjectRoot | Out-Null
    } catch {
        Write-Quiet ("[HUMAN GATE] Could not prune session state for " + $TaskId + ": " + $_.Exception.Message)
    }
}

function Invoke-HumanGateRejectAbandon {
    # Return unaccepted work through backlog restore or Abandoned archival, then
    # the rework handoff to implementation.
    # The caller enforces GateReason for rejection so the rework handoff carries
    # the human's reason; it remains optional in this helper's signature.
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Outcome,
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$PrimaryBranch,
        [string]$SourcePhase = "deployment",
        [string]$GateReason = ""
    )
    if ($SourcePhase -ne "grooming") {
        if ($Outcome -eq "rejected") {
            # Restore backlog state if it was archived
            Restore-BacklogTask -TaskId $TaskId -ProjectRoot $ProjectRoot -ActiveStatus "In Progress"
        } elseif ($Outcome -eq "abandoned") {
            Invoke-AbandonedBacklogTaskArchive -TaskId $TaskId -ProjectRoot $ProjectRoot
        }

        $currentHead = (Invoke-GitChecked { git rev-parse "refs/heads/$PrimaryBranch" }).Trim()
        $parents = (Invoke-GitChecked { git log --pretty=%P -n 1 $currentHead }).Trim()
        $parentList = @(if ([string]::IsNullOrWhiteSpace($parents)) { } else { $parents -split '\s+' })

        # In the review-before-merge flow a rejected or abandoned task was never merged, so
        # there is normally nothing to undo. Unwind only when git proves the primary branch's
        # head is this task's merge: a merge commit whose second parent is the task branch
        # tip, or, once that branch is gone, whose subject names it. A hand-made fast-forward
        # leaves no merge commit, so it counts only when the branch's newest reflog entry is
        # that fast-forward. Being ahead of origin proves nothing: accepted merges
        # stay local until pushed, and resetting them would lose other tasks' work. Item 180.
        $headIsTaskMerge = $false
        $unwindTarget = $null
        $lastMove = Invoke-Git reflog show --format=%gs -n 1 "refs/heads/$PrimaryBranch"
        if ($parentList.Count -lt 2 -and $lastMove.ExitCode -eq 0 -and $lastMove.Raw.Trim() -eq "merge task/${TaskId}: Fast-forward") {
            $priorRes = Invoke-Git rev-parse --verify --quiet "refs/heads/$PrimaryBranch@{1}"
            if ($priorRes.ExitCode -eq 0) {
                $headIsTaskMerge = $true
                $unwindTarget = $priorRes.Raw.Trim()
            }
        }
        if ($parentList.Count -ge 2) {
            $taskTipRes = Invoke-Git rev-parse --verify --quiet "refs/heads/task/$TaskId"
            if ($taskTipRes.ExitCode -eq 0) {
                $headIsTaskMerge = ($taskTipRes.Raw.Trim() -eq $parentList[1])
            } else {
                $subject = (Invoke-GitChecked { git log --pretty=%s -n 1 $currentHead }).Trim()
                $headIsTaskMerge = ($subject -eq "Merge branch 'task/$TaskId'")
            }
            $unwindTarget = $parentList[0]
        }

        Invoke-GitChecked { git checkout $PrimaryBranch }
        if ($headIsTaskMerge) {
            Write-Quiet "[HUMAN GATE] Unwinding this task's local merge. Resetting $PrimaryBranch to its pre-merge tip ($unwindTarget)..."
            Invoke-GitChecked { git reset --hard $unwindTarget }
        } else {
            Write-Quiet "[HUMAN GATE] $PrimaryBranch does not end in a merge of task/$TaskId; leaving it untouched."
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

            Restore-ImplementationWorktree -TaskId $TaskId -ProjectRoot $ProjectRoot

            # Check if the task is present in the backlog before running new-handoff.ps1
            $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $ProjectRoot
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
                        ProjectRoot = $ProjectRoot
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

function Get-GateReviewRange {
    # Computes the base..branch commit range the Human Gate shows for visual/text
    # review. The branch endpoint is the task branch TIP (the actual reviewed work),
    # not the handoff's commit_hash -- that is the stale bootstrap-era HEAD recorded
    # when the task was first created, before any implementation commit. The base
    # endpoint is the MERGE-BASE of the primary branch and the task branch, not the
    # primary-branch tip: when the primary branch has advanced past where the task
    # was cut, its tip skews the diff (wrong direction / unrelated commits) and omits
    # the task's own changes. Falls back to the legacy (primary-tip..commit_hash)
    # behavior only when no task branch exists (e.g. Crucible's own tasks whose changes are
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

function Get-GateAcceptDescription {
    # What "1) Accept" promises depends on review.auto_push: with it off the merge
    # stays local, and the menu must not offer a push that will not happen.
    param(
        [Parameter(Mandatory=$true)][string]$PrimaryBranch,
        [Parameter(Mandatory=$true)][string]$ProjectRoot
    )

    $autoPushVal = Get-ConfiguredReview -Key "auto_push" -ProjectRoot $ProjectRoot
    if ($autoPushVal -eq "true") {
        return "work looks good; merges to $PrimaryBranch and pushes to origin; pause after this item"
    }
    return "work looks good; merges to $PrimaryBranch (local only); pause after this item"
}

function Write-GatePendingSurface {
    # First firing and re-runs of an unfilled template must show the same review surface.
    # Callers supply the range because re-runs prefer the original gate shas over a
    # freshly computed range that may have moved beneath the human. Item 14.
    param(
        [Parameter(Mandatory=$true)][hashtable]$Context,
        [Parameter(Mandatory=$true)][string]$RepoRoot,
        [Parameter(Mandatory=$true)][string]$SessionDir,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$PendingFilePath,
        [Parameter(Mandatory=$true)][bool]$TaskBranchExists,
        [string]$BaseSha = "",
        [string]$BranchSha = "",
        [string]$NoCodeReviewHint = "",
        [string]$AcceptDesc = ""
    )

    $workspacesDir = if ($Context.ContainsKey("WorkspacesDir")) { $Context.WorkspacesDir } else { Get-ConfiguredPath -Key "workspaces" -ProjectRoot $RepoRoot }
    $wtPath = Join-Path $workspacesDir ("implementation-" + $TaskId)
    $wtPathDisplay = $wtPath -replace '\\', '/'

    $diffTool = Get-ConfiguredReview -Key "diff_tool" -ProjectRoot $RepoRoot
    $editor = Get-ConfiguredReview -Key "editor" -ProjectRoot $RepoRoot

    $diffToolCommand = ""
    $editorOpenCommand = ""

    if (![string]::IsNullOrEmpty($diffTool)) {
        $resolvedDiffTool = Get-ConfiguredEditorCommand -EditorOrToolName $diffTool
        $taskSessionDir = Join-Path $SessionDir $TaskId
        if (-not (Test-Path $taskSessionDir)) {
            New-Item -ItemType Directory -Force -Path $taskSessionDir | Out-Null
        }
        $helperScriptPath = Join-Path $taskSessionDir "review-diff.ps1"
        $resolvedDiffToolEscaped = $resolvedDiffTool -replace '"', '`"'
        # GetTempPath() works across platforms: Windows uses TMP then TEMP, others TMPDIR.
        # TEMP alone can be unset off Windows. Emit the call bare so it runs in the
        # generated helper on the reviewer's platform; there is no $ to defer. Item 103.
        $scriptContent = @"
`$left = `$args[0]
`$right = `$args[1]
`$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "crucible-review/$TaskId"
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
        $diffToolCommand = "git -C `"$RepoRoot`" difftool -y --extcmd=`"$pwshCmd -NoProfile -ExecutionPolicy Bypass -File \`"$helperScriptPathDisplay\`"`" $BaseSha..$BranchSha"
    }

    $editorToUse = if (![string]::IsNullOrEmpty($editor)) { $editor } else { $diffTool }
    if (![string]::IsNullOrEmpty($editorToUse)) {
        $resolvedEditor = Get-ConfiguredEditorCommand -EditorOrToolName $editorToUse
        $editorOpenCommand = "& `"$resolvedEditor`" `"$wtPathDisplay`""
    }

    Write-Host "`n[HUMAN GATE] Visual review options:" -ForegroundColor Yellow
    if ($TaskBranchExists) {
        if (-not [string]::IsNullOrEmpty($diffToolCommand)) {
            Write-Host "  - Launch visual diff tool (per-file):" -ForegroundColor Yellow
            Write-Host "    $diffToolCommand" -ForegroundColor Cyan
        }
        Write-Host "  - Command-line text diff:" -ForegroundColor Yellow
        Write-Host "    git -C `"$RepoRoot`" diff $BaseSha..$BranchSha" -ForegroundColor Cyan
        Write-Host "  - Open the worktree folder in your editor:" -ForegroundColor Yellow
        if (-not [string]::IsNullOrEmpty($editorOpenCommand)) {
            Write-Host "    $editorOpenCommand" -ForegroundColor Cyan
        } else {
            Write-Host "    $wtPathDisplay" -ForegroundColor Cyan
        }
    } else {
        Write-Host "  - $NoCodeReviewHint" -ForegroundColor Cyan
    }

    # Write machine-readable signal file
    $menu = "[HUMAN GATE] Task $TaskId complete. Present this menu to the human:`n`n" +
            "  1) Accept     - $AcceptDesc`n" +
            "  2) Reject     - something is wrong, send back for rework`n" +
            "  3) Redirect   - accept this item and work on a specific item next (ask which one)`n" +
            "  4) Abandon    - do not accept; stop the pipeline entirely`n`n" +
            "Review options:`n"
    if ($TaskBranchExists) {
        if (-not [string]::IsNullOrEmpty($diffToolCommand)) {
            $menu += "  - Launch visual diff tool (per-file):`n" +
                     "    $diffToolCommand`n"
        }
        $menu += "  - Command-line text diff:`n" +
                 "    git -C `"$RepoRoot`" diff $BaseSha..$BranchSha`n" +
                 "  - Open the worktree folder in your editor:`n"
        if (-not [string]::IsNullOrEmpty($editorOpenCommand)) {
            $menu += "    $editorOpenCommand`n`n"
        } else {
            $menu += "    $wtPathDisplay`n`n"
        }
    } else {
        $menu += "  - $NoCodeReviewHint`n`n"
    }
    $menu += "Gate fired. Run crucible.ps1 -Init -TaskId $TaskId -ProjectRoot `"$RepoRoot`" -GateOutcome <choice> [-GateReason `"Reason`"] to record the decision."
    $menu | Set-Content -Path $PendingFilePath -Encoding UTF8
}

function Invoke-HumanGate {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    if ($null -eq $Context) {
        throw "CrucibleContext is null."
    }
    # Require LogFile and CircuitBreakerHistoryFile in the context so downstream
    # actions receive explicit destinations rather than caller scope or missing events. Item 16.
    Assert-CrucibleContextKeys -Context $Context `
        -RequiredKeys @("Handoff", "IsBootstrap", "SessionDir", "GateOutcome", "GateReason", "GateRedirectTarget", "CrucibleRoot", "Quiet") `
        -NonNullKeys @("LogFile", "CircuitBreakerHistoryFile")

    $handoff = $Context.Handoff
    $isBootstrap = [bool]$Context.IsBootstrap
    $sessionDir = $Context.SessionDir
    $GateOutcome = $Context.GateOutcome
    $GateReason = $Context.GateReason
    $GateRedirectTarget = $Context.GateRedirectTarget
    $crucibleRoot = $Context.CrucibleRoot
    $Quiet = [bool]$Context.Quiet
    $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile

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
        $validOutcomes = Get-HumanGateOutcomes
        # Cycle that this gate is firing in. An advancing decision is only honored
        # as "already passed" on a re-run within the SAME cycle, so a stale accept
        # from a prior cycle cannot silently bypass a fresh human gate encounter.
        $currentGateCycle = if ($handoff.PSObject.Properties["session_cycle_id"] -and -not [string]::IsNullOrEmpty($handoff.session_cycle_id)) {
            [string]$handoff.session_cycle_id
        } elseif (-not [string]::IsNullOrEmpty($env:CRUCIBLE_CYCLE_ID)) {
            [string]$env:CRUCIBLE_CYCLE_ID
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
            Assert-GateReason -Reason $GateReason
            
            $primaryBranch = Get-ConfiguredPrimaryBranch
            $gateHandoffCommit = if ($handoff.PSObject.Properties["commit_hash"]) { $handoff.commit_hash } else { "" }
            $gateRange = Get-GateReviewRange -PrimaryBranch $primaryBranch -TaskId $handoff.task_id -CommitHash $gateHandoffCommit
            $baseSha = $gateRange.BaseSha
            $branchSha = $gateRange.BranchSha

            $decision = [ordered]@{
                task_id = $handoff.task_id
                backlog_item = $handoff.task_id
                gate_fired_at = Get-UtcTimestamp
                outcome = $GateOutcome
                reason = $trimmedGateReason
                rework_requested = ($GateOutcome -eq "rejected")
                redirect_target = $GateRedirectTarget
                session_cycle_id = $currentGateCycle
                base_sha = $baseSha
                branch_sha = $branchSha
            }
            
            $timestamp = Get-UtcFileTimestamp
            $archivePath = Join-Path $GATE_DIR ($handoff.task_id + "-" + $timestamp + ".json")
            $decision | ConvertTo-Json | Set-Content -Path $archivePath -Encoding UTF8
            Write-Host ("`n[HUMAN GATE] Decision recorded via CLI flag: " + $GateOutcome) -ForegroundColor Green
            Write-Host ("Reason: " + $trimmedGateReason) -ForegroundColor Gray

            # Execute push or reset based on automated CLI decision. An accepted merge
            # that conflicts routes to rework and removes this premature decision itself
            # (see Invoke-HumanGateMerge) so a non-completed accept cannot block a retry.
            Invoke-HumanGateAction -TaskId $handoff.task_id -Outcome $GateOutcome -ProjectRoot $repoRoot -SourcePhase $handoff.source_phase -GateReason $trimmedGateReason `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE

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
                    $timestamp = Get-UtcFileTimestamp
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
                            
                            $primaryBranch = Get-ConfiguredPrimaryBranch
                            $acceptDesc = Get-GateAcceptDescription -PrimaryBranch $primaryBranch -ProjectRoot $repoRoot

                            $baseSha = ""
                            $branchSha = ""
                            if ($gateData.PSObject.Properties["base_sha"]) { $baseSha = $gateData.base_sha }
                            if ($gateData.PSObject.Properties["branch_sha"]) { $branchSha = $gateData.branch_sha }
                            if ([string]::IsNullOrEmpty($baseSha) -or [string]::IsNullOrEmpty($branchSha)) {
                                $primaryBranch = Get-ConfiguredPrimaryBranch
                                $gateHandoffCommit = if ($handoff.PSObject.Properties["commit_hash"]) { $handoff.commit_hash } else { "" }
                                $gateRange = Get-GateReviewRange -PrimaryBranch $primaryBranch -TaskId $handoff.task_id -CommitHash $gateHandoffCommit
                                $baseSha = $gateRange.BaseSha
                                $branchSha = $gateRange.BranchSha
                            }

                            Write-GatePendingSurface -Context $Context -RepoRoot $repoRoot -SessionDir $sessionDir `
                                -TaskId $handoff.task_id -PendingFilePath $GATE_PENDING_FILE -TaskBranchExists $taskBranchExists `
                                -BaseSha $baseSha -BranchSha $branchSha -NoCodeReviewHint $noCodeClosureReviewHint -AcceptDesc $acceptDesc
                            
                            # Construct gate-specific command for next_step.txt
                            $pwshCmd = Get-PwshCommand
                            $gateCommand = "$pwshCmd -ExecutionPolicy Bypass -File `"$crucibleRoot/powershell/crucible.ps1`" -Init -TaskId $($handoff.task_id) -ProjectRoot `"$repoRoot`" -GateOutcome accepted -GateReason `"<one concrete quality reason>`" -Quiet"
                            Write-NextStep -SessionDir $sessionDir -Command $gateCommand -TaskId $handoff.task_id -Specialist $handoff.source_phase
                            
                            exit 0
                        } else {
                            $fileReason = if ($gateData.PSObject.Properties["reason"]) { [string]$gateData.reason } else { "" }
                            Assert-GateReason -Reason $fileReason -DecisionFile $gateTemplatePath
                            $timestamp = Get-UtcFileTimestamp
                            $archivePath = Join-Path $GATE_DIR ($handoff.task_id + "-" + $timestamp + ".json")
                            $gateData | Add-Member -NotePropertyName "session_cycle_id" -NotePropertyValue $currentGateCycle -Force
                            # Item 226: the handoff writer needs the saved rejection to
                            # authorize the first deployment -> implementation re-entry.
                            if ($gateData.outcome -eq "rejected") {
                                $gateData | Add-Member -NotePropertyName "rework_requested" -NotePropertyValue $true -Force
                                $gateData | ConvertTo-Json | Set-Content -Path $archivePath -Encoding UTF8
                            }

                            # Execute push or reset based on manual decision
                            Invoke-HumanGateAction -TaskId $handoff.task_id -Outcome $gateData.outcome -ProjectRoot $repoRoot -SourcePhase $handoff.source_phase -GateReason $gateData.reason `
            -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE

                            # Archive other outcomes after the action, stamping the firing
                            # cycle so only a same-cycle re-run is already-passed.
                            if ($gateData.outcome -ne "rejected") {
                                $gateData | ConvertTo-Json | Set-Content -Path $archivePath -Encoding UTF8
                            }
                            Remove-Item -Path $gateTemplatePath -Force
                            Write-Host ("`n[HUMAN GATE] Decision recorded: " + $gateData.outcome) -ForegroundColor Green
                            
                            # Cleanup machine-readable signal
                            if (Test-Path $GATE_PENDING_FILE) { Remove-Item $GATE_PENDING_FILE -Force }

                            if ($gateData.outcome -eq "rejected" -or $gateData.outcome -eq "abandoned") {
                                exit 0
                            }
                        }
                    } catch {
                        # This catch spans the gate action too, not just the parse, so a
                        # fixed message would report an unrecognized outcome as bad JSON
                        # and send the operator to debug a file that is well-formed.
                        Write-Host ("Error handling gate decision template: " + $_.Exception.Message) -ForegroundColor Red
                        exit 1
                    }
                } else {
                    # Create template and exit
                    $primaryBranch = Get-ConfiguredPrimaryBranch
                    $acceptDesc = Get-GateAcceptDescription -PrimaryBranch $primaryBranch -ProjectRoot $repoRoot
                    $gateHandoffCommit = if ($handoff.PSObject.Properties["commit_hash"]) { $handoff.commit_hash } else { "" }
                    $gateRange = Get-GateReviewRange -PrimaryBranch $primaryBranch -TaskId $handoff.task_id -CommitHash $gateHandoffCommit
                    $baseSha = $gateRange.BaseSha
                    $branchSha = $gateRange.BranchSha

                    $template = [ordered]@{
                        task_id = $handoff.task_id
                        backlog_item = $handoff.task_id
                        gate_fired_at = Get-UtcTimestamp
                        outcome = "accepted | rejected | redirected | abandoned"
                        reason = "Brief human description of why"
                        rework_requested = $false
                        redirect_target = $null
                        base_sha = $baseSha
                        branch_sha = $branchSha
                    }
                    $template | ConvertTo-Json | Set-Content -Path $gateTemplatePath -Encoding UTF8
                    
                    Write-GatePendingSurface -Context $Context -RepoRoot $repoRoot -SessionDir $sessionDir `
                        -TaskId $handoff.task_id -PendingFilePath $GATE_PENDING_FILE -TaskBranchExists $taskBranchExists `
                        -BaseSha $baseSha -BranchSha $branchSha -NoCodeReviewHint $noCodeClosureReviewHint -AcceptDesc $acceptDesc

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
                    $gateCommand = "$pwshCmd -ExecutionPolicy Bypass -File `"$crucibleRoot/powershell/crucible.ps1`" -Init -TaskId $($handoff.task_id) -ProjectRoot `"$repoRoot`" -GateOutcome accepted -GateReason `"<one concrete quality reason>`" -Quiet"
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

    Assert-CrucibleContextKeys -Context $Context `
        -RequiredKeys @("Handoff", "IsBootstrap", "Quiet", "FrameworkPowerShell", "SessionDir") `
        -NonNullKeys @("LogFile", "CircuitBreakerHistoryFile")

    $handoff = $Context.Handoff
    $isBootstrap = [bool]$Context.IsBootstrap
    $Quiet = [bool]$Context.Quiet
    $FRAMEWORK_POWERSHELL = $Context.FrameworkPowerShell
    $sessionDir = $Context.SessionDir
    $LOG_FILE = $Context.LogFile
    $CB_HISTORY_FILE = $Context.CircuitBreakerHistoryFile
    $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }

    # --- 3a. Baseline Cleanliness Probe at Task START ---
    # Runs when a fresh task enters its first phase (grooming) via crucible.ps1 -Init.
    $Init = if ($Context.ContainsKey("Init")) { [bool]$Context.Init } else { $false }
    if ($Init -and $handoff.target_phase -eq "grooming") {
        $statusRes = Invoke-Git status --porcelain
        $rawStatus = $statusRes.Lines
        $strayFiles = @()
        foreach ($line in $rawStatus) {
            if ($line.Length -lt 3) { continue }
            $statusCode = $line.Substring(0, 2)
            $path = $line.Substring(3).Trim()
            # Catch untracked (??) AND uncommitted modifications/additions/deletions in the main working tree.
            # Item 188: configured runtime directories are excluded from main-repo cleanliness.
            $isStray = ($statusCode -match '\?') -or ($statusCode.Trim() -match '^[MADRCUT]')
            if ($isStray) {
                $ignored = ($path -match '^(\.crucible[/\\]|\.gemini[/\\]|\.antigravitycli[/\\]|\.vscode[/\\]|vendor[/\\])') -or (Test-ConfiguredRuntimePath -Path $path.Trim('"') -ProjectRoot $repoRoot)
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
    # Apply to every task id; fixture-shaped prefixes must not bypass deployment integrity. Item 97.
    if ($handoff.source_phase -eq "deployment" -and $handoff.target_phase -ne "implementation" -and -not $isBootstrap) {
        Write-Quiet "`n[DEV LOG] Running Dev Log security validation..." -ForegroundColor Cyan
        # Item 188: dev logs belong to the bundle, not to the session directory's parent.
        $crucibleRoot = if ($Context.ContainsKey("CrucibleRoot")) { $Context.CrucibleRoot } else { ".crucible" }
        $bundleRoot = if ([System.IO.Path]::IsPathRooted($crucibleRoot)) { $crucibleRoot } else { Join-Path $repoRoot $crucibleRoot }
        $devLogPath = Join-Path $bundleRoot "dev-logs/UNPUBLISHED_LOGS.md"
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
    # Apply to every task id; fixture-shaped prefixes must not bypass cleanliness. Item 97.
    if ($handoff.source_phase -eq "deployment" -and $handoff.target_phase -ne "implementation" -and -not $isBootstrap) {
        $statusRes = Invoke-Git status --porcelain
        $rawStatus = $statusRes.Lines
        $strayFiles = @()
        foreach ($line in $rawStatus) {
            if ($line.Length -lt 3) { continue }
            $statusCode = $line.Substring(0, 2)
            $path = $line.Substring(3).Trim()
            # Catch untracked (??) AND uncommitted modifications/additions/deletions in the main working tree.
            # Item 188: configured runtime directories are excluded from main-repo cleanliness.
            $isStray = ($statusCode -match '\?') -or ($statusCode.Trim() -match '^[MADRCUT]')
            if ($isStray) {
                $ignored = ($path -match '^(\.crucible[/\\]|\.gemini[/\\]|\.antigravitycli[/\\]|\.vscode[/\\]|vendor[/\\])') -or (Test-ConfiguredRuntimePath -Path $path.Trim('"') -ProjectRoot $repoRoot)
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
            Write-Host "After resolving, re-run crucible.ps1 -Init -TaskId $($handoff.task_id) -ProjectRoot `"$repoRoot`"" -ForegroundColor Red
            Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.source_phase -Outcome "blocked" -Notes ("Stray untracked files: " + ($strayFiles -join ", ")) -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
            exit 2
        }
        Write-Quiet "[WORKSPACE] Clean - no stray untracked files." -ForegroundColor Green
    }
}

function Resolve-CrucibleTransition {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    Assert-CrucibleContextKeys -Context $Context `
        -RequiredKeys @("Handoff", "IsBootstrap", "SessionDir", "FrameworkPowerShell", "NextCrucibleCommand", "Quiet") `
        -NonNullKeys @("LogFile", "CircuitBreakerHistoryFile")

    $handoff = $Context.Handoff
    $isBootstrap = [bool]$Context.IsBootstrap
    $sessionDir = $Context.SessionDir
    $FRAMEWORK_POWERSHELL = $Context.FrameworkPowerShell
    $nextCrucibleCmd = $Context.NextCrucibleCommand
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
        Write-WedgeReport -TaskId $handoff.task_id -ProjectRoot (Get-RecoveryProjectRoot -Context $Context) -SourcePhase $handoff.source_phase -TargetPhase $handoff.target_phase -BreakerCode "invalid_transition" `
            -Why ("Invalid pipeline transition: " + $transitionMsg) `
            -RecoveryOverride ("Fix the handoff's target_phase field. Valid transitions: " + ($validTransitionSummary -join "; "))
        
        return @{
            ShouldExit = $true
            ExitCode = 2
            Reason = ""
            Transition = $null
            NextCrucibleCommand = $null
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
                    NextCrucibleCommand = $null
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
            NextCrucibleCommand = $null
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

                $repoRootForStatus = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { (Get-Location).Path }
                $bDir = if ($Context.ContainsKey("BacklogDir")) { $Context.BacklogDir } else { "" }
                if ([string]::IsNullOrWhiteSpace($bDir)) {
                    $bDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $repoRootForStatus
                }

                # Use the shared status lookup so archived specs without backlog rows
                # still exclude finished tasks. Item 54.
                $otherInfo = Get-BacklogTaskStatus -Task $otherTaskId -ProjectRoot $repoRootForStatus -BacklogDir $bDir
                if ($otherInfo.Found -and (Test-BacklogTaskTerminal $otherInfo.Status)) {
                    return $false
                }
                return $true
            })
        if ($otherGroomerSessions.Count -gt 0) {
            # task.md presence alone cannot prove a Groomer is running; stale directories
            # accumulate. Use the newest phase-directory write because task.md dates only
            # scaffolding, while live sessions write prompts, context and transcripts.
            # This remains a heuristic, which the warning must state. Item 55.
            $staleAfterMinutes = 120
            $nowUtc = (Get-Date).ToUniversalTime()
            $activeSessions = @()
            $staleSessions = @()
            foreach ($session in $otherGroomerSessions) {
                $phaseDir = Split-Path -Parent $session.FullName
                $newestWrite = $session.LastWriteTimeUtc
                $phaseFiles = @(Get-ChildItem -LiteralPath $phaseDir -File -ErrorAction SilentlyContinue)
                foreach ($phaseFile in $phaseFiles) {
                    if ($phaseFile.LastWriteTimeUtc -gt $newestWrite) { $newestWrite = $phaseFile.LastWriteTimeUtc }
                }
                $record = @{
                    Path      = $session.FullName
                    LastWrite = $newestWrite
                    AgeMinutes = [int]([Math]::Floor(($nowUtc - $newestWrite).TotalMinutes))
                }
                if ($record.AgeMinutes -le $staleAfterMinutes) {
                    $activeSessions += $record
                } else {
                    $staleSessions += $record
                }
            }

            if ($activeSessions.Count -gt 0) {
                Write-Host "[WARN] Another Groomer session was written recently and may be running - concurrent Groomers risk BACKLOG.md corruption:" -ForegroundColor Yellow
                $activeSessions | ForEach-Object {
                    Write-Host ("  - " + $_.Path + " (last written " + $_.AgeMinutes + " min ago)") -ForegroundColor Yellow
                }
                Write-Host "  Proceed only after confirming the other session is fully complete." -ForegroundColor Yellow
            }

            if ($staleSessions.Count -gt 0) {
                Write-Host ("[INFO] " + $staleSessions.Count + " older Groomer session directory(ies) found, untouched for over " + $staleAfterMinutes + " minutes; not treated as concurrent:") -ForegroundColor DarkGray
                $staleSessions | ForEach-Object {
                    Write-Host ("  - " + $_.Path + " (last written " + (Get-IsoTimestamp $_.LastWrite) + ")") -ForegroundColor DarkGray
                }
            }
        }
    }

    return @{
        ShouldExit = $false
        ExitCode = 0
        Reason = ""
        Transition = "$($handoff.source_phase) -> $($handoff.target_phase)"
        NextCrucibleCommand = $nextCrucibleCmd
        IsBootstrap = $isBootstrap
    }
}
