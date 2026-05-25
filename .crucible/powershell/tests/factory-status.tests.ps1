$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$STATUS_SCRIPT = Join-Path $REPO_ROOT "powershell/factory-status.ps1"

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

function Write-StatusFixture {
    param([string]$ProjectRoot)
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot ".crucible/session/global") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot ".crucible/backlog") -Force | Out-Null

    @(
        "project: FactoryStatusTest",
        "paths:",
        "  backlog: .crucible/backlog",
        "  session: .crucible/session",
        "  workspaces: .crucible/.agent-workspaces",
        "  prompts: .crucible/prompts"
    ) | Set-Content -LiteralPath (Join-Path $ProjectRoot ".crucible/config.yaml") -Encoding UTF8

    @"
{
  "tasks": {
    "F-001": {
      "active_specialist": "architect",
      "status": "in_progress",
      "specialists": {
        "architect": {
          "status": "in_progress",
          "timestamp": "2026-05-25T12:00:00Z"
        }
      }
    }
  }
}
"@ | Set-Content -LiteralPath (Join-Path $ProjectRoot ".crucible/session/global/session_state.json") -Encoding UTF8

    @(
        "# Backlog",
        "",
        "| ID | Title | Category | Status | Specialist | Priority |",
        "| --- | --- | --- | --- | --- | --- |",
        "| F-001 | [Synthetic Task](features/active/F-001.md) | Feature | In Progress | architect | P1 |"
    ) | Set-Content -LiteralPath (Join-Path $ProjectRoot ".crucible/backlog/BACKLOG.md") -Encoding UTF8
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-factory-status-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$projectRoot = Join-Path $tempRoot "project"

try {
    Write-StatusFixture -ProjectRoot $projectRoot

    $results += Run-Test -Name "ExportJSON emits parseable report" -Body {
        Push-Location $projectRoot
        try {
            $res = Invoke-ExternalCommand {
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File $STATUS_SCRIPT -ExportJSON
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        Assert-Result -Name "task surfaced" -Condition ($json.tasks[0].Task -eq "F-001") -FailureMessage "expected F-001 in JSON output. Output:`n$output"
        Assert-Result -Name "stats present" -Condition ($json.stats.total -eq 1) -FailureMessage "expected total=1 in JSON output. Output:`n$output"
    }

    $results += Run-Test -Name "Summary emits pipeline health" -Body {
        Push-Location $projectRoot
        try {
            $res = Invoke-ExternalCommand {
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File $STATUS_SCRIPT -Summary
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "summary output" -Condition ($output -match "Pipeline Health" -and $output -match "Total Managed Tasks: 1") -FailureMessage "summary output missing expected content. Output:`n$output"
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
