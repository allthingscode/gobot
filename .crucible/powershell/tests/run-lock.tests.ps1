# Tests for powershell/lib/run-lock.ps1 and the concurrency guard it gives
# run-all-tests.ps1. Two concurrent runs against one checkout destroy each other's
# fixtures; these assert that the second one is refused rather than allowed to.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/run-lock.ps1")
. (Join-Path $PSScriptRoot "_fixtures.ps1")

$RUNNER_SCRIPT = Join-Path $REPO_ROOT "powershell/run-all-tests.ps1"
$HARNESS_SCRIPT = Join-Path $PSScriptRoot "_harness.ps1"

$results = @()

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-run-lock-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-ScratchRoot {
    param([string]$Name)
    $dir = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return (Resolve-Path -LiteralPath $dir).ProviderPath
}

# A PID no live process owns. Probing beats picking a constant: a hard-coded id can
# be in use, which would turn the orphan-reclaim test into a false pass.
function Get-DeadProcessId {
    for ($candidate = 999999; $candidate -gt 900000; $candidate -= 7) {
        if ($null -eq (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) {
            return $candidate
        }
    }
    throw "Could not find an unused process id."
}

function New-RunnerScratch {
    param([string]$Name)

    $scratchDir = New-ScratchRoot -Name $Name
    $powershellDir = Join-Path $scratchDir "powershell"
    $testsDir = Join-Path $powershellDir "tests"
    $libDir = Join-Path $powershellDir "lib"
    New-Item -ItemType Directory -Path $testsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $libDir -Force | Out-Null

    Copy-Item -LiteralPath $RUNNER_SCRIPT -Destination (Join-Path $powershellDir "run-all-tests.ps1") -Force
    Copy-Item -LiteralPath $HARNESS_SCRIPT -Destination (Join-Path $testsDir "_harness.ps1") -Force
    foreach ($lib in @("run-lock.ps1", "normalized-hash.ps1")) {
        Copy-Item -LiteralPath (Join-Path $REPO_ROOT "powershell/lib/$lib") -Destination (Join-Path $libDir $lib) -Force
    }
    # The scratch runner reaps run roots for real, and that is safe: collection is by
    # dead owner, so the outer suite's root - owned by a live process - is never a
    # candidate. The stub only stands in for the fixture build, which needs the whole
    # framework the scratch root does not have.
    $fixturesStub = @'
function Get-SharedAdopterFixture { return $null }
'@
    Set-Content -LiteralPath (Join-Path $testsDir "_fixtures.ps1") -Value $fixturesStub -Encoding UTF8

    $syntheticContent = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
Write-Host "ALL TESTS PASSED (1 tests)"
exit 0
'@
    Set-Content -LiteralPath (Join-Path $testsDir "synthetic.tests.ps1") -Value $syntheticContent -Encoding UTF8

    return $powershellDir
}

try {
    $results += Run-Test -Name "Distinct scope roots take distinct locks" -Body {
        $a = New-ScratchRoot -Name "scope-a"
        $b = New-ScratchRoot -Name "scope-b"

        $pathA = Get-RunLockPath -ScopeRoot $a
        $pathB = Get-RunLockPath -ScopeRoot $b

        Assert-Result -Name "distinct lock paths" -Condition ($pathA -ne $pathB) -FailureMessage ("expected different lock paths, both were " + $pathA)
    }

    # The nested runner copies in run-all-tests-runner.tests.ps1 depend on this: they
    # execute inside the outer suite, and a machine-wide lock would reject all of them.
    $results += Run-Test -Name "Lock path does not depend on trailing separator or case" -Body {
        $root = New-ScratchRoot -Name "scope-spelling"

        $plain = Get-RunLockPath -ScopeRoot $root
        $trailing = Get-RunLockPath -ScopeRoot ($root + [System.IO.Path]::DirectorySeparatorChar)
        $upper = Get-RunLockPath -ScopeRoot $root.ToUpperInvariant()

        Assert-Result -Name "trailing separator" -Condition ($plain -eq $trailing) -FailureMessage ("expected " + $plain + ", got " + $trailing)
        Assert-Result -Name "case folded" -Condition ($plain -eq $upper) -FailureMessage ("expected " + $plain + ", got " + $upper)
    }

    $results += Run-Test -Name "Second acquisition is refused and names the live holder" -Body {
        $root = New-ScratchRoot -Name "second-acquire"

        $first = Enter-RunLock -ScopeRoot $root
        try {
            Assert-Result -Name "first acquires" -Condition $first.Acquired -FailureMessage "expected the first acquisition to succeed"

            $second = Enter-RunLock -ScopeRoot $root
            Assert-Result -Name "second refused" -Condition (-not $second.Acquired) -FailureMessage "expected the second acquisition to be refused"
            Assert-Result -Name "holder identified" -Condition ($null -ne $second.Holder) -FailureMessage "expected the refusal to carry a holder"
            Assert-Result -Name "holder pid" -Condition ($second.Holder.ProcessId -eq $PID) -FailureMessage ("expected holder pid " + $PID + ", got " + $second.Holder.ProcessId)
        } finally {
            Exit-RunLock -Lock $first
        }
    }

    $results += Run-Test -Name "Releasing the lock lets the next run acquire it" -Body {
        $root = New-ScratchRoot -Name "release"

        $first = Enter-RunLock -ScopeRoot $root
        Assert-Result -Name "first acquires" -Condition $first.Acquired -FailureMessage "expected the first acquisition to succeed"
        Exit-RunLock -Lock $first

        Assert-Result -Name "lock file removed" -Condition (-not (Test-Path -LiteralPath $first.LockPath)) -FailureMessage ("expected " + $first.LockPath + " to be gone")

        $second = Enter-RunLock -ScopeRoot $root
        try {
            Assert-Result -Name "second acquires" -Condition $second.Acquired -FailureMessage "expected the second acquisition to succeed after release"
        } finally {
            Exit-RunLock -Lock $second
        }
    }

    # A run killed mid-suite leaves its lock file behind. Without reclaim the checkout
    # is wedged until someone deletes a file in TEMP they have no reason to know about.
    #
    # The file on disk is all a killed run can leave: the OS closed its handle when it
    # died. So the fixture writes the lock WITHOUT holding it, which is exactly the
    # state a kill produces, and reclaim no longer depends on what pid is recorded.
    $results += Run-Test -Name "A lock file nobody holds is reclaimed" -Body {
        $root = New-ScratchRoot -Name "orphan"
        $lockPath = Get-RunLockPath -ScopeRoot $root

        [System.IO.File]::WriteAllText($lockPath, ("$PID;" + (Get-Date -Format 'o')), (New-Object System.Text.UTF8Encoding($false)))

        Assert-Result -Name "unheld lock is not held" -Condition (-not (Test-RunLockHeld -LockPath $lockPath)) -FailureMessage "expected a lock file with no open handle to report unheld"

        # Recording this process - which is alive - proves the point: under the old
        # pid-liveness rule this lock would have looked live and wedged the checkout.
        $lock = Enter-RunLock -ScopeRoot $root
        try {
            Assert-Result -Name "orphan reclaimed" -Condition $lock.Acquired -FailureMessage "expected the orphaned lock to be reclaimed"
        } finally {
            Exit-RunLock -Lock $lock
        }
    }

    # An age threshold would be wrong here even though backlog-io.ps1 uses one: a full
    # suite run legitimately holds this lock for far longer than any useful threshold.
    $results += Run-Test -Name "A long-held lock is not treated as stale" -Body {
        $root = New-ScratchRoot -Name "long-held"

        # Acquired for real rather than faked on disk, because holding the handle IS
        # what makes a lock live now. Backdating the file has to leave that untouched.
        $lock = Enter-RunLock -ScopeRoot $root
        try {
            Assert-Result -Name "first acquires" -Condition $lock.Acquired -FailureMessage "expected the acquisition to succeed"
            [System.IO.File]::SetLastWriteTimeUtc((Get-RunLockOwnerPath -LockPath $lock.LockPath), ([System.DateTime]::UtcNow.AddHours(-3)))

            Assert-Result -Name "still held" -Condition (Test-RunLockHeld -LockPath $lock.LockPath) -FailureMessage "expected a three-hour-old lock that is still open to report held"
            Assert-Result -Name "refused" -Condition (-not (Enter-RunLock -ScopeRoot $root).Acquired) -FailureMessage "expected acquisition to be refused while the holder is alive"
        } finally {
            Exit-RunLock -Lock $lock
        }
    }

    # The record is a diagnostic, so it has to survive being read while the lock is
    # held. It lives beside the lock rather than inside it precisely because a reader
    # cannot open the held file on both platforms.
    $results += Run-Test -Name "The holder record is readable while the lock is held" -Body {
        $root = New-ScratchRoot -Name "record-readable"

        $lock = Enter-RunLock -ScopeRoot $root
        try {
            $holder = Get-RunLockHolder -LockPath $lock.LockPath
            Assert-Result -Name "record present" -Condition ($null -ne $holder) -FailureMessage "expected a holder record while the lock is held"
            Assert-Result -Name "record pid" -Condition ($holder.ProcessId -eq $PID) -FailureMessage ("expected recorded pid " + $PID + ", got " + $holder.ProcessId)
        } finally {
            Exit-RunLock -Lock $lock
        }

        Assert-Result -Name "record removed on release" -Condition (-not (Test-Path -LiteralPath (Get-RunLockOwnerPath -LockPath $lock.LockPath))) -FailureMessage "expected the holder record to be deleted with the lock"
    }

    $results += Run-Test -Name "The runner refuses to start while the lock is held" -Body {
        $psDir = New-RunnerScratch -Name "runner-blocked"
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"

        $lock = Enter-RunLock -ScopeRoot $psDir
        try {
            Assert-Result -Name "lock acquired" -Condition $lock.Acquired -FailureMessage "expected the test to take the lock first"

            $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy 2>&1)
            $exitCode = $LASTEXITCODE
            $output = $outputLines -join "`n"

            Assert-Result -Name "blocked exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
            Assert-Result -Name "blocked message" -Condition ($output -match "Another test run already holds the lock") -FailureMessage ("expected the lock message in output: " + $output)
            Assert-Result -Name "names the holder" -Condition ($output -match ("Held by PID " + $PID)) -FailureMessage ("expected the holder pid in output: " + $output)
        } finally {
            Exit-RunLock -Lock $lock
        }
    }

    $results += Run-Test -Name "-Force overrides a held lock" -Body {
        $psDir = New-RunnerScratch -Name "runner-force"
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"

        $lock = Enter-RunLock -ScopeRoot $psDir
        try {
            $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -Force 2>&1)
            $exitCode = $LASTEXITCODE
            $output = $outputLines -join "`n"

            Assert-Result -Name "force exit code" -Condition ($exitCode -eq 0) -FailureMessage (Format-ProcessExitMessage -ExitCode $exitCode -Output $output)
            Assert-Result -Name "force ran the suite" -Condition ($output -match "All tests passed!") -FailureMessage ("expected the suite to run under -Force: " + $output)

            Assert-Result -Name "force left the lock alone" -Condition (Test-Path -LiteralPath $lock.LockPath) -FailureMessage "expected -Force to leave the existing holder's lock file in place"
        } finally {
            Exit-RunLock -Lock $lock
        }
    }

    $results += Run-Test -Name "The runner releases its lock on exit" -Body {
        $psDir = New-RunnerScratch -Name "runner-releases"
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $lockPath = Get-RunLockPath -ScopeRoot $psDir

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "run exit code" -Condition ($exitCode -eq 0) -FailureMessage (Format-ProcessExitMessage -ExitCode $exitCode -Output $output)
        Assert-Result -Name "lock released" -Condition (-not (Test-Path -LiteralPath $lockPath)) -FailureMessage ("expected " + $lockPath + " to be gone after the run")
    }

    # The lock serialises one checkout. The reaper runs against machine-wide TEMP, so
    # ownership - not age - is what stops a second checkout deleting a live run root.
    $results += Run-Test -Name "A run root owned by a live process is not orphaned" -Body {
        $name = "crucible-test-run-" + $PID + "-" + [guid]::NewGuid().ToString("N")
        Assert-Result -Name "live owner" -Condition (-not (Test-TestRunRootOrphaned -Name $name)) -FailureMessage ("expected " + $name + " to be treated as live")
    }

    $results += Run-Test -Name "A run root owned by a dead process is orphaned" -Body {
        $name = "crucible-test-run-" + (Get-DeadProcessId) + "-" + [guid]::NewGuid().ToString("N")
        Assert-Result -Name "dead owner" -Condition (Test-TestRunRootOrphaned -Name $name) -FailureMessage ("expected " + $name + " to be treated as orphaned")
    }

    # A name carrying no pid cannot be attributed to a live process by any other means,
    # so it is collected rather than left to accumulate forever.
    $results += Run-Test -Name "A run root name without a pid segment is orphaned" -Body {
        $name = "crucible-test-run-" + [guid]::NewGuid().ToString("N")
        Assert-Result -Name "unattributable name" -Condition (Test-TestRunRootOrphaned -Name $name) -FailureMessage ("expected the unattributable name " + $name + " to be treated as orphaned")
    }

    # The live run root belongs to this process, so the reaper must leave it alone.
    # This is the case a threshold could not express: the outer suite legitimately runs
    # for far longer than any age at which an abandoned root should be collected.
    $results += Run-Test -Name "The running suite's own root survives collection" -Body {
        $runRoot = Get-TestRunRoot
        $name = Split-Path -Leaf $runRoot

        Assert-Result -Name "own root exists" -Condition (Test-Path -LiteralPath $runRoot) -FailureMessage ("expected the run root " + $runRoot + " to exist")
        Assert-Result -Name "own root not orphaned" -Condition (-not (Test-TestRunRootOrphaned -Name $name)) -FailureMessage ("expected the live run root " + $name + " to survive")
    }

} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
