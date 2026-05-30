# Tests for the shared blocked task record helper.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$FACTORY_LIB = Join-Path $REPO_ROOT "powershell/factory-lib.ps1"
$HELPER = Join-Path $REPO_ROOT "powershell/lib/blocked.ps1"
$Quiet = $true
. $FACTORY_LIB
. $HELPER

$results = @()

function Assert-Result {
    param([string]$Name, [bool]$Condition, [string]$FailureMessage)
    if (-not $Condition) {
        throw ("FAILED: " + $Name + " - " + $FailureMessage)
    }
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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-blocked-test-" + [guid]::NewGuid().ToString("N"))
$backlogDir = Join-Path $tempRoot "backlog"
$frameworkDir = Join-Path $tempRoot "powershell"
New-Item -ItemType Directory -Path $backlogDir -Force | Out-Null
New-Item -ItemType Directory -Path $frameworkDir -Force | Out-Null

$stubScript = Join-Path $frameworkDir "update_session_state.ps1"
@'
param(
    [string]$Specialist,
    [string]$TaskId,
    [string]$UpdateJson,
    [bool]$Merge
)

$payload = [ordered]@{
    specialist = $Specialist
    task_id = $TaskId
    update_json = $UpdateJson
    merge = $Merge
}
$payload | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot "update-called.json") -Encoding UTF8
'@ | Set-Content -LiteralPath $stubScript -Encoding UTF8

try {
    $results += Run-Test -Name "Write-BlockedTaskRecord creates blocked record" -Body {
        Write-BlockedTaskRecord -TaskId "F-010" -CircuitBreaker "budget_exceeded" -AttemptCount 7 -LastPhase "verification" -Summary "Too many handoffs" -Artifacts @("report.md", "log.txt") -BacklogDir $backlogDir -FrameworkPowerShell $frameworkDir

        $blockedDir = Join-Path $backlogDir "blocked"
        Assert-Result -Name "blocked dir" -Condition (Test-Path -LiteralPath $blockedDir) -FailureMessage "blocked directory was not created"
        $records = @(Get-ChildItem -LiteralPath $blockedDir -Filter "F-010-*.json")
        Assert-Result -Name "one record" -Condition ($records.Count -eq 1) -FailureMessage "expected exactly one blocked record"
    }

    $results += Run-Test -Name "Blocked record contains required keys" -Body {
        $record = Get-ChildItem -LiteralPath (Join-Path $backlogDir "blocked") -Filter "F-010-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json

        Assert-Result -Name "task_id" -Condition ($record.task_id -eq "F-010") -FailureMessage "task_id changed"
        Assert-Result -Name "circuit_breaker" -Condition ($record.circuit_breaker -eq "budget_exceeded") -FailureMessage "circuit breaker changed"
        Assert-Result -Name "attempt_count" -Condition ($record.attempt_count -eq 7) -FailureMessage "attempt count changed"
        Assert-Result -Name "last_phase" -Condition ($record.last_phase -eq "verification") -FailureMessage "last phase changed"
        Assert-Result -Name "summary" -Condition ($record.summary -eq "Too many handoffs") -FailureMessage "summary changed"
        Assert-Result -Name "human decision" -Condition ($record.human_decision_needed -eq "Should we reduce scope, split the task, or abandon it?") -FailureMessage "default human decision changed"
        Assert-Result -Name "artifacts" -Condition (@($record.artifacts).Count -eq 2) -FailureMessage "artifacts changed"
    }

    $results += Run-Test -Name "Update session state side effect uses supplied framework path" -Body {
        $calledPath = Join-Path $frameworkDir "update-called.json"
        Assert-Result -Name "stub called" -Condition (Test-Path -LiteralPath $calledPath) -FailureMessage "update_session_state stub was not called"
        $called = Get-Content -LiteralPath $calledPath -Raw | ConvertFrom-Json
        Assert-Result -Name "stub specialist" -Condition ($called.specialist -eq "verification") -FailureMessage "specialist argument changed"
        Assert-Result -Name "stub task" -Condition ($called.task_id -eq "F-010") -FailureMessage "task argument changed"
        Assert-Result -Name "stub merge" -Condition ($called.merge -eq $true) -FailureMessage "merge argument changed"
        $update = $called.update_json | ConvertFrom-Json
        Assert-Result -Name "stub status" -Condition ($update.status -eq "blocked") -FailureMessage "status update changed"
        Assert-Result -Name "stub breaker" -Condition ($update.circuit_breaker -eq "budget_exceeded") -FailureMessage "circuit breaker update changed"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed blocked record test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll blocked record tests passed." -ForegroundColor Green
exit 0
