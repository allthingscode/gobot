param (
    [Parameter(Mandatory=$true)]
    [string]$TaskId,

    [Parameter(Mandatory=$false)]
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"

$factoryLibPath = Join-Path $PSScriptRoot "factory-lib.ps1"
if (-not (Test-Path -LiteralPath $factoryLibPath)) {
    throw "Required helper script not found at $factoryLibPath; your Crucible bundle is incomplete."
}
. $factoryLibPath

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $REPO_ROOT = (Get-Location).Path
} else {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) {
        Write-Host ("Error: -ProjectRoot path does not exist: " + $ProjectRoot) -ForegroundColor Red
        exit 1
    }
    $REPO_ROOT = (Resolve-Path -LiteralPath $ProjectRoot).Path
}

Write-Host "--- MERGE SIMULATION: $TaskId ---" -ForegroundColor Cyan

# 1. Verify branches
$mainBranch = "master"
git -C $REPO_ROOT show-ref --verify --quiet refs/heads/main
if ($LASTEXITCODE -eq 0) { $mainBranch = "main" }

# 1b. Verify task branch exists
git -C $REPO_ROOT show-ref --verify --quiet "refs/heads/task/$TaskId"
if ($LASTEXITCODE -ne 0) {
    Write-Host "No task branch (task/$TaskId) exists. Nothing to merge (No-Code Closure)." -ForegroundColor Green
    exit 0
}

$currentBranch = git -C $REPO_ROOT rev-parse --abbrev-ref HEAD
if ($currentBranch -ne $mainBranch) {
    Write-Host "Warning: Not on $mainBranch branch. Switching to $mainBranch..." -ForegroundColor Yellow
    git -C $REPO_ROOT checkout $mainBranch
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Could not checkout $mainBranch." -ForegroundColor Red
        exit 1
    }
}

# 2. Update main branch when a remote exists.
Write-Host "Updating $mainBranch..." -ForegroundColor Gray
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$originUrl = git -C $REPO_ROOT remote get-url origin 2>$null
$remoteExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousPreference
if ($remoteExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($originUrl)) {
    git -C $REPO_ROOT pull origin $mainBranch --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Could not pull origin/$mainBranch." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "No origin remote configured. Proceeding with local $mainBranch." -ForegroundColor Yellow
}

# 3. Simulate merge
Write-Host "Simulating merge from task/$TaskId..." -ForegroundColor Gray
# We use -no-commit and --no-ff to ensure we don't actually finish the merge.
# We want to see if it *can* merge cleanly.

$previousPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$mergeResult = git -C $REPO_ROOT merge --no-commit --no-ff "task/$TaskId"
$gitExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousPreference

if ($gitExitCode -ne 0) {
    Write-Host "!!! CONFLICT DETECTED !!!" -ForegroundColor Red
    
    $conflictingFiles = git -C $REPO_ROOT diff --name-only --diff-filter=U
    Write-Host "Conflicting files:" -ForegroundColor White
    $conflictingFiles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }

    # Generate conflict report
    $sessionDir = Get-ConfiguredPath -Key "session" -ProjectRoot $REPO_ROOT
    $reportDir = Join-Path $sessionDir $TaskId
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
    git -C $REPO_ROOT merge --abort
    exit 1
} else {
    Write-Host "CLEAN MERGE SIMULATED. No conflicts detected." -ForegroundColor Green
    # For a clean merge with --no-commit, we use reset --hard to return to clean state
    git -C $REPO_ROOT reset --hard HEAD --quiet
    exit 0
}
