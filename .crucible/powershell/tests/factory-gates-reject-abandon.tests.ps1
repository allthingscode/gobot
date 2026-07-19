# Tests for factory gate orchestration helpers.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$FACTORY_LIB = Join-Path $REPO_ROOT "powershell/factory-lib.ps1"
$Quiet = $true
. $FACTORY_LIB
$pwshCmd = Get-PwshCommand

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
        BudgetCeilings = $null
        Ceiling = $null
        BudgetTierKey = ""
        InvalidBudgetTier = ""
        Handoff = $null
        LatestHandoff = $null
        RelativeHandoffPath = $null
        CumulativeHandoffCount = 0
        IsBootstrap = $false
        Transition = $null
        NextFactoryCommand = $null
    }
}
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-factory-gates-reject-abandon-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $results += Run-Test -Name "D55: fresh-gate guard - rejected and abandoned outcomes require fresh decisions" -Body {
        $caseRoot = Join-Path $tempRoot "d55-fresh-gate-guard"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $sessionDir = Join-Path $caseRoot "session"
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")

        # 1. Seed a rejected decision
        $decisionRejected = [ordered]@{
            task_id = 'F-038'
            outcome = 'rejected'
            rework_requested = $true
        }
        $decisionRejected | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "F-038-20260604T120000Z.json") -Encoding UTF8

        $scriptPath = Join-Path $caseRoot "run-guard-check.ps1"
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = `$null
    GateReason = `$null
    GateRedirectTarget = `$null
    CrucibleRoot = '$caseRoot'
    RepoRoot = '$caseRoot'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-038'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
        session_cycle_id = 'cycle-A'
    }
}
Invoke-HumanGate -Context `$ctx
"@
        $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        # If gate is NOT bypassed, it writes gate_decision_F-038_pending.json and exits 0
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $pendingFile = Join-Path $gateDir "gate_decision_F-038_pending.json"

        Assert-Result -Name "D55: rejected decision does not bypass gate" -Condition (Test-Path $pendingFile) -FailureMessage "expected gate_decision_F-038_pending.json to be created, but it was bypassed"

        # 2. Cleanup pending, seed an accepted decision FROM THE CURRENT CYCLE
        if (Test-Path $pendingFile) { Remove-Item $pendingFile -Force }
        $decisionAccepted = [ordered]@{
            task_id = 'F-038'
            outcome = 'accepted'
            rework_requested = $false
            session_cycle_id = 'cycle-A'
        }
        $decisionAccepted | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "F-038-20260604T130000Z.json") -Encoding UTF8

        # Run guard check again
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1

        Assert-Result -Name "D55: same-cycle accepted decision bypasses gate" -Condition (-not (Test-Path $pendingFile)) -FailureMessage "expected gate to be bypassed, but pending file was created"

        # 3. Stale-cycle bypass regression: an accepted decision from a PRIOR cycle
        #    must NOT auto-advance a fresh gate encounter (re-opened task / rework
        #    re-entry). The human must be re-prompted.
        if (Test-Path $pendingFile) { Remove-Item $pendingFile -Force }
        Get-ChildItem -Path $gateDir -Filter "F-038-*.json" | Remove-Item -Force
        $decisionStale = [ordered]@{
            task_id = 'F-038'
            outcome = 'accepted'
            rework_requested = $false
            session_cycle_id = 'cycle-OLD'
        }
        $decisionStale | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "F-038-20260604T140000Z.json") -Encoding UTF8

        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1

        Assert-Result -Name "D55: stale-cycle accepted decision does NOT bypass gate" -Condition (Test-Path $pendingFile) -FailureMessage "expected stale-cycle accept to re-prompt (pending file created), but the gate was bypassed using a prior-cycle acceptance"
    }

    $results += Run-Test -Name "D55: end-to-end reject -> rework re-entry" -Body {
        # Stand up local + bare-origin repos
        $caseRoot = Join-Path $tempRoot "d55-e2e-reject-rework"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $originRepo = Join-Path $caseRoot "origin.git"
        $localRepo = Join-Path $caseRoot "local"

        # Init origin bare repo
        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        Invoke-GitChecked { git -C $originRepo init --bare --initial-branch master } | Out-Null

        # Clone local
        Invoke-GitChecked { git clone $originRepo $localRepo } | Out-Null

        # Seed master in local
        "init" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        Invoke-GitChecked { git -C $localRepo add README.md } | Out-Null
        Invoke-GitChecked { git -C $localRepo commit -m "init" } | Out-Null
        Invoke-GitChecked { git -C $localRepo push origin master } | Out-Null

        $beforeOriginHead = (Invoke-GitChecked { git -C $localRepo rev-parse origin/master }).Trim()

        # Seed backlog configuration in local
        $backlogDir = Join-Path $localRepo ".crucible/backlog"
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/active") -Force | Out-Null

        $configContent = @"
paths:
  backlog: ".crucible/backlog"
"@
        $configContent | Set-Content -LiteralPath (Join-Path $localRepo ".crucible/config.yaml") -Encoding UTF8

        # Create active spec file
        $specContent = @"
---
item_id: "F-999"
type: "Feature"
status: "Ready for Deploy"
priority: "P2"
target_phase: "deployment"
created_at: "2026-06-04"
---

# Test Spec F-999
"@
        $specContent | Set-Content -LiteralPath (Join-Path $backlogDir "features/active/F-999_Test_Spec.md") -Encoding UTF8

        # Create BACKLOG.md
        $backlogContent = @"
# Backlog

## Active Items

| ID | Status | Title | Target |
|---|---|---|---|
| [F-999](features/active/F-999_Test_Spec.md) | Ready for Deploy | Test Spec F-999 | Operator |
"@
        $backlogContent | Set-Content -LiteralPath (Join-Path $backlogDir "BACKLOG.md") -Encoding UTF8

        # 1. Un-pushed commit on master to make sure it survives (the D52 pattern)
        Invoke-GitChecked { git -C $localRepo checkout master } | Out-Null
        "unrelated" | Set-Content -LiteralPath (Join-Path $localRepo "unrelated.md") -Encoding UTF8
        Invoke-GitChecked { git -C $localRepo add unrelated.md } | Out-Null
        Invoke-GitChecked { git -C $localRepo commit -m "unrelated commit" } | Out-Null
        $unrelatedHash = (Invoke-GitChecked { git -C $localRepo rev-parse HEAD }).Trim()

        # 2. Checkout task branch from the initial commit (master~1), and commit a change
        Invoke-GitChecked { git -C $localRepo checkout -b task/F-999 HEAD~1 } | Out-Null
        "feature content" | Set-Content -LiteralPath (Join-Path $localRepo "feature.md") -Encoding UTF8
        Invoke-GitChecked { git -C $localRepo add feature.md } | Out-Null
        Invoke-GitChecked { git -C $localRepo commit -m "feature commit" } | Out-Null

        # 3. Checkout master and merge task branch locally
        Invoke-GitChecked { git -C $localRepo checkout master } | Out-Null
        Invoke-GitChecked { git -C $localRepo merge --no-edit task/F-999 } | Out-Null

        # Set up session folders
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        # Delete local implementation worktree (simulating Operator cleanup)
        $wtPath = Join-Path $localRepo ".crucible/.agent-workspaces/implementation-F-999"
        if (Test-Path $wtPath) { Remove-Item $wtPath -Recurse -Force }

        $scriptPath = Join-Path $caseRoot "run-reject.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")

        # Script to run Invoke-HumanGate with rejected outcome
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'rejected'
    GateReason = 'needs more polish'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    RepoRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-999'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
        artifacts = @('feature.md')
        session_cycle_id = 'cycle-999'
    }
}

Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
} finally {
    Pop-Location
}
"@
        $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        # Run rejected outcome
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE

        Assert-Result -Name "E2E Reject: exit code is 0" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got $exitCode. Output: " + $output)

        # 1. Assert master reset back to pre-merge tip (unrelated hash)
        $currentHead = (Invoke-GitChecked { git -C $localRepo rev-parse HEAD }).Trim()
        Assert-Result -Name "E2E Reject: master head restored to unrelated commit" -Condition ($currentHead -eq $unrelatedHash) -FailureMessage ("expected master to be $unrelatedHash, got $currentHead")

        # 2. Assert task branch task/F-999 is restored/present
        Invoke-GitChecked { git -C $localRepo show-ref --quiet "refs/heads/task/F-999" } | Out-Null
        $branchExists = ($LASTEXITCODE -eq 0)
        Assert-Result -Name "E2E Reject: task branch restored" -Condition $branchExists -FailureMessage "expected branch task/F-999 to be present"

        # 3. Assert implementation worktree was recreated
        $worktreeExists = (Test-Path $wtPath)
        Assert-Result -Name "E2E Reject: implementation worktree recreated" -Condition $worktreeExists -FailureMessage "expected worktree to exist at $wtPath"

        # 4. Assert new-handoff was run and created the deployment -> implementation handoff
        $handoffFiles = @(Get-ChildItem -Path (Join-Path $sessionDir "handoffs") -Filter "F-999-*.json")
        Assert-Result -Name "E2E Reject: handoff JSON generated" -Condition ($handoffFiles.Count -gt 0) -FailureMessage "expected at least one handoff file to be generated"

        $latestHandoff = Get-Content $handoffFiles[-1].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Result -Name "E2E Reject: handoff target is implementation" -Condition ($latestHandoff.target_phase -eq "implementation") -FailureMessage ("expected handoff target to be implementation, got " + $latestHandoff.target_phase)
        Assert-Result -Name "E2E Reject: strike count incremented" -Condition ($latestHandoff.review_strike_count -eq 1) -FailureMessage ("expected strike count 1, got " + $latestHandoff.review_strike_count)

        # 5. Assert the artifact check is satisfied and doesn't fail when initializing
        $initScriptPath = Join-Path $caseRoot "run-init.ps1"
        $factoryPath = Join-Path $localRepo "powershell/factory.ps1"
        # We need to copy powershell/ directory to localRepo to run factory.ps1 from it, or we can use $localRepo as ProjectRoot
        New-Item -ItemType Directory -Path (Join-Path $localRepo "powershell") -Force | Out-Null
        Copy-Item -Path (Join-Path $REPO_ROOT "powershell/*") -Destination (Join-Path $localRepo "powershell") -Recurse -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $localRepo "schemas") -Force | Out-Null
        Copy-Item -Path (Join-Path $REPO_ROOT "schemas/*") -Destination (Join-Path $localRepo "schemas") -Recurse -Force | Out-Null

        $initScriptContent = @"
