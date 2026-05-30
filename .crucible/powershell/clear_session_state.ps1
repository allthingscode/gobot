param (
    [Parameter(Mandatory=$true)]
    [ValidateSet(
        "research", "grooming", "implementation", "verification", "deployment", "coder", "done",
        "researcher", "groomer", "architect", "reviewer", "operator"
    )]
    [string]$Specialist
)

# Normalize specialist to phase names
$normalized = $Specialist
switch ($Specialist) {
    "researcher" { $normalized = "research" }
    "groomer"    { $normalized = "grooming" }
    "architect"  { $normalized = "implementation" }
    "reviewer"   { $normalized = "verification" }
    "operator"   { $normalized = "deployment" }
}

# Define idle states for each phase
$IdleStates = @{
    "research" = @{
        "phase" = "Complete"
        "status" = "idle"
        "last_item" = ""
        "notes" = "Cleared by script"
    }
    "grooming" = @{
        "phase" = "Complete"
        "status" = "idle"
        "last_item" = ""
        "completed_passes" = @()
        "pending_items" = @()
        "errors" = @()
        "notes" = "Cleared by script"
    }
    "implementation" = @{
        "phase" = "Complete"
        "status" = "idle"
        "last_item" = ""
        "blockers_resolved" = @()
        "notes" = "Cleared by script"
    }
    "verification" = @{
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
    "deployment" = @{
        "phase" = "Complete"
        "status" = "idle"
        "last_item" = ""
        "notes" = "Cleared by script"
    }
    "done" = @{
        "phase" = "Complete"
        "status" = "idle"
        "last_item" = ""
        "notes" = "Cleared by script"
    }
}

$IdleJson = $IdleStates[$normalized] | ConvertTo-Json -Compress
$ScriptPath = Join-Path $PSScriptRoot "update_session_state.ps1"

Write-Host "[CLEANUP] Clearing $normalized session state..." -ForegroundColor Cyan
& $ScriptPath -Specialist $normalized -UpdateJson $IdleJson -Merge:$false
