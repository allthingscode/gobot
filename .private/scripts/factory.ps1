# Factory Orchestrator Script
# Validates handoff.json, routes pipeline in code, assembles next prompt from template.
# Usage: .\.private\factory.ps1 [-Target agent|gemini|claude] [-Init]

param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("agent", "gemini", "claude")]
    [string]$Target = "agent",

    [Parameter(Mandatory=$false)]
    [switch]$Init,

    [Parameter(Mandatory=$false)]
    [string]$Resume,

    [Parameter(Mandatory=$false)]
    [switch]$Health,

    [Parameter(Mandatory=$false)]
    [string]$TaskId = ""
)

$ErrorActionPreference = "Stop"

$HANDOFF_DIR = ".private/session/handoffs"
$PROMPT_LIB = ".private/prompt-library"

# When $TaskId is provided, log to per-task file; otherwise global.
if (-not [string]::IsNullOrEmpty($TaskId)) {
    $LOG_FILE = ".private/session/" + $TaskId + "/pipeline.log.jsonl"
    # Ensure the directory exists
    $logDir = Split-Path $LOG_FILE
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
} else {
    $LOG_FILE = ".private/session/global/pipeline.log.jsonl"
}

$budgetCeilings = @{ low = 6; medium = 10; high = 16 }

if ($Health) {
    Write-Host ' '
    Write-Host '[HEALTH] Factory Health Report' -ForegroundColor Cyan
    Write-Host '--------------------------------------------------'
    $issueCount = 0

    # Check 1: Orphaned Git Worktrees
    Write-Host 'Checking for orphaned worktrees...' -ForegroundColor Gray
    $worktrees = git worktree list --porcelain | Where-Object { $_ -match '^worktree ' } | ForEach-Object { $_ -replace '^worktree ', '' }
    $orphanedWorktrees = @()
    $backlogPath = ".private/backlog/BACKLOG.md"
    $backlogContent = ""
    if (Test-Path $backlogPath) { $backlogContent = Get-Content $backlogPath -Raw }

    foreach ($wt in $worktrees) {
        if ($wt -match 'architect-([A-Z0-9\-]+)$') {
            $taskId = $matches[1]
            $pattern = '\|\s*' + $taskId + '\s*\|.*\|\s*(Ready|In Progress|Planning|Draft|Ready for Review)\s*\|'
            if ($backlogContent -notmatch $pattern) {
                $orphanedWorktrees += $wt
            }
        }
    }

    $wtColor = "White"
    if ($orphanedWorktrees.Count -gt 0) { $wtColor = "Yellow" }
    $wtMsg = "Orphaned Worktrees: " + $orphanedWorktrees.Count
    Write-Host $wtMsg -ForegroundColor $wtColor
    if ($orphanedWorktrees.Count -eq 0) {
        Write-Host "  None." -ForegroundColor Gray
    } else {
        $orphanedWorktrees | ForEach-Object { Write-Host ("  - " + $_ + " - task not active in backlog") -ForegroundColor Yellow }
        $issueCount += $orphanedWorktrees.Count
    }

    # Check 2: Unresolved Blocked Tasks
    Write-Host ' '
    Write-Host 'Checking for unresolved blocked tasks...' -ForegroundColor Gray
    $blockedTasks = Get-ChildItem -Path ".private/backlog/blocked" -Filter "*.json" | Where-Object { $_.PSIsContainer -eq $false }
    $btColor = "White"
    if ($blockedTasks.Count -gt 0) { $btColor = "Yellow" }
    $btMsg = "Unresolved Blocked Tasks: " + $blockedTasks.Count
    Write-Host $btMsg -ForegroundColor $btColor
    if ($blockedTasks.Count -eq 0) {
        Write-Host "  None." -ForegroundColor Gray
    } else {
        $blockedTasks | ForEach-Object { Write-Host ("  - " + $_.Name) -ForegroundColor Yellow }
        $issueCount += $blockedTasks.Count
    }

    # Check 3: Stale Handoff Files
    Write-Host ' '
    Write-Host 'Checking for stale handoff files over 24h...' -ForegroundColor Gray
    $cutoff = (Get-Date).AddHours(-24)
    $staleHandoffs = Get-ChildItem -Path ".private/session/handoffs" -Filter "*.json" | Where-Object { $_.LastWriteTime -lt $cutoff }
    $shColor = "White"
    if ($staleHandoffs.Count -gt 0) { $shColor = "Yellow" }
    $shMsg = "Stale Handoff Files over 24h: " + $staleHandoffs.Count
    Write-Host $shMsg -ForegroundColor $shColor
    if ($staleHandoffs.Count -eq 0) {
        Write-Host "  None." -ForegroundColor Gray
    } else {
        $staleHandoffs | ForEach-Object { 
            $age = [math]::Round(((Get-Date) - $_.LastWriteTime).TotalHours)
            Write-Host ("  - " + $_.Name + " - age: " + $age + "h") -ForegroundColor Yellow 
        }
        $issueCount += $staleHandoffs.Count
    }

    # Check 4: Stale Session Scratchpads
    Write-Host ' '
    Write-Host 'Checking for stale session scratchpads...' -ForegroundColor Gray
    $staleScratchpads = @()
    
    # 4a. Legacy role-scoped paths
    foreach ($specialist in "groomer", "architect", "reviewer", "operator", "researcher") {
        $taskPath = ".private/session/" + $specialist + "/task.md"
        if (Test-Path $taskPath) {
            $staleScratchpads += $taskPath
        }
    }

    # 4b. Task-scoped paths (flag if task is completed/resolved/blocked)
    if (Test-Path ".private/session") {
        $taskDirs = Get-ChildItem -Path ".private/session" -Directory | Where-Object { $_.Name -match '^[FBC]-[0-9]+$' }
        foreach ($td in $taskDirs) {
            $taskId = $td.Name
            $pattern = '\|\s*' + $taskId + '\s*\|.*\|\s*(Ready|In Progress|Planning|Draft|Ready for Review)\s*\|'
            if ($backlogContent -notmatch $pattern) {
                # Task is not active, any task.md inside is stale
                $taskFiles = Get-ChildItem -Path $td.FullName -Filter "task.md" -Recurse
                foreach ($tf in $taskFiles) {
                    $staleScratchpads += $tf.FullName
                }
            }
        }
    }

    $ssColor = "White"
    if ($staleScratchpads.Count -gt 0) { $ssColor = "Yellow" }
    $ssMsg = "Stale Session Scratchpads: " + $staleScratchpads.Count
    Write-Host $ssMsg -ForegroundColor $ssColor
    if ($staleScratchpads.Count -eq 0) {
        Write-Host "  None." -ForegroundColor Gray
    } else {
        $staleScratchpads | ForEach-Object { Write-Host ("  - " + $_) -ForegroundColor Yellow }
        $issueCount += $staleScratchpads.Count
    }

    # Check 5: Stale Locks
    Write-Host ' '
    Write-Host 'Checking for stale locks over 10m...' -ForegroundColor Gray
    $lockCutoff = (Get-Date).AddMinutes(-10)
    $staleLocks = @()
    if (Test-Path ".private/locks") { 
        $staleLocks = Get-ChildItem -Path ".private/locks" | Where-Object { $_.LastWriteTime -lt $lockCutoff }
    }
    $slColor = "White"
    if ($staleLocks.Count -gt 0) { $slColor = "Yellow" }
    $slMsg = "Stale Locks over 10m: " + $staleLocks.Count
    Write-Host $slMsg -ForegroundColor $slColor
    if ($staleLocks.Count -eq 0) {
        Write-Host "  None." -ForegroundColor Gray
    } else {
        $staleLocks | ForEach-Object { Write-Host ("  - " + $_.Name) -ForegroundColor Yellow }
        $issueCount += $staleLocks.Count
    }

    Write-Host ' '
    Write-Host '--------------------------------------------------'
    if ($issueCount -eq 0) {
        Write-Host "[HEALTH] All clear. No orphaned artifacts detected." -ForegroundColor Green
    } else {
        $finalMsg = "[HEALTH] Action needed for " + $issueCount + " item or items. Review above and clean up manually."
        Write-Host $finalMsg -ForegroundColor Yellow
    }
    exit 0
}

