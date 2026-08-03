# Single source of truth for the pipeline transition DAG, consumed by
# factory-gates.ps1 (Resolve-FactoryTransition) and validate-handoff.ps1.
# Edits must stay in sync with docs/pipeline-state-machine.md; a drift test
# enforces code/doc agreement.

function Get-PipelineValidTransitions {
    param([bool]$DeploymentRework)

    $deploymentSuccessors = [System.Collections.Generic.List[string]]::new()
    $deploymentSuccessors.Add("grooming")
    $deploymentSuccessors.Add("done")
    if ($DeploymentRework) {
        $deploymentSuccessors.Add("implementation")
    }

    return @{
        grooming       = @("implementation", "research", "verification", "done")
        implementation = @("verification")
        verification   = @("deployment", "implementation")
        deployment     = $deploymentSuccessors.ToArray()
        research       = @("grooming")
    }
}

function Test-DeploymentReworkReentry {
    param($Handoff, [string]$SessionDir)

    $isRework = $false
    $taskId = ""
    if ($null -ne $Handoff -and $null -ne $Handoff.task_id) {
        $taskId = ([string]$Handoff.task_id).Trim()
    }

    if (-not [string]::IsNullOrEmpty($taskId) -and -not [string]::IsNullOrEmpty($SessionDir)) {
        $gateDir = Join-Path $SessionDir "global/gate_decisions"
        if (Test-Path $gateDir) {
            $decisions = @(Get-ChildItem -Path $gateDir -Filter ($taskId + "-*.json") -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch "gate_decision_.*_pending.json" } |
                Sort-Object LastWriteTime -Descending)
            if ($decisions.Count -gt 0) {
                try {
                    $latestDecision = Get-Content $decisions[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($latestDecision.outcome -eq "rejected" -and $latestDecision.rework_requested -eq $true) {
                        $isRework = $true
                    }
                } catch {}
            }
        }
    }

    # A deployment -> implementation handoff carrying rebase_count >= 1 is a
    # rebase-conflict re-entry emitted by the accept gate when a merge could not be
    # auto-rebased cleanly (see Invoke-HumanGateMerge). The authorizing gate decision
    # is "accepted" (not "rejected"), so recognize the rebase counter directly.
    if (-not $isRework -and $null -ne $Handoff -and $Handoff.PSObject.Properties["rebase_count"]) {
        $rebaseCountVal = 0
        if ([int]::TryParse([string]$Handoff.rebase_count, [ref]$rebaseCountVal) -and $rebaseCountVal -ge 1) {
            $isRework = $true
        }
    }

    return $isRework
}
