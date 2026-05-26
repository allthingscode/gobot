$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$FACTORY_SCRIPT = Join-Path $REPO_ROOT "powershell/factory.ps1"

$results = @()

function Assert-Result {
    param([string]$Name, [bool]$Condition, [string]$FailureMessage)
    if (-not $Condition) { throw ("FAILED: " + $Name + " - " + $FailureMessage) }
}

function Run-Test {
    param([string]$Name, [scriptblock]$Body)
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
    param([Parameter(Mandatory=$true)][scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Command 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [PSCustomObject]@{ Output = $output; ExitCode = $exitCode }
}

function Test-GitInitMainSupported {
    $versionText = git --version
    if ($versionText -notmatch '(\d+)\.(\d+)') { return $false }
    $major = [int]$matches[1]
    $minor = [int]$matches[2]
    return ($major -gt 2 -or ($major -eq 2 -and $minor -ge 28))
}

function Initialize-ProjectRepo {
    param([string]$ProjectRoot, [string]$Branch = "master")
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
        New-Item -ItemType Directory -Path ".crucible" -Force | Out-Null
        @(
            "project: OperatorMergeTest",
            "paths:",
            "  backlog: .crucible/backlog",
            "  session: .crucible/session",
            "  workspaces: .crucible/.agent-workspaces",
            "  prompts: .crucible/prompts"
        ) | Set-Content -LiteralPath ".crucible/config.yaml" -Encoding UTF8
        Set-Content -LiteralPath "README.md" -Value "# operator merge test" -Encoding UTF8
        git add README.md .crucible/config.yaml
        git commit -m "init" --quiet
        return (git rev-parse HEAD).Trim()
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
        [string]$Target = "groomer",
        [AllowNull()][string]$CommitHash,
        [string[]]$FileAffinity = @("src/app.txt")
    )
    $handoffDir = Join-Path $ProjectRoot ".crucible/session/handoffs"
    New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    $handoffPath = Join-Path $handoffDir ("${TaskId}-${timestamp}.json")
    $handoff = [ordered]@{
        task_id                  = $TaskId
        source_specialist        = "operator"
        target_specialist        = $Target
        reason                   = "Operator merge verification test"
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
        powershell.exe @factoryArgs
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
        Initialize-ProjectRepo -ProjectRoot $projectRoot | Out-Null
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $null | Out-Null
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "commit_hash"
    }

    $results += Run-Test -Name "Nonexistent commit_hash is rejected" -Body {
        $projectRoot = Join-Path $tempRoot "nonexistent"
        $taskId = "C-OP-NONEXISTENT"
        Initialize-ProjectRepo -ProjectRoot $projectRoot | Out-Null
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash "ffffffffffffffffffffffffffffffffffffffff" | Out-Null
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "does not exist"
    }

    $results += Run-Test -Name "Unmerged commit_hash is rejected" -Body {
        $projectRoot = Join-Path $tempRoot "unmerged"
        $taskId = "C-OP-UNMERGED"
        Initialize-ProjectRepo -ProjectRoot $projectRoot | Out-Null
        $sideHash = New-SideBranchCommit -ProjectRoot $projectRoot -BaseBranch "master"
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $sideHash | Out-Null
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "is not merged"
    }

    $results += Run-Test -Name "Merged commit_hash passes" -Body {
        $projectRoot = Join-Path $tempRoot "happy"
        $taskId = "C-OP-HAPPY"
        $head = Initialize-ProjectRepo -ProjectRoot $projectRoot
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $head | Out-Null
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "no verification failure" -Condition ($output -notmatch "artifact_verification_failed") -FailureMessage "unexpected verification failure. Output:`n$output"
    }

    $results += Run-Test -Name "Factory task skip path allows missing commit_hash" -Body {
        $projectRoot = Join-Path $tempRoot "factory-skip"
        $taskId = "C-OP-FACTORY-SKIP"
        Initialize-ProjectRepo -ProjectRoot $projectRoot | Out-Null
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $null -FileAffinity @(".crucible/config.yaml") | Out-Null
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId -AcceptGate
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "commit_hash not required" -Condition ($output -notmatch "commit_hash") -FailureMessage "factory skip path still required commit_hash. Output:`n$output"
    }

    $results += Run-Test -Name "Main-default unmerged commit_hash is rejected against main" -Body {
        if (-not $mainSupported) {
            Write-Host "SKIPPED: git init -b requires git >= 2.28" -ForegroundColor Yellow
            return
        }
        $projectRoot = Join-Path $tempRoot "main-default"
        $taskId = "C-OP-MAIN-UNMERGED"
        Initialize-ProjectRepo -ProjectRoot $projectRoot -Branch "main" | Out-Null
        $sideHash = New-SideBranchCommit -ProjectRoot $projectRoot -BaseBranch "main"
        Write-OperatorHandoff -ProjectRoot $projectRoot -TaskId $taskId -CommitHash $sideHash | Out-Null
        $res = Invoke-FactoryForTask -ProjectRoot $projectRoot -TaskId $taskId
        Assert-VerificationBlocked -ProjectRoot $projectRoot -TaskId $taskId -Result $res -ExpectedText "is not merged into main"
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
