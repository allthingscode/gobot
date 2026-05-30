function Write-EventLog {
    param(
        [Parameter(Mandatory=$true)][string]$Event,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Alias("Specialist")]
        [Parameter(Mandatory=$true)][string]$Phase,
        [string]$Outcome = $null,
        [string]$Notes = $null,
        [int]$DurationSeconds = 0,
        [int]$HandoffCount = 0,
        [string]$CycleId = $env:FACTORY_CYCLE_ID,
        [hashtable]$Metrics = $null,
        [string]$LogFile = $LOG_FILE,
        [string]$CircuitBreakerHistoryFile = $CB_HISTORY_FILE
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    $eventObj = [ordered]@{
        event = $Event
        task_id = $TaskId
        phase = $Phase
        timestamp = $timestamp
    }

    if ($DurationSeconds -gt 0) { $eventObj.duration_seconds = $DurationSeconds }
    if ($HandoffCount -gt 0) { $eventObj.handoff_count = $HandoffCount }
    if (-not [string]::IsNullOrEmpty($Outcome)) { $eventObj.outcome = $Outcome }
    if (-not [string]::IsNullOrEmpty($Notes)) { $eventObj.notes = $Notes }
    if (-not [string]::IsNullOrEmpty($CycleId)) { $eventObj.cycle_id = $CycleId }
    if ($null -ne $Metrics) { $eventObj.metrics = $Metrics }

    $json = $eventObj | ConvertTo-Json -Compress

    $parentDir = Split-Path -Parent $LogFile
    if (-not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    
    Invoke-FileLock -LockPath "$LogFile.lock" -TimeoutMs 5000 -TimeoutMessage "[EVENT LOG] Lock timeout reached (5000 ms). Forcing removal of stale lock." -ScriptBlock {
        $parentDir = Split-Path -Parent $LogFile
        if (-not (Test-Path -LiteralPath $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }
        [System.IO.File]::AppendAllText($LogFile, $json + "`n", (New-Object System.Text.UTF8Encoding $false))
    }.GetNewClosure()

    if ($Event -eq "circuit_breaker") {
        $parentCB = Split-Path -Parent $CircuitBreakerHistoryFile
        if (-not (Test-Path -LiteralPath $parentCB)) {
            New-Item -ItemType Directory -Path $parentCB -Force | Out-Null
        }

        Invoke-FileLock -LockPath "$CircuitBreakerHistoryFile.lock" -TimeoutMs 5000 -TimeoutMessage "[EVENT LOG] Circuit breaker history lock timeout reached (5000 ms). Forcing stale lock removal." -ScriptBlock {
            $parentCB = Split-Path -Parent $CircuitBreakerHistoryFile
            if (-not (Test-Path -LiteralPath $parentCB)) {
                New-Item -ItemType Directory -Path $parentCB -Force | Out-Null
            }
            [System.IO.File]::AppendAllText($CircuitBreakerHistoryFile, $json + "`n", (New-Object System.Text.UTF8Encoding $false))
        }.GetNewClosure()
    }
    
    Write-Quiet "[EVENT LOG] $($Event) for $($TaskId) logged." -ForegroundColor DarkGray
}

function Get-LastEntry {
    param(
        [string]$TaskId,
        [Alias("Specialist")]
        [string]$Phase,
        [string]$Event,
        [string]$LogFile = $LOG_FILE
    )
    if (-not (Test-Path $LogFile)) { return $null }
    
    # Use a wider tail window so matching start events are still found in noisy task logs.
    $lines = Get-Content $LogFile -Tail 200 -Encoding UTF8
    for ($i = $lines.Length - 1; $i -ge 0; $i--) {
        try {
            $cleanedLine = $lines[$i] -replace "^$([char]0xFEFF)", ""
            $entry = $cleanedLine | ConvertFrom-Json
            
            # Resolve log phase, with fallback to legacy specialist field
            $logPhase = if ($entry.PSObject.Properties["phase"]) { $entry.phase } else { $entry.specialist }
            if ($entry.task_id -eq $TaskId -and $logPhase -eq $Phase -and ($null -eq $Event -or $entry.event -eq $Event)) {
                return $entry
            }
        } catch { continue }
    }
    return $null
}
