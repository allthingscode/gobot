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

$tempRoot = New-TestFixtureRoot -NameHint "run-isolated-checks-test"
$projectRoot = Join-Path $tempRoot "project"
$taskId = "T-001"
$worktreePath = Join-Path $projectRoot ".crucible/.agent-workspaces/implementation-$taskId"

try {
    Initialize-Repo -ProjectRoot $projectRoot
    Add-ImplementationWorktree -ProjectRoot $projectRoot -TaskId $taskId | Out-Null


    $results += Run-Test -Name "Unreadable encoding baseline fails closed (item 225)" -Body {
        $orphanProject = Join-Path $tempRoot "orphan-project"
        Initialize-Repo -ProjectRoot $orphanProject
        git -C $orphanProject branch -m main
        git -C $orphanProject checkout --orphan orphan-225 --quiet
        git -C $orphanProject commit -m "unrelated root" --quiet
        $res = Invoke-ExternalCommand { & $pwshCmd -NoProfile -File $RUN_CHECKS_SCRIPT -TaskId T-225 -Mode quick -Commit HEAD -ProjectRoot $orphanProject }
        Assert-Result -Name "unreadable encoding baseline fails" -Condition ($res.ExitCode -ne 0 -and ($res.Output -join "`n") -match "Could not determine encoding baseline") -FailureMessage ($res.Output -join "`n")
    }

    # A committed BOM must be scanned against the configured primary. Item 225.
    $results += Run-Test -Name "Release baseline catches committed encoding corruption" -Body {
        $releaseProject = Join-Path $tempRoot "release-project"
        Initialize-Repo -ProjectRoot $releaseProject
        git -C $releaseProject branch -m release
        $releaseConfig = Join-Path $releaseProject ".crucible/config.yaml"
        $config = [IO.File]::ReadAllText($releaseConfig).Replace("project: RunIsolatedChecksTest", "project:`n  default_branch: release")
        [IO.File]::WriteAllText($releaseConfig, $config, [Text.UTF8Encoding]::new($false))
        git -C $releaseProject add .
        git -C $releaseProject commit -m "configure release" --quiet
        $releaseWt = Add-ImplementationWorktree -ProjectRoot $releaseProject -TaskId T-225
        try {
            [IO.File]::WriteAllText((Join-Path $releaseWt "bad.md"), "bad encoding`n", [Text.UTF8Encoding]::new($true))
            git -C $releaseWt add bad.md
            git -C $releaseWt commit -m "committed BOM" --quiet
            $res = Invoke-ExternalCommand { & $pwshCmd -NoProfile -File $RUN_CHECKS_SCRIPT -TaskId T-225 -Mode quick -ProjectRoot $releaseProject }
            Assert-Result -Name "release encoding guard rejects BOM" -Condition ($res.ExitCode -ne 0 -and ($res.Output -join "`n") -match "Check failed: Encoding guard") -FailureMessage ($res.Output -join "`n")
        } finally {
            Remove-WorktreeIfPresent -ProjectRoot $releaseProject -WorktreePath $releaseWt
        }
    }

    $results += Run-Test -Name "Custom workspaces locates implementation checks (item 188)" -Body {
        $customProject = Join-Path $tempRoot "custom-project"
        Initialize-Repo -ProjectRoot $customProject
        $cfg = Join-Path $customProject ".crucible/config.yaml"
        [System.IO.File]::AppendAllText($cfg, "`npaths:`n  workspaces: custom worktrees`n", [System.Text.UTF8Encoding]::new($false))
        $customWt = Join-Path $customProject "custom worktrees/implementation-T-188"
        git -C $customProject worktree add -b task/T-188 $customWt --quiet
        try {
            $res = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $RUN_CHECKS_SCRIPT -TaskId T-188 -Mode quick -ProjectRoot $customProject }
            Assert-Result -Name "custom implementation checks pass" -Condition ($res.ExitCode -eq 0) -FailureMessage ($res.Output -join "`n")
            Assert-Result -Name "no default workspaces" -Condition (-not (Test-Path (Join-Path $customProject ".crucible/.agent-workspaces"))) -FailureMessage "created default workspaces"
        } finally {
            Remove-WorktreeIfPresent -ProjectRoot $customProject -WorktreePath $customWt
        }
    }


    $results += Run-Test -Name "Detached checks create only configured workspaces (item 188)" -Body {
        $customProject = Join-Path $tempRoot "custom-detached"
        Initialize-Repo -ProjectRoot $customProject
        [System.IO.File]::AppendAllText((Join-Path $customProject ".crucible/config.yaml"), "`npaths:`n  workspaces: custom worktrees`n", [System.Text.UTF8Encoding]::new($false))
        $res = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $RUN_CHECKS_SCRIPT -TaskId R-188 -Mode quick -Commit HEAD -ProjectRoot $customProject }
        Assert-Result -Name "detached checks pass" -Condition ($res.ExitCode -eq 0) -FailureMessage ($res.Output -join "`n")
        Assert-Result -Name "detached worktree uses configured root" -Condition (($res.Output -join "`n").Contains((Join-Path $customProject "custom worktrees"))) -FailureMessage ($res.Output -join "`n")
        Assert-Result -Name "no default workspaces" -Condition (-not (Test-Path (Join-Path $customProject ".crucible/.agent-workspaces"))) -FailureMessage "default workspaces created"
    }

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

    # Item 172: the project's pre-push hook runs on the task branch in full mode, so a
    # check it makes fails before the Human Gate instead of at the push after it.
    $hookConfig = @(
        "project: RunIsolatedChecksTest",
        "verification:",
        "  quick:",
        "    - name: no-op",
        "      command: $pwshCmd -NoProfile -Command exit 0",
        "  full:",
        "    - name: no-op-full",
        "      command: $pwshCmd -NoProfile -Command exit 0",
        "hooks:",
        "  project_dir: project-hooks"
    )
    New-Item -ItemType Directory -Path (Join-Path $projectRoot "project-hooks") -Force | Out-Null
    $worktreeHooksDir = Join-Path $worktreePath "project-hooks"
    New-Item -ItemType Directory -Path $worktreeHooksDir -Force | Out-Null
    $worktreeHook = Join-Path $worktreeHooksDir "pre-push"

    $results += Run-Test -Name "A failing project pre-push hook fails full mode and its output is shown (item 172)" -Body {
        $hookConfig | Set-Content -LiteralPath (Join-Path $projectRoot ".crucible/config.yaml") -Encoding UTF8
        [System.IO.File]::WriteAllText($worktreeHook, "#!/bin/sh`necho `"project hook ran, preflight=`$CRUCIBLE_PRE_PUSH_PREFLIGHT`"`nexit 3`n")
        $res = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode full -ProjectRoot $projectRoot
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -ne 0) -FailureMessage "expected the failing project hook to fail full mode, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "hook output shown" -Condition ($output -match "project hook ran, preflight=1") -FailureMessage "expected the hook's own output, with CRUCIBLE_PRE_PUSH_PREFLIGHT=1. Output:`n$output"
        Assert-Result -Name "named failure" -Condition ($output -match "Check failed: Project pre-push hook") -FailureMessage "expected the stable failure marker the gate parses. Output:`n$output"
    }

    $results += Run-Test -Name "A passing project pre-push hook lets full mode pass, and quick mode does not run it (item 172)" -Body {
        $hookConfig | Set-Content -LiteralPath (Join-Path $projectRoot ".crucible/config.yaml") -Encoding UTF8
        [System.IO.File]::WriteAllText($worktreeHook, "#!/bin/sh`necho `"project hook passed`"`nexit 0`n")
        $full = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode full -ProjectRoot $projectRoot
        }
        $fullOutput = $full.Output -join "`n"
        Assert-Result -Name "full exit code" -Condition ($full.ExitCode -eq 0) -FailureMessage "expected success, got $($full.ExitCode). Output:`n$fullOutput"
        Assert-Result -Name "hook ran in full" -Condition ($fullOutput -match "project hook passed") -FailureMessage "expected the hook to run in full mode. Output:`n$fullOutput"

        [System.IO.File]::WriteAllText($worktreeHook, "#!/bin/sh`necho `"project hook ran in quick`"`nexit 3`n")
        $quick = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode quick -ProjectRoot $projectRoot
        }
        $quickOutput = $quick.Output -join "`n"
        Assert-Result -Name "quick exit code" -Condition ($quick.ExitCode -eq 0) -FailureMessage "expected quick mode to skip the hook, got $($quick.ExitCode). Output:`n$quickOutput"
        Assert-Result -Name "hook skipped in quick" -Condition ($quickOutput -notmatch "project hook ran in quick") -FailureMessage "the hook should not run in quick mode. Output:`n$quickOutput"
    }

    $results += Run-Test -Name "A hook run by Git for Windows' sh finds sed though Git's tool directories are not on PATH (item 176)" -Body {
        if (-not (Test-PlatformIsWindows)) { Skip-Test "Git for Windows' fallback sh exists only on Windows"; return }
        $gitRoot = Split-Path -Parent (Split-Path -Parent (Get-Command git -CommandType Application).Source)
        $toolDirs = @("usr/bin", "mingw64/bin", "bin") | ForEach-Object { (Join-Path $gitRoot $_).TrimEnd('\') }
        $strippedPath = (($env:PATH -split ';') | Where-Object { $_ -and ($toolDirs -notcontains $_.TrimEnd('\')) }) -join ';'
        $hookConfig | Set-Content -LiteralPath (Join-Path $projectRoot ".crucible/config.yaml") -Encoding UTF8
        [System.IO.File]::WriteAllText($worktreeHook, "#!/bin/sh`necho before | sed 's/before/sed ran/'`n")
        $savedPath = $env:PATH
        $env:PATH = $strippedPath
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode full -ProjectRoot $projectRoot
            }
        } finally {
            $env:PATH = $savedPath
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected the hook to find Git's sed, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "sed ran" -Condition ($output -match "sed ran") -FailureMessage "expected sed's output. Output:`n$output"
    }

    $results += Run-Test -Name "-Commit runs the configured checks for a task with no worktree and reports each exit code (item 173)" -Body {
        # gobot R-040's Researcher had no worktree to run the checks in, built its own runner,
        # and a quoted coverage command passed without running.
        $commitRoot = Join-Path $tempRoot "commit-project"
        Initialize-Repo -ProjectRoot $commitRoot
        @(
            "project: RunIsolatedChecksTest",
            "verification:",
            "  quick:",
            "    - name: writes-artifact",
            "      command: Set-Content -LiteralPath artifact.txt -Value x; $pwshCmd -NoProfile -Command exit 0",
            "  full:",
            "    - name: fails-with-3",
            "      command: $pwshCmd -NoProfile -Command exit 3"
        ) | Set-Content -LiteralPath (Join-Path $commitRoot ".crucible/config.yaml") -Encoding UTF8
        git -C $commitRoot add .crucible/config.yaml
        git -C $commitRoot commit -m "checks" --quiet
        $workspaces = Join-Path $commitRoot ".crucible/.agent-workspaces"

        $quick = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId R-001 -Mode quick -Commit HEAD -ProjectRoot $commitRoot }
        $quickOut = $quick.Output -join "`n"
        Assert-Result -Name "quick passes" -Condition ($quick.ExitCode -eq 0) -FailureMessage "expected 0, got $($quick.ExitCode). Output:`n$quickOut"
        Assert-Result -Name "quick ran its check" -Condition ($quickOut -match "==> writes-artifact" -and $quickOut -match "exit code: 0") -FailureMessage "expected the check and its exit code. Output:`n$quickOut"
        Assert-Result -Name "main checkout untouched" -Condition (-not (Test-Path -LiteralPath (Join-Path $commitRoot "artifact.txt"))) -FailureMessage "the check's artifact must land in the temporary worktree, not the main checkout"

        $full = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId R-001 -Mode full -Commit HEAD -ProjectRoot $commitRoot }
        $fullOut = $full.Output -join "`n"
        Assert-Result -Name "full fails" -Condition ($full.ExitCode -ne 0) -FailureMessage "a failing check must fail the run. Output:`n$fullOut"
        Assert-Result -Name "full names the check and its exit code" -Condition ($fullOut -match "Check failed: fails-with-3" -and $fullOut -match "exit code: 3") -FailureMessage "expected the failing check and exit 3. Output:`n$fullOut"

        $left = @(Get-ChildItem -LiteralPath $workspaces -Directory -Filter "checks-*" -ErrorAction SilentlyContinue)
        Assert-Result -Name "temporary worktrees removed" -Condition ($left.Count -eq 0) -FailureMessage ("left behind: " + (($left | ForEach-Object { $_.Name }) -join ", "))
        $worktrees = @(git -C $commitRoot worktree list | Where-Object { $_ })
        Assert-Result -Name "git forgets them" -Condition ($worktrees.Count -eq 1) -FailureMessage ("git worktree list: " + ($worktrees -join " | "))

        $bad = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId R-001 -Mode quick -Commit no-such-rev -ProjectRoot $commitRoot }
        Assert-Result -Name "unknown commit refused" -Condition ($bad.ExitCode -ne 0 -and (($bad.Output -join "`n") -match "does not name a commit")) -FailureMessage ("Output:`n" + ($bad.Output -join "`n"))

        $none = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId R-001 -Mode quick -ProjectRoot $commitRoot }
        Assert-Result -Name "no worktree points at -Commit" -Condition ($none.ExitCode -ne 0 -and (($none.Output -join "`n") -match "passes -Commit")) -FailureMessage ("Output:`n" + ($none.Output -join "`n"))
    }
    $results += Run-Test -Name "host-gated checks are NOT RUN with a reason and alternative runners execute (item 239)" -Body {
        $cfgPath = Join-Path $projectRoot ".crucible/config.yaml"
        @(
            "project: RunIsolatedChecksTest",
            "verification:",
            "  quick:",
            "    - name: unavailable check",
            "      command: $pwshCmd -NoProfile -Command exit 0",
            "      host_gate: env=CRUCIBLE_ITEM239_MISSING",
            "    - name: alternate check",
            "      command: $pwshCmd -NoProfile -Command exit 9",
            "      alternative_runner: $pwshCmd -NoProfile -Command exit 0",
            "      host_gate: env=CRUCIBLE_ITEM239_MISSING"
        ) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
        Remove-Item Env:\CRUCIBLE_ITEM239_MISSING -ErrorAction SilentlyContinue
        $res = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode quick -ProjectRoot $projectRoot }
        $out = $res.Output -join "`n"
        $record = Join-Path $projectRoot ".crucible/session/$taskId/verification/checks-not-run.txt"
        Assert-Result -Name "host-gated check does not pass silently" -Condition ($res.ExitCode -eq 0 -and $out -match 'NOT RUN: unavailable check - requires environment variable' -and $out -notmatch '==> unavailable check\r?\n\s+exit code: 0') -FailureMessage $out
        Assert-Result -Name "not-run reason is persisted" -Condition ((Get-Content -LiteralPath $record -Raw) -match 'unavailable check: requires environment variable') -FailureMessage (Get-Content -LiteralPath $record -Raw)
        Assert-Result -Name "alternative runner runs instead of configured host command" -Condition ($out -match 'alternative runner:' -and $out -match '==> alternate check' -and $out -match 'exit code: 0' -and $out -notmatch 'exit code: 9') -FailureMessage $out
    }
    $results += Run-Test -Name "Command ending in a double-quoted argument runs as written (item 241)" -Body {
        $cfgPath = Join-Path $projectRoot ".crucible/config.yaml"
        @(
            "project: RunIsolatedChecksTest",
            "verification:",
            "  quick:",
            "    - name: quoted argument",
            "      command: $pwshCmd -NoProfile -Command `"Write-Output 'command argument preserved'; exit 0`""
        ) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
        $res = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode quick -ProjectRoot $projectRoot }
        $out = $res.Output -join "`n"
        Assert-Result -Name "command runs with its complete argument" -Condition ($res.ExitCode -eq 0 -and $out -match 'command argument preserved' -and $out -match 'exit code: 0') -FailureMessage $out
    }
    $results += Run-Test -Name "Command starting and ending with separate quoted words runs as written (item 241)" -Body {
        $cfgPath = Join-Path $projectRoot ".crucible/config.yaml"
        @(
            "project: RunIsolatedChecksTest",
            "verification:",
            "  quick:",
            "    - name: quoted words",
            "      command: 'outer' | Out-Null; $pwshCmd -NoProfile -Command 'Write-Output ''outer quotes preserved''; exit 0'"
        ) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
        $res = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode quick -ProjectRoot $projectRoot }
        $out = $res.Output -join "`n"
        Assert-Result -Name "command keeps both quoted words" -Condition ($res.ExitCode -eq 0 -and $out -match 'outer quotes preserved' -and $out -match 'exit code: 0') -FailureMessage $out
    }
    $results += Run-Test -Name "Alternative runner ending in a double-quoted argument runs as written (item 241)" -Body {
        $cfgPath = Join-Path $projectRoot ".crucible/config.yaml"
        @(
            "project: RunIsolatedChecksTest",
            "verification:",
            "  quick:",
            "    - name: quoted alternative argument",
            "      command: $pwshCmd -NoProfile -Command exit 9",
            "      host_gate: env=CRUCIBLE_ITEM241_MISSING",
            "      alternative_runner: $pwshCmd -NoProfile -Command `"Write-Output 'alternative argument preserved'; exit 0`""
        ) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
        Remove-Item Env:\CRUCIBLE_ITEM241_MISSING -ErrorAction SilentlyContinue
        $res = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode quick -ProjectRoot $projectRoot }
        $out = $res.Output -join "`n"
        Assert-Result -Name "alternative runs with its complete argument" -Condition ($res.ExitCode -eq 0 -and $out -match 'alternative runner:' -and $out -match 'alternative argument preserved' -and $out -match 'exit code: 0' -and $out -notmatch 'exit code: 9') -FailureMessage $out
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
