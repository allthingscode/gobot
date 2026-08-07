$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$FACTORY_SCRIPT = Join-Path $REPO_ROOT "powershell/factory.ps1"

$results = @()










function Test-GitInitMainSupported {
    $versionText = git --version
    if ($versionText -notmatch '(\d+)\.(\d+)') { return $false }
    $major = [int]$matches[1]
    $minor = [int]$matches[2]
    return ($major -gt 2 -or ($major -eq 2 -and $minor -ge 28))
}

function Initialize-WorktreeProject {
    param([string]$ProjectRoot, [string[]]$TaskIds, [string]$Branch)
    New-Item -ItemType Directory -Path $ProjectRoot -Force | Out-Null
    Push-Location $ProjectRoot
    try {
        if ($Branch -eq "main") {
            git init -b main --quiet
        } else {
            git init --quiet
        }
        git config user.name "Test"
        git config user.email "test@example.com"
        git config commit.gpgSign false

        New-Item -ItemType Directory -Path ".crucible/backlog/chores/active" -Force | Out-Null
        New-Item -ItemType Directory -Path ".crucible/session/handoffs" -Force | Out-Null
        @(
            "project: WorktreeIsolationTest",
            "paths:",
            "  backlog: .crucible/backlog",
            "  session: .crucible/session",
            "  workspaces: .crucible/.agent-workspaces",
            "  prompts: .crucible/prompts"
        ) | Set-Content -LiteralPath ".crucible/config.yaml" -Encoding UTF8

        foreach ($taskId in $TaskIds) {
            $specPath = ".crucible/backlog/chores/active/${taskId}_Task.md"
            @(
                "---",
                "item_id: `"$taskId`"",
                "priority: `"P3`"",
                "status: `"Ready`"",
                "target_phase: `"grooming`"",
                "budget_tier: `"low`"",
                "file_affinity: [`"src/$taskId.txt`"]",
                "created_at: `"2026-05-25`"",
                "---",
                "# $taskId"
            ) | Set-Content -LiteralPath $specPath -Encoding UTF8
        }

        $p3Items = $TaskIds -join ", "
        $backlog = @(
            "# Backlog",
            "",
            "## Priority Summary",
            "| Priority | Count | Items |",
            "| --- | ---: | --- |",
            "| **P0** | 0 | - |",
            "| **P1** | 0 | - |",
            "| **P2** | 0 | - |",
            "| **P3** | $($TaskIds.Count) | $p3Items |",
            "",
            "## Active Items",
            "| ID | Title | Type | Priority | Status | Link |",
            "| --- | --- | --- | --- | --- | --- |"
        )
        foreach ($taskId in $TaskIds) {
            $backlog += "| $taskId | $taskId | Chore | P3 | Ready | [Spec](chores/active/${taskId}_Task.md) |"
        }
        $backlog | Set-Content -LiteralPath ".crucible/backlog/BACKLOG.md" -Encoding UTF8

        Set-Content -LiteralPath "README.md" -Value "# worktree isolation test" -Encoding UTF8
        git add README.md .crucible/config.yaml .crucible/backlog/BACKLOG.md
        foreach ($taskId in $TaskIds) {
            git add ".crucible/backlog/chores/active/${taskId}_Task.md"
        }
        git commit -m "init worktree fixture" --quiet
    } finally {
        Pop-Location
    }
}

function Write-GroomerHandoff {
    param([string]$ProjectRoot, [string]$TaskId)
    $handoffDir = Join-Path $ProjectRoot ".crucible/session/handoffs"
    New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    $handoffPath = Join-Path $handoffDir ("${TaskId}-${timestamp}.json")
    $handoff = [ordered]@{
        task_id                  = $TaskId
        source_phase             = "grooming"
        target_phase             = "implementation"
        reason                   = "Ready for isolated implementation"
        generated_by             = "new-handoff.ps1"
        tool_version             = "1.0.0"
        handoff_retry_count      = 0
        review_strike_count      = 0
        rebase_count             = 0
        budget_tier              = "low"
        cumulative_handoff_count = 2
        prompt_version           = "test-v1"
        session_cycle_id         = "test-cycle"
        cycle_id                 = "test-cycle"
        artifacts                = @(".crucible/backlog/chores/active/${TaskId}_Task.md")
        file_affinity            = @("src/$TaskId.txt")
    }
    $handoff | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $handoffPath -Encoding UTF8
    return $handoffPath
}

function Invoke-FactoryForArchitect {
    param([string]$ProjectRoot, [string]$TaskId)
    $env:FACTORY_CYCLE_ID = "test-cycle"
    return Invoke-ExternalCommand {
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT -Init -TaskId $TaskId -ProjectRoot $ProjectRoot -Quiet
    }
}

function Assert-FactorySuccess {
    param([object]$Result, [string]$Name)
    $output = $Result.Output -join "`n"
    Assert-Result -Name $Name -Condition ($Result.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($Result.ExitCode). Output:`n$output"
}

function Remove-WorktreeIfPresent {
    param([string]$ProjectRoot, [string]$WorktreePath)
    if (Test-Path -LiteralPath $WorktreePath) {
        git -C $ProjectRoot worktree remove --force $WorktreePath 2>$null
    }
    git -C $ProjectRoot worktree prune 2>$null
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-worktree-isolation-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$projectRoot = Join-Path $tempRoot "app"
$mainSupported = Test-GitInitMainSupported
$baseBranch = if ($mainSupported) { "main" } else { "master" }
$taskA = "C-WT-A"
$taskB = "C-WT-B"
$wtA = Join-Path $projectRoot ".crucible/.agent-workspaces/implementation-$taskA"
$wtB = Join-Path $projectRoot ".crucible/.agent-workspaces/implementation-$taskB"

try {
    if (-not $mainSupported) {
        Write-Host "WARNING: git init -b unavailable; main-default branch regression portion uses master." -ForegroundColor Yellow
    }

    Initialize-WorktreeProject -ProjectRoot $projectRoot -TaskIds @($taskA, $taskB) -Branch $baseBranch

    $results += Run-Test -Name "Two tasks create isolated worktrees" -Body {
        Write-GroomerHandoff -ProjectRoot $projectRoot -TaskId $taskA | Out-Null
        $resA = Invoke-FactoryForArchitect -ProjectRoot $projectRoot -TaskId $taskA
        Assert-FactorySuccess -Result $resA -Name "task A factory init"

        Write-GroomerHandoff -ProjectRoot $projectRoot -TaskId $taskB | Out-Null
        $resB = Invoke-FactoryForArchitect -ProjectRoot $projectRoot -TaskId $taskB
        Assert-FactorySuccess -Result $resB -Name "task B factory init"

        Assert-Result -Name "worktree A exists" -Condition (Test-Path $wtA) -FailureMessage "$wtA missing"
        Assert-Result -Name "worktree B exists" -Condition (Test-Path $wtB) -FailureMessage "$wtB missing"
        Assert-Result -Name "worktree A branch" -Condition ((git -C $wtA branch --show-current) -eq "task/$taskA") -FailureMessage "worktree A is on wrong branch"
        Assert-Result -Name "worktree B branch" -Condition ((git -C $wtB branch --show-current) -eq "task/$taskB") -FailureMessage "worktree B is on wrong branch"

        $baseHead = (git -C $projectRoot rev-parse $baseBranch).Trim()
        Assert-Result -Name "task A starts at base" -Condition (((git -C $wtA rev-parse HEAD).Trim()) -eq $baseHead) -FailureMessage "task A did not branch from $baseBranch"
        Assert-Result -Name "task B starts at base" -Condition (((git -C $wtB rev-parse HEAD).Trim()) -eq $baseHead) -FailureMessage "task B did not branch from $baseBranch"

        Set-Content -LiteralPath (Join-Path $wtA "task-A-marker.txt") -Value "A" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $wtB "task-B-marker.txt") -Value "B" -Encoding UTF8
        Assert-Result -Name "A marker isolated" -Condition ((Test-Path (Join-Path $wtA "task-A-marker.txt")) -and -not (Test-Path (Join-Path $wtA "task-B-marker.txt"))) -FailureMessage "task A marker isolation failed"
        Assert-Result -Name "B marker isolated" -Condition ((Test-Path (Join-Path $wtB "task-B-marker.txt")) -and -not (Test-Path (Join-Path $wtB "task-A-marker.txt"))) -FailureMessage "task B marker isolation failed"
    }

    $results += Run-Test -Name "Cleanup isolation leaves other worktree intact" -Body {
        Remove-WorktreeIfPresent -ProjectRoot $projectRoot -WorktreePath $wtA
        Assert-Result -Name "worktree A removed" -Condition (-not (Test-Path $wtA)) -FailureMessage "worktree A still exists"
        Assert-Result -Name "worktree B remains" -Condition (Test-Path $wtB) -FailureMessage "worktree B was removed"
        Assert-Result -Name "worktree B branch intact" -Condition ((git -C $wtB branch --show-current) -eq "task/$taskB") -FailureMessage "worktree B branch changed"
        Assert-Result -Name "worktree B marker intact" -Condition (Test-Path (Join-Path $wtB "task-B-marker.txt")) -FailureMessage "worktree B marker missing"
    }

    $results += Run-Test -Name "Same-ID re-init reuses existing worktree cleanly" -Body {
        Write-GroomerHandoff -ProjectRoot $projectRoot -TaskId $taskA | Out-Null
        $resFirst = Invoke-FactoryForArchitect -ProjectRoot $projectRoot -TaskId $taskA
        Assert-FactorySuccess -Result $resFirst -Name "task A recreate factory init"
        Assert-Result -Name "worktree A recreated" -Condition (Test-Path $wtA) -FailureMessage "worktree A was not recreated"

        Start-Sleep -Milliseconds 10
        Write-GroomerHandoff -ProjectRoot $projectRoot -TaskId $taskA | Out-Null
        $resSecond = Invoke-FactoryForArchitect -ProjectRoot $projectRoot -TaskId $taskA
        Assert-FactorySuccess -Result $resSecond -Name "task A same-ID factory init"
        Assert-Result -Name "same-ID worktree remains" -Condition (Test-Path $wtA) -FailureMessage "same-ID re-init did not leave a worktree"
        Assert-Result -Name "same-ID branch intact" -Condition ((git -C $wtA branch --show-current) -eq "task/$taskA") -FailureMessage "same-ID re-init changed branch"
    }

    $results += Run-Test -Name "Branch namespace remains per task" -Body {
        $branches = @(git -C $projectRoot branch --list "task/*" --format="%(refname:short)" | Sort-Object)
        $expected = @("task/$taskA", "task/$taskB") | Sort-Object
        Assert-Result -Name "branch count" -Condition ($branches.Count -eq $expected.Count) -FailureMessage "expected $($expected.Count) task branches, got $($branches.Count): $($branches -join ', ')"
        for ($i = 0; $i -lt $expected.Count; $i++) {
            Assert-Result -Name "branch $i" -Condition ($branches[$i] -eq $expected[$i]) -FailureMessage "expected $($expected[$i]), got $($branches[$i])"
        }
    }
} finally {
    Remove-Item env:FACTORY_CYCLE_ID -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $projectRoot) {
        Remove-WorktreeIfPresent -ProjectRoot $projectRoot -WorktreePath $wtA
        Remove-WorktreeIfPresent -ProjectRoot $projectRoot -WorktreePath $wtB
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
