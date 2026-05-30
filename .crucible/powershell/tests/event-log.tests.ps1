# Tests for the shared event log helper.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$FACTORY_LIB = Join-Path $REPO_ROOT "powershell/factory-lib.ps1"
$HELPER = Join-Path $REPO_ROOT "powershell/lib/event-log.ps1"
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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-event-log-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Write-EventLog appends JSON line and creates parent directory" -Body {
        $logFile = Join-Path $tempRoot "nested/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $tempRoot "global/circuit_breakers.jsonl"

        Write-EventLog -Event "session_start" -TaskId "F-001" -Phase "implementation" -Outcome "started" -Notes "hello" -LogFile $logFile -CircuitBreakerHistoryFile $cbHistoryFile

        Assert-Result -Name "log exists" -Condition (Test-Path -LiteralPath $logFile) -FailureMessage "log file was not created"
        $lines = @(Get-Content -LiteralPath $logFile -Encoding UTF8)
        Assert-Result -Name "single line" -Condition ($lines.Count -eq 1) -FailureMessage "expected one JSONL entry"
        $entry = $lines[0] | ConvertFrom-Json
        Assert-Result -Name "event" -Condition ($entry.event -eq "session_start") -FailureMessage "event changed"
        Assert-Result -Name "task id" -Condition ($entry.task_id -eq "F-001") -FailureMessage "task id changed"
        Assert-Result -Name "phase" -Condition ($entry.phase -eq "implementation") -FailureMessage "phase changed"
        Assert-Result -Name "outcome" -Condition ($entry.outcome -eq "started") -FailureMessage "outcome missing"
        Assert-Result -Name "notes" -Condition ($entry.notes -eq "hello") -FailureMessage "notes missing"
    }

    $results += Run-Test -Name "Circuit breaker event also appends history file" -Body {
        $logFile = Join-Path $tempRoot "task/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $tempRoot "global/circuit_breakers.jsonl"

        Write-EventLog -Event "circuit_breaker" -TaskId "F-002" -Phase "factory" -Outcome "blocked" -LogFile $logFile -CircuitBreakerHistoryFile $cbHistoryFile

        Assert-Result -Name "history exists" -Condition (Test-Path -LiteralPath $cbHistoryFile) -FailureMessage "circuit breaker history was not created"
        $entry = (Get-Content -LiteralPath $cbHistoryFile -Encoding UTF8 -Tail 1) | ConvertFrom-Json
        Assert-Result -Name "history event" -Condition ($entry.event -eq "circuit_breaker") -FailureMessage "history event changed"
        Assert-Result -Name "history task" -Condition ($entry.task_id -eq "F-002") -FailureMessage "history task id changed"
    }

    $results += Run-Test -Name "Get-LastEntry returns null when log is missing" -Body {
        $missingLog = Join-Path $tempRoot "missing/pipeline.log.jsonl"
        $entry = Get-LastEntry -TaskId "F-003" -Phase "verification" -Event "session_start" -LogFile $missingLog
        Assert-Result -Name "null result" -Condition ($null -eq $entry) -FailureMessage "missing log should return null"
    }

    $results += Run-Test -Name "Get-LastEntry finds latest matching event" -Body {
        $logFile = Join-Path $tempRoot "lookup/pipeline.log.jsonl"
        New-Item -ItemType Directory -Path (Split-Path -Parent $logFile) -Force | Out-Null
        @(
            (@{ event = "session_start"; task_id = "F-004"; phase = "implementation"; marker = "old" } | ConvertTo-Json -Compress),
            (@{ event = "session_end"; task_id = "F-004"; phase = "implementation"; marker = "wrong event" } | ConvertTo-Json -Compress),
            (@{ event = "session_start"; task_id = "F-004"; phase = "implementation"; marker = "new" } | ConvertTo-Json -Compress)
        ) | Set-Content -LiteralPath $logFile -Encoding UTF8

        $entry = Get-LastEntry -TaskId "F-004" -Phase "implementation" -Event "session_start" -LogFile $logFile
        Assert-Result -Name "entry found" -Condition ($null -ne $entry) -FailureMessage "matching entry was not found"
        Assert-Result -Name "latest marker" -Condition ($entry.marker -eq "new") -FailureMessage "did not return latest matching entry"
    }

    $results += Run-Test -Name "Get-LastEntry accepts legacy specialist field" -Body {
        $logFile = Join-Path $tempRoot "legacy/pipeline.log.jsonl"
        New-Item -ItemType Directory -Path (Split-Path -Parent $logFile) -Force | Out-Null
        @(
            (@{ event = "session_start"; task_id = "F-000"; specialist = "grooming"; marker = "other" } | ConvertTo-Json -Compress),
            (@{ event = "session_start"; task_id = "F-005"; specialist = "grooming"; marker = "legacy" } | ConvertTo-Json -Compress)
        ) | Set-Content -LiteralPath $logFile -Encoding UTF8

        $entry = Get-LastEntry -TaskId "F-005" -Phase "grooming" -Event "session_start" -LogFile $logFile
        Assert-Result -Name "legacy found" -Condition ($null -ne $entry) -FailureMessage "legacy specialist entry was not found"
        Assert-Result -Name "legacy marker" -Condition ($entry.marker -eq "legacy") -FailureMessage "legacy entry changed"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed event log test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll event log tests passed." -ForegroundColor Green
exit 0
