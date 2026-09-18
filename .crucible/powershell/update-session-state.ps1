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
    Write-Error "Either -UpdateJson or -UpdateJsonFile must be provided."
    exit 1
}

$ErrorActionPreference = "Stop"
$helpersPath = Join-Path $PSScriptRoot "lib/config-helpers.ps1"
if (-not (Test-Path -LiteralPath $helpersPath)) {
    throw "Required helper script not found at $helpersPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $helpersPath
. (Join-Path $PSScriptRoot "lib/time.ps1")
$sessionDir = Get-ConfiguredPath -Key "session" -ProjectRoot $ProjectRoot
$StateFile = Join-Path $sessionDir "global/session_state.json"
$LockFile = Join-Path $sessionDir "global/session_state.lock"

# Ensure the parent directory of the lock file exists
$lockDir = Split-Path $LockFile
if (-not (Test-Path $lockDir)) {
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
}

# --- 1. Acquire Lock ---
# Stale-lock policy ({task_id}): if a lock file is older than $StaleAgeMinutes, treat
# it as orphaned from a crashed session, log a [WARN], auto-remove it, and retry
# acquisition once. A genuine concurrent lock (re-created within $MaxWait after
# stale recovery, or a fresh lock that never ages out) still triggers a timeout
# error so two live processes never silently clobber each other's state.
$MaxWait = 5 # seconds
$WaitStep = 100 # ms
$StaleAgeMinutes = 2
$StartTime = Get-Date
$Acquired = $false
$StaleRecovered = $false

while ((Get-Date) -lt $StartTime.AddSeconds($MaxWait)) {
    try {
        # New-Item fails if file exists (atomic check-and-create)
        $null = New-Item -Path $LockFile -ItemType File -Value "$PID" -ErrorAction Stop
        $Acquired = $true
        break
    } catch {
        $lockInfo = Get-Item $LockFile -ErrorAction SilentlyContinue
        if ($lockInfo -and (Get-Date) -gt $lockInfo.LastWriteTime.AddMinutes($StaleAgeMinutes)) {
            if ($StaleRecovered) {
                # A second stale lock appeared after we already cleared one this
                # session. Treat as a genuine conflict and let the timeout fire.
                Start-Sleep -Milliseconds $WaitStep
                continue
            }
            $ageSeconds = [int]((Get-Date) - $lockInfo.LastWriteTime).TotalSeconds
            Write-Warning "[WARN] Stale lock detected at '$LockFile' (age ${ageSeconds}s, > ${StaleAgeMinutes}m). Auto-removing and retrying acquisition."
            Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
            $StaleRecovered = $true
            # Skip sleep - retry immediately so we beat any concurrent acquirer.
            continue
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
        $state = [ordered]@{ tasks = @{} }
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

    # A CRUCIBLE_STATE_VALIDATOR hook used to run here, invoking an adopter-supplied command as
    # `<cmd> factory state validate <state file>`. Deleted by item 91 on the human's decision.
    # It printed "State validation passed." whenever the command could be launched: a native
    # process that exits non-zero does not throw even under $ErrorActionPreference = "Stop", and
    # nothing read $LASTEXITCODE, so the catch fired only for a command that could not start.
    # It could not tell "verified" from "never checked", which CONTRIBUTING.md forbids.
    #
    # Not repaired, because the repair would not have made it matter. No caller read its
    # outcome, so a corrected check would have been honest and still consequence-free. It had
    # also been present unchanged since the initial commit with no rationale, no implementation
    # anywhere including the live adopter, and no mention in any doc, schema, template or test -
    # an adopter could not discover the hook existed, let alone the subcommand to implement. If
    # adopter-side validation of this file is wanted, it belongs in a gate with a documented
    # config key, not an undiscoverable environment variable. That also retires the last
    # `factory` token in production PowerShell rather than documenting it as a contract.

} catch {
    Write-Error "Failed to update session state: $($_.Exception.Message)"
} finally {
    # --- 3. Release Lock ---
    if ($Acquired) {
        Remove-Item $LockFile -ErrorAction SilentlyContinue
    }
}
