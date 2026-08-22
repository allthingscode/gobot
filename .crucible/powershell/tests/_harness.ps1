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
        [Parameter(Position=2, Mandatory=$true)][string]$FailureMessage
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