# --- 0a. Require -TaskId for all pipeline operations ---
if ([string]::IsNullOrEmpty($TaskId)) {
    Write-Host "`n[ERROR] -TaskId is required." -ForegroundColor Red
    Write-Host "Usage: .\.private\factory.ps1 -Init -TaskId F-083" -ForegroundColor Yellow
    Write-Host "       .\.private\factory.ps1 -Health  (no -TaskId needed for health checks)" -ForegroundColor DarkGray
    exit 1
}

# --- 0. Logging Helpers (C-091) ---
function Write-EventLog {
    param(
        [Parameter(Mandatory=$true)][string]$Event,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$Specialist,
        [string]$Outcome = $null,
        [string]$Notes = $null,
        [int]$DurationSeconds = 0,
        [int]$HandoffCount = 0,
        [string]$CycleId = $env:FACTORY_CYCLE_ID,
        [hashtable]$Metrics = $null
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    $eventObj = [ordered]@{
        event = $Event
        task_id = $TaskId
        specialist = $Specialist
        timestamp = $timestamp
    }

    if ($DurationSeconds -gt 0) { $eventObj.duration_seconds = $DurationSeconds }
    if ($HandoffCount -gt 0) { $eventObj.handoff_count = $HandoffCount }
    if (-not [string]::IsNullOrEmpty($Outcome)) { $eventObj.outcome = $Outcome }
    if (-not [string]::IsNullOrEmpty($Notes)) { $eventObj.notes = $Notes }
    if (-not [string]::IsNullOrEmpty($CycleId)) { $eventObj.cycle_id = $CycleId }
    if ($null -ne $Metrics) { $eventObj.metrics = $Metrics }

    $json = $eventObj | ConvertTo-Json -Compress
    $json | Out-File -FilePath $LOG_FILE -Append -Encoding UTF8
}

function Get-LastEntry {
    param([string]$TaskId, [string]$Specialist, [string]$Event)
    if (-not (Test-Path $LOG_FILE)) { return $null }
    
    $lines = Get-Content $LOG_FILE -Tail 50
    for ($i = $lines.Length - 1; $i -ge 0; $i--) {
        try {
            $entry = $lines[$i] | ConvertFrom-Json
            if ($entry.task_id -eq $TaskId -and $entry.specialist -eq $Specialist -and ($null -eq $Event -or $entry.event -eq $Event)) {
                return $entry
            }
        } catch { continue }
    }
    return $null
}

# --- 1. Load latest handoff.json ---
if (-not (Test-Path $HANDOFF_DIR)) {
    Write-Host "Error: Handoff directory not found at $HANDOFF_DIR" -ForegroundColor Red
    exit 1
}

if (-not [string]::IsNullOrEmpty($TaskId)) {
    # Scoped: find the latest handoff for THIS task only
    $latestHandoff = Get-ChildItem -Path $HANDOFF_DIR -Filter ($TaskId + "-*.json") |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latestHandoff) {
        Write-Host ("Error: No handoff found for TaskId: " + $TaskId) -ForegroundColor Red
        exit 1
    }
} else {
    # Unscoped: legacy behavior — pick globally newest handoff
    $latestHandoff = Get-ChildItem -Path $HANDOFF_DIR -Filter "*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

if (-not $latestHandoff) {
    Write-Host "Error: No handoff.json found in $HANDOFF_DIR" -ForegroundColor Red
    exit 1
}

$handoffFile = $latestHandoff.FullName

try {
    $handoffRaw = Get-Content $handoffFile -Raw
    $handoff = $handoffRaw | ConvertFrom-Json
} catch {
    Write-Host "Error: Failed to parse handoff file $handoffFile" -ForegroundColor Red
    Write-Host $_.Exception.Message
    exit 1
}

# --- 1b. Restore or generate cycle_id (C-103) ---
if ($handoff.psobject.Properties["cycle_id"] -and -not [string]::IsNullOrEmpty($handoff.cycle_id)) {
    $env:FACTORY_CYCLE_ID = $handoff.cycle_id
} else {
    $env:FACTORY_CYCLE_ID = [System.Guid]::NewGuid().ToString("N").Substring(0, 8)
}

# --- 1a. Log Session End for Source (C-091) ---
$lastEnd = Get-LastEntry -TaskId $handoff.task_id -Specialist $handoff.source_specialist -Event "session_end"
if (-not $lastEnd -or $lastEnd.handoff_count -lt $handoff.cumulative_handoff_count) {
    $lastStart = Get-LastEntry -TaskId $handoff.task_id -Specialist $handoff.source_specialist -Event "session_start"
    $duration = 0
    if ($lastStart) {
        $startTime = [DateTimeOffset]::Parse($lastStart.timestamp).UtcDateTime
        $duration = [int](([DateTime]::UtcNow - $startTime).TotalSeconds)
    }

    # Build metrics block (C-107)
    $ceiling = $budgetCeilings[$handoff.budget_tier.ToLower()]
    $pctUsed = if ($ceiling -gt 0) { [math]::Min(100, [math]::Round(($handoff.cumulative_handoff_count / $ceiling) * 100)) } else { 0 }
    $metricsBlock = @{
        duration_seconds = $duration
        budget_tier      = $handoff.budget_tier
        budget_ceiling   = $ceiling
        handoff_count    = $handoff.cumulative_handoff_count
        budget_pct_used  = $pctUsed
    }

    Write-EventLog -Event "session_end" -TaskId $handoff.task_id -Specialist $handoff.source_specialist `
        -Outcome "success" -DurationSeconds $duration `
        -Notes ("Handoff to " + $handoff.target_specialist) `
        -HandoffCount $handoff.cumulative_handoff_count `
        -Metrics $metricsBlock
}

# --- 2. Schema Validation ---
$requiredFields = @("task_id", "source_specialist", "target_specialist", "reason", "handoff_retry_count", "budget_tier", "cumulative_handoff_count", "prompt_version")
foreach ($field in $requiredFields) {
    if ($null -eq $handoff.psobject.Properties[$field] -or $null -eq $handoff.$field) {
        Write-Host ("Error: Missing required field " + $field + " in handoff.json") -ForegroundColor Red
        exit 1
    }
}

# --- 2.1 File Affinity Conflict Check (C-116) ---
if ($handoff.psobject.Properties["file_affinity"] -and $handoff.file_affinity -ne $null -and $handoff.file_affinity.Count -gt 0) {
    $affinityScript = ".private/scripts/check-file-affinity.ps1"
    if (Test-Path $affinityScript) {
        & $affinityScript -TaskId $handoff.task_id -Affinity $handoff.file_affinity
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error: File affinity overlap detected with another active task." -ForegroundColor Red
            
            # Log circuit breaker event
            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $eventBlock = @{
                event = "circuit_breaker"
                task_id = $handoff.task_id
                cycle_id = $env:FACTORY_CYCLE_ID
                specialist = "factory"
                timestamp = $timestamp
                notes = "Handoff blocked due to overlapping file affinity."
                outcome = "file_affinity_conflict"
            }
            $eventBlock | ConvertTo-Json -Compress | Out-File -FilePath ".private/session/$($handoff.task_id)/pipeline.log.jsonl" -Append -Encoding UTF8
            
            exit 1
        }
    }
}

