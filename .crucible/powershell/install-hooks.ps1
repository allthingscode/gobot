# Installs git hooks for the Crucible framework repository or an adopter repository.
$ErrorActionPreference = "Stop"

# Determine if we are in the framework repo or an adopter
$parentDir = (Resolve-Path -Path "$PSScriptRoot/..").Path
$grandParentDir = (Resolve-Path -Path "$PSScriptRoot/../..").Path

if (Test-Path -LiteralPath (Join-Path $parentDir ".git")) {
    # Framework repo mode
    $repoRoot = $parentDir
    $hooksPath = "scripts/hooks"
} elseif (Test-Path -LiteralPath (Join-Path $grandParentDir ".git")) {
    # Adopter repo mode
    $repoRoot = $grandParentDir
    $hooksPath = ".crucible/scripts/hooks"
} else {
    throw "Not a git repository (missing .git directory)."
}

# Verify the hooks directory actually exists
$fullHooksDir = Join-Path $repoRoot $hooksPath
if (-not (Test-Path -LiteralPath $fullHooksDir)) {
    throw "Hooks directory not found: $fullHooksDir"
}

# Configure core.hooksPath in Git
Push-Location $repoRoot
try {
    git config core.hooksPath $hooksPath
    Write-Host "Success: Set git core.hooksPath to '$hooksPath' in $repoRoot" -ForegroundColor Green
} finally {
    Pop-Location
}

