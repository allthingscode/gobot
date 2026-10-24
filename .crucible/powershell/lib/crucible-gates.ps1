. (Join-Path $PSScriptRoot "platform.ps1")
. (Join-Path $PSScriptRoot "crucible-command.ps1")
. (Join-Path $PSScriptRoot "injection-detector.ps1")
. (Join-Path $PSScriptRoot "backlog-io.ps1")
. (Join-Path $PSScriptRoot "crucible-context.ps1")
. (Join-Path $PSScriptRoot "git.ps1")
. (Join-Path $PSScriptRoot "worktree.ps1")
. (Join-Path $PSScriptRoot "crucible-gates-wedge-report.ps1")
. (Join-Path $PSScriptRoot "crucible-gates-human.ps1")
. (Join-Path $PSScriptRoot "crucible-gates-handoff.ps1")
. (Join-Path $PSScriptRoot "crucible-gates-breakers.ps1")
. (Join-Path $PSScriptRoot "no-code-closure.ps1")
. (Join-Path $PSScriptRoot "checks-not-run.ps1")

function Get-GateNotRunSessionDir {
    # A skip that cannot be recorded would reach the Reviewer and the Human Gate as a pass. I12.
    param([Parameter(Mandatory=$true)][hashtable]$Context)
    if (-not $Context.ContainsKey("SessionDir") -or [string]::IsNullOrWhiteSpace([string]$Context["SessionDir"])) {
        throw "A skipped check cannot be recorded as not run: Context.SessionDir is missing."
    }
    return [string]$Context["SessionDir"]
}

function Clear-GateCheckNotRun {
    # A record that cannot be cleared stays as an over-report, which is the safe side, so a
    # context without SessionDir skips the clear where Get-GateNotRunSessionDir would refuse a write.
    param(
        [Parameter(Mandatory=$true)][hashtable]$Context,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Check
    )
    if (-not $Context.ContainsKey("SessionDir") -or [string]::IsNullOrWhiteSpace([string]$Context["SessionDir"])) { return }
    Clear-ChecksNotRun -SessionDir ([string]$Context["SessionDir"]) -TaskId $TaskId -Source $Source -Check $Check
}

