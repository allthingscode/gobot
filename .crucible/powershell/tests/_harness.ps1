# Shared test harness helper functions.
# Name does not contain "test" to prevent runner execution.

# Safe to load here: _ownership.ps1 has no load-time side effects, which is what lets
# _worktree-fixture.ps1 load it too without loading this file. See its header.
. (Join-Path $PSScriptRoot "_ownership.ps1")

function Get-ProcessDeathDescription {
    param(
        [Parameter(Mandatory=$true)]
        [int64]$ExitCode
    )

    $signals = @{
        1 = "SIGHUP"; 2 = "SIGINT"; 3 = "SIGQUIT"; 4 = "SIGILL"; 5 = "SIGTRAP";
        6 = "SIGABRT"; 7 = "SIGBUS"; 8 = "SIGFPE"; 9 = "SIGKILL"; 10 = "SIGUSR1";
        11 = "SIGSEGV"; 12 = "SIGUSR2"; 13 = "SIGPIPE"; 14 = "SIGALRM"; 15 = "SIGTERM";
        16 = "SIGSTKFLT"; 17 = "SIGCHLD"; 18 = "SIGCONT"; 19 = "SIGSTOP"; 20 = "SIGTSTP";
        24 = "SIGXCPU"; 25 = "SIGXFSZ"; 31 = "SIGSYS"
    }

    if ($ExitCode -gt 128 -and $ExitCode -le 165) {
        $sigNum = [int]($ExitCode - 128)
        $sigName = if ($signals.ContainsKey($sigNum)) { $signals[$sigNum] } else { "SIG$sigNum" }
        return "child process died on $sigName (exit $ExitCode)"
    }

    $winCrashes = @{
        "3221225477"  = "STATUS_ACCESS_VIOLATION (0xC0000005)";
        "-1073741819" = "STATUS_ACCESS_VIOLATION (0xC0000005)";
        "3221226505"  = "STATUS_STACK_BUFFER_OVERRUN (0xC0000409)";
        "-1073740791" = "STATUS_STACK_BUFFER_OVERRUN (0xC0000409)";
        "3221225725"  = "STATUS_STACK_OVERFLOW (0xC00000FD)";
        "-1073741571" = "STATUS_STACK_OVERFLOW (0xC00000FD)";
        "3221225491"  = "STATUS_ILLEGAL_INSTRUCTION (0xC000001D)";
        "-1073741805" = "STATUS_ILLEGAL_INSTRUCTION (0xC000001D)";
        "3221225509"  = "STATUS_NONCONTINUABLE_EXCEPTION (0xC0000025)";
        "-1073741787" = "STATUS_NONCONTINUABLE_EXCEPTION (0xC0000025)";
        "3221225620"  = "STATUS_INTEGER_DIVIDE_BY_ZERO (0xC0000094)";
        "-1073741676" = "STATUS_INTEGER_DIVIDE_BY_ZERO (0xC0000094)";
        "3221225794"  = "STATUS_DLL_INIT_FAILED (0xC0000142)";
        "-1073741502" = "STATUS_DLL_INIT_FAILED (0xC0000142)"
    }

    $strCode = [string]$ExitCode
    if ($winCrashes.ContainsKey($strCode)) {
        return "child process crashed on $($winCrashes[$strCode]) (exit $ExitCode)"
    }

    return $null
}

function Format-ProcessExitMessage {
    param(
        [Parameter(Mandatory=$true)][int64]$ExitCode,
        [Parameter(Mandatory=$false)][int64]$ExpectedExitCode = 0,
        [Parameter(Mandatory=$false)][string]$Output = ""
    )

    $deathDesc = Get-ProcessDeathDescription -ExitCode $ExitCode
    $prefix = if (-not [string]::IsNullOrWhiteSpace($deathDesc)) { ($deathDesc + ": ") } else { "" }
    $outSuffix = if (-not [string]::IsNullOrEmpty($Output)) { (". Output: " + $Output) } else { "" }
    return ($prefix + "expected exit " + $ExpectedExitCode + ", got " + $ExitCode + $outSuffix)
}

