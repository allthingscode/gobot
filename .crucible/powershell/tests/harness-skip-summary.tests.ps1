# Item 104: a file that Skip-Tests does not report the skip as a pass in its own tail.
# Item 344: a nested test file's skip reaches the outer runner once.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")

$results = @()
$tempRoot = New-TestFixtureRoot -NameHint "skip-summary"

$OLD_TAIL = @'
if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
'@

function New-SkipSummaryChild {
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Tail
    )

    $testsDir = Join-Path $Dir "tests"
    New-Item -ItemType Directory -Path $testsDir -Force | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot "_*.ps1") -Destination $testsDir -Force

    $body = @"
`$ErrorActionPreference = "Stop"
. (Join-Path `$PSScriptRoot "_harness.ps1")
`$results = @()
`$results += Run-Test -Name "passes" -Body {
    Assert-Result -Name "ok" -Condition `$true -FailureMessage "no"
}
`$results += Run-Test -Name "skips" -Body {
    Skip-Test "this platform cannot supply the precondition"
}
$Tail
"@
    $file = Join-Path $testsDir "skipping.tests.ps1"
    Set-Content -LiteralPath $file -Value $body -Encoding UTF8
    return $file
}

function Test-TailReportsSkip {
    param([Parameter(Mandatory = $true)][string]$Output)

    if ($Output -cnotmatch '(?m)^SKIPPED: skips - this platform cannot supply the precondition\s*$') {
        return $false
    }
    if ($Output -cnotmatch '(?m)^ALL TESTS PASSED \(1 tests, 1 skipped\)\s*$') {
        return $false
    }
    if ($Output -cmatch '(?m)^ALL TESTS PASSED \(2 tests\)\s*$') {
        return $false
    }
    return $true
}

try {
    $results += Run-Test -Name "A file that skips does not report the skip as passed" -Body {
        $dir = Join-Path $tempRoot "helper"
        $file = New-SkipSummaryChild -Dir $dir -Tail "Write-TestFileSummary -Results `$results"
        $cmd = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $file
        }
        Assert-Result -Name "skipping file exits 0" -Condition ($cmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $cmd.ExitCode + ". Output: " + $cmd.Output)
        Assert-Result -Name "the file that skips reports the skip in its own tail" -Condition (Test-TailReportsSkip -Output $cmd.Output) -FailureMessage ("expected ALL TESTS PASSED (1 tests, 1 skipped) and not (2 tests). Output: " + $cmd.Output)
    }

    $results += Run-Test -Name "Restoring the old tail fails that check" -Body {
        $dir = Join-Path $tempRoot "old-tail"
        $file = New-SkipSummaryChild -Dir $dir -Tail $OLD_TAIL
        $cmd = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $file
        }
        Assert-Result -Name "old tail still exits 0" -Condition ($cmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $cmd.ExitCode + ". Output: " + $cmd.Output)
        Assert-Result -Name "old tail counts the skip as a test that ran" -Condition ($cmd.Output -cmatch '(?m)^ALL TESTS PASSED \(2 tests\)\s*$') -FailureMessage ("expected the duplicated `$results.Count tail to print ALL TESTS PASSED (2 tests). Output: " + $cmd.Output)
        Assert-Result -Name "the honest-tail check rejects the old tail" -Condition (-not (Test-TailReportsSkip -Output $cmd.Output)) -FailureMessage ("restoring the old tail still satisfied the honest-tail check. Output: " + $cmd.Output)
    }

    # Item 344: a wrapper that runs a real test file republishes the child's skip once, a
    # wrapper of that wrapper republishes it once more without a second copy, and a fixture
    # that only captures a child publishes nothing.
    $results += Run-Test -Name "A nested test file's skip reaches the outer runner once, and a fixture's does not" -Body {
        $child = New-SkipSummaryChild -Dir (Join-Path $tempRoot "nested") -Tail "Write-TestFileSummary -Results `$results"
        $testsDir = Split-Path -Parent $child
        $wrapperBody = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
$results = @()
$results += Run-Test -Name "runs the child" -Body {
    $r = Invoke-NestedTestFile -Path (Join-Path $PSScriptRoot "{0}")
    Assert-Result -Name "child exit 0" -Condition ($r.ExitCode -eq 0) -FailureMessage $r.Output
}
Write-TestFileSummary -Results $results
'@
        $fixtureBody = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
$results = @()
$results += Run-Test -Name "captures a planted skip" -Body {
    $shell = (Get-Process -Id $PID).Path
    $file = Join-Path $PSScriptRoot "skipping.tests.ps1"
    $r = Invoke-ExternalCommand { & $shell -NoProfile -ExecutionPolicy Bypass -File $file }
    Assert-Result -Name "planted skip captured" -Condition ($r.Output -cmatch '(?m)^SKIPPED: skips - ') -FailureMessage $r.Output
}
Write-TestFileSummary -Results $results
'@
        $wrapper = Join-Path $testsDir "wrapper.tests.ps1"
        $outer = Join-Path $testsDir "outer.tests.ps1"
        $fixture = Join-Path $testsDir "fixture.tests.ps1"
        Set-Content -LiteralPath $wrapper -Value ($wrapperBody.Replace("{0}", "skipping.tests.ps1")) -Encoding UTF8
        Set-Content -LiteralPath $outer -Value ($wrapperBody.Replace("{0}", "wrapper.tests.ps1")) -Encoding UTF8
        Set-Content -LiteralPath $fixture -Value $fixtureBody -Encoding UTF8
        $reason = "skips - this platform cannot supply the precondition"

        $w = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $wrapper }
        Assert-Result -Name "wrapper exits 0" -Condition ($w.ExitCode -eq 0) -FailureMessage $w.Output
        $wSkips = @([regex]::Matches($w.Output, '(?m)^SKIPPED: .*$') | ForEach-Object { $_.Value.TrimEnd() })
        Assert-Result -Name "the wrapper publishes the child's skip once, naming the child" -Condition ($wSkips.Count -eq 1 -and $wSkips[0] -ceq ("SKIPPED: skipping.tests.ps1: " + $reason)) -FailureMessage ("expected one anchored skip line naming skipping.tests.ps1. Output: " + $w.Output)
        Assert-Result -Name "the wrapper's tail counts the nested skip apart from its own cases" -Condition ($w.Output -cmatch '(?m)^ALL TESTS PASSED \(1 tests, 1 nested skipped\)\s*$') -FailureMessage $w.Output

        $o = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $outer }
        Assert-Result -Name "outer wrapper exits 0" -Condition ($o.ExitCode -eq 0) -FailureMessage $o.Output
        $oSkips = @([regex]::Matches($o.Output, '(?m)^SKIPPED: .*$') | ForEach-Object { $_.Value.TrimEnd() })
        Assert-Result -Name "two levels of nesting still count the skip once" -Condition ($oSkips.Count -eq 1 -and $oSkips[0] -ceq ("SKIPPED: wrapper.tests.ps1: skipping.tests.ps1: " + $reason)) -FailureMessage ("expected one anchored skip line naming both files. Output: " + $o.Output)

        $f = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $fixture }
        Assert-Result -Name "fixture exits 0" -Condition ($f.ExitCode -eq 0) -FailureMessage $f.Output
        Assert-Result -Name "a captured fixture's planted skip is not published" -Condition ($f.Output -cnotmatch '(?m)^SKIPPED: ') -FailureMessage $f.Output
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-TestFileSummary -Results $results
