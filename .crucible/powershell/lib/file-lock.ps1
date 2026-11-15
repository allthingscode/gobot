if (-not (Test-Path -LiteralPath Function:Resolve-FilesystemPath)) { . (Join-Path $PSScriptRoot "config-helpers.ps1") }

# The exclusive-handle file lock (I5), shared by crucible-lib.ps1 and scripts that do not load it,
# such as run-isolated-checks.ps1. Item 258.

# On Unix, FileShare.None is a flock on the opened inode and DeleteOnClose unlinks the path
# when the owner closes, so a waiter that opened the old inode can lock it after the unlink
# while a new owner holds the recreated path. From .NET 7 the runtime rechecks, after locking
# an OpenOrCreate DeleteOnClose handle, that the path still names the locked inode, and
# reopens when it does not; .NET 6 does not. Windows enforces the share mode on the path.
# Supported: PowerShell 7.4 (.NET 8); refused: below .NET 7 on Linux or macOS. Item 260.
function Assert-FileLockRuntime {
    param(
        [version]$RuntimeVersion = [System.Environment]::Version,
        [bool]$OnWindows = $IsWindows
    )
    if (-not $OnWindows -and $RuntimeVersion.Major -lt 7) {
        throw [System.PlatformNotSupportedException]::new("Exclusive file locks on Linux and macOS need .NET 7 or later, which checks that a DeleteOnClose lock still owns its path; this PowerShell runs on .NET " + $RuntimeVersion + ". Install PowerShell 7.4 or later.")
    }
}

# One attempt at the lock: the open handle, or $null while another holder has it. A failure
# that waiting cannot clear throws, naming the lock as $Description. Every DeleteOnClose lock
# opens through here, so the runtime floor and the recheck's preconditions have one owner.
function Open-FileLockHandle {
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [string]$Description = ""
    )

    Assert-FileLockRuntime
    if ([string]::IsNullOrEmpty($Description)) { $Description = "lock '$LockPath'" }
    try {
        # The handle, rather than the file's name, is the lock. FileShare.None prevents
        # another process from opening it until this owner disposes the handle. DeleteOnClose
        # removes the path when the owner closes it, so no waiter ever needs to guess whether
        # a slow holder is stale or remove a lock owned by somebody else. OpenOrCreate makes
        # an orphaned pathname, such as one a dead holder left on Unix, immediately acquirable:
        # a file without an open handle holds no lock. The runtime's inode recheck applies
        # only to this exact mode, share and option.
        return New-Object System.IO.FileStream(
            (Resolve-FilesystemPath -Path $LockPath),
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None,
            1,
            [System.IO.FileOptions]::DeleteOnClose
        )
    } catch [System.IO.IOException] {
        # .NET wraps native sharing/lock violations as IOExceptions. Other IO
        # failures (missing directory, full disk, bad path) cannot be waited out.
        $ioError = $_.Exception
        while ($null -ne $ioError.InnerException) { $ioError = $ioError.InnerException }
        $nativeCode = $ioError.HResult -band 0xFFFF
        # FileStream's Unix flock failure carries EWOULDBLOCK directly:
        # EAGAIN (11) on Linux, EWOULDBLOCK (35) on macOS.
        $isContention = ($IsWindows -and $nativeCode -in @(32, 33)) -or
            ($IsLinux -and $nativeCode -eq 11) -or ($IsMacOS -and $nativeCode -eq 35)
        if (-not $isContention) {
            throw [System.IO.IOException]::new("Cannot acquire " + $Description + ": " + $ioError.Message, $ioError)
        }
        return $null
    }
}

function Invoke-FileLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [int]$TimeoutMs = 5000,
        [string]$TimeoutMessage = "[LOCK] Timeout reached; waiting for the exclusive lock holder."
    )

    $lockWaitTime = 0
    $totalWaitMs = 0
    $fileStream = $null
    while ($null -eq ($fileStream = Open-FileLockHandle -LockPath $LockPath)) {
        if ($lockWaitTime -ge $TimeoutMs) {
            # The wait is deliberately unbounded: a crashed holder's handle is closed by the
            # OS, which frees the lock, so anything still held after this long is a live holder
            # that is stuck. That is worth waiting out rather than corrupting the
            # file, but it has to be diagnosable - name the lock and the elapsed wait, because
            # this message repeats forever and a bare one says nothing about which lock.
            $totalWaitMs += $lockWaitTime
            $waitMessage = $TimeoutMessage + " Lock: " + $LockPath + ". Waited " + [int]($totalWaitMs / 1000) + "s so far; a holder still present has not crashed, it is stuck."
            if (Test-Path -LiteralPath Function:Write-Quiet) { Write-Quiet $waitMessage -ForegroundColor Yellow } else { Write-Host $waitMessage -ForegroundColor Yellow }
            $lockWaitTime = 0
        } else {
            Start-Sleep -Milliseconds 100
            $lockWaitTime += 100
        }
    }

    try {
        & $ScriptBlock
    } finally {
        $fileStream.Dispose()
    }
}