# --- 2a. Sanitize Inputs ---
# Prevent prompt injection or confusing formatting in the reason
$handoff.reason = $handoff.reason -replace '[\r\n]+', ' ' -replace '"', "'" -replace '[#*`]', ''
$handoff.reason = $handoff.reason.Trim()
if ($handoff.reason.Length -gt 250) {
    $handoff.reason = $handoff.reason.Substring(0, 247) + "..."
}

# --- 2b. Passive Injection Pattern Scan (C-104) ---
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
        Write-EventLog -Event "security_warning" -TaskId $handoff.task_id -Specialist $handoff.source_specialist -Outcome "warned" -Notes ("Injection pattern detected: " + $detected)
        Write-Host "`n[SECURITY WARNING] Potential injection pattern detected in handoff from $($handoff.source_specialist)." -ForegroundColor Yellow
        Write-Host ("Pattern matched: " + $detected) -ForegroundColor Yellow
        Write-Host ("Review handoff file: " + $handoffFile) -ForegroundColor White
    }

    if ($handoff.source_specialist -eq "researcher") {
        Write-Host "`n[STOP] Researcher handoffs with injection patterns require human review before proceeding." -ForegroundColor Red
        exit 2
    }
    Write-Host "[WARN] Proceeding - non-Researcher source. Human should review console output above.`n" -ForegroundColor Yellow
}

