# Tests for the serial marker in powershell/run-all-tests.ps1. Item 154.
#
# A file marked serial runs alone after the pool; a marker with no reason, or an unknown
# marker value, fails the run before any file starts. Each case runs a scratch copy of the
# runner over synthetic test files that record when they start and finish, because only
# the times a child actually ran show whether it shared the pool.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")

$RUNNER_SCRIPT = Join-Path $REPO_ROOT "powershell/run-all-tests.ps1"
$results = @()
$tempRoot = New-TestFixtureRoot -NameHint "serial-marker"

function Stage-RunnerScratch {
    param([string]$Dir)
    $powershellDir = Join-Path $Dir "powershell"
    $testsDir = Join-Path $powershellDir "tests"
    $libDir = Join-Path $powershellDir "lib"
    New-Item -ItemType Directory -Path $testsDir, $libDir -Force | Out-Null
    Copy-Item -LiteralPath $RUNNER_SCRIPT -Destination (Join-Path $powershellDir "run-all-tests.ps1") -Force
    Copy-Item -Path (Join-Path $PSScriptRoot "_*.ps1") -Destination $testsDir -Force
    Copy-TestRunnerLibraries -Destination $libDir
    Set-Content -LiteralPath (Join-Path $testsDir "_fixtures.ps1") -Value 'function Get-SharedAdopterFixture { return $null }' -Encoding UTF8
    # Hold every dispatched child until the whole current pool has recorded begin.
    # A wrongly pooled serial child must therefore overlap the pool, at any speed.
    $runner = Join-Path $powershellDir 'run-all-tests.ps1'
    $source = [IO.File]::ReadAllText($runner)
    $anchor = '                    # Check status of running processes'
    Assert-Result 'scheduling barrier remains calibrated' ($source.Contains($anchor)) 'pool status point changed'
    $barrier = @"
                    `$deadline = [datetime]::UtcNow.AddSeconds(120)
                    foreach (`$probe in `$running) {
                        `$begin = Join-Path `$env:CRUCIBLE_SERIAL_MARKER_LOG (`$probe.File.Name + '.begin')
                        while (-not (Test-Path -LiteralPath `$begin)) {
                            if ([datetime]::UtcNow -gt `$deadline) { throw 'probe did not begin' }
                            Start-Sleep -Milliseconds 10
                        }
                    }
                    foreach (`$probe in `$running) {
                        [IO.File]::WriteAllText((Join-Path `$env:CRUCIBLE_SERIAL_MARKER_LOG (`$probe.File.Name + '.release')), 'go')
                    }
"@
    $source = $source.Replace($anchor, $barrier + "`n" + $anchor)
    [IO.File]::WriteAllText($runner, $source, [Text.UTF8Encoding]::new($false))
    return $powershellDir
}

