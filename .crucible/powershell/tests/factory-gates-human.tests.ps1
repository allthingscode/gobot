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

function New-FakeGhForGate {
    param(
        [Parameter(Mandatory=$true)][string]$Dir,
        [Parameter(Mandatory=$true)][string]$Mode
    )
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $impl = Join-Path $Dir "gh-impl.ps1"
    $safeMode = $Mode.Replace("'", "''")
    (@"
`$Mode = '$safeMode'
`$verb = ""
if (`$args.Count -ge 2) { `$verb = `$args[0] + " " + `$args[1] }
if (`$verb -eq "auth status") {
    if (`$Mode -eq "unauth") { exit 1 }
    exit 0
}
if (`$verb -eq "run list") {
    if (`$Mode -eq "green") { Write-Output '[{"databaseId":201,"status":"completed","conclusion":"success"}]' }
    if (`$Mode -eq "red") { Write-Output '[{"databaseId":202,"status":"completed","conclusion":"failure"}]' }
    if (`$Mode -eq "pending") { Write-Output '[{"databaseId":203,"status":"in_progress","conclusion":null}]' }
    exit 0
}
if (`$verb -eq "run view") {
    Write-Output '{"jobs":[{"name":"windows-ci","conclusion":"failure"}]}'
    exit 0
}
exit 1
"@ -replace "`r`n", "`n") | Set-Content -LiteralPath $impl -Encoding ASCII

    $hostCmd = (Get-PwshCommand)
    if (Test-PlatformIsWindows) {
        $path = Join-Path $Dir "gh.cmd"
        @(
            '@echo off',
            ('"' + $hostCmd + '" -NoProfile -ExecutionPolicy Bypass -File "%~dp0gh-impl.ps1" %*'),
            'exit /b %errorlevel%'
        ) | Set-Content -LiteralPath $path -Encoding ASCII
    } else {
        $path = Join-Path $Dir "gh"
        (@"
#!/usr/bin/env bash
exec $hostCmd -NoProfile -ExecutionPolicy Bypass -File "`$(dirname "`$0")/gh-impl.ps1" "`$@"
"@ -replace "`r`n", "`n") | Set-Content -LiteralPath $path -Encoding ASCII
        & chmod "+x" $path
    }
    return $path
}

function New-CiGateCase {
    param(
        [Parameter(Mandatory=$true)][string]$CaseRoot,
        [Parameter(Mandatory=$true)][string]$TaskId
    )
    $originRepo = Join-Path $CaseRoot "remote_origin"
    $localRepo = Join-Path $CaseRoot "local_repo"
    New-Item -ItemType Directory -Path $originRepo, $localRepo -Force | Out-Null

    git -C $originRepo init --bare --initial-branch=master 2>$null | Out-Null
    git -C $localRepo init --initial-branch=master 2>$null | Out-Null
    git -C $localRepo config user.name "Tester"
    git -C $localRepo config user.email "test@example.com"
    git -C $localRepo remote add origin $originRepo

    "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
    git -C $localRepo add README.md 2>$null | Out-Null
    git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
    git -C $localRepo push -u origin master 2>$null | Out-Null

    git -C $localRepo checkout -b "task/$TaskId" 2>$null | Out-Null
    "feature" | Set-Content -LiteralPath (Join-Path $localRepo "feature.md") -Encoding UTF8
    git -C $localRepo add feature.md 2>$null | Out-Null
    git -C $localRepo commit -m "feature commit" 2>$null | Out-Null

    git -C $localRepo checkout master 2>$null | Out-Null

    $configDir = Join-Path $localRepo ".crucible"
    $sessionDir = Join-Path $configDir "session"
    New-Item -ItemType Directory -Path $configDir, (Join-Path $sessionDir "global/gate_decisions") -Force | Out-Null
    $configYaml = @"
project:
  name: Fake
  description: Fake
  default_branch: master
roles:
  researcher:  { model_tier: fast }
  groomer:     { model_tier: fast }
  architect:   { model_tier: high-capability }
  reviewer:    { model_tier: high-capability }
  operator:    { model_tier: fast }
verification:
  quick:
    - name: test
      command: echo quick
  full:
    - name: test
      command: echo full
project_mandates:
  - rules
review:
  auto_push: true
  require_green_ci: true
  ci_timeout_minutes: 1
"@
    $configYaml | Set-Content -LiteralPath (Join-Path $configDir "config.yaml") -Encoding UTF8

    return [pscustomobject]@{
        LocalRepo = $localRepo
        SessionDir = $sessionDir
    }
}

function Invoke-CiGateCase {
    param(
        [Parameter(Mandatory=$true)]$Case,
        [Parameter(Mandatory=$true)][string]$TaskId
    )
    $scriptPath = Join-Path (Split-Path -Parent $Case.LocalRepo) ("run-" + $TaskId + ".ps1")
    $libPath = $FACTORY_LIB.Replace("'", "''")
    $localRepo = $Case.LocalRepo.Replace("'", "''")
    $sessionDir = $Case.SessionDir.Replace("'", "''")
    $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'accepted'
    GateReason = 'ci gate coverage'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = '$TaskId'
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
    exit 1
} finally {
    Pop-Location
}
"@
    $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8
    $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($outputLines -join "`n")
    }
}
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-factory-gates-human-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $results += Run-Test -Name "Invoke-HumanGate D22 regression: gate push and reset behavior" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "d22-regression"
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

        # Create a commit on origin
        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        git -C $localRepo push -u origin master 2>$null | Out-Null

        # 2. Simulate local merge on task branch
        git -C $localRepo checkout -b task/F-999 2>$null | Out-Null
        "feature work" | Set-Content -LiteralPath (Join-Path $localRepo "feature.md") -Encoding UTF8
        git -C $localRepo add feature.md 2>$null | Out-Null
        git -C $localRepo commit -m "feature commit" 2>$null | Out-Null
        $featureSha = (git -C $localRepo rev-parse HEAD).Trim()

        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo merge --no-edit task/F-999 2>$null | Out-Null

        $localCommits = @(git -C $localRepo log origin/master..master --oneline)
        Assert-Result -Name "D22: local master ahead of origin before gate" -Condition ($localCommits.Count -gt 0) -FailureMessage "expected local master to be ahead of origin"

        # 3. Setup context structure
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        $configDir = Join-Path $localRepo ".crucible"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $configYaml = @"
project:
  name: Fake Project
  description: Fake description
  default_branch: master
roles:
  researcher:  { model_tier: fast }
  groomer:     { model_tier: fast }
  architect:   { model_tier: high-capability }
  reviewer:    { model_tier: high-capability }
  operator:    { model_tier: fast }
verification:
  quick:
    - name: test
      command: echo quick
  full:
    - name: test
      command: echo full
project_mandates:
  - rules
review:
  auto_push: true
"@
        $configYaml | Set-Content -LiteralPath (Join-Path $configDir "config.yaml") -Encoding UTF8

        $scriptPath = Join-Path $caseRoot "run-d22.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")

        # Test Case 1: Accepted outcome -> should push changes to origin
        $scriptContentAccept = @"
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
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-999'
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
        $scriptContentAccept | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $exitCode = $LASTEXITCODE
        $output = $outputLines -join "`n"
        Assert-Result -Name "D22: human gate accepted exits successfully" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode + ". Output: " + $output)

        $behindCommits = @(git -C $localRepo log origin/master..master --oneline)
        Assert-Result -Name "D22: git push succeeded on accept" -Condition ($behindCommits.Count -eq 0) -FailureMessage "origin/master is still behind master after acceptance"

        # Test Case 2: Rejected outcome -> should unwind local merge and restore task branch
        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo reset --hard HEAD~1 2>$null | Out-Null
        git -C $originRepo update-ref refs/heads/master HEAD~1 2>$null | Out-Null
        git -C $localRepo fetch origin master 2>$null | Out-Null
        git -C $localRepo branch task/F-999 $featureSha 2>$null | Out-Null
        git -C $localRepo merge --no-edit task/F-999 2>$null | Out-Null

        $behindCommits2 = @(git -C $localRepo log origin/master..master --oneline)
        Assert-Result -Name "D22: local master ahead before reject" -Condition ($behindCommits2.Count -gt 0) -FailureMessage "expected master to be ahead again"

        git -C $localRepo branch -D task/F-999 2>$null | Out-Null

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
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-999'
        source_phase = 'deployment'
        target_phase = 'implementation'
        cumulative_handoff_count = 1
    }
}

Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_REJECT"
} catch {
    Write-Host "FAILED: `$_"
} finally {
    Pop-Location
}
"@
        $scriptContentReject | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        $outputLines2 = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $exitCode2 = $LASTEXITCODE
        $output2 = $outputLines2 -join "`n"
        Assert-Result -Name "D22: human gate rejected exits successfully" -Condition ($exitCode2 -eq 0) -FailureMessage ("expected exit code 0, got " + $exitCode2 + ". Output: " + $output2)

        $behindCommits3 = @(git -C $localRepo log origin/master..master --oneline)
        Assert-Result -Name "D22: local merge was unwound on reject" -Condition ($behindCommits3.Count -eq 0) -FailureMessage "master is still ahead of origin/master after reject"

        git -C $localRepo show-ref --quiet refs/heads/task/F-999
        Assert-Result -Name "D22: task branch was restored on reject" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "task branch task/F-999 was not restored"
    }

    $results += Run-Test -Name "Invoke-HumanGate D37: push behavior with benign git stderr and failures" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "d37-testing"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        # 1. Setup origin & local repo
        $originRepo = Join-Path $caseRoot "remote_origin"
        $localRepo = Join-Path $caseRoot "local_repo"
        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        git -C $originRepo init --bare --initial-branch=master 2>$null | Out-Null
        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"
        git -C $localRepo remote add origin $originRepo

        # Initial commit
        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        git -C $localRepo push -u origin master 2>$null | Out-Null

        # Setup context structure
        $sessionDir = Join-Path $localRepo ".crucible/session"
        $configDir = Join-Path $localRepo ".crucible"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $configYaml = @"
