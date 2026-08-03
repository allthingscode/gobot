Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path variable:script:HeldBacklogLocks)) {
    $script:HeldBacklogLocks = @{}
}

function Get-BacklogLockFilePath {
    param([Parameter(Mandatory=$true)][string]$BacklogPath)

    $resolved = $BacklogPath
    if (Test-Path -LiteralPath $BacklogPath) {
        $resolved = (Resolve-Path -LiteralPath $BacklogPath).ProviderPath
    } else {
        $parent = Split-Path -Parent $BacklogPath
        if ($parent -and (Test-Path -LiteralPath $parent)) {
            $resolved = Join-Path (Resolve-Path -LiteralPath $parent).ProviderPath (Split-Path -Leaf $BacklogPath)
        }
    }
    return "$resolved.lock"
}

function Invoke-WithBacklogLock {
    param(
        [Parameter(Mandatory=$true)][string]$BacklogPath,
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 10,
        [int]$StaleLockAgeSeconds = 30
    )

    if ([string]::IsNullOrWhiteSpace($BacklogPath)) {
        throw "BacklogPath parameter cannot be empty."
    }

    $lockPath = Get-BacklogLockFilePath -BacklogPath $BacklogPath
    $normLockPath = $lockPath.ToLowerInvariant()

    # Process-local re-entrancy check
    if ($script:HeldBacklogLocks.ContainsKey($normLockPath) -and $script:HeldBacklogLocks[$normLockPath] -gt 0) {
        $script:HeldBacklogLocks[$normLockPath] = $script:HeldBacklogLocks[$normLockPath] + 1
        try {
            return & $ScriptBlock
        } finally {
            $script:HeldBacklogLocks[$normLockPath] = $script:HeldBacklogLocks[$normLockPath] - 1
            if ($script:HeldBacklogLocks[$normLockPath] -eq 0) {
                $script:HeldBacklogLocks.Remove($normLockPath)
            }
        }
    }

    $startTime = [System.DateTime]::UtcNow
    $acquired = $false

    while (([System.DateTime]::UtcNow - $startTime).TotalSeconds -lt $TimeoutSeconds) {
        try {
            # Try atomic file creation with FileAccess ReadWrite, FileShare None
            $fs = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $info = "$PID;$(Get-Date -Format 'o')"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($info)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Close()
            $fs.Dispose()
            $acquired = $true
            break
        } catch [System.IO.IOException] {
            # Lock file exists or is opened exclusively by another process. Check if stale.
            if (Test-Path -LiteralPath $lockPath) {
                $isStale = $false
                try {
                    $item = Get-Item -LiteralPath $lockPath -ErrorAction SilentlyContinue
                    if ($null -ne $item) {
                        $age = ([System.DateTime]::UtcNow - $item.LastWriteTimeUtc).TotalSeconds
                        if ($age -ge $StaleLockAgeSeconds) {
                            $isStale = $true
                        } else {
                            $content = [System.IO.File]::ReadAllText($lockPath)
                            if (-not [string]::IsNullOrWhiteSpace($content)) {
                                $parts = $content.Split(";")
                                $lockPid = 0
                                if ([int]::TryParse($parts[0], [ref]$lockPid)) {
                                    $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                                    if ($null -eq $proc) {
                                        $isStale = $true
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    # Ignore read failures if locked during active write
                }

                if ($isStale) {
                    try {
                        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
                    } catch {}
                    continue
                }
            }
            Start-Sleep -Milliseconds 100
        }
    }

    if (-not $acquired) {
        throw "Timed out waiting to acquire BACKLOG.md lock at $lockPath (timeout ${TimeoutSeconds}s)"
    }

    $script:HeldBacklogLocks[$normLockPath] = 1

    try {
        return & $ScriptBlock
    } finally {
        $script:HeldBacklogLocks.Remove($normLockPath)
        if (Test-Path -LiteralPath $lockPath) {
            try {
                Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
            } catch {}
        }
    }
}
