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

    $timestamp = Get-UtcTimestamp
    $fileTimestamp = Get-UtcFileTimestamp
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

    # The record above is the artifact the operator and tooling read; this is a follow-on
    # side effect. It runs in-process and reads config, so under $ErrorActionPreference =
    # "Stop" a failure here used to propagate out of the breaker path and replace a
    # deliberate refusal with an unrelated error - losing the wedge and the exit code with
    # it. A session-state update that cannot run is worth a warning, never the refusal.
    $updateJson = @{ status = "blocked"; circuit_breaker = $CircuitBreaker } | ConvertTo-Json -Compress
    try {
        & "$FrameworkPowerShell/update-session-state.ps1" -Specialist $LastPhase -TaskId $TaskId -UpdateJson $updateJson -Merge $true -ProjectRoot $actualProjectRoot 2>$null
    } catch {
        Write-Quiet ("[BLOCKED] Warning: session state was not updated for " + $TaskId + ": " + $_.Exception.Message) -ForegroundColor Yellow
    }
}
