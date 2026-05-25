# factory-status.ps1
# CLI Dashboard for monitoring the Dev Factory pipeline in real-time.
# Usage: .\.crucible\\scripts\factory-status.ps1 [-Summary] [-Tasks] [-ExportJSON]

param (
    [Parameter(Mandatory=$false)]
    [switch]$Summary,

    [Parameter(Mandatory=$false)]
    [switch]$Tasks,

    [Parameter(Mandatory=$false)]
    [switch]$ExportJSON
)

$ErrorActionPreference = "Stop"

$helpersPath = Join-Path $PSScriptRoot "lib/config-helpers.ps1"
if (-not (Test-Path -LiteralPath $helpersPath)) {
    throw "Required helper script not found at $helpersPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $helpersPath
$sessionDir = Get-ConfiguredPath -Key "session"
$backlogDir = Get-ConfiguredPath -Key "backlog"

$STATE_FILE = Join-Path $sessionDir "global/session_state.json"
$BACKLOG_FILE = Join-Path $backlogDir "BACKLOG.md"
$LOG_DIR = $sessionDir
$HANDOFF_DIR = Join-Path $sessionDir "handoffs"
$GLOBAL_CB_HISTORY_FILE = Join-Path $sessionDir "global/circuit_breakers.jsonl"
$RECENT_CB_WINDOW_HOURS = 72

# --- 1. Load Data ---

if (-not (Test-Path $STATE_FILE)) {
    Write-Error "Session state file not found: $STATE_FILE"
    exit 1
}
$sessionState = Get-Content $STATE_FILE | ConvertFrom-Json

if (-not (Test-Path $BACKLOG_FILE)) {
    Write-Error "Backlog file not found: $BACKLOG_FILE"
    exit 1
}
$backlogLines = Get-Content $BACKLOG_FILE

# --- 2. Parse Backlog Metadata ---
$taskMeta = @{}
foreach ($line in $backlogLines) {
    # Match: | ID | [Title](path) | Category | Status | Specialist | Priority |
    if ($line -match '^\|\s+([F|C|B]-\d+)\s+\|\s+\[(.*?)\]\(.*?\)\s+\|\s+(.*?)\s+\|\s+(.*?)\s+\|\s+(.*?)\s+\|\s+(.*?)\s+\|$') {
        $id = $Matches[1]
        $title = $Matches[2]
        $category = $Matches[3]
        $status = $Matches[4]
        $specialist = $Matches[5]
        $priority = $Matches[6]
        
        $taskMeta[$id] = @{
            Title      = $title
            Category   = $category
            Status     = $status
            Specialist = $specialist
            Priority   = $priority
        }
    }
}

# --- 3. Aggregate In-Flight Tasks ---
$allTasks = @()

# Tasks from session_state (Real-time source)
foreach ($taskId in $sessionState.tasks.PSObject.Properties.Name) {
    $taskState = $sessionState.tasks.$taskId
    $meta = $taskMeta[$taskId]
    
    # Determine active specialist
    $activeSpec = $taskState.active_specialist
    $isFinished = $true
    
    # Check if any specialist is still active
    $currentSpec = "N/A"
    $latestTs = [DateTime]::MinValue
    
    foreach ($specName in $taskState.specialists.PSObject.Properties.Name) {
        $spec = $taskState.specialists.$specName
        $specStatus = $spec.status
        
        # If any spec is not idle/Complete/deployed/Resolved, it's in-flight
        if ($specStatus -and $specStatus -notmatch "idle|Complete|deployed|Resolved") {
            $isFinished = $false
        }
        
        # Track latest specialist by timestamp
        if ($spec.timestamp) {
            $ts = [DateTime]::Parse($spec.timestamp)
            if ($ts -gt $latestTs) {
                $latestTs = $ts
                $currentSpec = $specName
            }
        }
    }
    
    if (-not $activeSpec -and -not $isFinished) {
        $activeSpec = $currentSpec
    }

    # If it's finished and not in active backlog, skip unless we want all tasks
    if ($isFinished -and -not $meta -and -not $Tasks) {
        continue
    }

    # Calculate duration for in-flight tasks
    $duration = "-"
    if (-not $isFinished) {
        $logPath = "$LOG_DIR/$taskId/pipeline.log.jsonl"
        if (Test-Path $logPath) {
            $logLines = Get-Content $logPath -ErrorAction SilentlyContinue
            if ($logLines) {
                $logs = @()
                foreach ($line in $logLines) {
                    $cleaned = $line -replace "^$([char]0xFEFF)", ""
                    $parsed = $cleaned | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($parsed) { $logs += $parsed }
                }
                if ($logs) {
                    $lastStart = $logs | Where-Object { $_.event -eq "session_start" } | Select-Object -Last 1
                    if ($lastStart) {
                        $startTime = [DateTime]::Parse($lastStart.timestamp)
                        $elapsed = [DateTime]::UtcNow - $startTime.ToUniversalTime()
                        $duration = "$([Math]::Floor($elapsed.TotalHours))h $($elapsed.Minutes)m"
                    }
                }
            }
        }
    }

    $affinity = ""
    if ($taskState.specialists.groomer -and $taskState.specialists.groomer.file_affinity) {
        $affinity = $taskState.specialists.groomer.file_affinity -join ", "
    }
    
    $dependencies = ""
    $featureFiles = @(Get-ChildItem -Path $backlogDir -Recurse -Filter ($taskId + "_*.md") -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "active" })
    if ($featureFiles.Count -gt 0) {
        $specContent = Get-Content $featureFiles[0].FullName
        $inDepends = $false
        $deps = @()
        foreach ($line in $specContent) {
            if ($line -match "^depends_on:\s*\[(.*?)\]") {
                $depsStr = $Matches[1] -replace '["''\s]', ''
                if ($depsStr) { $deps += $depsStr -split ',' }
                break
            } elseif ($line -match "^depends_on:") {
                $inDepends = $true
            } elseif ($inDepends -and $line -match "^---\s*$") {
                break
            } elseif ($inDepends -and $line -match "^\s*-\s*([F|C|B]-\d+)") {
                $deps += $Matches[1]
            } elseif ($inDepends -and $line -notmatch "^\s*-" -and $line.Trim() -ne "") {
                $inDepends = $false
            }
        }
        if ($deps.Count -gt 0) {
            $dependencies = $deps -join ", "
        }
    }

    # Is it blocked?
    $isBlocked = $false
    if ($taskState.status -eq "blocked") { 
        $isBlocked = $true 
        $isFinished = $false
    }

    $statusStr = if ($meta.Status) { $meta.Status } elseif ($isFinished) { "Finished" } else { "In Progress" }
    if ($isBlocked) { $statusStr = "Blocked" }

    $allTasks += [PSCustomObject]@{
        Task           = $taskId
        Title          = if ($meta.Title) { $meta.Title } else { "Unknown" }
        Status         = $statusStr
        Dependencies   = $dependencies
        Specialist     = if ($activeSpec) { $activeSpec } elseif ($isFinished) { "none" } else { "N/A" }
        "File Affinity"= $affinity
        Duration       = $duration
        Blocker        = if ($isBlocked) { "YES" } else { "none" }
    }
}

