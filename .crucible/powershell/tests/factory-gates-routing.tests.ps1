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
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-factory-gates-routing-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $results += Run-Test -Name "Resolve-FactoryTransition handles valid and invalid transitions" -Body {
        $ctx = New-TestContext -TempRoot (Join-Path $tempRoot "routing-gates") -TaskId "F-006"

        # Write dummy update-session-state.ps1
        "exit 0" | Set-Content -LiteralPath (Join-Path $ctx.FrameworkPowerShell "update-session-state.ps1") -Encoding UTF8

        # 1. Valid transition: grooming -> implementation (happy path)
        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-006"
            source_phase = "grooming"
            target_phase = "implementation"
        }
        $ctx.NextFactoryCommand = "$(Get-PwshCommand) factory.ps1"
        $ctx.IsBootstrap = $false

        $decision = Resolve-FactoryTransition -Context $ctx
        Assert-Result -Name "happy path ShouldExit" -Condition ($decision.ShouldExit -eq $false) -FailureMessage "ShouldExit was true on valid transition"
        Assert-Result -Name "happy path Transition" -Condition ($decision.Transition -eq "grooming -> implementation") -FailureMessage "Incorrect transition output"
        Assert-Result -Name "happy path NextFactoryCommand" -Condition ($decision.NextFactoryCommand -eq "$(Get-PwshCommand) factory.ps1") -FailureMessage "Incorrect NextFactoryCommand"

        # 2. Invalid transition: implementation -> done
        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-006"
            source_phase = "implementation"
            target_phase = "done"
        }
        $decision = Resolve-FactoryTransition -Context $ctx
        Assert-Result -Name "invalid path ShouldExit" -Condition ($decision.ShouldExit -eq $true) -FailureMessage "ShouldExit was false on invalid transition"
        Assert-Result -Name "invalid path ExitCode" -Condition ($decision.ExitCode -eq 2) -FailureMessage "Incorrect exit code on invalid transition"

        # 3. Done transition: deployment -> done
        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-006"
            source_phase = "deployment"
            target_phase = "done"
        }
        $decision = Resolve-FactoryTransition -Context $ctx
        Assert-Result -Name "done path ShouldExit" -Condition ($decision.ShouldExit -eq $true) -FailureMessage "ShouldExit was false on done transition"
        Assert-Result -Name "done path ExitCode" -Condition ($decision.ExitCode -eq 0) -FailureMessage "Incorrect exit code on done transition"
    }

    $results += Run-Test -Name "D39: concurrent Groomer warning filters archived and terminal tasks" -Body {
        $caseRoot = Join-Path $tempRoot "d39-test"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-101"

        # Create session directories
        $sessionDir = $ctx.SessionDir
        $activeGroomerSessionDir = Join-Path $sessionDir "F-102/grooming"
        $archivedGroomerSessionDir = Join-Path $sessionDir "archived/stale-task-sessions/F-103/grooming"
        $terminalGroomerSessionDir = Join-Path $sessionDir "F-104/grooming"

        New-Item -ItemType Directory -Path $activeGroomerSessionDir, $archivedGroomerSessionDir, $terminalGroomerSessionDir -Force | Out-Null

        # Create task.md files
        "task" | Set-Content -Path (Join-Path $activeGroomerSessionDir "task.md") -Encoding UTF8
        "task" | Set-Content -Path (Join-Path $archivedGroomerSessionDir "task.md") -Encoding UTF8
        "task" | Set-Content -Path (Join-Path $terminalGroomerSessionDir "task.md") -Encoding UTF8

        # Create BACKLOG.md with F-104 as terminal, F-101 and F-102 as active
        $backlogDir = $ctx.BacklogDir
        $backlogFile = Join-Path $backlogDir "BACKLOG.md"
        @"
| ID | Title | Status |
|---|---|---|
| [F-101](features/active/F-101_test.md) | Test 1 | Ready |
| [F-102](features/active/F-102_test.md) | Test 2 | Ready |
| [F-104](features/active/F-104_test.md) | Test 4 | Production |
"@ | Set-Content -Path $backlogFile -Encoding UTF8

        # 1. First test: we are transitioning to grooming for F-101.
        # F-102 is active and not terminal, so it SHOULD warn about F-102.
        # F-103 is under archived/ and F-104 is terminal in BACKLOG.md, so they should NOT be warned about.
        $ctx.Handoff = [PSCustomObject]@{
            task_id = "F-101"
            source_phase = "research"
            target_phase = "grooming"
        }
        $ctx.NextFactoryCommand = "$(Get-PwshCommand) factory.ps1"
        $ctx.IsBootstrap = $false

        $logOutput = & { Resolve-FactoryTransition -Context $ctx } 6>&1
        $logText = $logOutput -join "`n"

        Assert-Result -Name "Warning emitted for active task F-102" -Condition ($logText -match "F-102[/\\]grooming[/\\]task\.md") -FailureMessage "expected warning for F-102, got: $logText"
        Assert-Result -Name "No warning for archived task F-103" -Condition ($logText -notmatch "F-103") -FailureMessage "unexpected warning for archived task F-103, got: $logText"
        Assert-Result -Name "No warning for terminal task F-104" -Condition ($logText -notmatch "F-104") -FailureMessage "unexpected warning for terminal task F-104, got: $logText"
    }

    $results += Run-Test -Name "D44: auto-finalization on accept/push path when backlog is non-terminal" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "d44-auto-archive-test"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        # 1. Setup a fake git repository structure
        $originRepo = Join-Path $caseRoot "remote_origin"
        $localRepo = Join-Path $caseRoot "local_repo"
        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        # Initialize origin repo
        git -C $originRepo init --bare --initial-branch=master 2>$null | Out-Null

        # Initialize local repo
        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"
        git -C $localRepo remote add origin $originRepo

        # Create initial commit
        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        git -C $localRepo push -u origin master 2>$null | Out-Null

        # Create backlog structure under local_repo (so CWD equals project root)
        $backlogDir = Join-Path $localRepo ".crucible/backlog"
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "chores/active") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "chores/archived") -Force | Out-Null

        # Write .crucible/config.yaml
        $configContent = @"
