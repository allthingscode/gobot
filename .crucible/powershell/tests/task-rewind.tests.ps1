# Regression tests for powershell/factory.ps1 -Rewind mode.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$FACTORY_SCRIPT = Join-Path $REPO_ROOT "powershell/factory.ps1"

$results = @()

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-rewind-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function Invoke-FactoryRewind {
    param(
        [string]$TaskId,
        [string]$ToPhase,
        [switch]$ResetBudget,
        [string]$ProjectRoot,
        [switch]$Quiet
    )
    $cmdArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $FACTORY_SCRIPT)
    $cmdArgs += "-Rewind"
    if (-not [string]::IsNullOrEmpty($TaskId)) {
        $cmdArgs += @("-TaskId", $TaskId)
    }
    if (-not [string]::IsNullOrEmpty($ToPhase)) {
        $cmdArgs += @("-ToPhase", $ToPhase)
    }
    if ($ResetBudget) {
        $cmdArgs += "-ResetBudget"
    }
    if (-not [string]::IsNullOrEmpty($ProjectRoot)) {
        $cmdArgs += @("-ProjectRoot", $ProjectRoot)
    }
    if ($Quiet) {
        $cmdArgs += "-Quiet"
    }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $outputLines = @(& (Get-PwshCommand) @cmdArgs 2>&1)
        return @{ ExitCode = $LASTEXITCODE; Output = ($outputLines -join "`n") }
    } finally {
        $ErrorActionPreference = $prev
    }
}

