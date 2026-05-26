$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$ANALYZE_SCRIPT = Join-Path $REPO_ROOT "powershell/analyze-evals.ps1"

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

function Write-AnalyzeFixture {
    param([string]$ProjectRoot)
    $gateDir = Join-Path $ProjectRoot ".crucible/session/global/gate_decisions"
    $logDir = Join-Path $ProjectRoot ".crucible/session/archived"
    $evalDir = Join-Path $ProjectRoot ".crucible/session/eval"
    $handoffDir = Join-Path $ProjectRoot ".crucible/session/handoffs"
    $handoffArchiveDir = Join-Path $ProjectRoot ".crucible/session/handoffs/archived"
    New-Item -ItemType Directory -Path $gateDir, $logDir, $evalDir, $handoffDir, $handoffArchiveDir -Force | Out-Null

    @"
{
  "task_id": "T-001",
  "gate_fired_at": "2026-05-25T12:00:00Z",
  "outcome": "accepted",
  "reason": "Synthetic gate decision."
}
"@ | Set-Content -LiteralPath (Join-Path $gateDir "T-001.json") -Encoding UTF8

    @(
        '{"event":"session_end","task_id":"T-001","specialist":"architect","duration_seconds":120}',
        '{"event":"session_end","task_id":"T-001","specialist":"reviewer","duration_seconds":60,"outcome":"redirect"}',
        '{"event":"session_end","task_id":"T-001","specialist":"architect","duration_seconds":90}'
    ) | Set-Content -LiteralPath (Join-Path $logDir "pipeline-T-001.log.jsonl") -Encoding UTF8
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-analyze-evals-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$projectRoot = Join-Path $tempRoot "project"

try {
    Write-AnalyzeFixture -ProjectRoot $projectRoot

    $results += Run-Test -Name "Json report includes synthetic task" -Body {
        Push-Location $projectRoot
        try {
            $res = Invoke-ExternalCommand {
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ANALYZE_SCRIPT -Json
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        Assert-Result -Name "task count" -Condition ($json.total_tasks -eq 1) -FailureMessage "expected one gate decision. Output:`n$output"
        Assert-Result -Name "duration entries" -Condition ($json.avg_duration_minutes.Count -gt 0) -FailureMessage "expected duration summary entries. Output:`n$output"
        Assert-Result -Name "multi-cycle task" -Condition (@($json.multi_cycle_tasks) -contains "T-001") -FailureMessage "expected T-001 in multi_cycle_tasks. Output:`n$output"
    }

    $results += Run-Test -Name "Markdown report emits content" -Body {
        Push-Location $projectRoot
        try {
            $res = Invoke-ExternalCommand {
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ANALYZE_SCRIPT
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "report output" -Condition ($output -match "# Dev Factory - Eval Report" -and $output -match "T-001") -FailureMessage "markdown report missing expected content. Output:`n$output"
    }
} finally {
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
