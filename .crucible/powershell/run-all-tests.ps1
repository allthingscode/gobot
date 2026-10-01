# IdleTimeoutSeconds measures silence, not total runtime: a test that is still printing
# is not hung however long it takes. 300s is about 5x the worst gap between consecutive
# output lines measured across the suite's longest files (60.6s, in
# adopter-update-materialization.tests.ps1). NoTimeout is the debugging escape hatch.
# Both are parameters rather than environment variables because every child this runner
# spawns inherits the environment and would inherit the setting with it.
#
# One threshold governs both modes. A wall-clock cap cannot: it has to be set against the
# slowest legitimate file under the worst contention the pool can produce, so it is always
# either too tight for a slow test or too loose to catch a hang promptly. Silence does not
# scale with contention, so an idle cap needs no per-file exemptions.
param(
    [switch]$Serial,
    [int]$ThrottleLimit = 0,
    [switch]$Force,
    [int]$IdleTimeoutSeconds = 300,
    [switch]$NoTimeout
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:CRUCIBLE_SKIP_PROVENANCE = 'true'

# Before any fixture is built, point git at an isolated global config so the suite
# never inherits the developer's core.autocrlf. Defined in tests/_harness.ps1, which
# every test file also dot-sources, so a solo test run is isolated identically.
. (Join-Path $PSScriptRoot "tests/_harness.ps1")

$testsDir = Join-Path $PSScriptRoot "tests"
$testFiles = Get-ChildItem -Path $testsDir -Filter '*test*.ps1' | Sort-Object Name

if (@($testFiles).Count -eq 0) {
    Write-Host "No test files discovered under $testsDir" -ForegroundColor Red
    exit 1
}

# A file that measures its own timing or starts its own pwsh workers can miss a deadline
# when it shares the pool with seven others, and pass alone; event-log.tests.ps1 did on an
# 8-job Linux leg. Such a file declares, in its first 20 lines,
#   # crucible-test: serial - <why it cannot share the pool>
# and runs alone after the pool. A marker with no reason, or any other crucible-test
# value, fails the run before anything starts: a typo would otherwise put the file back
# in the pool with nothing to say so, and a reason is what keeps the marker from becoming
# a place to park a flaky test. Item 154.
$serialReasons = @{}
$markerErrors = @()
foreach ($f in $testFiles) {
    foreach ($line in @(Get-Content -LiteralPath $f.FullName -TotalCount 20 -Encoding UTF8)) {
        if ($line -notmatch '^\s*#\s*crucible-test:\s*(.*)$') { continue }
        $value = $Matches[1].Trim()
        if ($value -match '^serial\b\s*[-:]?\s*(.*)$') {
            $reason = $Matches[1].Trim()
            if ($reason) {
                $serialReasons[$f.Name] = $reason
            } else {
                $markerErrors += ($f.Name + ": the serial marker gives no reason. Write '# crucible-test: serial - <why this file cannot share the pool>'.")
            }
        } else {
            $markerErrors += ($f.Name + ": unknown crucible-test marker '" + $value + "'. The only marker is 'serial - <reason>'.")
        }
        break
    }
}
if ($markerErrors.Count -gt 0) {
    foreach ($err in $markerErrors) { Write-Host $err -ForegroundColor Red }
    exit 1
}


# Determine throttle limit if not provided
if ($ThrottleLimit -le 0) {
    if ($env:CRUCIBLE_TEST_JOBS -match '^\d+$') {
        $ThrottleLimit = [int]$env:CRUCIBLE_TEST_JOBS
    } else {
        $ThrottleLimit = [Environment]::ProcessorCount
    }
}

# Clamp ThrottleLimit to a sane range [1, 8]
if ($ThrottleLimit -gt 8) {
    $ThrottleLimit = 8
}
if ($ThrottleLimit -lt 1) {
    $ThrottleLimit = 1
}

$exitCode = 0
$runLock = $null

# Two concurrent runs of this script against the same checkout destroy each other's
# work: both build fixtures under one run root and the first to finish deletes it.
#
# The lock is taken after the no-test-files check so that path cannot exit holding
# it. The run root itself is created by _harness.ps1 above, before the lock exists;
# that is harmless because the root is named for this process and no other run will
# touch it.
#
# -Force is a command-line switch rather than an environment variable because every
# child this runner spawns inherits the environment and would inherit the bypass
# with it, disabling the guard everywhere at once.
if (-not $Force) {
    . (Join-Path $PSScriptRoot "lib/run-lock.ps1")
    $runLock = Enter-RunLock -ScopeRoot $PSScriptRoot
    if (-not $runLock.Acquired) {
        Write-Host "Another test run already holds the lock for this checkout." -ForegroundColor Red
        if ($null -ne $runLock.Holder) {
            Write-Host "  Held by PID $($runLock.Holder.ProcessId), started $($runLock.Holder.Started)" -ForegroundColor Red
        }
        Write-Host "  Lock file: $($runLock.LockPath)" -ForegroundColor Red
        Write-Host "  Wait for it to finish, or re-run with -Force if you are certain it is gone." -ForegroundColor Yellow
        exit 1
    }
}

try {
    . (Join-Path $PSScriptRoot "tests/_fixtures.ps1")

    # Collect run roots abandoned by runs that were killed, and by test files invoked
    # on their own. Both leave a root no finally will ever reach.
    #
    # This replaces an age-plus-ownership sweep over crucible-shared-adopter-*. The age
    # half is gone: a dead owner is proof of abandonment on its own, and the threshold
    # only ever delayed the collection it could not justify. Skipping the live root
    # this process is using falls out of the same check, since this process is alive.
    #
    # The whole DirectoryInfo is passed, not the name: a root whose pid has since been
    # reused by a later process is abandoned too, and only the creation time can tell that
    # apart from a second checkout's live run. Two such roots sat here for three days.
    $tempPath = [System.IO.Path]::GetTempPath()
    Get-ChildItem -Path $tempPath -Filter "crucible-test-run-*" -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-TestRunRootOrphaned -Directory $_ } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    # Pre-stage the shared adopter fixture once before running worker tests. Nothing
    # records whether this call built it: the fixture lives inside the run root now, so
    # ownership of the ROOT decides who cleans up, and a nested runner that inherits
    # both variables must not delete either.
    Write-Host "Pre-staging shared adopter fixture..." -ForegroundColor Cyan
    try {
        if (-not $env:CRUCIBLE_SHARED_FIXTURE -or -not (Test-Path -LiteralPath $env:CRUCIBLE_SHARED_FIXTURE)) {
            $env:CRUCIBLE_SHARED_FIXTURE = Get-SharedAdopterFixture
        }
        Write-Host "Shared adopter fixture pre-staged at: $env:CRUCIBLE_SHARED_FIXTURE" -ForegroundColor Green
    } catch {
        Write-Host "Warning: Failed to pre-stage shared adopter fixture: $_" -ForegroundColor Yellow
    }

    $shell = (Get-Process -Id $PID).Path
    if (-not $shell) {
        $shell = 'pwsh'
    }

    # Scans child standard output for harness failure signatures (EXCEPTION OCCURRED:, SOME TESTS FAILED, FAILED:).
    function Test-OutputHasFailure {
        param([string]$Output)

        if ([string]::IsNullOrWhiteSpace($Output)) {
            return $false
        }

        return ($Output -cmatch 'EXCEPTION OCCURRED:' -or $Output -cmatch 'SOME TESTS FAILED' -or $Output -cmatch '\bFAILED:')
    }

    # Collects the third outcome Run-Test can report. A test whose precondition cannot exist on
    # this platform is not a pass. Write-TestFileSummary is what a file's own tail uses when it
    # Skip-Tests; this is the run summary, which CI and scripts/test-linux.ps1 read. Without it
    # the skip would be invisible here and the Linux leg would be quietly weaker than the
    # Windows one rather than measurably narrower. Item 102, item 104.
    function Get-OutputSkipNotes {
        param([AllowEmptyString()][string]$Output)

        $notes = @()
        if ([string]::IsNullOrWhiteSpace($Output)) {
            return ,$notes
        }
        foreach ($line in ($Output -split "`r?`n")) {
            if ($line -cmatch '^SKIPPED: (.+)$') { $notes += $Matches[1] }
        }
        return ,$notes
    }

    # Consumes every line one stream has already produced, without blocking, restarting
    # the idle clock for each. Returns the still-pending read, or $null once the stream
    # has reached end of stream and must not be read again.
    function Read-PendingLines {
        param($Pending, $Reader, $Lines, $Idle)

        while ($null -ne $Pending -and $Pending.IsCompleted) {
            $line = $null
            try {
                $line = $Pending.Result
            } catch {
                # Killing a child closes its redirected pipes. Treat a read fault during
                # that shutdown exactly like end of stream.
                $line = $null
            }

            if ($null -eq $line) {
                $Pending = $null
            } else {
                [void]$Lines.Add($line)
                $Idle.Restart()
                $Pending = $Reader.ReadLineAsync()
            }
        }

        return $Pending
    }

    function Start-TestProcess {
        param($file, [switch]$StreamStandardOutput)

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $shell
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($file.FullName)`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        # A caller that streams reads both redirected streams itself, line by line, so
        # no reads are started here. Parallel mode reads line by line too, but buffers
        # what it reads rather than echoing it. Reading to end of stream instead would be
        # simpler and is what this used to do, but it completes exactly once, at end of
        # stream, so it can tell a finished child from an unfinished one and never a
        # hung one from a slow one. A pending per-line read makes each line's arrival
        # time observable, which is what an idle clock needs, while still printing
        # nothing until the child exits.
        $outRead = if ($StreamStandardOutput) { $null } else { $p.StandardOutput.ReadLineAsync() }
        $errRead = if ($StreamStandardOutput) { $null } else { $p.StandardError.ReadLineAsync() }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        return [PSCustomObject]@{
            File = $file
            Proc = $p
            OutRead = $outRead
            ErrRead = $errRead
            OutLines = (New-Object System.Collections.Generic.List[string])
            ErrLines = (New-Object System.Collections.Generic.List[string])
            Stopwatch = $sw
            Idle = [System.Diagnostics.Stopwatch]::StartNew()
        }
    }

    if ($Serial) {
        Write-Host "Running tests in serial mode..." -ForegroundColor Cyan
        $failedTests = @()
        $passCount = 0
        $skipNotes = @()

        foreach ($file in $testFiles) {
            Write-Host "Running $($file.Name)..." -ForegroundColor Cyan

            $item = Start-TestProcess -file $file -StreamStandardOutput
            $proc = $item.Proc

            # Echo each line as the child produces it, so a test that is still running is
            # visible while it runs rather than only once it finishes. Both streams are
            # read concurrently: draining only stdout would let a child that fills the
            # stderr pipe block forever, and would also make a test that reports progress
            # on stderr look silent to the idle check below.
            $outLines = New-Object System.Collections.Generic.List[string]
            $outRead = $proc.StandardOutput.ReadLineAsync()
            $errRead = $proc.StandardError.ReadLineAsync()
            $idle = [System.Diagnostics.Stopwatch]::StartNew()
            $pollMs = 250
            $isTimeout = $false

            while ($null -ne $outRead -or $null -ne $errRead) {
                $pending = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
                if ($null -ne $outRead) { [void]$pending.Add($outRead) }
                if ($null -ne $errRead) { [void]$pending.Add($errRead) }

                $completedIndex = [System.Threading.Tasks.Task]::WaitAny(
                    [System.Threading.Tasks.Task[]]$pending.ToArray(),
                    $pollMs
                )

                if ($completedIndex -eq -1) {
                    if (-not $NoTimeout -and $idle.Elapsed.TotalSeconds -ge $IdleTimeoutSeconds) {
                        $isTimeout = $true
                        try {
                            $proc.Kill()
                            $proc.WaitForExit()
                        } catch {}
                        # Stop reading rather than waiting for the pending reads to end.
                        # Killing the child does not close the pipes if it had spawned a
                        # process of its own that inherited the handles, so those reads
                        # can stay pending indefinitely and this loop would spin forever
                        # on the very hang the timeout exists to break.
                        break
                    }
                    continue
                }

                $completed = $pending[$completedIndex]
                try {
                    $line = $completed.Result
                } catch {
                    # Killing a timed-out child closes its redirected pipes. Treat a
                    # read fault during that shutdown exactly like end of stream.
                    $line = $null
                }

                if ($completed -eq $outRead) {
                    if ($null -eq $line) {
                        $outRead = $null
                    } else {
                        Write-Host $line
                        [void]$outLines.Add($line)
                        $idle.Restart()
                        $outRead = $proc.StandardOutput.ReadLineAsync()
                    }
                } else {
                    if ($null -eq $line) {
                        $errRead = $null
                    } else {
                        Write-Host $line -ForegroundColor Red
                        $idle.Restart()
                        $errRead = $proc.StandardError.ReadLineAsync()
                    }
                }
            }
            $proc.WaitForExit()
            $idle.Stop()

            $outText = ($outLines -join "`n")

            foreach ($note in (Get-OutputSkipNotes -Output $outText)) {
                $skipNotes += ($file.Name + ": " + $note)
            }

            $testFailed = $false
            if ($isTimeout -or $proc.ExitCode -ne 0 -or (Test-OutputHasFailure -Output $outText)) {
                $testFailed = $true
            }

            if ($isTimeout) {
                Write-Host "FAIL  $($file.Name) (TIMEOUT after $($IdleTimeoutSeconds)s)" -ForegroundColor Red
            }
            $proc.Dispose()

            if ($testFailed) {
                $failedTests += $file.Name
            } else {
                $passCount++
            }
        }

        Write-Host ""
        Write-Host "--- Test Summary ---" -ForegroundColor Cyan
        Write-Host "Passed: $passCount" -ForegroundColor Green
        if ($skipNotes.Count -gt 0) {
            # Named individually, not just totalled. A count alone tells a reader that the leg is
            # narrower than the other one without telling them where, which is how a skip becomes
            # permanent.
            Write-Host "Skipped: $($skipNotes.Count)" -ForegroundColor Yellow
            foreach ($note in ($skipNotes | Sort-Object)) {
                Write-Host ("  - " + $note) -ForegroundColor Yellow
            }
        }
        if ($failedTests.Count -gt 0) {
            $sortedFailed = @($failedTests | Sort-Object)
            Write-Host "Failed: $($sortedFailed.Count) ($($sortedFailed -join ', '))" -ForegroundColor Red
            $exitCode = 1
        } else {
            Write-Host "All tests passed!" -ForegroundColor Green
            $exitCode = 0
        }
    } else {
        Write-Host "Running tests in parallel (ThrottleLimit = $ThrottleLimit)..." -ForegroundColor Cyan

        # Scheduling weights: seconds per file on an 8-job Windows run, 2026-09-30. The
        # pool starts the heaviest first so the longest file is not left running alone
        # after the rest have drained; adopter-update-materialization was unweighted and
        # started after 39 lighter files. Only order matters, so a stale number costs
        # time, never correctness. A file under 20s, or a new one, weighs 0 and sorts
        # by name.
        $weights = @{
            'adopter-update-materialization.tests.ps1' = 461
            'run-all-tests-runner.tests.ps1'         = 426
            'crucible-gates-human.tests.ps1'          = 316
            'operator-merge-verification.tests.ps1'  = 141
            'check-assertion-deletion.tests.ps1'     = 136
            'crucible.tests.ps1'                      = 133
            'crucible-gates-reject-abandon.tests.ps1' = 125
            'update-bundle-rename-prune.tests.ps1'   = 122
            'shipped-tests-framework-layout.tests.ps1' = 118
            'adopter-pipeline-e2e.tests.ps1'         = 114
            'update-bundle-core.tests.ps1'           = 99
            'update-bundle-scope-snapshot.tests.ps1' = 93
            'launch-codex-specialist.tests.ps1'      = 89
            'watch-adopter-ci.tests.ps1'             = 88
            'init-project-config-version.tests.ps1'  = 82
            'check-linux-leg.tests.ps1'              = 81
            'implementation-hooks.tests.ps1'         = 79
            'crucible-gates-breakers.tests.ps1'       = 75
            'shipped-tests-crucible-lint.tests.ps1'  = 70
            'project-hook-chaining.tests.ps1'        = 69
            'check-generated-docs.tests.ps1'         = 62
            'validate-config.tests.ps1'              = 61
            'new-handoff.tests.ps1'                  = 56
            'validate-backlog.tests.ps1'             = 55
            'rebaseline-handoff.tests.ps1'           = 51
            'init-project-core.tests.ps1'            = 51
            'init-project-instructions.tests.ps1'    = 50
            'check-prompt-version.tests.ps1'         = 49
            'crucible-doctor.tests.ps1'               = 48
            'examples-mirror-sync.tests.ps1'         = 45
            'install-manifest.tests.ps1'             = 42
            'crucible-gates-routing.tests.ps1'        = 42
            'analyze-evals.tests.ps1'                = 36
            'adopter-bootstrap.tests.ps1'            = 36
            'concurrent-worktrees.tests.ps1'         = 36
            'run-isolated-checks.tests.ps1'          = 36
            'check-merge-conflicts.tests.ps1'        = 34
            'check-mojibake.tests.ps1'               = 33
            'scope-violation-circuit-breaker.tests.ps1' = 32
            'init-rerun-task-md.tests.ps1'           = 32
            'factory-shim.tests.ps1'                 = 31
            'check-ascii.tests.ps1'                  = 31
            'status-drift.tests.ps1'                 = 30
            'crucible-gates-completion.tests.ps1'     = 30
            'update-bundle-custom-regions.tests.ps1' = 29
            'staged-gate-scans.tests.ps1'            = 29
            'no-code-closure.tests.ps1'              = 27
            'archive-task.tests.ps1'                 = 27
            'crucible-gates-affinity.tests.ps1'       = 25
            'crucible-gates-handoff.tests.ps1'        = 24
            'install-hooks.tests.ps1'                = 23
            'adopter-smoke.tests.ps1'                = 20
            'provenance-manifest.tests.ps1'          = 20
            'budget-overrun-circuit-breaker.tests.ps1' = 20
        }

        $parallelFiles = @($testFiles | Where-Object { -not $serialReasons.ContainsKey($_.Name) })
        $serialFiles = @($testFiles | Where-Object { $serialReasons.ContainsKey($_.Name) })

        # Sort parallel files by scheduling weight descending, then alphabetically ascending
        $parallelFiles = @($parallelFiles | Sort-Object @{Expression = {
            if ($weights.ContainsKey($_.Name)) {
                $weights[$_.Name]
            } else {
                0
            }
        }; Descending = $true}, @{Expression = { $_.Name }; Ascending = $true})

        $running = @()
        $completed = @()

        try {
            # 1. Run the pool, then each serial-marked file alone with the same loop.
            $phases = @(
                [PSCustomObject]@{ Files = $parallelFiles; Limit = $ThrottleLimit },
                [PSCustomObject]@{ Files = $serialFiles; Limit = 1 }
            )
            foreach ($phase in $phases) {
                $phaseFiles = @($phase.Files)
                $phaseLimit = $phase.Limit
                $nextIndex = 0
                if ($phaseLimit -eq 1 -and $phaseFiles.Count -gt 0) {
                    Write-Host "Running $($phaseFiles.Count) serial file(s) one at a time..." -ForegroundColor Cyan
                }
                while ($nextIndex -lt $phaseFiles.Count -or $running.Count -gt 0) {
                    # Fill the running pool up to the phase's limit
                    while ($running.Count -lt $phaseLimit -and $nextIndex -lt $phaseFiles.Count) {
                        $file = $phaseFiles[$nextIndex]
                        $nextIndex++
                        if ($serialReasons.ContainsKey($file.Name)) {
                            Write-Host "SERIAL $($file.Name) - $($serialReasons[$file.Name])" -ForegroundColor Cyan
                        }

                        $item = Start-TestProcess -file $file
                        $running += $item
                    }

                    # Check status of running processes
                    $stillRunning = @()
                    foreach ($item in $running) {
                        $proc = $item.Proc
                        $sw = $item.Stopwatch
                        $file = $item.File

                        $exited = $false
                        $isTimeout = $false

                        $item.OutRead = Read-PendingLines -Pending $item.OutRead -Reader $proc.StandardOutput -Lines $item.OutLines -Idle $item.Idle
                        $item.ErrRead = Read-PendingLines -Pending $item.ErrRead -Reader $proc.StandardError -Lines $item.ErrLines -Idle $item.Idle

                        $proc.Refresh()
                        $streamsClosed = ($null -eq $item.OutRead -and $null -eq $item.ErrRead)

                        if ($proc.HasExited -and $streamsClosed) {
                            $proc.WaitForExit()
                            $exited = $true
                        } elseif (-not $NoTimeout -and $item.Idle.Elapsed.TotalSeconds -ge $IdleTimeoutSeconds) {
                            # Silence for the whole window. A child still running is hung, and
                            # is killed. A child that has already exited is not: its pipes are
                            # held open by a process that inherited them, so report the exit
                            # code it really had rather than calling a finished test a timeout.
                            # Either way the pending reads are abandoned rather than waited
                            # out, since waiting on them is the hang this exists to break.
                            if (-not $proc.HasExited) {
                                try {
                                    $proc.Kill()
                                    $proc.WaitForExit()
                                } catch {}
                                $isTimeout = $true
                            }
                            $item.OutRead = $null
                            $item.ErrRead = $null
                            $exited = $true
                        }

                        if ($exited) {
                            $sw.Stop()
                            $item.Idle.Stop()
                            $duration = [Math]::Round($sw.Elapsed.TotalSeconds, 2)

                            $outText = ($item.OutLines -join "`n")
                            $errText = ($item.ErrLines -join "`n")

                            $exitCodeValue = 0
                            if ($isTimeout) {
                                $exitCodeValue = -1
                            } else {
                                $exitCodeValue = $proc.ExitCode
                            }

                            $hasOutputFailure = ($exitCodeValue -eq 0) -and (Test-OutputHasFailure -Output $outText)

                            if ($exitCodeValue -eq 0 -and -not $hasOutputFailure) {
                                Write-Host "PASS  $($file.Name) ($($duration)s)" -ForegroundColor Green
                            } else {
                                if ($isTimeout) {
                                    Write-Host "FAIL  $($file.Name) (TIMEOUT after $($IdleTimeoutSeconds)s)" -ForegroundColor Red
                                } elseif ($hasOutputFailure) {
                                    Write-Host "FAIL  $($file.Name) ($($duration)s, Output Failure Signature)" -ForegroundColor Red
                                } else {
                                    Write-Host "FAIL  $($file.Name) ($($duration)s, ExitCode: $exitCodeValue)" -ForegroundColor Red
                                }
                            }

                            $completed += [PSCustomObject]@{
                                File = $file
                                ExitCode = $exitCodeValue
                                Output = $outText
                                Error = $errText
                                Duration = $duration
                                IsTimeout = $isTimeout
                                Timeout = $IdleTimeoutSeconds
                            }

                            $proc.Dispose()
                        } else {
                            $stillRunning += $item
                        }
                    }

                    $running = $stillRunning

                    if ($running.Count -gt 0 -or $nextIndex -lt $phaseFiles.Count) {
                        # Wake as soon as any child produces a line rather than always
                        # sleeping out the poll interval. Draining only on a fixed tick would
                        # cap a child's throughput at one buffer per tick, and a child that
                        # fills its pipe faster than that blocks on the write - which an idle
                        # clock cannot distinguish from a hang, because a blocked writer is
                        # exactly as silent as one.
                        $pendingReads = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
                        foreach ($item in $running) {
                            if ($null -ne $item.OutRead) { [void]$pendingReads.Add($item.OutRead) }
                            if ($null -ne $item.ErrRead) { [void]$pendingReads.Add($item.ErrRead) }
                        }

                        if ($pendingReads.Count -gt 0) {
                            [void][System.Threading.Tasks.Task]::WaitAny(
                                [System.Threading.Tasks.Task[]]$pendingReads.ToArray(),
                                100
                            )
                        } else {
                            Start-Sleep -Milliseconds 100
                        }
                    }
                }
            }
        }
        finally {
            # Clean up any remaining processes from unfinished runs
            foreach ($item in $running) {
                if ($null -ne $item.Proc) {
                    try {
                        $item.Proc.Refresh()
                        if (-not $item.Proc.HasExited) {
                            $item.Proc.Kill()
                            $item.Proc.WaitForExit()
                        }
                    } catch {}
                    try {
                        $item.Proc.Dispose()
                    } catch {}
                }
            }
        }

        # 2. Print detailed failures
        $failedItems = @($completed | Where-Object { $_.ExitCode -ne 0 -or (Test-OutputHasFailure -Output $_.Output) })
        if ($failedItems.Count -gt 0) {
            Write-Host ""
            Write-Host "=== Detailed Failures ===" -ForegroundColor Red
            foreach ($item in $failedItems) {
                Write-Host "--------------------------------------------------" -ForegroundColor Red
                Write-Host "Failure in: $($item.File.Name)" -ForegroundColor Red
                if ($item.IsTimeout) {
                    Write-Host "Status: TIMEOUT after $($item.Timeout) seconds of silence" -ForegroundColor Red
                } elseif ($item.ExitCode -ne 0) {
                    Write-Host "Status: Failed with Exit Code $($item.ExitCode) in $($item.Duration)s" -ForegroundColor Red
                } else {
                    Write-Host "Status: Failed with output failure signature (Exit Code 0) in $($item.Duration)s" -ForegroundColor Red
                }
                Write-Host "--------------------------------------------------" -ForegroundColor Red

                if (-not [string]::IsNullOrWhiteSpace($item.Output)) {
                    Write-Host "--- Standard Output ---" -ForegroundColor Yellow
                    Write-Host $item.Output
                }

                if (-not [string]::IsNullOrWhiteSpace($item.Error)) {
                    Write-Host "--- Standard Error ---" -ForegroundColor Red
                    Write-Host $item.Error
                }
            }
            Write-Host "=========================" -ForegroundColor Red
        }

        # 3. Final summary
        $failedTests = @()
        $passCount = 0
        $skipNotes = @()
        foreach ($item in $completed) {
            foreach ($note in (Get-OutputSkipNotes -Output $item.Output)) {
                $skipNotes += ($item.File.Name + ": " + $note)
            }
            if ($item.ExitCode -eq 0 -and -not (Test-OutputHasFailure -Output $item.Output)) {
                $passCount++
            } else {
                $failedTests += $item.File.Name
            }
        }

        Write-Host ""
        Write-Host "--- Test Summary ---" -ForegroundColor Cyan
        Write-Host "Passed: $passCount" -ForegroundColor Green
        if ($skipNotes.Count -gt 0) {
            # Named individually, not just totalled. A count alone tells a reader that the leg is
            # narrower than the other one without telling them where, which is how a skip becomes
            # permanent.
            Write-Host "Skipped: $($skipNotes.Count)" -ForegroundColor Yellow
            foreach ($note in ($skipNotes | Sort-Object)) {
                Write-Host ("  - " + $note) -ForegroundColor Yellow
            }
        }
        if ($failedTests.Count -gt 0) {
            $sortedFailed = @($failedTests | Sort-Object)
            Write-Host "Failed: $($sortedFailed.Count) ($($sortedFailed -join ', '))" -ForegroundColor Red
            $exitCode = 1
        } else {
            Write-Host "All tests passed!" -ForegroundColor Green
            $exitCode = 0
        }
    }
} finally {
    try {
        # Deleting the root takes the shared fixture and the isolated git config with
        # it. Only the process that created the root may do this: a nested runner
        # inherits CRUCIBLE_TEST_ROOT from the outer suite and would otherwise delete
        # the outer run's fixtures while it is still using them.
        if ($CRUCIBLE_TEST_ROOT_CREATED -and $env:CRUCIBLE_TEST_ROOT -and (Test-Path -LiteralPath $env:CRUCIBLE_TEST_ROOT)) {
            Write-Host "Cleaning up test run root..." -ForegroundColor Cyan
            Remove-Item -LiteralPath $env:CRUCIBLE_TEST_ROOT -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if ($null -ne $runLock) {
            Exit-RunLock -Lock $runLock
        }
    }
}
exit $exitCode