Push-Location '$localRepo'
try {
    $((Get-PwshCommand)) -ExecutionPolicy Bypass -File '$localRepo/powershell/factory.ps1' -Init -TaskId 'F-999' -Quiet
} finally {
    Pop-Location
}
"@
        $initScriptContent | Set-Content -LiteralPath $initScriptPath -Encoding UTF8

        # Run factory init to see if it advances to implementation without tripping the artifact gate
        $initOutput = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $initScriptPath 2>&1
        $initExitCode = $LASTEXITCODE

        Assert-Result -Name "E2E Reject: factory init succeeded" -Condition ($initExitCode -eq 0) -FailureMessage ("expected factory init to pass, got exit code $initExitCode. Output: " + $initOutput)

        # Strengthened assertions for D56 target_phase checks
        $pendingFile = Join-Path $gateDir "gate_decision_F-999_pending.json"
        Assert-Result -Name "D56 E2E Reject: pending gate decision JSON does not exist" -Condition (-not (Test-Path $pendingFile)) -FailureMessage "expected gate_decision_F-999_pending.json to not exist"

        $pendingTxt = Join-Path $sessionDir "F-999/gate_pending.txt"
        Assert-Result -Name "D56 E2E Reject: gate_pending.txt does not exist" -Condition (-not (Test-Path $pendingTxt)) -FailureMessage "expected gate_pending.txt to not be created"

        # Verify generated files for implementation phase
        $promptFile = Join-Path $sessionDir "F-999/implementation/prompt.md"
        Assert-Result -Name "D56 E2E Reject: prompt.md exists" -Condition (Test-Path $promptFile) -FailureMessage "expected prompt.md to exist at $promptFile"

        $promptContent = Get-Content $promptFile -Raw -Encoding UTF8
        Assert-Result -Name "D56 E2E Reject: prompt.md references Architect" -Condition ($promptContent -match "Architect") -FailureMessage ("expected prompt.md to reference Architect, got: " + $promptContent)

        $taskFile = Join-Path $sessionDir "F-999/implementation/task.md"
        Assert-Result -Name "D56 E2E Reject: task.md exists" -Condition (Test-Path $taskFile) -FailureMessage "expected task.md to exist at $taskFile"

        $taskContent = Get-Content $taskFile -Raw -Encoding UTF8
        Assert-Result -Name "D56 E2E Reject: task.md references implementation phase" -Condition ($taskContent -match "Phase: implementation") -FailureMessage ("expected task.md to reference Phase: implementation, got: " + $taskContent)
    }

    $results += Run-Test -Name "D56: human-gate trigger target_phase checks" -Body {
        $caseRoot = Join-Path $tempRoot "d56-gate-trigger-target"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $sessionDir = Join-Path $caseRoot "session"
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $libPath = $FACTORY_LIB.Replace("'", "''")

        # 1. Seed a rejected decision
        $decisionRejected = [ordered]@{
            task_id = 'F-039'
            outcome = 'rejected'
            rework_requested = $true
        }
        $decisionRejected | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "F-039-20260604T120000Z.json") -Encoding UTF8

        # 2. Invoke-HumanGate with deployment -> implementation handoff. It should NOT fire the gate (so no pending file, exits normally/doesn't exit 0/doesn't create menu)
        $scriptPath = Join-Path $caseRoot "run-rework-trigger.ps1"
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = `$null
    GateReason = `$null
    GateRedirectTarget = `$null
    CrucibleRoot = '$caseRoot'
    RepoRoot = '$caseRoot'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-039'
        source_phase = 'deployment'
        target_phase = 'implementation'
        cumulative_handoff_count = 2
    }
}
Invoke-HumanGate -Context `$ctx
Write-Host "SUCCESS_MARKER"
"@
        $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $outputStr = $output -join "`n"
        $pendingFile = Join-Path $gateDir "gate_decision_F-039_pending.json"

        Assert-Result -Name "D56: deployment -> implementation does not fire gate" -Condition (-not (Test-Path $pendingFile)) -FailureMessage "expected gate_decision_F-039_pending.json to not be created"
        Assert-Result -Name "D56: deployment -> implementation runs to completion" -Condition ($outputStr -match "SUCCESS_MARKER") -FailureMessage "expected script to run to completion, got: $outputStr"

        # 3. Invoke-HumanGate with deployment -> done handoff. It SHOULD fire the gate (so it creates the pending file)
        $scriptPathDone = Join-Path $caseRoot "run-done-trigger.ps1"
        $scriptContentDone = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = `$null
    GateReason = `$null
    GateRedirectTarget = `$null
    CrucibleRoot = '$caseRoot'
    RepoRoot = '$caseRoot'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-039'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 2
    }
}
Invoke-HumanGate -Context `$ctx
Write-Host "SUCCESS_MARKER"
"@
        $scriptContentDone | Set-Content -LiteralPath $scriptPathDone -Encoding UTF8

        $outputDone = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPathDone 2>&1
        $outputDoneStr = $outputDone -join "`n"

        Assert-Result -Name "D56: deployment -> done fires gate" -Condition (Test-Path $pendingFile) -FailureMessage "expected gate_decision_F-039_pending.json to be created"
        Assert-Result -Name "D56: deployment -> done exits early" -Condition ($outputDoneStr -notmatch "SUCCESS_MARKER") -FailureMessage "expected script to exit early, got: $outputDoneStr"
    }

    $results += Run-Test -Name "D57: end-to-end reject restores backlog if archived" -Body {
        $FRAMEWORK_POWERSHELL = Join-Path $REPO_ROOT "powershell"
        $caseRoot = Join-Path $tempRoot "d57-e2e-reject-restore"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $originRepo = Join-Path $caseRoot "origin.git"
        $localRepo = Join-Path $caseRoot "local"

        # Init origin bare repo
        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        Invoke-GitChecked { git -C $originRepo init --bare --initial-branch master } | Out-Null

        # Clone local
        Invoke-GitChecked { git clone $originRepo $localRepo } | Out-Null

        # Seed master in local
        "init" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        Invoke-GitChecked { git -C $localRepo add README.md } | Out-Null
        Invoke-GitChecked { git -C $localRepo commit -m "init" } | Out-Null
        Invoke-GitChecked { git -C $localRepo push origin master } | Out-Null

        # Seed backlog config
        $backlogDir = Join-Path $localRepo ".crucible/backlog"
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/active") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/archived") -Force | Out-Null

        $configContent = @"
