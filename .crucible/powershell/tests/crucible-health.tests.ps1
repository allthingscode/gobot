$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$HEALTH_SCRIPT = Join-Path $REPO_ROOT "powershell/crucible-health.ps1"

$results = @()










function Write-HealthFixture {
    param([string]$ProjectRoot)
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot ".crucible/session/global/gate_decisions") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot ".crucible/backlog") -Force | Out-Null

    Push-Location $ProjectRoot
    try {
        git init -q
        git config user.name "Test User"
        git config user.email "test@example.com"
    } finally {
        Pop-Location
    }

    @(
        "project: CrucibleHealthTest",
        "paths:",
        "  backlog: .crucible/backlog",
        "  session: .crucible/session",
        "  workspaces: .crucible/.agent-workspaces",
        "  prompts: .crucible/prompts"
    ) | Set-Content -LiteralPath (Join-Path $ProjectRoot ".crucible/config.yaml") -Encoding UTF8

    @(
        "# Backlog",
        "",
        "| ID | Title | Category | Status | Specialist | Priority |",
        "| --- | --- | --- | --- | --- | --- |",
        "| F-001 | [Synthetic Task 1](features/active/F-001.md) | Feature | In Progress | architect | P1 |",
        "| F-002 | [Synthetic Task 2](features/active/F-002.md) | Feature | Resolved | architect | P1 |"
    ) | Set-Content -LiteralPath (Join-Path $ProjectRoot ".crucible/backlog/BACKLOG.md") -Encoding UTF8
}

$tempRoot = New-TestFixtureRoot -NameHint "crucible-health-test"
$projectRoot = Join-Path $tempRoot "project"

