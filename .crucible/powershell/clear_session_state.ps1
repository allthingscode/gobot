param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("groomer", "architect", "reviewer", "coder", "operator", "researcher")]
    [string]$Specialist
)

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

$IdleJson = $IdleStates[$Specialist] | ConvertTo-Json -Compress
$ScriptPath = Join-Path $PSScriptRoot "update_session_state.ps1"

Write-Host "[CLEANUP] Clearing $Specialist session state..." -ForegroundColor Cyan
& $ScriptPath -Specialist $Specialist -UpdateJson $IdleJson -Merge:$false
