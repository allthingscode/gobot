$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$FACTORY_SCRIPT = Join-Path $REPO_ROOT "powershell/factory.ps1"

$results = @()

function Test-GitInitMainSupported {
    $versionText = git --version
    if ($versionText -notmatch '(\d+)\.(\d+)') { return $false }
    $major = [int]$matches[1]
    $minor = [int]$matches[2]
    return ($major -gt 2 -or ($major -eq 2 -and $minor -ge 28))
}

function Initialize-ProjectRepo {
    param([string]$ProjectRoot, [string]$Branch = "master", [string]$TaskId = "")
    New-Item -ItemType Directory -Path $ProjectRoot -Force | Out-Null
    Push-Location $ProjectRoot
    try {
        if ($Branch -eq "main") {
            git init -b main --quiet
        } else {
            git init --quiet
        }
        git config user.name "Test"
        git config user.email "test@example.com"
        git config commit.gpgSign false
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $backlogDir = Join-Path $ProjectRoot ".crucible/backlog"
        New-Item -ItemType Directory -Path $backlogDir -Force | Out-Null
        $typeDir = if ($TaskId -match "^C-") { "chores" } elseif ($TaskId -match "^B-") { "bugs" } else { "features" }
        $backlogItemCell = if ([string]::IsNullOrWhiteSpace($TaskId)) { "-" } else { "[$TaskId]($typeDir/active/${TaskId}_Test.md)" }
        $backlogRow = if ([string]::IsNullOrWhiteSpace($TaskId)) { "- | - | - | -" } else { "$backlogItemCell | Test Task | P2 | In Progress" }
        $backlogContent = @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | $(if ([string]::IsNullOrWhiteSpace($TaskId)) { "0" } else { "1" }) | $(if ([string]::IsNullOrWhiteSpace($TaskId)) { "-" } else { $TaskId }) |
| **P3** | 0 | - |

## Active Items

| Item ID | Title | Priority | Status |
|---|---|---|---|
| $backlogRow |

"@
        [System.IO.File]::WriteAllText((Join-Path $backlogDir "BACKLOG.md"), $backlogContent.Replace("`r`n", "`n").Replace("`n", "`r`n"), $utf8NoBom)
        $configContent = "project: OperatorMergeTest`r`npaths:`r`n  backlog: .crucible/backlog`r`n  session: .crucible/session`r`n  workspaces: .crucible/.agent-workspaces`r`n  prompts: .crucible/prompts`r`n  dev_logs: .crucible/dev-logs`r`n"
        [System.IO.File]::WriteAllText((Join-Path $ProjectRoot ".crucible/config.yaml"), $configContent, $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $ProjectRoot "README.md"), "# operator merge test`r`n", $utf8NoBom)

        $devLogsDir = Join-Path $ProjectRoot ".crucible/dev-logs"
        New-Item -ItemType Directory -Path $devLogsDir -Force | Out-Null
        $devLogContent = if ([string]::IsNullOrWhiteSpace($TaskId)) { "## General`r`n" } else { "## $TaskId`r`nValid dev log entry.`r`n" }
        [System.IO.File]::WriteAllText((Join-Path $devLogsDir "UNPUBLISHED_LOGS.md"), $devLogContent, $utf8NoBom)

        if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
            $typeDir = if ($TaskId -match "^C-") { "chores" } elseif ($TaskId -match "^B-") { "bugs" } else { "features" }
            $activeSpecDir = Join-Path $backlogDir "$typeDir/active"
            New-Item -ItemType Directory -Path $activeSpecDir -Force | Out-Null
            $specContent = "---`r`nitem_id: $TaskId`r`ntitle: Test Spec`r`nfile_affinity: [src/app.txt]`r`n---`r`n# $TaskId`r`n`r`n## Goal / Intent`r`nTest goal.`r`n"
            [System.IO.File]::WriteAllText((Join-Path $activeSpecDir "${TaskId}_Test.md"), $specContent, $utf8NoBom)
        }

        $gitignoreContent = "session/`r`nhandoffs/`r`n.agent-workspaces/`r`nlocks/`r`ntmp/`r`n"
        [System.IO.File]::WriteAllText((Join-Path $ProjectRoot ".crucible/.gitignore"), $gitignoreContent, $utf8NoBom)

        git add README.md .crucible/config.yaml .crucible/.gitignore .crucible/backlog/BACKLOG.md .crucible/dev-logs/UNPUBLISHED_LOGS.md .crucible/backlog/
        git commit -m "init" --quiet
        return (git rev-parse HEAD).Trim()
    } finally {
        Pop-Location
    }
}

