# Tests for the Crucible framework pre-push hook.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$HOOK_PATH = Join-Path $REPO_ROOT "scripts/hooks/pre-push"
$PRE_COMMIT_HOOK_PATH = Join-Path $REPO_ROOT "scripts/hooks/pre-commit"
$results = @()










function Get-ShellCommand {
    $shell = Get-Command sh -ErrorAction SilentlyContinue
    if ($null -ne $shell) {
        return $shell.Source
    }

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return $null
    }

    $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
    $gitShell = Join-Path $gitRoot "usr/bin/sh.exe"
    if (Test-Path -LiteralPath $gitShell) {
        return $gitShell
    }

    return $null
}

$results += Run-Test -Name "Pre-push hook exists and is non-empty" -Body {
    Assert-Result -Name "hook exists" -Condition (Test-Path -LiteralPath $HOOK_PATH) -FailureMessage "scripts/hooks/pre-push was not found"

    $hookContent = Get-Content -LiteralPath $HOOK_PATH -Raw -Encoding UTF8
    Assert-Result -Name "hook non-empty" -Condition (-not [string]::IsNullOrWhiteSpace($hookContent)) -FailureMessage "scripts/hooks/pre-push is empty"
    Assert-Result -Name "hook uses strict shell mode" -Condition ($hookContent -match '(?m)^set -e$') -FailureMessage "pre-push hook should abort on the first failed check"
}

$results += Run-Test -Name "Hooks do not self-detect framework repos from project files" -Body {
    $prePushContent = Get-Content -LiteralPath $HOOK_PATH -Raw -Encoding UTF8
    $preCommitContent = Get-Content -LiteralPath $PRE_COMMIT_HOOK_PATH -Raw -Encoding UTF8

    foreach ($hookContent in @($prePushContent, $preCommitContent)) {
        Assert-Result -Name "no proposals fallback" -Condition (-not $hookContent.Contains('$REPO_ROOT/proposals')) -FailureMessage "hook should not infer framework mode from a proposals directory"
        Assert-Result -Name "no run-all-tests fallback" -Condition (-not $hookContent.Contains('$REPO_ROOT/powershell/run-all-tests.ps1')) -FailureMessage "hook should not infer framework mode from run-all-tests.ps1"
    }
}

$results += Run-Test -Name "Pre-push hook has valid shell syntax" -Body {
    $shell = Get-ShellCommand
    Assert-Result -Name "sh available" -Condition ($null -ne $shell) -FailureMessage "sh is required to syntax-check scripts/hooks/pre-push"

    $syntax = Invoke-ExternalCommand {
        & $shell -n $HOOK_PATH
    }
    Assert-Result -Name "shell syntax" -Condition ($syntax.ExitCode -eq 0) -FailureMessage ("expected sh -n exit 0, got " + $syntax.ExitCode + ". Output: " + ($syntax.Output -join "`n"))
}

$results += Run-Test -Name "Pre-push hook runs the expected verification suites" -Body {
    $hookContent = Get-Content -LiteralPath $HOOK_PATH -Raw -Encoding UTF8
    $expectedScripts = @(
        "powershell/tests/init-project-core.tests.ps1",
        "powershell/tests/init-project-instructions.tests.ps1",
        "powershell/tests/init-project-config-version.tests.ps1",
        "powershell/tests/validate-config.tests.ps1",
        "powershell/tests/adopter-smoke.tests.ps1",
        "powershell/tests/check-file-affinity.tests.ps1",
        "powershell/tests/factory.tests.ps1",
        "powershell/tests/adopter-bootstrap.tests.ps1",
        "powershell/tests/pre-push-hook.tests.ps1",
        "powershell/tests/examples-mirror-sync.tests.ps1"
    )

    foreach ($script in $expectedScripts) {
        Assert-Result -Name "$script exists" -Condition (Test-Path -LiteralPath (Join-Path $REPO_ROOT $script)) -FailureMessage ("missing expected test script: " + $script)
        Assert-Result -Name "$script invoked" -Condition ($hookContent.Contains($script)) -FailureMessage ("pre-push hook does not invoke " + $script)
    }

    $preCommitOnlyScripts = @(
        "powershell/tests/check-policy-drift.ps1",
        "powershell/tests/check-mojibake.ps1",
        "scripts/factory_lint.go"
    )

    foreach ($script in $preCommitOnlyScripts) {
        Assert-Result -Name "$script remains pre-commit only" -Condition (-not $hookContent.Contains($script)) -FailureMessage ("pre-push hook should not duplicate pre-commit check " + $script)
    }
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
