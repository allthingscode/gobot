# Unit and regression tests for D49/D50 Grooming-to-Done closure transition.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$FACTORY_LIB = Join-Path $REPO_ROOT "powershell/factory-lib.ps1"
$Quiet = $true
. $FACTORY_LIB

$results = @()







function Write-TestHandoff {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][hashtable]$Values
    )

    if (-not $Values.ContainsKey("generated_by")) {
        $Values.generated_by = "new-handoff.ps1"
    }
    if (-not $Values.ContainsKey("tool_version")) {
        $Values.tool_version = "1.0.0"
    }

    $Values | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-TestContext {
    param(
        [Parameter(Mandatory=$true)][string]$TempRoot,
        [string]$TaskId = "F-001"
    )

    $sessionDir = Join-Path $TempRoot "session"
    $handoffDir = Join-Path $sessionDir "handoffs"
    $backlogDir = Join-Path $TempRoot "backlog"
    $frameworkDir = Join-Path $TempRoot "powershell"
    New-Item -ItemType Directory -Path $handoffDir, $backlogDir, $frameworkDir -Force | Out-Null

    # Create backlog folders
    New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/active") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/archived") -Force | Out-Null

    # Copy framework scripts to temp framework dir so they can be executed by factory-gates.ps1
    $actualPowershellDir = Join-Path $REPO_ROOT "powershell"
    Copy-Item -Path (Join-Path $actualPowershellDir "*.ps1") -Destination $frameworkDir -Force
    New-Item -ItemType Directory -Path (Join-Path $frameworkDir "lib") -Force | Out-Null
    Copy-Item -Path (Join-Path $actualPowershellDir "lib/*.ps1") -Destination (Join-Path $frameworkDir "lib") -Force

    # Write .crucible/config.yaml
    $crucibleDir = Join-Path $TempRoot ".crucible"
    New-Item -ItemType Directory -Path $crucibleDir -Force | Out-Null
    @"
paths:
  backlog: "backlog"
  session: "session"
"@ | Set-Content -LiteralPath (Join-Path $crucibleDir "config.yaml") -Encoding UTF8

    return @{
        RepoRoot = $TempRoot
        CrucibleRoot = ".crucible"
        FrameworkPowerShell = $frameworkDir
        SessionDir = $sessionDir
        BacklogDir = $backlogDir
        WorkspacesDir = Join-Path $TempRoot "workspaces"
        HandoffDir = $handoffDir
        PromptLib = Join-Path $TempRoot "prompts"
        LogFile = Join-Path $sessionDir "$TaskId/pipeline.log.jsonl"
        CircuitBreakerHistoryFile = Join-Path $sessionDir "global/circuit_breakers.jsonl"
        TaskId = $TaskId
        Target = "agent"
        Init = $true
        Recover = $false
        Quiet = $true
        AutoAdvance = $false
        GateOutcome = $null
        GateRedirectTarget = $null
        GateReason = $null
        BudgetCeilings = @{ low = 6; medium = 10; high = 24; extended = 32 }
        Ceiling = 6
        BudgetTierKey = "low"
        InvalidBudgetTier = ""
        Handoff = $null
        LatestHandoff = $null
        RelativeHandoffPath = $null
        CumulativeHandoffCount = 1
        IsBootstrap = $false
        Transition = $null
        NextFactoryCommand = $null
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-grooming-closure-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Resolve-FactoryTransition refuses grooming -> done if no human decision recorded" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "refusal") -TaskId "F-001"
        $handoffFile = Join-Path $ctx.HandoffDir "F-001-handoff.json"
        
        Write-TestHandoff -Path $handoffFile -Values @{
            task_id = "F-001"
            source_phase = "grooming"
            target_phase = "done"
            reason = "No deliverable"
            cumulative_handoff_count = 1
            budget_tier = "low"
            handoff_retry_count = 0
            prompt_version = "v1"
        }
        $ctx.Handoff = Get-Content $handoffFile -Raw | ConvertFrom-Json
        $ctx.LatestHandoff = Get-Item $handoffFile
        $ctx.RelativeHandoffPath = "session/handoffs/F-001-handoff.json"

        # Call Resolve-FactoryTransition
        $res = Resolve-FactoryTransition -Context $ctx
        Assert-Result -Name "refusal should exit" -Condition $res.ShouldExit -FailureMessage "expected transition to exit"
        Assert-Result -Name "refusal exit code" -Condition ($res.ExitCode -eq 2) -FailureMessage "expected exit code 2"
        Assert-Result -Name "refusal reason" -Condition ($res.Reason -match "no recorded human decision") -FailureMessage "expected reason matching no recorded human decision"
    }

    $results += Run-Test -Name "Resolve-FactoryTransition accepts grooming -> done if Research Gate approved it" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "approved-rg") -TaskId "F-001"
        
        # Create a spec in active features
        $specPath = Join-Path $ctx.BacklogDir "features/active/F-001_Verify.md"
        @"