function Finalize-TestTaskInRepo {
    param([string]$ProjectRoot, [string]$TaskId)
    Push-Location $ProjectRoot
    try {
        $backlogDir = Join-Path $ProjectRoot ".crucible/backlog"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        $typeDir = if ($TaskId -match "^C-") { "chores" } elseif ($TaskId -match "^B-") { "bugs" } else { "features" }
        $activeDir = Join-Path $backlogDir "$typeDir/active"
        $archivedDir = Join-Path $backlogDir "$typeDir/archived"
        New-Item -ItemType Directory -Path $archivedDir -Force | Out-Null
        $activeSpec = Join-Path $activeDir "${TaskId}_Test.md"
        $archivedSpec = Join-Path $archivedDir "${TaskId}_Test.md"
        if (Test-Path -LiteralPath $activeSpec) {
            $specContent = "---`r`nitem_id: $TaskId`r`ntitle: Test Spec`r`nstatus: Production`r`nfile_affinity: [src/app.txt]`r`n---`r`n# $TaskId`r`n`r`n## Goal / Intent`r`nTest goal.`r`n"
            [System.IO.File]::WriteAllText($archivedSpec, $specContent, $utf8NoBom)
            Remove-Item -LiteralPath $activeSpec -Force | Out-Null
        }

        $backlogPath = Join-Path $backlogDir "BACKLOG.md"
        $backlogContent = @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 0 | - |
| **P3** | 0 | - |

## Active Items

| Item ID | Title | Priority | Status |
|---|---|---|---|

## Archived Items

| Item ID | Title | Priority | Status |
|---|---|---|---|
| $TaskId | Test Task | P2 | Production |

"@
        [System.IO.File]::WriteAllText($backlogPath, $backlogContent.Replace("`r`n", "`n").Replace("`n", "`r`n"), $utf8NoBom)
        git add .crucible/backlog/
        git commit -m "finalize task" --quiet
    } finally {
        Pop-Location
    }
}

function New-SideBranchCommit {
    param([string]$ProjectRoot, [string]$BaseBranch)
    Push-Location $ProjectRoot
    try {
        git checkout -b side-only --quiet
        Set-Content -LiteralPath "side.txt" -Value "side branch only" -Encoding UTF8
        git add side.txt
        git commit -m "side branch commit" --quiet
        $hash = (git rev-parse HEAD).Trim()
        git checkout $BaseBranch --quiet
        return $hash
    } finally {
        Pop-Location
    }
}

function Write-OperatorHandoff {
    param(
        [string]$ProjectRoot,
        [string]$TaskId,
        [string]$Target = "done",
        [AllowNull()][string]$CommitHash,
        [AllowNull()][string]$BaseCommit,
        [string[]]$FileAffinity = @("src/app.txt")
    )
    $handoffDir = Join-Path $ProjectRoot ".crucible/session/handoffs"
    New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    $handoffPath = Join-Path $handoffDir ("${TaskId}-${timestamp}.json")
    $handoff = [ordered]@{
        task_id                  = $TaskId
        source_phase             = "deployment"
        target_phase             = $Target
        reason                   = "Operator merge verification test"
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
        artifacts                = @()
        file_affinity            = $FileAffinity
    }
    if ($null -ne $CommitHash) {
        $handoff.commit_hash = $CommitHash
    } elseif ($Target -eq "done") {
        # Schema requires commit_hash key for deployment -> done (nullable is ok)
        $handoff.commit_hash = $null
    }
    if ($null -ne $BaseCommit) {
        $handoff.base_commit = $BaseCommit
    }
    $handoff | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $handoffPath -Encoding UTF8
    return $handoffPath
}

function Invoke-FactoryForTask {
    param([string]$ProjectRoot, [string]$TaskId, [switch]$AcceptGate)
    $env:FACTORY_CYCLE_ID = "test-cycle"
    $factoryArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $FACTORY_SCRIPT, "-Init", "-TaskId", $TaskId, "-ProjectRoot", $ProjectRoot, "-Quiet")
    if ($AcceptGate) {
        $factoryArgs += @("-GateOutcome", "accepted", "-GateReason", "Commit verification test accepted")
    }
    return Invoke-ExternalCommand {
        & (Get-PwshCommand) @factoryArgs
    }
}