function Assert-Result {
    param(
        [Parameter(Position=0, Mandatory=$true)][string]$Name,
        [Parameter(Position=1, Mandatory=$true)][bool]$Condition,
        # AllowEmptyString, Mandatory kept: the natural idiom is
        # -FailureMessage $result.Output, and a command that succeeds SILENTLY yields
        # "". Binding runs before $Condition is evaluated, so without this a PASSING
        # assertion throws. The two attributes are independent - omitting the argument
        # entirely is still a caller error. Same shape as the AllowEmptyCollection fix
        # in lib/gitignore-conformance.ps1.
        [Parameter(Position=2, Mandatory=$true)][AllowEmptyString()][string]$FailureMessage
    )
    if (-not $Condition) {
        $crashPrefix = ""
        $matchedCode = $null
        if ($FailureMessage -match '\bexpected exit\b.*?\bgot\s*:?\s*(-?\d+)\b') {
            $candidate = [int64]$Matches[1]
            $desc = Get-ProcessDeathDescription -ExitCode $candidate
            if (-not [string]::IsNullOrWhiteSpace($desc)) {
                $matchedCode = $candidate
            }
        }
        if ($null -ne $matchedCode) {
            $deathDesc = Get-ProcessDeathDescription -ExitCode $matchedCode
            if (-not [string]::IsNullOrWhiteSpace($deathDesc) -and $FailureMessage -notmatch [regex]::Escape($deathDesc)) {
                $crashPrefix = ($deathDesc + " - ")
            }
        }
        throw ("FAILED: " + $Name + " - " + $crashPrefix + $FailureMessage)
    }
}

# A third outcome, for a test whose precondition cannot exist on the platform it is running on.
# Until item 102 there were two, so such a test either failed the whole leg or was rewritten to
# pass without having run. Both happened: run-lock.tests.ps1 borrows a protected Windows process
# to get one whose start time cannot be read, asserts it found one rather than skipping - which is
# item 89's lesson, applied on purpose - and therefore failed every Linux run.
#
# Signalled by a sentinel prefix on a thrown string, matching Assert-Result's "FAILED: " idiom,
# because the runner already classifies a child by grepping its output for exactly those prefixes.
# "SKIPPED: " is deliberately not a substring of any signature Test-OutputHasFailure looks for.
#
# Skip still returns $true from Run-Test, so "$results | Where-Object { -not $_ }" still
# treats it as a non-failure. $results.Count therefore still includes it, which is why a
# file's own "ALL TESTS PASSED (n tests)" line overstates coverage. Write-TestFileSummary
# is the one place that count is corrected; a file that Skip-Tests must call it rather
# than printing $results.Count. Item 104.
$CRUCIBLE_SKIP_SENTINEL = "CRUCIBLE-TEST-SKIPPED: "
$script:CrucibleSkipCount = 0

function Skip-Test {
    param(
        # No default. A skip with no stated reason is the vacuous pass this exists to prevent,
        # one rename later.
        [Parameter(Position=0, Mandatory=$true)][string]$Reason
    )
    if ([string]::IsNullOrWhiteSpace($Reason)) {
        throw "Skip-Test: -Reason must say why this platform cannot run the test."
    }
    throw ($CRUCIBLE_SKIP_SENTINEL + $Reason)
}

function Run-Test {
    param(
        [Parameter(Position=0, Mandatory=$true)][string]$Name,
        [Parameter(Position=1, Mandatory=$true)][scriptblock]$Body
    )

    Write-Host ("`nTest: " + $Name) -ForegroundColor Cyan
    try {
        & $Body
        Write-Host "PASSED" -ForegroundColor Green
        return $true
    } catch {
        $message = [string]$_.Exception.Message
        if ($message.StartsWith($CRUCIBLE_SKIP_SENTINEL)) {
            $script:CrucibleSkipCount++
            Write-Host ("SKIPPED: " + $Name + " - " + $message.Substring($CRUCIBLE_SKIP_SENTINEL.Length)) -ForegroundColor Yellow
            return $true
        }
        Write-Host "EXCEPTION OCCURRED: $_" -ForegroundColor Red
        if ($null -ne $_.ScriptStackTrace) {
            Write-Host $_.ScriptStackTrace -ForegroundColor Red
        }
        return $false
    }
}