# --- 4. Summary Stats ---
$totalManaged = ($sessionState.tasks.PSObject.Properties.Name).Count
$inFlight = @($allTasks | Where-Object { $_.Status -match "In Progress|Ready for Review|Ready for Deploy" }).Count
$blocked = @($allTasks | Where-Object { $_.Blocker -eq "YES" }).Count
$ready = @($taskMeta.Values | Where-Object { $_.Status -eq "Ready" }).Count

# Circuit Breakers (canonical history file + active/recent filtering)
$blockedTaskIds = @(
    $sessionState.tasks.PSObject.Properties.Name | Where-Object {
        $task = $sessionState.tasks.$_
        $null -ne $task -and $task.status -eq "blocked"
    }
)

$cbEventsAll = @()
if (Test-Path $GLOBAL_CB_HISTORY_FILE) {
    $cbEventsAll = @(
        Get-Content -Path $GLOBAL_CB_HISTORY_FILE -ErrorAction SilentlyContinue |
            ForEach-Object { $_ -replace "^$([char]0xFEFF)", "" } |
            ConvertFrom-Json -ErrorAction SilentlyContinue |
            Where-Object { $_.event -eq "circuit_breaker" -and $_.timestamp }
    )
}
if ($cbEventsAll.Count -eq 0) {
    foreach ($taskId in $sessionState.tasks.PSObject.Properties.Name) {
        $taskLog = Join-Path $LOG_DIR ($taskId + "/pipeline.log.jsonl")
        if (-not (Test-Path $taskLog)) { continue }
        $taskEvents = @(
            Get-Content -Path $taskLog -ErrorAction SilentlyContinue |
                ForEach-Object { $_ -replace "^$([char]0xFEFF)", "" } |
                ConvertFrom-Json -ErrorAction SilentlyContinue |
                Where-Object { $_.event -eq "circuit_breaker" -and $_.timestamp }
        )
        if ($taskEvents.Count -gt 0) {
            $cbEventsAll += $taskEvents
        }
    }
}

