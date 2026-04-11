param (
    [Parameter(Mandatory=$true)]
    [string]$TaskId
)

$ErrorActionPreference = "Stop"

Write-Host "--- MERGE SIMULATION: $TaskId ---" -ForegroundColor Cyan

# 1. Verify branches
$currentBranch = git rev-parse --abbrev-ref HEAD
if ($currentBranch -ne "master") {
    Write-Host "Warning: Not on master branch. Switching to master..." -ForegroundColor Yellow
    git checkout master
}

# 2. Update master
Write-Host "Updating master..." -ForegroundColor Gray
# Note: we assume 'origin' exists and is reachable. 
# If not, this might fail, but in local dev it might just be a no-op if no remote.
try {
    git pull origin master --quiet
} catch {
    Write-Host "Warning: Could not pull from origin. Proceeding with local master." -ForegroundColor Yellow
}

# 3. Simulate merge
Write-Host "Simulating merge from task/$TaskId..." -ForegroundColor Gray
# We use -no-commit and --no-ff to ensure we don't actually finish the merge.
# We want to see if it *can* merge cleanly.

$previousPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$mergeResult = git merge --no-commit --no-ff "task/$TaskId"
$gitExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousPreference

if ($gitExitCode -ne 0) {
    Write-Host "!!! CONFLICT DETECTED !!!" -ForegroundColor Red
    
    $conflictingFiles = git diff --name-only --diff-filter=U
    Write-Host "Conflicting files:" -ForegroundColor White
    $conflictingFiles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }

    # Generate conflict report
    $reportDir = ".private/session/$TaskId"
    if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Force -Path $reportDir | Out-Null }
    
    $report = [ordered]@{
        task_id = $TaskId
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        conflicting_files = $conflictingFiles
        summary = "Automatic merge simulation failed. Manual rebase required."
    }
    
    $reportFile = Join-Path $reportDir "conflict_report.json"
    $report | ConvertTo-Json | Set-Content -Path $reportFile -Encoding UTF8
    Write-Host "Report written to $reportFile" -ForegroundColor Gray

    # Abort the merge to return to clean state
    git merge --abort
    exit 1
} else {
    Write-Host "CLEAN MERGE SIMULATED. No conflicts detected." -ForegroundColor Green
    # For a clean merge with --no-commit, we use reset --hard to return to clean state
    git reset --hard HEAD --quiet
    exit 0
}
