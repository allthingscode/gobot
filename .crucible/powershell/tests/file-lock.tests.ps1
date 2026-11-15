# Tests for lib/file-lock.ps1: the exclusive-handle lock's runtime floor and its exclusion
# under contention. Item 260.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$FILE_LOCK = Join-Path $REPO_ROOT "powershell/lib/file-lock.ps1"
. $FILE_LOCK
. (Join-Path $REPO_ROOT "powershell/lib/backlog-io.ps1")

$results = @()
$utf8 = [System.Text.UTF8Encoding]::new($false)

$results += Run-Test -Name "The runtime floor refuses .NET 6 on Linux and macOS and admits .NET 7 and later" -Body {
    $message = $null
    $type = $null
    try { Assert-FileLockRuntime -RuntimeVersion ([version]"6.0.36") -OnWindows $false } catch { $message = $_.Exception.Message; $type = $_.Exception.GetType().FullName }
    Assert-Result -Name ".NET 6 on Unix is refused" -Condition ($type -eq "System.PlatformNotSupportedException") -FailureMessage ("got " + [string]$type + ": " + [string]$message)
    Assert-Result -Name "the refusal names the runtime and the supported PowerShell" -Condition ($null -ne $message -and $message.Contains(".NET 6.0.36") -and $message.Contains("PowerShell 7.4")) -FailureMessage ([string]$message)
    foreach ($admitted in @("7.0.0", "8.0.0", "10.0.0")) {
        Assert-FileLockRuntime -RuntimeVersion ([version]$admitted) -OnWindows $false
    }
    # Windows enforces FileShare.None on the path, so no runtime recheck is needed there.
    Assert-FileLockRuntime -RuntimeVersion ([version]"6.0.36") -OnWindows $true
    Assert-FileLockRuntime
    Assert-Result -Name "admitted runtimes pass" -Condition $true -FailureMessage "unreachable"
}