paths:
  backlog: ".crucible/backlog"
"@
        $configContent | Set-Content -LiteralPath (Join-Path $localRepo ".crucible/config.yaml") -Encoding UTF8

        # Create active spec file
        $specContent = @"
---
item_id: "F-888"
type: "Feature"
status: "Ready for Deploy"
priority: "P2"
target_phase: "deployment"
created_at: "2026-06-04"
---

# Test Spec F-888
"@
        $specContent | Set-Content -LiteralPath (Join-Path $backlogDir "features/active/F-888_Test_Spec.md") -Encoding UTF8

        # Create BACKLOG.md
        $backlogContent = @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | F-888 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [F-888](features/active/F-888_Test_Spec.md) | P2 | Ready for Deploy | Test Spec F-888 | Operator |
"@
        $backlogContent | Set-Content -LiteralPath (Join-Path $backlogDir "BACKLOG.md") -Encoding UTF8

        # Initialize/reconcile Priority-Summary
        $validateScript = Join-Path $FRAMEWORK_POWERSHELL "validate-backlog.ps1"
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $validateScript -FixSummary -ProjectRoot $localRepo | Out-Null

        # Checkout task branch and make commit
        Invoke-GitChecked { git -C $localRepo checkout -b task/F-888 } | Out-Null
        "feature content" | Set-Content -LiteralPath (Join-Path $localRepo "feature.md") -Encoding UTF8
        Invoke-GitChecked { git -C $localRepo add feature.md } | Out-Null
        Invoke-GitChecked { git -C $localRepo commit -m "feature commit" } | Out-Null

        # Checkout master and merge locally
        Invoke-GitChecked { git -C $localRepo checkout master } | Out-Null
        Invoke-GitChecked { git -C $localRepo merge --no-edit task/F-888 } | Out-Null

        # Setup session folders
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        # Legacy/old behavior: archive the task BEFORE the gate runs
        # Load archive-task helper
        $archiveLibPath = Join-Path $FRAMEWORK_POWERSHELL "lib/archive-task.ps1"
        if (-not (Get-Command "Invoke-BacklogTaskArchive" -ErrorAction SilentlyContinue)) {
            . $archiveLibPath
        }
        Invoke-BacklogTaskArchive -BacklogPath (Join-Path $backlogDir "BACKLOG.md") -SpecPath (Join-Path $backlogDir "features/active/F-888_Test_Spec.md") -Status "Production" | Out-Null

        # Verify it is archived
        Assert-Result -Name "D57 Test: spec is archived before reject" -Condition (Test-Path (Join-Path $backlogDir "features/archived/F-888_Test_Spec.md")) -FailureMessage "expected spec to be archived"

        # Script to run Invoke-HumanGate with rejected outcome
        $scriptPath = Join-Path $caseRoot "run-reject.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'rejected'
    GateReason = 'needs work'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    RepoRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-888'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
        artifacts = @('feature.md')
        session_cycle_id = 'cycle-888'
    }
}

Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
} finally {
    Pop-Location
}
"@
        $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        # Run rejected outcome
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE

        Assert-Result -Name "D57 Reject Restore: exit code is 0" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got $exitCode. Output: " + $output)

        # Assert: the spec is back under active/
        $activeSpecExists = Test-Path (Join-Path $backlogDir "features/active/F-888_Test_Spec.md")
        $archivedSpecExists = Test-Path (Join-Path $backlogDir "features/archived/F-888_Test_Spec.md")
        Assert-Result -Name "D57 Reject Restore: active spec restored" -Condition ($activeSpecExists -and -not $archivedSpecExists) -FailureMessage "expected active spec to exist and archived spec to be removed"

        # Assert: frontmatter status is non-terminal
        $specLines = Get-Content (Join-Path $backlogDir "features/active/F-888_Test_Spec.md") -Raw
        $statusMatches = ($specLines -match 'status:\s*"In Progress"')
        Assert-Result -Name "D57 Reject Restore: status is In Progress" -Condition $statusMatches -FailureMessage "expected spec status to be 'In Progress'"

        # Assert: BACKLOG.md row has active link and status In Progress
        $backlogLines = Get-Content (Join-Path $backlogDir "BACKLOG.md") -Raw
        $rowMatches = ($backlogLines -match '\[F-888\]\(features/active/F-888_Test_Spec.md\)\s*\|\s*P2\s*\|\s*In Progress')
        Assert-Result -Name "D57 Reject Restore: BACKLOG.md row updated" -Condition $rowMatches -FailureMessage ("expected BACKLOG.md row to show active link and 'In Progress', got: " + $backlogLines)

        # Assert: Priority-Summary counts are restored
        $prioritySummaryMatches = ($backlogLines -match '\|\s*\*\*P2\*\*\s*\|\s*1\s*\|\s*F-888\s*\|')
        Assert-Result -Name "D57 Reject Restore: Priority-Summary counts updated" -Condition $prioritySummaryMatches -FailureMessage ("expected P2 count 1, got BACKLOG.md: " + $backlogLines)
    }

    $results += Run-Test -Name "D57: end-to-end abandon archives as Abandoned" -Body {
        $FRAMEWORK_POWERSHELL = Join-Path $REPO_ROOT "powershell"
        $caseRoot = Join-Path $tempRoot "d57-e2e-abandon"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $originRepo = Join-Path $caseRoot "origin.git"
        $localRepo = Join-Path $caseRoot "local"

        # Init origin bare repo
        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        Invoke-GitChecked { git -C $originRepo init --bare --initial-branch master } | Out-Null

        # Clone local
        Invoke-GitChecked { git clone $originRepo $localRepo } | Out-Null

        # Seed master in local
        "init" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        Invoke-GitChecked { git -C $localRepo add README.md } | Out-Null
        Invoke-GitChecked { git -C $localRepo commit -m "init" } | Out-Null
        Invoke-GitChecked { git -C $localRepo push origin master } | Out-Null

        # Seed backlog config
        $backlogDir = Join-Path $localRepo ".crucible/backlog"
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/active") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/archived") -Force | Out-Null

        $configContent = @"
