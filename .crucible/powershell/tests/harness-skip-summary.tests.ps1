# Item 104: a file that Skip-Tests does not report the skip as a pass in its own tail.

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
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-TestFileSummary -Results $results