# --- 2c. State Sanitization ---
# Clear stale locks and scratchpads for the target specialist to prevent "zombie state"
$LOCK_DIR = ".private/locks"
if (Test-Path $LOCK_DIR) {
    $staleLocks = Get-ChildItem -Path $LOCK_DIR -Filter ("*" + $handoff.target_specialist + "*")
    if ($staleLocks) {
        Write-Host ("[CLEANUP] Removing stale locks for " + $handoff.target_specialist + "...") -ForegroundColor Cyan
        $staleLocks | Remove-Item -Force
    }
}

if (-not [string]::IsNullOrEmpty($TaskId)) {
    $targetDir = ".private/session/" + $TaskId + "/" + $handoff.target_specialist
} else {
    $targetDir = ".private/session/" + $handoff.target_specialist
}

if (Test-Path $targetDir) {
    $staleTask = Join-Path $targetDir "task.md"
    if (Test-Path $staleTask) {
        Write-Host ("[CLEANUP] Removing stale task.md for " + $handoff.target_specialist + "...") -ForegroundColor Cyan
        Remove-Item $staleTask -Force
    }
}

$validSpecialists = @("groomer", "architect", "reviewer", "operator", "researcher")
if ($validSpecialists -notcontains $handoff.source_specialist) {
    Write-Host ("Error: Invalid source_specialist " + $handoff.source_specialist) -ForegroundColor Red
    exit 1
}
if ($validSpecialists -notcontains $handoff.target_specialist) {
    Write-Host ("Error: Invalid target_specialist " + $handoff.target_specialist) -ForegroundColor Red
    exit 1
}

# --- 3. Circuit Breakers ---

function Write-BlockedTaskRecord {
    param(
        [string]$TaskId,
        [string]$CircuitBreaker,
        [int]$AttemptCount,
        [string]$LastSpecialist,
        [string]$Summary
    )
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $fileTimestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $recordFile = ".private/backlog/blocked/" + $TaskId + "-" + $fileTimestamp + ".json"

    $record = [ordered]@{
        task_id = $TaskId
        backlog_item = $TaskId
        blocked_at = $timestamp
        circuit_breaker = $CircuitBreaker
        attempt_count = $AttemptCount
        last_specialist = $LastSpecialist
        summary = $Summary
        human_decision_needed = "Should we reduce scope, split the task, or abandon it?"
        artifacts = @(".private/session/handoffs", $LOG_FILE)
    }

    $record | ConvertTo-Json -Depth 5 | Set-Content -Path $recordFile -Encoding UTF8
    Write-Host ("`n[DEAD-LETTER] Blocked task record written to: " + $recordFile) -ForegroundColor Magenta

    # Update global state via locked helper (C-094)
    $updateJson = @{ status = "blocked" } | ConvertTo-Json -Compress
    & ".private/scripts/update_session_state.ps1" -Specialist $LastSpecialist -TaskId $TaskId -UpdateJson $updateJson -Merge
}

# Suspicious Content (Prompt Injection Defense - C-098)
if ($null -ne $handoff.psobject.Properties["suspicious_content"] -and $null -ne $handoff.suspicious_content -and $handoff.suspicious_content -ne "") {
    Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_specialist -Outcome "blocked" -Notes ("Suspicious Content Flagged: " + $handoff.suspicious_content)
    Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "human_escalation" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist $handoff.source_specialist -Summary ("Suspicious content flagged in handoff: " + $handoff.suspicious_content)
    Write-Host "`n[CIRCUIT BREAKER] Suspicious Content detected." -ForegroundColor Yellow
    Write-Host "The Researcher specialist has flagged anomalous external instructions."
    Write-Host ("Details: " + $handoff.suspicious_content)
    Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED. Review external sources." -ForegroundColor Red
    exit 2
}

