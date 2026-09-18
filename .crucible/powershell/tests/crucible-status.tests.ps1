$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$STATUS_SCRIPT = Join-Path $REPO_ROOT "powershell/crucible-status.ps1"

$results = @()










function Write-StatusFixture {
    param([string]$ProjectRoot)
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot ".crucible/session/global") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot ".crucible/backlog") -Force | Out-Null

    @(
        "project: CrucibleStatusTest",
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

$tempRoot = New-TestFixtureRoot -NameHint "crucible-status-test"
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

    $results += Run-Test -Name "Merge conflict window excludes event just over seven days old" -Body {
        $statePath = Join-Path $projectRoot ".crucible/session/global/session_state.json"
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $state.tasks | Add-Member -MemberType NoteProperty -Name "F-005" -Value ([pscustomobject]@{
            status = "blocked"
        }) -Force
        $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding UTF8

        $eventInstant = [DateTimeOffset]::UtcNow.AddDays(-7).AddMinutes(-1).ToOffset([TimeSpan]::FromHours(-5))
        $eventTimestamp = $eventInstant.ToString("yyyy-MM-ddTHH:mm:sszzz", [System.Globalization.CultureInfo]::InvariantCulture)
        $cbPath = Join-Path $projectRoot ".crucible/session/global/circuit_breakers.jsonl"
        $event = [ordered]@{
            event = "circuit_breaker"
            timestamp = $eventTimestamp
            task_id = "F-005"
            outcome = "merge_conflict"
            notes = "older than seven days in UTC"
        }
        $event | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cbPath -Encoding UTF8

        Push-Location $projectRoot
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $STATUS_SCRIPT -ExportJSON
            }
        } finally {
            Pop-Location
        }

        $output = $res.Output -join "`n"
        Assert-Result -Name "seven day boundary status exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        Assert-Result -Name "seven day boundary excludes stale conflict" -Condition ($json.stats.conflict_rate -eq 0) -FailureMessage "expected conflict_rate=0 for stale event. Output:`n$output"

        $statusSource = Get-Content -LiteralPath $STATUS_SCRIPT -Raw -Encoding UTF8
        Assert-Result -Name "seven day boundary cutoff is UTC based" -Condition ($statusSource -match '\(Get-Date\)\.ToUniversalTime\(\)\.AddDays\(-7\)') -FailureMessage "merge conflict cutoff must compare UTC to UTC"
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
