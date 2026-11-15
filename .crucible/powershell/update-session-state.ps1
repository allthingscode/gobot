param (
    [Parameter(Mandatory=$true)]
    # Keep synchronized with $script:CRUCIBLE_PHASES in crucible-lib.ps1.
    # "coder" remains accepted here for legacy state cleanup calls.
    [ValidateSet("research", "grooming", "implementation", "verification", "deployment", "coder", "done")]
    [string]$Specialist,

    [Parameter(Mandatory=$false)]
    [string]$UpdateJson = "",

    [Parameter(Mandatory=$false)]
    [string]$UpdateJsonFile = "",

    [Parameter(Mandatory=$false)]
    [string]$TaskId = "",

    [Parameter(Mandatory=$false)]
    [bool]$Merge = $true,

    [Parameter(Mandatory=$false)]
    [string]$ProjectRoot = ""
)

if ([string]::IsNullOrEmpty($UpdateJson) -and [string]::IsNullOrEmpty($UpdateJsonFile)) {
    [Console]::Error.WriteLine("Either -UpdateJson or -UpdateJsonFile must be provided.")
    exit 1
}

$ErrorActionPreference = "Stop"

# I11: project/config helpers keep exceptions; this command owns refusal.
trap {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
$helpersPath = Join-Path $PSScriptRoot "lib/config-helpers.ps1"
if (-not (Test-Path -LiteralPath $helpersPath)) {
    [Console]::Error.WriteLine("Required helper script not found at $helpersPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository.")
    exit 1
}
. $helpersPath
. (Join-Path $PSScriptRoot "lib/time.ps1")
. (Join-Path $PSScriptRoot "lib/project-root.ps1")
. (Join-Path $PSScriptRoot "lib/file-lock.ps1")
$ProjectRoot = Resolve-CrucibleProjectRoot -ProjectRoot $ProjectRoot -ScriptRoot $PSScriptRoot
$sessionDir = Get-ConfiguredPath -Key "session" -ProjectRoot $ProjectRoot
$StateFile = Join-Path $sessionDir "global/session_state.json"
$LockFile = Join-Path $sessionDir "global/session_state.lock"

# Ensure the parent directory of the lock file exists
$lockDir = Split-Path $LockFile
if (-not (Test-Path $lockDir)) {
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
}

# --- 1. Acquire Lock, 2. Update State ---
# The shared exclusive-handle lock (I5): the open handle is the lock for the whole write, and
# closing it, on exit or process death, releases it. No waiter judges a lock stale by its age
# and deletes it; that let a waiter steal a slow live writer's lock, and either writer's cleanup
# remove the other's. A holder still present is waited out, with a repeating message naming
# the lock. Item 263.
try {
    Invoke-FileLock -LockPath $LockFile -TimeoutMessage "[SESSION STATE] Waiting for the exclusive lock holder." -ScriptBlock {
        if (-not (Test-Path $StateFile)) {
            # The same shape ConvertFrom-Json gives an existing file. A hashtable here took the
            # Add-Member calls below as note properties that ConvertTo-Json drops, so the first
            # write to a fresh install was lost. Item 234.
            $state = [PSCustomObject]@{ tasks = [PSCustomObject]@{} }
        } else {
            $raw = Get-Content $StateFile -Raw -Encoding UTF8
            $state = $raw | ConvertFrom-Json
        }

        if (-not [string]::IsNullOrEmpty($UpdateJsonFile)) {
            $UpdateJson = Get-Content $UpdateJsonFile -Raw -Encoding UTF8
        }

        $updateObj = $UpdateJson | ConvertFrom-Json

        # Resolve target state based on TaskId
        if (-not [string]::IsNullOrEmpty($TaskId)) {
            if ($Specialist -eq "done") {
                if ($state.PSObject.Properties["tasks"] -and $state.tasks.PSObject.Properties[$TaskId]) {
                    $state.tasks.psobject.Properties.Remove($TaskId)
                    Write-Host "Successfully removed task $TaskId from session state" -ForegroundColor Green
                }
            } else {
                if (-not $state.PSObject.Properties["tasks"]) {
                    $state | Add-Member -MemberType NoteProperty -Name "tasks" -Value ([PSCustomObject]@{})
                }
                if (-not $state.tasks.PSObject.Properties[$TaskId]) {
                    $state.tasks | Add-Member -MemberType NoteProperty -Name $TaskId -Value ([PSCustomObject]@{})
                }
                $targetTask = $state.tasks.$TaskId
                
                # New formalized schema uses 'phases' sub-property
                if (-not $targetTask.PSObject.Properties["phases"]) {
                    $targetTask | Add-Member -MemberType NoteProperty -Name "phases" -Value ([PSCustomObject]@{})
                }
                $targetStateMap = $targetTask.phases
            }
        } else {
            # Legacy fallback
            if (-not $state.PSObject.Properties["phases"]) {
                $state | Add-Member -MemberType NoteProperty -Name "phases" -Value ([PSCustomObject]@{})
                $targetStateMap = $state.phases
            } else {
                $targetStateMap = $state.phases
            }
        }

        if ($Specialist -ne "done") {
            if ($Merge -and $targetStateMap.PSObject.Properties[$Specialist]) {
                # Shallow merge properties into the specialist's section
                foreach ($prop in $updateObj.psobject.Properties) {
                    if (-not $targetStateMap.$Specialist.PSObject.Properties[$prop.Name]) {
                        $targetStateMap.$Specialist | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value
                    } else {
                        $targetStateMap.$Specialist.$($prop.Name) = $prop.Value
                    }
                }
                if (-not $targetStateMap.$Specialist.PSObject.Properties["timestamp"]) {
                    $targetStateMap.$Specialist | Add-Member -MemberType NoteProperty -Name "timestamp" -Value (Get-UtcTimestamp)
                } else {
                    $targetStateMap.$Specialist.timestamp = Get-UtcTimestamp
                }
            } else {
                # Overwrite or create new section
                $targetStateMap | Add-Member -MemberType NoteProperty -Name $Specialist -Value $updateObj -Force
                if (-not $targetStateMap.$Specialist.PSObject.Properties["timestamp"]) {
                    $targetStateMap.$Specialist | Add-Member -MemberType NoteProperty -Name "timestamp" -Value (Get-UtcTimestamp)
                } else {
                    $targetStateMap.$Specialist.timestamp = Get-UtcTimestamp
                }
            }
        }

        # Update global fields if formalized schema is detected
        if ($state.PSObject.Properties["version"]) {
            $nowStamp = Get-UtcTimestamp
            if ($state.PSObject.Properties["timestamp"]) {
                $state.timestamp = $nowStamp
            } else {
                $state | Add-Member -MemberType NoteProperty -Name "timestamp" -Value $nowStamp
            }
        }

        # Convert to JSON (PowerShell's default Pretty Print)
        $json = $state | ConvertTo-Json -Depth 10
        
        $json | Set-Content -Path $StateFile -Encoding UTF8
        Write-Host "Successfully updated $Specialist state in $StateFile" -ForegroundColor Green

        # Adopter-side state validation belongs in a gate with a documented config key,
        # so its outcome controls progression and the contract is discoverable. Item 91.
    }
} catch {
    [Console]::Error.WriteLine("Failed to update session state: $($_.Exception.Message)")
    exit 1
}

exit 0