paths:
  backlog: ".crucible/backlog"
"@
        $configContent | Set-Content -LiteralPath (Join-Path $localRepo ".crucible/config.yaml") -Encoding UTF8

        # Create active spec file
        $specContent = @"
---
item_id: "F-777"
type: "Feature"
status: "Ready for Deploy"
priority: "P2"
target_phase: "deployment"
created_at: "2026-06-04"
---

# Test Spec F-777
"@
        $specContent | Set-Content -LiteralPath (Join-Path $backlogDir "features/active/F-777_Test_Spec.md") -Encoding UTF8

        # Create BACKLOG.md
        $backlogContent = @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | F-777 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [F-777](features/active/F-777_Test_Spec.md) | P2 | Ready for Deploy | Test Spec F-777 | Operator |
"@
        $backlogContent | Set-Content -LiteralPath (Join-Path $backlogDir "BACKLOG.md") -Encoding UTF8

        # Initialize/reconcile Priority-Summary
        $validateScript = Join-Path $FRAMEWORK_POWERSHELL "validate-backlog.ps1"
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $validateScript -FixSummary -ProjectRoot $localRepo | Out-Null

        # Checkout task branch and commit
        Invoke-GitChecked { git -C $localRepo checkout -b task/F-777 } | Out-Null
        "feature content" | Set-Content -LiteralPath (Join-Path $localRepo "feature.md") -Encoding UTF8
        Invoke-GitChecked { git -C $localRepo add feature.md } | Out-Null
        Invoke-GitChecked { git -C $localRepo commit -m "feature commit" } | Out-Null

        # Checkout master and merge locally
        Invoke-GitChecked { git -C $localRepo checkout master } | Out-Null
        Invoke-GitChecked { git -C $localRepo merge --no-edit task/F-777 } | Out-Null

        # Setup session folders
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        # Under Approach A, the spec is active (NOT archived) before the gate is run

        # Script to run Invoke-HumanGate with abandoned outcome
        $scriptPath = Join-Path $caseRoot "run-abandon.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'abandoned'
    GateReason = 'canceled'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    RepoRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-777'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
        artifacts = @('feature.md')
        session_cycle_id = 'cycle-777'
    }
}

Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
} finally {
    Pop-Location
}
"@
        $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        # Run abandoned outcome
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE

        Assert-Result -Name "D57 Abandon: exit code is 0" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got $exitCode. Output: " + $output)

        # Assert: the spec is archived
        $activeSpecExists = Test-Path (Join-Path $backlogDir "features/active/F-777_Test_Spec.md")
        $archivedSpecExists = Test-Path (Join-Path $backlogDir "features/archived/F-777_Test_Spec.md")
        Assert-Result -Name "D57 Abandon: archived spec created" -Condition ($archivedSpecExists -and -not $activeSpecExists) -FailureMessage "expected archived spec to exist and active spec to be removed"

        # Assert: frontmatter status is Abandoned
        $specLines = Get-Content (Join-Path $backlogDir "features/archived/F-777_Test_Spec.md") -Raw
        $statusMatches = ($specLines -match 'status:\s*"Abandoned"')
        Assert-Result -Name "D57 Abandon: status is Abandoned in spec" -Condition $statusMatches -FailureMessage "expected spec status to be 'Abandoned'"

        # Assert: BACKLOG.md row shows Abandoned
        $backlogLines = Get-Content (Join-Path $backlogDir "BACKLOG.md") -Raw
        $rowMatches = ($backlogLines -match '\[F-777\]\(features/archived/F-777_Test_Spec.md\)\s*\|\s*P2\s*\|\s*Abandoned')
        Assert-Result -Name "D57 Abandon: BACKLOG.md row updated" -Condition $rowMatches -FailureMessage ("expected BACKLOG.md row to show archived link and 'Abandoned', got: " + $backlogLines)

        # Assert: Priority-Summary counts are reconciled (F-777 removed)
        $prioritySummaryMatches = ($backlogLines -match '\|\s*\*\*P2\*\*\s*\|\s*0\s*\|\s*-\s*\|')
        Assert-Result -Name "D57 Abandon: Priority-Summary counts updated" -Condition $prioritySummaryMatches -FailureMessage ("expected P2 count 0, got BACKLOG.md: " + $backlogLines)
    }

    $results += Run-Test -Name "D57: full-loop reject -> rework -> accept" -Body {
        $FRAMEWORK_POWERSHELL = Join-Path $REPO_ROOT "powershell"
        $caseRoot = Join-Path $tempRoot "d57-full-loop"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $originRepo = Join-Path $caseRoot "origin.git"
        $localRepo = Join-Path $caseRoot "local"

        # Init origin bare repo
        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        Invoke-GitChecked { git -C $originRepo init --bare --initial-branch master } | Out-Null

        # Clone local
        Invoke-GitChecked { git clone $originRepo $localRepo } | Out-Null

        # Seed master in local
        "init" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        Invoke-GitChecked { git -C $localRepo add README.md } | Out-Null
        Invoke-GitChecked { git -C $localRepo commit -m "init" } | Out-Null
        Invoke-GitChecked { git -C $localRepo push origin master } | Out-Null

        # Seed backlog config
        $backlogDir = Join-Path $localRepo ".crucible/backlog"
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/active") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/archived") -Force | Out-Null

        $configContent = @"
