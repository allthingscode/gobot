function Invoke-TaskRewind {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$ToPhase,
        [switch]$ResetBudget,
        [Parameter(Mandatory=$true)][string]$SessionDir,
        [Parameter(Mandatory=$true)][string]$HandoffDir,
        [Parameter(Mandatory=$true)][string]$LogFile,
        [Parameter(Mandatory=$true)][string]$CircuitBreakerHistoryFile,
        [switch]$Quiet,
        [Parameter(Mandatory=$true)][string]$WorkspacesDir
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $taskDir = Join-Path $SessionDir $TaskId
    $archiveDir = Join-Path $taskDir ("rewinds/" + $timestamp)

    # 1. Identify handoff candidates to archive
    $handoffFiles = @()
    if (Test-Path -LiteralPath $HandoffDir) {
        $handoffFiles = @(Get-ChildItem -Path $HandoffDir -Filter ($TaskId + "-*.json") -ErrorAction SilentlyContinue)
    }

    # 2. Identify phase directories to archive
    $allPhases = @("research", "grooming", "implementation", "verification", "deployment")
    $targetIdx = [Array]::IndexOf($allPhases, $ToPhase.ToLowerInvariant())
    $phasesToArchive = @()
    if ($targetIdx -ge 0) {
        for ($i = $targetIdx; $i -lt $allPhases.Count; $i++) {
            $phaseName = $allPhases[$i]
            $phasePath = Join-Path $taskDir $phaseName
            if (Test-Path -LiteralPath $phasePath) {
                $phasesToArchive += [pscustomobject]@{
                    Name = $phaseName
                    Path = $phasePath
                }
            }
        }
    }

    # 3. Check if log file exists
    $logExists = Test-Path -LiteralPath $LogFile

    # 4. If nothing to archive, no-op exit
    if ($handoffFiles.Count -eq 0 -and $phasesToArchive.Count -eq 0 -and (-not $ResetBudget -or -not $logExists)) {
        if (-not $Quiet) {
            Write-Host "[REWIND] No downstream state found for task $TaskId. State is already at or before $ToPhase." -ForegroundColor Green
        }
        return
    }

    # 5. Ensure task directory exists so we can write rewinds
    if (-not (Test-Path -LiteralPath $taskDir)) {
        New-Item -ItemType Directory -Path $taskDir -Force | Out-Null
    }

    # 6. Create archive directory
    New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null

    # 7. Write rewind event to log file before moving it (if it exists)
    if ($logExists) {
        Write-EventLog -Event "rewind" -TaskId $TaskId -Phase $ToPhase -Outcome "success" -Notes "Rewound to $ToPhase" -LogFile $LogFile -CircuitBreakerHistoryFile $CircuitBreakerHistoryFile
    }

    # 8. Move handoffs
    $archivedHandoffs = @()
    if ($handoffFiles.Count -gt 0) {
        $archiveHandoffsDir = Join-Path $archiveDir "handoffs"
        New-Item -ItemType Directory -Path $archiveHandoffsDir -Force | Out-Null
        foreach ($file in $handoffFiles) {
            Move-Item -LiteralPath $file.FullName -Destination $archiveHandoffsDir -Force
            $archivedHandoffs += $file.Name
        }
    }

    # 9. Move phases
    $archivedPhases = @()
    if ($phasesToArchive.Count -gt 0) {
        $archivePhasesDir = Join-Path $archiveDir "phases"
        New-Item -ItemType Directory -Path $archivePhasesDir -Force | Out-Null
        foreach ($phase in $phasesToArchive) {
            Move-Item -LiteralPath $phase.Path -Destination $archivePhasesDir -Force
            $archivedPhases += $phase.Name
        }
    }

    # 10. Move/archive log file if -ResetBudget is requested
    $archivedPipelineLog = $false
    if ($ResetBudget -and $logExists) {
        Move-Item -LiteralPath $LogFile -Destination $archiveDir -Force
        $archivedPipelineLog = $true
    }

    # 11. Write manifest.json
    $manifestFile = Join-Path $archiveDir "manifest.json"
    $manifestObj = [ordered]@{
        timestamp = $timestamp
        task_id = $TaskId
        to_phase = $ToPhase
        reset_budget = [bool]$ResetBudget
        archived_handoffs = [string[]]$archivedHandoffs
        archived_phases = [string[]]$archivedPhases
        archived_pipeline_log = [bool]$archivedPipelineLog
    }
    $manifestObj | ConvertTo-Json -Depth 12 | Out-File -LiteralPath $manifestFile -Encoding UTF8

    # 12. Report worktree status (preserving it)
    $worktreePath = Resolve-ImplementationWorktreePath -TaskId $TaskId -WorkspacesDir $WorkspacesDir
    $worktreeDetected = Test-Path -LiteralPath $worktreePath

    # 13. Print summary
    if (-not $Quiet) {
        Write-Host "`n[REWIND] Task $TaskId successfully rewound to $ToPhase." -ForegroundColor Green
        Write-Host "[REWIND] Archived files moved to: $archiveDir" -ForegroundColor Gray
        if ($archivedHandoffs.Count -gt 0) {
            Write-Host "  - Handoffs: $($archivedHandoffs -join ', ')" -ForegroundColor Gray
        }
        if ($archivedPhases.Count -gt 0) {
            Write-Host "  - Phases: $($archivedPhases -join ', ')" -ForegroundColor Gray
        }
        if ($archivedPipelineLog) {
            Write-Host "  - Budget Log: Reset (archived)" -ForegroundColor Gray
        } else {
            Write-Host "  - Budget Log: Preserved" -ForegroundColor Gray
        }
        if ($worktreeDetected) {
            Write-Host "  - Worktree: Preserved at $worktreePath" -ForegroundColor Yellow
        }
        Write-Host "`n[REWIND] Next suggested command to start grooming:" -ForegroundColor Green
        Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .crucible/powershell/factory.ps1 -Init -TaskId $TaskId" -ForegroundColor Yellow
    }
}
