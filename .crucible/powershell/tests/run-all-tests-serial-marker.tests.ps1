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
    foreach ($lib in @("run-lock.ps1", "normalized-hash.ps1")) {
        Copy-Item -LiteralPath (Join-Path $REPO_ROOT "powershell/lib/$lib") -Destination (Join-Path $libDir $lib) -Force
    }
    Set-Content -LiteralPath (Join-Path $testsDir "_fixtures.ps1") -Value 'function Get-SharedAdopterFixture { return $null }' -Encoding UTF8
    return $powershellDir
}

# A synthetic test that records its start and end, in UTC ticks, under the directory the
# caller names in CRUCIBLE_SERIAL_MARKER_LOG, sleeping in between so overlap is visible.
function Write-RecordingTest {
    param([string]$Path, [string]$Header, [int]$SleepMs)
    $name = Split-Path -Leaf $Path
    $body = @"
$Header
`$ErrorActionPreference = "Stop"
`$log = `$env:CRUCIBLE_SERIAL_MARKER_LOG
[System.IO.File]::WriteAllText((Join-Path `$log "$name.begin"), [string][DateTime]::UtcNow.Ticks)
Start-Sleep -Milliseconds $SleepMs
[System.IO.File]::WriteAllText((Join-Path `$log "$name.end"), [string][DateTime]::UtcNow.Ticks)
Write-Host "PASSED"
exit 0
"@
    Set-Content -LiteralPath $Path -Value $body -Encoding UTF8
}

function Invoke-ScratchRunner {
    param([string]$Runner, [string[]]$RunnerArgs)
    $out = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $Runner @RunnerArgs 2>&1)
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}

function Get-Ticks {
    param([string]$Log, [string]$Name)
    $path = Join-Path $Log $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return [long]([System.IO.File]::ReadAllText($path).Trim())
}

try {
    $results += Run-Test -Name "Serial-marked files run one at a time after the pool" -Body {
        $psDir = Stage-RunnerScratch -Dir (Join-Path $tempRoot "runs-alone")
        $testsDir = Join-Path $psDir "tests"
        $log = Join-Path $tempRoot "runs-alone-log"
        New-Item -ItemType Directory -Path $log -Force | Out-Null
        # The serial files sort first by name, so a runner that ignored the marker would
        # start them alongside the pool files.
        Write-RecordingTest -Path (Join-Path $testsDir "aaa-serial.tests.ps1") -Header "# crucible-test: serial - records its own timing" -SleepMs 1500
        Write-RecordingTest -Path (Join-Path $testsDir "aab-serial.tests.ps1") -Header "# crucible-test: serial: also records its own timing" -SleepMs 1500
        Write-RecordingTest -Path (Join-Path $testsDir "bbb-pool.tests.ps1") -Header "# pool file" -SleepMs 3000
        Write-RecordingTest -Path (Join-Path $testsDir "ccc-pool.tests.ps1") -Header "# pool file" -SleepMs 3000

        $env:CRUCIBLE_SERIAL_MARKER_LOG = $log
        try {
            $r = Invoke-ScratchRunner -Runner (Join-Path $psDir "run-all-tests.ps1") -RunnerArgs @("-ThrottleLimit", "4")
        } finally {
            Remove-Item env:CRUCIBLE_SERIAL_MARKER_LOG -ErrorAction SilentlyContinue
        }
        Assert-Result -Name "run passes" -Condition ($r.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $r.ExitCode + ". Output: " + $r.Output)
        Assert-Result -Name "all four ran" -Condition ($r.Output -match "Passed: 4") -FailureMessage ("expected 'Passed: 4': " + $r.Output)
        Assert-Result -Name "names the file and its reason" -Condition ($r.Output -match "SERIAL aaa-serial\.tests\.ps1 - records its own timing") -FailureMessage ("expected the SERIAL line with the reason: " + $r.Output)

        $poolEnd = [Math]::Max((Get-Ticks $log "bbb-pool.tests.ps1.end"), (Get-Ticks $log "ccc-pool.tests.ps1.end"))
        $aBegin = Get-Ticks $log "aaa-serial.tests.ps1.begin"
        $aEnd = Get-Ticks $log "aaa-serial.tests.ps1.end"
        $bBegin = Get-Ticks $log "aab-serial.tests.ps1.begin"
        $bEnd = Get-Ticks $log "aab-serial.tests.ps1.end"
        Assert-Result -Name "every file recorded" -Condition ($null -notin @($aBegin, $aEnd, $bBegin, $bEnd, $poolEnd)) -FailureMessage ("a synthetic file did not record its run: " + $r.Output)
        Assert-Result -Name "serial files start after the pool ends" -Condition (($aBegin -ge $poolEnd) -and ($bBegin -ge $poolEnd)) -FailureMessage "a serial file started while the pool was still running"
        Assert-Result -Name "serial files do not overlap each other" -Condition (($aEnd -le $bBegin) -or ($bEnd -le $aBegin)) -FailureMessage "two serial files ran at the same time"
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
            Write-RecordingTest -Path (Join-Path $testsDir "bad.tests.ps1") -Header $case.Header -SleepMs 0
            Write-RecordingTest -Path (Join-Path $testsDir "good.tests.ps1") -Header "# pool file" -SleepMs 0

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