project:
  name: Fake
  description: Fake
  default_branch: master
roles:
  researcher:  { model_tier: fast }
  groomer:     { model_tier: fast }
  architect:   { model_tier: high-capability }
  reviewer:    { model_tier: high-capability }
  operator:    { model_tier: fast }
verification:
  quick:
    - name: test
      command: echo quick
  full:
    - name: test
      command: echo full
project_mandates:
  - rules
review:
  auto_push: true
"@
        $configYaml | Set-Content -LiteralPath (Join-Path $configDir "config.yaml") -Encoding UTF8
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        $pendingFile = Join-Path $sessionDir "F-100/gate_pending.txt"
        $legacyPendingFile = Join-Path $gateDir "gate_decision_F-100_pending.json"

        # Helper to re-create pending files
        function Reset-PendingFiles {
            New-Item -ItemType Directory -Path $gateDir, (Join-Path $sessionDir "F-100") -Force | Out-Null
            "pending" | Set-Content -LiteralPath $pendingFile -Encoding UTF8
            "legacy-pending" | Set-Content -LiteralPath $legacyPendingFile -Encoding UTF8
        }

        $scriptPath = Join-Path $caseRoot "run-d37.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")

        # Test Case 1: Accept with no-op push
        Reset-PendingFiles
        $scriptAcceptNoOp = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'accepted'
    GateReason = 'verification of acceptance criteria passed'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-100'
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
    exit 1
} finally {
    Pop-Location
}
"@
        $scriptAcceptNoOp | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $output -join "`n"

        Assert-Result -Name "D37: no-op accept push exits 0" -Condition ($exitCode -eq 0) -FailureMessage "expected exit code 0, got $exitCode. Output:`n$outputText"
        Assert-Result -Name "D37: new pending file removed" -Condition (-not (Test-Path $pendingFile)) -FailureMessage "new pending file still exists"
        Assert-Result -Name "D37: legacy pending file removed" -Condition (-not (Test-Path $legacyPendingFile)) -FailureMessage "legacy pending file still exists"

        # Test Case 2: Redirect with no-op push
        Reset-PendingFiles
        $scriptRedirectNoOp = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'redirected'
    GateReason = 'redirect to new'
    GateRedirectTarget = 'F-101'
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-100'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_REDIRECT"
} catch {
    Write-Host "FAILED: `$_"
    exit 1
} finally {
    Pop-Location
}
"@
        $scriptRedirectNoOp | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $output -join "`n"

        Assert-Result -Name "D37: no-op redirect push exits 0" -Condition ($exitCode -eq 0) -FailureMessage "expected exit code 0, got $exitCode. Output:`n$outputText"
        Assert-Result -Name "D37: redirected new pending file removed" -Condition (-not (Test-Path $pendingFile)) -FailureMessage "new pending file still exists"
        Assert-Result -Name "D37: redirected legacy pending file removed" -Condition (-not (Test-Path $legacyPendingFile)) -FailureMessage "legacy pending file still exists"

        # Test Case 3: Real successful push (1 commit ahead)
        git -C $localRepo checkout master 2>$null | Out-Null
        "update" | Set-Content -LiteralPath (Join-Path $localRepo "update.txt") -Encoding UTF8
        git -C $localRepo add update.txt 2>$null | Out-Null
        git -C $localRepo commit -m "second commit" 2>$null | Out-Null

        Reset-PendingFiles
        $scriptRealPush = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'accepted'
    GateReason = 'commit push verification'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-100'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_REAL_PUSH"
} catch {
    Write-Host "FAILED: `$_"
    exit 1
} finally {
    Pop-Location
}
"@
        $scriptRealPush | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $output -join "`n"

        Assert-Result -Name "D37: real successful push exits 0" -Condition ($exitCode -eq 0) -FailureMessage "expected exit code 0, got $exitCode. Output:`n$outputText"
        Assert-Result -Name "D37: real successful push does not emit error records" -Condition ($outputText -notlike "*NativeCommandError*" -and $outputText -notlike "*WriteErrorException*") -FailureMessage "successful push emitted error record. Output:`n$outputText"
        Assert-Result -Name "D37: real push pending file removed" -Condition (-not (Test-Path $pendingFile)) -FailureMessage "new pending file still exists"

        # Verify remote origin now matches local master
        $behindCommits = @(git -C $localRepo log origin/master..master --oneline)
        Assert-Result -Name "D37: push landed on origin" -Condition ($behindCommits.Count -eq 0) -FailureMessage "origin/master did not catch up"

        # Test Case 4: Failing push (invalid remote / remote ref)
        git -C $localRepo remote set-url origin "https://example.invalid/repo.git"
        Reset-PendingFiles
        $scriptFailedPush = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'accepted'
    GateReason = 'this should fail push'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-100'
        source_phase = 'deployment'
        target_phase = 'done'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_UNEXPECTED"
} catch {
    Write-Host "FAILED: `$_"
    exit 1
} finally {
    Pop-Location
}
"@
        $scriptFailedPush | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $output -join "`n"

        # Check that it exited 1 due to push failure
        Assert-Result -Name "D37: failed push exits 1" -Condition ($exitCode -eq 1) -FailureMessage "expected exit code 1, got $exitCode. Output:`n$outputText"
        Assert-Result -Name "D37: failed push surfaces git error text" -Condition ($outputText -like "*fatal:*" -or $outputText -like "*error:*") -FailureMessage "failed push did not surface git error. Output:`n$outputText"
        Assert-Result -Name "D37: failed push keeps pending files" -Condition (Test-Path $pendingFile) -FailureMessage "pending file was cleaned up on failure"

        # Test Case 5: Reject/Abandon branch unwinding
        # Restore a valid remote origin
        git -C $localRepo remote set-url origin $originRepo

        # Simulate local merge on task branch
        git -C $localRepo checkout -b task/F-100 2>$null | Out-Null
        "rwork" | Set-Content -LiteralPath (Join-Path $localRepo "rwork.txt") -Encoding UTF8
        git -C $localRepo add rwork.txt 2>$null | Out-Null
        git -C $localRepo commit -m "rework commit" 2>$null | Out-Null
        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo merge --no-edit task/F-100 2>$null | Out-Null

        # Remove task branch first to test restoration
        git -C $localRepo branch -D task/F-100 2>$null | Out-Null

        Reset-PendingFiles
        $scriptReject = @"
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
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-100'
        source_phase = 'deployment'
        target_phase = 'implementation'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
    Write-Host "PASSED_REJECT"
} catch {
    Write-Host "FAILED: `$_"
    exit 1
} finally {
    Pop-Location
}
"@
        $scriptReject | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = $output -join "`n"

        Assert-Result -Name "D37: reject unwinds merge and exits 0" -Condition ($exitCode -eq 0) -FailureMessage "expected exit code 0 on reject, got $exitCode. Output:`n$outputText"
        # Confirm branch task/F-100 exists
        git -C $localRepo show-ref --quiet refs/heads/task/F-100
        Assert-Result -Name "D37: reject restored task branch" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "task/F-100 branch was not restored"
    }

    $results += Run-Test -Name "D22 follow-up: unwind merge resets to pre-merge tip, preserving unrelated commit" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "d22-followup"
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

        # Create an unrelated local commit on master that is unpushed
        "unrelated" | Set-Content -LiteralPath (Join-Path $localRepo "unrelated.md") -Encoding UTF8
        git -C $localRepo add unrelated.md 2>$null | Out-Null
        git -C $localRepo commit -m "unrelated commit" 2>$null | Out-Null
        $unrelatedHash = (git -C $localRepo rev-parse HEAD).Trim()

        # Create and commit on a task branch
        git -C $localRepo checkout -b task/F-998 origin/master 2>$null | Out-Null
        "feature work" | Set-Content -LiteralPath (Join-Path $localRepo "feature.md") -Encoding UTF8
        git -C $localRepo add feature.md 2>$null | Out-Null
        git -C $localRepo commit -m "feature commit" 2>$null | Out-Null

        # Merge task branch into master (where master has the unrelated commit)
        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo merge --no-edit task/F-998 2>$null | Out-Null

        # Set up human gate decision folder
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        # Run unwind human gate rejected
        $scriptPath = Join-Path $caseRoot "run-d22-followup.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        $scriptReject = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'rejected'
    GateReason = 'unwind test'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-998'
        source_phase = 'deployment'
        target_phase = 'implementation'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
} catch {}
finally {
    Pop-Location
}
"@
        $scriptReject | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $null = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1

        # Check that master head has been reset back to $unrelatedHash, NOT origin/master!
        $currentHead = (git -C $localRepo rev-parse HEAD).Trim()
        Assert-Result -Name "D22 follow-up: master reset back to unrelated commit" -Condition ($currentHead -eq $unrelatedHash) -FailureMessage "expected master HEAD to be $unrelatedHash, got $currentHead"
    }

    $results += Run-Test -Name "D52: rejected unwind preserves unrelated un-pushed commits after fast-forward merge" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "d52-unwind-ff"
        $originRepo = Join-Path $caseRoot "origin"
        $localRepo = Join-Path $caseRoot "local"
        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        git -C $originRepo init --bare --initial-branch=master 2>$null | Out-Null
        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"
        git -C $localRepo remote add origin $originRepo

        "initial content" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        git -C $localRepo push -u origin master 2>$null | Out-Null

        # Create an unrelated commit on master locally (un-pushed)
        "unrelated content" | Set-Content -LiteralPath (Join-Path $localRepo "unrelated.md") -Encoding UTF8
        git -C $localRepo add unrelated.md 2>$null | Out-Null
        git -C $localRepo commit -m "unrelated commit" 2>$null | Out-Null
        $unrelatedHash = (git -C $localRepo rev-parse HEAD).Trim()

        # Create task branch from the unrelated commit (since it is rebased/based on master)
        git -C $localRepo checkout -b task/F-997 2>$null | Out-Null
        "feature work" | Set-Content -LiteralPath (Join-Path $localRepo "feature.md") -Encoding UTF8
        git -C $localRepo add feature.md 2>$null | Out-Null
        git -C $localRepo commit -m "feature commit" 2>$null | Out-Null

        # Merge task branch into master using fast-forward (default behavior here since task branch is directly ahead of master)
        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo merge task/F-997 2>$null | Out-Null

        # Verify it was indeed a fast-forward (no merge commit with 2 parents)
        $currentHead = (git -C $localRepo rev-parse HEAD).Trim()
        $parents = (git -C $localRepo log --pretty=%P -n 1 $currentHead).Trim()
        $parentList = @(if ([string]::IsNullOrWhiteSpace($parents)) { } else { $parents -split '\s+' })
        Assert-Result -Name "D52: verify merge was fast-forward" -Condition ($parentList.Count -lt 2) -FailureMessage "expected fast-forward merge (1 parent), but got merge commit"

        # Set up human gate decision folder
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        # Run unwind human gate rejected
        $scriptPath = Join-Path $caseRoot "run-d52-unwind.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        $scriptReject = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'rejected'
    GateReason = 'unwind FF test'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-997'
        source_phase = 'deployment'
        target_phase = 'implementation'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try {
    Invoke-HumanGate -Context `$ctx
} catch {}
finally {
    Pop-Location
}
"@
        $scriptReject | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $null = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1

        # Check that master HEAD has been reset back to $unrelatedHash, preserving the unrelated commit!
        $currentHead = (git -C $localRepo rev-parse HEAD).Trim()
        Assert-Result -Name "D52: master reset back to unrelated commit after FF merge rejection" -Condition ($currentHead -eq $unrelatedHash) -FailureMessage "expected master HEAD to be $unrelatedHash, got $currentHead"
    }

    $results += Run-Test -Name "Human gate records base and branch SHAs and prints review command" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "gate-diff-cmd"
        $localRepo = Join-Path $caseRoot "local"
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"

        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        $baseSha = (git -C $localRepo rev-parse HEAD).Trim()

        # Create task branch
        git -C $localRepo checkout -b task/F-888 2>$null | Out-Null
        "changes" | Set-Content -LiteralPath (Join-Path $localRepo "file.txt") -Encoding UTF8
        git -C $localRepo add file.txt 2>$null | Out-Null
        git -C $localRepo commit -m "commit on task branch" 2>$null | Out-Null
        $branchSha = (git -C $localRepo rev-parse HEAD).Trim()

        # Set up human gate decision folder
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        $scriptPath = Join-Path $caseRoot "run-diff-cmd-test.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
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
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-888'
        source_phase = 'deployment'
        target_phase = 'done'
        commit_hash = '$branchSha'
        cumulative_handoff_count = 1
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
        $outputText = $output -join "`n"

        # 1. Assert pending JSON contains base_sha and branch_sha
        $pendingFile = Join-Path $gateDir "gate_decision_F-888_pending.json"
        Assert-Result -Name "Pending file exists" -Condition (Test-Path $pendingFile) -FailureMessage "expected $pendingFile to exist"
        $pendingData = Get-Content $pendingFile -Raw | ConvertFrom-Json
        Assert-Result -Name "Pending JSON records base_sha" -Condition ($pendingData.base_sha -eq $baseSha) -FailureMessage "expected base_sha $baseSha, got $($pendingData.base_sha)"
        Assert-Result -Name "Pending JSON records branch_sha" -Condition ($pendingData.branch_sha -eq $branchSha) -FailureMessage "expected branch_sha $branchSha, got $($pendingData.branch_sha)"

        # 2. Assert output text contains the exact diff command
        $expectedCmd = "git -C `"$localRepo`" diff $baseSha..$branchSha"
        Assert-Result -Name "Output contains review command" -Condition ($outputText -match [regex]::Escape($expectedCmd)) -FailureMessage "expected output to contain command '$expectedCmd', got:`n$outputText"
    }

    $results += Run-Test -Name "Review-before-merge: reject on an unmerged task branch leaves master untouched (no data loss)" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "new-flow-reject"
        $originRepo = Join-Path $caseRoot "origin"
        $localRepo = Join-Path $caseRoot "local"
        New-Item -ItemType Directory -Path $originRepo -Force | Out-Null
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        git -C $originRepo init --bare --initial-branch=master 2>$null | Out-Null
        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"
        git -C $localRepo remote add origin $originRepo

        "c1" | Set-Content -LiteralPath (Join-Path $localRepo "a.txt") -Encoding UTF8
        git -C $localRepo add a.txt 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        git -C $localRepo push -u origin master 2>$null | Out-Null

        # A previously-accepted task that advanced AND pushed master (so master == origin
        # and the reflog's prior entry is the unrelated initial commit).
        "c2" | Set-Content -LiteralPath (Join-Path $localRepo "b.txt") -Encoding UTF8
        git -C $localRepo add b.txt 2>$null | Out-Null
        git -C $localRepo commit -m "prior accepted task" 2>$null | Out-Null
        git -C $localRepo push origin master 2>$null | Out-Null
        $masterBefore = (git -C $localRepo rev-parse HEAD).Trim()

        # New flow: task branch exists with a commit but is NOT merged into master.
        git -C $localRepo checkout -b task/F-779 2>$null | Out-Null
        "feat" | Set-Content -LiteralPath (Join-Path $localRepo "feat.txt") -Encoding UTF8
        git -C $localRepo add feat.txt 2>$null | Out-Null
        git -C $localRepo commit -m "feature" 2>$null | Out-Null
        git -C $localRepo checkout master 2>$null | Out-Null

        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path (Join-Path $sessionDir "global/gate_decisions") -Force | Out-Null

        $scriptPath = Join-Path $caseRoot "run-new-flow-reject.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        $scriptReject = @"