paths:
  backlog: ".crucible/backlog"
"@
        $configContent | Set-Content -LiteralPath (Join-Path $localRepo ".crucible/config.yaml") -Encoding UTF8

        # Create active spec file
        $specContent = @"
---
item_id: "C-999"
type: "Chore"
status: "Ready for Deploy"
priority: "P2"
target_phase: "deployment"
created_at: "2026-05-25"
---

# Test Spec
"@
        $specContent | Set-Content -LiteralPath (Join-Path $backlogDir "chores/active/C-999_Test_Spec.md") -Encoding UTF8

        # Create BACKLOG.md
        $backlogContent = @"
# Backlog

## Active Items

| ID | Status | Title | Target |
|---|---|---|---|
| [C-999](chores/active/C-999_Test_Spec.md) | Ready for Deploy | Test Spec | Operator |
"@
        $backlogContent | Set-Content -LiteralPath (Join-Path $backlogDir "BACKLOG.md") -Encoding UTF8

        # Simulate local merge on task branch
        git -C $localRepo checkout -b task/C-999 2>$null | Out-Null
        "chore work" | Set-Content -LiteralPath (Join-Path $localRepo "chore.md") -Encoding UTF8
        git -C $localRepo add chore.md 2>$null | Out-Null
        git -C $localRepo commit -m "chore commit" 2>$null | Out-Null

        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo merge --no-edit task/C-999 2>$null | Out-Null

        # Setup context structure
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        $scriptPath = Join-Path $caseRoot "run-d44.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")

        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'accepted'
    GateReason = 'work looks beautiful'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    RepoRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'C-999'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
    }
}

Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_ACCEPT"
} catch {
    Write-Host "FAILED: `$_"
} finally {
    Pop-Location
}
"@
        $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "D44: human gate accept with auto-archive exits successfully" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)

        # Verify task is now finalized
        # 1. Spec moved to archived/
        $activeExists = Test-Path -LiteralPath (Join-Path $backlogDir "chores/active/C-999_Test_Spec.md")
        $archivedExists = Test-Path -LiteralPath (Join-Path $backlogDir "chores/archived/C-999_Test_Spec.md")
        Assert-Result -Name "D44: active spec removed" -Condition (-not $activeExists) -FailureMessage "expected active spec to be removed"
        Assert-Result -Name "D44: archived spec created" -Condition ($archivedExists) -FailureMessage "expected archived spec to be created"

        # 2. Spec frontmatter status is Resolved
        $fmStr = [string](Get-Content -LiteralPath (Join-Path $backlogDir "chores/archived/C-999_Test_Spec.md") -Head 15 -Encoding UTF8)
        $specStatus = ""
        if ($fmStr -match 'status:\s*["'']?([^"''\s\r\n]+)"?') { $specStatus = $matches[1] }
        Assert-Result -Name "D44: archived spec status is Resolved" -Condition ($specStatus -eq "Resolved") -FailureMessage ("expected spec status 'Resolved', got " + $specStatus)

        # 3. BACKLOG.md is updated to Resolved and path is archived/
        $backlogLines = Get-Content -LiteralPath (Join-Path $backlogDir "BACKLOG.md") -Encoding UTF8
        $rowLine = ""
        foreach ($line in $backlogLines) {
            if ($line -match 'C-999') { $rowLine = $line; break }
        }
        Assert-Result -Name "D44: BACKLOG.md row updated" -Condition ($rowLine -match 'chores/archived/C-999_Test_Spec.md' -and $rowLine -match 'Resolved') -FailureMessage ("expected row to show archived path and Resolved, got: " + $rowLine)
    }

    $results += Run-Test -Name "D44: terminal-state check resolves correctly with -ProjectRoot from a different CWD" -Body {
        $caseRoot = Join-Path $tempRoot "d44-project-root-cwd-test"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $adopterRepo = Join-Path $caseRoot "adopter_repo"
        New-Item -ItemType Directory -Path $adopterRepo -Force | Out-Null

        # Setup backlog structure under adopter_repo
        $backlogDir = Join-Path $adopterRepo ".crucible/backlog"
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "chores/active") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "chores/archived") -Force | Out-Null

        # Write config.yaml in adopter repo
        $configContent = @"