paths:
  backlog: ".crucible/backlog"
"@
        $configContent | Set-Content -LiteralPath (Join-Path $localRepo ".crucible/config.yaml") -Encoding UTF8

        # Create active spec file
        $specContent = @"
---
item_id: "F-666"
type: "Feature"
status: "Ready for Deploy"
priority: "P2"
target_phase: "deployment"
created_at: "2026-06-04"
---

# Test Spec F-666
"@
        $specContent | Set-Content -LiteralPath (Join-Path $backlogDir "features/active/F-666_Test_Spec.md") -Encoding UTF8

        # Create BACKLOG.md
        $backlogContent = @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | F-666 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [F-666](features/active/F-666_Test_Spec.md) | P2 | Ready for Deploy | Test Spec F-666 | Operator |
"@
        $backlogContent | Set-Content -LiteralPath (Join-Path $backlogDir "BACKLOG.md") -Encoding UTF8

        # Initialize/reconcile Priority-Summary
        $validateScript = Join-Path $FRAMEWORK_POWERSHELL "validate-backlog.ps1"
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $validateScript -FixSummary -ProjectRoot $localRepo | Out-Null

        # Checkout task branch and commit
        Invoke-GitChecked { git -C $localRepo checkout -b task/F-666 } | Out-Null
        "feature content" | Set-Content -LiteralPath (Join-Path $localRepo "feature.md") -Encoding UTF8
        Invoke-GitChecked { git -C $localRepo add feature.md } | Out-Null
        Invoke-GitChecked { git -C $localRepo commit -m "feature commit" } | Out-Null

        # Checkout master and merge locally
        Invoke-GitChecked { git -C $localRepo checkout master } | Out-Null
        Invoke-GitChecked { git -C $localRepo merge --no-edit task/F-666 } | Out-Null

        # Setup session folders
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        # 1. RUN REJECTED OUTCOME (using Invoke-HumanGate)
        $scriptPathReject = Join-Path $caseRoot "run-reject.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        $scriptContentReject = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'rejected'
    GateReason = 'needs rework'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    RepoRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-666'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
        artifacts = @('feature.md')
        session_cycle_id = 'cycle-666'
    }
}

Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
} finally {
    Pop-Location
}
"@
        $scriptContentReject | Set-Content -LiteralPath $scriptPathReject -Encoding UTF8
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPathReject 2>&1 | Out-Null

        # Verify spec is active and status is In Progress
        Assert-Result -Name "D57 Loop: active spec exists after reject" -Condition (Test-Path (Join-Path $backlogDir "features/active/F-666_Test_Spec.md")) -FailureMessage "expected active spec to exist after reject"

        # 2. SIMULATE REWORK -> RE-DEPLOY
        # Make a rework commit inside the implementation worktree
        $wtPath = Join-Path $localRepo ".crucible/.agent-workspaces/implementation-F-666"
        "reworked content" | Set-Content -LiteralPath (Join-Path $wtPath "reworked.md") -Encoding UTF8
        Invoke-GitChecked { git -C $wtPath add reworked.md } | Out-Null
        Invoke-GitChecked { git -C $wtPath commit -m "rework commit" } | Out-Null

        # Now merge task/F-666 into master
        Invoke-GitChecked { git -C $localRepo checkout master } | Out-Null
        Invoke-GitChecked { git -C $localRepo merge --no-edit task/F-666 } | Out-Null

        # 3. RUN ACCEPTED OUTCOME (using Invoke-HumanGate)
        $scriptPathAccept = Join-Path $caseRoot "run-accept.ps1"
        $scriptContentAccept = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'accepted'
    GateReason = 'perfect now'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    RepoRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-666'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 2
        artifacts = @('feature.md', 'reworked.md')
        session_cycle_id = 'cycle-666'
    }
}

Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
} finally {
    Pop-Location
}
"@
        $scriptContentAccept | Set-Content -LiteralPath $scriptPathAccept -Encoding UTF8

        $acceptOutput = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPathAccept 2>&1
        $acceptExitCode = $LASTEXITCODE

        Assert-Result -Name "D57 Loop Accept: exit code is 0" -Condition ($acceptExitCode -eq 0) -FailureMessage ("expected exit code 0, got $acceptExitCode. Output: " + $acceptOutput)

        # Assert: the spec is archived
        $activeSpecExists = Test-Path (Join-Path $backlogDir "features/active/F-666_Test_Spec.md")
        $archivedSpecExists = Test-Path (Join-Path $backlogDir "features/archived/F-666_Test_Spec.md")
        Assert-Result -Name "D57 Loop: archived spec created" -Condition ($archivedSpecExists -and -not $activeSpecExists) -FailureMessage "expected archived spec to exist and active spec to be removed"

        # Assert: frontmatter status is Production
        $specLines = Get-Content (Join-Path $backlogDir "features/archived/F-666_Test_Spec.md") -Raw
        $statusMatches = ($specLines -match 'status:\s*"Production"')
        Assert-Result -Name "D57 Loop: status is Production in spec" -Condition $statusMatches -FailureMessage "expected spec status to be 'Production'"

        # Assert: BACKLOG.md row shows Production
        $backlogLines = Get-Content (Join-Path $backlogDir "BACKLOG.md") -Raw
        $rowMatches = ($backlogLines -match '\[F-666\]\(features/archived/F-666_Test_Spec.md\)\s*\|\s*P2\s*\|\s*Production')
        Assert-Result -Name "D57 Loop: BACKLOG.md row updated to Production" -Condition $rowMatches -FailureMessage ("expected BACKLOG.md row to show Production, got: " + $backlogLines)

        # Assert: Priority-Summary counts are reconciled (F-666 removed)
        $prioritySummaryMatches = ($backlogLines -match '\|\s*\*\*P2\*\*\s*\|\s*0\s*\|\s*-\s*\|')
        Assert-Result -Name "D57 Loop: Priority-Summary counts updated" -Condition $prioritySummaryMatches -FailureMessage ("expected P2 count 0, got BACKLOG.md: " + $backlogLines)
    }

    $results += Run-Test -Name "D58: end-to-end redirect finalizes+pushes and records redirect_target" -Body {
        # Redirect is an advancing outcome: it ships the current task exactly like
        # accept (finalize -> merge -> push) AND records the redirect_target so the
        # audit trail captures which item the human chose to work on next. The D37
        # coverage only exercised a no-op push and never asserted either the
        # finalization/push or the recorded redirect_target -- this locks both.
        $FRAMEWORK_POWERSHELL = Join-Path $REPO_ROOT "powershell"
        $caseRoot = Join-Path $tempRoot "d58-e2e-redirect"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $originRepo = Join-Path $caseRoot "origin.git"
        $localRepo = Join-Path $caseRoot "local"

        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        Invoke-GitChecked { git -C $originRepo init --bare --initial-branch master } | Out-Null
        Invoke-GitChecked { git clone $originRepo $localRepo } | Out-Null

        "init" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        Invoke-GitChecked { git -C $localRepo add README.md } | Out-Null
        Invoke-GitChecked { git -C $localRepo commit -m "init" } | Out-Null
        Invoke-GitChecked { git -C $localRepo push origin master } | Out-Null

        $backlogDir = Join-Path $localRepo ".crucible/backlog"
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/active") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/archived") -Force | Out-Null

        $configContent = @"