`$ErrorActionPreference = "Continue"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = 'rejected'
    GateReason = 'reject on unmerged branch'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-779'
        source_phase = 'deployment'
        target_phase = 'implementation'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try { Invoke-HumanGate -Context `$ctx } catch {} finally { Pop-Location }
"@
        $scriptReject | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $null = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1

        $masterAfter = (git -C $localRepo rev-parse HEAD).Trim()
        Assert-Result -Name "new-flow reject: master unchanged" -Condition ($masterAfter -eq $masterBefore) -FailureMessage "master moved on reject of an unmerged branch: $masterBefore -> $masterAfter"
        Assert-Result -Name "new-flow reject: prior task commit preserved" -Condition (Test-Path (Join-Path $localRepo "b.txt")) -FailureMessage "previously-accepted task's file b.txt was discarded by the reject unwind"
        Assert-Result -Name "new-flow reject: task branch retained" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "task/F-779 branch was not retained after reject"
    }

    $results += Run-Test -Name "Human gate visual review affordances appear when diff_tool is configured" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "gate-affordances"
        $localRepo = Join-Path $caseRoot "local"
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"

        # Create config.yaml with review config
        $configDir = Join-Path $localRepo ".crucible"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $configYaml = @"
crucible_root: ".crucible"
project:
  name: "Test"
  description: "Test"
  default_branch: "master"
