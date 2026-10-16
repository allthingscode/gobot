$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$CRUCIBLE_SCRIPT = Join-Path $REPO_ROOT "powershell/crucible.ps1"
$tempRoot = New-TestFixtureRoot -NameHint "crucible-usage"
$results = @()

try {
    # Item 218: no task ID must explain both the invocation path and bootstrap route.
    $output = (& pwsh -NoProfile -File $CRUCIBLE_SCRIPT -Init -ProjectRoot $tempRoot -Quiet 2>&1) -join "`n"
    $exitCode = $LASTEXITCODE
    $results += Run-Test -Name "Missing TaskId exits with an error" -Body {
        Assert-Result -Name "exit code" -Condition ($exitCode -eq 1) -FailureMessage "expected exit 1, got $exitCode. Output: $output"
        Assert-Result -Name "missing TaskId" -Condition ($output -match '\[ERROR\] -TaskId is required') -FailureMessage $output
    }
    $results += Run-Test -Name "Missing TaskId usage names the installed script" -Body {
        foreach ($mode in @('Init', 'Health', 'Doctor')) {
            $expected = '.\.crucible\powershell\crucible.ps1 -' + $mode
            Assert-Result -Name "$mode script path" -Condition ($output.Contains($expected)) -FailureMessage $output
        }
    }
    $results += Run-Test -Name "Missing TaskId explains bootstrap mode" -Body {
        Assert-Result -Name "bootstrap route" -Condition ($output -match 'bootstrap mode.*Groomer.*sops/orchestrator\.md.*Session Start.*step 5') -FailureMessage $output
    }
} finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $runRoot = [IO.Path]::GetFullPath((Get-TestRunRoot)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTemp.StartsWith($runRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Fixture cleanup path is outside the test run root: $resolvedTemp"
    }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}

if ($results -contains $false) { exit 1 }
Write-Host "ALL TESTS PASSED ($($results.Count) tests)"
exit 0
