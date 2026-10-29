if (-not (Get-Command Resolve-FilesystemPath -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "config-helpers.ps1") }

# The exclusive-handle file lock (I5), shared by crucible-lib.ps1 and scripts that do not load it,
# such as run-isolated-checks.ps1. Item 258.

function Invoke-FileLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [int]$TimeoutMs = 5000,
        [string]$TimeoutMessage = "[LOCK] Timeout reached; waiting for the exclusive lock holder."
    )

    $lockAcquired = $false
    $lockWaitTime = 0
    $totalWaitMs = 0
    $fileStream = $null
    while (-not $lockAcquired) {
        try {
            # The handle, rather than the file's name, is the lock. FileShare.None prevents
            # another process from opening it until this owner disposes the handle. DeleteOnClose
            # removes the path on both normal exit and process death, so no waiter ever needs to
            # guess whether a slow holder is stale or remove a lock owned by somebody else.
            # OpenOrCreate makes an orphaned pathname immediately acquirable:
            # a file without an open handle holds no lock.
            $fileStream = New-Object System.IO.FileStream(
                (Resolve-FilesystemPath -Path $LockPath),
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None,
                1,
                [System.IO.FileOptions]::DeleteOnClose
            )
            $lockAcquired = $true
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
                throw [System.IO.IOException]::new("Cannot acquire lock '$LockPath': " + $ioError.Message, $ioError)
            }
            if ($lockWaitTime -ge $TimeoutMs) {
                # The wait is deliberately unbounded: a crashed holder's handle is closed by the
                # OS and DeleteOnClose frees the path, so anything still held after this long is a
                # live holder that is stuck. That is worth waiting out rather than corrupting the
                # file, but it has to be diagnosable - name the lock and the elapsed wait, because
                # this message repeats forever and a bare one says nothing about which lock.
                $totalWaitMs += $lockWaitTime
                $waitMessage = $TimeoutMessage + " Lock: " + $LockPath + ". Waited " + [int]($totalWaitMs / 1000) + "s so far; a holder still present has not crashed, it is stuck."
                if (Get-Command Write-Quiet -ErrorAction SilentlyContinue) { Write-Quiet $waitMessage -ForegroundColor Yellow } else { Write-Host $waitMessage -ForegroundColor Yellow }
                $lockWaitTime = 0
            } else {
                Start-Sleep -Milliseconds 100
                $lockWaitTime += 100
            }
        }
    }

    try {
        & $ScriptBlock
    } finally {
        if ($null -ne $fileStream) {
            $fileStream.Dispose()
        }
    }
}
