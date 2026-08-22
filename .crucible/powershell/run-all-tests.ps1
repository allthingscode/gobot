param(
    [switch]$Serial,
    [int]$ThrottleLimit = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:CRUCIBLE_SKIP_PROVENANCE = 'true'

$testsDir = Join-Path $PSScriptRoot "tests"
$testFiles = Get-ChildItem -Path $testsDir -Filter '*test*.ps1' | Sort-Object Name

if (@($testFiles).Count -eq 0) {
    Write-Host "No test files discovered under $testsDir" -ForegroundColor Red
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

try {
    # Clean up old runner-owned shared adopter fixtures to prevent TEMP directory bloat
    $tempPath = [System.IO.Path]::GetTempPath()
    Get-ChildItem -Path $tempPath -Filter "crucible-shared-adopter-*" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-30) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    $createdSharedFixture = $false
    # Pre-stage the shared adopter fixture once before running worker tests
    Write-Host "Pre-staging shared adopter fixture..." -ForegroundColor Cyan
    . (Join-Path $PSScriptRoot "tests/_fixtures.ps1")
    try {
        if (-not $env:CRUCIBLE_SHARED_FIXTURE -or -not (Test-Path -LiteralPath $env:CRUCIBLE_SHARED_FIXTURE)) {
            $env:CRUCIBLE_SHARED_FIXTURE = Get-SharedAdopterFixture
            $createdSharedFixture = $true
        }
        Write-Host "Shared adopter fixture pre-staged at: $env:CRUCIBLE_SHARED_FIXTURE" -ForegroundColor Green
    } catch {
        Write-Host "Warning: Failed to pre-stage shared adopter fixture: $_" -ForegroundColor Yellow
    }

    $shell = (Get-Process -Id $PID).Path
    if (-not $shell) {
        $isWindows = ($PSVersionTable.PSEdition -ne 'Core') -or ($env:OS -match 'Windows_NT')
        $shell = if ($isWindows) { 'powershell.exe' } else { 'pwsh' }
    }

    # Scans child standard output for harness failure signatures (EXCEPTION OCCURRED:, SOME TESTS FAILED, FAILED:).
    function Test-OutputHasFailure {
        param([string]$Output)

        if ([string]::IsNullOrWhiteSpace($Output)) {
            return $false
        }

        return ($Output -cmatch 'EXCEPTION OCCURRED:' -or $Output -cmatch 'SOME TESTS FAILED' -or $Output -cmatch '\bFAILED:')
    }

    function Start-TestProcess {
        param($file)

        # These two run 190s-265s standalone and swing near 2x under parallel load,
        # so the default 360s cap makes them flake as timeouts rather than failures.
        $timeout = 360
        if ($file.Name -in @('factory-gates.tests.ps1', 'factory-gates-human.tests.ps1')) {
            $timeout = 600
        }

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

        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        return [PSCustomObject]@{
            File = $file
            Proc = $p
            OutTask = $outTask
            ErrTask = $errTask
            Stopwatch = $sw
            Timeout = $timeout
        }
    }

    if ($Serial) {
        Write-Host "Running tests in serial mode..." -ForegroundColor Cyan
        $failedTests = @()
        $passCount = 0

        foreach ($file in $testFiles) {
            Write-Host "Running $($file.Name)..." -ForegroundColor Cyan

            $item = Start-TestProcess -file $file
            $proc = $item.Proc
            $proc.WaitForExit()

            $outText = $item.OutTask.Result
            $errText = $item.ErrTask.Result

            if ($null -eq $outText) { $outText = "" }
            if ($null -eq $errText) { $errText = "" }

            if (-not [string]::IsNullOrWhiteSpace($outText)) {
                Write-Host $outText
            }
            if (-not [string]::IsNullOrWhiteSpace($errText)) {
                Write-Host $errText -ForegroundColor Red
            }

            $testFailed = $false
            if ($proc.ExitCode -ne 0 -or (Test-OutputHasFailure -Output $outText)) {
                $testFailed = $true
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

        # Static scheduling weights (in seconds) based on Windows CI execution times.
        # Unknown/new tests will default to 0 weight and sort alphabetically.
        $weights = @{
            'factory-gates-reject-abandon.tests.ps1' = 35
            'adopter-pipeline-e2e.tests.ps1'         = 28
            'factory-gates-human.tests.ps1'          = 26
            'update-bundle-rename-prune.tests.ps1'   = 24
            'factory.tests.ps1'                      = 21
            'operator-merge-verification.tests.ps1'  = 20
            'validate-config.tests.ps1'              = 18
            'concurrent-worktrees.tests.ps1'         = 18
            'adopter-bootstrap.tests.ps1'            = 18
            'check-merge-conflicts.tests.ps1'        = 18
            'validate-backlog.tests.ps1'             = 17
            'factory-gates-breakers.tests.ps1'       = 16
            'update-bundle-core.tests.ps1'           = 15
            'factory-gates-routing.tests.ps1'        = 15
            'status-drift.tests.ps1'                 = 15
            'update-bundle-custom-regions.tests.ps1' = 14
            'archive-task.tests.ps1'                 = 11
            'init-project-config-version.tests.ps1'  = 11
            'init-project-instructions.tests.ps1'    = 10
            'new-handoff.tests.ps1'                  = 10
            'update-session-state-stale-lock.tests.ps1' = 9
            'factory-gates-affinity.tests.ps1'       = 9
            'run-isolated-checks.tests.ps1'          = 9
            'fabricated-test-result-circuit-breaker.tests.ps1' = 8
            'check-file-affinity.tests.ps1'          = 8
            'update-bundle-scope-snapshot.tests.ps1' = 8
            'adopter-smoke.tests.ps1'                = 8
            'provenance-manifest.tests.ps1'          = 8
            'factory-health.tests.ps1'               = 8
            'scope-violation-circuit-breaker.tests.ps1' = 7
            'factory-doctor.tests.ps1'               = 7
            'factory-gates-completion.tests.ps1'     = 6
            'grooming-task-reason.tests.ps1'         = 5
            'init-project-core.tests.ps1'            = 5
            'install-hooks.tests.ps1'                = 5
        }

        $sequentialFiles = @()
        $parallelFiles = @($testFiles)

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
        $nextIndex = 0

        try {
            # 1. Run sequential/subprocess-heavy tests first to prevent CPU/IO contention
            if ($sequentialFiles.Count -gt 0) {
                Write-Host "Running sequential tests first to prevent CPU/IO contention..." -ForegroundColor Cyan
                foreach ($file in $sequentialFiles) {
                    Write-Host "Running $($file.Name) serially..." -ForegroundColor Cyan

                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    $p = New-Object System.Diagnostics.Process
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = $shell
                    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($file.FullName)`""
                    $psi.UseShellExecute = $false
                    $psi.RedirectStandardOutput = $true
                    $psi.RedirectStandardError = $true
                    $psi.CreateNoWindow = $true
                    $p.StartInfo = $psi
                    [void]$p.Start()

                    $outTask = $p.StandardOutput.ReadToEndAsync()
                    $errTask = $p.StandardError.ReadToEndAsync()

                    # Wait for exit or timeout (900 seconds is plenty when serial)
                    $exited = $false
                    $isTimeout = $false
                    while (-not $exited) {
                        $p.Refresh()
                        if ($p.HasExited) {
                            $p.WaitForExit()
                            $exited = $true
                        } elseif ($sw.Elapsed.TotalSeconds -ge 900) {
                            try {
                                $p.Kill()
                                $p.WaitForExit()
                            } catch {}
                            $exited = $true
                            $isTimeout = $true
                        }
                        if (-not $exited) {
                            Start-Sleep -Milliseconds 100
                        }
                    }

                    $sw.Stop()
                    $duration = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
                    $outText = $outTask.Result
                    $errText = $errTask.Result
                    if ($null -eq $outText) { $outText = "" }
                    if ($null -eq $errText) { $errText = "" }

                    $exitCodeValue = if ($isTimeout) { -1 } else { $p.ExitCode }

                    if ($exitCodeValue -eq 0) {
                        Write-Host "PASS  $($file.Name) ($($duration)s)" -ForegroundColor Green
                    } else {
                        if ($isTimeout) {
                            Write-Host "FAIL  $($file.Name) (TIMEOUT after 900s)" -ForegroundColor Red
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
                        Timeout = 900
                    }
                    $p.Dispose()
                }
            }

            # 2. Run parallel tests
            while ($nextIndex -lt $parallelFiles.Count -or $running.Count -gt 0) {
                # Fill the running pool up to ThrottleLimit
                while ($running.Count -lt $ThrottleLimit -and $nextIndex -lt $parallelFiles.Count) {
                    $file = $parallelFiles[$nextIndex]
                    $nextIndex++

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

                    $proc.Refresh()
                    if ($proc.HasExited) {
                        $proc.WaitForExit()
                        $exited = $true
                    } elseif ($sw.Elapsed.TotalSeconds -ge $item.Timeout) {
                        try {
                            $proc.Kill()
                            $proc.WaitForExit()
                        } catch {}
                        $exited = $true
                        $isTimeout = $true
                    }

                    if ($exited) {
                        $sw.Stop()
                        $duration = [Math]::Round($sw.Elapsed.TotalSeconds, 2)

                        $outText = $item.OutTask.Result
                        $errText = $item.ErrTask.Result

                        if ($null -eq $outText) { $outText = "" }
                        if ($null -eq $errText) { $errText = "" }

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
                                Write-Host "FAIL  $($file.Name) (TIMEOUT after $($item.Timeout)s)" -ForegroundColor Red
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
                            Timeout = $item.Timeout
                        }

                        $proc.Dispose()
                    } else {
                        $stillRunning += $item
                    }
                }

                $running = $stillRunning

                if ($running.Count -gt 0 -or $nextIndex -lt $parallelFiles.Count) {
                    Start-Sleep -Milliseconds 100
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

        # 3. Print detailed failures
        $failedItems = @($completed | Where-Object { $_.ExitCode -ne 0 -or (Test-OutputHasFailure -Output $_.Output) })
        if ($failedItems.Count -gt 0) {
            Write-Host ""
            Write-Host "=== Detailed Failures ===" -ForegroundColor Red
            foreach ($item in $failedItems) {
                Write-Host "--------------------------------------------------" -ForegroundColor Red
                Write-Host "Failure in: $($item.File.Name)" -ForegroundColor Red
                if ($item.IsTimeout) {
                    Write-Host "Status: TIMEOUT after $($item.Timeout) seconds" -ForegroundColor Red
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

        # 4. Final summary
        $failedTests = @()
        $passCount = 0
        foreach ($item in $completed) {
            if ($item.ExitCode -eq 0 -and -not (Test-OutputHasFailure -Output $item.Output)) {
                $passCount++
            } else {
                $failedTests += $item.File.Name
            }
        }

        Write-Host ""
        Write-Host "--- Test Summary ---" -ForegroundColor Cyan
        Write-Host "Passed: $passCount" -ForegroundColor Green
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
    if ($createdSharedFixture -and $env:CRUCIBLE_SHARED_FIXTURE -and (Test-Path -LiteralPath $env:CRUCIBLE_SHARED_FIXTURE)) {
        Write-Host "Cleaning up shared adopter fixture..." -ForegroundColor Cyan
        Remove-Item -LiteralPath $env:CRUCIBLE_SHARED_FIXTURE -Recurse -Force -ErrorAction SilentlyContinue
    }
}
exit $exitCode
