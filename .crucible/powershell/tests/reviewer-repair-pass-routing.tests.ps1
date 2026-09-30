# Tests that a Reviewer repair pass can send an approved task back to implementation.
#
# Gobot B-016's Reviewer approved and wrote a verification -> deployment handoff. The
# orchestrator found an unmet criterion, and on the human's go re-dispatched the Reviewer,
# which wrote a newer verification -> implementation handoff. Crucible must take the newer
# handoff and route to implementation, with no gate decision behind it. Item 147.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$Quiet = $true
. (Join-Path $REPO_ROOT "powershell/crucible-lib.ps1")

$results = @()

function Write-TestHandoff {
    param([string]$Path, [hashtable]$Values)
    $Values.generated_by = "new-handoff.ps1"
    $Values.tool_version = "1.0.0"
    $Values | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$tempRoot = New-TestFixtureRoot -NameHint "reviewer-repair-pass-routing-test"
try {
    $results += Run-Test -Name "A later verification -> implementation handoff supersedes an approval" -Body {
        $taskId = "B-016"
        $sessionDir = Join-Path $tempRoot "session"
        $handoffDir = Join-Path $sessionDir "handoffs"
        $backlogDir = Join-Path $tempRoot "backlog"
        New-Item -ItemType Directory -Path $handoffDir, $backlogDir -Force | Out-Null

        $common = @{
            task_id = $taskId
            source_phase = "verification"
            budget_tier = "medium"
            handoff_retry_count = 0
            rebase_count = 0
            artifacts = @()
            file_affinity = @()
            session_cycle_id = "cycle-b016"
        }
        $approval = $common.Clone()
        $approval.target_phase = "deployment"
        $approval.cumulative_handoff_count = 3
        $approval.review_strike_count = 0
        $approval.reason = "Review approved - no blockers"
        Write-TestHandoff -Path (Join-Path $handoffDir "$taskId-20260930T140000Z.json") -Values $approval

        $repair = $common.Clone()
        $repair.target_phase = "implementation"
        $repair.cumulative_handoff_count = 4
        $repair.review_strike_count = 1
        $repair.reason = "Changes requested"
        $repairPath = Join-Path $handoffDir "$taskId-20260930T150000Z.json"
        Write-TestHandoff -Path $repairPath -Values $repair

        $ctx = @{
            TaskId = $taskId
            HandoffDir = $handoffDir
            BacklogDir = $backlogDir
            SessionDir = $sessionDir
            Quiet = $true
            LogFile = Join-Path $sessionDir "$taskId/pipeline.log.jsonl"
            CircuitBreakerHistoryFile = Join-Path $sessionDir "global/circuit_breakers.jsonl"
            IsBootstrap = $false
            LatestHandoff = $null
            Handoff = $null
        }
        Resolve-CrucibleInputHandoff -Context $ctx

        Assert-Result -Name "repair handoff is the input" -Condition ($null -ne $ctx.LatestHandoff -and $ctx.LatestHandoff.FullName -eq $repairPath) -FailureMessage ("Crucible resolved " + $ctx.LatestHandoff + " instead of the newer repair handoff")
        $handoff = Get-Content -LiteralPath $ctx.LatestHandoff.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Result -Name "routes to implementation" -Condition ($handoff.target_phase -eq "implementation") -FailureMessage ("resolved handoff targets " + $handoff.target_phase)

        $isRework = Test-DeploymentReworkReentry -Handoff $handoff -SessionDir $sessionDir
        $valid = Get-PipelineValidTransitions -DeploymentRework $isRework
        Assert-Result -Name "transition allowed without a gate" -Condition ($valid["verification"] -contains "implementation") -FailureMessage "verification -> implementation is not a valid transition without a gate decision"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed reviewer-repair-pass-routing test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll reviewer-repair-pass-routing tests passed." -ForegroundColor Green
exit 0
