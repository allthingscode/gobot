param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("groomer", "architect", "reviewer", "coder", "operator", "researcher")]
    [string]$Specialist
)

$Path = ".private/session/session_state.json"

if (-not (Test-Path $Path)) {
    Write-Host "No session state file found at $Path"
    exit 0
}

try {
    $RawJson = Get-Content $Path -Raw -Encoding utf8
    $State = $RawJson | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse ${Path}: $_"
    exit 1
}

# Define idle states for each specialist
$IdleStates = @{
    "groomer" = @{
        "phase" = "Complete"
        "status" = "idle"
        "last_item" = ""
        "completed_passes" = @()
        "pending_items" = @()
        "errors" = @()
        "notes" = "Cleared by script"
    }
    "architect" = @{
        "phase" = "Complete"
        "status" = "idle"
        "last_item" = ""
        "blockers_resolved" = @()
        "notes" = "Cleared by script"
    }
    "reviewer" = @{
        "phase" = "Complete"
        "status" = "idle"
        "last_item" = ""
        "review_strike_count" = 0
        "blockers_found" = 0
        "observations" = @()
        "decision" = ""
        "notes" = "Cleared by script"
    }
    "coder" = @{
        "phase" = "Complete"
        "status" = "idle"
        "last_item" = ""
        "notes" = "Cleared by script"
    }
    "operator" = @{
        "phase" = "Complete"
        "status" = "idle"
        "last_item" = ""
        "notes" = "Cleared by script"
    }
    "researcher" = @{
        "phase" = "Complete"
        "status" = "idle"
        "last_item" = ""
        "notes" = "Cleared by script"
    }
}

if ($State.specialists.PSObject.Properties[$Specialist]) {
    $State.specialists.$Specialist = $IdleStates[$Specialist]
    
    # Use PowerShell's built-in JSON conversion (default is 2 spaces, but we want 4)
    # Since PowerShell 7.1, ConvertTo-Json doesn't support custom indentation easily.
    # We will use a regex replace to convert 2-space to 4-space if needed, 
    # but the primary goal is a clean multi-line write.
    $JsonOutput = $State | ConvertTo-Json -Depth 10
    
    # Force 4-space indentation for compliance with project mandates
    $JsonOutput = $JsonOutput -replace '^(\s+)', { $args[0].Value + $args[0].Value }
    
    $JsonOutput | Set-Content $Path -Encoding utf8
    Write-Host "Successfully cleared $Specialist session state (with 4-space indentation)."
} else {
    Write-Host "Specialist $Specialist not found in session state."
}
