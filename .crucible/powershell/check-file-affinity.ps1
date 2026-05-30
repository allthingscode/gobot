param (
    [Parameter(Mandatory=$true)]
    [string]$TaskId,

    [Parameter(Mandatory=$true)]
    [string[]]$Affinity,

    [Parameter(Mandatory=$false)]
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"
$helpersPath = Join-Path $PSScriptRoot "lib/config-helpers.ps1"
if (-not (Test-Path -LiteralPath $helpersPath)) {
    throw "Required helper script not found at $helpersPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $helpersPath
$sessionDir = Get-ConfiguredPath -Key "session" -ProjectRoot $ProjectRoot
$StateFile = Join-Path $sessionDir "global/session_state.json"

if (-not (Test-Path $StateFile)) {
    exit 0
}

$raw = Get-Content $StateFile -Raw -Encoding UTF8
$state = $raw | ConvertFrom-Json

$overlapFound = $false

if ($state.PSObject.Properties["tasks"] -and $null -ne $state.tasks) {
    $taskNames = @($state.tasks.PSObject.Properties | Select-Object -ExpandProperty Name)
    foreach ($otherTaskId in $taskNames) {
        if ($otherTaskId -eq $TaskId) { continue }
        
        $otherTask = $state.tasks.$otherTaskId
        
        # Check if task is active (not resolved/archived). We can check if operator has finished.
        $operatorDone = $false
        $opSpec = if ($otherTask.phases -and $otherTask.phases.PSObject.Properties["deployment"]) { $otherTask.phases.deployment } else { $null }
        if ($opSpec) {
            if ($opSpec.PSObject.Properties["status"] -and ($opSpec.status -eq "Complete" -or $opSpec.status -eq "idle")) {
                if ($opSpec.PSObject.Properties["phase"] -and ($opSpec.phase -eq "Production" -or $opSpec.phase -eq "Complete")) {
                    $operatorDone = $true
                }
            }
        }
        
        if ($operatorDone) { continue }

        # Extract affinity for the other task (from grooming or implementation state)
        $otherAffinity = @()
        if ($otherTask.phases) {
            $archSpec = if ($otherTask.phases.PSObject.Properties["implementation"]) { $otherTask.phases.implementation } else { $null }
            $groomSpec = if ($otherTask.phases.PSObject.Properties["grooming"]) { $otherTask.phases.grooming } else { $null }
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