paths:
  backlog: ".crucible/backlog"
"@
        $configContent | Set-Content -LiteralPath (Join-Path $adopterRepo ".crucible/config.yaml") -Encoding UTF8

        # Create active spec file in adopter repo
        $specContent = @"
---
item_id: "C-888"
type: "Chore"
status: "Ready for Deploy"
priority: "P2"
target_phase: "deployment"
created_at: "2026-05-25"
---

# Test Spec C-888
"@
        $specContent | Set-Content -LiteralPath (Join-Path $backlogDir "chores/active/C-888_Test_Spec.md") -Encoding UTF8

        # Create BACKLOG.md in adopter repo
        $backlogContent = @"
# Backlog

## Active Items

| ID | Status | Title | Target |
|---|---|---|---|
| [C-888](chores/active/C-888_Test_Spec.md) | Ready for Deploy | Test Spec C-888 | Operator |
"@
        $backlogContent | Set-Content -LiteralPath (Join-Path $backlogDir "BACKLOG.md") -Encoding UTF8

        # Call helper functions in a PowerShell subprocess from a different CWD (tempRoot)
        $scriptPath = Join-Path $caseRoot "run-cwd-test.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")

        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
`$FRAMEWORK_POWERSHELL = '$(Split-Path -Parent $FACTORY_LIB)'
. '$libPath'

`$resBefore = Get-TaskFinalizationDetails -TaskId 'C-888' -ProjectRoot '$adopterRepo'
Write-Host "BEFORE_FINALIZED: `$(`$resBefore.IsFinalized)"
Write-Host "BEFORE_ACTIVE: `$(`$resBefore.SpecExistsInActive)"

