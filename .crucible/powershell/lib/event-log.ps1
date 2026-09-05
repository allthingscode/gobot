function Write-EventLog {
    param(
        [Parameter(Mandatory=$true)][string]$Event,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Alias("Specialist")]
        [Parameter(Mandatory=$true)][string]$Phase,
        [string]$Outcome = $null,
        [string]$Kind = $null,
        [string]$Notes = $null,
        [int]$DurationSeconds = 0,
        [int]$HandoffCount = 0,
        [string]$CycleId = $env:FACTORY_CYCLE_ID,
        [hashtable]$Metrics = $null,
        # Mandatory, not defaulted to the ambient $LOG_FILE / $CB_HISTORY_FILE. A param
        # default naming an unassigned variable is resolved at call time against the
        # caller's dynamic scope chain, so an omitted argument used to pick up whichever
        # log an ancestor frame happened to be holding. That is silent by construction:
        # the wrong log path is still a valid log path, so nothing downstream can tell.
        #
        # CircuitBreakerHistoryFile is mandatory too, even though it is only read when
        # $Event is "circuit_breaker". Which events are breaker events is decided by an
        # argument value, not by the call site, so a caller that omits it is asserting
        # something it cannot check - and the alternative, throwing at runtime only on
        # the breaker path, moves the failure onto the rarest and most important branch.
        [Parameter(Mandatory=$true)][string]$LogFile,
        [Parameter(Mandatory=$true)][string]$CircuitBreakerHistoryFile
    )

    $timestamp = Get-UtcTimestamp
    
    $eventObj = [ordered]@{
        event = $Event
        task_id = $TaskId
        phase = $Phase
        timestamp = $timestamp
    }

    if ($DurationSeconds -gt 0) { $eventObj.duration_seconds = $DurationSeconds }
    if ($HandoffCount -gt 0) { $eventObj.handoff_count = $HandoffCount }
    if (-not [string]::IsNullOrEmpty($Outcome)) { $eventObj.outcome = $Outcome }
    if (-not [string]::IsNullOrEmpty($Kind)) { $eventObj.kind = $Kind }
    if (-not [string]::IsNullOrEmpty($Notes)) { $eventObj.notes = $Notes }
    if (-not [string]::IsNullOrEmpty($CycleId)) { $eventObj.cycle_id = $CycleId }
    if ($null -ne $Metrics) { $eventObj.metrics = $Metrics }

    $json = $eventObj | ConvertTo-Json -Compress

    $parentDir = Split-Path -Parent $LogFile
    if (-not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    
    Invoke-FileLock -LockPath "$LogFile.lock" -TimeoutMs 5000 -TimeoutMessage "[EVENT LOG] Lock timeout reached (5000 ms). Waiting for the exclusive lock holder." -ScriptBlock {
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

        Invoke-FileLock -LockPath "$CircuitBreakerHistoryFile.lock" -TimeoutMs 5000 -TimeoutMessage "[EVENT LOG] Circuit breaker history lock timeout reached (5000 ms). Waiting for the exclusive lock holder." -ScriptBlock {
            $parentCB = Split-Path -Parent $CircuitBreakerHistoryFile
            if (-not (Test-Path -LiteralPath $parentCB)) {
                New-Item -ItemType Directory -Path $parentCB -Force | Out-Null
            }
            [System.IO.File]::AppendAllText($CircuitBreakerHistoryFile, $json + "`n", (New-Object System.Text.UTF8Encoding $false))
        }.GetNewClosure()
    }
    
    Write-Quiet "[EVENT LOG] $($Event) for $($TaskId) logged." -ForegroundColor DarkGray
}

function ConvertTo-CanonicalPhase {
    param($Phase)
    # Crucible's own gate events were stamped phase "factory" before the rename.
    # Archived logs are never rewritten, so readers canonicalise on the way in and
    # both values stay accepted permanently, not for a migration window.
    if ($Phase -eq "factory") { return "crucible" }
    return $Phase
}

function Get-EntryPhase {
    param($Entry)
    if ($null -eq $Entry) { return $null }
    # Falls back to the legacy specialist field, then canonicalises the value, so a
    # caller never has to know which of the two renames produced the entry it holds.
    $raw = if ($Entry.PSObject.Properties["phase"]) { $Entry.phase } else { $Entry.specialist }
    return (ConvertTo-CanonicalPhase $raw)
}

function Get-LastEntry {
    param(
        [string]$TaskId,
        [Alias("Specialist")]
        [string]$Phase,
        [string]$Event,
        [Parameter(Mandatory=$true)][string]$LogFile
    )
    if (-not (Test-Path $LogFile)) { return $null }
    $wantedPhase = ConvertTo-CanonicalPhase $Phase
    
    # Use a wider tail window so matching start events are still found in noisy task logs.
    $lines = @(Get-Content $LogFile -Tail 200 -Encoding UTF8)
    for ($i = $lines.Length - 1; $i -ge 0; $i--) {
        try {
            $cleanedLine = $lines[$i] -replace "^$([char]0xFEFF)", ""
            $entry = $cleanedLine | ConvertFrom-Json
            
            $logPhase = Get-EntryPhase $entry
            if ($entry.task_id -eq $TaskId -and $logPhase -eq $wantedPhase -and ($null -eq $Event -or $entry.event -eq $Event)) {
                return $entry
            }
        } catch { continue }
    }
    return $null
}