# Handoff Retry Limit
if ($handoff.handoff_retry_count -gt 2 -and $handoff.source_specialist -eq $handoff.target_specialist) {
    Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_specialist -Outcome "blocked" -Notes "Persistent Task Failure - Retry over 2"
    Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "handoff_retry_exceeded" -AttemptCount $handoff.handoff_retry_count -LastSpecialist $handoff.target_specialist -Summary "Persistent Task Failure - Retry over 2"
    Write-Host "`n[CIRCUIT BREAKER] Persistent Task Failure detected." -ForegroundColor Yellow
    Write-Host ("Task " + $handoff.task_id + " has been handed off to " + $handoff.target_specialist + " " + $handoff.handoff_retry_count + " times.")
    Write-Host ("Reason: " + $handoff.reason)
    Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED." -ForegroundColor Red
    exit 2
}

# Review Strike-2 DEGRADED Warning (C-109)
if ($handoff.review_strike_count -eq 2 -and $handoff.target_specialist -eq "architect") {
    Write-EventLog -Event "degraded" -TaskId $handoff.task_id -Specialist $handoff.target_specialist `
        -Outcome "warned" -Notes "Review strike 2 of 3: Architect should reduce scope"
    Write-Host ("`n[DEGRADED] Task " + $handoff.task_id + " has failed review twice.") -ForegroundColor Yellow
    Write-Host "  Strike count: 2 of 3. One more failure will BLOCK this task." -ForegroundColor Yellow
    Write-Host "  Architect DIRECTIVE: Do not attempt a full re-implementation." -ForegroundColor White
    Write-Host "  Consider: splitting the task, deferring the contentious part, or simplifying scope." -ForegroundColor White
}

# Review 3-Strike Rule
if ($handoff.review_strike_count -ge 3) {
    Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_specialist -Outcome "blocked" -Notes "Review Stalemate - 3 strikes"
    Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "review_stalemate" -AttemptCount $handoff.review_strike_count -LastSpecialist $handoff.target_specialist -Summary "Review Stalemate - 3 strikes"
    Write-Host "`n[CIRCUIT BREAKER] Review Stalemate detected." -ForegroundColor Yellow
    Write-Host ("Task " + $handoff.task_id + " has failed review " + $handoff.review_strike_count + " times.")
    Write-Host ("Reason: " + $handoff.reason)
    Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED." -ForegroundColor Red
    exit 2
}

# Token Budget Enforcement (C-090)
if ($handoff.budget_tier) {
    $ceiling = $budgetCeilings[$handoff.budget_tier.ToLower()]
    if ($null -eq $ceiling) {
        Write-Host ("Error: Invalid budget_tier " + $handoff.budget_tier) -ForegroundColor Red
        exit 1
    }

    if ($handoff.cumulative_handoff_count -gt $ceiling) {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_specialist -Outcome "budget_exceeded" -Notes ("Token Budget Exceeded - " + $handoff.cumulative_handoff_count + " over " + $ceiling)
        Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "budget_exceeded" -AttemptCount $handoff.cumulative_handoff_count -LastSpecialist $handoff.target_specialist -Summary ("Token Budget Exceeded - " + $handoff.cumulative_handoff_count + " over " + $ceiling)
        Write-Host "`n[CIRCUIT BREAKER] Token Budget Exceeded." -ForegroundColor Yellow
        Write-Host ("Task " + $handoff.task_id + " has reached " + $handoff.cumulative_handoff_count + " handoffs. Ceiling: " + $ceiling + " for tier " + $handoff.budget_tier)
        Write-Host ("Reason: " + $handoff.reason)
        Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED. Review costs before continuing." -ForegroundColor Red
        exit 2
    }
}

# Recurring Merge Conflicts (F-098)
if ($handoff.psobject.Properties["rebase_count"] -and $handoff.rebase_count -ge 3) {
    Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_specialist -Outcome "blocked" -Notes "Recurring Merge Conflicts - 3 strikes"
    Write-BlockedTaskRecord -TaskId $handoff.task_id -CircuitBreaker "recurring_merge_conflicts" -AttemptCount $handoff.rebase_count -LastSpecialist $handoff.target_specialist -Summary "Recurring Merge Conflicts - 3 strikes. Task requires manual intervention."
    Write-Host "`n[CIRCUIT BREAKER] Recurring Merge Conflicts detected." -ForegroundColor Yellow
    Write-Host ("Task " + $handoff.task_id + " has been rebased " + $handoff.rebase_count + " times and still conflicts.")
    Write-Host "`n[STOP] HUMAN INTERVENTION REQUIRED. Reduce scope or resolve manually." -ForegroundColor Red
    exit 2
}