# Perform archival using Get-BacklogItemPathForTaskProjectRoot
`$activePath = Get-BacklogItemPathForTaskProjectRoot -Task 'C-888' -ProjectRoot '$adopterRepo'
Write-Host "ACTIVE_PATH: `$activePath"

# Load archive-task helper from framework path
`$archiveLibPath = Join-Path `$FRAMEWORK_POWERSHELL "lib/archive-task.ps1"
. `$archiveLibPath

Invoke-BacklogTaskArchive -BacklogPath '$(Join-Path $backlogDir "BACKLOG.md")' -SpecPath `$activePath | Out-Null

`$resAfter = Get-TaskFinalizationDetails -TaskId 'C-888' -ProjectRoot '$adopterRepo'
Write-Host "AFTER_FINALIZED: `$(`$resAfter.IsFinalized)"
Write-Host "AFTER_ARCHIVED: `$(`$resAfter.SpecExistsInArchived)"
"@
        $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        # Run script from tempRoot (which is NOT the adopterRepo or localRepo)
        $exitCode = 0
        $outputLines = @()
        Push-Location $tempRoot
        try {
            $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $output = $outputLines -join "`n"
        Assert-Result -Name "D44: cwd-independent test runs successfully" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "D44: check before was not finalized" -Condition ($output -match "BEFORE_FINALIZED: False") -FailureMessage "expected not finalized before"
        Assert-Result -Name "D44: active spec found before" -Condition ($output -match "BEFORE_ACTIVE: True") -FailureMessage "expected active spec true before"
        Assert-Result -Name "D44: check after is finalized" -Condition ($output -match "AFTER_FINALIZED: True") -FailureMessage "expected finalized after"
        Assert-Result -Name "D44: archived spec found after" -Condition ($output -match "AFTER_ARCHIVED: True") -FailureMessage "expected archived spec true after"
    }

    $results += Run-Test -Name "D44: deployment Complete-FactorySourceSession blocks if backlog not terminal" -Body {
        $caseRoot = Join-Path $tempRoot "d44-complete-session-test"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $caseRoot ".crucible") -Force | Out-Null

        # Setup backlog structure under caseRoot
        $backlogDir = Join-Path $caseRoot "backlog"
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "chores/active") -Force | Out-Null

        # Write config.yaml
        $configContent = @"
paths:
  backlog: "backlog"
"@
        $configContent | Set-Content -LiteralPath (Join-Path $caseRoot ".crucible/config.yaml") -Encoding UTF8

        # Create active spec file
        $specContent = @"
---
item_id: "C-777"
type: "Chore"
status: "Ready for Deploy"
priority: "P2"
target_phase: "deployment"
created_at: "2026-05-25"
---

# Test Spec C-777
"@
        $specContent | Set-Content -LiteralPath (Join-Path $backlogDir "chores/active/C-777_Test_Spec.md") -Encoding UTF8

        # Create BACKLOG.md
        $backlogContent = @"
# Backlog

## Active Items

| ID | Status | Title | Target |
|---|---|---|---|
| [C-777](chores/active/C-777_Test_Spec.md) | Ready for Deploy | Test Spec C-777 | Operator |
"@
        $backlogContent | Set-Content -LiteralPath (Join-Path $backlogDir "BACKLOG.md") -Encoding UTF8

        $sessionDir = Join-Path $caseRoot "session"
        $taskSessionDir = Join-Path $sessionDir "C-777/deployment"
        New-Item -ItemType Directory -Path $taskSessionDir -Force | Out-Null

        # Write task.md
        $taskMd = @"