roles:
  researcher:
    model_tier: fast
  groomer:
    model_tier: fast
  architect:
    model_tier: fast
  reviewer:
    model_tier: fast
  operator:
    model_tier: fast
verification:
  quick:
    - name: test
      command: echo quick
  full:
    - name: test
      command: echo full
project_mandates:
  - rules
review:
  diff_tool: "zed"
  editor: "code"
"@
        $configYaml | Set-Content -LiteralPath (Join-Path $configDir "config.yaml") -Encoding UTF8

        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        $baseSha = (git -C $localRepo rev-parse HEAD).Trim()

        # Create task branch
        git -C $localRepo checkout -b task/F-889 2>$null | Out-Null
        "changes" | Set-Content -LiteralPath (Join-Path $localRepo "file.txt") -Encoding UTF8
        git -C $localRepo add file.txt 2>$null | Out-Null
        git -C $localRepo commit -m "commit on task branch" 2>$null | Out-Null
        $branchSha = (git -C $localRepo rev-parse HEAD).Trim()

        # Set up human gate decision folder
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        $scriptPath = Join-Path $caseRoot "run-affordances-test.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
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
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-889'
        source_phase = 'deployment'
        target_phase = 'done'
        commit_hash = '$branchSha'
        cumulative_handoff_count = 1
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
        $outputText = $output -join "`n"

        # Assert visual review commands and worktree opening command are generated
        Assert-Result -Name "Visual diff tool command appears when configured" -Condition ($outputText -like "*difftool*") -FailureMessage "expected output to contain 'difftool', got:`n$outputText"
        Assert-Result -Name "Editor command appears when configured" -Condition ($outputText -like "*code*") -FailureMessage "expected output to contain 'code' (from editor configuration), got:`n$outputText"
        
        # Verify review-diff.ps1 helper script was generated
        $helperPath = Join-Path $sessionDir "F-889/review-diff.ps1"
        Assert-Result -Name "review-diff.ps1 helper script generated" -Condition (Test-Path $helperPath) -FailureMessage "expected $helperPath to exist"
        $helperContent = Get-Content $helperPath -Raw
        Assert-Result -Name "review-diff.ps1 uses the resolved zed path" -Condition ($helperContent -like "*zed*") -FailureMessage "expected helper script to reference 'zed'"

        # Regression check: Extract and run the generated difftool command to verify quoting and execution
        $diffLines = @($outputText -split "`n" | Where-Object { $_.Trim() -like "git -C *" -and $_ -like "*difftool*" })
        Assert-Result -Name "Found emitted git difftool command in output" -Condition ($diffLines.Count -eq 1) -FailureMessage "expected exactly 1 difftool command line, found: $($diffLines.Count)`n$outputText"
        
        if ($diffLines.Count -eq 1) {
            $diffToolCommand = $diffLines[0].Trim()
            
            # 1. Static quote balancing assertion
            $cleanCommandForQuotes = $diffToolCommand -replace '\\"', ''
            $quoteCount = ($cleanCommandForQuotes -split '"').Count - 1
            Assert-Result -Name "Difftool command unescaped quotes are balanced" -Condition ($quoteCount -eq 4) -FailureMessage "expected exactly 4 unescaped double quotes (balanced), found $quoteCount in command:`n$diffToolCommand"
            
            Assert-Result -Name "Difftool command has no doubled escaped quotes" -Condition ($diffToolCommand -notlike '*\"\"*') -FailureMessage "expected no doubled escaped quotes in command:`n$diffToolCommand"

            # 2. Dynamic execution regression check
            $stubLog = Join-Path $caseRoot "stub.log"
            $stubContent = @"
`$args | Set-Content -LiteralPath '$stubLog' -Encoding UTF8
"@
            $stubContent | Set-Content -LiteralPath $helperPath -Encoding UTF8

            $runningOnWindows = $true
            $isWindowsVar = Get-Variable -Name "IsWindows" -ErrorAction SilentlyContinue
            if ($null -ne $isWindowsVar) { $runningOnWindows = $isWindowsVar.Value }
            if ($runningOnWindows) {
                $runScript = Join-Path $caseRoot "run-diff.bat"
                $diffToolCommand | Set-Content -LiteralPath $runScript -Encoding ASCII
                $runOutput = cmd.exe /c `"$runScript`" 2>&1
            } else {
                $runScript = Join-Path $caseRoot "run-diff.sh"
                $diffToolCommand | Set-Content -LiteralPath $runScript -Encoding UTF8
                $runOutput = sh $runScript 2>&1
            }
            $runOutputText = $runOutput -join "`n"
            
            Assert-Result -Name "Emitted difftool command executed successfully" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "difftool command execution failed with exit code $LASTEXITCODE. Output:`n$runOutputText`nCommand run:`n$diffToolCommand"
            $gitDiffOut = git -C $localRepo diff --stat "$baseSha..$branchSha" 2>&1
            $gitLogOut = git -C $localRepo log --oneline -n 5 2>&1
            Assert-Result -Name "Stub log file was created" -Condition (Test-Path $stubLog) -FailureMessage "expected $stubLog to exist after running difftool command.`nOutput from difftool was:`n$runOutputText`nCommand run:`n$diffToolCommand`nGit Diff:`n$gitDiffOut`nGit Log:`n$gitLogOut"
            
            if (Test-Path $stubLog) {
                $loggedArgs = @(Get-Content $stubLog)
                Assert-Result -Name "Stub logged exactly two file arguments" -Condition ($loggedArgs.Count -eq 2) -FailureMessage "expected 2 arguments to be logged, found: $($loggedArgs.Count)`nContent:`n$($loggedArgs -join "`n")"
            }
        }
    }

    $results += Run-Test -Name "Pattern-C closure (no task branch): gate prints Pattern-C message, not a diff/worktree surface" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "gate-pattern-c"
        $localRepo = Join-Path $caseRoot "local"
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"

        # Review IS configured (diff_tool + editor) - so any diff/worktree surface that appears would
        # be because a task branch was assumed, NOT because review config is missing.
        $configDir = Join-Path $localRepo ".crucible"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        @"
crucible_root: ".crucible"
project:
  name: "Test"
  description: "Test"
  default_branch: "master"
review:
  diff_tool: "zed"
  editor: "code"
"@ | Set-Content -LiteralPath (Join-Path $configDir "config.yaml") -Encoding UTF8

        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        $baseSha = (git -C $localRepo rev-parse HEAD).Trim()

        # NOTE: deliberately NO task/R-900 branch is created (Pattern-C research closure).
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path (Join-Path $sessionDir "global/gate_decisions") -Force | Out-Null

        $scriptPath = Join-Path $caseRoot "run-pattern-c.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = `$null
    GateReason = `$null
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'R-900'
        source_phase = 'deployment'
        target_phase = 'done'
        commit_hash = '$baseSha'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try { Invoke-HumanGate -Context `$ctx } finally { Pop-Location }
