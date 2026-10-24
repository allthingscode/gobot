# Regression for run-all-tests.ps1 Start-TestProcess: a test that omits a mandatory
# argument must get a binding error even when the runner has an open stdin pipe.
# Pin -NonInteractive separately: closed stdin alone also gives a binding error.
# Exercise the pool, -Serial streaming, and the serial-marked phase. Item 322.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/platform.ps1')

$results = @()
$tempRoot = New-TestFixtureRoot -NameHint 'runner-stdin'

try {
    foreach ($mode in @('parallel', 'serial', 'serial-marked')) {
        $results += Run-Test -Name "Test children refuse prompts and see stdin EOF with open runner stdin ($mode)" -Body {
            $psDir = Join-Path $tempRoot "$mode/powershell"
            $testsDir = Join-Path $psDir 'tests'
            $libDir = Join-Path $psDir 'lib'
            New-Item -ItemType Directory -Path $testsDir, $libDir -Force | Out-Null
            $runnerCopy = Join-Path $psDir 'run-all-tests.ps1'
            Copy-Item -LiteralPath (Join-Path $REPO_ROOT 'powershell/run-all-tests.ps1') -Destination $runnerCopy
            Copy-Item -Path (Join-Path $PSScriptRoot '_*.ps1') -Destination $testsDir
            foreach ($lib in @('run-lock.ps1', 'normalized-hash.ps1')) {
                Copy-Item -LiteralPath (Join-Path $REPO_ROOT "powershell/lib/$lib") -Destination $libDir
            }
            # Keep the real runner and lock; only fixture pre-staging needs the full
            # framework, so stub it just as run-all-tests-runner.tests.ps1 does.
            Set-Content -LiteralPath (Join-Path $testsDir '_fixtures.ps1') -Encoding UTF8 -Value 'function Get-SharedAdopterFixture { return $null }'
            $fixture = @'
$ErrorActionPreference = 'Stop'
if ([Environment]::GetCommandLineArgs() -notcontains '-NonInteractive') {
    throw 'Test child was started without -NonInteractive.'
}
function Require-Argument {
    param([Parameter(Mandatory = $true)][string]$Required)
    throw 'The function body must never run without its mandatory argument.'
}
try {
    Require-Argument
    throw 'Missing argument did not raise a binding error.'
} catch [System.Management.Automation.ParameterBindingException] {
    if ($_.FullyQualifiedErrorId -notmatch 'MissingMandatoryParameter' -or $_ -notmatch 'Required') { throw }
    Set-Content -LiteralPath (Join-Path $PSScriptRoot 'binding-error.txt') -Value 'Required' -Encoding UTF8
}
if ([Console]::In.Read() -ne -1) { throw 'Test stdin did not reach EOF.' }
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'stdin-eof.txt') -Value 'EOF' -Encoding UTF8
exit 0
'@
            if ($mode -eq 'serial-marked') {
                $fixture = "# crucible-test: serial - exercises stdin isolation after the pool`n" + $fixture
            }
            Set-Content -LiteralPath (Join-Path $testsDir 'missing-argument.tests.ps1') -Value $fixture -Encoding UTF8

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = Get-PwshCommand
            # Deliberately interactive, with stdin redirected but held open until
            # the run ends. Closing this pipe early would mask the original hang.
            foreach ($arg in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerCopy, '-ThrottleLimit', '2', '-IdleTimeoutSeconds', '5')) {
                [void]$psi.ArgumentList.Add($arg)
            }
            if ($mode -eq 'serial') { [void]$psi.ArgumentList.Add('-Serial') }
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            [void]$proc.Start()
            try {
                $outTask = $proc.StandardOutput.ReadToEndAsync()
                $errTask = $proc.StandardError.ReadToEndAsync()
                # The inner idle timeout bounds the original prompt hang. The outer
                # cap and tree kill also bound regressions in timeout handling.
                $exited = $proc.WaitForExit(20000)
                Assert-Result -Name 'runner completes within 20s' -Condition $exited -FailureMessage 'Runner hung with an open stdin pipe.'
                Assert-Result -Name 'runner releases output pipes' -Condition ($outTask.Wait(1000) -and $errTask.Wait(1000)) -FailureMessage 'Runner left output pipes open.'
                $output = $outTask.Result + $errTask.Result
                Assert-Result -Name 'missing argument does not time out' -Condition ($output -notmatch 'TIMEOUT') -FailureMessage $output
                Assert-Result -Name 'fixture exits successfully' -Condition ($proc.ExitCode -eq 0) -FailureMessage $output
                Assert-Result -Name 'mandatory argument raises a binding error' -Condition (Test-Path -LiteralPath (Join-Path $testsDir 'binding-error.txt')) -FailureMessage $output
                Assert-Result -Name 'test stdin is closed' -Condition (Test-Path -LiteralPath (Join-Path $testsDir 'stdin-eof.txt')) -FailureMessage $output
                Assert-Result -Name 'runner counts the fixture' -Condition ($output -match 'Passed: 1') -FailureMessage $output
                if ($mode -eq 'serial-marked') {
                    Assert-Result -Name 'fixture ran in serial-marked phase' -Condition ($output -match 'SERIAL missing-argument.tests.ps1') -FailureMessage $output
                }
            } finally {
                if (-not $proc.HasExited) {
                    $proc.Kill($true)
                    [void]$proc.WaitForExit(5000)
                }
                $proc.StandardInput.Close()
                $proc.Dispose()
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-TestFileSummary -Results $results
