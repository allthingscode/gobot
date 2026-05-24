param (
    [Parameter(Mandatory=$true)]
    [string]$TaskId,

    [Parameter(Mandatory=$true)]
    [string[]]$Affinity
)

$ErrorActionPreference = "Stop"
$StateFile = ".crucible/session/global/session_state.json"

if (-not (Test-Path $StateFile)) {
    exit 0
}

$raw = Get-Content $StateFile -Raw -Encoding UTF8
$state = $raw | ConvertFrom-Json

$overlapFound = $false

if ($state.tasks) {
    foreach ($otherTaskId in $state.tasks.PSObject.Properties.Name) {
        if ($otherTaskId -eq $TaskId) { continue }
        
        $otherTask = $state.tasks.$otherTaskId
        
        # Check if task is active (not resolved/archived). We can check if operator has finished.
        $operatorDone = $false
        $opSpec = if ($otherTask.specialists -and $otherTask.specialists.PSObject.Properties["operator"]) { $otherTask.specialists.operator } else { $null }
        if ($opSpec) {
            if ($opSpec.PSObject.Properties["status"] -and ($opSpec.status -eq "Complete" -or $opSpec.status -eq "idle")) {
                if ($opSpec.PSObject.Properties["phase"] -and ($opSpec.phase -eq "Production" -or $opSpec.phase -eq "Complete")) {
                    $operatorDone = $true
                }
            }
        }
        
        if ($operatorDone) { continue }

        # Extract affinity for the other task (from groomer or architect state)
        $otherAffinity = @()
        if ($otherTask.specialists) {
            $archSpec = if ($otherTask.specialists.PSObject.Properties["architect"]) { $otherTask.specialists.architect } else { $null }
            $groomSpec = if ($otherTask.specialists.PSObject.Properties["groomer"]) { $otherTask.specialists.groomer } else { $null }
            if ($archSpec -and $archSpec.PSObject.Properties["file_affinity"]) {
                $otherAffinity = $archSpec.file_affinity
            } elseif ($groomSpec -and $groomSpec.PSObject.Properties["file_affinity"]) {
                $otherAffinity = $groomSpec.file_affinity
            }
        }

        # Check for overlaps
        foreach ($pattern in $Affinity) {
            $cleanPattern = $pattern -replace '\*.*', '' -replace '\\', '/'
            foreach ($otherPattern in $otherAffinity) {
                $cleanOther = $otherPattern -replace '\*.*', '' -replace '\\', '/'
                
                # Check if one is a prefix of another
                if ($cleanPattern -ne "" -and $cleanOther -ne "") {
                    if ($cleanPattern.StartsWith($cleanOther) -or $cleanOther.StartsWith($cleanPattern)) {
                        Write-Host "CONFLICT: $pattern overlaps with active task $otherTaskId ($otherPattern)" -ForegroundColor Red
                        $overlapFound = $true
                    }
                }
            }
        }
    }
}

if ($overlapFound) {
    exit 1
} else {
    exit 0
}