# --- 3a. Human Gate (C-096) ---
if ($handoff.source_specialist -eq "operator") {
    $GATE_DIR = ".private/session/global/gate_decisions"
    if (-not (Test-Path $GATE_DIR)) {
        New-Item -ItemType Directory -Force -Path $GATE_DIR | Out-Null
    }

    $validOutcomes = @("accepted", "rejected", "redirected", "abandoned")
    $gateAlreadyPassed = $false
    $decisions = @(Get-ChildItem -Path $GATE_DIR -Filter ($handoff.task_id + "-*.json") |
        Where-Object { $_.Name -ne "gate_decision_template.json" } |
        Sort-Object LastWriteTime -Descending)

    if ($decisions.Count -gt 0) {
        try {
            $latestDecision = Get-Content $decisions[0].FullName -Raw | ConvertFrom-Json
            if ($validOutcomes -contains $latestDecision.outcome) {
                $gateAlreadyPassed = $true
            }
        } catch {
            Write-Host ("[GATE] Warning: Could not parse gate decision file " + $decisions[0].Name) -ForegroundColor Yellow
        }
    }

    if (-not $gateAlreadyPassed) {
        $gateTemplatePath = Join-Path $GATE_DIR "gate_decision_template.json"
        
        if (Test-Path $gateTemplatePath) {
            try {
                $gateData = Get-Content $gateTemplatePath -Raw | ConvertFrom-Json
                if ([string]::IsNullOrWhiteSpace($gateData.outcome) -or $gateData.outcome -eq "accepted | rejected | redirected | abandoned") {
                    Write-Host "`n[HUMAN GATE] Action Required: Please complete the gate decision." -ForegroundColor Yellow
                    Write-Host ("File: " + $gateTemplatePath) -ForegroundColor White
                    exit 0
                } else {
                    # Archive the decision
                    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
                    $archivePath = Join-Path $GATE_DIR ($handoff.task_id + "-" + $timestamp + ".json")
                    Move-Item -Path $gateTemplatePath -Destination $archivePath -Force
                    Write-Host ("`n[HUMAN GATE] Decision recorded: " + $gateData.outcome) -ForegroundColor Green
                }
            } catch {
                Write-Host "Error parsing gate decision template." -ForegroundColor Red
                exit 1
            }
        } else {
            # Create template and exit
            $template = [ordered]@{
                task_id = $handoff.task_id
                backlog_item = ""
                gate_fired_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                outcome = "accepted | rejected | redirected | abandoned"
                reason = "Brief human description of why"
                rework_requested = $false
                redirect_target = $null
            }
            $template | ConvertTo-Json | Set-Content -Path $gateTemplatePath -Encoding UTF8
            Write-Host "`n[HUMAN GATE] Task $($handoff.task_id) complete. Present this menu to the human:" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  1) Accept     - work looks good, pick the next item" -ForegroundColor Cyan
            Write-Host "  2) Reject     - something is wrong, send back for rework" -ForegroundColor Cyan
            Write-Host "  3) Redirect   - done, but go work on a specific item next (ask which one)" -ForegroundColor Cyan
            Write-Host "  4) Abandon    - stop the pipeline entirely" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "AGENT ACTION REQUIRED:" -ForegroundColor Magenta
            Write-Host "1. Show the menu above to the human and ask them to reply with 1, 2, 3, or 4." -ForegroundColor White
            Write-Host "2. Map their choice to the outcome: 1=accepted 2=rejected 3=redirected 4=abandoned" -ForegroundColor White
            Write-Host "3. Fill out $gateTemplatePath with the outcome (and redirect_target if they chose 3)." -ForegroundColor White
            Write-Host "4. Re-run factory.ps1 to proceed." -ForegroundColor White
            exit 0
        }
    }
}

# --- 3b. Backlog Integrity Gate ---
# Run automatically when Groomer or Operator hands off (they own BACKLOG.md).
if ($handoff.source_specialist -eq "groomer" -or $handoff.source_specialist -eq "operator") {
    Write-Host "`n[BACKLOG] Running backlog integrity check..." -ForegroundColor Cyan
    try {
        $result = & ".private/scripts/validate-backlog.ps1" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[BACKLOG] VALIDATION FAILED:" -ForegroundColor Red
            $result | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Red }
            Write-Host "`n[STOP] AGENT ACTION REQUIRED: YOU must fix BACKLOG.md before proceeding." -ForegroundColor Red
            Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.source_specialist -Outcome "blocked" -Notes "Backlog validation failed before handoff"
            exit 2
        }
        Write-Host "[BACKLOG] Validation passed." -ForegroundColor Green
    } catch {
        Write-Host ("[BACKLOG] Validation script error: " + $_) -ForegroundColor Red
        exit 1
    }
}

# --- 4. Pipeline Routing (Validation) ---
# Hard-coded routing table for validation
$validTransitions = @{
    groomer = @("architect", "groomer")
    architect = @("reviewer", "architect")
    reviewer = @("operator", "architect", "reviewer")
    operator = @("groomer", "operator")
    researcher = @("groomer", "researcher")
}

if (-not $validTransitions[$handoff.source_specialist].Contains($handoff.target_specialist)) {
    Write-Host ("Warning: Non-standard transition from " + $handoff.source_specialist + " to " + $handoff.target_specialist) -ForegroundColor Cyan
}

