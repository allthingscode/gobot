# Test for Token Budget Exceeded circuit breaker.
# Supplies a handoff with budget_tier="low" (ceiling=10) and cumulative_handoff_count=11,
# which exceeds the ceiling.  Expects factory to write a "budget_exceeded" blocked record
# and exit with code 2.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$FACTORY_SCRIPT = Join-Path $REPO_ROOT "powershell/factory.ps1"

$results = @()










$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-budget-overrun-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $projectRoot = Join-Path $tempRoot "app"
    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

    $results += Run-Test -Name "Budget overrun trips at low-tier ceiling (10)" -Body {
        # 1. Git repo + initial commit
        Push-Location $projectRoot
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            Set-Content -Path "README.md" -Value "# Budget Test"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        # 2. Backlog spec with budget_tier = "low" (ceiling = 10 handoffs)
        $taskId  = "C-BUDGET"
        $specDir = Join-Path $projectRoot ".crucible/backlog/chores/active"
        New-Item -ItemType Directory -Path $specDir -Force | Out-Null
        $specPath = Join-Path $specDir "${taskId}_BudgetTest.md"
        $specContent = @"
---
item_id: "$taskId"
priority: "P3"
status: "Ready"
target_phase: "grooming"
budget_tier: "low"
file_affinity: ["src/"]
created_at: "2026-05-25"
---
# Spec
"@
        [System.IO.File]::WriteAllText($specPath, $specContent)

        $backlogPath = Join-Path $projectRoot ".crucible/backlog/BACKLOG.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $backlogPath) -Force | Out-Null
        if (-not (Test-Path $backlogPath)) {
            "# Test Backlog" | Out-File -LiteralPath $backlogPath -Encoding UTF8
        }
        [System.IO.File]::AppendAllText($backlogPath, "`n| [$taskId](chores/active/${taskId}_BudgetTest.md) | Title |")

        # 3. Handoff with cumulative_handoff_count = 11 (> ceiling of 10 for "low")
        $handoffDir = Join-Path $projectRoot ".crucible/session/handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $ts = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
        $handoffPath = Join-Path $handoffDir ("${taskId}-${ts}.json")
        $handoff = [ordered]@{
            task_id                  = $taskId
            source_phase             = "grooming"
            target_phase             = "implementation"
            reason                   = "Implement"
            handoff_retry_count      = 0
            review_strike_count      = 0
            rebase_count             = 0
            budget_tier              = "low"          # ceiling = 10
            cumulative_handoff_count = 11             # exceeds ceiling -> breaker fires
            prompt_version           = "test-v1"
            session_cycle_id         = "test-cycle"
            cycle_id                 = "test-cycle"
            generated_by             = "new-handoff.ps1"
            tool_version             = "1.0.0"
            artifacts                = @($specPath)
            file_affinity            = @("src/")
        }
        $handoff | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $handoffPath -Encoding UTF8

        $env:FACTORY_CYCLE_ID = "test-cycle"

        # 4. Run factory
        $res = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT `
                -Init -TaskId $taskId -ProjectRoot $projectRoot
        }
        $output   = $res.Output -join "`n"
        $exitCode = $res.ExitCode

        # 5. Assertions
        Assert-Result -Name "Factory exits 2 (blocked)" -Condition ($exitCode -eq 2) `
            -FailureMessage ("expected exit 2, got $exitCode. Output:`n$output")

        $blockedDir  = Join-Path $projectRoot ".crucible/backlog/blocked"
        Assert-Result -Name "Blocked dir created" -Condition (Test-Path $blockedDir) `
            -FailureMessage "blocked dir not found"

        $blockedFile = Get-ChildItem -Path $blockedDir -Filter "${taskId}-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        Assert-Result -Name "Blocked record written" -Condition ($null -ne $blockedFile) `
            -FailureMessage "no blocked record found in $blockedDir"

        $blockedJson = Get-Content -LiteralPath $blockedFile.FullName -Raw -Encoding UTF8
        Assert-Result -Name "Breaker is budget_exceeded" `
            -Condition ($blockedJson -match '"circuit_breaker":\s*"budget_exceeded"') `
            -FailureMessage "blocked record does not name 'budget_exceeded'. Content:`n$blockedJson"
    }

    function Invoke-BudgetScenario {
        param([string]$TaskId, [int]$RebaseCount, [int]$CumulativeCount)
        $specDir = Join-Path $projectRoot ".crucible/backlog/chores/active"
        New-Item -ItemType Directory -Path $specDir -Force | Out-Null
        $specPath = Join-Path $specDir "${TaskId}_BudgetTest.md"
        $specContent = @"
---
item_id: "$TaskId"
priority: "P3"
status: "Ready"
target_phase: "grooming"
budget_tier: "low"
file_affinity: ["src/"]
created_at: "2026-05-25"
---
# Spec
"@
        [System.IO.File]::WriteAllText($specPath, $specContent)
        $backlogPath = Join-Path $projectRoot ".crucible/backlog/BACKLOG.md"
        [System.IO.File]::AppendAllText($backlogPath, "`n| [$TaskId](chores/active/${TaskId}_BudgetTest.md) | Title |")

        $handoffDir = Join-Path $projectRoot ".crucible/session/handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $ts = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
        $handoffPath = Join-Path $handoffDir ("${TaskId}-${ts}.json")
        $handoff = [ordered]@{
            task_id                  = $TaskId
            source_phase             = "grooming"
            target_phase             = "implementation"
            reason                   = "Implement"
            handoff_retry_count      = 0
            review_strike_count      = 0
            rebase_count             = $RebaseCount
            budget_tier              = "low"
            cumulative_handoff_count = $CumulativeCount
            prompt_version           = "test-v1"
            session_cycle_id         = "test-cycle"
            cycle_id                 = "test-cycle"
            generated_by             = "new-handoff.ps1"
            tool_version             = "1.0.0"
            artifacts                = @($specPath)
            file_affinity            = @("src/")
        }
        $handoff | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $handoffPath -Encoding UTF8
        $env:FACTORY_CYCLE_ID = "test-cycle"
        $res = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT `
                -Init -TaskId $TaskId -ProjectRoot $projectRoot
        }
        return $res
    }

    $results += Run-Test -Name "Rebase headroom: cum 11 with rebase_count 1 does NOT trip (effective ceiling 15)" -Body {
        $res = Invoke-BudgetScenario -TaskId "C-BUDGET-RB" -RebaseCount 1 -CumulativeCount 11
        $output = $res.Output -join "`n"
        Assert-Result -Name "No budget breaker in output" `
            -Condition ($output -notmatch "Token Budget Exceeded") `
            -FailureMessage ("budget breaker fired despite rebase headroom. Output:`n$output")
        $blockedDir = Join-Path $projectRoot ".crucible/backlog/blocked"
        $rb = @(Get-ChildItem -Path $blockedDir -Filter "C-BUDGET-RB-*.json" -ErrorAction SilentlyContinue)
        Assert-Result -Name "No budget_exceeded record written" `
            -Condition ($rb.Count -eq 0 -or -not ((Get-Content $rb[0].FullName -Raw) -match "budget_exceeded")) `
            -FailureMessage "a budget_exceeded record was written despite rebase headroom"
    }

    $results += Run-Test -Name "Rebase headroom is bounded: cum 16 with rebase_count 1 still trips (effective ceiling 15)" -Body {
        $res = Invoke-BudgetScenario -TaskId "C-BUDGET-RB2" -RebaseCount 1 -CumulativeCount 16
        $output = $res.Output -join "`n"
        Assert-Result -Name "Factory exits 2 (blocked)" -Condition ($res.ExitCode -eq 2) `
            -FailureMessage ("expected exit 2 for cum 16 over effective ceiling 15, got $($res.ExitCode). Output:`n$output")
        Assert-Result -Name "Budget breaker fired" -Condition ($output -match "Token Budget Exceeded") `
            -FailureMessage ("expected budget breaker. Output:`n$output")
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
