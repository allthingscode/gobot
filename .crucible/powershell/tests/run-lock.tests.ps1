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

$tempRoot = New-TestFixtureRoot -NameHint "run-lock"

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

# A run root that is really on disk. Ownership reads the directory's creation time now, so a
# bare name cannot stand in for one: [System.IO.DirectoryInfo] coerces from a string and would
# hand back the 1601 epoch, which every live process started after.
#
# These live under this file's own $tempRoot rather than directly in TEMP, so no concurrent
# run's reaper can see them and delete a fixture mid-assertion. $tempRoot is itself under the run
# root since item 88, which does not weaken that: a reaper globs the top level of TEMP, so one
# directory of nesting is all it takes to be out of reach, and these fixtures are two.
function New-RunRootFixture {
    param([Parameter(Mandatory = $true)][string]$NameSuffix)

    $dir = Join-Path $tempRoot ("crucible-test-run-" + $NameSuffix)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return (Get-Item -LiteralPath $dir)
}

# Deliberately NOT Get-ProcessStartTimeUtc, even though it computes the same thing. Every fixture
# below establishes its own precondition with this, and a fixture that derives its precondition
# from the function under test cannot fail an assertion when that function breaks - it throws
# while building instead, and a kill by crash cannot be told apart from a harness falling over.
# Item 90's battery landed exactly there: mutating Get-ProcessStartTimeUtc produced CRASH-ONLY
# results for two cases whose assertions should have named the defect.
function Get-RawProcessStartTimeUtc {
    param([Parameter(Mandatory = $true)]$Process)

    $raw = $Process.StartTime
    if ($null -eq $raw) { return $null }
    return $raw.ToUniversalTime()
}

