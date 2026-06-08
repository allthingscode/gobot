function Write-BlockedTaskRecord {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$CircuitBreaker,
        [Parameter(Mandatory=$true)][int]$AttemptCount,
        [Alias("LastSpecialist")]
        [Parameter(Mandatory=$true)][string]$LastPhase,
        [Parameter(Mandatory=$true)][string]$Summary,
        [string]$HumanDecisionNeeded = "Should we reduce scope, split the task, or abandon it?",
        [string[]]$Artifacts = @(),
        [string]$BacklogDir = $backlogDir,
        [string]$FrameworkPowerShell = $FRAMEWORK_POWERSHELL
    )
    $blockedDir = Join-Path $BacklogDir "blocked"
    if (-not (Test-Path $blockedDir)) { New-Item -ItemType Directory -Force -Path $blockedDir | Out-Null }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $fileTimestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $record = [ordered]@{
        task_id                = $TaskId
        backlog_item           = $TaskId
        blocked_at             = $timestamp
        circuit_breaker        = $CircuitBreaker
        attempt_count          = $AttemptCount
        last_phase             = $LastPhase
        summary                = $Summary
        human_decision_needed  = $HumanDecisionNeeded
        artifacts              = $Artifacts
    }
    $recordPath = Join-Path $blockedDir ("$TaskId-$fileTimestamp.json")
    $record | ConvertTo-Json | Set-Content -Path $recordPath -Encoding UTF8
    Write-Quiet ("[BLOCKED] Record written to $recordPath") -ForegroundColor Cyan

    $actualProjectRoot = ""
    if (Test-Path "variable:Context") {
        $localContext = Get-Variable "Context" -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $localContext -and $localContext.ContainsKey("RepoRoot")) {
            $actualProjectRoot = $localContext.RepoRoot
        }
    }
    if ([string]::IsNullOrEmpty($actualProjectRoot) -and (Test-Path "variable:repoRoot")) {
        $localRepoRoot = Get-Variable "repoRoot" -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $localRepoRoot) {
            $actualProjectRoot = $localRepoRoot
        }
    }
    if ([string]::IsNullOrEmpty($actualProjectRoot)) {
        try {
            $resolvedBacklog = (Resolve-Path $BacklogDir).Path
            $dir = Split-Path -Parent $resolvedBacklog
            while (-not [string]::IsNullOrEmpty($dir)) {
                if (Test-Path (Join-Path $dir ".crucible")) {
                    $actualProjectRoot = $dir
                    break
                }
                $nextDir = Split-Path -Parent $dir
                if ($nextDir -eq $dir) { break }
                $dir = $nextDir
            }
        } catch {}
    }

    $updateJson = @{ status = "blocked"; circuit_breaker = $CircuitBreaker } | ConvertTo-Json -Compress
    & "$FrameworkPowerShell/update-session-state.ps1" -Specialist $LastPhase -TaskId $TaskId -UpdateJson $updateJson -Merge $true -ProjectRoot $actualProjectRoot 2>$null
}
