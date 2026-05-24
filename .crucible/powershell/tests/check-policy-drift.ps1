# Check Policy Drift
# Verifies that factory.ps1 and prompt templates remain synchronized with POLICY.md

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path

$POLICY_FILE = Join-Path $REPO_ROOT "docs/policy.md"
if (-not (Test-Path $POLICY_FILE)) {
    Write-Host "Error: POLICY.md not found" -ForegroundColor Red
    exit 1
}

$policyContent = Get-Content $POLICY_FILE -Raw
$errors = @()

# 1. Verify Budget Tiers in factory.ps1
$factoryPath = Join-Path $REPO_ROOT "powershell/factory.ps1"
if (Test-Path $factoryPath) {
    $factoryContent = Get-Content $factoryPath -Raw
    
    # Extract budgets from POLICY.md
    if ($policyContent -match 'Token Budget \(Low\)\s*\|\s*(\d+)') {
        $low = $Matches[1]
        if ($factoryContent -notmatch "`$budgetCeilings = @\{ low = $low;") {
            $errors += "Budget mismatch: POLICY.md says Low=$low, but factory.ps1 differs"
        }
    }
    if ($policyContent -match 'Token Budget \(Medium\)\s*\|\s*(\d+)') {
        $med = $Matches[1]
        if ($factoryContent -notmatch "medium = $med;") {
            $errors += "Budget mismatch: POLICY.md says Medium=$med, but factory.ps1 differs"
        }
    }
    if ($policyContent -match 'Token Budget \(High\)\s*\|\s*(\d+)') {
        $high = $Matches[1]
        if ($factoryContent -notmatch "high = $high \}") {
            $errors += "Budget mismatch: POLICY.md says High=$high, but factory.ps1 differs"
        }
    }
}

# 2. Verify Prompt Templates have Policy Enforcement block
$promptLib = Join-Path $REPO_ROOT "prompts"
if (Test-Path $promptLib) {
    $prompts = Get-ChildItem -Path $promptLib -Filter "*_prompt.md"
    foreach ($prompt in $prompts) {
        $pContent = Get-Content $prompt.FullName -Raw
        if ($pContent -notmatch "## POLICY ENFORCEMENT \(Mandatory\)") {
            $errors += "Prompt template missing mandatory Policy Enforcement block: $($prompt.Name)"
        }
    }
}

if ($errors.Count -gt 0) {
    Write-Host "POLICY DRIFT DETECTED:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 2
} else {
    Write-Host "No policy drift detected. Documentation and code are synchronized." -ForegroundColor Green
    exit 0
}