"@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $outputText = $output -join "`n"

        Assert-Result -Name "Pattern-C: gate prints the Pattern-C closure message" -Condition ($outputText -like "*Pattern-C closure*") -FailureMessage "expected 'Pattern-C closure' message, got:`n$outputText"
        Assert-Result -Name "Pattern-C: no difftool command emitted (no task branch)" -Condition ($outputText -notlike "*difftool*") -FailureMessage "expected NO difftool command for a no-branch closure, got:`n$outputText"
        Assert-Result -Name "Pattern-C: no text git-diff review command emitted" -Condition ($outputText -notlike "*diff $baseSha..$baseSha*") -FailureMessage "expected NO degenerate commit..commit diff command, got:`n$outputText"
        $pendingFile = Join-Path $sessionDir "R-900/gate_pending.txt"
        Assert-Result -Name "Pattern-C: gate_pending.txt written" -Condition (Test-Path $pendingFile) -FailureMessage "expected gate_pending.txt at $pendingFile"
        if (Test-Path $pendingFile) {
            $pendingText = Get-Content $pendingFile -Raw
            Assert-Result -Name "Pattern-C: gate_pending menu carries the Pattern-C message" -Condition ($pendingText -like "*Pattern-C closure*") -FailureMessage "expected gate_pending.txt to contain the Pattern-C message, got:`n$pendingText"
        }
    }

    $results += Run-Test -Name "Pattern-C closure resolves the actual findings doc path into the review hint" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "gate-pattern-c-findings"
        $localRepo = Join-Path $caseRoot "local"
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"

        $configDir = Join-Path $localRepo ".crucible"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        @"
crucible_root: ".crucible"
project:
  name: "Test"
  description: "Test"
  default_branch: "master"
"@ | Set-Content -LiteralPath (Join-Path $configDir "config.yaml") -Encoding UTF8

        # A research findings deliverable exists at the conventional location.
        $researchDir = Join-Path $configDir "research"
        New-Item -ItemType Directory -Path $researchDir -Force | Out-Null
        "findings body" | Set-Content -LiteralPath (Join-Path $researchDir "R-901_findings.md") -Encoding UTF8

        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        $baseSha = (git -C $localRepo rev-parse HEAD).Trim()

        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path (Join-Path $sessionDir "global/gate_decisions") -Force | Out-Null

        $scriptPath = Join-Path $caseRoot "run-pattern-c-findings.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    GateOutcome = `$null
    GateReason = `$null
    GateRedirectTarget = `$null
    CrucibleRoot = '.crucible'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'R-901'
        source_phase = 'deployment'
        target_phase = 'done'
        commit_hash = '$baseSha'
        cumulative_handoff_count = 1
    }
}
Push-Location '$localRepo'
try { Invoke-HumanGate -Context `$ctx } finally { Pop-Location }
"@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8
        $output = & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1
        $outputText = $output -join "`n"

        Assert-Result -Name "Pattern-C: review hint names the actual findings doc" -Condition ($outputText -like "*.crucible/research/R-901_findings.md*") -FailureMessage "expected the resolved findings path, got:`n$outputText"
        Assert-Result -Name "Pattern-C: no literal placeholder remains" -Condition ($outputText -notlike "*<findings doc>*") -FailureMessage "expected no '<findings doc>' placeholder, got:`n$outputText"
    }

    $results += Run-Test -Name "Human gate visual review affordances fall back to text git diff when diff_tool is unconfigured" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "gate-no-affordances"
        $localRepo = Join-Path $caseRoot "local"
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"

        # Create config.yaml WITHOUT review config
        $configDir = Join-Path $localRepo ".crucible"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $configYaml = @"
crucible_root: ".crucible"
project:
  name: "Test"
  description: "Test"
  default_branch: "master"
