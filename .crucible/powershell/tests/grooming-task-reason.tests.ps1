# Regression test for scoped grooming phase init reason handling.
# A researcher->groomer handoff must keep its own reason even when another Ready item exists.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$INIT_SCRIPT = Join-Path $REPO_ROOT "powershell/init-project.ps1"
$FACTORY_SCRIPT = Join-Path $REPO_ROOT "powershell/factory.ps1"

$results = @()










$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-groomer-reason-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $projectRoot = Join-Path $tempRoot "groomer-reason-app"

    $results += Run-Test -Name "Grooming task.md keeps scoped handoff reason" -Body {
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        Push-Location $projectRoot
        try {
            git init --quiet
            git config user.name "Test User"
            git config user.email "test@example.com"
            Set-Content -Path "README.md" -Value "# Groomer Reason App"
            git add README.md
            git commit -m "initial commit" --quiet
        } finally {
            Pop-Location
        }

        $initCmd = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $INIT_SCRIPT `
                -ProjectRoot $projectRoot `
                -ProjectName "Groomer Reason App" `
                -Quiet
        }
        Assert-Result -Name "init-project exit" -Condition ($initCmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $initCmd.ExitCode + ". Output: " + ($initCmd.Output -join "`n"))

        $readySpecPath = Join-Path $projectRoot ".crucible/backlog/chores/active/C-200_Ready_Item.md"
        $readySpec = @"
---
item_id: C-200
title: Ready Item
status: Ready
priority: P1
target_phase: grooming
budget_tier: low
created_at: 2026-05-23
---

## Summary
Separate ready item that must not rewrite another task's handoff reason.
"@
        Set-Content -LiteralPath $readySpecPath -Value $readySpec -Encoding UTF8

        $backlogFile = Join-Path $projectRoot ".crucible/backlog/BACKLOG.md"
        $backlogContent = @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 1 | C-200 |
| **P2** | 0 | - |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| C-200 | P1 | Ready | Ready Item | Groomer |
"@
        Set-Content -LiteralPath $backlogFile -Value $backlogContent -Encoding UTF8

        $researchPath = Join-Path $projectRoot ".crucible/research/C-100_findings.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $researchPath) -Force | Out-Null
        Set-Content -LiteralPath $researchPath -Value "# Findings`n`nResearch completed for C-100." -Encoding UTF8

        $handoffDir = Join-Path $projectRoot ".crucible/session/handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $handoff = [ordered]@{
            task_id                  = "C-100"
            source_phase             = "research"
            target_phase             = "grooming"
            reason                   = "Research Gate approved C-100 scope"
            generated_by             = "new-handoff.ps1"
            tool_version             = "1.0.0"
            handoff_retry_count      = 0
            review_strike_count      = 0
            rebase_count             = 0
            budget_tier              = "low"
            cumulative_handoff_count = 1
            prompt_version           = "test-v1"
            suspicious_content       = ""
            session_cycle_id         = "reason-test-cycle"
            cycle_id                 = "reason-test-cycle"
            artifacts                = @(".crucible/research/C-100_findings.md")
            file_affinity            = @(".crucible/backlog/chores/active/C-100_Research.md")
            human_decisions          = [ordered]@{
                approved = @("Research Gate approved C-100 scope")
                deferred = @()
                rejected = @()
            }
        }
        $handoffPath = Join-Path $handoffDir "C-100-20260523T000000Z.json"
        $handoff | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $handoffPath -Encoding UTF8

        Push-Location $projectRoot
        try {
            $factoryCmd = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT `
                    -Init -TaskId "C-100" -Quiet
            }
        } finally {
            Pop-Location
        }
        Assert-Result -Name "factory -Init exit" -Condition ($factoryCmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $factoryCmd.ExitCode + ". Output: " + ($factoryCmd.Output -join "`n"))

        $taskFile = Join-Path $projectRoot ".crucible/session/C-100/grooming/task.md"
        Assert-Result -Name "grooming task.md exists" -Condition (Test-Path -LiteralPath $taskFile) -FailureMessage "expected grooming/task.md to exist"

        $taskContent = Get-Content -LiteralPath $taskFile -Raw -Encoding UTF8
        Assert-Result -Name "reason keeps research gate text" -Condition ($taskContent -match "Reason: Research Gate approved C-100 scope") -FailureMessage ("unexpected task.md content: " + $taskContent)
        Assert-Result -Name "reason excludes unrelated ready task" -Condition ($taskContent -notmatch "Target task: C-200") -FailureMessage ("task.md should not reference C-200. Content: " + $taskContent)
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
