# Tests for Crucible gate orchestration helpers.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$CRUCIBLE_LIB = Join-Path $REPO_ROOT "powershell/crucible-lib.ps1"
$Quiet = $true
. $CRUCIBLE_LIB
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
        NextCrucibleCommand = $null
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
if (`$verb -eq "api repos" -or (`$args.Count -ge 1 -and `$args[0] -eq "api")) {
    `$endpoint = `$args[`$args.Count - 1]
    if (`$endpoint -match "actions/workflows$") {
        if (`$Mode -eq "api-error" -or `$Mode -eq "404") {
            Write-Output "HTTP 404: Not Found"
            exit 1
        }
        Write-Output '{"total_count":1,"workflows":[{"id":2001,"name":"CI","state":"active"}]}'
        exit 0
    }
    if (`$endpoint -match "actions/workflows/(\d+)/runs") {
        if (`$Mode -eq "api-error" -or `$Mode -eq "404") {
            Write-Output "HTTP 404: Not Found"
            exit 1
        }
        if (`$Mode -eq "green") { Write-Output '{"total_count":1,"workflow_runs":[{"id":201,"status":"completed","conclusion":"success","name":"CI"}]}' }
        if (`$Mode -eq "red") { Write-Output '{"total_count":1,"workflow_runs":[{"id":202,"status":"completed","conclusion":"failure","name":"CI"}]}' }
        if (`$Mode -eq "pending") { Write-Output '{"total_count":1,"workflow_runs":[{"id":203,"status":"in_progress","conclusion":null,"name":"CI"}]}' }
        if (`$Mode -eq "post-push-red") {
            `$runsFile = Join-Path `$PSScriptRoot "runs_count.txt"
            `$count = 0
            if (Test-Path `$runsFile) {
                `$count = [int](Get-Content `$runsFile -Raw)
            }
            `$count++
            `$count | Set-Content `$runsFile
            if (`$count -eq 1) {
                Write-Output '{"total_count":1,"workflow_runs":[{"id":201,"status":"completed","conclusion":"success","name":"CI"}]}'
            } else {
                Write-Output '{"total_count":1,"workflow_runs":[{"id":202,"status":"completed","conclusion":"failure","name":"CI"}]}'
            }
        }
        if (`$Mode -eq "post-push-missing-jobs") {
            Write-Output '{"total_count":1,"workflow_runs":[{"id":201,"status":"completed","conclusion":"success","name":"CI"}]}'
        }
        exit 0
    }
    if (`$endpoint -match "actions/runs/(\d+)/jobs") {
        if (`$Mode -eq "api-error" -or `$Mode -eq "404") {
            Write-Output "HTTP 404: Not Found"
            exit 1
        }
        if (`$Mode -eq "red") {
            Write-Output '{"total_count":1,"jobs":[{"name":"windows-ci","conclusion":"failure"}]}'
            exit 0
        }
        if (`$Mode -eq "post-push-red") {
            `$runId = `$Matches[1]
            if (`$runId -eq "202") {
                Write-Output '{"total_count":1,"jobs":[{"name":"windows-ci","conclusion":"failure"}]}'
                exit 0
            }
            Write-Output '{"total_count":1,"jobs":[{"name":"windows-ci","conclusion":"success"}]}'
            exit 0
        }
        if (`$Mode -eq "post-push-missing-jobs") {
            `$jobsFile = Join-Path `$PSScriptRoot "jobs_count.txt"
            `$count = 0
            if (Test-Path `$jobsFile) {
                `$count = [int](Get-Content `$jobsFile -Raw)
            }
            `$count++
            `$count | Set-Content `$jobsFile
            if (`$count -eq 1) {
                Write-Output '{"total_count":1,"jobs":[{"name":"coverage-windows","conclusion":"success"}]}'
            } else {
                Write-Output '{"total_count":1,"jobs":[{"name":"other-job","conclusion":"success"}]}'
            }
            exit 0
        }
        Write-Output '{"total_count":1,"jobs":[{"name":"windows-ci","conclusion":"success"}]}'
        exit 0
    }
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
    # Identity string only - the next line overrides the push URL to a local bare repo, so this
    # is never dialed. Keep the host github.com so these cases exercise the github.com path in
    # Get-OriginRepoIdentity (watch-adopter-ci.ps1:74-83); GHES host dispatch is covered by
    # watch-adopter-ci.tests.ps1.
    git -C $localRepo remote add origin "https://github.com/gate-fixture-owner/gate-fixture-repo.git"
    git -C $localRepo remote set-url --push origin $originRepo

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
        [Parameter(Mandatory=$true)][string]$TaskId,
        [switch]$OmitLogFile
    )
    $scriptPath = Join-Path (Split-Path -Parent $Case.LocalRepo) ("run-" + $TaskId + ".ps1")
    $libPath = $CRUCIBLE_LIB.Replace("'", "''")
    $localRepo = $Case.LocalRepo.Replace("'", "''")
    $sessionDir = $Case.SessionDir.Replace("'", "''")
    $logFile = (Join-Path $Case.SessionDir ($TaskId + "/pipeline.log.jsonl")).Replace("'", "''")
    $cbFile = (Join-Path $Case.SessionDir "global/circuit_breakers.jsonl").Replace("'", "''")

    $logSetup = ""
    $ctxLogEntries = ""
    if (-not $OmitLogFile) {
        $ctxLogEntries = @"
    LogFile = '$logFile'
    CircuitBreakerHistoryFile = '$cbFile'
"@
    }

    $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
