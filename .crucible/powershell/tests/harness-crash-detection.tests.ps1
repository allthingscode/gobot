# Tests for process death / signal detection and labeling in _harness.ps1.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")

$results = @()

$results += Run-Test -Name "synthetic child exit 139 produces SIGSEGV label" -Body {
    $cmd = Invoke-ExternalCommand -Command {
        if (Test-PlatformIsWindows) {
            & cmd.exe /c "exit 139"
        } else {
            & (Get-PwshCommand) -NoProfile -Command "exit 139"
        }
    }
    Assert-Result -Name "synthetic child exits 139" -Condition ($cmd.ExitCode -eq 139) -FailureMessage "expected exit 139"

    $caught = $null
    try {
        Assert-Result -Name "synthetic child exit 0" -Condition ($cmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $cmd.ExitCode + ". Output: " + $cmd.Output)
    } catch {
        $caught = $_.Exception.Message
    }

    Assert-Result -Name "synthetic child exit 139 exception thrown" -Condition ($null -ne $caught) -FailureMessage "expected exception to be thrown"
    Assert-Result -Name "synthetic child exit 139 labeled as SIGSEGV" -Condition ($caught -match "child process died on SIGSEGV \(exit 139\)") -FailureMessage ("expected SIGSEGV label in exception message, got: " + $caught)
}

$results += Run-Test -Name "synthetic child exit 134 produces SIGABRT label" -Body {
    $cmd = Invoke-ExternalCommand -Command {
        if (Test-PlatformIsWindows) {
            & cmd.exe /c "exit 134"
        } else {
            & (Get-PwshCommand) -NoProfile -Command "exit 134"
        }
    }
    Assert-Result -Name "synthetic child exits 134" -Condition ($cmd.ExitCode -eq 134) -FailureMessage "expected exit 134"

    $caught = $null
    try {
        Assert-Result -Name "synthetic child exit 0" -Condition ($cmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $cmd.ExitCode + ". Output: " + $cmd.Output)
    } catch {
        $caught = $_.Exception.Message
    }

    Assert-Result -Name "synthetic child exit 134 exception thrown" -Condition ($null -ne $caught) -FailureMessage "expected exception to be thrown"
    Assert-Result -Name "synthetic child exit 134 labeled as SIGABRT" -Condition ($caught -match "child process died on SIGABRT \(exit 134\)") -FailureMessage ("expected SIGABRT label in exception message, got: " + $caught)
}

$results += Run-Test -Name "windows access violation exit code produces STATUS_ACCESS_VIOLATION label" -Body {
    $caught = $null
    try {
        Assert-Result -Name "access violation child exit 0" -Condition ($false) -FailureMessage "expected exit 0, got 3221225477. Output: "
    } catch {
        $caught = $_.Exception.Message
    }

    Assert-Result -Name "access violation exception thrown" -Condition ($null -ne $caught) -FailureMessage "expected exception to be thrown"
    Assert-Result -Name "access violation labeled as STATUS_ACCESS_VIOLATION" -Condition ($caught -match "child process crashed on STATUS_ACCESS_VIOLATION \(0xC0000005\) \(exit 3221225477\)") -FailureMessage ("expected STATUS_ACCESS_VIOLATION label in exception message, got: " + $caught)
}

$results += Run-Test -Name "normal exit code 1 is not labeled as crash" -Body {
    $cmd = Invoke-ExternalCommand -Command {
        if (Test-PlatformIsWindows) {
            & cmd.exe /c "exit 1"
        } else {
            & (Get-PwshCommand) -NoProfile -Command "exit 1"
        }
    }
    Assert-Result -Name "synthetic child exits 1" -Condition ($cmd.ExitCode -eq 1) -FailureMessage "expected exit 1"

    $caught = $null
    try {
        Assert-Result -Name "normal child exit 0" -Condition ($cmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $cmd.ExitCode + ". Output: " + $cmd.Output)
    } catch {
        $caught = $_.Exception.Message
    }

    Assert-Result -Name "normal child exit 1 exception thrown" -Condition ($null -ne $caught) -FailureMessage "expected exception to be thrown"
    Assert-Result -Name "normal exit 1 contains expected message" -Condition ($caught -match "expected exit 0, got 1") -FailureMessage ("expected message to contain expected exit 0, got 1; got: " + $caught)
    Assert-Result -Name "normal exit 1 does not contain crash label" -Condition ($caught -notmatch "child process died" -and $caught -notmatch "child process crashed") -FailureMessage ("expected no crash label in exception message, got: " + $caught)
}

$results += Run-Test -Name "Format-ProcessExitMessage formats crash and non-crash messages" -Body {
    $msg139 = Format-ProcessExitMessage -ExitCode 139 -ExpectedExitCode 0 -Output ""
    Assert-Result -Name "Format-ProcessExitMessage 139 contains SIGSEGV" -Condition ($msg139 -match "child process died on SIGSEGV \(exit 139\): expected exit 0, got 139") -FailureMessage ("expected SIGSEGV format, got: " + $msg139)

    $msg1 = Format-ProcessExitMessage -ExitCode 1 -ExpectedExitCode 0 -Output "some error"
    Assert-Result -Name "Format-ProcessExitMessage 1 does not contain crash prefix" -Condition ($msg1 -eq "expected exit 0, got 1. Output: some error") -FailureMessage ("expected plain format, got: " + $msg1)
}