paths:
  backlog: ".crucible/backlog"
review:
  auto_push: true
"@
        $configContent | Set-Content -LiteralPath (Join-Path $localRepo ".crucible/config.yaml") -Encoding UTF8

        $specContent = @"
---
item_id: "F-555"
type: "Feature"
status: "Ready for Deploy"
priority: "P2"
target_phase: "deployment"
created_at: "2026-06-04"
---

# Test Spec F-555
"@
        $specContent | Set-Content -LiteralPath (Join-Path $backlogDir "features/active/F-555_Test_Spec.md") -Encoding UTF8

        $backlogContent = @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | F-555 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [F-555](features/active/F-555_Test_Spec.md) | P2 | Ready for Deploy | Test Spec F-555 | Operator |
"@
        $backlogContent | Set-Content -LiteralPath (Join-Path $backlogDir "BACKLOG.md") -Encoding UTF8

        $validateScript = Join-Path $FRAMEWORK_POWERSHELL "validate-backlog.ps1"
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $validateScript -FixSummary -ProjectRoot $localRepo | Out-Null

        Invoke-GitChecked { git -C $localRepo checkout -b task/F-555 } | Out-Null
        "feature content" | Set-Content -LiteralPath (Join-Path $localRepo "feature.md") -Encoding UTF8
        Invoke-GitChecked { git -C $localRepo add feature.md } | Out-Null
        Invoke-GitChecked { git -C $localRepo commit -m "feature commit" } | Out-Null
        Invoke-GitChecked { git -C $localRepo checkout master } | Out-Null

        $sessionDir = Join-Path $localRepo ".crucible/session"
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        $beforeOriginHead = (Invoke-GitChecked { git -C $localRepo rev-parse origin/master }).Trim()

        $scriptPath = Join-Path $caseRoot "run-redirect.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'redirected'
    GateReason = 'ship F-555 and pivot to the hotfix next'
    GateRedirectTarget = 'F-556'
    CrucibleRoot = '$localRepo'
    RepoRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-555'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
        artifacts = @('feature.md')
        session_cycle_id = 'cycle-555'
    }
}

Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
} finally {
    Pop-Location
}
"@
        $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE

        Assert-Result -Name "D58 Redirect: exit code is 0" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got $exitCode. Output: " + $output)

        # Redirect finalizes the current task exactly like accept.
        $activeSpecExists = Test-Path (Join-Path $backlogDir "features/active/F-555_Test_Spec.md")
        $archivedSpecExists = Test-Path (Join-Path $backlogDir "features/archived/F-555_Test_Spec.md")
        Assert-Result -Name "D58 Redirect: current task archived (finalized)" -Condition ($archivedSpecExists -and -not $activeSpecExists) -FailureMessage "expected redirect to archive the current task like accept"

        $specLines = Get-Content (Join-Path $backlogDir "features/archived/F-555_Test_Spec.md") -Raw
        Assert-Result -Name "D58 Redirect: archived status is Production" -Condition ($specLines -match 'status:\s*"Production"') -FailureMessage "expected redirect to finalize the task as Production"

        # Redirect pushes to origin (auto_push=true), same as accept.
        $afterOriginHead = (Invoke-GitChecked { git -C $localRepo rev-parse origin/master }).Trim()
        Assert-Result -Name "D58 Redirect: origin/master advanced (pushed)" -Condition ($afterOriginHead -ne $beforeOriginHead) -FailureMessage "expected redirect to push the merge to origin"

        # The distinguishing behavior: redirect_target is recorded in the decision.
        $decisions = @(Get-ChildItem -Path $gateDir -Filter "F-555-*.json" | Where-Object { $_.Name -notmatch "gate_decision_.*_pending.json" })
        Assert-Result -Name "D58 Redirect: decision archived" -Condition ($decisions.Count -gt 0) -FailureMessage "expected a redirect decision file"
        $decision = Get-Content $decisions[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Result -Name "D58 Redirect: outcome recorded as redirected" -Condition ($decision.outcome -eq "redirected") -FailureMessage ("expected outcome 'redirected', got " + $decision.outcome)
        Assert-Result -Name "D58 Redirect: redirect_target recorded" -Condition ($decision.redirect_target -eq "F-556") -FailureMessage ("expected redirect_target 'F-556', got " + $decision.redirect_target)
        Assert-Result -Name "D58 Redirect: rework_requested is false" -Condition ($decision.rework_requested -eq $false) -FailureMessage "expected rework_requested false for an advancing redirect"
    }

    $results += Run-Test -Name "D59: abandon of a pre-archived task marks it Abandoned in place" -Body {
        # Symmetric to D57 reject-restore's already-archived branch: when a task was
        # archived (e.g. as Production) BEFORE the gate runs, abandon must still flip
        # the archived spec frontmatter AND the BACKLOG.md row to Abandoned rather
        # than leaving a terminal-but-wrong status. This exercises the legacy
        # already-archived branch of Invoke-HumanGateAction that had no coverage.
        $FRAMEWORK_POWERSHELL = Join-Path $REPO_ROOT "powershell"
        $caseRoot = Join-Path $tempRoot "d59-abandon-prearchived"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $originRepo = Join-Path $caseRoot "origin.git"
        $localRepo = Join-Path $caseRoot "local"

        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        Invoke-GitChecked { git -C $originRepo init --bare --initial-branch master } | Out-Null
        Invoke-GitChecked { git clone $originRepo $localRepo } | Out-Null

        "init" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        Invoke-GitChecked { git -C $localRepo add README.md } | Out-Null
        Invoke-GitChecked { git -C $localRepo commit -m "init" } | Out-Null
        Invoke-GitChecked { git -C $localRepo push origin master } | Out-Null

        $backlogDir = Join-Path $localRepo ".crucible/backlog"
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/active") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/archived") -Force | Out-Null

        $configContent = @"
