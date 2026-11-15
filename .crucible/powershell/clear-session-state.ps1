param (
    [Parameter(Mandatory=$true)]
    [ValidateSet(
        "research", "grooming", "implementation", "verification", "deployment", "coder", "done",
        "researcher", "groomer", "architect", "reviewer", "operator"
    )]
    [string]$Specialist,

    [Parameter(Mandatory=$false)]
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"

# I11: project/config helpers keep exceptions; this command owns refusal.
trap {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
. (Join-Path $PSScriptRoot "lib/project-root.ps1")
$resolvedProjectRoot = Resolve-CrucibleProjectRoot -ProjectRoot $ProjectRoot -ScriptRoot $PSScriptRoot

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
$ScriptPath = Join-Path $PSScriptRoot "update-session-state.ps1"

Write-Host "[CLEANUP] Clearing $normalized session state..." -ForegroundColor Cyan
$global:LASTEXITCODE = 0
& $ScriptPath -Specialist $normalized -UpdateJson $IdleJson -Merge:$false -ProjectRoot $resolvedProjectRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
exit 0