## Task List
- [x] Merge task/C-777
- [x] Run archive-task.ps1
"@
        $taskMd | Set-Content -LiteralPath (Join-Path $taskSessionDir "task.md") -Encoding UTF8

        $logFile = Join-Path $caseRoot "session/global/event_log.json"
        $cbHistoryFile = Join-Path $caseRoot "session/global/circuit_breakers.json"
        New-Item -ItemType Directory -Path (Split-Path -Parent $logFile) -Force | Out-Null
        "[]" | Set-Content -LiteralPath $logFile -Encoding UTF8
        "[]" | Set-Content -LiteralPath $cbHistoryFile -Encoding UTF8

        # Write a dummy accepted gate decision to simulate that the gate has passed
        $gateDecisionsDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDecisionsDir -Force | Out-Null
        $decisionJson = @{
            task_id = "C-777"
            outcome = "accepted"
        } | ConvertTo-Json
        $decisionJson | Set-Content -LiteralPath (Join-Path $gateDecisionsDir "C-777-20260603T120000Z.json") -Encoding UTF8

        $scriptPath = Join-Path $caseRoot "run-session-test.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")

        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    RepoRoot = '$caseRoot'
    BacklogDir = '$backlogDir'
    SessionDir = '$sessionDir'
    LogFile = '$($logFile.Replace("'", "''"))'
    CircuitBreakerHistoryFile = '$($cbHistoryFile.Replace("'", "''"))'
    Quiet = `$true
    Ceiling = 10
    Handoff = [PSCustomObject]@{
        task_id = 'C-777'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
        budget_tier = 'low'
    }
}

Complete-FactorySourceSession -Context `$ctx
"@
        $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        # Run script - it should exit with 2 because task is not finalized
        $exitCode = 0
        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        Assert-Result -Name "D44: complete session exits with 2 when not finalized" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit code 2, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "D44: complete session outputs quality gate failed message" -Condition ($output -match "Quality gate failed:") -FailureMessage "expected quality gate failed error message"
    }

    $results += Run-Test -Name "D45: accept with un-locatable active spec withholds the push" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "d45-missing-spec-test"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $originRepo = Join-Path $caseRoot "remote_origin"
        $localRepo = Join-Path $caseRoot "local_repo"
        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        git -C $originRepo init --bare --initial-branch=master 2>$null | Out-Null
        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"
        git -C $localRepo remote add origin $originRepo

        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        git -C $localRepo push -u origin master 2>$null | Out-Null

        # Save origin master head commit hash
        $beforeOriginHead = (git -C $localRepo rev-parse origin/master).Trim()

        # Create backlog structure under local_repo, but do NOT create the active spec file (it is missing)
        $backlogDir = Join-Path $localRepo ".crucible/backlog"
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "chores/active") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "chores/archived") -Force | Out-Null

        $configContent = @"
paths:
  backlog: ".crucible/backlog"
"@
        $configContent | Set-Content -LiteralPath (Join-Path $localRepo ".crucible/config.yaml") -Encoding UTF8

        # Create BACKLOG.md pointing to the missing active spec file
        $backlogContent = @"
# Backlog

## Active Items

| ID | Status | Title | Target |
|---|---|---|---|
| [C-998](chores/active/C-998_Test_Spec.md) | Ready for Deploy | Test Spec C-998 | Operator |
"@
        $backlogContent | Set-Content -LiteralPath (Join-Path $backlogDir "BACKLOG.md") -Encoding UTF8

        git -C $localRepo checkout -b task/C-998 2>$null | Out-Null
        "chore work" | Set-Content -LiteralPath (Join-Path $localRepo "chore.md") -Encoding UTF8
        git -C $localRepo add chore.md 2>$null | Out-Null
        git -C $localRepo commit -m "chore commit" 2>$null | Out-Null

        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo merge --no-edit task/C-998 2>$null | Out-Null

        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        $scriptPath = Join-Path $caseRoot "run-d45-1.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")

        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'accepted'
    GateReason = 'work looks beautiful'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    RepoRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'C-998'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
    }
}

Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_ACCEPT"
} catch {
    Write-Host "FAILED: `$_"
} finally {
    Pop-Location
}
"@
        $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        # Assertions
        Assert-Result -Name "D45-1: human gate accept with missing spec fails with exit code 2" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit code 2, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "D45-1: outputs refusing to push message" -Condition ($output -match "refusing to push" -and $output -match "Auto-finalization failed") -FailureMessage ("expected refusing to push and Auto-finalization failed messages. Got: " + $output)

        # Verify push did not happen (origin/master still points to $beforeOriginHead)
        $afterOriginHead = (git -C $localRepo rev-parse origin/master).Trim()
        Assert-Result -Name "D45-1: push did not occur" -Condition ($beforeOriginHead -eq $afterOriginHead) -FailureMessage ("expected origin master tip to remain " + $beforeOriginHead + ", but it advanced to " + $afterOriginHead)
    }

    $results += Run-Test -Name "D45: archival throw withholds the push" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "d45-archival-throw-test"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $originRepo = Join-Path $caseRoot "remote_origin"
        $localRepo = Join-Path $caseRoot "local_repo"
        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        git -C $originRepo init --bare --initial-branch=master 2>$null | Out-Null
        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"
        git -C $localRepo remote add origin $originRepo

        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        git -C $localRepo push -u origin master 2>$null | Out-Null

        # Save origin master head commit hash
        $beforeOriginHead = (git -C $localRepo rev-parse origin/master).Trim()

        # Create backlog structure under local_repo
        $backlogDir = Join-Path $localRepo ".crucible/backlog"
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "chores/active") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $backlogDir "chores/archived") -Force | Out-Null

        $configContent = @"