# The per-file tail. Skip-Test returns $true, so $results.Count counts a skip as a test
# that ran. Files that never skip can keep printing that count; files that Skip-Test
# must come through here so a skip is not reported as a pass. Item 104.
function Write-TestFileSummary {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        $Results
    )

    $list = @($Results)
    $failed = @($list | Where-Object { $_ -eq $false }).Count
    $skipped = [int]$script:CrucibleSkipCount
    $passed = $list.Count - $failed - $skipped

    if ($failed -gt 0) {
        Write-Host ("`nSOME TESTS FAILED ($failed failed, $passed passed, $skipped skipped)") -ForegroundColor Red
        exit 1
    }
    if ($skipped -gt 0) {
        Write-Host ("`nALL TESTS PASSED ($passed tests, $skipped skipped)") -ForegroundColor Green
    } else {
        Write-Host ("`nALL TESTS PASSED ($passed tests)") -ForegroundColor Green
    }
    exit 0
}

# Start-Process -WindowStyle does not exist on PowerShell's Linux edition; it throws "The parameter
# '-WindowStyle' is not supported for the cmdlet 'Start-Process' on this edition of PowerShell".
# Hidden is there only to stop a console window flashing on Windows, so the parameter is needed on
# one platform and rejected on the other. Two test files spawn a host process whose only job is to
# exist - run-lock.tests.ps1's pid-reuse fixture and framework-worktree-hygiene.tests.ps1's dead and
# live owners - and both failed the entire Linux leg on this one parameter. Item 102.
#
# Here rather than in each caller so the platform branch has one definition, and not dot-sourcing
# lib/platform.ps1 to reach Test-PlatformIsWindows: that file carries the mock state
# platform.tests.ps1 drives, and loading it from the harness would put a second loader in front of
# the file that tests it. Both callers already load it, so this asks rather than assumes.
function Start-HiddenHostProcess {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if ($null -eq (Get-Command Test-PlatformIsWindows -ErrorAction SilentlyContinue)) {
        throw "Start-HiddenHostProcess: dot-source lib/platform.ps1 before calling this."
    }

    $startArgs = @{
        FilePath     = (Get-PwshCommand)
        ArgumentList = $Arguments
        PassThru     = $true
    }
    if (Test-PlatformIsWindows) { $startArgs["WindowStyle"] = "Hidden" }
    return (Start-Process @startArgs)
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$Command
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Command 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [PSCustomObject]@{ Output = ($output -join "`n"); ExitCode = $exitCode }
}

