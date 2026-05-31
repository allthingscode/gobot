# Test for Reviewer Verification Failure (fabricated test result rejected) circuit breaker.
$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$FACTORY_SCRIPT = Join-Path $REPO_ROOT "powershell/factory.ps1"
$INIT_SCRIPT = Join-Path $REPO_ROOT "powershell/init-project.ps1"

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
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$Command
    )
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Command 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [PSCustomObject]@{ Output = $output; ExitCode = $exitCode }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-fabricated-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $projectRoot = Join-Path $tempRoot "app"
    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

    $results += Run-Test -Name "Fabricated test result trips verification failure breaker" -Body {
        # 1. Initialize git repo
        Push-Location $projectRoot
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            Set-Content -Path "README.md" -Value "# Temp Repo"
            git add README.md
            git commit -m "initial commit" --quiet
        } finally {
            Pop-Location
        }

        # 2. Initialize Crucible project
        $null = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $INIT_SCRIPT `
            -ProjectRoot $projectRoot `
            -ProjectName "Fabricated Test App" `
            -DefaultBranch "master" `
            -Language python `
            -Quiet 2>&1

        # 3. Configure failing verification check (using cmd.exe /c exit 1 to avoid quotes)
        $configPath = Join-Path $projectRoot ".crucible/config.yaml"
        $configContent = @"
project_name: "Fabricated Test App"
description: "Failing verify"
default_branch: "master"
crucible_version: "0.1.0"
crucible_install_commit: "abcdef"
verification:
  quick:
    - name: Failing Test
      command: cmd.exe /c exit 1
  full:
    - name: Failing Test Full
      command: cmd.exe /c exit 1
"@
        [System.IO.File]::WriteAllText($configPath, $configContent)

        # 4. Set up task spec file
        $specPath = Join-Path $projectRoot ".crucible/backlog/chores/active/C-FABRICATED_FactoryTest.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $specPath) -Force | Out-Null
        $specContent = @"
---
item_id: "C-FABRICATED"
priority: "P3"
status: "Ready"
target_phase: "grooming"
budget_tier: "low"
file_affinity: ["src/"]
created_at: "2026-05-08"
---
# Spec
"@
        [System.IO.File]::WriteAllText($specPath, $specContent)

        # Ensure BACKLOG.md is updated
        $backlogPath = Join-Path $projectRoot ".crucible/backlog/BACKLOG.md"
        $backlogLine = "| [C-FABRICATED](chores/active/C-FABRICATED_FactoryTest.md) | Test Title |"
        [System.IO.File]::AppendAllText($backlogPath, "`n" + $backlogLine)

        # 5. Create Architect worktree on branch task/C-FABRICATED
        Push-Location $projectRoot
        try {
            git branch task/C-FABRICATED master
            git worktree add .crucible/.agent-workspaces/implementation-C-FABRICATED task/C-FABRICATED --quiet
        } finally {
            Pop-Location
        }

        # 6. Write Reviewer APPROVED report
        $reportDir = Join-Path $projectRoot ".crucible/session/C-FABRICATED/verification"
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
        $reportContent = @"
---
review_decision: APPROVED
acceptance_criteria_met: true
---
APPROVED
"@
        [System.IO.File]::WriteAllText((Join-Path $reportDir "review_report.md"), $reportContent)

        # 7. Write Reviewer->Operator handoff JSON (Reviewer APPROVED)
        $handoffDir = Join-Path $projectRoot ".crucible/session/handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
        $handoffPath = Join-Path $handoffDir ("C-FABRICATED-" + $timestamp + ".json")
        $handoffData = [ordered]@{
            task_id                  = "C-FABRICATED"
            source_phase             = "verification"
            target_phase             = "deployment"
            reason                   = "APPROVED"
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
            reviewer_checks_passed   = @("tests_pass", "vet_pass", "acceptance_criteria_met", "scope_bounded", "no_regressions", "no_hard_mandates_violated")
        }
        $handoffJson = $handoffData | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($handoffPath, $handoffJson)

        # Set env FACTORY_CYCLE_ID to match session_cycle_id / cycle_id
        $env:FACTORY_CYCLE_ID = "test-cycle"

        # 8. Run factory safely using Invoke-ExternalCommand helper
        $res = Invoke-ExternalCommand {
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT `
                -Init -TaskId "C-FABRICATED" -ProjectRoot $projectRoot
        }
        $output = $res.Output -join "`n"
        $exitCode = $res.ExitCode

        # 9. Assertions
        Assert-Result -Name "Factory exits with block code 2" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit code 2, got " + $exitCode + ". Output: " + $output)
        
        # Verify event log or block record
        $blockedDir = Join-Path $projectRoot ".crucible/backlog/blocked"
        Assert-Result -Name "Blocked folder exists" -Condition (Test-Path $blockedDir) -FailureMessage "expected blocked folder to exist"
        
        $blockedFile = Get-ChildItem -Path $blockedDir -Filter "C-FABRICATED-*.json" | Select-Object -First 1
        Assert-Result -Name "Blocked record created" -Condition ($null -ne $blockedFile) -FailureMessage "blocked task record not found"
        
        $blockedContent = Get-Content -LiteralPath $blockedFile.FullName -Raw -Encoding UTF8
        Assert-Result -Name "Blocked content matches cb type" -Condition ($blockedContent -match '"circuit_breaker":\s*"reviewer_verification_failed"') -FailureMessage ("unexpected blocked record content: " + $blockedContent)
    }
} finally {
    # Clean up env variable
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