# --- 5. Template Assembly ---
$templateFile = Join-Path $PROMPT_LIB ($handoff.target_specialist + "_prompt.md")
$promptVersion = "unknown"
if (-not (Test-Path $templateFile)) {
    # Minimalist fallback
    $promptText = ($handoff.target_specialist | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) + ": Proceed with " + $handoff.task_id + ". See handoff."
} else {
    $promptText = Get-Content $templateFile -Raw
    
    # Extract prompt_version
    if ($promptText -match '<!--\s*prompt_version:\s*(.+?)\s*-->') {
        $promptVersion = $matches[1]
    }

    # Simple placeholder replacement
    $promptText = $promptText.Replace("{task_id}", $handoff.task_id)
    $promptText = $promptText.Replace("{worktree}", (".private/.agent-workspaces/architect-" + $handoff.task_id))
    
    $rebaseCount = if ($handoff.psobject.Properties["rebase_count"]) { $handoff.rebase_count } else { 0 }
    $promptText = $promptText.Replace("{rebase_count}", $rebaseCount)

    # Inject exact resolved handoff filename so agents don't have to glob
    $relativeHandoffPath = ".private/session/handoffs/" + $latestHandoff.Name
    $promptText = $promptText.Replace("{handoff_file}", $relativeHandoffPath)

    if (-not [string]::IsNullOrEmpty($TaskId)) {
        $promptText = $promptText.Replace("{session_dir}", (".private/session/" + $TaskId))
    } else {
        # Legacy: use role-scoped path
        $promptText = $promptText.Replace("{session_dir}", (".private/session/" + $handoff.target_specialist))
    }
    
    $typeDir = "unknown"
    if ($handoff.task_id -match "^F-") { $typeDir = "features" }
    elseif ($handoff.task_id -match "^B-") { $typeDir = "bugs" }
    elseif ($handoff.task_id -match "^C-") { $typeDir = "chores" }
    $promptText = $promptText.Replace("{type}", $typeDir)
    
    $promptText = $promptText.Trim()

    # Unresolved placeholder guard (C-108)
    $unresolvedTokens = [regex]::Matches($promptText, '\{[a-zA-Z_][a-zA-Z0-9_]*\}') |
        ForEach-Object { $_.Value } | Select-Object -Unique
    if ($unresolvedTokens.Count -gt 0) {
        Write-EventLog -Event "circuit_breaker" -TaskId $handoff.task_id -Specialist $handoff.target_specialist `
            -Outcome "failed" -Notes ("Unresolved template placeholders: " + ($unresolvedTokens -join ", "))
        Write-Host ("`n[ERROR] Template " + $templateFile + " has unresolved placeholders:") -ForegroundColor Red
        $unresolvedTokens | ForEach-Object { Write-Host ("  - " + $_) -ForegroundColor Red }
        Write-Host "Add a replacement rule in factory.ps1 section 5 for each token." -ForegroundColor Yellow
        exit 1
    }
}

# --- 6. Output Command ---
# Model Selection Strategy (C-097)
$models = @{
    claude = @{
        architect = "claude-opus-4-6"
        reviewer  = "claude-opus-4-6"
        groomer   = "claude-sonnet-4-6"
        researcher = "claude-sonnet-4-6"
        operator  = "claude-sonnet-4-6"
    }
    gemini = @{
        architect = "gemini-3-pro-preview"
        reviewer  = "gemini-3-pro-preview"
        groomer   = "gemini-3-flash-preview"
        researcher = "gemini-3-flash-preview"
        operator  = "gemini-3-flash-preview"
    }
    agent = @{
        architect = "gemini-3-pro-preview"
        reviewer  = "gemini-3-pro-preview"
        groomer   = "gemini-3-flash-preview"
        researcher = "gemini-3-flash-preview"
        operator  = "gemini-3-flash-preview"
        test      = "gemini-3-flash-preview"
    }
}

$selectedModel = $models[$Target][$handoff.target_specialist]
$modelFlag = if ($selectedModel) { "--model $selectedModel" } else { "" }

Write-Host "`n[FACTORY] Handoff validated. Next step prepared." -ForegroundColor Green
Write-Host "----------------------------------------------------"
if (-not [string]::IsNullOrEmpty($TaskId)) {
    Write-Host ("PIPELINE  : scoped to " + $TaskId) -ForegroundColor Cyan
} else {
    Write-Host ("PIPELINE  : unscoped (legacy mode)") -ForegroundColor DarkGray
}
Write-Host ("TASK ID   : " + $handoff.task_id) -ForegroundColor White
Write-Host ("CYCLE ID  : " + $env:FACTORY_CYCLE_ID) -ForegroundColor DarkGray
Write-Host ("FROM      : " + $handoff.source_specialist) -ForegroundColor White
Write-Host ("TO        : " + $handoff.target_specialist) -ForegroundColor White
Write-Host ("MODEL     : " + $selectedModel) -ForegroundColor Cyan
if ($handoff.review_strike_count -gt 0) {
    $strikeColor = "White"
    if ($handoff.review_strike_count -ge 2) { $strikeColor = "Yellow" }
    Write-Host ("STRIKE    : " + $handoff.review_strike_count + "/3") -ForegroundColor $strikeColor
}
Write-Host ("BUDGET    : " + $handoff.budget_tier + " (" + $handoff.cumulative_handoff_count + "/" + $budgetCeilings[$handoff.budget_tier.ToLower()] + ")") -ForegroundColor White
Write-Host ("REASON    : " + $handoff.reason) -ForegroundColor Gray
Write-Host ("TEMPLATE  : " + $handoff.target_specialist + " (v: " + $promptVersion + ")") -ForegroundColor Gray