$cbRecentCutoff = (Get-Date).ToUniversalTime().AddHours(-1 * $RECENT_CB_WINDOW_HOURS)
$cbEvents = @(
    $cbEventsAll | Where-Object {
        $eventTs = [DateTime]::Parse($_.timestamp)
        ($eventTs -ge $cbRecentCutoff) -or ($blockedTaskIds -contains $_.task_id)
    } | Sort-Object { [DateTime]::Parse($_.timestamp) }
)

# Merge Conflicts (Last 7 Days)
$cutoff = (Get-Date).AddDays(-7)
$conflictEvents = $cbEvents | Where-Object { $_.outcome -match "conflict" -and [DateTime]::Parse($_.timestamp) -gt $cutoff }
$conflictRate = 0
if ($totalManaged -gt 0) {
    $conflictRate = ($conflictEvents.Count / $totalManaged) * 100
}

# --- 5. Display ---

if ($ExportJSON) {
    $report = [PSCustomObject]@{
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        tasks = $allTasks
        stats = @{
            total = $totalManaged
            in_flight = $inFlight
            blocked = $blocked
            ready = $ready
            conflict_rate = $conflictRate
            circuit_breakers_recent_or_unresolved = $cbEvents.Count
            circuit_breakers_total = $cbEventsAll.Count
        }
    }
    $report | ConvertTo-Json -Depth 10
    exit 0
}

if (-not $Summary -or $Tasks) {
    Write-Host "`nTask Dashboard" -ForegroundColor Cyan
    Write-Host "==============" -ForegroundColor Cyan
    $allTasks | Format-Table -Property Task, Title, Status, Dependencies, Specialist, "File Affinity", Duration, Blocker -AutoSize
}

if (-not $Tasks -or $Summary) {
    Write-Host "`nPipeline Health" -ForegroundColor Cyan
    Write-Host "===============" -ForegroundColor Cyan
    Write-Host "Total Managed Tasks: $totalManaged"
    Write-Host "In-Flight:           $inFlight"
    Write-Host "Blocked:             $blocked"
    Write-Host "Ready in Backlog:    $ready"

    Write-Host "`nMerge Conflicts (Last 7 Days)" -ForegroundColor Cyan
    Write-Host "=============================" -ForegroundColor Cyan
    Write-Host "Total Conflicts:     $($conflictEvents.Count)"
    Write-Host "Conflict Rate:       $([Math]::Round($conflictRate, 1))%"

    Write-Host "`nCircuit Breaker Events (Recent/Unresolved)" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    if ($cbEvents.Count -eq 0) {
        Write-Host ("No circuit breaker events in the last " + $RECENT_CB_WINDOW_HOURS + "h and no unresolved blocked tasks.") -ForegroundColor Gray
    } else {
        $cbEvents | Select-Object -Last 5 | ForEach-Object {
            $ts = [DateTime]::Parse($_.timestamp).ToString("MM-dd HH:mm")
            Write-Host "[$ts] $($_.task_id): $($_.outcome) - $($_.notes)" -ForegroundColor Yellow
        }
    }
}
Write-Host "`n"