roles:
  researcher:
    model_tier: fast
  groomer:
    model_tier: fast
  architect:
    model_tier: fast
  reviewer:
    model_tier: fast
  operator:
    model_tier: fast
verification:
  quick:
    - name: test
      command: echo quick
  full:
    - name: test
      command: echo full
project_mandates:
  - rules
"@
        $configYaml | Set-Content -LiteralPath (Join-Path $configDir "config.yaml") -Encoding UTF8

        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null
        $baseSha = (git -C $localRepo rev-parse HEAD).Trim()

        # Create task branch
        git -C $localRepo checkout -b task/F-890 2>$null | Out-Null
        "changes" | Set-Content -LiteralPath (Join-Path $localRepo "file.txt") -Encoding UTF8
        git -C $localRepo add file.txt 2>$null | Out-Null
        git -C $localRepo commit -m "commit on task branch" 2>$null | Out-Null
        $branchSha = (git -C $localRepo rev-parse HEAD).Trim()

        # Set up human gate decision folder
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        $scriptPath = Join-Path $caseRoot "run-no-affordances-test.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
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
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-890'
        source_phase = 'deployment'
        target_phase = 'done'
        commit_hash = '$branchSha'
        cumulative_handoff_count = 1
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
        $outputText = $output -join "`n"

        # Assert no visual review command is printed
        Assert-Result -Name "No visual diff tool command printed when unconfigured" -Condition ($outputText -notlike "*difftool*") -FailureMessage "expected output to NOT contain 'difftool', got:`n$outputText"
        Assert-Result -Name "Text diff fallback still printed" -Condition ($outputText -like "*git -C*diff*") -FailureMessage "expected output to contain command-line diff, got:`n$outputText"
    }

    $results += Run-Test -Name "Get-GateReviewRange: base=merge-base, branch=task tip when primary advanced past task base" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "gate-review-range"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        git -C $caseRoot init --initial-branch=master 2>$null | Out-Null
        git -C $caseRoot config user.name "Tester"
        git -C $caseRoot config user.email "test@example.com"

        # Base commit: where the task branch is cut from.
        "base" | Set-Content -LiteralPath (Join-Path $caseRoot "README.md") -Encoding UTF8
        git -C $caseRoot add README.md 2>$null | Out-Null
        git -C $caseRoot commit -m "base commit" 2>$null | Out-Null
        $baseCommit = (git -C $caseRoot rev-parse HEAD).Trim()

        # Cut the task branch from the base (no work on it yet).
        git -C $caseRoot branch task/F-700 $baseCommit 2>$null | Out-Null

        # Primary branch advances past the base -- the trigger that broke the old range.
        "unrelated" | Set-Content -LiteralPath (Join-Path $caseRoot "other.md") -Encoding UTF8
        git -C $caseRoot add other.md 2>$null | Out-Null
        git -C $caseRoot commit -m "advance master" 2>$null | Out-Null
        $masterTip = (git -C $caseRoot rev-parse HEAD).Trim()

        # The actual reviewed work lands on the task branch.
        git -C $caseRoot checkout task/F-700 2>$null | Out-Null
        "feature" | Set-Content -LiteralPath (Join-Path $caseRoot "feature.md") -Encoding UTF8
        git -C $caseRoot add feature.md 2>$null | Out-Null
        git -C $caseRoot commit -m "task work" 2>$null | Out-Null
        $taskTip = (git -C $caseRoot rev-parse HEAD).Trim()
        git -C $caseRoot checkout master 2>$null | Out-Null

        Push-Location $caseRoot
        try {
            # Pass the stale bootstrap-era HEAD (here the base commit) as CommitHash to
            # prove the helper prefers the live task-branch tip over it.
            $range = Get-GateReviewRange -PrimaryBranch "master" -TaskId "F-700" -CommitHash $baseCommit
        } finally {
            Pop-Location
        }

        Assert-Result -Name "review-range: branch endpoint is the task tip" -Condition ($range.BranchSha -eq $taskTip) -FailureMessage "expected BranchSha=$taskTip (task tip), got $($range.BranchSha)"
        Assert-Result -Name "review-range: branch endpoint ignores stale commit_hash" -Condition ($range.BranchSha -ne $baseCommit) -FailureMessage "BranchSha fell back to the stale commit_hash $baseCommit"
        Assert-Result -Name "review-range: base endpoint is the merge-base" -Condition ($range.BaseSha -eq $baseCommit) -FailureMessage "expected BaseSha=$baseCommit (merge-base), got $($range.BaseSha)"
        Assert-Result -Name "review-range: base endpoint is not the advanced primary tip" -Condition ($range.BaseSha -ne $masterTip) -FailureMessage "BaseSha used the advanced master tip $masterTip"

        $rangeFiles = @(git -C $caseRoot diff --name-only "$($range.BaseSha)..$($range.BranchSha)")
        Assert-Result -Name "review-range: diff lists the task file" -Condition ($rangeFiles -contains "feature.md") -FailureMessage "expected feature.md in range diff, got: $($rangeFiles -join ', ')"
        Assert-Result -Name "review-range: diff excludes unrelated master-only file" -Condition ($rangeFiles -notcontains "other.md") -FailureMessage "range diff leaked unrelated master commit (other.md)"
    }

    $results += Run-Test -Name "Invoke-HumanGate: auto_push config controls git push" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "auto-push-testing"
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
        $null = git -C $localRepo push -u origin master 2>&1

        # Cut task branch and commit
        git -C $localRepo checkout -b task/F-777 2>$null | Out-Null
        "feature work" | Set-Content -LiteralPath (Join-Path $localRepo "feature.md") -Encoding UTF8
        git -C $localRepo add feature.md 2>$null | Out-Null
        git -C $localRepo commit -m "feature commit" 2>$null | Out-Null
        $featureSha = (git -C $localRepo rev-parse HEAD).Trim()

        # Checkout master and merge locally
        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo merge --no-edit task/F-777 2>$null | Out-Null

        # Setup context structure
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        $configDir = Join-Path $localRepo ".crucible"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null

        $scriptPath = Join-Path $caseRoot "run-autopush.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")

        # Test Case 1: auto_push = false (should merge locally but not push, and print instructions)
        $configYaml = @"
project:
  name: Fake
  description: Fake
  default_branch: master
roles:
  researcher:  { model_tier: fast }
  groomer:     { model_tier: fast }
  architect:   { model_tier: high-capability }
  reviewer:    { model_tier: high-capability }
  operator:    { model_tier: fast }
verification:
  quick:
    - name: test
      command: echo quick
  full:
    - name: test
      command: echo full
project_mandates:
  - rules
review:
  auto_push: false
