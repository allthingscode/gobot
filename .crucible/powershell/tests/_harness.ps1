# Shared test harness helper functions.
# Name does not contain "test" to prevent runner execution.

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
        Write-Host "EXCEPTION OCCURRED: $_" -ForegroundColor Red
        if ($null -ne $_.ScriptStackTrace) {
            Write-Host $_.ScriptStackTrace -ForegroundColor Red
        }
        return $false
    }
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
# The owning process id is in the name because ownership cannot be inferred any other
# way, and it is still needed: the runner deletes its own root in a finally, but a run
# that is KILLED never reaches that finally, and a test file invoked on its own has no
# finally to reach. Those two cases are what Test-TestRunRootOrphaned collects.
#
# CRUCIBLE_TEST_ROOT is exported so the 80-odd child processes the runner spawns share
# the parent's root rather than each making one. A child therefore never creates a
# root and never deletes one.
function Get-TestRunRoot {
    if ($env:CRUCIBLE_TEST_ROOT -and (Test-Path -LiteralPath $env:CRUCIBLE_TEST_ROOT)) {
        return $env:CRUCIBLE_TEST_ROOT
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-test-run-" + $PID + "-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $env:CRUCIBLE_TEST_ROOT = $root
    return $root
}

# Age is not ownership. The run lock serialises one checkout, so a second checkout can
# legitimately have a run in flight, and a threshold short enough to collect a crashed
# run would also collect that one alive. A dead owner is proof; nothing else is.
#
# Names that do not carry a pid are reported orphaned. The caller has already
# established the directory is a run root, and an unparseable name cannot be
# attributed to a live process by any other means.
function Test-TestRunRootOrphaned {
    param([Parameter(Mandatory=$true)][string]$Name)

    $segments = $Name.Split("-")
    if ($segments.Count -lt 5) {
        return $true
    }

    $ownerPid = 0
    if (-not [int]::TryParse($segments[3], [ref]$ownerPid)) {
        return $true
    }

    return ($null -eq (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue))
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
# file while another was rewriting it and get a truncated config. Inside the run root
# there is exactly one writer.
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

    [System.IO.File]::WriteAllText($configPath, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $env:GIT_CONFIG_GLOBAL = $configPath
    return $configPath
}

# Recorded BEFORE the root is first used, so run-all-tests.ps1 can tell whether it
# owns the root it runs in. run-all-tests-runner.tests.ps1 starts a dozen nested
# runners inside the outer suite; each inherits CRUCIBLE_TEST_ROOT and must not delete
# the outer run's directory on its way out.
$CRUCIBLE_TEST_ROOT_CREATED = -not ($env:CRUCIBLE_TEST_ROOT -and (Test-Path -LiteralPath $env:CRUCIBLE_TEST_ROOT))

$null = Initialize-GitTestIsolation