# A live process whose start time this session cannot read. pid 4 (System) is the reliable one
# on Windows; the sweep is the fallback for hosts where it is readable. pid 0 is excluded
# deliberately - Test-OwnerProcessLive rejects a non-positive pid before it ever looks at a
# start time, so Idle would exercise the wrong branch.
#
# Both conditions are checked together and the liveness check is repeated afterwards: a process
# that has merely exited between enumeration and read also reads as unreadable, and borrowing
# one of those would make the case below pass through the dead-owner branch instead.
function Get-UnreadableStartTimeProcess {
    foreach ($candidate in (@(4) + @(Get-Process | Where-Object { $_.Id -gt 0 } | ForEach-Object { $_.Id }))) {
        $proc = Get-Process -Id $candidate -ErrorAction SilentlyContinue
        if ($null -eq $proc) { continue }
        if ($null -ne (Get-RawProcessStartTimeUtc -Process $proc)) { continue }
        if ($null -eq (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) { continue }
        return $proc
    }
    return $null
}

# A live process that provably started after $Directory was created - the pid-reuse shape item
# 90 is about, with the ordering real rather than backdated. Start-Sleep bounds the leak if a
# later assertion throws before the caller's finally runs.
function Start-ProcessStartedAfter {
    param([Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$Directory)

    $proc = Start-HiddenHostProcess -Arguments @("-NoProfile", "-Command", "Start-Sleep -Seconds 60")
    $startUtc = Get-RawProcessStartTimeUtc -Process $proc
    if ($null -eq $startUtc -or $startUtc -le $Directory.CreationTimeUtc) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        throw ("Start-ProcessStartedAfter: spawned pid " + $proc.Id + " reports start time '" + $startUtc +
            "', which is not after the creation time '" + $Directory.CreationTimeUtc + "' of " +
            $Directory.FullName + ". The pid-reuse case cannot be built on this pair.")
    }
    return $proc
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
    # Every helper, not the two this fixture was written knowing about. _harness.ps1 grew a
    # dot-source of _ownership.ps1 for item 90 and a fixture that copied it by name would have
    # produced a scratch runner that dies on a missing file - the same stale-fixture failure
    # item 89 hit. Helpers are the _*.ps1 files, none of which match the runner's *test*.ps1
    # discovery glob, so copying all of them cannot smuggle in a test file.
    Copy-Item -Path (Join-Path (Split-Path -Parent $HARNESS_SCRIPT) "_*.ps1") -Destination $testsDir -Force
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

            $run = Invoke-ExternalCommand -Command { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy }
            $exitCode = $run.ExitCode
            $output = $run.Output

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
            $run = Invoke-ExternalCommand -Command { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -Force }
            $exitCode = $run.ExitCode
            $output = $run.Output

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

        $run = Invoke-ExternalCommand -Command { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy }
        $exitCode = $run.ExitCode
        $output = $run.Output

        Assert-Result -Name "run exit code" -Condition ($exitCode -eq 0) -FailureMessage (Format-ProcessExitMessage -ExitCode $exitCode -Output $output)
        Assert-Result -Name "lock released" -Condition (-not (Test-Path -LiteralPath $lockPath)) -FailureMessage ("expected " + $lockPath + " to be gone after the run")
    }

    # The criterion item 90 was actually filed on: collected by a run, not by hand. The unit cases
    # above prove the verdict; this proves the reaper acts on it.
    #
    # The temp directory is redirected for the child, so the staged root lives where that run's
    # reaper looks and nowhere another run can see it. Without that, a nested runner from
    # run-all-tests-runner.tests.ps1 could collect the fixture first and this case would pass
    # without the change under test having done anything.
    $results += Run-Test -Name "A run collects a root whose pid has been reused" -Body {
        $psDir = New-RunnerScratch -Name "reaps-reused-pid"
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $privateTemp = New-ScratchRoot -Name "reaper-temp"

        $staged = Join-Path $privateTemp ("crucible-test-run-staged-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $staged -Force | Out-Null
        $child = Start-ProcessStartedAfter -Directory (Get-Item -LiteralPath $staged)
        $prevTemp = $env:TEMP
        $prevTmp = $env:TMP
        $prevTmpDir = $env:TMPDIR
        try {
            $reusedName = "crucible-test-run-" + $child.Id + "-" + [guid]::NewGuid().ToString("N")
            Rename-Item -LiteralPath $staged -NewName $reusedName
            $reusedPath = Join-Path $privateTemp $reusedName

            # TMPDIR as well as TEMP and TMP. The reaper finds roots through
            # [System.IO.Path]::GetTempPath(), which reads TMP then TEMP on Windows and TMPDIR
            # everywhere else, so setting only the Windows pair left the child walking the real
            # /tmp with the fixture sitting untouched in a directory nothing looked at. Item 102.
            # All three are set on both platforms rather than behind a platform branch: each is
            # ignored where it does not apply, and a branch here would be a second place to be
            # wrong about which name a given edition reads.
            $env:TEMP = $privateTemp
            $env:TMP = $privateTemp
            $env:TMPDIR = $privateTemp

            # Measured, not assumed. That redirection is this test's entire premise, and it was
            # silently a no-op on one platform for as long as the test existed. Asking the child
            # where its temp path actually is costs one process start and converts the premise
            # into a fact. It also fixes the worse failure mode: with the redirect not taking,
            # this case passes as soon as any other run happens to collect the fixture from the
            # shared TEMP first, which is the vacuous pass the comment above was written against.
            $childTemp = (& (Get-PwshCommand) -NoProfile -Command '[System.IO.Path]::GetTempPath()' | Select-Object -First 1)
            $childTempFull = [System.IO.Path]::GetFullPath(([string]$childTemp).Trim()).TrimEnd('/', '\')
            $privateTempFull = [System.IO.Path]::GetFullPath($privateTemp).TrimEnd('/', '\')
            Assert-Result -Name "the child's temp directory is the private one" -Condition ($childTempFull -eq $privateTempFull) -FailureMessage (
                "the child resolved its temp directory to '" + $childTempFull + "' rather than '" + $privateTempFull +
                "', so the reaper under test walks a directory this test does not control and neither its " +
                "collecting nor its leaving the fixture alone would mean anything")

            $run = Invoke-ExternalCommand -Command { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy }
            $exitCode = $run.ExitCode
            $output = $run.Output

            Assert-Result -Name "the run succeeded" -Condition ($exitCode -eq 0) -FailureMessage (Format-ProcessExitMessage -ExitCode $exitCode -Output $output)
            Assert-Result -Name "the claimed owner outlived the run" -Condition ($null -ne (Get-Process -Id $child.Id -ErrorAction SilentlyContinue)) -FailureMessage (
                "pid " + $child.Id + " exited during the run, so collection would prove only that a dead " +
                "owner is collected - which was already true")
            Assert-Result -Name "the reused-pid root was collected" -Condition (-not (Test-Path -LiteralPath $reusedPath)) -FailureMessage (
                $reusedName + " survived a full run whose reaper walked " + $privateTemp + ". Its pid belongs " +
                "to a process that started afterwards, so no run will ever collect it and the directory is " +
                "uncollectable for the life of the machine. Run output: " + $output)
        } finally {
            $env:TEMP = $prevTemp
            $env:TMP = $prevTmp
            $env:TMPDIR = $prevTmpDir
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
            $child.Dispose()
        }
    }

    # The lock serialises one checkout. The reaper runs against machine-wide TEMP, so
    # ownership - not age - is what stops a second checkout deleting a live run root.
    $results += Run-Test -Name "A run root owned by a live process is not orphaned" -Body {
        $root = New-RunRootFixture -NameSuffix ($PID.ToString() + "-" + [guid]::NewGuid().ToString("N"))
        Assert-Result -Name "live owner" -Condition (-not (Test-TestRunRootOrphaned -Directory $root)) -FailureMessage ("expected " + $root.Name + " to be treated as live")
    }

    $results += Run-Test -Name "A run root owned by a dead process is orphaned" -Body {
        $root = New-RunRootFixture -NameSuffix ((Get-DeadProcessId).ToString() + "-" + [guid]::NewGuid().ToString("N"))
        Assert-Result -Name "dead owner" -Condition (Test-TestRunRootOrphaned -Directory $root) -FailureMessage ("expected " + $root.Name + " to be treated as orphaned")
    }

    # A name carrying no pid cannot be attributed to a live process by any other means,
    # so it is collected rather than left to accumulate forever.
    $results += Run-Test -Name "A run root name without a pid segment is orphaned" -Body {
        $root = New-RunRootFixture -NameSuffix ([guid]::NewGuid().ToString("N"))
        Assert-Result -Name "unattributable name" -Condition (Test-TestRunRootOrphaned -Directory $root) -FailureMessage ("expected the unattributable name " + $root.Name + " to be treated as orphaned")
    }

    # The live run root belongs to this process, so the reaper must leave it alone.
    # This is the case a threshold could not express: the outer suite legitimately runs
    # for far longer than any age at which an abandoned root should be collected.
    $results += Run-Test -Name "The running suite's own root survives collection" -Body {
        $runRoot = Get-TestRunRoot

        Assert-Result -Name "own root exists" -Condition (Test-Path -LiteralPath $runRoot) -FailureMessage ("expected the run root " + $runRoot + " to exist")
        Assert-Result -Name "own root not orphaned" -Condition (-not (Test-TestRunRootOrphaned -Directory (Get-Item -LiteralPath $runRoot))) -FailureMessage ("expected the live run root " + $runRoot + " to survive")
    }

    # Item 90. Two roots from 2026-09-10 survived every run for three days because their pids had
    # been handed to processes that started the next morning, and pid liveness alone said "live
    # owner" every time. The ordering here is real, not backdated: the directory is created first,
    # a process is started second, and only then is the directory renamed to claim that pid.
    # Rename preserves the creation time on NTFS - and if it ever stopped, the directory would
    # look newer than the process and this case would fail rather than quietly stop testing
    # anything.
    $results += Run-Test -Name "A run root whose pid was reused by a later process is orphaned" -Body {
        $staged = New-RunRootFixture -NameSuffix ("staged-" + [guid]::NewGuid().ToString("N"))
        $child = Start-ProcessStartedAfter -Directory $staged
        try {
            $childStartUtc = Get-RawProcessStartTimeUtc -Process $child
            $reusedName = "crucible-test-run-" + $child.Id + "-" + [guid]::NewGuid().ToString("N")
            Rename-Item -LiteralPath $staged.FullName -NewName $reusedName
            $reused = Get-Item -LiteralPath (Join-Path $tempRoot $reusedName)

            Assert-Result -Name "the rename kept the original creation time" -Condition ($reused.CreationTimeUtc -lt $childStartUtc) -FailureMessage (
                "after the rename the root reports creation time " + $reused.CreationTimeUtc + ", which is not " +
                "before pid " + $child.Id + "'s start time " + $childStartUtc + "; the fixture no longer " +
                "represents a reused pid")
            Assert-Result -Name "the claimed owner is still alive" -Condition ($null -ne (Get-Process -Id $child.Id -ErrorAction SilentlyContinue)) -FailureMessage (
                "pid " + $child.Id + " exited before the assertion, so a positive result would only prove " +
                "the dead-owner branch works")
            Assert-Result -Name "live pid that started later: orphaned" -Condition (Test-TestRunRootOrphaned -Directory $reused) -FailureMessage (
                $reusedName + " is owned by live pid " + $child.Id + ", which started after the directory " +
                "was created, so it cannot be the creator and the root is abandoned")

            # The control, without which the assertion above would also pass if the check had simply
            # started reporting every live-owned root as orphaned.
            $ownedLater = New-RunRootFixture -NameSuffix ($child.Id.ToString() + "-" + [guid]::NewGuid().ToString("N"))
            Assert-Result -Name "same live pid, root created after it started: live" -Condition (-not (Test-TestRunRootOrphaned -Directory $ownedLater)) -FailureMessage (
                $ownedLater.Name + " was created after pid " + $child.Id + " started, so that process could " +
                "be its owner and the root must survive")
        } finally {
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
            $child.Dispose()
        }
    }

    # Deleting a live run's root is worse than leaking an abandoned one, so a start time that
    # cannot be read means "assume the owner" - the answer the pid-only rule gave for everything.
    # Exercised against a real process whose StartTime this session cannot read, not a stub, and
    # paired with a control that proves the backdated timestamp produces the opposite answer when
    # the start time can be read. Item 102 treated "Windows" as the host that can supply that
    # process. After item 26, CI Windows is pwsh 7 on a GitHub-hosted runner that can read every
    # live process start time - the same shape as Linux. Skip when the fixture cannot be built.
    # A host that still has a protected process (typical non-admin Windows) still runs the case.
    $results += Run-Test -Name "A run root whose owner's start time cannot be read is left alone" -Body {
        $protected = Get-UnreadableStartTimeProcess
        if ($null -eq $protected) {
            Skip-Test ("no live process on this host has an unreadable start time, so an owner whose start time " +
                "cannot be read cannot be constructed")
        }

        # 1990: before any process on a running Windows machine can have started, so a readable start
        # time makes this root orphaned. A fixed date rather than one derived from the borrowed
        # process's uptime, because that uptime is exactly what cannot be read.
        $beforeAnyProcess = New-Object datetime(1990, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)

        $aged = New-RunRootFixture -NameSuffix ($protected.Id.ToString() + "-" + [guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::SetCreationTimeUtc($aged.FullName, $beforeAnyProcess)
        $aged = Get-Item -LiteralPath $aged.FullName

        Assert-Result -Name "unreadable start time: left alone" -Condition (-not (Test-TestRunRootOrphaned -Directory $aged)) -FailureMessage (
            "a root owned by pid " + $protected.Id + " (" + $protected.ProcessName + "), whose start time " +
            "cannot be read, was reported orphaned; the reaper would delete it, and the same answer for a " +
            "live run's root would delete that instead")

        $control = New-RunRootFixture -NameSuffix ($PID.ToString() + "-" + [guid]::NewGuid().ToString("N"))
        [System.IO.Directory]::SetCreationTimeUtc($control.FullName, $beforeAnyProcess)
        $control = Get-Item -LiteralPath $control.FullName

        Assert-Result -Name "readable start time, same timestamp: orphaned" -Condition (Test-TestRunRootOrphaned -Directory $control) -FailureMessage (
            "a root dated 1990 and owned by this live process was reported live, so the case above proves " +
            "nothing: the timestamp is not what produced the answer")
    }

    # [System.IO.DirectoryInfo] coerces from a string, so a caller passing a bare name reaches
    # this. Its CreationTimeUtc would be the 1601 epoch, which every live process started after -
    # an orphan verdict arrived at for a reason that has nothing to do with ownership.
    $results += Run-Test -Name "A run root that is not on disk is not reported as residue" -Body {
        $absent = Join-Path $tempRoot ("crucible-test-run-" + $PID + "-" + [guid]::NewGuid().ToString("N"))

        Assert-Result -Name "the path really is absent" -Condition (-not (Test-Path -LiteralPath $absent)) -FailureMessage (
            "the fixture path " + $absent + " exists, so this case is not testing an absent directory")
        Assert-Result -Name "absent directory: not residue" -Condition (-not (Test-TestRunRootOrphaned -Directory $absent)) -FailureMessage (
            "a directory that is not there was reported as collectable residue")
    }

    # Called directly rather than through a run root, because no caller can reach it with a
    # non-positive pid: Test-TestRunRootOrphaned parses one out of a real name, and the worktree
    # check short-circuits on 0 before it gets here. Item 90's battery found that deleting this
    # guard changed nothing any test could see - `Get-Process -Id 0` returns the real Idle
    # process on Windows, so without the guard every root named for pid 0 would read as live
    # forever, which is the exact defect the item is about wearing a different pid.
    $results += Run-Test -Name "A non-positive owner pid is never a live owner" -Body {
        $now = [datetime]::UtcNow

        Assert-Result -Name "pid 0 is not an owner" -Condition (-not (Test-OwnerProcessLive -OwnerPid 0 -CreatedUtc $now)) -FailureMessage (
            "pid 0 was accepted as a live owner; Get-Process -Id 0 returns the Idle process, so a " +
            "root named for it would never be collected")
        Assert-Result -Name "a negative pid is not an owner" -Condition (-not (Test-OwnerProcessLive -OwnerPid -1 -CreatedUtc $now)) -FailureMessage (
            "a negative pid was accepted as a live owner")
        Assert-Result -Name "pid 0 is not an owner with no creation time either" -Condition (-not (Test-OwnerProcessLive -OwnerPid 0 -CreatedUtc $null)) -FailureMessage (
            "pid 0 was accepted as a live owner on the no-creation-time path, which is the path " +
            "the worktree check uses for a registration whose checkout is gone")
    }

} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-TestFileSummary -Results $results