# Everything a run creates in TEMP lives under one directory, so cleaning up after a
# run is one delete instead of a pattern match per artifact kind. Before this there
# were three separate mechanisms - an age-based fixture reaper, an ownership check on
# fixture names, and a pid-liveness reclaim in the run lock - each maintaining its own
# idea of which stray TEMP entry belonged to whom.
#
# That sentence was written for item 24 and was false for two years: 88 of 98 test files built their
# fixture root straight off the machine TEMP path, at 107 sites, so the delete collected the fixtures
# of nine files and a developer's TEMP accumulated 131 directories nothing could attribute. Item 88
# made it true. It is kept honest by fixture-root-conformance.tests.ps1, which fails when a test file
# reaches TEMP without a recorded exemption - there are five exemptions and each names its own line.
# The one that matters to a reader here is item 85's fixture worktrees, which stay directly in TEMP
# because a checkout of this repository needs the depth; residue there is detected rather than
# deleted, and _worktree-fixture.ps1 states the measurement.
#
# The owning process id is in the name because ownership cannot be inferred any other
# way, and it is still needed: the runner deletes its own root in a finally, but a run
# that is KILLED never reaches that finally, and a test file invoked on its own has no
# finally to reach. Those two cases are what Test-TestRunRootOrphaned collects.
#
# CRUCIBLE_TEST_ROOT is exported so the 80-odd child processes the runner spawns share
# the parent's root rather than each making one. A child therefore never creates a
# root and never deletes one.
#
# The name is 32 characters, and it used to be 56 because the unique part was a whole guid. Those
# 24 characters were the reason nothing deep could be built under here at all: a worktree of this
# repository under a run root projected exactly 260 characters against
# examples/gobot/.crucible/templates/project/.crucible/backlog/_example_F-001_example_feature.md,
# one over the Windows limit, on a machine whose TEMP path is 46 characters - so the fixture that
# item 85 landed sits directly in TEMP instead. Item 88 moved the other 88 files, which were doing
# the same thing for no such reason, and it had to start here: none of them could move until there
# was budget to move them into.
#
# Eight hex digits rather than 32: the pid is already in the name and a root is created once per
# process, so the digits only have to separate this run from residue left by a dead process that
# happened to hold the same pid. A collision there is benign rather than unlikely-and-fatal - the
# owner is dead, New-Item -Force adopts the directory, and the run's own finally deletes both.
function Get-TestRunRoot {
    if ($env:CRUCIBLE_TEST_ROOT -and (Test-Path -LiteralPath $env:CRUCIBLE_TEST_ROOT)) {
        return $env:CRUCIBLE_TEST_ROOT
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-test-run-" + $PID + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $env:CRUCIBLE_TEST_ROOT = $root
    return $root
}

# One place builds a fixture root, for the reason item 88 was filed about: 88 test files built
# their own directly off the machine TEMP path, so the runner's single delete collected almost
# nothing and Test-TestRunRootOrphaned could not attribute what was left. Measured while that
# migration landed, a developer's TEMP held 131 such directories going back three months.
#
# The unique suffix is eight hex digits rather than a whole guid, and that is what pays for the
# move. A run root costs 33 characters over bare TEMP; dropping 24 characters of guid off the
# fixture's own leaf gives most of them straight back, so converting a fixture is close to
# length-neutral instead of a 33-character step towards 'Filename too long'.
#
# No path budget is enforced here, and that is a decision rather than an omission. A version of
# this function refused any root that could not hold this repository's deepest tracked path, 94
# characters. Measured against what fixtures actually write, that was the wrong number: the
# deepest path the suite produced was 211 of the 259 available, and its payload below the fixture
# root was 133 - deeper than anything in the tree, because a fixture nests an agent workspace
# inside an installed bundle. Raising the constant to 133 does not fix it either. The deepest
# payload and the longest root belong to DIFFERENT fixtures, so a single global constant is the
# product of two independent maxima: it refuses roots that would have worked while still not
# proving that the one deep fixture fits. A budget assertion needs the payload, so it belongs
# where the payload is known - Assert-FrameworkTestWorktreePathBudget in _worktree-fixture.ps1 is
# that shape, and it is the one caller that can name its own committish.
function New-TestFixtureRoot {
    param([Parameter(Mandatory = $true)][string]$NameHint)

    $safe = ($NameHint -replace '[^A-Za-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        throw "New-TestFixtureRoot: -NameHint must contain at least one alphanumeric character."
    }

    $path = Join-Path (Get-TestRunRoot) ($safe + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

# Ownership is decided by Test-OwnerProcessLive in _ownership.ps1: a dead owner is proof of
# abandonment, and so is a live owner that started after the root was created, because
# Windows reuses pids. Age is still not ownership and no threshold is used here.
#
# Names that do not carry a pid are reported orphaned. The caller has already
# established the directory is a run root, and an unparseable name cannot be
# attributed to a live process by any other means.
#
# -Directory rather than -Name because the name and the creation time have to come from the
# same directory. Two parameters would let a caller pair one root's name with another's
# timestamp, and the only production caller - the reaper in run-all-tests.ps1 - already holds
# the object.
function Test-TestRunRootOrphaned {
    param([Parameter(Mandatory=$true)][System.IO.DirectoryInfo]$Directory)

    # A directory that is not there is not residue anyone can collect, and its
    # CreationTimeUtc would be the 1601 epoch - a time every live process started after, so
    # it would read as orphaned for a reason that has nothing to do with ownership.
    # [System.IO.DirectoryInfo] coerces from a string, so a caller that passes a bare name
    # reaches exactly that.
    if (-not $Directory.Exists) {
        return $false
    }

    $segments = $Directory.Name.Split("-")
    if ($segments.Count -lt 5) {
        return $true
    }

    $ownerPid = 0
    if (-not [int]::TryParse($segments[3], [ref]$ownerPid)) {
        return $true
    }

    return (-not (Test-OwnerProcessLive -OwnerPid $ownerPid -CreatedUtc $Directory.CreationTimeUtc))
}

# Fixture repos git-init into TEMP, which inherits the DEVELOPER'S global git
# config. That made the suite's behaviour a property of the machine rather than of
# the repository: on a box with core.autocrlf=true, staging an LF file warns "LF
# will be replaced by CRLF", and the fixture's working copy of a shell script turns
# CRLF on the next checkout. Roughly two dozen fixtures defended against this by
# hand; about sixty did not.
#
# GIT_CONFIG_GLOBAL replaces only the GLOBAL layer, so a test that deliberately
# sets core.autocrlf in a repo's LOCAL config still wins. Measured, not assumed -
# init-project-core.tests.ps1 depends on exactly that precedence. Setting
# GIT_CONFIG_COUNT/KEY/VALUE instead would NOT work: those rank as command-line
# config and would override the local setting, silently gutting that test.
# The config used to be written to a fixed TEMP path shared by every run. The content
# is a constant, so concurrent runs wrote identical bytes and the sharing was almost
# safe - but WriteAllText is not atomic, so a run of a second checkout could read the
# file while another was rewriting it and get a truncated config. Moving it inside the
# run root was believed to leave exactly one writer. It did not. The run root is per RUN,
# not per process, and the parallel runner exports it to every child, so the same path
# went from two occasional writers to as many as eight simultaneous ones. That claim was
# recorded here as an invariant rather than as the assumption it was, which is why the
# change that falsified it went unnoticed for so long: a reader checks a stated invariant
# against the code below it, not against the callers above it. The writer count is no
# longer what makes this safe - the publish is. See the rename in the body.
function Initialize-GitTestIsolation {
    $configPath = Join-Path (Get-TestRunRoot) "gitconfig"

    # user.*             fixtures that commit without a local identity would fail
    #                    outright once the developer's global identity is out of scope.
    # merge.autoedit     without it a fixture merge can block on an editor.
    # init.defaultBranch pinned because it is the global setting most likely to differ
    #                    between two developers, and leaving it unpinned would preserve
    #                    the exact machine-dependence this function exists to remove.
    $lines = @(
        "[core]",
        "`tautocrlf = false",
        "`tsafecrlf = false",
        "[user]",
        "`tname = Crucible Test",
        "`temail = test@crucible.invalid",
        "[merge]",
        "`tautoedit = no",
        "[init]",
        "`tdefaultBranch = master"
    )

    # Create-if-absent, published by rename. Every process that dot-sources this file
    # calls this function, and under the parallel runner up to eight of them resolve the
    # same path inside one shared run root, so the write cannot be a plain WriteAllText
    # to $configPath: that opens the destination for truncation. A sibling READING it
    # through GIT_CONFIG_GLOBAL at that moment gets a truncated config; a sibling WRITING
    # it at that moment gets "the process cannot access the file because it is being used
    # by another process" and takes an unrelated test down with it. Staging under a unique
    # name and renaming into place means the destination is only ever created whole, and
    # only ever created once. The Test-Path is an optimisation, not the guard - two
    # processes can both pass it - and the loser of the rename is right to discard its
    # copy, because the bytes are a constant and the winner wrote the same ones.
    # -PathType Leaf on both checks, because "something occupies that name" is not the
    # question being asked either time. A directory there satisfies a bare Test-Path,
    # which would skip the publish and then point GIT_CONFIG_GLOBAL at a path git cannot
    # read as a config - silently, and looking exactly like isolation.
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $stagePath = $configPath + ".stage-" + $PID + "-" + [guid]::NewGuid().ToString("N")
        [System.IO.File]::WriteAllText($stagePath, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        try {
            [System.IO.File]::Move($stagePath, $configPath)
        } catch {
            # Losing the rename is the expected outcome of a tie, not an error. Any other
            # failure leaves the destination absent, and pointing GIT_CONFIG_GLOBAL at a
            # file that does not exist would hand the suite straight back to the global
            # config of whoever is running it - the one thing this function exists to
            # prevent. So the swallow is conditional on the file being there, whoever put
            # it there.
            Remove-Item -LiteralPath $stagePath -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw }
        }
    }

    $env:GIT_CONFIG_GLOBAL = $configPath
    return $configPath
}

# Recorded BEFORE the root is first used, so run-all-tests.ps1 can tell whether it
# owns the root it runs in. run-all-tests-runner.tests.ps1 starts a dozen nested
# runners inside the outer suite; each inherits CRUCIBLE_TEST_ROOT and must not delete
# the outer run's directory on its way out.
$CRUCIBLE_TEST_ROOT_CREATED = -not ($env:CRUCIBLE_TEST_ROOT -and (Test-Path -LiteralPath $env:CRUCIBLE_TEST_ROOT))

$null = Initialize-GitTestIsolation