# Regression tests for clear-session-state.ps1 and update-session-state.ps1 project-root
# resolution (TODO item 240).
#
# Every specialist SOP runs clear-session-state.ps1 first. It used to take no -ProjectRoot
# and update-session-state.ps1 fell back to the working directory, so a Claude specialist
# standing in the orchestrator's directory cleared that repository's state instead of the
# adopter's, and reported success.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$results = @()

$tempRoot = New-TestFixtureRoot -NameHint "clear-session-state-test"
$frameworkScript = Join-Path $REPO_ROOT "powershell/clear-session-state.ps1"

function New-ProjectDir {
    param([string]$Path)
    New-Item -ItemType Directory -Path (Join-Path $Path ".crucible/backlog") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Path ".crucible/config.yaml") -Value "crucible_root: .crucible" -Encoding UTF8
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-StateFile {
    param([string]$Root)
    return (Join-Path $Root ".crucible/session/global/session_state.json")
}

function Invoke-Clear {
    param([string]$Script, [string]$WorkingDir, [string]$ProjectRoot = "")
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Script, "-Specialist", "implementation")
    if ($ProjectRoot) { $argList += @("-ProjectRoot", $ProjectRoot) }
    Push-Location $WorkingDir
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & (Get-PwshCommand) @argList 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevPref
        Pop-Location
    }
    return [pscustomobject]@{ ExitCode = $code; Output = (($output | ForEach-Object { "$_" }) -join "`n") }
}

try {
    $results += Run-Test -Name "A bundled copy clears its own adopter's state, not the working directory's" -Body {
        $adopter = New-ProjectDir -Path (Join-Path $tempRoot "adopter")
        $orchestratorDir = New-ProjectDir -Path (Join-Path $tempRoot "orchestrator")
        $bundle = Join-Path $adopter ".crucible/powershell"
        New-Item -ItemType Directory -Path $bundle -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $REPO_ROOT "powershell/clear-session-state.ps1") -Destination $bundle
        Copy-Item -LiteralPath (Join-Path $REPO_ROOT "powershell/update-session-state.ps1") -Destination $bundle
        Copy-Item -LiteralPath (Join-Path $REPO_ROOT "powershell/lib") -Destination $bundle -Recurse

        $res = Invoke-Clear -Script (Join-Path $bundle "clear-session-state.ps1") -WorkingDir $orchestratorDir
        Assert-Result -Name "exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage ("exit " + $res.ExitCode + ":`n" + $res.Output)
        Assert-Result -Name "adopter state written" -Condition (Test-Path -LiteralPath (Get-StateFile $adopter)) -FailureMessage "the adopter's session_state.json was not written"
        Assert-Result -Name "working directory untouched" -Condition (-not (Test-Path -LiteralPath (Get-StateFile $orchestratorDir))) -FailureMessage "the working directory's session_state.json was written"
    }

    $results += Run-Test -Name "An explicit -ProjectRoot names the project to clear" -Body {
        $target = New-ProjectDir -Path (Join-Path $tempRoot "explicit-target")
        $other = New-ProjectDir -Path (Join-Path $tempRoot "explicit-other")

        $res = Invoke-Clear -Script $frameworkScript -WorkingDir $other -ProjectRoot $target
        Assert-Result -Name "exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage ("exit " + $res.ExitCode + ":`n" + $res.Output)
        Assert-Result -Name "target state written" -Condition (Test-Path -LiteralPath (Get-StateFile $target)) -FailureMessage "the named project's session_state.json was not written"
        $state = Get-Content -LiteralPath (Get-StateFile $target) -Raw
        Assert-Result -Name "implementation cleared" -Condition ($state -match '"implementation"' -and $state -match 'Cleared by script') -FailureMessage ("unexpected state:`n" + $state)
        Assert-Result -Name "other project untouched" -Condition (-not (Test-Path -LiteralPath (Get-StateFile $other))) -FailureMessage "the working directory's session_state.json was written"
    }

    $results += Run-Test -Name "With no root to find, it refuses instead of writing into the working directory" -Body {
        $bare = Join-Path $tempRoot "not-a-project"
        New-Item -ItemType Directory -Path $bare -Force | Out-Null

        $res = Invoke-Clear -Script $frameworkScript -WorkingDir $bare
        Assert-Result -Name "non-zero exit" -Condition ($res.ExitCode -ne 0) -FailureMessage ("expected a refusal, got exit 0:`n" + $res.Output)
        Assert-Result -Name "names -ProjectRoot" -Condition ($res.Output -match 'Pass -ProjectRoot') -FailureMessage ("refusal did not tell the caller to pass -ProjectRoot:`n" + $res.Output)
        Assert-Result -Name "nothing written" -Condition (-not (Test-Path -LiteralPath (Join-Path $bare ".crucible"))) -FailureMessage "a .crucible directory was created in a non-project working directory"
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failures = @($results | Where-Object { -not $_ }).Count
if ($failures -gt 0) {
    Write-Host ("`n{0} test(s) failed." -f $failures) -ForegroundColor Red
    exit 1
}
Write-Host "`nALL TESTS PASSED" -ForegroundColor Green
exit 0