try {
    Write-HealthFixture -ProjectRoot $projectRoot

    # Create pending gate file for F-001 (active status: In Progress) -> Should NOT be cleaned up
    $pendingF1 = Join-Path $projectRoot ".crucible/session/global/gate_decisions/gate_decision_F-001_pending.json"
    "{}" | Set-Content -LiteralPath $pendingF1 -Encoding UTF8

    # Create pending gate file for F-002 (inactive status: Resolved) -> Should be cleaned up
    $pendingF2 = Join-Path $projectRoot ".crucible/session/global/gate_decisions/gate_decision_F-002_pending.json"
    "{}" | Set-Content -LiteralPath $pendingF2 -Encoding UTF8

    # Create pending gate file for F-003 (not in backlog) -> Should be cleaned up
    $pendingF3 = Join-Path $projectRoot ".crucible/session/global/gate_decisions/gate_decision_F-003_pending.json"
    "{}" | Set-Content -LiteralPath $pendingF3 -Encoding UTF8

    # Set up task session dirs for F-001 (active), F-002 (Resolved/inactive), F-003 (not in backlog)
    $sessionF1_arch = Join-Path $projectRoot ".crucible/session/F-001/architect"
    $sessionF1_impl = Join-Path $projectRoot ".crucible/session/F-001/implementation"
    $sessionF2_arch = Join-Path $projectRoot ".crucible/session/F-002/architect"
    $sessionF2_impl = Join-Path $projectRoot ".crucible/session/F-002/implementation"
    $sessionF3_arch = Join-Path $projectRoot ".crucible/session/F-003/architect"
    $sessionF3_impl = Join-Path $projectRoot ".crucible/session/F-003/implementation"

    New-Item -ItemType Directory -Path $sessionF1_arch -Force | Out-Null
    New-Item -ItemType Directory -Path $sessionF1_impl -Force | Out-Null
    New-Item -ItemType Directory -Path $sessionF2_arch -Force | Out-Null
    New-Item -ItemType Directory -Path $sessionF2_impl -Force | Out-Null
    New-Item -ItemType Directory -Path $sessionF3_arch -Force | Out-Null
    New-Item -ItemType Directory -Path $sessionF3_impl -Force | Out-Null

    "F-001 task content" | Set-Content -LiteralPath (Join-Path $sessionF1_arch "task.md") -Encoding UTF8
    "F-001 task content" | Set-Content -LiteralPath (Join-Path $sessionF1_impl "task.md") -Encoding UTF8
    "F-002 task content" | Set-Content -LiteralPath (Join-Path $sessionF2_arch "task.md") -Encoding UTF8
    "F-002 task content" | Set-Content -LiteralPath (Join-Path $sessionF2_impl "task.md") -Encoding UTF8
    "F-003 task content" | Set-Content -LiteralPath (Join-Path $sessionF3_arch "task.md") -Encoding UTF8
    "F-003 task content" | Set-Content -LiteralPath (Join-Path $sessionF3_impl "task.md") -Encoding UTF8

    $results += Run-Test -Name "Health identifies stale pending files and task dirs" -Body {
        Push-Location $projectRoot
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $HEALTH_SCRIPT -Health -ProjectRoot $projectRoot
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "orphaned count warning" -Condition ($output -match "Orphaned Pending Gate Files: 2") -FailureMessage "expected 2 orphaned files detected. Output:`n$output"
        Assert-Result -Name "stale scratchpad count" -Condition ($output -match "Stale Session Scratchpads: 4") -FailureMessage "expected 4 stale scratchpads detected. Output:`n$output"
    }

    $results += Run-Test -Name "Cleanup removes stale pending files and task dirs in a single pass" -Body {
        Push-Location $projectRoot
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $HEALTH_SCRIPT -Cleanup -Force -ProjectRoot $projectRoot
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "F-001 pending remains" -Condition (Test-Path $pendingF1) -FailureMessage "expected F-001 pending file to remain"
        Assert-Result -Name "F-001 session dir remains" -Condition (Test-Path (Join-Path $projectRoot ".crucible/session/F-001")) -FailureMessage "expected F-001 session dir to remain"
        Assert-Result -Name "F-002 pending removed" -Condition (-not (Test-Path $pendingF2)) -FailureMessage "expected F-002 pending file to be removed"
        Assert-Result -Name "F-002 session dir archived" -Condition (-not (Test-Path (Join-Path $projectRoot ".crucible/session/F-002"))) -FailureMessage "expected F-002 session dir to be archived/removed"
        Assert-Result -Name "F-003 pending removed" -Condition (-not (Test-Path $pendingF3)) -FailureMessage "expected F-003 pending file to be removed"
        Assert-Result -Name "F-003 session dir archived" -Condition (-not (Test-Path (Join-Path $projectRoot ".crucible/session/F-003"))) -FailureMessage "expected F-003 session dir to be archived/removed"
    }

    # Item 155: a worktree inherits the main checkout's relative hooksPath, resolved from
    # the worktree root. The legacy per-worktree architect override ran no hook at all.
    $results += Run-Test -Name "Health flags a worktree whose hooksPath holds no pre-commit" -Body {
        Push-Location $projectRoot
        try {
            git config core.longpaths true *> $null
            "seed" | Set-Content -LiteralPath (Join-Path $projectRoot "seed.txt") -Encoding UTF8
            New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible/scripts/hooks") -Force | Out-Null
            "#!/bin/sh`nexit 0`n" | Set-Content -LiteralPath (Join-Path $projectRoot ".crucible/scripts/hooks/pre-commit") -Encoding UTF8 -NoNewline
            git add seed.txt .crucible/scripts/hooks/pre-commit *> $null
            git commit -q -m "init" *> $null
            git config core.hooksPath ".crucible/scripts/hooks" *> $null
            $wtPath = Join-Path $projectRoot ".crucible/.agent-workspaces/implementation-F-009"
            git worktree add -q -b task/F-009 $wtPath *> $null

            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $HEALTH_SCRIPT -Health -ProjectRoot $projectRoot
            }
            $okOut = $res.Output -join "`n"
            Assert-Result -Name "inherited hooksPath not flagged" -Condition ($okOut -match "Misconfigured Implementation Worktrees \(hooksPath\): 0") -FailureMessage "a worktree inheriting a hooksPath with a pre-commit must not be flagged. Output:`n$okOut"

            $legacyDir = Join-Path $projectRoot "scripts/hooks/architect"
            New-Item -ItemType Directory -Path $legacyDir -Force | Out-Null
            git config extensions.worktreeConfig true *> $null
            git -C $wtPath config --worktree core.hooksPath $legacyDir *> $null
            $res2 = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $HEALTH_SCRIPT -Health -ProjectRoot $projectRoot
            }
            $badOut = $res2.Output -join "`n"
            Assert-Result -Name "legacy architect override flagged" -Condition ($badOut -match "Misconfigured Implementation Worktrees \(hooksPath\): 1") -FailureMessage "the legacy override runs no hook and must be flagged. Output:`n$badOut"
            Assert-Result -Name "names the fix" -Condition ($badOut -match "config --worktree --unset core\.hooksPath") -FailureMessage "expected the unset remediation. Output:`n$badOut"
        } finally {
            Pop-Location
        }
    }
} finally {
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
