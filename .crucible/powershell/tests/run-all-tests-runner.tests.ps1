# Tests for powershell/run-all-tests.ps1.
# Verifies that run-all-tests.ps1 exits non-zero when zero test files are discovered in both parallel and serial modes,
# and exits zero when a test file is discovered and passes.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")

$RUNNER_SCRIPT = Join-Path $REPO_ROOT "powershell/run-all-tests.ps1"
$HARNESS_SCRIPT = Join-Path $PSScriptRoot "_harness.ps1"

$results = @()

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-test-runner-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    function Stage-RunnerScratch {
        param([string]$Dir)

        $powershellDir = Join-Path $Dir "powershell"
        $testsDir = Join-Path $powershellDir "tests"
        New-Item -ItemType Directory -Path $testsDir -Force | Out-Null

        Copy-Item -LiteralPath $RUNNER_SCRIPT -Destination (Join-Path $powershellDir "run-all-tests.ps1") -Force
        Copy-Item -LiteralPath $HARNESS_SCRIPT -Destination (Join-Path $testsDir "_harness.ps1") -Force

        $fixturesContent = "function Get-SharedAdopterFixture { return `$null }"
        Set-Content -LiteralPath (Join-Path $testsDir "_fixtures.ps1") -Value $fixturesContent -Encoding UTF8

        return $powershellDir
    }

    $results += Run-Test -Name "Exits non-zero when zero test files discovered (parallel mode)" -Body {
        $scratchDir = Join-Path $tempRoot "parallel-empty"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "parallel empty exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "parallel empty output warning" -Condition ($output -match "No test files discovered") -FailureMessage ("expected 'No test files discovered' in output: " + $output)
    }

    $results += Run-Test -Name "Exits non-zero when zero test files discovered (serial mode)" -Body {
        $scratchDir = Join-Path $tempRoot "serial-empty"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -Serial 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "serial empty exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "serial empty output warning" -Condition ($output -match "No test files discovered") -FailureMessage ("expected 'No test files discovered' in output: " + $output)
    }

    $results += Run-Test -Name "Exits zero when test files are discovered and pass" -Body {
        $scratchDir = Join-Path $tempRoot "synthetic-pass"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $syntheticTest = Join-Path $testsDir "synthetic.tests.ps1"
        $syntheticContent = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
$results = @()
$results += Run-Test -Name "Synthetic pass" -Body {
    Assert-Result -Name "Always passes" -Condition ($true) -FailureMessage "Never fails"
}
if ($results -contains $false) { exit 1 }
exit 0
'@
        Set-Content -LiteralPath $syntheticTest -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "synthetic pass exit code" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "synthetic pass summary" -Condition ($output -match "Passed: 1") -FailureMessage ("expected 'Passed: 1' in output: " + $output)
    }

    $results += Run-Test -Name "Exits non-zero when child test prints failure signature and exits 0 (parallel mode)" -Body {
        $scratchDir = Join-Path $tempRoot "parallel-stdout-fail"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $syntheticTest = Join-Path $testsDir "unaggregated-fail.tests.ps1"
        $syntheticContent = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
Run-Test -Name "Failing test" -Body {
    Assert-Result -Name "Synthetic failure" -Condition ($false) -FailureMessage "boom"
}
exit 0
'@
        Set-Content -LiteralPath $syntheticTest -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "parallel stdout fail exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "parallel stdout fail summary" -Condition ($output -match "Failed: 1 \(unaggregated-fail.tests.ps1\)") -FailureMessage ("expected 'Failed: 1 (unaggregated-fail.tests.ps1)' in output: " + $output)
        Assert-Result -Name "parallel stdout fail detailed failure output" -Condition ($output -match "EXCEPTION OCCURRED: FAILED: Synthetic failure - boom") -FailureMessage ("expected captured exception output in detailed failure: " + $output)
    }

    $results += Run-Test -Name "Exits non-zero when child test prints failure signature and exits 0 (serial mode)" -Body {
        $scratchDir = Join-Path $tempRoot "serial-stdout-fail"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $syntheticTest = Join-Path $testsDir "unaggregated-fail.tests.ps1"
        $syntheticContent = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
Run-Test -Name "Failing test" -Body {
    Assert-Result -Name "Synthetic failure" -Condition ($false) -FailureMessage "boom"
}
exit 0
'@
        Set-Content -LiteralPath $syntheticTest -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -Serial 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "serial stdout fail exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "serial stdout fail summary" -Condition ($output -match "Failed: 1 \(unaggregated-fail.tests.ps1\)") -FailureMessage ("expected 'Failed: 1 (unaggregated-fail.tests.ps1)' in output: " + $output)
    }

    $results += Run-Test -Name "Failure signature is not suppressible by any in-band marker (parallel mode)" -Body {
        $scratchDir = Join-Path $tempRoot "unsuppressible-stdout-fail-parallel"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $syntheticTest = Join-Path $testsDir "unsuppressible-fail.tests.ps1"
        $syntheticContent = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
Write-Host "CRUCIBLE_ALLOW_FAILURE_SIGNATURE"
Write-Host "EXCEPTION OCCURRED: FAILED: Synthetic failure - unsuppressed"
exit 0
'@
        Set-Content -LiteralPath $syntheticTest -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "unsuppressible failure parallel exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "unsuppressible failure parallel summary" -Condition ($output -match "Failed: 1 \(unsuppressible-fail.tests.ps1\)") -FailureMessage ("expected 'Failed: 1 (unsuppressible-fail.tests.ps1)' in output: " + $output)
    }

    $results += Run-Test -Name "Failure signature is not suppressible by any in-band marker (serial mode)" -Body {
        $scratchDir = Join-Path $tempRoot "unsuppressible-stdout-fail-serial"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $syntheticTest = Join-Path $testsDir "unsuppressible-fail.tests.ps1"
        $syntheticContent = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
Write-Host "CRUCIBLE_ALLOW_FAILURE_SIGNATURE"
Write-Host "EXCEPTION OCCURRED: FAILED: Synthetic failure - unsuppressed"
exit 0
'@
        Set-Content -LiteralPath $syntheticTest -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -Serial 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "unsuppressible failure serial exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "unsuppressible failure serial summary" -Condition ($output -match "Failed: 1 \(unsuppressible-fail.tests.ps1\)") -FailureMessage ("expected 'Failed: 1 (unsuppressible-fail.tests.ps1)' in output: " + $output)
    }

    $results += Run-Test -Name "Exits zero when child test prints lowercase failure prose and exits 0" -Body {
        $scratchDir = Join-Path $tempRoot "prose-lowercase-pass"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $syntheticTest = Join-Path $testsDir "prose-lowercase.tests.ps1"
        $syntheticContent = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
Write-Host "this operation failed: but was retried and succeeded; some tests failed earlier but now pass"
exit 0
'@
        Set-Content -LiteralPath $syntheticTest -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "prose lowercase pass exit code" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "prose lowercase pass summary" -Condition ($output -match "Passed: 1") -FailureMessage ("expected 'Passed: 1' in output: " + $output)
    }

    # Test-OutputHasFailure ors three signatures together, and every other synthetic
    # child above prints "EXCEPTION OCCURRED: FAILED: ..." which satisfies two of them
    # at once. Any single clause could therefore be deleted with the whole suite still
    # green. These three drive a child whose output matches one clause and no other.

    # Test names must not spell any signature literally: the harness echoes the name on
    # a passing run, so the literal would land on this file's own stdout and the parent
    # runner would scan it and fail a green file.
    $results += Run-Test -Name "Exception-signature clause alone is load-bearing" -Body {
        $scratchDir = Join-Path $tempRoot "clause-exception"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $syntheticTest = Join-Path $testsDir "clause-exception.tests.ps1"
        $syntheticContent = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
Write-Host "EXCEPTION OCCURRED: detached from any other signature"
exit 0
'@
        Set-Content -LiteralPath $syntheticTest -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "exception clause exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "exception clause summary" -Condition ($output -match "Failed: 1 \(clause-exception.tests.ps1\)") -FailureMessage ("expected 'Failed: 1 (clause-exception.tests.ps1)' in output: " + $output)
    }

    $results += Run-Test -Name "Aggregate-summary clause alone is load-bearing" -Body {
        $scratchDir = Join-Path $tempRoot "clause-aggregate"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $syntheticTest = Join-Path $testsDir "clause-aggregate.tests.ps1"
        $syntheticContent = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
Write-Host "SOME TESTS FAILED"
exit 0
'@
        Set-Content -LiteralPath $syntheticTest -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "aggregate clause exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "aggregate clause summary" -Condition ($output -match "Failed: 1 \(clause-aggregate.tests.ps1\)") -FailureMessage ("expected 'Failed: 1 (clause-aggregate.tests.ps1)' in output: " + $output)
    }

    $results += Run-Test -Name "Assertion-signature clause alone is load-bearing" -Body {
        $scratchDir = Join-Path $tempRoot "clause-assertion"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $syntheticTest = Join-Path $testsDir "clause-assertion.tests.ps1"
        $syntheticContent = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
Write-Host "FAILED: Synthetic case - detached from any other signature"
exit 0
'@
        Set-Content -LiteralPath $syntheticTest -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "assertion clause exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "assertion clause summary" -Condition ($output -match "Failed: 1 \(clause-assertion.tests.ps1\)") -FailureMessage ("expected 'Failed: 1 (clause-assertion.tests.ps1)' in output: " + $output)
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
