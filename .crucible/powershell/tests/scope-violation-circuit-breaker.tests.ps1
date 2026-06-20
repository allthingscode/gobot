# Test for Scope Boundary Violation circuit breaker.
#
# This test modifies a file outside the spec file_affinity and asserts factory blocks
# the handoff before it can proceed to Reviewer.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$FACTORY_SCRIPT = Join-Path $REPO_ROOT "powershell/factory.ps1"
$INIT_SCRIPT    = Join-Path $REPO_ROOT "powershell/init-project.ps1"

$results = @()










$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-scope-violation-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $projectRoot = Join-Path $tempRoot "app"
    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

    $results += Run-Test -Name "Scope violation rejected by factory" -Body {
        # 1. Git repo
        Push-Location $projectRoot
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            New-Item -ItemType Directory -Path "src" -Force | Out-Null
            Set-Content -Path "README.md"  -Value "# Scope Test"
            Set-Content -Path "src/a.txt"  -Value "in-scope file"
            git add .
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        # 2. Initialize Crucible
        $null = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $INIT_SCRIPT `
            -ProjectRoot $projectRoot -ProjectName "ScopeApp" -DefaultBranch "master" `
            -Language python -Quiet 2>&1

        # 3. Spec declares only src/a.txt as in-scope
        $taskId  = "C-SCOPE"
        $specDir = Join-Path $projectRoot ".crucible/backlog/chores/active"
        New-Item -ItemType Directory -Path $specDir -Force | Out-Null
        $specPath = Join-Path $specDir "${taskId}_ScopeTest.md"

        $specLines = @(
            "---",
            "item_id: `"$taskId`"",
            "priority: `"P3`"",
            "status: `"Ready`"",
            "specialist: `"Groomer`"",
            "budget_tier: `"low`"",
            "file_affinity: [`"src/a.txt`"]",
            "created_at: `"2026-05-25`"",
            "---",
            "# Spec"
        )
        [System.IO.File]::WriteAllLines($specPath, $specLines)

        $backlogPath = Join-Path $projectRoot ".crucible/backlog/BACKLOG.md"
        [System.IO.File]::AppendAllText($backlogPath, ("`n| [$taskId](chores/active/${taskId}_ScopeTest.md) | Title |"))

        # 4. Create architect worktree; touch ONLY the out-of-scope file src/b.txt
        Push-Location $projectRoot
        try {
            git branch "task/$taskId" master
            git worktree add ".crucible/.agent-workspaces/implementation-$taskId" "task/$taskId" --quiet
        } finally {
            Pop-Location
        }

        $wtPath = Join-Path $projectRoot ".crucible/.agent-workspaces/implementation-$taskId"
        Set-Content -Path (Join-Path $wtPath "src/b.txt") -Value "out-of-scope change"
        Push-Location $wtPath
        try {
            git add "src/b.txt"
            git commit -m "feat: out-of-scope edit" --quiet
        } finally {
            Pop-Location
        }

        # 5. Handoff: architect -> reviewer (spec only declares src/a.txt)
        $handoffDir = Join-Path $projectRoot ".crucible/session/handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $ts = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
        $handoffPath = Join-Path $handoffDir ("${taskId}-${ts}.json")
        $handoff = [ordered]@{
            task_id                  = $taskId
            source_phase             = "implementation"
            target_phase             = "verification"
            reason                   = "Implementation complete"
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
            artifacts                = @($specPath)
            file_affinity            = @("src/a.txt")   # b.txt not declared
        }
        $handoff | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $handoffPath -Encoding UTF8

        $env:FACTORY_CYCLE_ID = "test-cycle"

        # 6. Run factory; expect exit 2 (block) because src/b.txt is out-of-scope
        $res = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT `
                -Init -TaskId $taskId -ProjectRoot $projectRoot
        }
        $output   = $res.Output -join "`n"
        $exitCode = $res.ExitCode

        Assert-Result -Name "Factory blocks out-of-scope handoff" `
            -Condition ($exitCode -eq 2) `
            -FailureMessage ("expected exit 2 (scope violation block), got $exitCode. " +
                "Output:`n$output")

        $blockedDir = Join-Path $projectRoot ".crucible/backlog/blocked"
        Assert-Result -Name "Blocked dir created" -Condition (Test-Path $blockedDir) `
            -FailureMessage "blocked dir not found"

        $blockedFile = Get-ChildItem -Path $blockedDir -Filter "${taskId}-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        Assert-Result -Name "Blocked record written" -Condition ($null -ne $blockedFile) `
            -FailureMessage "no blocked record found in $blockedDir"

        $blockedJson = Get-Content -LiteralPath $blockedFile.FullName -Raw -Encoding UTF8
        Assert-Result -Name "Breaker is scope_violation" `
            -Condition ($blockedJson -match '"circuit_breaker":\s*"scope_violation"') `
            -FailureMessage "blocked record does not name 'scope_violation'. Content:`n$blockedJson"
    }

    $results += Run-Test -Name "Scope check skipped and advisory logged when file_affinity is empty" -Body {
        # 1. Setup new project root
        $projectRoot2 = Join-Path $tempRoot "app2"
        New-Item -ItemType Directory -Path $projectRoot2 -Force | Out-Null

        Push-Location $projectRoot2
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            New-Item -ItemType Directory -Path "src" -Force | Out-Null
            Set-Content -Path "README.md"  -Value "# Scope Test 2"
            Set-Content -Path "src/a.txt"  -Value "in-scope file"
            git add .
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        # 2. Initialize Crucible
        $null = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $INIT_SCRIPT `
            -ProjectRoot $projectRoot2 -ProjectName "ScopeApp2" -DefaultBranch "master" `
            -Language python -Quiet 2>&1

        # 3. Spec has empty file_affinity
        $taskId2  = "C-SCOPE-EMPTY"
        $specDir2 = Join-Path $projectRoot2 ".crucible/backlog/chores/active"
        New-Item -ItemType Directory -Path $specDir2 -Force | Out-Null
        $specPath2 = Join-Path $specDir2 "${taskId2}_ScopeTest.md"

        $specLines2 = @(
            "---",
            "item_id: `"$taskId2`"",
            "priority: `"P3`"",
            "status: `"Ready`"",
            "specialist: `"Groomer`"",
            "budget_tier: `"low`"",
            "file_affinity: []",
            "created_at: `"2026-05-25`"",
            "---",
            "# Spec"
        )
        [System.IO.File]::WriteAllLines($specPath2, $specLines2)

        $backlogPath2 = Join-Path $projectRoot2 ".crucible/backlog/BACKLOG.md"
        [System.IO.File]::AppendAllText($backlogPath2, ("`n| [$taskId2](chores/active/${taskId2}_ScopeTest.md) | Title |"))

        # 4. Create architect worktree; touch some files
        Push-Location $projectRoot2
        try {
            git branch "task/$taskId2" master
            git worktree add ".crucible/.agent-workspaces/implementation-$taskId2" "task/$taskId2" --quiet
        } finally {
            Pop-Location
        }

        $wtPath2 = Join-Path $projectRoot2 ".crucible/.agent-workspaces/implementation-$taskId2"
        Set-Content -Path (Join-Path $wtPath2 "src/b.txt") -Value "out-of-scope change"
        Push-Location $wtPath2
        try {
            git add "src/b.txt"
            git commit -m "feat: out-of-scope edit" --quiet
        } finally {
            Pop-Location
        }

        # 5. Handoff: architect -> reviewer (empty file_affinity)
        $handoffDir2 = Join-Path $projectRoot2 ".crucible/session/handoffs"
        New-Item -ItemType Directory -Path $handoffDir2 -Force | Out-Null
        $ts2 = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
        $handoffPath2 = Join-Path $handoffDir2 ("${taskId2}-${ts2}.json")
        $handoff2 = [ordered]@{
            task_id                  = $taskId2
            source_phase             = "implementation"
            target_phase             = "verification"
            reason                   = "Implementation complete"
            generated_by             = "new-handoff.ps1"
            tool_version             = "1.0.0"
            handoff_retry_count      = 0
            review_strike_count      = 0
            rebase_count             = 0
            budget_tier              = "low"
            cumulative_handoff_count = 2
            prompt_version           = "test-v1"
            session_cycle_id         = "test-cycle2"
            cycle_id                 = "test-cycle2"
            artifacts                = @($specPath2)
            file_affinity            = @()   # empty
        }
        $handoff2 | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $handoffPath2 -Encoding UTF8

        $env:FACTORY_CYCLE_ID = "test-cycle2"

        # 6. Run factory; expect exit 0 because empty affinity skips scope checks with an advisory
        $res = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT `
                -Init -TaskId $taskId2 -ProjectRoot $projectRoot2
        }
        $output   = $res.Output -join "`n"
        $exitCode = $res.ExitCode

        Assert-Result -Name "Factory succeeds on empty file_affinity" `
            -Condition ($exitCode -eq 0) `
            -FailureMessage ("expected exit 0 (skipped scope check), got $exitCode. Output:`n$output")

        Assert-Result -Name "Advisory logged for empty file_affinity" `
            -Condition ($output -match "\[ADVISORY\] No file_affinity declared") `
            -FailureMessage "Expected advisory in output, got: $output"
    }
} finally {
    Remove-Item env:FACTORY_CYCLE_ID -ErrorAction SilentlyContinue
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