function Get-RootRelativePath {
    # Cross-platform relative path of $Path under $Root. Avoids [System.Uri]/MakeRelativeUri:
    # on Linux an absolute path (e.g. /tmp/x) has no drive letter, so [System.Uri] treats it
    # as a relative URI and MakeRelativeUri throws "not supported for a relative URI".
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Path
    )
    # This display adapter also accepts non-qualified display paths (e.g. \shared\backlog).
    # Only full paths can be compared by the filesystem owner; others keep their spelling.
    if ($Root -match '^[A-Za-z]:$') { $Root += "\" }
    if (-not [System.IO.Path]::IsPathFullyQualified($Root) -or
        -not [System.IO.Path]::IsPathFullyQualified($Path)) { return $Path.Replace("\", "/") }
    # This display adapter retains the historical ordinal case rule and outside fallback.
    $relative = Get-PathRelativeToDirectory -Path $Path -Directory $Root -Comparison Ordinal -Separator "/"
    if ($null -ne $relative) { return $relative }
    return $Path.Replace("\", "/")
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

    $cruciblePath = Resolve-CrucibleBundleRoot -ProjectRoot $repoRoot -CrucibleRoot $crucibleRoot
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
    # Unlike the event above, the not-run record is what the Reviewer and Human Gate read. Item 258.
    $integrityTaskId = if ($Context.ContainsKey("TaskId") -and -not [string]::IsNullOrWhiteSpace([string]$Context.TaskId)) { [string]$Context.TaskId }
        elseif ($Context.ContainsKey("Handoff") -and $null -ne $Context.Handoff -and $Context.Handoff.PSObject.Properties["task_id"]) { [string]$Context.Handoff.task_id }
        else { "" }
    if ($Context.ContainsKey("FrameworkIntegrityBaseline") -and -not [string]::IsNullOrWhiteSpace($integrityTaskId)) {
        $integrityCheck = "framework integrity committed-change check"
        if ($null -eq $Context["FrameworkIntegrityBaseline"]) {
            Write-CheckNotRun -SessionDir (Get-GateNotRunSessionDir -Context $Context) -TaskId $integrityTaskId -Source "integrity gate" -Check $integrityCheck `
                -Reason "no task baseline (no base_commit and no task branch merge-base), so only the working tree was checked and framework edits committed during the task were not"
        } else {
            Clear-GateCheckNotRun -Context $Context -TaskId $integrityTaskId -Source "integrity gate" -Check $integrityCheck
        }
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
    Write-Host ("         " + (New-CrucibleCommand -Script "powershell/new-handoff.ps1" -Transport PowerShell -Parameters ([ordered]@{ TaskId = $handoff.task_id; Rebaseline = $true; BaseCommit = "<commit-of-the-bundle-update>"; ProjectRoot = (Get-RecoveryProjectRoot -Context $Context) }) -CrucibleRoot (Get-RecoveryCrucibleRoot -Context $Context))) -ForegroundColor Red
    Write-Host "       This carries the incoming handoff forward with only base_commit changed. It does not count against the handoff budget." -ForegroundColor Red
    exit 2
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
            $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { Resolve-ConfigProjectRoot }
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
                        # Only the task's own row counts; another row that mentions the ID
                        # in its title is not this task's status. Item 245.
                        for ($i = 0; $i -lt $statusLines.Count; $i++) {
                            if (Test-BacklogTaskRow -Line $statusLines[$i] -TaskId $handoff.task_id) {
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
                            } elseif ($statusLines[$matchingRowIdx] -match '\b(?:Production|Resolved)\b') {
                                $isPremature = $true
                            }
                        } elseif ($matchingRowIdx -ge 0 -and $statusLines[$matchingRowIdx] -match '\b(?:Production|Resolved)\b') {
                            $isPremature = $true
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
            $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { Resolve-ConfigProjectRoot }
            $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $repoRoot
            $backlogPath = Join-Path $backlogDir "BACKLOG.md"
            if (Test-Path -LiteralPath $backlogPath) {
                $backlogContent = Get-Content -LiteralPath $backlogPath -Raw -Encoding UTF8
                $hasExactBacklogRow = @($backlogContent -split "`r?`n" | Where-Object { Test-BacklogTaskRow -Line $_ -TaskId $handoff.task_id }).Count -gt 0
                if (-not $hasExactBacklogRow) {
                    # Fail closed: an ID only in prose, a prefix of another row, or a malformed row
                    # cannot show the task was finalized. Items 281 and 282, I8 and I11.
                    Write-Host ("[STOP] Quality gate failed: BACKLOG.md has no exact row for " + $handoff.task_id + ". A row must start with | " + $handoff.task_id + " | or | [" + $handoff.task_id + "](spec path) |. Repair the row in BACKLOG.md, then rerun this handoff.") -ForegroundColor Red
                    Write-EventLog -Event "quality_gate_retry" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                        -Outcome "retry_required" -Notes "Deployment finalization gate found no exact BACKLOG.md row" `
                        -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                    exit 2
                }
                if ($hasExactBacklogRow) {
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
            } else {
                Write-Host ("[STOP] Quality gate failed: BACKLOG.md is missing at " + $backlogPath + ", so " + $handoff.task_id + " cannot be shown finalized. Restore BACKLOG.md with an exact row for " + $handoff.task_id + ", then rerun this handoff.") -ForegroundColor Red
                Write-EventLog -Event "quality_gate_retry" -TaskId $handoff.task_id -Specialist $handoff.source_phase `
                    -Outcome "retry_required" -Notes "Deployment finalization gate found no BACKLOG.md" `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                exit 2
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
                Write-Host ("Tick the required ## Task List checkboxes in task.md, then re-run: " + (New-CrucibleCommand -Script "powershell/crucible.ps1" -Transport PowerShell -Parameters ([ordered]@{ Init = $true; TaskId = $handoff.task_id; ProjectRoot = (Get-RecoveryProjectRoot -Context $Context) }) -CrucibleRoot (Get-RecoveryCrucibleRoot -Context $Context))) -ForegroundColor Red
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

        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { Resolve-ConfigProjectRoot }
        $workspacesDir = if ($Context.ContainsKey("WorkspacesDir")) { $Context.WorkspacesDir } else { Get-ConfiguredPath -Key "workspaces" -ProjectRoot $repoRoot }
        $wtPath = Resolve-ImplementationWorktreePath -TaskId $handoff.task_id -WorkspacesDir $workspacesDir
        $baseArtifactDir = if (Test-Path $wtPath) { $wtPath } else { $repoRoot }

        foreach ($artifact in $handoff.artifacts) {
            if ([string]::IsNullOrWhiteSpace($artifact)) { continue }

            $exists = $false
            $matchedPath = $null
            foreach ($base in @($wtPath, $repoRoot)) {
                if ([string]::IsNullOrWhiteSpace($base)) { continue }
                $candidate = Resolve-PathFromRoot -Root $base -Path $artifact
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
                        $candidate = Resolve-PathFromRoot -Root $base -Path $archivedArtifact
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

    $hasAffinity = ($handoff.psobject.Properties["file_affinity"] -and $handoff.file_affinity -ne $null -and @($handoff.file_affinity).Count -gt 0)
    $conflictCheck = "file affinity conflict check"

    # --- 2.1 File Affinity Conflict Check ---
    if ($hasAffinity) {
        $affinityScript = "$FRAMEWORK_POWERSHELL/check-file-affinity.ps1"
        if (-not (Test-Path $affinityScript)) {
            Write-Host "[ADVISORY] check-file-affinity.ps1 is missing; file affinity conflict check skipped." -ForegroundColor Yellow
            Write-CheckNotRun -SessionDir (Get-GateNotRunSessionDir -Context $Context) -TaskId $handoff.task_id -Source "scope gate" `
                -Check $conflictCheck -Reason ("check-file-affinity.ps1 not found at " + $affinityScript + ", so overlap with other active tasks was not checked")
        } else {
            & $affinityScript -TaskId $handoff.task_id -Affinity $handoff.file_affinity
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Error: File affinity overlap detected with another active task." -ForegroundColor Red
                Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist "crucible" `
                    -Outcome "file_affinity_conflict" -Notes "Handoff blocked due to overlapping file affinity." `
                    -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE
                exit 1
            }
            Clear-GateCheckNotRun -Context $Context -TaskId $handoff.task_id -Source "scope gate" -Check $conflictCheck
        }
    } elseif (@("implementation", "verification", "deployment") -contains $handoff.source_phase -or @("implementation", "verification", "deployment") -contains $handoff.target_phase) {
        # The conflict check applies wherever code is written, reviewed or shipped. Research and
        # grooming-only transitions (research -> grooming, grooming -> research or done) change no
        # task files, so there is nothing to overlap and no skip to report. Item 258.
        Write-CheckNotRun -SessionDir (Get-GateNotRunSessionDir -Context $Context) -TaskId $handoff.task_id -Source "scope gate" `
            -Check $conflictCheck -Reason "no file_affinity declared, so overlap with other active tasks was not checked"
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
            $scopeCheck = "implementation scope check"
            if (@($declaredAffinity).Count -gt 0) {
                $outOfScopeFiles = @(Get-OutOfScopeImplementationFiles -WorktreePath $wtPath -TaskId $handoff.task_id -FileAffinity $declaredAffinity)
                if ($outOfScopeFiles.Count -eq 0) {
                    Clear-GateCheckNotRun -Context $Context -TaskId $handoff.task_id -Source "scope gate" -Check $scopeCheck
                }
            } else {
                # Empty affinity stays allowed; the skip is reported, not refused. Item 258.
                Write-Host "[ADVISORY] No file_affinity declared; scope check skipped." -ForegroundColor Yellow
                Write-CheckNotRun -SessionDir (Get-GateNotRunSessionDir -Context $Context) -TaskId $handoff.task_id -Source "scope gate" -Check $scopeCheck `
                    -Reason "no file_affinity declared, so the files this task changed were not compared with a declared scope"
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
        $repoRoot = if ($Context.ContainsKey("RepoRoot") -and $null -ne $Context["RepoRoot"]) { $Context["RepoRoot"] } else { Resolve-ConfigProjectRoot }
        try {
            # Files, not collapsed directories, so a new stub is judged by its own name.
            $statusLines = @(git -C $repoRoot status --porcelain --untracked-files=all 2>$null)
            if ($LASTEXITCODE -ne 0) { throw ("git status exited " + $LASTEXITCODE + " in " + $repoRoot) }
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
            Clear-GateCheckNotRun -Context $Context -TaskId $handoff.task_id -Source "scope gate" -Check "research scope check"
        } catch {
            # The gate does not throw on this advisory check, but its skip is reported. Item 258.
            Write-Host ("[ADVISORY] Research scope check could not run: " + $_.Exception.Message) -ForegroundColor Yellow
            Write-CheckNotRun -SessionDir (Get-GateNotRunSessionDir -Context $Context) -TaskId $handoff.task_id -Source "scope gate" `
                -Check "research scope check" -Reason ("could not read the changed files: " + $_.Exception.Message)
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
                $noCodeClosureRepoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { Resolve-ConfigProjectRoot }
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

function Assert-CodeTaskWorktree {
    # A task/<id> branch requires scope checks and independent verification in its
    # worktree; a missing directory must not bypass them. No branch means no code. Item 187.
    param(
        [Parameter(Mandatory=$true)][hashtable]$Context,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$WorktreePath,
        [Parameter(Mandatory=$true)][string]$Check
    )
    $repoRoot = if ($Context.ContainsKey("RepoRoot") -and $null -ne $Context["RepoRoot"]) { $Context["RepoRoot"] } else { Resolve-ConfigProjectRoot }
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
                $resolvedCrucibleRoot = Resolve-CrucibleBundleRoot -ProjectRoot $ProjectRoot -CrucibleRoot $crucibleRoot
                $researchDir = Join-Path $resolvedCrucibleRoot "research"
                if (Test-Path -LiteralPath $researchDir) {
                    $artifact = Get-ResearchFindingsArtifact -TaskId $Handoff.task_id -ResearchDirectory $researchDir
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
    $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { Resolve-ConfigProjectRoot }

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
        $bundleRoot = Resolve-CrucibleBundleRoot -ProjectRoot $repoRoot -CrucibleRoot $crucibleRoot
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
            Write-Host ("After resolving, re-run: " + (New-CrucibleCommand -Script "powershell/crucible.ps1" -Transport PowerShell -Parameters ([ordered]@{ Init = $true; TaskId = $handoff.task_id; ProjectRoot = $repoRoot }) -CrucibleRoot (Get-RecoveryCrucibleRoot -Context $Context))) -ForegroundColor Red
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
        $repoRoot = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { Resolve-ConfigProjectRoot }

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
                # 3. Exclude current task ID: the session directory name must equal it. Item 281.
                $otherTaskId = Split-Path -Parent (Split-Path -Parent $fullName) | Split-Path -Leaf
                $sessionOfFile = Split-Path -Parent (Split-Path -Parent $fullName)
                $isCurrentSession = if ([string]::IsNullOrEmpty($handoff.task_id)) {
                    [IO.Path]::GetFullPath($sessionOfFile).TrimEnd([char]92, [char]47) -eq [IO.Path]::GetFullPath($sessionDir).TrimEnd([char]92, [char]47)
                } else {
                    $otherTaskId -eq $handoff.task_id
                }
                if ($isCurrentSession) {
                    return $false
                }
                # 4. Exclude tasks whose BACKLOG row is terminal (Production/Resolved)
                if ([string]::IsNullOrWhiteSpace($otherTaskId)) {
                    return $false
                }

                $repoRootForStatus = if ($Context.ContainsKey("RepoRoot")) { $Context.RepoRoot } else { Resolve-ConfigProjectRoot }
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