---
item_id: "F-001"
type: "Feature"
status: "Grooming"
priority: "P1"
---
# Verify
"@ | Set-Content -Path $specPath -Encoding UTF8

        # Create a BACKLOG.md
        $backlogPath = Join-Path $ctx.BacklogDir "BACKLOG.md"
        @"
# BACKLOG

## Active Items
| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [F-001](features/active/F-001_Verify.md) | P1 | Grooming | Verify | Operator |
"@ | Set-Content -Path $backlogPath -Encoding UTF8

        # Write research handoff that contains human_decisions
        $researchHandoff = Join-Path $ctx.HandoffDir "F-001-research-handoff.json"
        Write-TestHandoff -Path $researchHandoff -Values @{
            task_id = "F-001"
            source_phase = "research"
            target_phase = "grooming"
            reason = "Research done"
            cumulative_handoff_count = 1
            budget_tier = "low"
            handoff_retry_count = 0
            prompt_version = "v1"
            artifacts = @("research/F-001.md")
            human_decisions = @{
                approved = @("Resolution: task resolved already")
                deferred = @()
                rejected = @()
            }
        }

        # Write grooming handoff
        $handoffFile = Join-Path $ctx.HandoffDir "F-001-handoff.json"
        Write-TestHandoff -Path $handoffFile -Values @{
            task_id = "F-001"
            source_phase = "grooming"
            target_phase = "done"
            reason = "No deliverable"
            cumulative_handoff_count = 2
            budget_tier = "low"
            handoff_retry_count = 0
            prompt_version = "v1"
            artifacts = @()
        }
        $ctx.Handoff = Get-Content $handoffFile -Raw | ConvertFrom-Json
        $ctx.LatestHandoff = Get-Item $handoffFile
        $ctx.RelativeHandoffPath = "session/handoffs/F-001-handoff.json"

        # Call Resolve-FactoryTransition
        $res = Resolve-FactoryTransition -Context $ctx
        Assert-Result -Name "approved transition should exit 0" -Condition ($res.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $res.ExitCode)

        # Check backlog archival was executed automatically
        $archivedSpec = Join-Path $ctx.BacklogDir "features/archived/F-001_Verify.md"
        Assert-Result -Name "active spec moved" -Condition (-not (Test-Path $specPath)) -FailureMessage "active spec still exists"
        Assert-Result -Name "archived spec created" -Condition (Test-Path $archivedSpec) -FailureMessage "archived spec was not found"
        
        $specContent = Get-Content -Path $archivedSpec -Raw
        $backlogContent = Get-Content -Path $backlogPath -Raw
        Assert-Result -Name "spec status resolved" -Condition ($specContent -match 'status:\s*"Resolved"') -FailureMessage "expected status resolved in spec"
        Assert-Result -Name "backlog status resolved" -Condition ($backlogContent -match 'Resolved') -FailureMessage "expected Resolved status in BACKLOG.md row"
    }

    function New-ResearchSpec {
        param(
            [Parameter(Mandatory=$true)]$Context,
            [Parameter(Mandatory=$true)][string]$TaskId,
            [Parameter(Mandatory=$true)][string]$Type,
            [string]$OpenQuestions = ""
        )
        $specPath = Join-Path $Context.BacklogDir ("features/active/" + $TaskId + "_Investigate.md")
        $body = @"
---
item_id: "$TaskId"
type: "$Type"
status: "Grooming"
priority: "P1"
---
# Investigate
"@
        if (-not [string]::IsNullOrEmpty($OpenQuestions)) {
            $body = $body + "`n`n## Open Questions`n`n" + $OpenQuestions + "`n"
        }
        Set-Content -LiteralPath $specPath -Value $body -Encoding UTF8
        return $specPath
    }

    function New-GroomingClosureHandoff {
        param([Parameter(Mandatory=$true)]$Context, [Parameter(Mandatory=$true)][string]$TaskId)
        $handoffFile = Join-Path $Context.HandoffDir ($TaskId + "-handoff.json")
        Write-TestHandoff -Path $handoffFile -Values @{
            task_id = $TaskId
            source_phase = "grooming"
            target_phase = "done"
            reason = "No deliverable"
            cumulative_handoff_count = 1
            budget_tier = "low"
            handoff_retry_count = 0
            prompt_version = "v1"
        }
        return (Get-Content $handoffFile -Raw | ConvertFrom-Json)
    }

    $results += Run-Test -Name "Research-misroute advisory warns when a Research-type task closes grooming -> done with no research lineage" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "misroute-type") -TaskId "F-001"
        New-ResearchSpec -Context $ctx -TaskId "F-001" -Type "Research" | Out-Null
        $handoff = New-GroomingClosureHandoff -Context $ctx -TaskId "F-001"

        $advisory = Get-ResearchMisrouteAdvisory -Handoff $handoff -Context $ctx -ProjectRoot $ctx.RepoRoot
        Assert-Result -Name "advisory returned" -Condition (-not [string]::IsNullOrEmpty($advisory)) -FailureMessage "expected a non-empty advisory for Research-type closure"
        Assert-Result -Name "advisory names the task" -Condition ($advisory -match "F-001") -FailureMessage "advisory should name the task"
        Assert-Result -Name "advisory flags premature closure" -Condition ($advisory -match "premature closure") -FailureMessage "advisory should flag premature closure"
    }

    $results += Run-Test -Name "Research-misroute advisory warns on a populated Open Questions section" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "misroute-oq") -TaskId "F-002"
        New-ResearchSpec -Context $ctx -TaskId "F-002" -Type "Feature" -OpenQuestions "- Does the token survive a WAL replay?" | Out-Null
        $handoff = New-GroomingClosureHandoff -Context $ctx -TaskId "F-002"

        $advisory = Get-ResearchMisrouteAdvisory -Handoff $handoff -Context $ctx -ProjectRoot $ctx.RepoRoot
        Assert-Result -Name "advisory returned for open questions" -Condition (-not [string]::IsNullOrEmpty($advisory)) -FailureMessage "expected advisory for populated Open Questions"
        Assert-Result -Name "advisory cites open questions" -Condition ($advisory -match "Open Questions") -FailureMessage "advisory should cite the Open Questions signal"
    }

    $results += Run-Test -Name "Research-misroute advisory is silent when a research handoff exists in lineage" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "misroute-lineage") -TaskId "F-003"
        New-ResearchSpec -Context $ctx -TaskId "F-003" -Type "Research" | Out-Null
        $researchHandoff = Join-Path $ctx.HandoffDir "F-003-research-handoff.json"
        Write-TestHandoff -Path $researchHandoff -Values @{
            task_id = "F-003"
            source_phase = "research"
            target_phase = "grooming"
            reason = "Research done"
            cumulative_handoff_count = 1
            budget_tier = "low"
            handoff_retry_count = 0
            prompt_version = "v1"
        }
        $handoff = New-GroomingClosureHandoff -Context $ctx -TaskId "F-003"

        $advisory = Get-ResearchMisrouteAdvisory -Handoff $handoff -Context $ctx -ProjectRoot $ctx.RepoRoot
        Assert-Result -Name "advisory silent with research lineage" -Condition ([string]::IsNullOrEmpty($advisory)) -FailureMessage "advisory should be silent when research lineage exists"
    }

    $results += Run-Test -Name "Research-misroute advisory is silent for a non-research task with no open questions" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "misroute-plain") -TaskId "F-004"
        New-ResearchSpec -Context $ctx -TaskId "F-004" -Type "Feature" | Out-Null
        $handoff = New-GroomingClosureHandoff -Context $ctx -TaskId "F-004"

        $advisory = Get-ResearchMisrouteAdvisory -Handoff $handoff -Context $ctx -ProjectRoot $ctx.RepoRoot
        Assert-Result -Name "advisory silent for plain feature" -Condition ([string]::IsNullOrEmpty($advisory)) -FailureMessage "advisory should be silent for a non-research task"
    }

} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failures = @($results | Where-Object { -not $_ }).Count
if ($failures -gt 0) {
    Write-Host ("`n{0} test(s) failed." -f $failures) -ForegroundColor Red
    exit 1
}
Write-Host "`nALL TESTS PASSED" -ForegroundColor Green
exit 0