"@
        $configYaml | Set-Content -LiteralPath (Join-Path $configDir "config.yaml") -Encoding UTF8

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
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-777'
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

        Assert-Result -Name "auto_push=false: human gate accepted exits successfully" -Condition ($exitCode -eq 0) -FailureMessage "expected exit code 0, got $exitCode"
        Assert-Result -Name "auto_push=false: prints refusal note" -Condition ($output -match "Refusing to push; merge remains LOCAL only") -FailureMessage "expected refusal note in output"
        Assert-Result -Name "auto_push=false: prints push command" -Condition ($output -match "git push origin master") -FailureMessage "expected push command in output"

        $behindCommits = @(git -C $localRepo log origin/master..master --oneline)
        Assert-Result -Name "auto_push=false: local master remains ahead of origin" -Condition ($behindCommits.Count -gt 0) -FailureMessage "expected origin/master to be behind master"

        # Test Case 2: auto_push = true (should merge and push)
        $configYamlTrue = $configYaml -replace "auto_push: false", "auto_push: true"
        $configYamlTrue | Set-Content -LiteralPath (Join-Path $configDir "config.yaml") -Encoding UTF8

        # Restore branch and merge state for re-test
        git -C $localRepo checkout master 2>$null | Out-Null
        git -C $localRepo reset --hard HEAD~1 2>$null | Out-Null
        git -C $originRepo update-ref refs/heads/master HEAD~1 2>$null | Out-Null
        git -C $localRepo fetch origin master 2>$null | Out-Null
        git -C $localRepo branch task/F-777 $featureSha 2>$null | Out-Null
        git -C $localRepo merge --no-edit task/F-777 2>$null | Out-Null

        $outputLinesTrue = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
        $exitCodeTrue = $LASTEXITCODE
        $outputTrue = $outputLinesTrue -join "`n"

        Assert-Result -Name "auto_push=true: human gate accepted exits successfully" -Condition ($exitCodeTrue -eq 0) -FailureMessage "expected exit code 0, got $exitCodeTrue"
        Assert-Result -Name "auto_push=true: does not print refusal note" -Condition ($outputTrue -notmatch "Refusing to push; merge remains LOCAL only") -FailureMessage "should not have printed refusal note"

        $behindCommitsTrue = @(git -C $localRepo log origin/master..master --oneline)
        Assert-Result -Name "auto_push=true: git push succeeded" -Condition ($behindCommitsTrue.Count -eq 0) -FailureMessage "expected origin/master to be even with master"
    }

    $results += Run-Test -Name "Invoke-HumanGate accept prunes finalized task from session_state.json" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "accept-prune-state"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $localRepo = Join-Path $caseRoot "local_repo"
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null
        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"
        "initial" | Set-Content -LiteralPath (Join-Path $localRepo "README.md") -Encoding UTF8
        git -C $localRepo add README.md 2>$null | Out-Null
        git -C $localRepo commit -m "initial commit" 2>$null | Out-Null

        $configDir = Join-Path $localRepo ".crucible"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $sessionDir = Join-Path $localRepo ".crucible/session"
        $globalDir = Join-Path $sessionDir "global"
        New-Item -ItemType Directory -Path $globalDir -Force | Out-Null

        $configYaml = @"
project:
  name: Fake
  description: Fake
  default_branch: master
roles:
  researcher:  { model_tier: fast }
  groomer:     { model_tier: fast }
  architect:   { model_tier: high-capability }
  reviewer:    { model_tier: high-capability }
  operator:    { model_tier: fast }
verification:
  quick:
    - name: test
      command: echo quick
  full:
    - name: test
      command: echo full
project_mandates:
  - rules
review:
  auto_push: false
