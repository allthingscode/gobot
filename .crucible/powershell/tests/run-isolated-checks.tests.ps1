$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$RUN_CHECKS_SCRIPT = Join-Path $REPO_ROOT "powershell/run-isolated-checks.ps1"
$pwshCmd = Get-PwshCommand

$results = @()










function Initialize-Repo {
    param([string]$ProjectRoot)
    New-Item -ItemType Directory -Path $ProjectRoot -Force | Out-Null
    Push-Location $ProjectRoot
    try {
        git init --quiet
        git config user.name "Test"
        git config user.email "test@example.com"
        git config commit.gpgSign false
        New-Item -ItemType Directory -Path ".crucible" -Force | Out-Null
        @(
            "project: RunIsolatedChecksTest",
            "verification:",
            "  quick:",
            "    - name: no-op",
            "      command: $pwshCmd -NoProfile -Command exit 0"
        ) | Set-Content -LiteralPath ".crucible/config.yaml" -Encoding UTF8
        Set-Content -LiteralPath "README.md" -Value "# run isolated checks test" -Encoding UTF8
        git add README.md .crucible/config.yaml
        git commit -m "init" --quiet
    } finally {
        Pop-Location
    }
}

function Add-ImplementationWorktree {
    param([string]$ProjectRoot, [string]$TaskId)
    $worktreePath = Join-Path $ProjectRoot ".crucible/.agent-workspaces/implementation-$TaskId"
    New-Item -ItemType Directory -Path (Split-Path -Parent $worktreePath) -Force | Out-Null
    git -C $ProjectRoot worktree add -b "task/$TaskId" $worktreePath --quiet
    return $worktreePath
}

