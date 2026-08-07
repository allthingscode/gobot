# Unit tests for update-session-state.ps1 stale-lock policy ({task_id}).
# Verifies AC1-3: stale lock auto-removed with [WARN], message includes path
# and age, and second-stale (genuine concurrent) still triggers timeout error.

$ErrorActionPreference = "Stop"

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
Set-StrictMode -Version Latest

$scriptUnderTest = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) "update-session-state.ps1"
if (-not (Test-Path -LiteralPath $scriptUnderTest)) {
    throw "Missing script under test: $scriptUnderTest"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-stale-lock-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$LockFile = Join-Path $tempRoot ".crucible/session/global/session_state.lock"
$StateFile = Join-Path $tempRoot ".crucible/session/global/session_state.json"
$StateBackup = Join-Path $tempRoot ".crucible/session/global/session_state.c223-test-backup.json"
$TaskId = "{task_id}"

# Ensure lock directory exists
New-Item -ItemType Directory -Path (Split-Path -Parent $LockFile) -Force | Out-Null

function Backup-State {
    if (Test-Path -LiteralPath $StateFile) {
        Copy-Item -LiteralPath $StateFile -Destination $StateBackup -Force
    }
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
}

function Restore-State {
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $StateBackup) {
        Move-Item -LiteralPath $StateBackup -Destination $StateFile -Force
    }
}

$payloadFile = Join-Path ([System.IO.Path]::GetTempPath()) ("c223-locktest-" + [guid]::NewGuid().ToString("N") + ".json")
'{"status":"locktest"}' | Out-File -LiteralPath $payloadFile -Encoding UTF8

function Invoke-ScriptUnderTest {
    $args = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $scriptUnderTest,
        "-Specialist", "implementation",
        "-TaskId", $TaskId,
        "-UpdateJsonFile", $payloadFile,
        "-ProjectRoot", $tempRoot
    )
    # Wrap in try so a non-zero exit doesn't trip $ErrorActionPreference=Stop in the
    # parent harness. We assert exit codes explicitly in each test.
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & (Get-PwshCommand) @args 2>&1
        $exit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevPref
    }
    # Explicitly stringify each element (WarningRecord, ErrorRecord, etc.)
    # so console-formatting artifacts don't leak into the joined text.
    $stringified = @($output | ForEach-Object { "$_" })
    return @{ Output = ($stringified -join "`n"); ExitCode = $exit }
}

$results = @()

function Assert-True {
    param([string]$Name, [bool]$Cond, [string]$Detail)
    if ($Cond) {
        Write-Host "PASS: $Name" -ForegroundColor Green
        $script:results += $true
    } else {
        Write-Host "FAIL: $Name -- $Detail" -ForegroundColor Red
        $script:results += $false
    }
}

Backup-State
try {
    Write-Host "`nTest 1: Stale lock (>2 min) is auto-removed with [WARN]" -ForegroundColor Cyan
    Set-Content -LiteralPath $LockFile -Value "999999" -Encoding UTF8
    $stale = (Get-Date).AddMinutes(-5)
    (Get-Item -LiteralPath $LockFile).LastWriteTime = $stale
    $r1 = Invoke-ScriptUnderTest
    Assert-True -Name "exit code 0 after stale recovery" -Cond ($r1.ExitCode -eq 0) -Detail ("got " + $r1.ExitCode + " :: " + $r1.Output)
    Assert-True -Name "warning emitted with [WARN] tag" -Cond ($r1.Output -match "\[WARN\]") -Detail $r1.Output
    $flatOutput = [regex]::Replace($r1.Output, '[\r\n\t ]+', '')
    $flatPath   = [regex]::Replace($LockFile,   '[\r\n\t ]+', '')
    Assert-True -Name "warning includes lock file path" -Cond ($flatOutput.Contains($flatPath)) -Detail $r1.Output
    Assert-True -Name "warning includes age in seconds" -Cond ($r1.Output -match "age \d+s") -Detail $r1.Output
    Assert-True -Name "lock file released after success" -Cond (-not (Test-Path -LiteralPath $LockFile)) -Detail "lock still present"

    Write-Host "`nTest 2: Fresh lock (<2 min) causes timeout error" -ForegroundColor Cyan
    Set-Content -LiteralPath $LockFile -Value "888888" -Encoding UTF8
    # LastWriteTime is "now" by default - well within 2-minute threshold.
    $r2 = Invoke-ScriptUnderTest
    Assert-True -Name "exit code 1 on fresh-lock timeout" -Cond ($r2.ExitCode -eq 1) -Detail ("got " + $r2.ExitCode + " :: " + $r2.Output)
    Assert-True -Name "no [WARN] auto-removal for fresh lock" -Cond ($r2.Output -notmatch "Auto-removing") -Detail $r2.Output
    Assert-True -Name "fresh lock not deleted by script" -Cond (Test-Path -LiteralPath $LockFile) -Detail "fresh lock was unexpectedly removed"
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue

    Write-Host "`nTest 3: Normal acquisition (no lock present)" -ForegroundColor Cyan
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    $r3 = Invoke-ScriptUnderTest
    Assert-True -Name "exit code 0 with no contention" -Cond ($r3.ExitCode -eq 0) -Detail ("got " + $r3.ExitCode + " :: " + $r3.Output)
    Assert-True -Name "no warning when lock absent" -Cond ($r3.Output -notmatch "\[WARN\] Stale lock") -Detail $r3.Output
}
finally {
    Restore-State
    Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

$failed = $results -contains $false
if ($failed) {
    Write-Host "`nSOME TESTS FAILED ($($results.Count) total)" -ForegroundColor Red
    exit 1
}
Write-Host "`nALL TESTS PASSED ($($results.Count) total)" -ForegroundColor Green
exit 0
