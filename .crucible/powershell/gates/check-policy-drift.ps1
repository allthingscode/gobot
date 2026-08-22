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

# 1. Verify Budget Tiers in factory-lib.ps1
$factoryLibPath = Join-Path $REPO_ROOT "powershell/factory-lib.ps1"
if (Test-Path $factoryLibPath) {
    $factoryLibContent = Get-Content $factoryLibPath -Raw
    
    # Extract budgets from POLICY.md
    if ($policyContent -match 'Token Budget \(Low\)\s*\|\s*(\d+)') {
        $low = $Matches[1]
        if ($factoryLibContent -notmatch "low = $low") {
            $errors += "Budget mismatch: POLICY.md says Low=$low, but factory-lib.ps1 differs"
        }
    }
    if ($policyContent -match 'Token Budget \(Medium\)\s*\|\s*(\d+)') {
        $med = $Matches[1]
        if ($factoryLibContent -notmatch "medium = $med") {
            $errors += "Budget mismatch: POLICY.md says Medium=$med, but factory-lib.ps1 differs"
        }
    }
    if ($policyContent -match 'Token Budget \(High\)\s*\|\s*(\d+)') {
        $high = $Matches[1]
        if ($factoryLibContent -notmatch "high = $high") {
            $errors += "Budget mismatch: POLICY.md says High=$high, but factory-lib.ps1 differs"
        }
    }
    if ($policyContent -match 'Token Budget \(Extended\)\s*\|\s*(\d+)') {
        $extended = $Matches[1]
        if ($factoryLibContent -notmatch "extended = $extended") {
            $errors += "Budget mismatch: POLICY.md says Extended=$extended, but factory-lib.ps1 differs"
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

# 3. Verify no stray .crucible directory exists in the source repository root (Test Pollution check)
$strayCrucible = Join-Path $REPO_ROOT ".crucible"
if (Test-Path -LiteralPath $strayCrucible) {
    Push-Location $REPO_ROOT
    try {
        $tracked   = @(git ls-files -- .crucible 2>$null)
        $stageable = @(git ls-files --others --exclude-standard -- .crucible 2>$null)
    } finally { Pop-Location }
    $committable = @(($tracked + $stageable) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($committable.Count -gt 0) {
        $errors += "Test pollution detected: committable files exist under a stray '.crucible' at the repository root ($strayCrucible): " + ($committable -join ", ") + ". Remove them or ensure tests write to isolated temp dirs."
    }
}

# 4. Assert no phase prompt/SOP instructs to write handoff JSON directly and each references new-handoff.ps1
$phaseDocs = @(
    "prompts/research_prompt.md",
    "prompts/grooming_prompt.md",
    "prompts/implementation_prompt.md",
    "prompts/verification_prompt.md",
    "prompts/deployment_prompt.md",
    "sops/research.md",
    "sops/grooming.md",
    "sops/implementation.md",
    "sops/verification.md",
    "sops/deployment.md"
)
foreach ($relPath in $phaseDocs) {
    $fullPath = Join-Path $REPO_ROOT $relPath
    if (Test-Path $fullPath) {
        $content = Get-Content $fullPath -Raw
        # Search for pattern "Write `.crucible/...`" or similar JSON writing instructions
        if ($content -match '(?i)Write\s+`[^`]*handoffs/[^`]*\.json`' -or $content -match '(?i)Write\s+`[^`]*handoff\.json`') {
            $errors += "File instructs writing JSON handoff directly instead of using tool: $relPath"
        }
        if ($content -notmatch "new-handoff\.ps1") {
            $errors += "File missing reference to new-handoff.ps1: $relPath"
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
