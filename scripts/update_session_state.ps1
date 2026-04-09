param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("groomer", "architect", "reviewer", "coder", "operator", "researcher")]
    [string]$Specialist,

    [Parameter(Mandatory=$true)]
    [string]$UpdateJson,

    [Parameter(Mandatory=$false)]
    [switch]$Merge = $true
)

$ErrorActionPreference = "Stop"
$StateFile = ".private/session/global/session_state.json"
$LockFile = ".private/session/global/session_state.lock"

# --- 1. Acquire Lock ---
$MaxWait = 5 # seconds
$WaitStep = 100 # ms
$StartTime = Get-Date
$Acquired = $false

while ((Get-Date) -lt $StartTime.AddSeconds($MaxWait)) {
    try {
        # New-Item fails if file exists (atomic check-and-create)
        $null = New-Item -Path $LockFile -ItemType File -Value "$PID" -ErrorAction Stop
        $Acquired = $true
        break
    } catch {
        # Check for stale lock
        $lockInfo = Get-Item $LockFile -ErrorAction SilentlyContinue
        if ($lockInfo -and (Get-Date) -gt $lockInfo.LastWriteTime.AddMinutes(10)) {
            Write-Error "STALE LOCK DETECTED! Lock created at $($lockInfo.CreationTime) by a previous process. Delete it manually if no session is active: rm $LockFile"
            exit 1
        }
        Start-Sleep -Milliseconds $WaitStep
    }
}

if (-not $Acquired) {
    Write-Error "Lock timeout: Could not acquire lock for $StateFile after $MaxWait seconds."
    exit 1
}

# --- 2. Update State ---
try {
    if (-not (Test-Path $StateFile)) {
        $state = @{ specialists = @{} }
    } else {
        $raw = Get-Content $StateFile -Raw -Encoding UTF8
        $state = $raw | ConvertFrom-Json
    }

    $updateObj = $UpdateJson | ConvertFrom-Json

    if ($Merge -and $state.specialists.PSObject.Properties[$Specialist]) {
        # Shallow merge properties into the specialist's section
        foreach ($prop in $updateObj.psobject.Properties) {
            $state.specialists.$Specialist.$($prop.Name) = $prop.Value
        }
        $state.specialists.$Specialist.timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    } else {
        # Overwrite or create new section
        $state.specialists.$Specialist = $updateObj
        if (-not $state.specialists.$Specialist.timestamp) {
            $state.specialists.$Specialist.timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }

    # Convert to JSON (PowerShell's default Pretty Print)
    $json = $state | ConvertTo-Json -Depth 10
    
    $json | Set-Content -Path $StateFile -Encoding UTF8
    Write-Host "Successfully updated $Specialist state in $StateFile" -ForegroundColor Green

} catch {
    Write-Error "Failed to update session state: $($_.Exception.Message)"
} finally {
    # --- 3. Release Lock ---
    if ($Acquired) {
        Remove-Item $LockFile -ErrorAction SilentlyContinue
    }
}