$results += Run-Test -Name "Get-ProcessDeathDescription covers standard POSIX signal range" -Body {
    $desc139 = Get-ProcessDeathDescription -ExitCode 139
    Assert-Result -Name "signal 139 description" -Condition ($desc139 -eq "child process died on SIGSEGV (exit 139)") -FailureMessage ("got: " + $desc139)

    $desc137 = Get-ProcessDeathDescription -ExitCode 137
    Assert-Result -Name "signal 137 description" -Condition ($desc137 -eq "child process died on SIGKILL (exit 137)") -FailureMessage ("got: " + $desc137)

    $desc143 = Get-ProcessDeathDescription -ExitCode 143
    Assert-Result -Name "signal 143 description" -Condition ($desc143 -eq "child process died on SIGTERM (exit 143)") -FailureMessage ("got: " + $desc143)

    $desc0 = Get-ProcessDeathDescription -ExitCode 0
    Assert-Result -Name "exit 0 description is null" -Condition ($null -eq $desc0) -FailureMessage "expected null for exit 0"

    $desc1 = Get-ProcessDeathDescription -ExitCode 1
    Assert-Result -Name "exit 1 description is null" -Condition ($null -eq $desc1) -FailureMessage "expected null for exit 1"
}

$results += Run-Test -Name "failure message with in-range integer in output is not labeled as crash" -Body {
    $caught = $null
    try {
        Assert-Result -Name "exit 1 with line 139 in output" -Condition ($false) -FailureMessage "expected exit 0, got 1. Output: parse error at line 139 of backlog.json"
    } catch {
        $caught = $_.Exception.Message
    }

    Assert-Result -Name "exit 1 with line 139 exception thrown" -Condition ($null -ne $caught) -FailureMessage "expected exception to be thrown"
    Assert-Result -Name "exit 1 with line 139 does not contain crash label" -Condition ($caught -notmatch "child process died" -and $caught -notmatch "child process crashed") -FailureMessage ("expected no crash label in exception message, got: " + $caught)
}

$results += Run-Test -Name "non-exit-code message containing in-range integer is not labeled as crash" -Body {
    $caught = $null
    try {
        Assert-Result -Name "row count failure with 150" -Condition ($false) -FailureMessage "expected 150 rows, got 2"
    } catch {
        $caught = $_.Exception.Message
    }

    Assert-Result -Name "row count 150 exception thrown" -Condition ($null -ne $caught) -FailureMessage "expected exception to be thrown"
    Assert-Result -Name "row count 150 does not contain crash label" -Condition ($caught -notmatch "child process died" -and $caught -notmatch "child process crashed") -FailureMessage ("expected no crash label in exception message, got: " + $caught)
}

$results += Run-Test -Name "expected exit 139 got 0 is not labeled as crash" -Body {
    $caught = $null
    try {
        Assert-Result -Name "expected crash got 0" -Condition ($false) -FailureMessage "expected exit 139, got 0"
    } catch {
        $caught = $_.Exception.Message
    }

    Assert-Result -Name "expected crash got 0 exception thrown" -Condition ($null -ne $caught) -FailureMessage "expected exception to be thrown"
    Assert-Result -Name "expected crash got 0 does not contain crash label" -Condition ($caught -notmatch "child process died" -and $caught -notmatch "child process crashed") -FailureMessage ("expected no crash label in exception message, got: " + $caught)
}

$results += Run-Test -Name "non-exit-code message whose got-value is in crash range is not labeled" -Body {
    $caught = $null
    try {
        Assert-Result -Name "retry count failure" -Condition ($false) -FailureMessage "expected 3 retries, got 139 attempts"
    } catch {
        $caught = $_.Exception.Message
    }

    Assert-Result -Name "retry count exception thrown" -Condition ($null -ne $caught) -FailureMessage "expected exception to be thrown"
    Assert-Result -Name "got-value without expected-exit context is not labeled" -Condition ($caught -notmatch "child process died" -and $caught -notmatch "child process crashed") -FailureMessage ("expected no crash label when the message is not reporting an exit code, got: " + $caught)
}

$results += Run-Test -Name "real crash message expected exit 0 got 139 is labeled as SIGSEGV" -Body {
    $caught = $null
    try {
        Assert-Result -Name "real crash got 139" -Condition ($false) -FailureMessage "expected exit 0, got 139. Output: "
    } catch {
        $caught = $_.Exception.Message
    }

    Assert-Result -Name "real crash got 139 exception thrown" -Condition ($null -ne $caught) -FailureMessage "expected exception to be thrown"
    Assert-Result -Name "real crash got 139 labeled as SIGSEGV" -Condition ($caught -match "child process died on SIGSEGV \(exit 139\)") -FailureMessage ("expected SIGSEGV label in exception message, got: " + $caught)
}

# --- Summary ---
$passed = @($results | Where-Object { $_ -eq $true }).Count
$failed = @($results | Where-Object { $_ -eq $false }).Count
Write-Host "`n========================="
Write-Host "Passed: $passed / Failed: $failed"
if ($failed -gt 0) {
    exit 1
}
exit 0