function Remove-WorktreeIfPresent {
    param([string]$ProjectRoot, [string]$WorktreePath)
    if (Test-Path -LiteralPath $WorktreePath) {
        git -C $ProjectRoot worktree remove --force $WorktreePath 2>$null
    }
    git -C $ProjectRoot worktree prune 2>$null
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-run-isolated-checks-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$projectRoot = Join-Path $tempRoot "project"
$taskId = "T-001"
$worktreePath = Join-Path $projectRoot ".crucible/.agent-workspaces/implementation-$taskId"

try {
    Initialize-Repo -ProjectRoot $projectRoot
    Add-ImplementationWorktree -ProjectRoot $projectRoot -TaskId $taskId | Out-Null

    $results += Run-Test -Name "Executes configured quick check in worktree" -Body {
        Push-Location $projectRoot
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode quick
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "check name" -Condition ($output -match "==> no-op") -FailureMessage "expected configured check to run. Output:`n$output"
    }

    $results += Run-Test -Name "Executes when CWD is different using -ProjectRoot" -Body {
        Push-Location $tempRoot
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode quick -ProjectRoot $projectRoot
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "check name" -Condition ($output -match "==> no-op") -FailureMessage "expected configured check to run. Output:`n$output"
    }

    $results += Run-Test -Name "Configured config_check command runs in full mode and fails when exit code is non-zero (D53)" -Body {
        Push-Location $projectRoot
        try {
            @(
                "project: RunIsolatedChecksTest",
                "verification:",
                "  quick:",
                "    - name: no-op",
                "      command: $pwshCmd -NoProfile -Command exit 0",
                "  full:",
                "    - name: no-op-full",
                "      command: $pwshCmd -NoProfile -Command exit 0",
                "  config_check:",
                "    name: test config check",
                "    command: $pwshCmd -NoProfile -Command exit 1"
            ) | Set-Content -LiteralPath ".crucible/config.yaml" -Encoding UTF8
            
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode full
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -ne 0) -FailureMessage "expected failure (non-zero exit) due to config_check failing, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "config check run" -Condition ($output -match "==> test config check") -FailureMessage "expected config check to run in full mode. Output:`n$output"
    }

    $results += Run-Test -Name "Configured config_check command runs in full mode and passes when exit code is zero (D53)" -Body {
        Push-Location $projectRoot
        try {
            @(
                "project: RunIsolatedChecksTest",
                "verification:",
                "  quick:",
                "    - name: no-op",
                "      command: $pwshCmd -NoProfile -Command exit 0",
                "  full:",
                "    - name: no-op-full",
                "      command: $pwshCmd -NoProfile -Command exit 0",
                "  config_check:",
                "    name: test config check pass",
                "    command: $pwshCmd -NoProfile -Command exit 0"
            ) | Set-Content -LiteralPath ".crucible/config.yaml" -Encoding UTF8
            
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode full
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected success, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "config check run" -Condition ($output -match "==> test config check pass") -FailureMessage "expected config check to run and pass. Output:`n$output"
    }

    $results += Run-Test -Name "Configured config_check is skipped in quick/test mode (D53)" -Body {
        Push-Location $projectRoot
        try {
            @(
                "project: RunIsolatedChecksTest",
                "verification:",
                "  quick:",
                "    - name: no-op",
                "      command: $pwshCmd -NoProfile -Command exit 0",
                "  full:",
                "    - name: no-op-full",
                "      command: $pwshCmd -NoProfile -Command exit 0",
                "  config_check:",
                "    name: test config check skip",
                "    command: $pwshCmd -NoProfile -Command exit 1"
            ) | Set-Content -LiteralPath ".crucible/config.yaml" -Encoding UTF8
            
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode quick
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected success (config_check should be skipped in quick mode), got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "config check skip" -Condition ($output -notmatch "==> test config check skip") -FailureMessage "config check should not run in quick mode. Output:`n$output"
    }

    $results += Run-Test -Name "Folded block-scalar command is joined and executed, not parsed as a bare '>'" -Body {
        Push-Location $projectRoot
        try {
            @(
                "project: RunIsolatedChecksTest",
                "verification:",
                "  full:",
                "    - name: folded-ok",
                "      command: >-",
                "        $pwshCmd -NoProfile",
                "        -Command `"exit 0`""
            ) | Set-Content -LiteralPath ".crucible/config.yaml" -Encoding UTF8

            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode full
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected success from folded command, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "check ran" -Condition ($output -match "==> folded-ok") -FailureMessage "expected folded check to run. Output:`n$output"
        Assert-Result -Name "no bare-gt parse error" -Condition ($output -notmatch "is not recognized") -FailureMessage "folded scalar indicator leaked to Invoke-Expression. Output:`n$output"
    }

    $results += Run-Test -Name "Block-scalar command body actually executes (failure propagates)" -Body {
        Push-Location $projectRoot
        try {
            @(
                "project: RunIsolatedChecksTest",
                "verification:",
                "  full:",
                "    - name: folded-fail",
                "      command: >-",
                "        $pwshCmd -NoProfile",
                "        -Command `"exit 1`""
            ) | Set-Content -LiteralPath ".crucible/config.yaml" -Encoding UTF8

            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode full
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -ne 0) -FailureMessage "expected folded command body to run and fail, got $($res.ExitCode). Output:`n$output"
    }

    $results += Run-Test -Name "Cross-platform advisory names uncovered CI OS on a multi-OS matrix (D3)" -Body {
        $wfDir = Join-Path $projectRoot ".github/workflows"
        New-Item -ItemType Directory -Path $wfDir -Force | Out-Null
        @(
            "name: ci",
            "on: [push]",
            "jobs:",
            "  test:",
            "    strategy:",
            "      matrix:",
            "        os: [ubuntu-latest, windows-latest]",
            "    runs-on: matrix.os"
        ) | Set-Content -LiteralPath (Join-Path $wfDir "ci.yml") -Encoding UTF8
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode quick -ProjectRoot $projectRoot
            }
        } finally {
            Remove-Item -LiteralPath (Join-Path $wfDir "ci.yml") -Force -ErrorAction SilentlyContinue
        }
        $output = $res.Output -join "`n"
        $expectedUncovered = if (Test-PlatformIsWindows) { "linux" } else { "windows" }
        Assert-Result -Name "advisory present" -Condition ($output -match "\[cross-platform\]") -FailureMessage "expected cross-platform advisory. Output:`n$output"
        Assert-Result -Name "names uncovered os" -Condition ($output -match $expectedUncovered) -FailureMessage "expected advisory to name uncovered OS '$expectedUncovered'. Output:`n$output"
    }

    $results += Run-Test -Name "No cross-platform advisory when CI targets only the host OS (D3)" -Body {
        $wfDir = Join-Path $projectRoot ".github/workflows"
        New-Item -ItemType Directory -Path $wfDir -Force | Out-Null
        $onlyHost = if (Test-PlatformIsWindows) { "windows-latest" } else { "ubuntu-latest" }
        @(
            "name: ci",
            "on: [push]",
            "jobs:",
            "  test:",
            "    runs-on: $onlyHost"
        ) | Set-Content -LiteralPath (Join-Path $wfDir "ci.yml") -Encoding UTF8
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode quick -ProjectRoot $projectRoot
            }
        } finally {
            Remove-Item -LiteralPath (Join-Path $wfDir "ci.yml") -Force -ErrorAction SilentlyContinue
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "no advisory" -Condition ($output -notmatch "\[cross-platform\]") -FailureMessage "advisory should not fire when CI only targets host OS. Output:`n$output"
    }
} finally {
    if (Test-Path -LiteralPath $projectRoot) {
        Remove-WorktreeIfPresent -ProjectRoot $projectRoot -WorktreePath $worktreePath
    }
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
