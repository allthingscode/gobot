# Test for Git Hook Bypass Prevention circuit breaker.
# Git intentionally honors --no-verify by skipping local hooks, so Crucible enforces
# this at the factory boundary when a handoff reports or references a bypass attempt.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$FACTORY_SCRIPT = Join-Path $REPO_ROOT "powershell/factory.ps1"

$results = @()

function Assert-Result {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$FailureMessage
    )
    if (-not $Condition) {
        throw ("FAILED: " + $Name + " - " + $FailureMessage)
    }
}

function Run-Test {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    Write-Host ("`nTest: " + $Name) -ForegroundColor Cyan
    try {
        & $Body
        Write-Host "PASSED" -ForegroundColor Green
        return $true
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        return $false
    }
}

function Invoke-ExternalCommand {
    param([Parameter(Mandatory=$true)][scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Command 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [PSCustomObject]@{ Output = $output; ExitCode = $exitCode }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-hook-bypass-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $projectRoot = Join-Path $tempRoot "app"
    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

    $results += Run-Test -Name "Factory blocks handoff that reports --no-verify" -Body {
        Push-Location $projectRoot
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            Set-Content -Path "README.md" -Value "# Hook Bypass Test"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        $taskId = "C-HOOKBYPASS"
        $specDir = Join-Path $projectRoot ".crucible/backlog/chores/active"
        New-Item -ItemType Directory -Path $specDir -Force | Out-Null
        $specPath = Join-Path $specDir "${taskId}_HookBypassTest.md"
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

        $backlogPath = Join-Path $projectRoot ".crucible/backlog/BACKLOG.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $backlogPath) -Force | Out-Null
        "# Test Backlog`n| [$taskId](chores/active/${taskId}_HookBypassTest.md) | Title |" |
            Out-File -LiteralPath $backlogPath -Encoding UTF8

        $handoffDir = Join-Path $projectRoot ".crucible/session/handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $ts = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
        $handoffPath = Join-Path $handoffDir ("${taskId}-${ts}.json")
        $handoff = [ordered]@{
            task_id                  = $taskId
            source_phase             = "implementation"
            target_phase             = "verification"
            reason                   = "Implementation committed with git commit --no-verify after hook failure."
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
            file_affinity            = @("src/")
        }
        $handoff | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $handoffPath -Encoding UTF8

        $env:FACTORY_CYCLE_ID = "test-cycle"

        $res = Invoke-ExternalCommand {
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT `
                -Init -TaskId $taskId -ProjectRoot $projectRoot
        }
        $output = $res.Output -join "`n"
        $exitCode = $res.ExitCode

        Assert-Result -Name "Factory exits 2 (blocked)" -Condition ($exitCode -eq 2) `
            -FailureMessage ("expected exit 2, got $exitCode. Output:`n$output")

        $blockedDir = Join-Path $projectRoot ".crucible/backlog/blocked"
        Assert-Result -Name "Blocked dir created" -Condition (Test-Path $blockedDir) `
            -FailureMessage "blocked dir not found"

        $blockedFile = Get-ChildItem -Path $blockedDir -Filter "${taskId}-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        Assert-Result -Name "Blocked record written" -Condition ($null -ne $blockedFile) `
            -FailureMessage "no blocked record found in $blockedDir"

        $blockedJson = Get-Content -LiteralPath $blockedFile.FullName -Raw -Encoding UTF8
        Assert-Result -Name "Breaker is git_hook_bypass" `
            -Condition ($blockedJson -match '"circuit_breaker":\s*"git_hook_bypass"') `
            -FailureMessage "blocked record does not name 'git_hook_bypass'. Content:`n$blockedJson"
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
