# Test for Review Stalemate (runaway review loop) circuit breaker.
# Triggers by submitting a handoff with review_strike_count >= 3, targeting the Architect.
# Expects factory to trip the 3-strike stalemate breaker (exit 2) and write a blocked record.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$FACTORY_SCRIPT = Join-Path $REPO_ROOT "powershell/factory.ps1"

$results = @()










$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-runaway-loop-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $projectRoot = Join-Path $tempRoot "app"
    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

    # -- Test: 3-strike stalemate trips ----------------------------------------
    $results += Run-Test -Name "Review stalemate trips at 3 strikes (runaway loop)" -Body {
        # 1. Git repo + initial commit
        Push-Location $projectRoot
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            Set-Content -Path "README.md" -Value "# Temp"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        # 2. Minimal backlog spec
        $taskId  = "C-RUNAWAY"
        $specDir = Join-Path $projectRoot ".crucible/backlog/chores/active"
        New-Item -ItemType Directory -Path $specDir -Force | Out-Null
        $specPath = Join-Path $specDir "${taskId}_RunawayTest.md"
        $specContent = @"
---
item_id: "$taskId"
priority: "P3"
status: "Ready"
specialist: "Groomer"
budget_tier: "low"
file_affinity: ["src/"]
created_at: "2026-05-25"
---
# Spec
"@
        [System.IO.File]::WriteAllText($specPath, $specContent)

        # Ensure BACKLOG.md entry
        $backlogPath = Join-Path $projectRoot ".crucible/backlog/BACKLOG.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $backlogPath) -Force | Out-Null
        if (-not (Test-Path $backlogPath)) {
            "# Test Backlog" | Out-File -LiteralPath $backlogPath -Encoding UTF8
        }
        [System.IO.File]::AppendAllText($backlogPath, "`n| [$taskId](chores/active/${taskId}_RunawayTest.md) | Title |")

        # 3. Handoff: reviewer -> architect with review_strike_count = 3 (stalemate threshold)
        $handoffDir = Join-Path $projectRoot ".crucible/session/handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $ts = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
        $handoffPath = Join-Path $handoffDir ("${taskId}-${ts}.json")
        $handoff = [ordered]@{
            task_id                  = $taskId
            source_phase             = "verification"
            target_phase             = "implementation"
            reason                   = "CHANGES_REQUESTED - third rejection"
            generated_by             = "new-handoff.ps1"
            tool_version             = "1.0.0"
            handoff_retry_count      = 0
            review_strike_count      = 3         # at threshold -> stalemate fires
            rebase_count             = 0
            budget_tier              = "low"
            cumulative_handoff_count = 4
            prompt_version           = "test-v1"
            session_cycle_id         = "test-cycle"
            cycle_id                 = "test-cycle"
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
        Assert-Result -Name "Breaker is review_stalemate" `
            -Condition ($blockedJson -match '"circuit_breaker":\s*"review_stalemate"') `
            -FailureMessage "blocked record does not name 'review_stalemate'. Content:`n$blockedJson"
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
