# Installs git hooks for the Crucible framework repository.
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -Path "$PSScriptRoot/..").Path
$destDir = Join-Path $repoRoot ".git/hooks"

if (-not (Test-Path -LiteralPath $destDir)) {
    throw "Not a git repository (missing .git directory)."
}

foreach ($hookName in "pre-commit", "pre-push") {
    $hookSource = Join-Path $repoRoot "scripts/hooks/$hookName"
    $hookDest = Join-Path $destDir $hookName
    
    if (-not (Test-Path -LiteralPath $hookSource)) {
        throw "Source hook script not found: $hookSource"
    }

    Copy-Item -LiteralPath $hookSource -Destination $hookDest -Force
    Write-Host "Success: Installed $hookName hook to $hookDest" -ForegroundColor Green
}
