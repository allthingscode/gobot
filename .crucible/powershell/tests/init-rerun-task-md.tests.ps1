# Item 137: re-running -Init on the handoff that created the current session must keep
# its task.md (and any checkpoints in it). A task.md left by an earlier handoff is still
# stale and must still be replaced.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$INIT_SCRIPT = Join-Path $REPO_ROOT "powershell/init-project.ps1"
$CRUCIBLE_SCRIPT = Join-Path $REPO_ROOT "powershell/crucible.ps1"

$results = @()

$tempRoot = New-TestFixtureRoot -NameHint "init-rerun"

function Invoke-FixtureInit {
    param([string]$ProjectRoot)
    Push-Location $ProjectRoot
    try {
        return Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CRUCIBLE_SCRIPT `
                -Init -ProjectRoot $ProjectRoot -TaskId "C-100"
        }
    } finally {
        Pop-Location
    }
}

try {
    $projectRoot = Join-Path $tempRoot "init-rerun-app"
    $taskFile = Join-Path $projectRoot ".crucible/session/C-100/grooming/task.md"

    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
    Push-Location $projectRoot
    try {
        git init --quiet
        git config user.name "Test User"
        git config user.email "test@example.com"
        Set-Content -Path "README.md" -Value "# Init Rerun App"
        git add README.md
        git commit -m "initial commit" --quiet
    } finally {
        Pop-Location
    }

    $initCmd = Invoke-ExternalCommand {
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $INIT_SCRIPT `
            -ProjectRoot $projectRoot -ProjectName "Init Rerun App" -Quiet
    }
    if ($initCmd.ExitCode -ne 0) { throw ("init-project failed: " + ($initCmd.Output -join "`n")) }

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
        session_cycle_id         = "init-rerun-cycle"
        cycle_id                 = "init-rerun-cycle"
        artifacts                = @(".crucible/research/C-100_findings.md")
        file_affinity            = @(".crucible/backlog/chores/active/C-100_Research.md")
        human_decisions          = [ordered]@{
            approved = @("Research Gate approved C-100 scope")
            deferred = @()
            rejected = @()
        }
    }
    $handoffName = "C-100-20260523T000000Z.json"
    $handoff | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $handoffDir $handoffName) -Encoding UTF8

    $results += Run-Test -Name "Rerun on the creating handoff keeps task.md checkpoints" -Body {
        $first = Invoke-FixtureInit -ProjectRoot $projectRoot
        Assert-Result -Name "first -Init exit" -Condition ($first.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $first.ExitCode + ". Output: " + ($first.Output -join "`n"))
        Assert-Result -Name "task.md created" -Condition (Test-Path -LiteralPath $taskFile) -FailureMessage "expected grooming/task.md after the first -Init"
        $created = Get-Content -LiteralPath $taskFile -Raw -Encoding UTF8
        Assert-Result -Name "task.md names its handoff" -Condition ($created.Contains($handoffName)) -FailureMessage ("task.md should name " + $handoffName + ". Content: " + $created)

        Add-Content -LiteralPath $taskFile -Value "`n### CHECKPOINT specialist-progress`nwork recorded by the specialist" -Encoding UTF8

        $second = Invoke-FixtureInit -ProjectRoot $projectRoot
        $secondOut = $second.Output -join "`n"
        Assert-Result -Name "rerun -Init exit" -Condition ($second.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $second.ExitCode + ". Output: " + $secondOut)
        $after = Get-Content -LiteralPath $taskFile -Raw -Encoding UTF8
        Assert-Result -Name "checkpoint survives the rerun" -Condition ($after.Contains("### CHECKPOINT specialist-progress")) -FailureMessage ("the rerun deleted the specialist's task.md. Content: " + $after)
        Assert-Result -Name "rerun reports keeping task.md" -Condition ($secondOut.Contains("Keeping task.md")) -FailureMessage ("expected a Keeping task.md line. Output: " + $secondOut)
        Assert-Result -Name "rerun does not report stale cleanup" -Condition (-not $secondOut.Contains("Removing stale task.md")) -FailureMessage ("the rerun treated its own task.md as stale. Output: " + $secondOut)
    }

    $results += Run-Test -Name "The Operator prompt and SOP do not ask for an -Init rerun at session start" -Body {
        foreach ($rel in @("prompts/deployment_prompt.md", "sops/deployment.md")) {
            $text = Get-Content -LiteralPath (Join-Path $REPO_ROOT $rel) -Raw -Encoding UTF8
            Assert-Result -Name "$rel drops the rerun step" -Condition (-not $text.Contains("already done if you are reading this")) -FailureMessage "$rel still tells the Operator to re-run -Init"
            Assert-Result -Name "$rel forbids the rerun" -Condition ($text.Contains("Do not re-run ``-Init`` at session start")) -FailureMessage "$rel should say not to re-run -Init at session start"
        }
    }

    $results += Run-Test -Name "A task.md from an earlier handoff is still replaced" -Body {
        $staleContent = "# Task: C-100`nPhase: grooming`nHandoff:      .crucible/session/handoffs/C-100-20260101T000000Z.json`n`n### CHECKPOINT earlier-cycle`n"
        Set-Content -LiteralPath $taskFile -Value $staleContent -Encoding UTF8

        $rerun = Invoke-FixtureInit -ProjectRoot $projectRoot
        $rerunOut = $rerun.Output -join "`n"
        Assert-Result -Name "-Init exit" -Condition ($rerun.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $rerun.ExitCode + ". Output: " + $rerunOut)
        $after = Get-Content -LiteralPath $taskFile -Raw -Encoding UTF8
        Assert-Result -Name "earlier-cycle checkpoint is gone" -Condition (-not $after.Contains("### CHECKPOINT earlier-cycle")) -FailureMessage ("a task.md from another handoff was kept. Content: " + $after)
        Assert-Result -Name "task.md recreated for the current handoff" -Condition ($after.Contains($handoffName)) -FailureMessage ("expected a fresh task.md naming " + $handoffName + ". Content: " + $after)
        Assert-Result -Name "stale cleanup reported" -Condition ($rerunOut.Contains("Removing stale task.md")) -FailureMessage ("expected a Removing stale task.md line. Output: " + $rerunOut)
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