paths:
  backlog: ".crucible/backlog"
"@
        $configContent | Set-Content -LiteralPath (Join-Path $localRepo ".crucible/config.yaml") -Encoding UTF8

        $specContent = @"
---
item_id: "F-444"
type: "Feature"
status: "Ready for Deploy"
priority: "P2"
target_phase: "deployment"
created_at: "2026-06-04"
---

# Test Spec F-444
"@
        $specContent | Set-Content -LiteralPath (Join-Path $backlogDir "features/active/F-444_Test_Spec.md") -Encoding UTF8

        $backlogContent = @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 1 | F-444 |
| **P3** | 0 | - |

**Status Overview**: 1 active items.

## Active Items

| ID | Priority | Status | Title | Target |
|---|---|---|---|---|
| [F-444](features/active/F-444_Test_Spec.md) | P2 | Ready for Deploy | Test Spec F-444 | Operator |
"@
        $backlogContent | Set-Content -LiteralPath (Join-Path $backlogDir "BACKLOG.md") -Encoding UTF8

        $validateScript = Join-Path $FRAMEWORK_POWERSHELL "validate-backlog.ps1"
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $validateScript -FixSummary -ProjectRoot $localRepo | Out-Null

        Invoke-GitChecked { git -C $localRepo checkout -b task/F-444 } | Out-Null
        "feature content" | Set-Content -LiteralPath (Join-Path $localRepo "feature.md") -Encoding UTF8
        Invoke-GitChecked { git -C $localRepo add feature.md } | Out-Null
        Invoke-GitChecked { git -C $localRepo commit -m "feature commit" } | Out-Null
        Invoke-GitChecked { git -C $localRepo checkout master } | Out-Null
        Invoke-GitChecked { git -C $localRepo merge --no-edit task/F-444 } | Out-Null

        # Legacy path: archive the task as Production BEFORE the gate runs.
        $archiveLibPath = Join-Path $FRAMEWORK_POWERSHELL "lib/archive-task.ps1"
        if (-not (Get-Command "Invoke-BacklogTaskArchive" -ErrorAction SilentlyContinue)) {
            . $archiveLibPath
        }
        Invoke-BacklogTaskArchive -BacklogPath (Join-Path $backlogDir "BACKLOG.md") -SpecPath (Join-Path $backlogDir "features/active/F-444_Test_Spec.md") -Status "Production" | Out-Null
        Assert-Result -Name "D59 Test: spec is pre-archived before abandon" -Condition (Test-Path (Join-Path $backlogDir "features/archived/F-444_Test_Spec.md")) -FailureMessage "expected spec to be pre-archived"

        $sessionDir = Join-Path $localRepo ".crucible/session"
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        $scriptPath = Join-Path $caseRoot "run-abandon.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'abandoned'
    GateReason = 'scope pulled; drop it'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    RepoRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-444'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
        artifacts = @('feature.md')
        session_cycle_id = 'cycle-444'
    }
}

Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
} finally {
    Pop-Location
}
"@
        $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE

        Assert-Result -Name "D59 Abandon(pre-archived): exit code is 0" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got $exitCode. Output: " + $output)

        # Spec stays archived, but status is flipped from Production to Abandoned.
        $activeSpecExists = Test-Path (Join-Path $backlogDir "features/active/F-444_Test_Spec.md")
        $archivedSpecExists = Test-Path (Join-Path $backlogDir "features/archived/F-444_Test_Spec.md")
        Assert-Result -Name "D59 Abandon(pre-archived): spec remains archived" -Condition ($archivedSpecExists -and -not $activeSpecExists) -FailureMessage "expected the pre-archived spec to stay archived"

        $specLines = Get-Content (Join-Path $backlogDir "features/archived/F-444_Test_Spec.md") -Raw
        Assert-Result -Name "D59 Abandon(pre-archived): frontmatter is Abandoned" -Condition ($specLines -match 'status:\s*"Abandoned"') -FailureMessage ("expected frontmatter status Abandoned, got: " + $specLines)

        $backlogLines = Get-Content (Join-Path $backlogDir "BACKLOG.md") -Raw
        $rowMatches = ($backlogLines -match '\[F-444\]\(features/archived/F-444_Test_Spec.md\)\s*\|\s*P2\s*\|\s*Abandoned')
        Assert-Result -Name "D59 Abandon(pre-archived): BACKLOG.md row is Abandoned" -Condition $rowMatches -FailureMessage ("expected BACKLOG.md row to show Abandoned, got: " + $backlogLines)
    }

} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed factory gate test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll factory gate tests passed." -ForegroundColor Green
exit 0