if ($handoff.target_specialist -eq "architect") {
    $wtPath = ".private/.agent-workspaces/architect-" + $handoff.task_id
    Write-Host ("WORKTREE  : " + $wtPath) -ForegroundColor Cyan
    
    if ($Init) {
        if (-not (Test-Path $wtPath)) {
            Write-Host ("[INIT] Creating git worktree at " + $wtPath + "...") -ForegroundColor Yellow
            git worktree add $wtPath -b ("task/" + $handoff.task_id) master
        } else {
            Write-Host ("[INIT] Worktree already exists at $wtPath.") -ForegroundColor Cyan
        }

        # Create task-scoped session directory (C-112)
        $sessionDir = if (-not [string]::IsNullOrEmpty($TaskId)) {
            ".private/session/" + $TaskId + "/architect"
        } else {
            ".private/session/architect"
        }
        if (-not (Test-Path $sessionDir)) {
            New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
            Write-Host ("[INIT] Created session dir: $sessionDir") -ForegroundColor Gray
        }
    }
}

if ($Init) {
    # Initialize task.md for the specialist — task-scoped when -TaskId is set
    $targetDir = if (-not [string]::IsNullOrEmpty($TaskId)) {
        ".private/session/" + $TaskId + "/" + $handoff.target_specialist
    } else {
        ".private/session/" + $handoff.target_specialist
    }
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    }
    $taskFile = Join-Path $targetDir "task.md"
    if (-not (Test-Path $taskFile)) {
        Write-Host ("[INIT] Initializing " + $taskFile + "...") -ForegroundColor Yellow
        $wtPath = ".private/.agent-workspaces/architect-" + $handoff.task_id
        $sessionPath = if (-not [string]::IsNullOrEmpty($TaskId)) {
            ".private/session/" + $TaskId
        } else {
            ".private/session/" + $handoff.target_specialist
        }
        
        $affinitySection = ""
        if ($handoff.psobject.Properties["file_affinity"] -and $handoff.file_affinity -ne $null -and $handoff.file_affinity.Count -gt 0) {
            $affinitySection = "`n## Scope Boundary (File Affinity)`n- " + ($handoff.file_affinity -join "`n- ") + "`n"
        }

        # Resolve backlog item path so agents don't need to search
        $backlogItemPath = "unknown"
        if ($typeDir -ne "unknown") {
            $activeFile = Get-ChildItem -Path (".private/backlog/" + $typeDir + "/active") -Filter ($handoff.task_id + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($activeFile) {
                $backlogItemPath = ".private/backlog/" + $typeDir + "/active/" + $activeFile.Name
            } else {
                # Fall back to root of type dir (Groomer may not have moved it yet)
                $rootFile = Get-ChildItem -Path (".private/backlog/" + $typeDir) -Filter ($handoff.task_id + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($rootFile) { $backlogItemPath = ".private/backlog/" + $typeDir + "/" + $rootFile.Name }
            }
        }

        $taskContent = @"
# Task: $($handoff.task_id)
Role: $($handoff.target_specialist)
Cycle ID: $env:FACTORY_CYCLE_ID
Status: In Progress
Reason: $($handoff.reason)

## Resolved Paths
Backlog Item: $backlogItemPath
Handoff:      $relativeHandoffPath
Worktree:     $wtPath
Session Dir:  $sessionPath
Scratchpad:   $sessionPath/$($handoff.target_specialist)/task.md
$affinitySection
## Task List
- [ ] Research
- [ ] Strategy
- [ ] Execution
- [ ] Validation
- [ ] Handoff
"@
        Set-Content -Path $taskFile -Value $taskContent
    }
}

Write-Host "----------------------------------------------------"
Write-Host "[ACTION REQUIRED] Run the following command:`n"
$actionCmd = $Target + " " + $modelFlag + " " + '"' + $promptText + '"'
Write-Host $actionCmd -ForegroundColor White -BackgroundColor Black
Write-Host ""
$nextFactoryCmd = if (-not [string]::IsNullOrEmpty($TaskId)) {
    ".private/scripts/factory.ps1 -Init -TaskId " + $handoff.task_id
} else {
    ".private/scripts/factory.ps1 -Init -TaskId " + $handoff.task_id + "  # (use this at session end)"
}
Write-Host "[NEXT PIPELINE STEP] Agent must run at session end:" -ForegroundColor DarkGray
Write-Host $nextFactoryCmd -ForegroundColor Yellow
Write-Host "----------------------------------------------------`n"

# --- 7. Log Session Start for Target (C-091) ---
$lastStart = Get-LastEntry -TaskId $handoff.task_id -Specialist $handoff.target_specialist -Event "session_start"
if (-not $lastStart -or $lastStart.handoff_count -lt $handoff.cumulative_handoff_count) {
    Write-EventLog -Event "session_start" -TaskId $handoff.task_id -Specialist $handoff.target_specialist -HandoffCount $handoff.cumulative_handoff_count
}
