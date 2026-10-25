param (
    [Parameter(Mandatory=$true)]
    [string]$TaskId,

    [Parameter(Mandatory=$false)]
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"

$crucibleLibPath = Join-Path $PSScriptRoot "crucible-lib.ps1"
if (-not (Test-Path -LiteralPath $crucibleLibPath)) {
    throw "Required helper script not found at $crucibleLibPath; your Crucible bundle is incomplete."
}
. $crucibleLibPath

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $REPO_ROOT = Resolve-ConfigProjectRoot
} else {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) {
        Write-Host ("Error: -ProjectRoot path does not exist: " + $ProjectRoot) -ForegroundColor Red
        exit 1
    }
    $REPO_ROOT = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
}
# Native git cannot use a PowerShell drive alias, including one selected by the CWD.
$REPO_ROOT = Resolve-FilesystemPath -Path $REPO_ROOT

Write-Host "--- MERGE SIMULATION: $TaskId ---" -ForegroundColor Cyan

# 1. A quiet exit 1 is only a candidate missing task ref. Repository/launch failures
# must refuse (I11), even when an embedding caller catches exceptions.
$previousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = $null
    $taskRefOutput = @(Invoke-GitChecked {
        git -C $REPO_ROOT show-ref --verify --quiet "refs/heads/task/$TaskId"
    } 2>&1)
    $taskRefExitCode = $LASTEXITCODE
    $taskRefMissing = ($taskRefExitCode -eq 1 -and $taskRefOutput.Count -eq 0)
    if ($taskRefMissing) {
        # --verify --quiet also returns a silent 1 for a malformed loose ref.
        # Probe only this task ref: unrelated broken refs must not prevent closure.
        # The scoped probe diagnoses corruption; an absent ref is still a silent 1.
        $global:LASTEXITCODE = $null
        $taskRefOutput = @(Invoke-GitChecked {
            git -C $REPO_ROOT show-ref --quiet "refs/heads/task/$TaskId"
        } 2>&1)
        $taskRefExitCode = $LASTEXITCODE
        $taskRefMissing = ($taskRefExitCode -eq 1 -and $taskRefOutput.Count -eq 0)
    }
} catch {
    Write-Host ("Error: Could not query task branch: " + $_.Exception.Message) -ForegroundColor Red
    exit 2
} finally {
    $ErrorActionPreference = $previousPreference
}
if (-not $taskRefMissing -and ($null -eq $taskRefExitCode -or $taskRefExitCode -ne 0 -or $taskRefOutput.Count -gt 0)) {
    Write-Host ("Error: Could not query task branch (git show-ref exit " + $taskRefExitCode + "): " + ($taskRefOutput -join "`n")) -ForegroundColor Red
    exit 2
}
# Validate configuration before No-Code Closure; an outer catch must not bypass it (I11).
try {
    $mainBranch = Get-ConfiguredPrimaryBranch -ProjectRoot $REPO_ROOT
} catch {
    Write-Host ("Error: Could not resolve primary branch: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
if ($taskRefMissing) {
    Write-Host "No task branch (task/$TaskId) exists. Nothing to merge (No-Code Closure)." -ForegroundColor Green
    exit 0
}

# The simulation merges into this checkout and then undoes the merge. Undoing a merge cannot
# safely separate it from edits that were already there, so refuse to start over any. Untracked
# files are untouched by both the merge and its abort. Exit 2 means "not run", never a
# conflict, so the Operator does not send the task back for a rebase. Item 179.
$null = Test-GitDiscardSafe -Directory $REPO_ROOT -Operation "merge simulation and abort" -IncludeUntracked:$false -Refuse

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
        timestamp = Get-UtcTimestamp
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
    # An already-merged branch leaves no merge in progress, so there is nothing to abort.
    git -C $REPO_ROOT rev-parse -q --verify MERGE_HEAD *> $null
    if ($LASTEXITCODE -eq 0) {
        git -C $REPO_ROOT merge --abort
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error: could not abort the simulated merge; run 'git merge --abort' in $REPO_ROOT." -ForegroundColor Red
            exit 2
        }
    }
    exit 0
}
