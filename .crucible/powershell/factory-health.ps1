# Factory Health/Cleanup Script
# Extracted from factory.ps1 for {task_id}
param (
    [Parameter(Mandatory=$false)][switch]$Health,
    [Parameter(Mandatory=$false)][switch]$Cleanup,
    [Parameter(Mandatory=$false)][switch]$Force,
    [Parameter(Mandatory=$false)][switch]$Quiet,
    [Parameter(Mandatory=$false)][string]$TaskId = "",
    # Absolute path to the project root (the directory containing .crucible/).
    # Defaults to the current working directory.
    [Parameter(Mandatory=$false)][string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"
$factoryLibPath = Join-Path $PSScriptRoot "factory-lib.ps1"
. $factoryLibPath
# Anchor paths to the project root (where .crucible/ lives).
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $REPO_ROOT = (Get-Location).Path
} else {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) {
        Write-Host ("Error: -ProjectRoot path does not exist: " + $ProjectRoot) -ForegroundColor Red
        exit 1
    }
    $REPO_ROOT = (Resolve-Path -LiteralPath $ProjectRoot).Path
}
Push-Location $REPO_ROOT

function Write-Quiet {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$ForegroundColor = "White"
    )
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
}

try {
    if ($Health -or $Cleanup) {
        Write-Quiet ' '
        if ($Cleanup) {
            if ($Force) {
                Write-Quiet '[CLEANUP] Factory Auto-Cleanup (Executing)' -ForegroundColor Cyan
            } else {
                Write-Quiet '[CLEANUP] Factory Auto-Cleanup (Dry Run)' -ForegroundColor Cyan
            }
        } else {
            Write-Quiet '[HEALTH] Factory Health Report' -ForegroundColor Cyan
        }
        Write-Quiet '--------------------------------------------------'
        $issueCount = 0
    
        # Check 1: Orphaned Git Worktrees
        Write-Quiet 'Checking for orphaned worktrees...' -ForegroundColor Gray
        $worktrees = @(git worktree list --porcelain | Where-Object { $_ -match '^worktree ' } | ForEach-Object { $_ -replace '^worktree ', '' })
        $orphanedWorktrees = @()
        $backlogPath = ".crucible/backlog/BACKLOG.md"
        $backlogContent = ""
        if (Test-Path $backlogPath) { $backlogContent = Get-Content $backlogPath -Raw -Encoding UTF8 }
    
        foreach ($wt in $worktrees) {
            if ($wt -match 'architect-([A-Z0-9\-]+)$') {
                $taskId = $matches[1]
                $pattern = '\|\s*' + $taskId + '\s*\|.*\|\s*(Ready|In Progress|Planning|Draft|Ready for Review|Ready for Deploy)\s*\|'
                $pendingGateFile = Join-Path ".crucible/session/global/gate_decisions" "gate_decision_$taskId`_pending.json"
                if ($backlogContent -notmatch $pattern -and -not (Test-Path $pendingGateFile)) {
                    $orphanedWorktrees += $wt
                }
            }
        }
    
        $wtColor = "White"
        if ($orphanedWorktrees.Count -gt 0) { $wtColor = "Yellow" }
        $wtMsg = "Orphaned Worktrees: " + $orphanedWorktrees.Count
        Write-Quiet $wtMsg -ForegroundColor $wtColor
        if ($orphanedWorktrees.Count -eq 0) {
            Write-Quiet "  None." -ForegroundColor Gray
        } else {
            $orphanedWorktrees | ForEach-Object { Write-Quiet ("  - " + $_ + " - task not active in backlog") -ForegroundColor Yellow }
            $issueCount += $orphanedWorktrees.Count
        }
    
        # Check 2: Unresolved Blocked Tasks
        Write-Quiet ' '
        Write-Quiet 'Checking for unresolved blocked tasks...' -ForegroundColor Gray
        $blockedTasks = @()
        if (Test-Path ".crucible/backlog/blocked") {
            $blockedTasks = @(Get-ChildItem -Path ".crucible/backlog/blocked" -Filter "*.json" | Where-Object { $_.PSIsContainer -eq $false })
        }
        $btColor = "White"
        if ($blockedTasks.Count -gt 0) { $btColor = "Yellow" }
        $btMsg = "Unresolved Blocked Tasks: " + $blockedTasks.Count
        Write-Quiet $btMsg -ForegroundColor $btColor
        if ($blockedTasks.Count -eq 0) {
            Write-Quiet "  None." -ForegroundColor Gray
        } else {
            $blockedTasks | ForEach-Object { Write-Quiet ("  - " + $_.Name) -ForegroundColor Yellow }
            $issueCount += $blockedTasks.Count
        }
    
        # Check 3: Stale Handoff Files
        Write-Quiet ' '
        Write-Quiet 'Checking for stale handoff files over 24h...' -ForegroundColor Gray
        $cutoff = (Get-Date).AddHours(-24)
        $staleHandoffs = @()
        if (Test-Path ".crucible/session/handoffs") {
            $staleHandoffs = @(Get-ChildItem -Path ".crucible/session/handoffs" -Filter "*.json" | Where-Object { $_.LastWriteTime -lt $cutoff })
        }
        $shColor = "White"
        if ($staleHandoffs.Count -gt 0) { $shColor = "Yellow" }
        $shMsg = "Stale Handoff Files over 24h: " + $staleHandoffs.Count
        Write-Quiet $shMsg -ForegroundColor $shColor
        if ($staleHandoffs.Count -eq 0) {
            Write-Quiet "  None." -ForegroundColor Gray
        } else {
            $staleHandoffs | ForEach-Object { 
                $age = [math]::Round(((Get-Date) - $_.LastWriteTime).TotalHours)
                Write-Quiet ("  - " + $_.Name + " - age: " + $age + "h") -ForegroundColor Yellow 
            }
            $issueCount += $staleHandoffs.Count
        }
    
        # Check 4: Stale Session Scratchpads
        Write-Quiet ' '
        Write-Quiet 'Checking for stale session scratchpads...' -ForegroundColor Gray
        $staleScratchpads = @()
        $staleTaskDirs = @()
        
        # 4a. Legacy role-scoped paths
        foreach ($specialist in "groomer", "architect", "reviewer", "operator", "researcher") {
            $taskPath = ".crucible/session/" + $specialist + "/task.md"
            if (Test-Path $taskPath) {
                $staleScratchpads += $taskPath
            }
        }
    
        # 4b. Task-scoped paths (flag if task is completed/resolved/blocked)
        if (Test-Path ".crucible/session") {
            $taskDirs = @(Get-ChildItem -Path ".crucible/session" -Directory | Where-Object { $_.Name -match '^[FBC]-[0-9]+$' })
            foreach ($td in $taskDirs) {
                $taskId = $td.Name
                $pattern = '\|\s*' + $taskId + '\s*\|.*\|\s*(Ready|In Progress|Planning|Draft|Ready for Review|Ready for Deploy)\s*\|'
                $pendingGateFile = Join-Path ".crucible/session/global/gate_decisions" "gate_decision_$taskId`_pending.json"
                if ($backlogContent -notmatch $pattern -and -not (Test-Path $pendingGateFile)) {
                    # Task is not active, any task.md inside is stale
                    $staleTaskDirs += $td.FullName
                    $taskFiles = @(Get-ChildItem -Path $td.FullName -Filter "task.md" -Recurse)
                    foreach ($tf in $taskFiles) {
                        $staleScratchpads += $tf.FullName
                    }
                }
            }
        }
    
        $ssColor = "White"
        if ($staleScratchpads.Count -gt 0) { $ssColor = "Yellow" }
        $ssMsg = "Stale Session Scratchpads: " + $staleScratchpads.Count
        Write-Quiet $ssMsg -ForegroundColor $ssColor
        if ($staleScratchpads.Count -eq 0) {
            Write-Quiet "  None." -ForegroundColor Gray
        } else {
            $staleScratchpads | ForEach-Object { Write-Quiet ("  - " + $_) -ForegroundColor Yellow }
            $issueCount += $staleScratchpads.Count
        }
    
        # Check 5: Stale Locks
        Write-Quiet ' '
        Write-Quiet 'Checking for stale locks over 10m...' -ForegroundColor Gray
        $lockCutoff = (Get-Date).AddMinutes(-10)
        $staleLocks = @()
        if (Test-Path ".crucible/locks") { 
            $staleLocks = @(Get-ChildItem -Path ".crucible/locks" | Where-Object { $_.LastWriteTime -lt $lockCutoff })
        }
        $slColor = "White"
        if ($staleLocks.Count -gt 0) { $slColor = "Yellow" }
        $slMsg = "Stale Locks over 10m: " + $staleLocks.Count
        Write-Quiet $slMsg -ForegroundColor $slColor
        if ($staleLocks.Count -eq 0) {
            Write-Quiet "  None." -ForegroundColor Gray
        } else {
            $staleLocks | ForEach-Object { Write-Quiet ("  - " + $_.Name) -ForegroundColor Yellow }
            $issueCount += $staleLocks.Count
        }
    
        # Check 6: Architect Hook Configuration ({task_id})
        Write-Quiet ' '
        Write-Quiet 'Checking for architect hook configuration...' -ForegroundColor Gray
        $misconfiguredWorktrees = @()
        $archWtPaths = @(git worktree list --porcelain | Where-Object { $_ -match '^worktree .*architect-' } | ForEach-Object { $_ -replace '^worktree ', '' })
        
        foreach ($wt in $archWtPaths) {
            $hooksPath = git -C $wt config core.hooksPath
            if ($hooksPath -ne "../../scripts/hooks/architect") {
                $misconfiguredWorktrees += $wt
            }
        }
    
        $mcColor = "White"
        if ($misconfiguredWorktrees.Count -gt 0) { $mcColor = "Yellow" }
        $mcMsg = "Misconfigured Architect Worktrees (hooksPath): " + $misconfiguredWorktrees.Count
        Write-Quiet $mcMsg -ForegroundColor $mcColor
        if ($misconfiguredWorktrees.Count -eq 0) {
            Write-Quiet "  None." -ForegroundColor Gray
        } else {
            $misconfiguredWorktrees | ForEach-Object { 
                $current = git -C $_ config core.hooksPath
                Write-Quiet ("  - " + $_ + " - core.hooksPath: " + $current) -ForegroundColor Yellow 
            }
            $issueCount += $misconfiguredWorktrees.Count
        }
    
        # Check 7: Orphaned Pending Gate Files ({task_id})
        Write-Quiet ' '
        Write-Quiet 'Checking for orphaned pending gate files...' -ForegroundColor Gray
        $orphanedGateFiles = @()
        if (Test-Path ".crucible/session/global/gate_decisions") {
            # Check both new task-scoped and legacy template file
            $pendingFiles = @(Get-ChildItem -Path ".crucible/session/global/gate_decisions" -Filter "gate_decision_*_pending.json")
            $legacyTemplate = Join-Path ".crucible/session/global/gate_decisions" "gate_decision_template.json"
            if (Test-Path $legacyTemplate) { $pendingFiles += Get-Item $legacyTemplate }
    
            foreach ($pf in $pendingFiles) {
                if ($pf.Name -eq "gate_decision_template.json") {
                    $orphanedGateFiles += $pf
                } elseif ($pf.Name -match 'gate_decision_([A-Z0-9\-]+)_pending\.json') {
                    $taskId = $matches[1]
                    $pattern = '\|\s*' + $taskId + '\s*\|.*\|\s*(Ready|In Progress|Planning|Draft|Ready for Review|Production|Resolved)\s*\|'
                    if ($backlogContent -notmatch $pattern) {
                        $orphanedGateFiles += $pf
                    }
                } else {
                    # malformed pending file
                    $orphanedGateFiles += $pf
                }
            }
        }
        
        $ogfColor = "White"
        if ($orphanedGateFiles.Count -gt 0) { $ogfColor = "Yellow" }
        $ogfMsg = "Orphaned Pending Gate Files: " + $orphanedGateFiles.Count
        Write-Quiet $ogfMsg -ForegroundColor $ogfColor
        if ($orphanedGateFiles.Count -eq 0) {
            Write-Quiet "  None." -ForegroundColor Gray
        } else {
            $orphanedGateFiles | ForEach-Object { Write-Quiet ("  - " + $_.Name + " - task not active in backlog") -ForegroundColor Yellow }
            $issueCount += $orphanedGateFiles.Count
        }
    
        # Check 8: Scratchpad Size Policy
        # task.md > 500 lines or review_report.md > 300 lines risk context window saturation.
        Write-Quiet ' '
        Write-Quiet 'Checking scratchpad sizes...' -ForegroundColor Gray
        $oversizedScratchpads = @()
        $sessionRoot = ".crucible/session"
        if (Test-Path $sessionRoot) {
            Get-ChildItem -Path $sessionRoot -Recurse -Filter "task.md" | ForEach-Object {
                $lineCount = (Get-Content $_.FullName -Encoding UTF8 | Measure-Object -Line).Lines
                if ($lineCount -gt 500) {
                    $oversizedScratchpads += [PSCustomObject]@{ Path = $_.FullName; Lines = $lineCount; Limit = 500 }
                }
            }
            Get-ChildItem -Path $sessionRoot -Recurse -Filter "review_report.md" | ForEach-Object {
                $lineCount = (Get-Content $_.FullName -Encoding UTF8 | Measure-Object -Line).Lines
                if ($lineCount -gt 300) {
                    $oversizedScratchpads += [PSCustomObject]@{ Path = $_.FullName; Lines = $lineCount; Limit = 300 }
                }
            }
        }
        $spColor = "White"
        if ($oversizedScratchpads.Count -gt 0) { $spColor = "Yellow" }
        Write-Quiet ("Oversized Scratchpads: " + $oversizedScratchpads.Count) -ForegroundColor $spColor
        if ($oversizedScratchpads.Count -eq 0) {
            Write-Quiet "  None." -ForegroundColor Gray
        } else {
            $oversizedScratchpads | ForEach-Object {
                Write-Quiet ("  - " + $_.Path + " (" + $_.Lines + " lines, limit " + $_.Limit + ") - specialist must compact") -ForegroundColor Yellow
            }
            $issueCount += $oversizedScratchpads.Count
        }
    
        if ($Cleanup) {
            Write-Quiet ' '
            Write-Quiet '--- Cleanup Operations ---' -ForegroundColor Cyan
            $archiveTs = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
            $staleTaskArchiveRoot = ".crucible/session/archived/stale-task-sessions"
            $handoffArchiveDir = ".crucible/session/handoffs/archived"
            $blockedArchiveDir = ".crucible/backlog/blocked/archived"
            if ($Force) {
                if (-not (Test-Path $staleTaskArchiveRoot)) { New-Item -ItemType Directory -Path $staleTaskArchiveRoot -Force | Out-Null }
                if (-not (Test-Path $handoffArchiveDir)) { New-Item -ItemType Directory -Path $handoffArchiveDir -Force | Out-Null }
                if (-not (Test-Path $blockedArchiveDir)) { New-Item -ItemType Directory -Path $blockedArchiveDir -Force | Out-Null }
            }
    
            # 0. Blocked task records
            if ($blockedTasks.Count -gt 0) {
                foreach ($bt in $blockedTasks) {
                    if ($Force) {
                        $blockedArchivePath = Join-Path $blockedArchiveDir $bt.Name
                        if (Test-Path $blockedArchivePath) {
                            $base = [System.IO.Path]::GetFileNameWithoutExtension($bt.Name)
                            $ext = [System.IO.Path]::GetExtension($bt.Name)
                            $blockedArchivePath = Join-Path $blockedArchiveDir ($base + "-" + $archiveTs + $ext)
                        }
                        Write-Quiet ("Archiving blocked task record: " + $bt.FullName + " -> " + $blockedArchivePath) -ForegroundColor Yellow
                        Move-Item -Path $bt.FullName -Destination $blockedArchivePath -Force
                    } else {
                        Write-Quiet ("Would archive blocked task record: " + $bt.FullName + " -> " + (Join-Path $blockedArchiveDir $bt.Name)) -ForegroundColor Gray
                    }
                }
            }
    
            # 1. Worktrees
            if ($orphanedWorktrees.Count -gt 0) {
                foreach ($wt in $orphanedWorktrees) {
                    if ($Force) {
                        Write-Quiet ("Removing worktree: " + $wt) -ForegroundColor Yellow
                        git worktree remove --force $wt
                    } else {
                        Write-Quiet ("Would remove worktree: " + $wt) -ForegroundColor Gray
                    }
                }
            }
            
            # 2. Handoffs
            if ($staleHandoffs.Count -gt 0) {
                foreach ($sh in $staleHandoffs) {
                    if ($Force) {
                        $handoffArchivePath = Join-Path $handoffArchiveDir $sh.Name
                        if (Test-Path $handoffArchivePath) {
                            $base = [System.IO.Path]::GetFileNameWithoutExtension($sh.Name)
                            $ext = [System.IO.Path]::GetExtension($sh.Name)
                            $handoffArchivePath = Join-Path $handoffArchiveDir ($base + "-" + $archiveTs + $ext)
                        }
                        Write-Quiet ("Archiving stale handoff: " + $sh.FullName + " -> " + $handoffArchivePath) -ForegroundColor Yellow
                        Move-Item -Path $sh.FullName -Destination $handoffArchivePath -Force
                    } else {
                        Write-Quiet ("Would archive stale handoff: " + $sh.FullName + " -> " + (Join-Path $handoffArchiveDir $sh.Name)) -ForegroundColor Gray
                    }
                }
            }
            
            # 3. Scratchpads (legacy)
            foreach ($specialist in "groomer", "architect", "reviewer", "operator", "researcher") {
                $taskPath = ".crucible/session/" + $specialist + "/task.md"
                if (Test-Path $taskPath) {
                    if ($Force) {
                        Write-Quiet ("Removing legacy scratchpad: " + $taskPath) -ForegroundColor Yellow
                        Remove-Item -Path $taskPath -Force
                    } else {
                        Write-Quiet ("Would remove legacy scratchpad: " + $taskPath) -ForegroundColor Gray
                    }
                }
            }
    
            # 4. Task-scoped dirs
            if ($staleTaskDirs.Count -gt 0) {
                foreach ($td in $staleTaskDirs) {
                    if ($Force) {
                        $taskDirName = Split-Path -Path $td -Leaf
                        $archiveTaskDir = Join-Path $staleTaskArchiveRoot ($taskDirName + "-" + $archiveTs)
                        Write-Quiet ("Archiving stale task dir: " + $td + " -> " + $archiveTaskDir) -ForegroundColor Yellow
                        Move-Item -Path $td -Destination $archiveTaskDir -Force
                    } else {
                        $taskDirName = Split-Path -Path $td -Leaf
                        Write-Quiet ("Would archive stale task dir: " + $td + " -> " + (Join-Path $staleTaskArchiveRoot ($taskDirName + "-<timestamp>"))) -ForegroundColor Gray
                    }
                }
            }
    
            # 4c. Role-scoped prompt.md (P-1)
            foreach ($specialist in "groomer", "architect", "reviewer", "operator", "researcher") {
                $pPath = ".crucible/session/" + $specialist + "/prompt.md"
                if (Test-Path $pPath) {
                    if ($Force) {
                        Write-Quiet ("Removing role-scoped prompt: " + $pPath) -ForegroundColor Yellow
                        Remove-Item -Path $pPath -Force
                    } else {
                        Write-Quiet ("Would remove role-scoped prompt: " + $pPath) -ForegroundColor Gray
                    }
                }
            }
    
            # 5. Locks
            if ($staleLocks.Count -gt 0) {
                foreach ($sl in $staleLocks) {
                    if ($Force) {
                        Write-Quiet ("Removing stale lock: " + $sl.FullName) -ForegroundColor Yellow
                        Remove-Item -Path $sl.FullName -Force
                    } else {
                        Write-Quiet ("Would remove stale lock: " + $sl.FullName) -ForegroundColor Gray
                    }
                }
            }
    
            # 6. Orphaned Pending Gate Files
            if ($orphanedGateFiles.Count -gt 0) {
                foreach ($ogf in $orphanedGateFiles) {
                    if ($Force) {
                        Write-Quiet ("Removing orphaned pending gate file: " + $ogf.FullName) -ForegroundColor Yellow
                        Remove-Item -Path $ogf.FullName -Force
                    } else {
                        Write-Quiet ("Would remove orphaned pending gate file: " + $ogf.FullName) -ForegroundColor Gray
                    }
                }
            }
            
            Write-Quiet ' '
            Write-Quiet '--------------------------------------------------'
            if ($Force) {
                Write-Quiet '[CLEANUP] Factory Auto-Cleanup complete.' -ForegroundColor Green
            } else {
                Write-Quiet '[CLEANUP] Dry run complete. Use -Force to execute.' -ForegroundColor Yellow
            }
        } else {
            Write-Quiet ' '
            Write-Quiet '--------------------------------------------------'
            if ($issueCount -eq 0) {
                Write-Quiet "[HEALTH] All clear. No orphaned artifacts detected." -ForegroundColor Green
            } else {
                $finalMsg = "[HEALTH] Action needed for " + $issueCount + " item or items. Review above and clean up manually."
                Write-Quiet $finalMsg -ForegroundColor Yellow
            }
        }
        exit 0
    }
} finally {
    Pop-Location
}