"@
        $configYaml | Set-Content -LiteralPath (Join-Path $configDir "config.yaml") -Encoding UTF8

        # Seed session_state.json with the finalized task plus a sibling that must survive.
        $stateFile = Join-Path $globalDir "session_state.json"
        $stateJson = @"
{
  "version": "1.0",
  "tasks": {
    "F-778": { "phases": { "implementation": { "status": "complete", "timestamp": "2026-06-29T00:00:00Z" } } },
    "F-999": { "phases": { "grooming": { "status": "complete", "timestamp": "2026-06-29T00:00:00Z" } } }
  }
}
"@
        $stateJson | Set-Content -LiteralPath $stateFile -Encoding UTF8

        $scriptPath = Join-Path $caseRoot "run-prune.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        $fwPwsh = (Split-Path -Parent $FACTORY_LIB).Replace("'", "''")
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    FrameworkPowerShell = '$fwPwsh'
    GateOutcome = 'accepted'
    GateReason = 'work looks complete and correct'
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-778'
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

        Assert-Result -Name "accept-prune: human gate accepted exits successfully" -Condition ($exitCode -eq 0) -FailureMessage "expected exit code 0, got $exitCode. Output: $output"

        $stateAfter = (Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8) | ConvertFrom-Json
        $hasGhost = $stateAfter.tasks.PSObject.Properties["F-778"]
        Assert-Result -Name "accept-prune: finalized task removed from session_state" -Condition ($null -eq $hasGhost) -FailureMessage "expected F-778 pruned from session_state.json; output: $output"

        $siblingKept = $stateAfter.tasks.PSObject.Properties["F-999"]
        Assert-Result -Name "accept-prune: other tasks preserved" -Condition ($null -ne $siblingKept) -FailureMessage "expected F-999 to remain in session_state.json"
    }

    $results += Run-Test -Name "Invoke-HumanGate require_green_ci blocks final cleanup on RED" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "ci-red"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $case = New-CiGateCase -CaseRoot $caseRoot -TaskId "F-CIR"
        $binDir = Join-Path $caseRoot "bin"
        New-FakeGhForGate -Dir $binDir -Mode "red" | Out-Null
        $oldPath = $env:PATH
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $oldPath
            $result = Invoke-CiGateCase -Case $case -TaskId "F-CIR"
        } finally {
            $env:PATH = $oldPath
        }

        Assert-Result -Name "ci red exits 1" -Condition ($result.ExitCode -eq 1) -FailureMessage ("expected 1, got " + $result.ExitCode + ". Output:`n" + $result.Output)
        Assert-Result -Name "ci red reports status" -Condition ($result.Output -match "\[CI WATCH\] STATUS=RED") -FailureMessage $result.Output
        Assert-Result -Name "ci red reports failed job" -Condition ($result.Output -match "windows-ci") -FailureMessage $result.Output
        Assert-Result -Name "ci red task not done" -Condition ($result.Output -match "task F-CIR is NOT done") -FailureMessage $result.Output
        git -C $case.LocalRepo show-ref --quiet refs/heads/task/F-CIR
        Assert-Result -Name "ci red keeps task branch" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "task branch was deleted on red CI"
    }

    $results += Run-Test -Name "Invoke-HumanGate require_green_ci finalizes on GREEN" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "ci-green"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $case = New-CiGateCase -CaseRoot $caseRoot -TaskId "F-CIG"
        $binDir = Join-Path $caseRoot "bin"
        New-FakeGhForGate -Dir $binDir -Mode "green" | Out-Null
        $oldPath = $env:PATH
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $oldPath
            $result = Invoke-CiGateCase -Case $case -TaskId "F-CIG"
        } finally {
            $env:PATH = $oldPath
        }

        Assert-Result -Name "ci green exits 0" -Condition ($result.ExitCode -eq 0) -FailureMessage ("expected 0, got " + $result.ExitCode + ". Output:`n" + $result.Output)
        Assert-Result -Name "ci green reports status" -Condition ($result.Output -match "\[CI WATCH\] STATUS=GREEN") -FailureMessage $result.Output
        git -C $case.LocalRepo show-ref --quiet refs/heads/task/F-CIG
        Assert-Result -Name "ci green deletes task branch" -Condition ($LASTEXITCODE -ne 0) -FailureMessage "task branch was not deleted after green CI"
    }

    $results += Run-Test -Name "Invoke-HumanGate require_green_ci finalizes when gh is absent" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "ci-gh-absent"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $case = New-CiGateCase -CaseRoot $caseRoot -TaskId "F-CIA"
        # Simulate "gh unavailable" with a shim whose `auth status` fails, rather
        # than stripping gh's dir from PATH -- on CI/Linux gh lives in /usr/bin
        # alongside git, so removing it would also remove git and break the gate.
        $binDir = Join-Path $caseRoot "bin"
        New-FakeGhForGate -Dir $binDir -Mode "unauth" | Out-Null
        $oldPath = $env:PATH
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $oldPath
            $result = Invoke-CiGateCase -Case $case -TaskId "F-CIA"
        } finally {
            $env:PATH = $oldPath
        }

        Assert-Result -Name "ci absent exits 0" -Condition ($result.ExitCode -eq 0) -FailureMessage ("expected 0, got " + $result.ExitCode + ". Output:`n" + $result.Output)
        Assert-Result -Name "ci absent reports skip" -Condition ($result.Output -match "\[CI WATCH\] SKIPPED \(gh unavailable\)") -FailureMessage $result.Output
        git -C $case.LocalRepo show-ref --quiet refs/heads/task/F-CIA
        Assert-Result -Name "ci absent deletes task branch" -Condition ($LASTEXITCODE -ne 0) -FailureMessage "task branch was not deleted after skipped CI watch"
    }

    $results += Run-Test -Name "F3: RED withholds the master push and deletes staging ref" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "f3-ci-red"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $case = New-CiGateCase -CaseRoot $caseRoot -TaskId "F3-RED"
        $originRepo = Join-Path $caseRoot "remote_origin"
        $preMergeSha = (git -C $originRepo rev-parse master).Trim()

        $binDir = Join-Path $caseRoot "bin"
        New-FakeGhForGate -Dir $binDir -Mode "red" | Out-Null
        $oldPath = $env:PATH
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $oldPath
            $result = Invoke-CiGateCase -Case $case -TaskId "F3-RED"
        } finally {
            $env:PATH = $oldPath
        }

        Assert-Result -Name "f3 red exits 1" -Condition ($result.ExitCode -eq 1) -FailureMessage ("expected 1, got " + $result.ExitCode + ". Output:`n" + $result.Output)
        Assert-Result -Name "f3 red output indicates master not published" -Condition ($result.Output -match "master was NOT published \(still local only\)") -FailureMessage $result.Output
        $postMergeOriginSha = (git -C $originRepo rev-parse master).Trim()
        Assert-Result -Name "f3 red master branch tip on origin unchanged" -Condition ($postMergeOriginSha -eq $preMergeSha) -FailureMessage ("expected origin master tip $preMergeSha, got $postMergeOriginSha")
        git -C $originRepo show-ref --quiet refs/heads/crucible-ci/F3-RED
        Assert-Result -Name "f3 red deleted staging branch on origin" -Condition ($LASTEXITCODE -ne 0) -FailureMessage "staging branch was not deleted on red CI"
    }

    $results += Run-Test -Name "F3: GREEN publishes master then deletes staging ref" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "f3-ci-green"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $case = New-CiGateCase -CaseRoot $caseRoot -TaskId "F3-GRN"
        $originRepo = Join-Path $caseRoot "remote_origin"

        $binDir = Join-Path $caseRoot "bin"
        New-FakeGhForGate -Dir $binDir -Mode "green" | Out-Null
        $oldPath = $env:PATH
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $oldPath
            $result = Invoke-CiGateCase -Case $case -TaskId "F3-GRN"
        } finally {
            $env:PATH = $oldPath
        }

        Assert-Result -Name "f3 green exits 0" -Condition ($result.ExitCode -eq 0) -FailureMessage ("expected 0, got " + $result.ExitCode + ". Output:`n" + $result.Output)
        Assert-Result -Name "f3 green staging ref pushed" -Condition ($result.Output -match "Publishing CI staging ref origin/crucible-ci/F3-GRN") -FailureMessage $result.Output
        $postMergeLocalSha = (git -C $case.LocalRepo rev-parse master).Trim()
        $postMergeOriginSha = (git -C $originRepo rev-parse master).Trim()
        Assert-Result -Name "f3 green master branch updated on origin" -Condition ($postMergeOriginSha -eq $postMergeLocalSha) -FailureMessage ("expected origin master tip $postMergeLocalSha, got $postMergeOriginSha")
        git -C $originRepo show-ref --quiet refs/heads/crucible-ci/F3-GRN
        Assert-Result -Name "f3 green deleted staging branch on origin" -Condition ($LASTEXITCODE -ne 0) -FailureMessage "staging branch was not deleted on green CI"
    }

    $results += Run-Test -Name "F3: Timeout publishes master and emits warning" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "f3-ci-timeout"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $case = New-CiGateCase -CaseRoot $caseRoot -TaskId "F3-TMO"
        $originRepo = Join-Path $caseRoot "remote_origin"

        $configYaml = (Get-Content -LiteralPath (Join-Path $case.LocalRepo ".crucible/config.yaml") -Raw) -replace "ci_timeout_minutes: 1", "ci_timeout_minutes: 0"
        $configYaml | Set-Content -LiteralPath (Join-Path $case.LocalRepo ".crucible/config.yaml") -Encoding UTF8

        $binDir = Join-Path $caseRoot "bin"
        New-FakeGhForGate -Dir $binDir -Mode "pending" | Out-Null
        $oldPath = $env:PATH
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $oldPath
            $result = Invoke-CiGateCase -Case $case -TaskId "F3-TMO"
        } finally {
            $env:PATH = $oldPath
        }

        Assert-Result -Name "f3 timeout exits 0" -Condition ($result.ExitCode -eq 0) -FailureMessage ("expected 0, got " + $result.ExitCode + ". Output:`n" + $result.Output)
        Assert-Result -Name "f3 timeout warning emitted" -Condition ($result.Output -match "CI did not finish before timeout") -FailureMessage $result.Output
        $postMergeLocalSha = (git -C $case.LocalRepo rev-parse master).Trim()
        $postMergeOriginSha = (git -C $originRepo rev-parse master).Trim()
        Assert-Result -Name "f3 timeout pushed master to origin" -Condition ($postMergeOriginSha -eq $postMergeLocalSha) -FailureMessage ("expected origin master tip $postMergeLocalSha, got $postMergeOriginSha")
        git -C $originRepo show-ref --quiet refs/heads/crucible-ci/F3-TMO
        Assert-Result -Name "f3 timeout deleted staging branch on origin" -Condition ($LASTEXITCODE -ne 0) -FailureMessage "staging branch was not deleted on timeout CI"
    }

    $results += Run-Test -Name "F3: Staging push failure cleanly aborts without pushing master" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "f3-staging-fail"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $case = New-CiGateCase -CaseRoot $caseRoot -TaskId "F3-SPF"
        $originRepo = Join-Path $caseRoot "remote_origin"
        $preMergeSha = (git -C $originRepo rev-parse master).Trim()

        git -C $case.LocalRepo remote set-url origin "invalid/path/repo.git"

        $binDir = Join-Path $caseRoot "bin"
        New-FakeGhForGate -Dir $binDir -Mode "green" | Out-Null
        $oldPath = $env:PATH
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $oldPath
            $result = Invoke-CiGateCase -Case $case -TaskId "F3-SPF"
        } finally {
            $env:PATH = $oldPath
        }

        Assert-Result -Name "f3 staging push fail exits 1" -Condition ($result.ExitCode -eq 1) -FailureMessage ("expected 1, got " + $result.ExitCode + ". Output:`n" + $result.Output)
        Assert-Result -Name "f3 staging push fail error message" -Condition ($result.Output -match "Failed to publish CI staging ref") -FailureMessage $result.Output
        $postMergeOriginSha = (git -C $originRepo rev-parse master).Trim()
        Assert-Result -Name "f3 staging push fail master tip unchanged on real origin" -Condition ($postMergeOriginSha -eq $preMergeSha) -FailureMessage ("expected origin master tip $preMergeSha, got $postMergeOriginSha")
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
