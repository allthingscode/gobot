# Test for Scope Boundary Violation circuit breaker.
#
# This test modifies a file outside the spec file_affinity and asserts factory blocks
# the handoff before it can proceed to Reviewer.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$FACTORY_SCRIPT = Join-Path $REPO_ROOT "powershell/factory.ps1"
$INIT_SCRIPT    = Join-Path $REPO_ROOT "powershell/init-project.ps1"

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
        $null = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $INIT_SCRIPT `
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
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT `
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