# Both DeleteOnClose locks open through Open-FileLockHandle, which asks first: a lock taken on
# .NET 6 is not exclusive.
foreach ($lockName in @("Invoke-FileLock", "Invoke-WithBacklogLock")) {
    $results += Run-Test -Name ("$lockName refuses an old Unix runtime before it opens the lock") -Body {
        $tempDir = New-TestFixtureRoot -NameHint "file-lock-floor"
        $realCheck = ${function:Assert-FileLockRuntime}
        try {
            $target = Join-Path $tempDir "BACKLOG.md"
            [System.IO.File]::WriteAllText($target, "x`n", $utf8)
            $lockPath = if ($lockName -eq "Invoke-FileLock") { $target + ".lock" } else { Get-BacklogLockFilePath -BacklogPath $target }
            ${function:script:Assert-FileLockRuntime} = { & $realCheck -RuntimeVersion ([version]"6.0.36") -OnWindows $false }.GetNewClosure()
            $script:floorBodyRan = $false
            $message = $null
            try {
                if ($lockName -eq "Invoke-FileLock") {
                    Invoke-FileLock -LockPath $lockPath -TimeoutMs 200 -ScriptBlock { $script:floorBodyRan = $true }
                } else {
                    Invoke-WithBacklogLock -BacklogPath $target -TimeoutSeconds 1 -ScriptBlock { $script:floorBodyRan = $true }
                }
            } catch { $message = $_.Exception.Message }
            Assert-Result -Name "the lock is refused" -Condition ($null -ne $message -and $message.Contains(".NET 6.0.36")) -FailureMessage ([string]$message)
            Assert-Result -Name "the protected body does not run" -Condition (-not $script:floorBodyRan) -FailureMessage "the body ran under a refused runtime"
            Assert-Result -Name "no lock file is opened" -Condition (-not (Test-Path -LiteralPath $lockPath)) -FailureMessage ("lock opened at " + $lockPath)
        } finally {
            ${function:script:Assert-FileLockRuntime} = $realCheck
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Contenders retry Open-FileLockHandle back to back, without Invoke-FileLock's 100 ms backoff,
# and each holder claims an occupancy marker with CreateNew, so two holders at once is an
# observed collision rather than an inference. On Linux this is the .NET 6 race: a waiter that
# opened the old inode locks it after the owner's unlink while a new owner holds the recreated
# path. With FileMode.Create in the opener, which the runtime does not recheck, WSL on .NET 10
# collided 6 to 15 times in each of five runs; the opener's OpenOrCreate never did.
$results += Run-Test -Name "Contending processes never hold the lock at the same time" -Body {
    # Windows enforces the share mode on the path, so there is no inode recheck to exercise, and
    # back-to-back retries there meet a closing lock as access denied (item 380).
    if (Test-PlatformIsWindows) { Skip-Test "the inode recheck is Unix-only; Windows retries without backoff hit item 380" }
    $tempDir = New-TestFixtureRoot -NameHint "file-lock-contention"
    $workers = @()
    try {
        $lockPath = Join-Path $tempDir "shared.lock"
        $marker = Join-Path $tempDir "occupied"
        $go = Join-Path $tempDir "go"
        $workerPath = Join-Path $tempDir "contender.ps1"
        $workerText = @(
            'param([string]$FileLock, [string]$LockPath, [string]$Marker, [string]$Go, [string]$ReadyPath, [string]$ResultPath, [int]$DurationMs)',
            '$ErrorActionPreference = "Stop"',
            '. $FileLock',
            '[System.IO.File]::WriteAllText($ReadyPath, "$PID")',
            'while (-not (Test-Path -LiteralPath $Go)) { Start-Sleep -Milliseconds 10 }',
            '$acquired = 0',
            '$collisions = 0',
            '$clock = [System.Diagnostics.Stopwatch]::StartNew()',
            'while ($clock.ElapsedMilliseconds -lt $DurationMs) {',
            '    $handle = Open-FileLockHandle -LockPath $LockPath',
            '    if ($null -eq $handle) { continue }',
            '    $acquired++',
            '    try {',
            '        $claim = [System.IO.File]::Open($Marker, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)',
            '        $claim.Dispose()',
            '        [System.IO.File]::Delete($Marker)',
            '    } catch [System.IO.IOException] {',
            '        $collisions++',
            '    }',
            '    $handle.Dispose()',
            '}',
            '[System.IO.File]::WriteAllText($ResultPath, "$acquired $collisions")'
        ) -join "`n"
        [System.IO.File]::WriteAllText($workerPath, $workerText + "`n", $utf8)

        $count = 6
        for ($n = 0; $n -lt $count; $n++) {
            $ready = Join-Path $tempDir "ready-$n"
            $result = Join-Path $tempDir "result-$n"
            $workers += [pscustomobject]@{
                Ready = $ready; Result = $result
                Process = Start-HiddenHostProcess -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$workerPath`"", "-FileLock", "`"$FILE_LOCK`"", "-LockPath", "`"$lockPath`"", "-Marker", "`"$marker`"", "-Go", "`"$go`"", "-ReadyPath", "`"$ready`"", "-ResultPath", "`"$result`"", "-DurationMs", "4000")
            }
        }
        # Generous: pwsh startup alone can exceed 5s on a loaded parallel run.
        $deadline = (Get-Date).AddSeconds(60)
        while (@($workers | Where-Object { -not (Test-Path -LiteralPath $_.Ready) }).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Assert-Result -Name "every contender started" -Condition (@($workers | Where-Object { -not (Test-Path -LiteralPath $_.Ready) }).Count -eq 0) -FailureMessage "a contender did not start within 60 seconds"
        [System.IO.File]::WriteAllText($go, "go", $utf8)
        foreach ($worker in $workers) {
            if (-not $worker.Process.WaitForExit(120000)) { throw "a contender did not finish within 120 seconds" }
        }
        $acquired = 0
        $collisions = 0
        foreach ($worker in $workers) {
            Assert-Result -Name "contender exits successfully" -Condition ($worker.Process.ExitCode -eq 0 -and (Test-Path -LiteralPath $worker.Result)) -FailureMessage ("exit " + $worker.Process.ExitCode)
            $fields = ([System.IO.File]::ReadAllText($worker.Result)).Split(" ")
            $acquired += [int]$fields[0]
            $collisions += [int]$fields[1]
        }
        Assert-Result -Name "the lock changed hands under contention" -Condition ($acquired -ge $count) -FailureMessage ("only $acquired acquisitions")
        Assert-Result -Name "no two holders overlapped" -Condition ($collisions -eq 0) -FailureMessage ("$collisions overlapping holders in $acquired acquisitions across $count contenders on " + [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)
    } finally {
        foreach ($worker in $workers) { if (-not $worker.Process.HasExited) { Stop-Process -Id $worker.Process.Id -Force -ErrorAction SilentlyContinue } }
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-TestFileSummary -Results $results
