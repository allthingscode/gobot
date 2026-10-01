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

$tempRoot = New-TestFixtureRoot -NameHint "test-runner"

try {
    function Stage-RunnerScratch {
        param([string]$Dir)

        $powershellDir = Join-Path $Dir "powershell"
        $testsDir = Join-Path $powershellDir "tests"
        New-Item -ItemType Directory -Path $testsDir -Force | Out-Null

        Copy-Item -LiteralPath $RUNNER_SCRIPT -Destination (Join-Path $powershellDir "run-all-tests.ps1") -Force
        # Every helper, not just _harness.ps1: it dot-sources _ownership.ps1 since item 90, and a
        # fixture that copies "the real script" by name goes stale the moment the caller gains a
        # second one. No _*.ps1 matches the runner's *test*.ps1 discovery glob, so copying all of
        # them cannot smuggle a test file into the scratch suite.
        Copy-Item -Path (Join-Path (Split-Path -Parent $HARNESS_SCRIPT) "_*.ps1") -Destination $testsDir -Force

        # The runner dot-sources its concurrency lock from lib/, so a scratch copy is
        # not runnable without it. The lock is scoped to the runner's own directory,
        # which is why these nested runs do not collide with the outer suite.
        $libDir = Join-Path $powershellDir "lib"
        New-Item -ItemType Directory -Path $libDir -Force | Out-Null
        foreach ($lib in @("run-lock.ps1", "normalized-hash.ps1")) {
            Copy-Item -LiteralPath (Join-Path $REPO_ROOT "powershell/lib/$lib") -Destination (Join-Path $libDir $lib) -Force
        }

        # The nested runner reaps run roots for real. That is safe because collection is
        # by dead owner, and the outer suite's root is owned by a process that is very
        # much alive. Only the fixture build is stubbed, since it needs a whole
        # framework this scratch root does not have.
        $fixturesContent = @'
function Get-SharedAdopterFixture { return $null }
'@
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
        # The other half of item 102's skip reporting: a run with nothing skipped must not print a
        # Skipped line at all. Without this, a summary that always printed "Skipped: 0" - or one
        # whose count came from somewhere other than the child output - would satisfy the skip test
        # below without measuring anything.
        Assert-Result -Name "no skip line when nothing skipped" -Condition ($output -notmatch "Skipped:") -FailureMessage ("a run with no skipped test still reported a skip count: " + $output)
    }

    # Item 102. A test whose precondition cannot exist on the running platform is neither a pass
    # nor a failure, and before this there was no third answer: run-lock.tests.ps1 asserted its
    # Windows-only precondition on purpose, so it failed every Linux run. Both modes are exercised
    # because the runner carries two separate summary blocks.
    foreach ($mode in @("parallel", "serial")) {
        $results += Run-Test -Name ("A skipped test does not fail the run and is named in the summary (" + $mode + " mode)") -Body {
            $scratchDir = Join-Path $tempRoot ("synthetic-skip-" + $mode)
            $psDir = Stage-RunnerScratch -Dir $scratchDir
            $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
            $testsDir = Join-Path $psDir "tests"

            $syntheticTest = Join-Path $testsDir "synthetic-skip.tests.ps1"
            $syntheticContent = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
$results = @()
$results += Run-Test -Name "Synthetic skip" -Body {
    Skip-Test "this platform cannot supply the precondition"
}
if ($results -contains $false) { exit 1 }
exit 0
'@
            Set-Content -LiteralPath $syntheticTest -Value $syntheticContent -Encoding UTF8

            if ($mode -eq "serial") {
                $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -Serial 2>&1)
            } else {
                $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy 2>&1)
            }
            $exitCode = $LASTEXITCODE
            $output = $outputLines -join "`n"

            Assert-Result -Name "a skip does not fail the run" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)
            Assert-Result -Name "the skip is counted" -Condition ($output -match "Skipped: 1") -FailureMessage ("expected 'Skipped: 1' in output: " + $output)
            Assert-Result -Name "the summary names the file and the test" -Condition ($output -match "synthetic-skip\.tests\.ps1: Synthetic skip") -FailureMessage ("the skip was counted without saying which test it was: " + $output)
            Assert-Result -Name "the summary carries the stated reason" -Condition ($output -match "this platform cannot supply the precondition") -FailureMessage ("the reason given to Skip-Test did not reach the summary: " + $output)
            # The distinction that makes this worth having. A skip that printed PASSED for the test
            # would be the vacuous pass the mechanism exists to replace, and the run would look
            # identical to one where the assertion really ran.
            # -cnotmatch, and anchored at both ends. The harness prints exactly "PASSED" on its own
            # line; the summary prints "Passed: 1", and -notmatch is case-insensitive, so the
            # obvious spelling of this assertion fails against the run's own summary line.
            Assert-Result -Name "the skipped test is not reported as passed" -Condition ($output -cnotmatch "(?m)^PASSED\s*$") -FailureMessage ("a skipped test printed PASSED as well as SKIPPED: " + $output)
        }
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

    $results += Run-Test -Name "Serial mode kills a silent child after the idle timeout" -Body {
        $scratchDir = Join-Path $tempRoot "serial-idle-timeout"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $syntheticContent = @'
Start-Sleep -Seconds 20
exit 0
'@
        Set-Content -LiteralPath (Join-Path $testsDir "silent.tests.ps1") -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -Serial -IdleTimeoutSeconds 1 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "silent timeout exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "silent timeout report" -Condition ($output -match "FAIL  silent.tests.ps1 \(TIMEOUT after 1s\)") -FailureMessage ("expected timeout failure in output: " + $output)
    }

    $results += Run-Test -Name "Serial mode lets a slow talking child exceed the idle timeout" -Body {
        $scratchDir = Join-Path $tempRoot "serial-talking"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        # Runs 7s in 1s steps against a 5s threshold. Total runtime has to exceed the
        # threshold or an implementation measuring elapsed-since-start would pass this
        # too, but the per-line gap needs several times the threshold's margin: the
        # first line cannot arrive until the child shell has started, and this file runs
        # alongside seven others.
        $syntheticContent = @'
foreach ($number in 1..7) {
    Write-Host "progress $number"
    Start-Sleep -Seconds 1
}
exit 0
'@
        Set-Content -LiteralPath (Join-Path $testsDir "talking.tests.ps1") -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -Serial -IdleTimeoutSeconds 5 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "talking child exit code" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "talking child completes all progress" -Condition ($output -match "progress 7") -FailureMessage ("expected final progress line in output: " + $output)
        Assert-Result -Name "talking child has no timeout report" -Condition ($output -notmatch "TIMEOUT") -FailureMessage ("did not expect timeout in output: " + $output)
    }

    $results += Run-Test -Name "Serial mode NoTimeout lets a silent child finish" -Body {
        $scratchDir = Join-Path $tempRoot "serial-no-timeout"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $syntheticContent = @'
Start-Sleep -Seconds 3
exit 0
'@
        Set-Content -LiteralPath (Join-Path $testsDir "silent-finish.tests.ps1") -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -Serial -IdleTimeoutSeconds 1 -NoTimeout 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "NoTimeout child exit code" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "NoTimeout child has no timeout report" -Condition ($output -notmatch "TIMEOUT") -FailureMessage ("did not expect timeout in output: " + $output)
    }

    $results += Run-Test -Name "Serial mode resets the idle timeout from stderr" -Body {
        $scratchDir = Join-Path $tempRoot "serial-stderr-talking"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        # Nothing is written to stdout at all, so this child is silent for its whole
        # 7s run to a stdout-only idle check. Same 5s threshold and startup margin as
        # the talking-child case above.
        $syntheticContent = @'
foreach ($number in 1..7) {
    [Console]::Error.WriteLine("stderr progress $number")
    Start-Sleep -Seconds 1
}
exit 0
'@
        Set-Content -LiteralPath (Join-Path $testsDir "stderr-talking.tests.ps1") -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -Serial -IdleTimeoutSeconds 5 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "stderr talking child exit code" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "stderr talking child completes all progress" -Condition ($output -match "stderr progress 7") -FailureMessage ("expected final stderr progress line in output: " + $output)
        Assert-Result -Name "stderr talking child has no timeout report" -Condition ($output -notmatch "TIMEOUT") -FailureMessage ("did not expect timeout in output: " + $output)
    }

    $results += Run-Test -Name "Serial mode gives up on a timed-out child that leaked its pipes" -Body {
        $scratchDir = Join-Path $tempRoot "serial-orphan-holder"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $holderPidFile = Join-Path $scratchDir "holder-pid.txt"

        # The hung test spawns a process that inherits its stdout and stderr handles, so
        # killing the test does not close those pipes and the runner's pending reads
        # never complete. A runner that waits for end of stream after the kill hangs on
        # exactly the case the idle timeout exists to break, so the timeout has to stop
        # reading rather than wait. This test is run as a bounded process for that
        # reason: a regression here hangs the runner, and must not hang the suite too.
        $syntheticContent = @'
$holder = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 90' -NoNewWindow -PassThru
Set-Content -LiteralPath "__PID_FILE__" -Value $holder.Id -Encoding ASCII
Start-Sleep -Seconds 90
exit 0
'@
        $syntheticContent = $syntheticContent.Replace("__PID_FILE__", $holderPidFile)
        Set-Content -LiteralPath (Join-Path $testsDir "orphan-holder.tests.ps1") -Value $syntheticContent -Encoding UTF8

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-PwshCommand)
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runnerCopy`" -Serial -IdleTimeoutSeconds 2"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        $exited = $p.WaitForExit(60000)
        if (-not $exited) {
            try { $p.Kill() } catch {}
            $p.WaitForExit()
        }

        $output = $outTask.Result
        if ($null -eq $output) { $output = "" }

        $exitCode = $p.ExitCode
        $p.Dispose()

        if (Test-Path -LiteralPath $holderPidFile) {
            # Empty when the runner killed the child between creating the file and writing it.
            $holderPid = ([string](Get-Content -LiteralPath $holderPidFile -Raw)).Trim()
            if ($holderPid -match '^\d+$') {
                $holderProc = Get-Process -Id ([int]$holderPid) -ErrorAction SilentlyContinue
                if ($null -ne $holderProc) { try { $holderProc.Kill() } catch {} }
            }
        }

        Assert-Result -Name "leaked-pipe runner exits" -Condition ($exited) -FailureMessage ("runner did not exit within 60s after killing a timed-out child that leaked its pipes. Output: " + $output)
        Assert-Result -Name "leaked-pipe timeout report" -Condition ($output -match "FAIL  orphan-holder.tests.ps1 \(TIMEOUT after 2s\)") -FailureMessage ("expected timeout failure in output: " + $output)
        Assert-Result -Name "leaked-pipe exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
    }

    $results += Run-Test -Name "Serial mode streams child output before the child exits" -Body {
        $scratchDir = Join-Path $tempRoot "serial-streaming"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $releaseFile = Join-Path $scratchDir "release-child.txt"

        # The child prints a marker and then blocks until this test creates the release
        # file, which this test only does once it has read the marker. So the proof is a
        # deadlock rather than a stopwatch: if serial mode buffered stdout the marker
        # could not arrive, the release would never be written, and the read loop below
        # would expire. Sleeping in the child and comparing elapsed time would instead be
        # a race against process startup under a loaded suite.
        $syntheticContent = @'
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_harness.ps1")
Write-Host "STREAM-MARKER-BEFORE-EXIT"
$releaseFile = "__RELEASE_FILE__"
$deadline = [DateTime]::UtcNow.AddSeconds(120)
while (-not (Test-Path -LiteralPath $releaseFile) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
}
$results = @()
$results += Run-Test -Name "Streaming child" -Body {
    Assert-Result -Name "Always passes" -Condition ($true) -FailureMessage "Never fails"
}
if ($results -contains $false) { exit 1 }
exit 0
'@
        $syntheticContent = $syntheticContent.Replace("__RELEASE_FILE__", $releaseFile)
        Set-Content -LiteralPath (Join-Path $testsDir "streaming.tests.ps1") -Value $syntheticContent -Encoding UTF8

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-PwshCommand)
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runnerCopy`" -Serial"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        $errTask = $p.StandardError.ReadToEndAsync()

        $seen = New-Object System.Collections.Generic.List[string]
        $markerSeen = $false
        $lineTask = $null
        $readDeadline = [DateTime]::UtcNow.AddSeconds(90)

        while (-not $markerSeen -and [DateTime]::UtcNow -lt $readDeadline) {
            if ($null -eq $lineTask) { $lineTask = $p.StandardOutput.ReadLineAsync() }
            # A pending task has to be carried across a wait that times out. Issuing a
            # second ReadLineAsync on the same reader while one is outstanding is not
            # defined, and the abandoned one would still swallow a line.
            if ($lineTask.Wait(500)) {
                $line = $lineTask.Result
                $lineTask = $null
                if ($null -eq $line) { break }
                [void]$seen.Add($line)
                if ($line -match "STREAM-MARKER-BEFORE-EXIT") { $markerSeen = $true }
            }
        }

        # Released before any assertion, so a failure cannot leave the child parked on
        # its own deadline.
        Set-Content -LiteralPath $releaseFile -Value "go" -Encoding UTF8

        while ($true) {
            if ($null -eq $lineTask) { $lineTask = $p.StandardOutput.ReadLineAsync() }
            if (-not $lineTask.Wait(180000)) { break }
            $line = $lineTask.Result
            $lineTask = $null
            if ($null -eq $line) { break }
            [void]$seen.Add($line)
        }

        $p.WaitForExit()
        $exitCode = $p.ExitCode
        $p.Dispose()

        $output = ($seen -join "`n")
        $errText = $errTask.Result
        if ($null -eq $errText) { $errText = "" }

        Assert-Result -Name "serial streaming: child output arrives while the child is still running" -Condition $markerSeen -FailureMessage ("the child marker never arrived within 90s, so serial mode held the child stdout until exit. Output: " + $output + " Stderr: " + $errText)
        Assert-Result -Name "serial streaming: streamed run exits zero" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output + " Stderr: " + $errText)
        Assert-Result -Name "serial streaming: streaming does not cost the summary" -Condition ($output -match "Passed: 1") -FailureMessage ("expected 'Passed: 1' in output: " + $output)
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

    $results += Run-Test -Name "Parallel mode kills a silent child after the idle timeout" -Body {
        $scratchDir = Join-Path $tempRoot "parallel-idle-timeout"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $syntheticContent = @'
Start-Sleep -Seconds 20
exit 0
'@
        Set-Content -LiteralPath (Join-Path $testsDir "parallel-silent.tests.ps1") -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -IdleTimeoutSeconds 1 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "parallel silent timeout exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "parallel silent timeout report" -Condition ($output -match "FAIL  parallel-silent.tests.ps1 \(TIMEOUT after 1s\)") -FailureMessage ("expected timeout failure in output: " + $output)
    }

    $results += Run-Test -Name "Parallel mode lets a slow talking child exceed the idle timeout" -Body {
        $scratchDir = Join-Path $tempRoot "parallel-talking"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        # The pool used to cap on total runtime, so this is the case that distinguishes
        # the two: 7s of work against a 5s threshold, still printing the whole way. A
        # wall-clock implementation kills it; an idle one does not. Parallel mode prints
        # nothing for a passing child, so the proof is the absence of the timeout rather
        # than the presence of the progress lines.
        $syntheticContent = @'
foreach ($number in 1..7) {
    Write-Host "progress $number"
    Start-Sleep -Seconds 1
}
exit 0
'@
        Set-Content -LiteralPath (Join-Path $testsDir "parallel-talking.tests.ps1") -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -IdleTimeoutSeconds 5 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "parallel talking child exit code" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "parallel talking child has no timeout report" -Condition ($output -notmatch "TIMEOUT") -FailureMessage ("did not expect timeout in output: " + $output)
        Assert-Result -Name "parallel talking child passes" -Condition ($output -match "PASS  parallel-talking.tests.ps1") -FailureMessage ("expected a PASS line in output: " + $output)
    }

    $results += Run-Test -Name "Parallel mode resets the idle timeout from stderr" -Body {
        $scratchDir = Join-Path $tempRoot "parallel-stderr-talking"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        # Nothing reaches stdout at all, so this child is silent for its whole 7s run to
        # an idle check that watches stdout alone.
        $syntheticContent = @'
foreach ($number in 1..7) {
    [Console]::Error.WriteLine("stderr progress $number")
    Start-Sleep -Seconds 1
}
exit 0
'@
        Set-Content -LiteralPath (Join-Path $testsDir "parallel-stderr.tests.ps1") -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -IdleTimeoutSeconds 5 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "parallel stderr child exit code" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "parallel stderr child has no timeout report" -Condition ($output -notmatch "TIMEOUT") -FailureMessage ("did not expect timeout in output: " + $output)
    }

    $results += Run-Test -Name "Parallel mode NoTimeout lets a silent child finish" -Body {
        $scratchDir = Join-Path $tempRoot "parallel-no-timeout"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $syntheticContent = @'
Start-Sleep -Seconds 3
exit 0
'@
        Set-Content -LiteralPath (Join-Path $testsDir "parallel-silent-finish.tests.ps1") -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -IdleTimeoutSeconds 1 -NoTimeout 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "parallel NoTimeout child exit code" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "parallel NoTimeout child has no timeout report" -Condition ($output -notmatch "TIMEOUT") -FailureMessage ("did not expect timeout in output: " + $output)
    }

    $results += Run-Test -Name "Parallel mode collects a failing child's whole output on both streams" -Body {
        $scratchDir = Join-Path $tempRoot "parallel-output-capture"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        # The pool reads line by line so it can time each line's arrival, and buffers the
        # lines to report at the end. Reading to end of stream could not lose anything;
        # reading line by line can, at either edge or across the buffer refill in the
        # middle, so the reported output has to be checked and not assumed.
        $syntheticContent = @'
[Console]::Error.WriteLine("ERR-MARKER-FIRST")
Write-Host "OUT-MARKER-FIRST"
foreach ($number in 1..500) {
    Write-Host ("filler line " + $number)
}
Write-Host "OUT-MARKER-LAST"
[Console]::Error.WriteLine("ERR-MARKER-LAST")
exit 3
'@
        Set-Content -LiteralPath (Join-Path $testsDir "parallel-chatty.tests.ps1") -Value $syntheticContent -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $runnerCopy -IdleTimeoutSeconds 30 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "parallel capture exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "parallel capture reports the child exit code" -Condition ($output -match "ExitCode: 3") -FailureMessage ("expected the child exit code in output: " + $output)
        Assert-Result -Name "parallel capture keeps the first stdout line" -Condition ($output -match "OUT-MARKER-FIRST") -FailureMessage ("first stdout line missing from reported output: " + $output)
        Assert-Result -Name "parallel capture keeps the last stdout line" -Condition ($output -match "OUT-MARKER-LAST") -FailureMessage ("last stdout line missing from reported output: " + $output)
        Assert-Result -Name "parallel capture keeps the middle of stdout" -Condition ($output -match "filler line 500") -FailureMessage ("bulk stdout missing from reported output: " + $output)
        Assert-Result -Name "parallel capture keeps the first stderr line" -Condition ($output -match "ERR-MARKER-FIRST") -FailureMessage ("first stderr line missing from reported output: " + $output)
        Assert-Result -Name "parallel capture keeps the last stderr line" -Condition ($output -match "ERR-MARKER-LAST") -FailureMessage ("last stderr line missing from reported output: " + $output)
    }

    $results += Run-Test -Name "Parallel mode gives up on a timed-out child that leaked its pipes" -Body {
        $scratchDir = Join-Path $tempRoot "parallel-orphan-holder"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $holderPidFile = Join-Path $scratchDir "holder-pid.txt"

        # Same leak as the serial case, and the reason the pool cannot simply wait for its
        # reads once a child is gone: killing the test does not close pipes a grandchild
        # inherited, so a pool that reads to end of stream after the kill hangs on exactly
        # the case the timeout exists to break. Run as a bounded process because a
        # regression here hangs the runner, and must not hang the suite with it.
        $syntheticContent = @'
$holder = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 90' -NoNewWindow -PassThru
Set-Content -LiteralPath "__PID_FILE__" -Value $holder.Id -Encoding ASCII
Start-Sleep -Seconds 90
exit 0
'@
        $syntheticContent = $syntheticContent.Replace("__PID_FILE__", $holderPidFile)
        Set-Content -LiteralPath (Join-Path $testsDir "parallel-orphan.tests.ps1") -Value $syntheticContent -Encoding UTF8

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-PwshCommand)
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runnerCopy`" -IdleTimeoutSeconds 2"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        [void]$p.StandardError.ReadToEndAsync()

        $exited = $p.WaitForExit(60000)
        if (-not $exited) {
            try { $p.Kill() } catch {}
            $p.WaitForExit()
        }

        $output = $outTask.Result
        if ($null -eq $output) { $output = "" }

        $exitCode = $p.ExitCode
        $p.Dispose()

        if (Test-Path -LiteralPath $holderPidFile) {
            # Empty when the runner killed the child between creating the file and writing it.
            $holderPid = ([string](Get-Content -LiteralPath $holderPidFile -Raw)).Trim()
            if ($holderPid -match '^\d+$') {
                $holderProc = Get-Process -Id ([int]$holderPid) -ErrorAction SilentlyContinue
                if ($null -ne $holderProc) { try { $holderProc.Kill() } catch {} }
            }
        }

        Assert-Result -Name "parallel leaked-pipe runner exits" -Condition ($exited) -FailureMessage ("runner did not exit within 60s after killing a timed-out child that leaked its pipes. Output: " + $output)
        Assert-Result -Name "parallel leaked-pipe timeout report" -Condition ($output -match "FAIL  parallel-orphan.tests.ps1 \(TIMEOUT after 2s\)") -FailureMessage ("expected timeout failure in output: " + $output)
        Assert-Result -Name "parallel leaked-pipe exit code" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit code, got " + $exitCode + ". Output: " + $output)
    }

    $results += Run-Test -Name "Parallel mode does not call a finished child a timeout when its pipes are held open" -Body {
        $scratchDir = Join-Path $tempRoot "parallel-exited-holder"
        $psDir = Stage-RunnerScratch -Dir $scratchDir
        $runnerCopy = Join-Path $psDir "run-all-tests.ps1"
        $testsDir = Join-Path $psDir "tests"

        $holderPidFile = Join-Path $scratchDir "holder-pid.txt"

        # Three numbers with a required ordering, so they are derived rather than written
        # out separately: startup budget << runner bound < pipe hold.
        #
        # $idleTimeout is the budget for the child to get from launch to exit. That whole
        # interval is silent - the child never writes a byte - and the pool's idle clock
        # starts at Start(), so any excursion past the threshold while the child is still
        # alive is killed and reported as a timeout. That is the runner behaving correctly;
        # a silent running child IS what the timeout is for. This value was 2s, which is a
        # 1.8x margin over the worst launch measured here (781 samples taken during a full
        # parallel suite run: median 0.40s, p99 0.81s, max 1.13s) and was exceeded for real
        # on 2026-09-10. Startup stalls are heavy-tailed, so the margin is now ~18x.
        #
        # Unlike the talking-child cases above, nothing here couples the threshold to the
        # child's runtime: the child exits immediately either way, so the threshold only
        # sets how long the pool waits before inspecting a child it finds already gone.
        # Raising it costs one wait, not one wait per assertion.
        $idleTimeout = 20
        $runnerBoundMs = 90000
        # The grandchild must outlive the whole run. If it exits first the pipes close on
        # their own, the pool takes the ordinary streams-closed path, and every assertion
        # below passes without the leaked-handle case ever happening - the vacuous green
        # this file exists to prevent. Derived from the bound so no edit can invert them.
        $holdSeconds = [int]($runnerBoundMs / 1000) + 30

        # The other half of the leaked-pipe case: this child passes and exits at once, but
        # a grandchild holds its pipes open, so the pool sees a process that has exited
        # and streams that never close. Silence after exit is a leaked handle, not a hang,
        # and reporting the exit code the child really had is the difference between this
        # and a false timeout on a test that passed.
        $syntheticContent = @'
$holder = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds __HOLD__' -NoNewWindow -PassThru
Set-Content -LiteralPath "__PID_FILE__" -Value $holder.Id -Encoding ASCII
exit 0
'@
        $syntheticContent = $syntheticContent.Replace("__PID_FILE__", $holderPidFile).Replace("__HOLD__", [string]$holdSeconds)
        Set-Content -LiteralPath (Join-Path $testsDir "exited-holder.tests.ps1") -Value $syntheticContent -Encoding UTF8

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-PwshCommand)
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runnerCopy`" -IdleTimeoutSeconds $idleTimeout"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        [void]$p.StandardError.ReadToEndAsync()

        $exited = $p.WaitForExit($runnerBoundMs)
        if (-not $exited) {
            try { $p.Kill() } catch {}
            $p.WaitForExit()
        }

        $output = $outTask.Result
        if ($null -eq $output) { $output = "" }

        $exitCode = $p.ExitCode
        $p.Dispose()

        if (Test-Path -LiteralPath $holderPidFile) {
            # Empty when the runner killed the child between creating the file and writing it.
            $holderPid = ([string](Get-Content -LiteralPath $holderPidFile -Raw)).Trim()
            if ($holderPid -match '^\d+$') {
                $holderProc = Get-Process -Id ([int]$holderPid) -ErrorAction SilentlyContinue
                if ($null -ne $holderProc) { try { $holderProc.Kill() } catch {} }
            }
        }

        Assert-Result -Name "exited-holder runner exits" -Condition ($exited) -FailureMessage ("runner did not exit within $([int]($runnerBoundMs / 1000))s waiting on pipes held open by a grandchild of a child that had already finished. Output: " + $output)
        Assert-Result -Name "exited-holder is not reported as a timeout" -Condition ($output -notmatch "TIMEOUT") -FailureMessage ("a child that had already exited was reported as a timeout: " + $output)
        Assert-Result -Name "exited-holder passes" -Condition ($output -match "PASS  exited-holder.tests.ps1") -FailureMessage ("expected a PASS line in output: " + $output)
        Assert-Result -Name "exited-holder run exit code" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)

        # The three assertions above are all satisfied by a run where the pipes were never
        # held at all: the child exits, the streams close, the pool takes the ordinary path
        # and reports a pass. So none of them prove the leaked-handle branch ran, and a
        # threshold raised past the pipe hold would turn this test green while testing
        # nothing - the failure mode the second acceptance criterion of item 76 names.
        #
        # The runner reports each child's duration on its own PASS line, and for this child
        # the duration and the idle clock start together and the idle clock never resets, so
        # reaching the idle branch means a duration of at least the threshold, while the
        # ordinary streams-closed path means about a second. Asserting the floor therefore
        # pins which branch ran. It is one-sided on purpose: contention can only push the
        # measured duration up, never toward a false failure.
        $reportedDuration = $null
        if ($output -match 'PASS  exited-holder\.tests\.ps1 \(([0-9.]+)s\)') {
            $reportedDuration = [double]$Matches[1]
        }
        Assert-Result -Name "exited-holder waited out the idle window with its pipes still held" -Condition ($null -ne $reportedDuration -and $reportedDuration -ge $idleTimeout) -FailureMessage ("expected a reported duration of at least the ${idleTimeout}s idle threshold, proving the pool reached the idle branch on a child whose pipes were still open; got '" + $reportedDuration + "'. A shorter duration means the grandchild released the pipes first and the leaked-handle path was never exercised. Output: " + $output)
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