# Each begin marker records which children had ended; no wall clock determines order.
# A scheduler handshake makes overlap observable.
function Write-RecordingTest {
    param([string]$Path, [string]$Header, [switch]$WaitForRelease)
    $name = Split-Path -Leaf $Path
    $body = @"
$Header
`$ErrorActionPreference = "Stop"
`$log = `$env:CRUCIBLE_SERIAL_MARKER_LOG
[System.IO.File]::WriteAllText((Join-Path `$log "$name.begin"), ((@(Get-ChildItem -LiteralPath `$log -Filter '*.end') | ForEach-Object { `$_.Name }) -join "`n"))
if (`$$($WaitForRelease.IsPresent.ToString().ToLowerInvariant())) {
    `$deadline = [datetime]::UtcNow.AddSeconds(120)
    while (-not (Test-Path -LiteralPath (Join-Path `$log "$name.release"))) {
        if ([datetime]::UtcNow -gt `$deadline) { throw 'scheduler did not release the probe' }
        Start-Sleep -Milliseconds 10
    }
}
[System.IO.File]::WriteAllText((Join-Path `$log "$name.end"), 'ended')
Write-Host "PASSED"
exit 0
"@
    Set-Content -LiteralPath $Path -Value $body -Encoding UTF8
}

function Invoke-ScratchRunner {
    param([string]$Runner, [string[]]$RunnerArgs)
    $out = @(Invoke-ExternalCommand -AsLines { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $Runner @RunnerArgs 2>&1 })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}

function Get-RecordedEnds {
    param([string]$Log, [string]$Name)
    $path = Join-Path $Log $Name
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @([System.IO.File]::ReadAllLines($path))
}

try {
    $results += Run-Test -Name "The adopter materialization fixture cannot overlap the CI worker pool" -Body {
        if (-not (Test-Path -LiteralPath (Join-Path $REPO_ROOT "powershell/gates/check-ascii.ps1"))) {
            Skip-Test "the adopter materialization fixture is framework-only and is not installed in bundles"
        }
        $psDir = Stage-RunnerScratch -Dir (Join-Path $tempRoot "adopter-scheduling")
        $testsDir = Join-Path $psDir "tests"
        $log = Join-Path $tempRoot "adopter-scheduling-log"
        New-Item -ItemType Directory -Path $log -Force | Out-Null
        $name = "adopter-update-materialization.tests.ps1"
        # Keep the real scheduling declaration, replacing only the expensive fixture body.
        # Its weight starts it first if the declaration is lost, exposing overlap below.
        $header = (Get-Content -LiteralPath (Join-Path $PSScriptRoot $name) -TotalCount 20) -join "`n"
        $comments = ($header -split "`n" | Where-Object { $_ -match '^\s*#' }) -join "`n"
        Write-RecordingTest -Path (Join-Path $testsDir $name) -Header $comments -WaitForRelease
        foreach ($worker in @("bbb", "ccc", "ddd")) {
            Write-RecordingTest -Path (Join-Path $testsDir "$worker.tests.ps1") -Header "# CI pool worker" -WaitForRelease
        }
        $env:CRUCIBLE_SERIAL_MARKER_LOG = $log
        try {
            $r = Invoke-ScratchRunner -Runner (Join-Path $psDir "run-all-tests.ps1") -RunnerArgs @("-ThrottleLimit", "4")
        } finally {
            Remove-Item env:CRUCIBLE_SERIAL_MARKER_LOG -ErrorAction SilentlyContinue
        }
        Assert-Result -Name "all scheduling probes ran successfully" -Condition ($r.ExitCode -eq 0 -and $r.Output -match 'Passed: 4') -FailureMessage $r.Output
        $begin = @(Get-RecordedEnds $log "$name.begin")
        Assert-Result -Name "adopter probe ran" -Condition (Test-Path -LiteralPath (Join-Path $log "$name.begin")) -FailureMessage $r.Output
        foreach ($worker in @("bbb", "ccc", "ddd")) {
            Assert-Result -Name "adopter starts after $worker finishes" -Condition ($begin -contains "$worker.tests.ps1.end") -FailureMessage "the silent update fixture shared contention with a CI pool worker"
        }
    }

    $results += Run-Test -Name "Serial-marked files run one at a time after the pool" -Body {
        $psDir = Stage-RunnerScratch -Dir (Join-Path $tempRoot "runs-alone")
        $testsDir = Join-Path $psDir "tests"
        $log = Join-Path $tempRoot "runs-alone-log"
        New-Item -ItemType Directory -Path $log -Force | Out-Null
        # The serial files sort first by name, so a runner that ignored the marker would
        # start them alongside the pool files.
        Write-RecordingTest -Path (Join-Path $testsDir "aaa-serial.tests.ps1") -Header "# crucible-test: serial - records its own timing" -WaitForRelease
        Write-RecordingTest -Path (Join-Path $testsDir "aab-serial.tests.ps1") -Header "# crucible-test: serial: also records its own timing" -WaitForRelease
        Write-RecordingTest -Path (Join-Path $testsDir "bbb-pool.tests.ps1") -Header "# pool file" -WaitForRelease
        Write-RecordingTest -Path (Join-Path $testsDir "ccc-pool.tests.ps1") -Header "# pool file" -WaitForRelease

        $env:CRUCIBLE_SERIAL_MARKER_LOG = $log
        try {
            $r = Invoke-ScratchRunner -Runner (Join-Path $psDir "run-all-tests.ps1") -RunnerArgs @("-ThrottleLimit", "4")
        } finally {
            Remove-Item env:CRUCIBLE_SERIAL_MARKER_LOG -ErrorAction SilentlyContinue
        }
        Assert-Result -Name "run passes" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "all four ran" -Condition ($r.Output -match "Passed: 4") -FailureMessage ("expected 'Passed: 4': " + $r.Output)
        Assert-Result -Name "names the file and its reason" -Condition ($r.Output -match "SERIAL aaa-serial\.tests\.ps1 - records its own timing") -FailureMessage ("expected the SERIAL line with the reason: " + $r.Output)

        $aBegin = @(Get-RecordedEnds $log "aaa-serial.tests.ps1.begin")
        $bBegin = @(Get-RecordedEnds $log "aab-serial.tests.ps1.begin")
        $recorded = @('aaa-serial', 'aab-serial', 'bbb-pool', 'ccc-pool' | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $log "${_}.tests.ps1.begin")) -or
            -not (Test-Path -LiteralPath (Join-Path $log "${_}.tests.ps1.end"))
        })
        Assert-Result -Name "every file recorded" -Condition ($recorded.Count -eq 0) -FailureMessage $r.Output
        $afterPool = @('bbb-pool.tests.ps1.end', 'ccc-pool.tests.ps1.end' | Where-Object {
            $_ -notin $aBegin -or $_ -notin $bBegin
        }).Count -eq 0
        Assert-Result -Name "serial files start after the pool ends" -Condition $afterPool -FailureMessage "a serial file started while the pool was still running"
        Assert-Result -Name "serial files do not overlap each other" -Condition (('aaa-serial.tests.ps1.end' -in $bBegin) -or ('aab-serial.tests.ps1.end' -in $aBegin)) -FailureMessage "two serial files ran at the same time"
    }

    foreach ($case in @(
        @{ Name = "no reason"; Header = "# crucible-test: serial"; Expect = "bad\.tests\.ps1: the serial marker gives no reason"; Mode = @() },
        @{ Name = "no reason, -Serial mode"; Header = "# crucible-test: serial -"; Expect = "bad\.tests\.ps1: the serial marker gives no reason"; Mode = @("-Serial") },
        @{ Name = "unknown value"; Header = "# crucible-test: serail - misspelled"; Expect = "bad\.tests\.ps1: unknown crucible-test marker 'serail - misspelled'"; Mode = @() }
    )) {
        $results += Run-Test -Name ("A bad marker fails the run before any file starts (" + $case.Name + ")") -Body {
            $slug = ($case.Name -replace '[^a-z]+', '-')
            $psDir = Stage-RunnerScratch -Dir (Join-Path $tempRoot ("bad-" + $slug))
            $testsDir = Join-Path $psDir "tests"
            $log = Join-Path $tempRoot ("bad-" + $slug + "-log")
            New-Item -ItemType Directory -Path $log -Force | Out-Null
            Write-RecordingTest -Path (Join-Path $testsDir "bad.tests.ps1") -Header $case.Header
            Write-RecordingTest -Path (Join-Path $testsDir "good.tests.ps1") -Header "# pool file"

            $env:CRUCIBLE_SERIAL_MARKER_LOG = $log
            try {
                $r = Invoke-ScratchRunner -Runner (Join-Path $psDir "run-all-tests.ps1") -RunnerArgs $case.Mode
            } finally {
                Remove-Item env:CRUCIBLE_SERIAL_MARKER_LOG -ErrorAction SilentlyContinue
            }
            Assert-Result -Name "run fails" -Condition ($r.ExitCode -ne 0) -FailureMessage ("a bad marker did not fail the run: " + $r.Output)
            Assert-Result -Name "names the file and the problem" -Condition ($r.Output -match $case.Expect) -FailureMessage ("expected '" + $case.Expect + "': " + $r.Output)
            Assert-Result -Name "no file ran" -Condition (@(Get-ChildItem -LiteralPath $log -File).Count -eq 0) -FailureMessage "a test file ran before the marker error stopped the run"
        }
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-TestFileSummary -Results $results