function Assert-VerificationBlocked {
    param([string]$ProjectRoot, [string]$TaskId, [object]$Result, [string]$ExpectedText)
    $output = $Result.Output -join "`n"
    Assert-Result -Name "exit code" -Condition ($Result.ExitCode -eq 1) -FailureMessage "expected 1, got $($Result.ExitCode). Output:`n$output"
    Assert-Result -Name "output names failure" -Condition ($output -match [regex]::Escape($ExpectedText)) -FailureMessage "expected '$ExpectedText'. Output:`n$output"

    $logPath = Join-Path $ProjectRoot ".crucible/session/$TaskId/pipeline.log.jsonl"
    Assert-Result -Name "event log exists" -Condition (Test-Path $logPath) -FailureMessage "missing event log $logPath"
    $log = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
    Assert-Result -Name "artifact verification event" -Condition ($log -match "artifact_verification_failed") -FailureMessage "event log missing artifact_verification_failed. Content:`n$log"

    $blockedDir = Join-Path $ProjectRoot ".crucible/backlog/blocked"
    $blocked = @(Get-ChildItem -Path $blockedDir -Filter "${TaskId}-*.json" -ErrorAction SilentlyContinue)
    Assert-Result -Name "blocked record" -Condition ($blocked.Count -gt 0) -FailureMessage "no blocked record found in $blockedDir"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-operator-merge-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$mainSupported = Test-GitInitMainSupported

try {
    $results += Run-Test -Name "Missing commit_hash is rejected" -Body {
        $projectRoot = Join-Path $tempRoot "missing"
        $taskId = "C-OP-MISSING"
        Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId | Out-Null
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $null | Out-Null
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "commit_hash"
    }

    $results += Run-Test -Name "Nonexistent commit_hash is rejected" -Body {
        $projectRoot = Join-Path $tempRoot "nonexistent"
        $taskId = "C-OP-NONEXISTENT"
        Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId | Out-Null
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash "ffffffffffffffffffffffffffffffffffffffff" | Out-Null
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "does not exist"
    }

    $results += Run-Test -Name "Unmerged commit_hash is rejected if gate has passed" -Body {
        $projectRoot = Join-Path $tempRoot "unmerged"
        $taskId = "C-OP-UNMERGED"
        Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId | Out-Null
        $sideHash = New-SideBranchCommit -ProjectRoot $projectRoot -BaseBranch "master"
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $sideHash | Out-Null
        
        # Seed an accepted decision to simulate gate already passed
        $gateDir = Join-Path $projectRoot ".crucible/session/global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $decision = [ordered]@{
            task_id = $taskId
            outcome = "accepted"
            session_cycle_id = "test-cycle"
        }
        $decision | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "${taskId}-20260604T120000Z.json") -Encoding UTF8

        Finalize-TestTaskInRepo -ProjectRoot $projectRoot -TaskId $taskId
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "is not merged"
    }

    $results += Run-Test -Name "Merged commit_hash passes" -Body {
        $projectRoot = Join-Path $tempRoot "happy"
        $taskId = "C-OP-HAPPY"
        $baseHash = Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId
        Push-Location $projectRoot
        try {
            git checkout -b task/$taskId --quiet
            Set-Content -LiteralPath "work.txt" -Value "merged task work" -Encoding UTF8
            git add work.txt
            git commit -m "task work" --quiet
            git checkout master --quiet
            git merge task/$taskId --no-ff -m "merge task work" --quiet
            $mergedHash = (git rev-parse HEAD).Trim()
        } finally {
            Pop-Location
        }
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $mergedHash -BaseCommit $baseHash | Out-Null
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "no verification failure" -Condition ($output -notmatch "artifact_verification_failed") -FailureMessage "unexpected verification failure. Output:`n$output"
    }

    $results += Run-Test -Name "Baseline commit_hash matching base_commit is rejected at merge verification" -Body {
        $projectRoot = Join-Path $tempRoot "baseline-rejected"
        $taskId = "C-OP-BASELINE"
        $baseHash = Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $baseHash -BaseCommit $baseHash | Out-Null

        $gateDir = Join-Path $projectRoot ".crucible/session/global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $decision = [ordered]@{
            task_id = $taskId
            outcome = "accepted"
            session_cycle_id = "test-cycle"
        }
        $decision | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "${taskId}-20260604T120000Z.json") -Encoding UTF8

        Finalize-TestTaskInRepo -ProjectRoot $projectRoot -TaskId $taskId
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "is a baseline commit"
    }

    $results += Run-Test -Name "Ignored-only file_affinity no longer bypasses merge verification" -Body {
        $projectRoot = Join-Path $tempRoot "factory-skip"
        $taskId = "C-OP-FACTORY-SKIP"
        Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId | Out-Null
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $null -FileAffinity @(".crucible/session/notes.md") | Out-Null
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "commit_hash"
    }

    $results += Run-Test -Name "Mixed affinity with unmerged commit_hash fails merge verification" -Body {
        if (-not $mainSupported) {
            Write-Host "SKIPPED: git init -b requires git >= 2.28" -ForegroundColor Yellow
            return
        }
        $projectRoot = Join-Path $tempRoot "mixed-affinity"
        $taskId = "C-OP-MIXED-AFFINITY"
        Initialize-ProjectRepo -ProjectRoot $projectRoot -Branch "main" -TaskId $taskId | Out-Null
        $sideHash = New-SideBranchCommit -ProjectRoot $projectRoot -BaseBranch "main"
        # Ignored-only file_affinity bypass has been deleted; mixed affinity with unmerged
        # commit_hash fails merge verification as expected.
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $sideHash -FileAffinity @(".crucible/session/notes.md", "src/app.go") | Out-Null

        # Seed an accepted decision
        $gateDir = Join-Path $projectRoot ".crucible/session/global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $decision = [ordered]@{
            task_id = $taskId
            outcome = "accepted"
            session_cycle_id = "test-cycle"
        }
        $decision | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "${taskId}-20260604T120000Z.json") -Encoding UTF8

        Finalize-TestTaskInRepo -ProjectRoot $projectRoot -TaskId $taskId
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "is not merged into main"
    }

    $results += Run-Test -Name "Main-default unmerged commit_hash is rejected against main if gate has passed" -Body {
        if (-not $mainSupported) {
            Write-Host "SKIPPED: git init -b requires git >= 2.28" -ForegroundColor Yellow
            return
        }
        $projectRoot = Join-Path $tempRoot "main-default"
        $taskId = "C-OP-MAIN-UNMERGED"
        Initialize-ProjectRepo -ProjectRoot $projectRoot -Branch "main" -TaskId $taskId | Out-Null
        $sideHash = New-SideBranchCommit -ProjectRoot $projectRoot -BaseBranch "main"
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $sideHash | Out-Null

        # Seed an accepted decision
        $gateDir = Join-Path $projectRoot ".crucible/session/global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $decision = [ordered]@{
            task_id = $taskId
            outcome = "accepted"
            session_cycle_id = "test-cycle"
        }
        $decision | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "${taskId}-20260604T120000Z.json") -Encoding UTF8

        Finalize-TestTaskInRepo -ProjectRoot $projectRoot -TaskId $taskId
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "is not merged into main"
    }

    # --- No-Code Closure tests ---

    $results += Run-Test -Name "No-Code Closure with null commit_hash passes (B4 shape)" -Body {
        $projectRoot = Join-Path $tempRoot "nocode-closure-null"
        $taskId = "C-OP-NOCODECLOSURE-NULL"
        Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId | Out-Null

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        # Seed .crucible/.gitignore to prevent framework-integrity breaker
        $gitignoreContent = "session/`r`nhandoffs/`r`n.agent-workspaces/`r`nlocks/`r`ntmp/`r`n"
        [System.IO.File]::WriteAllText((Join-Path $projectRoot ".crucible/.gitignore"), $gitignoreContent, $utf8NoBom)

        Push-Location $projectRoot
        try {
            git add .crucible/.gitignore
            git commit -m "add gitignore" --quiet
        } finally {
            Pop-Location
        }

        # Finalize inline: archive spec WITH type: research preserved
        $backlogDir = Join-Path $projectRoot ".crucible/backlog"
        $archivedDir = Join-Path $backlogDir "chores/archived"
        New-Item -ItemType Directory -Path $archivedDir -Force | Out-Null
        $specContent = "---`r`nitem_id: $taskId`r`ntitle: Research Task`r`ntype: research`r`nstatus: Production`r`nfile_affinity: [docs/findings.md]`r`n---`r`n# $taskId`r`n`r`n## Goal / Intent`r`nResearch goal.`r`n"
        [System.IO.File]::WriteAllText((Join-Path $archivedDir "${taskId}_Test.md"), $specContent, $utf8NoBom)
        $activeSpec = Join-Path $backlogDir "chores/active/${taskId}_Test.md"
        if (Test-Path -LiteralPath $activeSpec) { Remove-Item -LiteralPath $activeSpec -Force }
        $backlogContent = @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 0 | - |
| **P3** | 0 | - |

## Active Items

| Item ID | Title | Priority | Status |
|---|---|---|---|

## Archived Items

| Item ID | Title | Priority | Status |
|---|---|---|---|
| $taskId | Research Task | P2 | Production |

"@
        [System.IO.File]::WriteAllText((Join-Path $backlogDir "BACKLOG.md"), $backlogContent.Replace("`r`n", "`n").Replace("`n", "`r`n"), $utf8NoBom)
        Push-Location $projectRoot
        try {
            git add .crucible/backlog/
            git commit -m "finalize task" --quiet
        } finally {
            Pop-Location
        }

        # Write handoff with null commit_hash (no merge happened)
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $null -FileAffinity @("docs/findings.md") | Out-Null

        # Seed gate decision
        $gateDir = Join-Path $projectRoot ".crucible/session/global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $decision = [ordered]@{
            task_id = $taskId
            outcome = "accepted"
            session_cycle_id = "test-cycle"
        }
        $decision | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "${taskId}-20260604T120000Z.json") -Encoding UTF8

        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "No-Code Closure detected" -Condition ($output -match "No-Code Closure") -FailureMessage "expected No-Code Closure detection message. Output:`n$output"
    }

    $results += Run-Test -Name "Legacy primary-HEAD commit_hash is blocked, not exempted (C4 shape)" -Body {
        $projectRoot = Join-Path $tempRoot "nocode-closure-legacy"
        $taskId = "C-OP-NOCODECLOSURE-LEGACY"
        $baseHash = Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        $gitignoreContent = "session/`r`nhandoffs/`r`n.agent-workspaces/`r`nlocks/`r`ntmp/`r`n"
        [System.IO.File]::WriteAllText((Join-Path $projectRoot ".crucible/.gitignore"), $gitignoreContent, $utf8NoBom)

        Push-Location $projectRoot
        try {
            git add .crucible/.gitignore
            git commit -m "add gitignore" --quiet
        } finally {
            Pop-Location
        }

        # Finalize inline: archive spec WITH type: research preserved
        $backlogDir = Join-Path $projectRoot ".crucible/backlog"
        $archivedDir = Join-Path $backlogDir "chores/archived"
        New-Item -ItemType Directory -Path $archivedDir -Force | Out-Null
        $specContent = "---`r`nitem_id: $taskId`r`ntitle: Research Task`r`ntype: research`r`nstatus: Production`r`nfile_affinity: [docs/findings.md]`r`n---`r`n# $taskId`r`n`r`n## Goal / Intent`r`nResearch goal.`r`n"
        [System.IO.File]::WriteAllText((Join-Path $archivedDir "${taskId}_Test.md"), $specContent, $utf8NoBom)
        $activeSpec = Join-Path $backlogDir "chores/active/${taskId}_Test.md"
        if (Test-Path -LiteralPath $activeSpec) { Remove-Item -LiteralPath $activeSpec -Force }
        $backlogContent = @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 0 | - |
| **P3** | 0 | - |

## Active Items

| Item ID | Title | Priority | Status |
|---|---|---|---|

## Archived Items

| Item ID | Title | Priority | Status |
|---|---|---|---|
| $taskId | Research Task | P2 | Production |

"@
        [System.IO.File]::WriteAllText((Join-Path $backlogDir "BACKLOG.md"), $backlogContent.Replace("`r`n", "`n").Replace("`n", "`r`n"), $utf8NoBom)
        Push-Location $projectRoot
        try {
            git add .crucible/backlog/
            git commit -m "finalize task" --quiet
        } finally {
            Pop-Location
        }

        # Write handoff with legacy back-filled primary HEAD as commit_hash
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $baseHash -FileAffinity @("docs/findings.md") | Out-Null

        $gateDir = Join-Path $projectRoot ".crucible/session/global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $decision = [ordered]@{
            task_id = $taskId
            outcome = "accepted"
            session_cycle_id = "test-cycle"
        }
        $decision | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "${taskId}-20260604T120000Z.json") -Encoding UTF8

        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "Merge verification failed"
    }

    $results += Run-Test -Name "Task with branch cannot claim No-Code Closure exemption" -Body {
        $projectRoot = Join-Path $tempRoot "nocode-closure-branch"
        $taskId = "C-OP-NOCODECLOSURE-BRANCH"
        $baseHash = Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId

        # Rewrite spec with type: research but CREATE a task branch (this invalidates No-Code Closure)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $specDir = Join-Path $projectRoot ".crucible/backlog/chores/active"
        $specContent = "---`r`nitem_id: $taskId`r`ntitle: Research Task`r`ntype: research`r`nfile_affinity: [docs/findings.md]`r`n---`r`n# $taskId`r`n`r`n## Goal / Intent`r`nResearch goal.`r`n"
        [System.IO.File]::WriteAllText((Join-Path $specDir "${taskId}_Test.md"), $specContent, $utf8NoBom)

        $gitignoreContent = "session/`r`nhandoffs/`r`n.agent-workspaces/`r`nlocks/`r`ntmp/`r`n"
        [System.IO.File]::WriteAllText((Join-Path $projectRoot ".crucible/.gitignore"), $gitignoreContent, $utf8NoBom)

        Push-Location $projectRoot
        try {
            git add .crucible/.gitignore
            git commit -m "add gitignore" --quiet
            # Create a task branch - this means No-Code Closure should NOT apply
            git checkout -b task/$taskId --quiet
            Set-Content -LiteralPath "research-work.txt" -Value "research work" -Encoding UTF8
            git add research-work.txt
            git commit -m "research work" --quiet
            git checkout master --quiet
        } finally {
            Pop-Location
        }

        # Null commit_hash but with a task branch -> should be rejected (not No-Code Closure)
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $null -FileAffinity @("docs/findings.md") | Out-Null

        $gateDir = Join-Path $projectRoot ".crucible/session/global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $decision = [ordered]@{
            task_id = $taskId
            outcome = "accepted"
            session_cycle_id = "test-cycle"
        }
        $decision | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "${taskId}-20260604T120000Z.json") -Encoding UTF8

        Finalize-TestTaskInRepo -ProjectRoot $projectRoot -TaskId $taskId
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "commit_hash"
    }

    $results += Run-Test -Name "No-Code Closure with quoted capital Research type passes" -Body {
        $projectRoot = Join-Path $tempRoot "nocode-closure-quoted-cap"
        $taskId = "C-OP-NOCODECLOSURE-QUOTED"
        $baseHash = Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $gitignoreContent = "session/`r`nhandoffs/`r`n.agent-workspaces/`r`nlocks/`r`ntmp/`r`n"
        [System.IO.File]::WriteAllText((Join-Path $projectRoot ".crucible/.gitignore"), $gitignoreContent, $utf8NoBom)
        Push-Location $projectRoot
        try {
            git add .crucible/.gitignore
            git commit -m "add gitignore" --quiet
        } finally {
            Pop-Location
        }

        $backlogDir = Join-Path $projectRoot ".crucible/backlog"
        $archivedDir = Join-Path $backlogDir "chores/archived"
        New-Item -ItemType Directory -Path $archivedDir -Force | Out-Null
        $specContent = "---`r`nitem_id: $taskId`r`ntitle: Research Task`r`ntype: `"Research`"`r`nstatus: Production`r`nfile_affinity: [docs/findings.md]`r`n---`r`n# $taskId`r`n`r`n## Goal / Intent`r`nResearch goal.`r`n"
        [System.IO.File]::WriteAllText((Join-Path $archivedDir "${taskId}_Test.md"), $specContent, $utf8NoBom)
        $activeSpec = Join-Path $backlogDir "chores/active/${taskId}_Test.md"
        if (Test-Path -LiteralPath $activeSpec) { Remove-Item -LiteralPath $activeSpec -Force }
        $backlogContent = @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 0 | - |
| **P3** | 0 | - |

## Active Items

| Item ID | Title | Priority | Status |
|---|---|---|---|

## Archived Items

| Item ID | Title | Priority | Status |
|---|---|---|---|
| $taskId | Research Task | P2 | Production |

"@
        [System.IO.File]::WriteAllText((Join-Path $backlogDir "BACKLOG.md"), $backlogContent.Replace("`r`n", "`n").Replace("`n", "`r`n"), $utf8NoBom)
        Push-Location $projectRoot
        try {
            git add .crucible/backlog/
            git commit -m "finalize task" --quiet
        } finally {
            Pop-Location
        }

        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $null -FileAffinity @("docs/findings.md") | Out-Null

        $gateDir = Join-Path $projectRoot ".crucible/session/global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $decision = [ordered]@{
            task_id = $taskId
            outcome = "accepted"
            session_cycle_id = "test-cycle"
        }
        $decision | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "${taskId}-20260604T120000Z.json") -Encoding UTF8

        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "No-Code Closure detected" -Condition ($output -match "No-Code Closure") -FailureMessage "expected No-Code Closure detection message. Output:`n$output"
    }

    $results += Run-Test -Name "No-Code Closure with R-* prefix and no type line passes" -Body {
        $projectRoot = Join-Path $tempRoot "nocode-closure-r-prefix"
        $taskId = "R-011"
        $baseHash = Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $gitignoreContent = "session/`r`nhandoffs/`r`n.agent-workspaces/`r`nlocks/`r`ntmp/`r`n"
        [System.IO.File]::WriteAllText((Join-Path $projectRoot ".crucible/.gitignore"), $gitignoreContent, $utf8NoBom)
        Push-Location $projectRoot
        try {
            git add .crucible/.gitignore
            git commit -m "add gitignore" --quiet
        } finally {
            Pop-Location
        }

        $backlogDir = Join-Path $projectRoot ".crucible/backlog"
        $archivedDir = Join-Path $backlogDir "features/archived"
        New-Item -ItemType Directory -Path $archivedDir -Force | Out-Null
        $specContent = "---`r`nitem_id: $taskId`r`ntitle: R-011 Dashboard UX Audit`r`nstatus: Production`r`nfile_affinity: [docs/findings.md]`r`n---`r`n# $taskId`r`n`r`n## Goal / Intent`r`nResearch goal.`r`n"
        [System.IO.File]::WriteAllText((Join-Path $archivedDir "${taskId}_Test.md"), $specContent, $utf8NoBom)
        $activeSpec = Join-Path $backlogDir "features/active/${taskId}_Test.md"
        if (Test-Path -LiteralPath $activeSpec) { Remove-Item -LiteralPath $activeSpec -Force }
        $backlogContent = @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 0 | - |
| **P3** | 0 | - |

## Active Items

| Item ID | Title | Priority | Status |
|---|---|---|---|

## Archived Items

| Item ID | Title | Priority | Status |
|---|---|---|---|
| $taskId | R-011 Task | P2 | Production |

"@
        [System.IO.File]::WriteAllText((Join-Path $backlogDir "BACKLOG.md"), $backlogContent.Replace("`r`n", "`n").Replace("`n", "`r`n"), $utf8NoBom)
        Push-Location $projectRoot
        try {
            git add .crucible/backlog/
            git commit -m "finalize task" --quiet
        } finally {
            Pop-Location
        }

        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $null -FileAffinity @("docs/findings.md") | Out-Null

        $gateDir = Join-Path $projectRoot ".crucible/session/global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $decision = [ordered]@{
            task_id = $taskId
            outcome = "accepted"
            session_cycle_id = "test-cycle"
        }
        $decision | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "${taskId}-20260604T120000Z.json") -Encoding UTF8

        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "No-Code Closure detected" -Condition ($output -match "No-Code Closure") -FailureMessage "expected No-Code Closure detection message. Output:`n$output"
    }

    $results += Run-Test -Name "R-* task with deleted branch and baseline commit_hash is blocked" -Body {
        $projectRoot = Join-Path $tempRoot "nocode-closure-r900-baseline"
        $taskId = "R-900"
        $baseHash = Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $gitignoreContent = "session/`r`nhandoffs/`r`n.agent-workspaces/`r`nlocks/`r`ntmp/`r`n"
        [System.IO.File]::WriteAllText((Join-Path $projectRoot ".crucible/.gitignore"), $gitignoreContent, $utf8NoBom)
        Push-Location $projectRoot
        try {
            git add .crucible/.gitignore
            git commit -m "add gitignore" --quiet
        } finally {
            Pop-Location
        }

        $backlogDir = Join-Path $projectRoot ".crucible/backlog"
        $archivedDir = Join-Path $backlogDir "features/archived"
        New-Item -ItemType Directory -Path $archivedDir -Force | Out-Null
        $specContent = "---`r`nitem_id: $taskId`r`ntitle: R-900 Research Task`r`ntype: research`r`nstatus: Production`r`nfile_affinity: [docs/findings.md]`r`n---`r`n# $taskId`r`n`r`n## Goal / Intent`r`nResearch goal.`r`n"
        [System.IO.File]::WriteAllText((Join-Path $archivedDir "${taskId}_Test.md"), $specContent, $utf8NoBom)
        $activeSpec = Join-Path $backlogDir "features/active/${taskId}_Test.md"
        if (Test-Path -LiteralPath $activeSpec) { Remove-Item -LiteralPath $activeSpec -Force }
        $backlogContent = @"
# Backlog

## Priority Summary

| Priority | Active Count | Item IDs |
|---|---|---|
| **P0** | 0 | - |
| **P1** | 0 | - |
| **P2** | 0 | - |
| **P3** | 0 | - |

## Active Items

| Item ID | Title | Priority | Status |
|---|---|---|---|

## Archived Items

| Item ID | Title | Priority | Status |
|---|---|---|---|
| $taskId | R-900 Task | P2 | Production |

"@
        [System.IO.File]::WriteAllText((Join-Path $backlogDir "BACKLOG.md"), $backlogContent.Replace("`r`n", "`n").Replace("`n", "`r`n"), $utf8NoBom)
        Push-Location $projectRoot
        try {
            git add .crucible/backlog/
            git commit -m "finalize task" --quiet
        } finally {
            Pop-Location
        }

        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $baseHash -FileAffinity @("docs/findings.md") | Out-Null

        $gateDir = Join-Path $projectRoot ".crucible/session/global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $decision = [ordered]@{
            task_id = $taskId
            outcome = "accepted"
            session_cycle_id = "test-cycle"
        }
        $decision | ConvertTo-Json | Set-Content -Path (Join-Path $gateDir "${taskId}-20260604T120000Z.json") -Encoding UTF8

        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        $output = $res.Output -join "`n"
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "Merge verification failed"
        Assert-Result -Name "No-Code Closure NOT detected" -Condition ($output -notmatch "No-Code Closure detected") -FailureMessage "unexpected No-Code Closure detection message. Output:`n$output"
    }

    # --- deployment -> grooming tests ---

    $results += Run-Test -Name "deployment -> grooming dependency-blocked passes without commit_hash" -Body {
        $projectRoot = Join-Path $tempRoot "grooming-depblocked"
        $taskId = "C-OP-GROOM-DEPBLK"
        Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId | Out-Null
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -Target "grooming" -CommitHash $null | Out-Null
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "no verification failure" -Condition ($output -notmatch "artifact_verification_failed") -FailureMessage "unexpected verification failure. Output:`n$output"
    }

    $results += Run-Test -Name "deployment -> grooming incident with valid merged commit_hash passes" -Body {
        $projectRoot = Join-Path $tempRoot "grooming-incident-ok"
        $taskId = "C-OP-GROOM-INC-OK"
        $baseHash = Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId
        Push-Location $projectRoot
        try {
            git checkout -b task/$taskId --quiet
            Set-Content -LiteralPath "work.txt" -Value "merged task work" -Encoding UTF8
            git add work.txt
            git commit -m "task work" --quiet
            git checkout master --quiet
            git merge task/$taskId --no-ff -m "merge task work" --quiet
            $mergedHash = (git rev-parse HEAD).Trim()
        } finally {
            Pop-Location
        }
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -Target "grooming" -CommitHash $mergedHash -BaseCommit $baseHash | Out-Null
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "no verification failure" -Condition ($output -notmatch "artifact_verification_failed") -FailureMessage "unexpected verification failure. Output:`n$output"
    }

    $results += Run-Test -Name "deployment -> grooming incident with unmerged commit_hash is rejected" -Body {
        $projectRoot = Join-Path $tempRoot "grooming-incident-bad"
        $taskId = "C-OP-GROOM-INC-BAD"
        Initialize-ProjectRepo -ProjectRoot $projectRoot -TaskId $taskId | Out-Null
        $sideHash = New-SideBranchCommit -ProjectRoot $projectRoot -BaseBranch "master"
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -Target "grooming" -CommitHash $sideHash | Out-Null
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "Incident handoff"
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