try {
    # Test 1: Refuses missing TaskId
    $results += Run-Test -Name "Rewind refuses missing TaskId" -Body {
        $r = Invoke-FactoryRewind -ToPhase "grooming" -ProjectRoot $tempRoot
        Assert-Result -Name "refuses missing TaskId" -Condition ($r.ExitCode -ne 0) -FailureMessage "expected non-zero exit code when TaskId is missing"
        Assert-Result -Name "shows task id error" -Condition ($r.Output -match "TaskId is required") -FailureMessage "expected task id error message"
    }

    # Test 2: Refuses missing ToPhase
    $results += Run-Test -Name "Rewind refuses missing ToPhase" -Body {
        $r = Invoke-FactoryRewind -TaskId "B-001" -ProjectRoot $tempRoot
        Assert-Result -Name "refuses missing ToPhase" -Condition ($r.ExitCode -ne 0) -FailureMessage "expected non-zero exit code when ToPhase is missing"
        Assert-Result -Name "shows to phase error" -Condition ($r.Output -match "ToPhase") -FailureMessage "expected to phase error message"
    }

    # Test 3: Refuses invalid ToPhase
    $results += Run-Test -Name "Rewind refuses invalid ToPhase" -Body {
        # Using a phase other than grooming should fail
        $r = Invoke-FactoryRewind -TaskId "B-001" -ToPhase "implementation" -ProjectRoot $tempRoot
        Assert-Result -Name "refuses invalid ToPhase" -Condition ($r.ExitCode -ne 0) -FailureMessage "expected non-zero exit code when ToPhase is not grooming"
    }

    # Test 4: Rewind archives downstream state
    $results += Run-Test -Name "Rewind archives handoffs and downstream phase folders" -Body {
        # Setup directories
        $sessionDir = Join-Path $tempRoot ".crucible/session"
        $handoffsDir = Join-Path $sessionDir "handoffs"
        $taskDir = Join-Path $sessionDir "B-001"

        New-Item -ItemType Directory -Path $handoffsDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $taskDir "research") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $taskDir "grooming") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $taskDir "implementation") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $taskDir "verification") -Force | Out-Null

        # Create active handoffs
        Set-Content -Path (Join-Path $handoffsDir "B-001-20260615T010000Z.json") -Value "{}"
        Set-Content -Path (Join-Path $handoffsDir "B-001-20260615T020000Z.json") -Value "{}"
        # Handoff for another task should NOT be touched
        Set-Content -Path (Join-Path $handoffsDir "B-002-20260615T020000Z.json") -Value "{}"

        # Create pipeline log
        $logFile = Join-Path $taskDir "pipeline.log.jsonl"
        Set-Content -Path $logFile -Value '{"event":"session_start","task_id":"B-001","phase":"grooming"}'

        # Execute rewind (without ResetBudget)
        $r = Invoke-FactoryRewind -TaskId "B-001" -ToPhase "grooming" -ProjectRoot $tempRoot
        Assert-Result -Name "rewind success" -Condition ($r.ExitCode -eq 0) -FailureMessage "expected exit code 0. Output: $($r.Output)"

        # Verify handoffs moved out of active path
        Assert-Result -Name "active handoffs moved" -Condition (-not (Test-Path (Join-Path $handoffsDir "B-001-*.json"))) -FailureMessage "active B-001 handoffs were not moved"
        Assert-Result -Name "other task handoff preserved" -Condition (Test-Path (Join-Path $handoffsDir "B-002-20260615T020000Z.json")) -FailureMessage "B-002 handoff was incorrectly moved/deleted"

        # Verify downstream phases moved
        Assert-Result -Name "research preserved" -Condition (Test-Path (Join-Path $taskDir "research")) -FailureMessage "research phase should be preserved (it is upstream of grooming)"
        Assert-Result -Name "grooming moved" -Condition (-not (Test-Path (Join-Path $taskDir "grooming"))) -FailureMessage "grooming phase should be moved"
        Assert-Result -Name "implementation moved" -Condition (-not (Test-Path (Join-Path $taskDir "implementation"))) -FailureMessage "implementation phase should be moved"
        Assert-Result -Name "verification moved" -Condition (-not (Test-Path (Join-Path $taskDir "verification"))) -FailureMessage "verification phase should be moved"

        # Verify pipeline log preserved at active path (since ResetBudget was not passed)
        Assert-Result -Name "pipeline log preserved" -Condition (Test-Path $logFile) -FailureMessage "pipeline.log.jsonl should be preserved"

        # Verify archive contains everything
        $rewindsDir = Join-Path $taskDir "rewinds"
        Assert-Result -Name "rewinds dir exists" -Condition (Test-Path $rewindsDir) -FailureMessage "rewinds folder should exist"
        $archiveFolders = @(Get-ChildItem -Path $rewindsDir)
        Assert-Result -Name "one archive folder" -Condition ($archiveFolders.Count -eq 1) -FailureMessage "expected exactly one archive folder"

        $archivePath = $archiveFolders[0].FullName
        Assert-Result -Name "archive handoffs exist" -Condition (Test-Path (Join-Path $archivePath "handoffs/B-001-20260615T010000Z.json")) -FailureMessage "archived handoff 1 missing"
        Assert-Result -Name "archive phases exist" -Condition (Test-Path (Join-Path $archivePath "phases/grooming")) -FailureMessage "archived grooming phase missing"
        Assert-Result -Name "archive implementation exist" -Condition (Test-Path (Join-Path $archivePath "phases/implementation")) -FailureMessage "archived implementation phase missing"

        # Verify manifest.json
        $manifestPath = Join-Path $archivePath "manifest.json"
        Assert-Result -Name "manifest exists" -Condition (Test-Path $manifestPath) -FailureMessage "manifest.json not found in archive"
        $manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json
        Assert-Result -Name "manifest task_id" -Condition ($manifest.task_id -eq "B-001") -FailureMessage "manifest task_id wrong"
        Assert-Result -Name "manifest to_phase" -Condition ($manifest.to_phase -eq "grooming") -FailureMessage "manifest to_phase wrong"
        Assert-Result -Name "manifest reset_budget" -Condition ($manifest.reset_budget -eq $false) -FailureMessage "manifest reset_budget should be false"
    }

    # Test 5: Rewind with ResetBudget archives pipeline.log.jsonl
    $results += Run-Test -Name "Rewind with ResetBudget archives pipeline log" -Body {
        # Setup directories
        $sessionDir = Join-Path $tempRoot ".crucible/session"
        $handoffsDir = Join-Path $sessionDir "handoffs"
        $taskDir = Join-Path $sessionDir "B-003"

        New-Item -ItemType Directory -Path $handoffsDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $taskDir "grooming") -Force | Out-Null

        # Create pipeline log
        $logFile = Join-Path $taskDir "pipeline.log.jsonl"
        Set-Content -Path $logFile -Value '{"event":"session_start","task_id":"B-003","phase":"grooming"}'

        # Execute rewind (with ResetBudget)
        $r = Invoke-FactoryRewind -TaskId "B-003" -ToPhase "grooming" -ResetBudget -ProjectRoot $tempRoot
        Assert-Result -Name "rewind success" -Condition ($r.ExitCode -eq 0) -FailureMessage "expected exit code 0"

        # Verify pipeline log moved out of active path
        Assert-Result -Name "pipeline log archived" -Condition (-not (Test-Path $logFile)) -FailureMessage "pipeline.log.jsonl was not archived/moved"

        # Verify archive contains pipeline.log.jsonl
        $rewindsDir = Join-Path $taskDir "rewinds"
        $archiveFolders = @(Get-ChildItem -Path $rewindsDir)
        $archivePath = $archiveFolders[0].FullName
        Assert-Result -Name "archive contains log" -Condition (Test-Path (Join-Path $archivePath "pipeline.log.jsonl")) -FailureMessage "archived pipeline log not found"

        # Verify manifest.json shows reset_budget is true
        $manifestPath = Join-Path $archivePath "manifest.json"
        $manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json
        Assert-Result -Name "manifest reset_budget true" -Condition ($manifest.reset_budget -eq $true) -FailureMessage "manifest reset_budget should be true"
    }

    # Test 6: Idempotency (no-op on second run)
    $results += Run-Test -Name "Rewind is idempotent (no-op on second run)" -Body {
        # Execute rewind again on B-003 (which was already rewound)
        $r = Invoke-FactoryRewind -TaskId "B-003" -ToPhase "grooming" -ResetBudget -ProjectRoot $tempRoot
        Assert-Result -Name "rewind success second time" -Condition ($r.ExitCode -eq 0) -FailureMessage "expected exit code 0"
        Assert-Result -Name "no-op message" -Condition ($r.Output -match "No downstream state found") -FailureMessage "expected no downstream state message"
    }

} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed task rewind test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll task rewind tests passed." -ForegroundColor Green
exit 0
