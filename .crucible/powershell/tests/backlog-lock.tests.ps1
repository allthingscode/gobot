# Tests for BACKLOG.md mutual-exclusion locking (backlog-io.ps1).

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/backlog-io.ps1")

$results = @()
$shell = Get-PwshCommand

$results += Run-Test -Name "Invoke-WithBacklogLock acquires and removes lock file on completion" -Body {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("backlog-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $backlogFile = Join-Path $tempDir "BACKLOG.md"
        [System.IO.File]::WriteAllText($backlogFile, "Initial Content`n", [System.Text.UTF8Encoding]::new($false))
        $lockFile = Get-BacklogLockFilePath $backlogFile

        $script:lockExistedDuringExec = $false
        Invoke-WithBacklogLock -BacklogPath $backlogFile -ScriptBlock {
            $script:lockExistedDuringExec = Test-Path -LiteralPath $lockFile
        }

        Assert-Result -Name "Lock file existed during execution" -Condition $script:lockExistedDuringExec -FailureMessage "Expected lock file to exist during lock execution"
        Assert-Result -Name "Lock file removed after completion" -Condition (-not (Test-Path -LiteralPath $lockFile)) -FailureMessage "Expected lock file to be removed after execution"
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "Invoke-WithBacklogLock supports process-local re-entrancy" -Body {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("backlog-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $backlogFile = Join-Path $tempDir "BACKLOG.md"
        [System.IO.File]::WriteAllText($backlogFile, "Initial Content`n", [System.Text.UTF8Encoding]::new($false))
        $lockFile = Get-BacklogLockFilePath $backlogFile

        $script:innerExecuted = $false
        Invoke-WithBacklogLock -BacklogPath $backlogFile -ScriptBlock {
            Invoke-WithBacklogLock -BacklogPath $backlogFile -ScriptBlock {
                $script:innerExecuted = $true
            }
            Assert-Result -Name "Lock file remains during outer scope" -Condition (Test-Path -LiteralPath $lockFile) -FailureMessage "Expected lock file to exist during outer scope"
        }

        Assert-Result -Name "Inner re-entrant block executed" -Condition $script:innerExecuted -FailureMessage "Expected inner block to execute"
        Assert-Result -Name "Lock file removed after outer exit" -Condition (-not (Test-Path -LiteralPath $lockFile)) -FailureMessage "Expected lock file to be removed after outer exit"
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "Concurrent process writers serialize without losing edits" -Body {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("backlog-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $backlogFile = Join-Path $tempDir "BACKLOG.md"
        [System.IO.File]::WriteAllText($backlogFile, "LINE_START`n", [System.Text.UTF8Encoding]::new($false))
        $backlogIoPath = Join-Path $REPO_ROOT "powershell/lib/backlog-io.ps1"

        # Child script to simulate concurrent writer
        $scriptContent = @"
param([string]`$BacklogFile, [string]`$Tag, [string]`$BacklogIoPath)
. "`$BacklogIoPath"
Invoke-WithBacklogLock -BacklogPath `$BacklogFile -ScriptBlock {
    `$text = [System.IO.File]::ReadAllText(`$BacklogFile)
    Start-Sleep -Milliseconds 400
    [System.IO.File]::WriteAllText(`$BacklogFile, `$text + "`$Tag`n", [System.Text.UTF8Encoding]::new(`$false))
}
"@
        $writerScript = Join-Path $tempDir "writer.ps1"
        [System.IO.File]::WriteAllText($writerScript, $scriptContent, [System.Text.UTF8Encoding]::new($false))

        # Launch two child processes simultaneously
        $p1 = Start-Process -FilePath $shell -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$writerScript`"", "-BacklogFile", "`"$backlogFile`"", "-Tag", "WRITER_1", "-BacklogIoPath", "`"$backlogIoPath`"" -PassThru
        $p2 = Start-Process -FilePath $shell -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$writerScript`"", "-BacklogFile", "`"$backlogFile`"", "-Tag", "WRITER_2", "-BacklogIoPath", "`"$backlogIoPath`"" -PassThru

        $p1.WaitForExit()
        $p2.WaitForExit()

        Assert-Result -Name "Writer 1 exit code 0" -Condition ($p1.ExitCode -eq 0) -FailureMessage "Writer 1 failed with exit code $($p1.ExitCode)"
        Assert-Result -Name "Writer 2 exit code 0" -Condition ($p2.ExitCode -eq 0) -FailureMessage "Writer 2 failed with exit code $($p2.ExitCode)"

        $finalContent = [System.IO.File]::ReadAllText($backlogFile)
        $hasWriter1 = $finalContent.Contains("WRITER_1")
        $hasWriter2 = $finalContent.Contains("WRITER_2")

        Assert-Result -Name "Writer 1 edit preserved" -Condition $hasWriter1 -FailureMessage "WRITER_1 edit was lost"
        Assert-Result -Name "Writer 2 edit preserved" -Condition $hasWriter2 -FailureMessage "WRITER_2 edit was lost"
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "Stale lock file with non-existent PID is automatically recovered" -Body {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("backlog-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $backlogFile = Join-Path $tempDir "BACKLOG.md"
        [System.IO.File]::WriteAllText($backlogFile, "Initial Content`n", [System.Text.UTF8Encoding]::new($false))
        $lockFile = Get-BacklogLockFilePath $backlogFile

        # Create lock file with dead PID
        $deadPid = 99999
        [System.IO.File]::WriteAllText($lockFile, "$deadPid;2020-01-01T00:00:00Z", [System.Text.UTF8Encoding]::new($false))

        $script:executed = $false
        Invoke-WithBacklogLock -BacklogPath $backlogFile -ScriptBlock {
            $script:executed = $true
        } -StaleLockAgeSeconds 5

        Assert-Result -Name "Execution succeeded after stale lock recovery" -Condition $script:executed -FailureMessage "Expected lock acquisition after recovering stale lock"
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "Invoke-WithBacklogLock times out when lock held by active writer" -Body {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("backlog-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $backlogFile = Join-Path $tempDir "BACKLOG.md"
        [System.IO.File]::WriteAllText($backlogFile, "Initial Content`n", [System.Text.UTF8Encoding]::new($false))
        $lockFile = Get-BacklogLockFilePath $backlogFile

        # Create lock file with current PID
        [System.IO.File]::WriteAllText($lockFile, "$PID;$(Get-Date -Format 'o')", [System.Text.UTF8Encoding]::new($false))

        # Clear script-scoped held locks dictionary for this test block so it checks disk file
        $oldLocks = $script:HeldBacklogLocks
        $script:HeldBacklogLocks = @{}
        try {
            $timedOut = $false
            try {
                Invoke-WithBacklogLock -BacklogPath $backlogFile -TimeoutSeconds 1 -StaleLockAgeSeconds 600 -ScriptBlock {
                    Write-Host "Should not reach here"
                }
            } catch {
                if ($_.Exception.Message -like "*Timed out waiting to acquire BACKLOG.md lock*") {
                    $timedOut = $true
                }
            }
            Assert-Result -Name "Timed out waiting for active lock" -Condition $timedOut -FailureMessage "Expected timeout exception when lock file is active"
        } finally {
            $script:HeldBacklogLocks = $oldLocks
            Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($results -contains $false) {
    exit 1
} else {
    exit 0
}
