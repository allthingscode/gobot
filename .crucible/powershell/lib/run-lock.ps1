# Deliberately does NOT call Set-StrictMode. The mode is scoped to the session, not to
# the file that sets it, so a dot-sourced library imposes it on every caller. See the
# comment at the top of lib/update-classification.ps1 for the failure that caused
# there. run-all-tests.ps1 sets the mode itself, so nothing is lost here.

if (-not (Get-Command "Get-NormalizedSha256" -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "normalized-hash.ps1")
}

# The lock is scoped to the runner's own repo root, NOT to the machine.
# run-all-tests-runner.tests.ps1 copies run-all-tests.ps1 into a dozen scratch roots
# and executes each one WHILE the outer suite is running, so a machine-wide lock
# would reject every one of those legitimate nested runs. Distinct roots hash to
# distinct lock files; two runs of the same checkout collide, which is the case the
# guard exists for.
#
# The lock lives in TEMP rather than in the repo: a lock file inside the tree would
# show up as an untracked path for the whole run, and the suite asserts on clean
# working trees.
function Get-RunLockPath {
    param([Parameter(Mandatory=$true)][string]$ScopeRoot)

    if ([string]::IsNullOrWhiteSpace($ScopeRoot)) {
        throw "ScopeRoot parameter cannot be empty."
    }

    $resolved = $ScopeRoot
    if (Test-Path -LiteralPath $ScopeRoot) {
        $resolved = (Resolve-Path -LiteralPath $ScopeRoot).ProviderPath
    }
    $resolved = $resolved.TrimEnd([char]'\', [char]'/')

    # Case-folded so two spellings of one path on Windows map to one lock.
    $hash = Get-NormalizedSha256 -Content ($resolved.Replace("\", "/").ToLowerInvariant())
    return (Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-run-all-tests-" + $hash.Substring(0, 16) + ".lock"))
}

# The holder record is a SEPARATE file from the lock, and that separation is load
# bearing rather than tidiness.
#
# The lock file is held open for the whole run, so anything that opens it competes
# with the holder's own handle. Windows and Unix disagree about who wins: .NET on
# Unix emulates FileShare with flock, and a holder that permits FileShare.Read takes
# LOCK_EX, so a reader asking for a shared lock is refused outright. Reading the
# record out of the lock file itself therefore works on Windows and fails on Linux.
# Keeping the record in a plain file nobody holds open removes the question.
function Get-RunLockOwnerPath {
    param([Parameter(Mandatory=$true)][string]$LockPath)
    return ($LockPath + ".owner")
}

# Reads whatever the current owner recorded about itself. This says nothing about
# whether the lock is still held - Test-RunLockHeld answers that. The record exists
# only so a refusal can name a process to go looking for.
function Get-RunLockHolder {
    param([Parameter(Mandatory=$true)][string]$LockPath)

    $ownerPath = Get-RunLockOwnerPath -LockPath $LockPath
    if (-not (Test-Path -LiteralPath $ownerPath)) {
        return $null
    }

    $content = $null
    try {
        $content = [System.IO.File]::ReadAllText($ownerPath)
    } catch {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }

    $parts = $content.Split(";")
    $holderPid = 0
    if (-not [int]::TryParse($parts[0], [ref]$holderPid)) {
        return $null
    }

    $started = "unknown"
    if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
        $started = $parts[1]
    }
    return [PSCustomObject]@{ ProcessId = $holderPid; Started = $started }
}

# True when a live process holds the lock.
#
# Decided by trying to take the file exclusively rather than by checking whether a
# recorded process id is still alive. An OS file handle cannot outlive the process
# that owns it, so a successful exclusive open proves nobody holds the lock no matter
# what the record says. That removes two failure modes the pid check had: a reused pid
# made an abandoned lock look live, and a run killed before it wrote its record left a
# file that could not be attributed at all.
function Test-RunLockHeld {
    param([Parameter(Mandatory=$true)][string]$LockPath)

    if (-not (Test-Path -LiteralPath $LockPath)) {
        return $false
    }

    try {
        $probe = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $probe.Close()
        $probe.Dispose()
        return $false
    } catch {
        # A sharing violation on Windows and an flock refusal on Unix surface as
        # different exception types; either one means somebody else has it.
        return $true
    }
}

# Acquires without waiting. A suite that silently queues behind another for an
# unknown duration is harder to diagnose than one that names the process holding
# the lock and exits.
#
# The returned Stream stays OPEN for the life of the run. That is the whole design:
# the operating system releases it when the process ends, however the process ends,
# so a killed run cannot leave a lock that still looks held.
function Enter-RunLock {
    param([Parameter(Mandatory=$true)][string]$ScopeRoot)

    $lockPath = Get-RunLockPath -ScopeRoot $ScopeRoot
    $ownerPath = Get-RunLockOwnerPath -LockPath $lockPath

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch {
            if (Test-RunLockHeld -LockPath $lockPath) {
                return [PSCustomObject]@{
                    Acquired = $false
                    LockPath = $lockPath
                    Holder   = (Get-RunLockHolder -LockPath $lockPath)
                    Stream   = $null
                }
            }
            # Nobody holds it, so the file outlived the run that made it. Reclaim both
            # halves and try once more.
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $ownerPath -Force -ErrorAction SilentlyContinue
            continue
        }

        # Written after the handle is held, so a record on disk always describes a
        # holder that actually got the lock.
        $info = "$PID;$(Get-Date -Format 'o')"
        [System.IO.File]::WriteAllText($ownerPath, $info, (New-Object System.Text.UTF8Encoding($false)))

        return [PSCustomObject]@{
            Acquired = $true
            LockPath = $lockPath
            Holder   = $null
            Stream   = $stream
        }
    }

    return [PSCustomObject]@{
        Acquired = $false
        LockPath = $lockPath
        Holder   = (Get-RunLockHolder -LockPath $lockPath)
        Stream   = $null
    }
}

# Takes the object Enter-RunLock returned rather than a bare path, because releasing
# now means closing a handle and not only deleting a file.
function Exit-RunLock {
    param([AllowNull()][object]$Lock)

    if ($null -eq $Lock) {
        return
    }

    if ($null -ne $Lock.Stream) {
        try {
            $Lock.Stream.Close()
            $Lock.Stream.Dispose()
        } catch {}
    }

    if ([string]::IsNullOrWhiteSpace($Lock.LockPath)) {
        return
    }
    Remove-Item -LiteralPath (Get-RunLockOwnerPath -LockPath $Lock.LockPath) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Lock.LockPath -Force -ErrorAction SilentlyContinue
}