paths:
  backlog: ".crucible/backlog"
"@
        $configContent | Set-Content -LiteralPath (Join-Path $localRepo ".crucible/config.yaml") -Encoding UTF8

        # Create active spec file
        $specContent = @"
---
item_id: "C-997"
type: "Chore"
status: "Ready for Deploy"
priority: "P2"
target_phase: "deployment"
created_at: "2026-05-25"
---

# Test Spec
"@
        $specContent | Set-Content -LiteralPath (Join-Path $backlogDir "chores/active/C-997_Test_Spec.md") -Encoding UTF8

        # Pre-create the destination archived file to force archival to throw "Archived spec already exists"
        "already archived content" | Set-Content -LiteralPath (Join-Path $backlogDir "chores/archived/C-997_Test_Spec.md") -Encoding UTF8

        # Create BACKLOG.md
        $backlogContent = @"
# Backlog

## Active Items

| ID | Status | Title | Target |
|---|---|---|---|
| [C-997](chores/active/C-997_Test_Spec.md) | Ready for Deploy | Test Spec C-997 | Operator |
"@
        $backlogContent | Set-Content -LiteralPath (Join-Path $backlogDir "BACKLOG.md") -Encoding UTF8

        git -C $localRepo checkout -b task/C-997 2>$null | Out-Null
        "chore work" | Set-Content -LiteralPath (Join-Path $localRepo "chore.md") -Encoding UTF8
        git -C $localRepo add chore.md 2>$null | Out-Null
        git -C $localRepo commit -m "chore commit" 2>$null | Out-Null

        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo merge --no-edit task/C-997 2>$null | Out-Null

        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        $scriptPath = Join-Path $caseRoot "run-d45-2.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")

        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'accepted'
    GateReason = 'work looks beautiful'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    RepoRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'C-997'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
    }
}

Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_ACCEPT"
} catch {
    Write-Host "FAILED: `$_"
} finally {
    Pop-Location
}
"@
        $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"

        # Assertions
        Assert-Result -Name "D45-2: human gate accept with archival throw fails with exit code 2" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit code 2, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "D45-2: outputs refusing to push and archival failed messages" -Condition ($output -match "refusing to push" -and $output -match "Archived spec already exists") -FailureMessage ("expected refusing to push and Archived spec already exists messages. Got: " + $output)

        # Verify push did not happen (origin/master still points to $beforeOriginHead)
        $afterOriginHead = (git -C $localRepo rev-parse origin/master).Trim()
        Assert-Result -Name "D45-2: push did not occur" -Condition ($beforeOriginHead -eq $afterOriginHead) -FailureMessage ("expected origin master tip to remain " + $beforeOriginHead + ", but it advanced to " + $afterOriginHead)
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
