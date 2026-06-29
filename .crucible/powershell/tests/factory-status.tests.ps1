$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$STATUS_SCRIPT = Join-Path $REPO_ROOT "powershell/factory-status.ps1"

$results = @()










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
    },
    "F-002": {
      "status": "finished"
    },
    "F-003": {
      "phases": {
        "architect": {
          "status": "Complete",
          "timestamp": "2026-05-25T13:00:00Z"
        }
      }
    },
    "F-004": {
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
        "| F-001 | [Synthetic Task](features/active/F-001.md) | Feature | In Progress | architect | P1 |",
        "| F-004 | [Synthetic Task 4](features/active/F-004.md) | Feature | Production | architect | P1 |"
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
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $STATUS_SCRIPT -ExportJSON
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        Assert-Result -Name "task surfaced" -Condition ($json.tasks[0].Task -eq "F-001") -FailureMessage "expected F-001 in JSON output. Output:`n$output"
        Assert-Result -Name "stats present" -Condition ($json.stats.total -eq 4) -FailureMessage "expected total=4 in JSON output. Output:`n$output"
        Assert-Result -Name "F-004 is not in-flight" -Condition ($json.stats.in_flight -eq 1) -FailureMessage "expected in_flight=1 (only F-001), got $($json.stats.in_flight). Output:`n$output"
        $f004 = $json.tasks | Where-Object { $_.Task -eq "F-004" }
        Assert-Result -Name "F-004 status is Production" -Condition ($f004.Status -eq "Production") -FailureMessage "expected F-004 status 'Production', got '$($f004.Status)'"
        Assert-Result -Name "F-004 duration is empty" -Condition ($f004.Duration -eq "-") -FailureMessage "expected F-004 duration '-', got '$($f004.Duration)'"
    }

    $results += Run-Test -Name "Summary emits pipeline health" -Body {
        Push-Location $projectRoot
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $STATUS_SCRIPT -Summary
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "summary output" -Condition ($output -match "Pipeline Health" -and $output -match "Total Managed Tasks: 4") -FailureMessage "summary output missing expected content. Output:`n$output"
    }

    $results += Run-Test -Name "Status runs clean under StrictMode when task lacks keys" -Body {
        Push-Location $projectRoot
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -Command "Set-StrictMode -Version Latest; & '$STATUS_SCRIPT' -ExportJSON"
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code under StrictMode" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
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
