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

    # Item 156: the fixture above uses a layout no current BACKLOG.md has. These rows are
    # the template's layout (linked ID, Priority before Status) and gobot's (no Priority),
    # with R- and suffixed IDs, and blocks recorded on the phase as a circuit breaker does.
    $results += Run-Test -Name "Current BACKLOG.md layouts and phase-level blocks are read" -Body {
        $layoutRoot = Join-Path $tempRoot "layouts"
        Write-StatusFixture -ProjectRoot $layoutRoot
        @"
{
  "tasks": {
    "R-020": { "phases": { "research": { "circuit_breaker": "human_escalation", "status": "blocked", "timestamp": "2026-07-11T01:42:32Z" } } },
    "R-040": { "phases": { "research": { "circuit_breaker": "human_escalation", "status": "blocked", "timestamp": "2026-07-11T01:42:32Z" } } },
    "C-305a": { "phases": { "deployment": { "status": "in_progress", "timestamp": "2026-07-11T01:42:32Z" } } }
  }
}
"@ | Set-Content -LiteralPath (Join-Path $layoutRoot ".crucible/session/global/session_state.json") -Encoding UTF8
        @(
            "# Backlog",
            "",
            "| Priority | Active Count | Item IDs |",
            "|---|---|---|",
            "| **P1** | 1 | C-305a |",
            "",
            "| ID | Priority | Status | Title | Target |",
            "|---|---|---|---|---|",
            "| [C-305a](chores/active/C-305a_Soak.md) | P1 | Ready | Execute the soak | Operator |",
            "| [R-040](features/active/R-040_Audit.md) | P2 | Ready | Open audit | Researcher |",
            "",
            "## Archived",
            "",
            "| ID | Status | Title | Target |",
            "|---|---|---|---|",
            "| [R-020](features/archived/R-020_Audit.md) | Production | Finished audit | Researcher |"
        ) | Set-Content -LiteralPath (Join-Path $layoutRoot ".crucible/backlog/BACKLOG.md") -Encoding UTF8

        Push-Location $layoutRoot
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $STATUS_SCRIPT -ExportJSON
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "layout exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        $r020 = $json.tasks | Where-Object { $_.Task -eq "R-020" }
        $r040 = $json.tasks | Where-Object { $_.Task -eq "R-040" }
        $c305a = $json.tasks | Where-Object { $_.Task -eq "C-305a" }
        Assert-Result -Name "archived row title and status" -Condition ($r020.Title -eq "Finished audit" -and $r020.Status -eq "Production" -and $r020.Blocker -eq "none") -FailureMessage "expected R-020 'Finished audit', Production, not blocked; got '$($r020.Title)', '$($r020.Status)', '$($r020.Blocker)'"
        Assert-Result -Name "phase-level block shown" -Condition ($r040.Title -eq "Open audit" -and $r040.Status -eq "Blocked" -and $r040.Blocker -eq "YES") -FailureMessage "expected R-040 'Open audit', Blocked; got '$($r040.Title)', '$($r040.Status)', '$($r040.Blocker)'"
        Assert-Result -Name "suffixed ID read" -Condition ($c305a.Title -eq "Execute the soak") -FailureMessage "expected C-305a title 'Execute the soak', got '$($c305a.Title)'"
        Assert-Result -Name "blocked count" -Condition ($json.stats.blocked -eq 1) -FailureMessage "expected blocked=1, got $($json.stats.blocked). Output:`n$output"
        Assert-Result -Name "ready count" -Condition ($json.stats.ready -eq 2) -FailureMessage "expected ready=2 (C-305a, R-040), got $($json.stats.ready). Output:`n$output"

        '{ "tasks": {} }' | Set-Content -LiteralPath (Join-Path $layoutRoot ".crucible/session/global/session_state.json") -Encoding UTF8
        Push-Location $layoutRoot
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $STATUS_SCRIPT -ExportJSON
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        $json = $output | ConvertFrom-Json
        Assert-Result -Name "no tasks counts zero" -Condition ($res.ExitCode -eq 0 -and $json.stats.total -eq 0) -FailureMessage "expected total=0 for an empty tasks map, got $($json.stats.total). Output:`n$output"
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