$logSetup
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
$ctxLogEntries
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
        LogFile = (Join-Path $Case.SessionDir ($TaskId + "/pipeline.log.jsonl"))
    }
}
$tempRoot = New-TestFixtureRoot -NameHint "crucible-gates-human-test"
try {
    $results += Run-Test -Name "New-FakeGhForGate parses endpoint when flags precede endpoint" -Body {
        $caseRoot = Join-Path $tempRoot "fake-gh-flags"
        $binDir = Join-Path $caseRoot "bin"
        $ghPath = New-FakeGhForGate -Dir $binDir -Mode "green"
        $out = & $ghPath api --hostname ghe.example.com repos/o/r/actions/workflows
        Assert-Result -Name "fake gh api exit code with preceding flag" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit code 0, got $LASTEXITCODE. Output:`n$out")
        Assert-Result -Name "fake gh api output matches workflows with preceding flag" -Condition ($out -match "workflows") -FailureMessage ("expected output matching 'workflows', got:`n$out")
    }

    $results += Run-Test -Name "Write-WedgeReport formats recurring merge conflict recovery for human gate breakers" -Body {
        $lines = @(Get-WedgeReportLines -TaskId "F-HUM" -SourcePhase "deployment" -TargetPhase "implementation" -BreakerCode "recurring_merge_conflicts" -Why "merge conflict persisted")
        $text = $lines -join "`n"
        Assert-Result -Name "human gate wedge sentinel" -Condition ($text -match "\[STOP\] HUMAN INTERVENTION REQUIRED") -FailureMessage ("missing stop sentinel. Output:`n" + $text)
        Assert-Result -Name "human gate wedge phase" -Condition ($text -match "PHASE:\s+deployment -> implementation") -FailureMessage ("missing phase line. Output:`n" + $text)
        Assert-Result -Name "human gate wedge code" -Condition ($text -match [regex]::Escape("(recurring_merge_conflicts)")) -FailureMessage ("missing breaker code. Output:`n" + $text)
        Assert-Result -Name "human gate wedge recovery" -Condition ($text -match "(?m)^RECOVERY:\s+\S") -FailureMessage ("missing recovery line. Output:`n" + $text)
    }

    $results += Run-Test -Name "Invoke-HumanGateMerge recurring conflict breaker emits wedge output without handoff" -Body {
        $caseRoot = Join-Path $tempRoot "merge-breaker-no-handoff"
        $localRepo = Join-Path $caseRoot "local_repo"
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        git -C $localRepo init --quiet
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"
        git -C $localRepo config commit.gpgSign false

        "base" | Set-Content -LiteralPath (Join-Path $localRepo "conflict.txt") -Encoding UTF8
        git -C $localRepo add conflict.txt
        git -C $localRepo commit -m "base" --quiet
        git -C $localRepo branch -M master

        git -C $localRepo checkout -b task/F-HUM-BREAK --quiet
        "task" | Set-Content -LiteralPath (Join-Path $localRepo "conflict.txt") -Encoding UTF8
        git -C $localRepo add conflict.txt
        git -C $localRepo commit -m "task change" --quiet

        git -C $localRepo checkout master --quiet
        "primary" | Set-Content -LiteralPath (Join-Path $localRepo "conflict.txt") -Encoding UTF8
        git -C $localRepo add conflict.txt
        git -C $localRepo commit -m "primary change" --quiet

        $script:LOG_FILE = Join-Path $localRepo ".crucible/session/F-HUM-BREAK/pipeline.log.jsonl"
        $script:CB_HISTORY_FILE = Join-Path $localRepo ".crucible/session/global/circuit_breakers.jsonl"
        $script:backlogDir = Join-Path $localRepo ".crucible/backlog"
        $script:FRAMEWORK_POWERSHELL = Split-Path -Parent $CRUCIBLE_LIB
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:LOG_FILE), (Split-Path -Parent $script:CB_HISTORY_FILE), $script:backlogDir -Force | Out-Null

        $script:HumanGateMergeBreakerResult = $null
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            Push-Location $localRepo
            $outputLines = @(& {
                $script:HumanGateMergeBreakerResult = Invoke-HumanGateMerge -TaskId "F-HUM-BREAK" -PrimaryBranch "master" -ProjectRoot $localRepo -Handoff $null -MaxRebaseAttempts 0 `
                    -LogFile $script:LOG_FILE -CircuitBreakerHistoryFile $script:CB_HISTORY_FILE
            } 6>&1)
        } finally {
            Pop-Location
            $ErrorActionPreference = $previous
        }
        $mergeResult = $script:HumanGateMergeBreakerResult
        $script:HumanGateMergeBreakerResult = $null
        $outputText = ($outputLines | ForEach-Object { [string]$_ }) -join "`n"

        Assert-Result -Name "human gate merge breaker result" -Condition ($mergeResult -eq "breaker") -FailureMessage ("expected breaker, got " + $mergeResult)
        Assert-Result -Name "human gate merge wedge sentinel" -Condition ($outputText -match "\[STOP\] HUMAN INTERVENTION REQUIRED") -FailureMessage ("missing wedge sentinel. Output:`n" + $outputText)
        Assert-Result -Name "human gate merge wedge task" -Condition ($outputText -match "TASK:\s+F-HUM-BREAK") -FailureMessage ("missing task line. Output:`n" + $outputText)
        Assert-Result -Name "human gate merge wedge phase" -Condition ($outputText -match "PHASE:\s+deployment -> deployment") -FailureMessage ("missing deployment phase line. Output:`n" + $outputText)
        Assert-Result -Name "human gate merge wedge code" -Condition ($outputText -match [regex]::Escape("(recurring_merge_conflicts)")) -FailureMessage ("missing recurring_merge_conflicts wedge code. Output:`n" + $outputText)
        Assert-Result -Name "human gate merge why keeps conflict detail" -Condition ($outputText -match [regex]::Escape("still conflicts with master")) -FailureMessage ("missing conflict detail. Output:`n" + $outputText)
        Assert-Result -Name "human gate merge wedge recovery" -Condition ($outputText -match "(?m)^RECOVERY:\s+\S") -FailureMessage ("missing recovery line. Output:`n" + $outputText)
    }

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
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")

        # Test Case 1: Accepted outcome -> should push changes to origin
        $scriptContentAccept = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")

        # Test Case 1: Accept with no-op push
        Reset-PendingFiles
        $scriptAcceptNoOp = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
        $scriptReject = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
        $scriptReject = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
        $scriptReject = @"
`$ErrorActionPreference = "Continue"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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

        # Item 103, and two assertions about one defect because neither alone would have caught it.
        # The generated helper built its scratch path from a Windows-only variable name, which is
        # empty off Windows, so an adopter on Linux got a difftool that opened nothing. The text
        # assertions are the regression lock and hold on every platform - the defect is entirely in
        # which name the emitted script says, and that name resolves fine here, so a Windows run
        # that only executed the helper passed for as long as the bug existed. The execution below
        # is what a text check cannot do: prove the emitted line is PowerShell that actually
        # resolves, which a substring match would still report clean if the call were pasted in
        # without the parentheses Join-Path needs around it.
        Assert-Result -Name "review-diff.ps1 resolves its scratch directory portably" -Condition ($helperContent -match '\[System\.IO\.Path\]::GetTempPath\(\)') -FailureMessage (
            "the generated helper does not resolve its scratch directory by the one call that works on all three " +
            "platforms, so it works on at most one. Helper body:`n" + $helperContent)
        Assert-Result -Name "review-diff.ps1 does not name the temp directory by a platform-specific variable" -Condition ($helperContent -cnotmatch '\$env:(TEMP|TMP|TMPDIR)\b') -FailureMessage (
            "the generated helper names a temp variable that is defined on one platform and empty on the others. " +
            "Helper body:`n" + $helperContent)

        # Run the generated body, with the temp directory redirected under this case's own root.
        # That keeps the copies out of the developer's temp directory, and it makes the assertion
        # measure the redirect rather than assume it: a redirect that does not take leaves this
        # count at zero and fails, rather than quietly passing on litter somebody else's run left
        # behind.
        $prevTemp = $env:TEMP
        $prevTmp = $env:TMP
        $prevTmpDir = $env:TMPDIR
        try {
            $scratchHome = Join-Path $caseRoot "helper-temp"
            New-Item -ItemType Directory -Path $scratchHome -Force | Out-Null
            # All three names on both platforms rather than behind a branch, for the reason item
            # 102 records against run-lock.tests.ps1: each is ignored where it does not apply, and
            # a branch here is a second place to be wrong about which one an edition reads.
            $env:TEMP = $scratchHome
            $env:TMP = $scratchHome
            $env:TMPDIR = $scratchHome

            $leftFile = Join-Path $caseRoot "helper-left.txt"
            $rightFile = Join-Path $caseRoot "helper-right.txt"
            "left side" | Set-Content -LiteralPath $leftFile -Encoding UTF8
            "right side" | Set-Content -LiteralPath $rightFile -Encoding UTF8

            # Everything the helper does except its last line, which launches the configured diff
            # tool. That line is dropped on purpose and the drop is asserted rather than assumed:
            # "zed" resolves to a real installed editor on a developer machine, and running the
            # helper whole opens a GUI that never exits, so the suite hangs instead of failing.
            # That is why the block below this one replaces the helper with a stub before executing
            # it - and why replacing it is not enough on its own, since a stub proves nothing about
            # the body that was generated.
            #
            # What is kept is the whole of the part under test: resolving the scratch directory,
            # creating it, and copying both sides. Removing the last line and naming what was
            # removed keeps the distinction visible, where trusting a missing binary would leave a
            # test that passes on CI and hangs the first time someone installs the tool.
            $helperLines = @($helperContent -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
            $launchLine = if ($helperLines.Count -gt 0) { $helperLines[$helperLines.Count - 1] } else { "" }
            Assert-Result -Name "the helper's last line is the diff tool launch" -Condition ($launchLine -match '^&\s+".+"\s+--diff') -FailureMessage (
                "expected the generated helper to end with the diff tool launch, so that dropping its last line " +
                "drops exactly that. Last line was '" + $launchLine + "'. Helper body:`n" + $helperContent)

            $bodyPath = Join-Path $caseRoot "review-diff-body.ps1"
            ($helperLines[0..($helperLines.Count - 2)] -join "`n") | Set-Content -LiteralPath $bodyPath -Encoding UTF8
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $bodyPath $leftFile $rightFile 2>&1 | Out-Null

            $copies = @(Get-ChildItem -Path $scratchHome -Recurse -File -ErrorAction SilentlyContinue)
            Assert-Result -Name "the generated helper copies both sides into the scratch directory it resolved" -Condition ($copies.Count -eq 2) -FailureMessage (
                "expected the helper to copy two files below '" + $scratchHome + "', found " + $copies.Count +
                ". A helper whose temp lookup returns nothing copies neither side and reports nothing, which is " +
                "exactly what an adopter sees as a diff tool that opens on an empty pair.")
        } finally {
            $env:TEMP = $prevTemp
            $env:TMP = $prevTmp
            $env:TMPDIR = $prevTmpDir
        }

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

    $results += Run-Test -Name "Human gate re-run on an unfilled pending template prints the review surface" -Body {
        # Invoke-HumanGate builds the review surface in two arms: one when no pending
        # template exists yet (create it and print), one when a template exists with its
        # outcome still unfilled - the operator re-ran crucible.ps1 before answering. The
        # two arms are the same 87 lines twice, and only the first was covered: an
        # unconditional throw at the top of the second failed nothing in this file. Two
        # copies that nothing compares can drift, and the tested copy stays green while
        # the operator-facing one rots. This drives the second arm.
        #
        # It also pins the one real difference between them. The unfilled-template arm
        # must PREFER the base_sha/branch_sha already recorded in the template over a
        # fresh Get-GateReviewRange computation, so the human reviews the range the gate
        # fired on rather than a range that moved underneath them. The recorded branch
        # sha below is deliberately an ancestor of the task tip, so "read the template"
        # and "recompute" give different answers and the assertion can tell them apart.
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "gate-pending-template"
        $localRepo = Join-Path $caseRoot "local"
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        git -C $localRepo init --initial-branch=master 2>$null | Out-Null
        git -C $localRepo config user.name "Tester"
        git -C $localRepo config user.email "test@example.com"

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

        git -C $localRepo checkout -b task/F-890 2>$null | Out-Null
        "first" | Set-Content -LiteralPath (Join-Path $localRepo "one.txt") -Encoding UTF8
        git -C $localRepo add one.txt 2>$null | Out-Null
        git -C $localRepo commit -m "first commit on task branch" 2>$null | Out-Null
        $recordedSha = (git -C $localRepo rev-parse HEAD).Trim()

        "second" | Set-Content -LiteralPath (Join-Path $localRepo "two.txt") -Encoding UTF8
        git -C $localRepo add two.txt 2>$null | Out-Null
        git -C $localRepo commit -m "second commit on task branch" 2>$null | Out-Null
        $tipSha = (git -C $localRepo rev-parse HEAD).Trim()

        Assert-Result -Name "recorded sha differs from the task tip" -Condition ($recordedSha -ne $tipSha) -FailureMessage "the test needs two distinct task-branch commits for the range assertions below to mean anything"

        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        # The template as the previous gate firing left it: outcome still the placeholder
        # the human is meant to overwrite.
        $pendingTemplate = Join-Path $gateDir "gate_decision_F-890_pending.json"
        $templateJson = @"
{
    "task_id":  "F-890",
    "backlog_item":  "F-890",
    "gate_fired_at":  "2026-01-01T00:00:00Z",
    "outcome":  "accepted | rejected | redirected | abandoned",
    "reason":  "Brief human description of why",
    "rework_requested":  false,
    "redirect_target":  null,
    "base_sha":  "$baseSha",
    "branch_sha":  "$recordedSha"
}
"@
        $templateJson | Set-Content -LiteralPath $pendingTemplate -Encoding UTF8

        $scriptPath = Join-Path $caseRoot "run-pending-template-test.ps1"
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
    GateOutcome = `$null
    GateReason = `$null
    GateRedirectTarget = `$null
    CrucibleRoot = '$localRepo'
    Quiet = `$true
    Handoff = [PSCustomObject]@{
        task_id = 'F-890'
        source_phase = 'deployment'
        target_phase = 'done'
        commit_hash = '$tipSha'
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

        Assert-Result -Name "unfilled template prompts the human to complete the decision" -Condition ($outputText -like "*Action Required*") -FailureMessage "expected the unfilled-template arm to ask for the gate decision, got:`n$outputText"
        Assert-Result -Name "unfilled template arm emits the visual diff tool command" -Condition ($outputText -like "*difftool*") -FailureMessage "expected output to contain 'difftool', got:`n$outputText"
        Assert-Result -Name "unfilled template arm emits the editor command" -Condition ($outputText -like "*code*") -FailureMessage "expected output to contain 'code' (from editor configuration), got:`n$outputText"

        $helperPath = Join-Path $sessionDir "F-890/review-diff.ps1"
        Assert-Result -Name "unfilled template arm generates review-diff.ps1" -Condition (Test-Path $helperPath) -FailureMessage "expected $helperPath to exist"

        $menuPath = Join-Path $sessionDir "F-890/gate_pending.txt"
        Assert-Result -Name "unfilled template arm writes the machine-readable menu" -Condition (Test-Path $menuPath) -FailureMessage "expected $menuPath to exist"
        if (Test-Path $menuPath) {
            $menuText = Get-Content -LiteralPath $menuPath -Raw
            Assert-Result -Name "menu offers all four outcomes" -Condition (($menuText -like "*1) Accept*") -and ($menuText -like "*2) Reject*") -and ($menuText -like "*3) Redirect*") -and ($menuText -like "*4) Abandon*")) -FailureMessage "expected the four-outcome menu, got:`n$menuText"
        }

        # The range the human is shown must be the template's, not a recomputed one.
        $textDiffLines = @($outputText -split "`n" | Where-Object { $_.Trim() -like "git -C *" -and $_ -notlike "*difftool*" })
        Assert-Result -Name "found exactly one emitted text diff command" -Condition ($textDiffLines.Count -eq 1) -FailureMessage "expected exactly 1 plain git diff command line, found $($textDiffLines.Count):`n$outputText"
        if ($textDiffLines.Count -eq 1) {
            $emittedRange = $textDiffLines[0].Trim()
            Assert-Result -Name "review range comes from the pending template" -Condition ($emittedRange -like "*$baseSha..$recordedSha") -FailureMessage "expected the emitted range to end with the template's $baseSha..$recordedSha, got:`n$emittedRange"
            Assert-Result -Name "review range was not recomputed to the task tip" -Condition ($emittedRange -notlike "*$tipSha*") -FailureMessage "the emitted range used the task branch tip $tipSha, so the template's recorded branch_sha was ignored:`n$emittedRange"
        }
    }

    $results += Run-Test -Name "No-Code Closure (no task branch): gate prints No-Code Closure message, not a diff/worktree surface" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "gate-nocode-closure"
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

        # NOTE: deliberately NO task/R-900 branch is created (No-Code Closure research closure).
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path (Join-Path $sessionDir "global/gate_decisions") -Force | Out-Null

        $scriptPath = Join-Path $caseRoot "run-nocode-closure.ps1"
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
        @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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

        Assert-Result -Name "No-Code Closure: gate prints the No-Code Closure message" -Condition ($outputText -like "*No-Code Closure*") -FailureMessage "expected 'No-Code Closure' message, got:`n$outputText"
        Assert-Result -Name "No-Code Closure: no difftool command emitted (no task branch)" -Condition ($outputText -notlike "*difftool*") -FailureMessage "expected NO difftool command for a no-branch closure, got:`n$outputText"
        Assert-Result -Name "No-Code Closure: no text git-diff review command emitted" -Condition ($outputText -notlike "*diff $baseSha..$baseSha*") -FailureMessage "expected NO degenerate commit..commit diff command, got:`n$outputText"
        $pendingFile = Join-Path $sessionDir "R-900/gate_pending.txt"
        Assert-Result -Name "No-Code Closure: gate_pending.txt written" -Condition (Test-Path $pendingFile) -FailureMessage "expected gate_pending.txt at $pendingFile"
        if (Test-Path $pendingFile) {
            $pendingText = Get-Content $pendingFile -Raw
            Assert-Result -Name "No-Code Closure: gate_pending menu carries the No-Code Closure message" -Condition ($pendingText -like "*No-Code Closure*") -FailureMessage "expected gate_pending.txt to contain the No-Code Closure message, got:`n$pendingText"
        }
    }

    $results += Run-Test -Name "No-Code Closure resolves the actual findings doc path into the review hint" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "gate-nocode-closure-findings"
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

        $scriptPath = Join-Path $caseRoot "run-nocode-closure-findings.ps1"
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
        @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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

        Assert-Result -Name "No-Code Closure: review hint names the actual findings doc" -Condition ($outputText -like "*.crucible/research/R-901_findings.md*") -FailureMessage "expected the resolved findings path, got:`n$outputText"
        Assert-Result -Name "No-Code Closure: no literal placeholder remains" -Condition ($outputText -notlike "*<findings doc>*") -FailureMessage "expected no '<findings doc>' placeholder, got:`n$outputText"
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
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")

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
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
        $fwPwsh = (Split-Path -Parent $CRUCIBLE_LIB).Replace("'", "''")
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$true
. '$libPath'
`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    LogFile = (Join-Path '$sessionDir' 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
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

    $results += Run-Test -Name "Invoke-HumanGate require_green_ci blocks when gh is unauthenticated" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "ci-gh-absent"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $case = New-CiGateCase -CaseRoot $caseRoot -TaskId "F-CIA"
        $originRepo = Join-Path $caseRoot "remote_origin"
        $preMergeSha = (git -C $originRepo rev-parse master).Trim()

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

        Assert-Result -Name "ci unauth exits 1" -Condition ($result.ExitCode -eq 1) -FailureMessage ("expected 1, got " + $result.ExitCode + ". Output:`n" + $result.Output)
        Assert-Result -Name "ci unauth reports failure" -Condition ($result.Output -match "\[HUMAN GATE\] CI_CHECK_FAILED") -FailureMessage $result.Output
        $postMergeOriginSha = (git -C $originRepo rev-parse master).Trim()
        Assert-Result -Name "ci unauth master branch tip on origin unchanged" -Condition ($postMergeOriginSha -eq $preMergeSha) -FailureMessage ("expected origin master tip $preMergeSha, got $postMergeOriginSha")
        git -C $case.LocalRepo show-ref --quiet refs/heads/task/F-CIA
        Assert-Result -Name "ci unauth keeps task branch" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "task branch was deleted after failed CI watch"
        $logLines = @()
        if (Test-Path -LiteralPath $result.LogFile) {
            $logLines = @(Get-Content -LiteralPath $result.LogFile -Encoding UTF8 | Where-Object { $_ -match '"event":"ci_check_failed"' })
        }
        Assert-Result -Name "ci unauth writes ci_check_failed event to log" -Condition ($logLines.Count -ge 1) -FailureMessage ("expected ci_check_failed in " + $result.LogFile + ", got: " + (Get-Content -LiteralPath $result.LogFile -ErrorAction SilentlyContinue | Out-String))
    }

    $results += Run-Test -Name "Invoke-HumanGate require_green_ci blocks when gh returns API 404" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "ci-api-404"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $case = New-CiGateCase -CaseRoot $caseRoot -TaskId "F-404"
        $originRepo = Join-Path $caseRoot "remote_origin"
        $preMergeSha = (git -C $originRepo rev-parse master).Trim()

        $binDir = Join-Path $caseRoot "bin"
        New-FakeGhForGate -Dir $binDir -Mode "404" | Out-Null
        $oldPath = $env:PATH
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $oldPath
            $result = Invoke-CiGateCase -Case $case -TaskId "F-404"
        } finally {
            $env:PATH = $oldPath
        }

        Assert-Result -Name "ci 404 exits 1" -Condition ($result.ExitCode -eq 1) -FailureMessage ("expected 1, got " + $result.ExitCode + ". Output:`n" + $result.Output)
        Assert-Result -Name "ci 404 reports failure" -Condition ($result.Output -match "\[HUMAN GATE\] CI_CHECK_FAILED") -FailureMessage $result.Output
        $postMergeOriginSha = (git -C $originRepo rev-parse master).Trim()
        Assert-Result -Name "ci 404 master branch tip on origin unchanged" -Condition ($postMergeOriginSha -eq $preMergeSha) -FailureMessage ("expected origin master tip $preMergeSha, got $postMergeOriginSha")
        $logLines = @()
        if (Test-Path -LiteralPath $result.LogFile) {
            $logLines = @(Get-Content -LiteralPath $result.LogFile -Encoding UTF8 | Where-Object { $_ -match '"event":"ci_check_failed"' })
        }
        Assert-Result -Name "ci 404 writes ci_check_failed event to log" -Condition ($logLines.Count -ge 1) -FailureMessage ("expected ci_check_failed in " + $result.LogFile + ", got: " + (Get-Content -LiteralPath $result.LogFile -ErrorAction SilentlyContinue | Out-String))
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
        # The advisory after the timeout warning is the operator's only pointer to the
        # still-running CI. It comes from Write-GateCiRunUrl, deduplicated out of the
        # timeout and queue-stall arms; nothing named its output before.
        Assert-Result -Name "f3 timeout advisory points at the CI run" -Condition ($result.Output -match "CI run URL:") -FailureMessage $result.Output
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

        git -C $case.LocalRepo remote set-url --push origin "invalid/path/repo.git"

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

    $results += Run-Test -Name "F3: MISSING_REQUIRED_JOBS withholds master push and deletes staging ref" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "f3-ci-missing-jobs"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $case = New-CiGateCase -CaseRoot $caseRoot -TaskId "F3-MSJ"
        $originRepo = Join-Path $caseRoot "remote_origin"
        $preMergeSha = (git -C $originRepo rev-parse master).Trim()

        $configPath = Join-Path $case.LocalRepo ".crucible/config.yaml"
        $configYaml = (Get-Content -LiteralPath $configPath -Raw) + "`n  ci_required_checks: coverage-windows"
        $configYaml | Set-Content -LiteralPath $configPath -Encoding UTF8

        $binDir = Join-Path $caseRoot "bin"
        New-FakeGhForGate -Dir $binDir -Mode "green" | Out-Null
        $oldPath = $env:PATH
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $oldPath
            $result = Invoke-CiGateCase -Case $case -TaskId "F3-MSJ"
        } finally {
            $env:PATH = $oldPath
        }

        Assert-Result -Name "f3 missing jobs exits 1" -Condition ($result.ExitCode -eq 1) -FailureMessage ("expected 1, got " + $result.ExitCode + ". Output:`n" + $result.Output)
        Assert-Result -Name "f3 missing jobs output indicates refusing to publish" -Condition ($result.Output -match "MISSING_REQUIRED_JOBS: Staging CI run for .* is missing required jobs") -FailureMessage $result.Output
        $postMergeOriginSha = (git -C $originRepo rev-parse master).Trim()
        Assert-Result -Name "f3 missing jobs master tip on origin unchanged" -Condition ($postMergeOriginSha -eq $preMergeSha) -FailureMessage ("expected origin master tip $preMergeSha, got $postMergeOriginSha")
        git -C $originRepo show-ref --quiet refs/heads/crucible-ci/F3-MSJ
        Assert-Result -Name "f3 missing jobs deleted staging branch on origin" -Condition ($LASTEXITCODE -ne 0) -FailureMessage "staging branch was not deleted on missing required jobs"
        $logLines = @()
        if (Test-Path -LiteralPath $result.LogFile) {
            $logLines = @(Get-Content -LiteralPath $result.LogFile -Encoding UTF8 | Where-Object { $_ -match '"event":"ci_missing_required_jobs"' })
        }
        Assert-Result -Name "f3 missing jobs writes ci_missing_required_jobs event to log" -Condition ($logLines.Count -ge 1) -FailureMessage ("expected ci_missing_required_jobs in " + $result.LogFile + ", got: " + (Get-Content -LiteralPath $result.LogFile -ErrorAction SilentlyContinue | Out-String))
    }

    $results += Run-Test -Name "F3: ci_post_push_watch records post_push_ci_red event and keeps going" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "f3-post-push-red"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $case = New-CiGateCase -CaseRoot $caseRoot -TaskId "F3-PPR"
        $originRepo = Join-Path $caseRoot "remote_origin"

        $configPath = Join-Path $case.LocalRepo ".crucible/config.yaml"
        $configYaml = (Get-Content -LiteralPath $configPath -Raw) + "`n  ci_post_push_watch: true"
        $configYaml | Set-Content -LiteralPath $configPath -Encoding UTF8

        $binDir = Join-Path $caseRoot "bin"
        New-FakeGhForGate -Dir $binDir -Mode "post-push-red" | Out-Null
        $oldPath = $env:PATH
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $oldPath
            $result = Invoke-CiGateCase -Case $case -TaskId "F3-PPR"
        } finally {
            $env:PATH = $oldPath
        }

        Assert-Result -Name "post push red exits 0" -Condition ($result.ExitCode -eq 0) -FailureMessage ("expected 0, got " + $result.ExitCode + ". Output:`n" + $result.Output)
        Assert-Result -Name "post push red reports status" -Condition ($result.Output -match "\[CI WATCH\] STATUS=POST_PUSH_RED") -FailureMessage $result.Output
        $postMergeLocalSha = (git -C $case.LocalRepo rev-parse master).Trim()
        $postMergeOriginSha = (git -C $originRepo rev-parse master).Trim()
        Assert-Result -Name "post push red master branch updated on origin" -Condition ($postMergeOriginSha -eq $postMergeLocalSha) -FailureMessage ("expected origin master tip $postMergeLocalSha, got $postMergeOriginSha")
        $logLines = @()
        if (Test-Path -LiteralPath $result.LogFile) {
            $logLines += @(Get-Content -LiteralPath $result.LogFile -Encoding UTF8)
        }
        $archivedLogs = @(Get-ChildItem -Path (Join-Path $case.SessionDir "archived") -Filter "pipeline-F3-PPR-*.log.jsonl" -File -ErrorAction SilentlyContinue)
        foreach ($f in $archivedLogs) {
            $logLines += @(Get-Content -LiteralPath $f.FullName -Encoding UTF8)
        }
        $matchedLines = @($logLines | Where-Object { $_ -match '"event":"post_push_ci_red"' })
        Assert-Result -Name "post push red writes post_push_ci_red event to log" -Condition ($matchedLines.Count -ge 1) -FailureMessage ("expected post_push_ci_red in log, found: " + ($logLines -join "`n"))
    }

    $results += Run-Test -Name "F3: ci_post_push_watch records post_push_ci_missing_required_jobs event and keeps going" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "f3-post-push-msj"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $case = New-CiGateCase -CaseRoot $caseRoot -TaskId "F3-PMS"
        $originRepo = Join-Path $caseRoot "remote_origin"

        $configPath = Join-Path $case.LocalRepo ".crucible/config.yaml"
        $configYaml = (Get-Content -LiteralPath $configPath -Raw) + "`n  ci_post_push_watch: true`n  ci_required_checks: coverage-windows"
        $configYaml | Set-Content -LiteralPath $configPath -Encoding UTF8

        $binDir = Join-Path $caseRoot "bin"
        New-FakeGhForGate -Dir $binDir -Mode "post-push-missing-jobs" | Out-Null
        $oldPath = $env:PATH
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $oldPath
            $result = Invoke-CiGateCase -Case $case -TaskId "F3-PMS"
        } finally {
            $env:PATH = $oldPath
        }

        Assert-Result -Name "post push missing jobs exits 0" -Condition ($result.ExitCode -eq 0) -FailureMessage ("expected 0, got " + $result.ExitCode + ". Output:`n" + $result.Output)
        Assert-Result -Name "post push missing jobs reports status" -Condition ($result.Output -match "\[CI WATCH\] STATUS=POST_PUSH_MISSING_REQUIRED_JOBS") -FailureMessage $result.Output
        $postMergeLocalSha = (git -C $case.LocalRepo rev-parse master).Trim()
        $postMergeOriginSha = (git -C $originRepo rev-parse master).Trim()
        Assert-Result -Name "post push missing jobs master branch updated on origin" -Condition ($postMergeOriginSha -eq $postMergeLocalSha) -FailureMessage ("expected origin master tip $postMergeLocalSha, got $postMergeOriginSha")
        $logLines = @()
        if (Test-Path -LiteralPath $result.LogFile) {
            $logLines += @(Get-Content -LiteralPath $result.LogFile -Encoding UTF8)
        }
        $archivedLogs = @(Get-ChildItem -Path (Join-Path $case.SessionDir "archived") -Filter "pipeline-F3-PMS-*.log.jsonl" -File -ErrorAction SilentlyContinue)
        foreach ($f in $archivedLogs) {
            $logLines += @(Get-Content -LiteralPath $f.FullName -Encoding UTF8)
        }
        $matchedLines = @($logLines | Where-Object { $_ -match '"event":"post_push_ci_missing_required_jobs"' })
        Assert-Result -Name "post push missing jobs writes post_push_ci_missing_required_jobs event to log" -Condition ($matchedLines.Count -ge 1) -FailureMessage ("expected post_push_ci_missing_required_jobs in log, found: " + ($logLines -join "`n"))
    }

    # This test used to assert the opposite: that a context with no LogFile ran through
    # to a CI_CHECK_FAILED verdict without a StrictMode "variable cannot be retrieved"
    # crash. Tolerating the omission is what let Invoke-HumanGateAction resolve its five
    # event destinations out of an ancestor frame, or drop the events entirely. The real
    # concern behind the original test survives - a bare context must not surface as an
    # unhelpful variable error - and is now met by naming the missing key instead.
    $results += Run-Test -Name "Invoke-HumanGate rejects a context with no log destination, naming the key" -Body {
        $ErrorActionPreference = "Continue"
        $caseRoot = Join-Path $tempRoot "ci-no-logfile"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $case = New-CiGateCase -CaseRoot $caseRoot -TaskId "F-NOL"
        $binDir = Join-Path $caseRoot "bin"
        New-FakeGhForGate -Dir $binDir -Mode "unauth" | Out-Null
        $oldPath = $env:PATH
        try {
            $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $oldPath
            $result = Invoke-CiGateCase -Case $case -TaskId "F-NOL" -OmitLogFile
        } finally {
            $env:PATH = $oldPath
        }

        Assert-Result -Name "no-logfile context exits 1" -Condition ($result.ExitCode -eq 1) -FailureMessage ("expected 1, got " + $result.ExitCode + ". Output:`n" + $result.Output)
        Assert-Result -Name "no-logfile context names the missing key" -Condition ($result.Output -match "Required key 'LogFile' is missing from CrucibleContext") -FailureMessage $result.Output
        Assert-Result -Name "no-logfile context fails before reaching the CI verdict" -Condition ($result.Output -notmatch "\[HUMAN GATE\] CI_CHECK_FAILED") -FailureMessage ("the gate ran to a CI verdict on a context with no log destination:`n" + $result.Output)
        Assert-Result -Name "no-logfile context does not surface a StrictMode variable error" -Condition ($result.Output -notmatch "The variable '\`$LOG_FILE' cannot be retrieved") -FailureMessage $result.Output
    }

    $results += Run-Test -Name "Get-ActionsUrlFromOriginUrl maps GitHub remotes to their Actions page" -Body {
        # The gate prints this URL when it finalizes without a confirmed CI verdict, so
        # a wrong translation sends the human to somebody else's runs - or to nothing.
        # A remote that is not recognizably GitHub comes back untouched rather than
        # bent into a github.com URL that was never checked.
        $cases = @(
            @{ In = "git@github.com:allthingscode/crucible.git"; Out = "https://github.com/allthingscode/crucible/actions" },
            @{ In = "git@github.com:allthingscode/crucible"; Out = "https://github.com/allthingscode/crucible/actions" },
            @{ In = "https://github.com/allthingscode/crucible.git"; Out = "https://github.com/allthingscode/crucible/actions" },
            @{ In = "https://github.com/allthingscode/crucible"; Out = "https://github.com/allthingscode/crucible/actions" },
            @{ In = "https://github.com/allthingscode/crucible/"; Out = "https://github.com/allthingscode/crucible/actions" },
            @{ In = "  git@github.com:allthingscode/crucible.git  "; Out = "https://github.com/allthingscode/crucible/actions" },
            @{ In = "git@gitlab.com:someone/thing.git"; Out = "git@gitlab.com:someone/thing.git" },
            @{ In = "https://example.com/someone/thing.git"; Out = "https://example.com/someone/thing.git" },
            @{ In = "C:/mirrors/local-remote.git"; Out = "C:/mirrors/local-remote.git" },
            @{ In = ""; Out = "" }
        )

        foreach ($case in $cases) {
            $actual = Get-ActionsUrlFromOriginUrl -OriginUrl $case.In
            Assert-Result -Name "origin [$($case.In)] maps to [$($case.Out)]" -Condition ($actual -ceq $case.Out) -FailureMessage "expected [$($case.Out)], got [$actual]"
        }
    }

    $results += Run-Test -Name "Gate accept description tracks the auto_push setting" -Body {
        # "1) Accept" must not promise a push that will not happen. With review.auto_push
        # off the merge stays local, and a menu claiming it reached origin tells the human
        # the work shipped when it is still sitting on their machine.
        $descRoot = Join-Path $tempRoot "accept-desc"
        $cases = @(
            @{ Dir = "on"; Value = "true"; Expect = "and pushes to origin"; Reject = "(local only)" },
            @{ Dir = "off"; Value = "false"; Expect = "(local only)"; Reject = "and pushes to origin" }
        )

        foreach ($case in $cases) {
            $root = Join-Path $descRoot $case.Dir
            $cfgDir = Join-Path $root ".crucible"
            New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
            $cfg = @"
crucible_root: ".crucible"
project:
  name: "Test"
  description: "Test"
  default_branch: "master"
review:
  auto_push: $($case.Value)
"@
            $cfg | Set-Content -LiteralPath (Join-Path $cfgDir "config.yaml") -Encoding UTF8

            $desc = Get-GateAcceptDescription -PrimaryBranch "master" -ProjectRoot $root
            Assert-Result -Name "auto_push=$($case.Value) description says [$($case.Expect)]" -Condition ($desc -like "*$($case.Expect)*") -FailureMessage "got: $desc"
            Assert-Result -Name "auto_push=$($case.Value) description does not say [$($case.Reject)]" -Condition ($desc -notlike "*$($case.Reject)*") -FailureMessage "got: $desc"
            Assert-Result -Name "auto_push=$($case.Value) description names the primary branch" -Condition ($desc -like "*master*") -FailureMessage "got: $desc"
        }
    }

    $results += Run-Test -Name "Shipped instructions never hardcode an Accept line the gate did not emit" -Body {
        # The gate computes option 1 from review.auto_push, but the human never reads that
        # string if the presenter takes its menu from an SOP instead. Four shipped surfaces
        # did exactly that, each printing an Accept line that mentioned neither merging nor
        # publishing, so the auto_push-aware wording reached nobody. Found by TODO item 64.
        $offenders = @()
        $scanned = 0
        foreach ($rel in @("sops", "prompts", "docs")) {
            $dir = Join-Path $REPO_ROOT $rel
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter "*.md" -Recurse -File)) {
                # Proposals quote the code as it stood when they were written. They are design
                # history, not instructions anyone follows at a gate.
                if ($file.FullName -like "*proposals*") { continue }
                $lineNo = 0
                foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                    $lineNo++
                    if ($line -notmatch '^\s*1\)\s*Accept') { continue }
                    $scanned++
                    if ($line -match 'gate_pending\.txt' -or $line -match 'local only' -or $line -match 'auto_push') { continue }
                    $offenders += ($rel + "/" + $file.Name + ":" + $lineNo + "  " + $line.Trim())
                }
            }
        }

        # Without this the whole test passes by finding nothing: a regex that stops matching
        # reports a clean scan of zero lines, which is the same green as a correct one.
        Assert-Result -Name "the scan reached the documented menus" -Condition ($scanned -ge 4) `
            -FailureMessage "expected at least 4 documented Accept lines, found $scanned"
        Assert-Result -Name "every documented Accept line defers to the gate or states what accept publishes" `
            -Condition ($offenders.Count -eq 0) `
            -FailureMessage ("Accept lines that say nothing about merging or publishing:`n" + ($offenders -join "`n"))
    }
    $results += Run-Test -Name "An outcome matching no dispatch arm is refused, not passed over" -Body {
        # In process, deliberately: the refusal path does not exit, which is what makes
        # the whole outcome observable from here. Before the fix this call returned 0
        # having written nothing, and Invoke-HumanGate read that silence as success -
        # archiving the decision, deleting the pending template, and printing
        # "Decision recorded" in green for an outcome no arm had acted on.
        $root = Join-Path $tempRoot "bad-outcome"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $logFile = Join-Path $root "events.jsonl"
        $cbFile = Join-Path $root "circuit-breaker.jsonl"

        $message = ""
        try {
            Invoke-HumanGateAction -TaskId "F-BAD" -Outcome "accpeted" -ProjectRoot $root `
                -LogFile $logFile -CircuitBreakerHistoryFile $cbFile | Out-Null
        } catch {
            $message = [string]$_.Exception.Message
        }

        Assert-Result -Name "a misspelled outcome throws" -Condition ($message -ne "") `
            -FailureMessage "Invoke-HumanGateAction returned normally for outcome 'accpeted'"
        Assert-Result -Name "the message quotes what was received" -Condition ($message -match "accpeted") `
            -FailureMessage ("expected the rejected outcome to be named, got: " + $message)
        foreach ($valid in (Get-HumanGateOutcomes)) {
            Assert-Result -Name "the message offers '$valid'" -Condition ($message -match $valid) `
                -FailureMessage ("expected the message to list $valid, got: " + $message)
        }
        Assert-Result -Name "no event was recorded for an outcome nothing acted on" `
            -Condition (-not (Test-Path -LiteralPath $logFile) -and -not (Test-Path -LiteralPath $cbFile)) `
            -FailureMessage "a refused outcome still wrote to the event log or circuit-breaker history"
    }

    $results += Run-Test -Name "Every outcome the CLI accepts reaches a dispatch arm" -Body {
        # The pairing the fix above depends on: -GateOutcome validates against
        # Get-HumanGateOutcomes, so any value on that list which the dispatcher does not
        # recognize would pass validation and then throw as unrecognized. Asserting the
        # two agree is cheaper than asserting it four times by hand.
        $dispatcher = (Get-Command Invoke-HumanGateAction).ScriptBlock.ToString()
        foreach ($valid in (Get-HumanGateOutcomes)) {
            Assert-Result -Name "'$valid' is dispatched" -Condition ($dispatcher -match ('"' + $valid + '"')) `
                -FailureMessage "$valid passes -GateOutcome validation but appears in no arm of Invoke-HumanGateAction"
        }
    }

} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed Crucible gate test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll Crucible gate tests passed." -ForegroundColor Green
exit 0
