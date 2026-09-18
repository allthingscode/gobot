$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$ANALYZE_SCRIPT = Join-Path $REPO_ROOT "powershell/analyze-evals.ps1"

$results = @()
$tempRoot = New-TestFixtureRoot -NameHint "analyze-evals-test"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )
    [System.IO.File]::WriteAllText($Path, ($Content.Replace("`r`n", "`n")), $utf8NoBom)
}

function New-AnalyzeProject {
    param([Parameter(Mandatory=$true)][string]$Name)

    $projectRoot = Join-Path $tempRoot $Name
    $gateDir = Join-Path $projectRoot ".crucible/session/global/gate_decisions"
    $logDir = Join-Path $projectRoot ".crucible/session/archived"
    $evalDir = Join-Path $projectRoot ".crucible/session/eval"
    $handoffDir = Join-Path $projectRoot ".crucible/session/handoffs"
    $handoffArchiveDir = Join-Path $projectRoot ".crucible/session/handoffs/archived"
    New-Item -ItemType Directory -Path $gateDir, $logDir, $evalDir, $handoffDir, $handoffArchiveDir -Force | Out-Null
    return $projectRoot
}

function Write-GateDecision {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$GateFiredAt = "2026-05-25T12:00:00Z",
        [string]$FileName,
        [switch]$ReworkRequested
    )

    $gateDir = Join-Path $ProjectRoot ".crucible/session/global/gate_decisions"
    $rework = if ($ReworkRequested) { "true" } else { "false" }
    $gateJson = @"
{
  "task_id": "$TaskId",
  "gate_fired_at": "$GateFiredAt",
  "outcome": "accepted",
  "rework_requested": $rework,
  "reason": "Synthetic gate decision."
}
"@
    $name = if ($FileName) { $FileName } else { "$TaskId.json" }
    Write-Utf8NoBomFile -Path (Join-Path $gateDir $name) -Content ($gateJson + "`n")
}

function Write-TestHandoffRecord {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$FileName,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$SourcePhase,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$TargetPhase
    )

    $handoffDir = Join-Path $ProjectRoot ".crucible/session/handoffs"
    $json = @"
{
  "task_id": "$TaskId",
  "source_phase": "$SourcePhase",
  "target_phase": "$TargetPhase",
  "handoff_retry_count": 0,
  "review_strike_count": 0,
  "rebase_count": 0,
  "prompt_version": "test-v1"
}
"@
    Write-Utf8NoBomFile -Path (Join-Path $handoffDir $FileName) -Content ($json + "`n")
}

function Write-PipelineLog {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string[]]$Lines
    )

    $logDir = Join-Path $ProjectRoot ".crucible/session/archived"
    Write-Utf8NoBomFile -Path (Join-Path $logDir "pipeline-$TaskId.log.jsonl") -Content (($Lines -join "`n") + "`n")
}

function Write-AnalyzeFixture {
    param([string]$ProjectRoot)

    Write-GateDecision -ProjectRoot $ProjectRoot -TaskId "T-001"
    Write-PipelineLog -ProjectRoot $ProjectRoot -TaskId "T-001" -Lines @(
        '{"event":"session_end","task_id":"T-001","specialist":"architect","duration_seconds":120}',
        '{"event":"session_end","task_id":"T-001","specialist":"reviewer","duration_seconds":60,"outcome":"redirect"}',
        '{"event":"session_end","task_id":"T-001","specialist":"architect","duration_seconds":90}'
    )
}

function Invoke-AnalyzeJson {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)

    Push-Location $ProjectRoot
    try {
        return Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $ANALYZE_SCRIPT -Json
        }
    } finally {
        Pop-Location
    }
}

function Invoke-AnalyzeMarkdown {
    param([Parameter(Mandatory=$true)][string]$ProjectRoot)

    Push-Location $ProjectRoot
    try {
        return Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $ANALYZE_SCRIPT
        }
    } finally {
        Pop-Location
    }
}

try {
    $results += Run-Test -Name "Json report includes synthetic task" -Body {
        $projectRoot = New-AnalyzeProject -Name "json-basic"
        Write-AnalyzeFixture -ProjectRoot $projectRoot

        $res = Invoke-AnalyzeJson -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "json basic exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        Assert-Result -Name "json basic task count" -Condition ($json.total_tasks -eq 1) -FailureMessage "expected one gate decision. Output:`n$output"
        Assert-Result -Name "json basic duration key absent despite field" -Condition ($null -eq $json.PSObject.Properties["avg_duration_minutes"]) -FailureMessage "expected avg_duration_minutes to be absent despite duration_seconds fixture input. Output:`n$output"
        Assert-Result -Name "json basic multi-cycle task" -Condition (@($json.multi_cycle_tasks) -contains "T-001") -FailureMessage "expected T-001 in multi_cycle_tasks. Output:`n$output"
    }

    $results += Run-Test -Name "Phase wall summary reports phase provenance" -Body {
        $projectRoot = New-AnalyzeProject -Name "json-phase-wall-provenance"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-WALL"
        Write-PipelineLog -ProjectRoot $projectRoot -TaskId "T-WALL" -Lines @(
            '{"event":"session_end","timestamp":"2026-07-30T22:48:43Z","task_id":"T-WALL","phase":"implementation","specialist":"architect","metrics":{"phase_wall_seconds":600}}',
            '{"event":"session_end","timestamp":"2026-07-30T22:40:00Z","task_id":"T-WALL","phase":"implementation","specialist":"architect","metrics":{"phase_wall_seconds":300}}'
        )

        $res = Invoke-AnalyzeJson -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "json phase wall provenance exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        $phaseRows = @($json.avg_phase_wall_minutes)
        $phaseRow = @($phaseRows | Where-Object { $_.phase -eq "implementation" }) | Select-Object -First 1
        Assert-Result -Name "json phase wall provenance phase property" -Condition ($null -ne $phaseRow.PSObject.Properties["phase"]) -FailureMessage "expected phase property on phase wall row. Output:`n$output"
        Assert-Result -Name "json phase wall provenance events property" -Condition ($null -ne $phaseRow.PSObject.Properties["events"] -and $phaseRow.events -eq 2) -FailureMessage "expected events property with count 2. Output:`n$output"
        Assert-Result -Name "json phase wall provenance newest property" -Condition ($null -ne $phaseRow.PSObject.Properties["newest_event"] -and $output -match '"newest_event":\s*"2026-07-30T22:48:43Z"') -FailureMessage "expected newest_event to be the latest contributing timestamp, emitted as an ISO-8601 Zulu string. This is asserted against the raw output rather than the parsed object because ConvertFrom-Json on PowerShell 7 re-parses that string back into a DateTime. Output:`n$output"
        Assert-Result -Name "json phase wall provenance no specialist property" -Condition ($null -eq $phaseRow.PSObject.Properties["specialist"]) -FailureMessage "did not expect specialist property on phase wall row. Output:`n$output"

        $md = Invoke-AnalyzeMarkdown -ProjectRoot $projectRoot
        $markdown = $md.Output -join "`n"
        Assert-Result -Name "markdown phase wall provenance exit code" -Condition ($md.ExitCode -eq 0) -FailureMessage "expected 0, got $($md.ExitCode). Output:`n$markdown"
        Assert-Result -Name "markdown phase wall header uses phase events newest" -Condition ($markdown -match "\| Phase \| Avg Minutes \| Events \| Unattributed \| Newest Event \|") -FailureMessage "expected phase wall table header with provenance. Output:`n$markdown"
    }

    $results += Run-Test -Name "Legacy factory phase and canonical crucible phase aggregate as one phase" -Body {
        # Item 50 renamed the value Crucible stamps on its own gate events. Archived logs
        # are never rewritten, so a real adopter log holds both spellings - and a reader
        # that did not canonicalise would split one phase into two rows, quietly dividing
        # every per-phase figure between them without failing anything.
        $projectRoot = New-AnalyzeProject -Name "phase-rename-mixed"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-RENAME"
        Write-PipelineLog -ProjectRoot $projectRoot -TaskId "T-RENAME" -Lines @(
            '{"event":"session_end","timestamp":"2026-06-01T10:00:00Z","task_id":"T-RENAME","phase":"factory","metrics":{"phase_wall_seconds":600}}',
            '{"event":"session_end","timestamp":"2026-09-04T10:00:00Z","task_id":"T-RENAME","phase":"crucible","metrics":{"phase_wall_seconds":300}}',
            '{"event":"session_end","timestamp":"2026-05-01T10:00:00Z","task_id":"T-RENAME","specialist":"factory","metrics":{"phase_wall_seconds":900}}'
        )

        $res = Invoke-AnalyzeJson -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "mixed phase log exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        $phaseRows = @($json.avg_phase_wall_minutes)

        $legacyRows = @($phaseRows | Where-Object { $_.phase -eq "factory" })
        Assert-Result -Name "no legacy phase row" -Condition ($legacyRows.Count -eq 0) -FailureMessage "the report still shows a separate 'factory' phase row. Output:`n$output"

        $canonicalRow = @($phaseRows | Where-Object { $_.phase -eq "crucible" }) | Select-Object -First 1
        Assert-Result -Name "canonical phase row exists" -Condition ($null -ne $canonicalRow) -FailureMessage "expected a 'crucible' phase row. Output:`n$output"
        Assert-Result -Name "all three spellings in one bucket" -Condition ($canonicalRow.events -eq 3) -FailureMessage "expected all 3 mixed-spelling events in one bucket, got $($canonicalRow.events). Output:`n$output"
        Assert-Result -Name "average spans both spellings" -Condition ($canonicalRow.avg_minutes -eq 10) -FailureMessage "expected the average over all 3 events (600+300+900)/3 = 600s = 10min, got $($canonicalRow.avg_minutes). Output:`n$output"
        Assert-Result -Name "newest event spans the rename" -Condition ($output -match 'newest_event.*2026-09-04T10:00:00Z') -FailureMessage "expected the newest contributing event across both spellings. Output:`n$output"
    }

    $results += Run-Test -Name "Latest gate decision is chosen chronologically" -Body {
        $projectRoot = New-AnalyzeProject -Name "gate-decision-latest"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-DEDUP" -FileName "T-DEDUP-old.json" -GateFiredAt "2025-12-01T00:00:00Z" -ReworkRequested
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-DEDUP" -FileName "T-DEDUP-new.json" -GateFiredAt "2026-01-15T00:00:00Z"

        $res = Invoke-AnalyzeJson -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "json gate latest exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        Assert-Result -Name "json gate latest collapses to one task" -Condition ($json.total_tasks -eq 1) -FailureMessage "expected the two decisions for T-DEDUP to collapse to one task. Output:`n$output"
        Assert-Result -Name "json gate latest wins across year boundary" -Condition ($json.rework_count -eq 0) -FailureMessage "expected the 2026-01-15 decision to beat 2025-12-01, so rework_count should be 0. A month-first culture rendering of these timestamps compares them backwards. Output:`n$output"
    }
    $results += Run-Test -Name "Zero-valued phase wall sample is not dropped" -Body {
        $projectRoot = New-AnalyzeProject -Name "json-phase-wall-zero"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-ZERO"
        Write-PipelineLog -ProjectRoot $projectRoot -TaskId "T-ZERO" -Lines @(
            '{"event":"session_end","timestamp":"2026-07-30T22:00:00Z","task_id":"T-ZERO","phase":"deployment","metrics":{"phase_wall_seconds":0,"duration_anomaly":"missing_start_event"}}',
            '{"event":"session_end","timestamp":"2026-07-30T22:10:00Z","task_id":"T-ZERO","phase":"deployment","metrics":{"phase_wall_seconds":600}}'
        )

        $res = Invoke-AnalyzeJson -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "json phase wall zero exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        $row = @(@($json.avg_phase_wall_minutes) | Where-Object { $_.phase -eq "deployment" }) | Select-Object -First 1
        Assert-Result -Name "json phase wall zero sample counted" -Condition ($null -ne $row -and $row.events -eq 2) -FailureMessage "expected the zero-valued sample to be retained, got events=$($row.events). Output:`n$output"
        Assert-Result -Name "json phase wall zero sample averaged" -Condition ($null -ne $row -and $row.avg_minutes -eq 5) -FailureMessage "expected avg of 0 and 600 seconds to be 5 minutes, got $($row.avg_minutes). Output:`n$output"
    }
    $results += Run-Test -Name "Unattributable spans are excluded from the average and counted" -Body {
        # A resumed session measures the calendar, not the work, so the producer withholds
        # phase_wall_seconds for it. Excluding it silently would leave the average taken
        # over a filtered population with nothing in the report to say so, which is the
        # same class of defect as averaging the outlier. Found by TODO item 63.
        $projectRoot = New-AnalyzeProject -Name "json-phase-wall-unattributed"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-LONG"
        Write-PipelineLog -ProjectRoot $projectRoot -TaskId "T-LONG" -Lines @(
            '{"event":"session_end","timestamp":"2026-09-06T23:16:40Z","task_id":"T-LONG","phase":"grooming","metrics":{"phase_elapsed_seconds":90552}}',
            '{"event":"session_end","timestamp":"2026-09-06T23:32:44Z","task_id":"T-LONG","phase":"grooming","metrics":{"phase_wall_seconds":600}}',
            '{"event":"session_end","timestamp":"2026-09-06T23:55:08Z","task_id":"T-LONG","phase":"deployment","metrics":{"phase_elapsed_seconds":161282}}',
            '{"event":"session_end","timestamp":"2026-09-05T10:00:00Z","task_id":"T-LONG","phase":"verification","metrics":{"phase_wall_seconds":90552}}',
            '{"event":"session_end","timestamp":"2026-09-05T11:00:00Z","task_id":"T-LONG","phase":"verification","metrics":{"phase_wall_seconds":1200}}'
        )

        $res = Invoke-AnalyzeJson -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "json unattributed exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        $grooming = @(@($json.avg_phase_wall_minutes) | Where-Object { $_.phase -eq "grooming" }) | Select-Object -First 1
        Assert-Result -Name "json unattributed span not averaged" -Condition ($null -ne $grooming -and $grooming.events -eq 1 -and $grooming.avg_minutes -eq 10) -FailureMessage "expected only the 600-second sample to be averaged, got events=$($grooming.events) avg=$($grooming.avg_minutes). Output:`n$output"
        Assert-Result -Name "json unattributed span counted" -Condition ($null -ne $grooming -and $grooming.unattributed -eq 1) -FailureMessage "expected the excluded span to be counted. Output:`n$output"

        # A phase with nothing but unattributable spans has to survive into the report.
        # Keying the summary off the timed table alone would drop it entirely, which reads
        # as a phase that never ran.
        $deployment = @(@($json.avg_phase_wall_minutes) | Where-Object { $_.phase -eq "deployment" }) | Select-Object -First 1
        Assert-Result -Name "json phase with no usable sample survives" -Condition ($null -ne $deployment -and $deployment.events -eq 0 -and $deployment.unattributed -eq 1) -FailureMessage "expected a deployment row with no timed events and one exclusion. Output:`n$output"

        # Archived logs are never rewritten, so the spans already on disk as
        # phase_wall_seconds keep arriving forever. Fixing only the producer would leave
        # the adopter's 30 existing outliers inflating this average for good.
        $verification = @(@($json.avg_phase_wall_minutes) | Where-Object { $_.phase -eq "verification" }) | Select-Object -First 1
        Assert-Result -Name "json legacy over-limit wall time excluded" -Condition ($null -ne $verification -and $verification.events -eq 1 -and $verification.avg_minutes -eq 20) -FailureMessage "expected the 90552-second phase_wall_seconds sample to be excluded from the average, got events=$($verification.events) avg=$($verification.avg_minutes). Output:`n$output"
        Assert-Result -Name "json legacy over-limit wall time counted" -Condition ($null -ne $verification -and $verification.unattributed -eq 1) -FailureMessage "expected the excluded legacy span to be counted. Output:`n$output"

        $md = Invoke-AnalyzeMarkdown -ProjectRoot $projectRoot
        $markdown = $md.Output -join "`n"
        Assert-Result -Name "markdown unattributed exit code" -Condition ($md.ExitCode -eq 0) -FailureMessage "expected 0, got $($md.ExitCode). Output:`n$markdown"
        Assert-Result -Name "markdown unattributed column populated" -Condition ($markdown -match "\| grooming \| 10 \| 1 \| 1 \|") -FailureMessage "expected the grooming row to show one averaged event and one exclusion. Output:`n$markdown"
        Assert-Result -Name "markdown empty phase reads n/a" -Condition ($markdown -match "\| deployment \| n/a \| 0 \| 1 \|") -FailureMessage "expected a phase with no usable sample to render n/a rather than a zero average. Output:`n$markdown"
    }
    $results += Run-Test -Name "Duration anomalies omit constructed zero duration" -Body {
        $projectRoot = New-AnalyzeProject -Name "json-duration-anomaly-shape"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-ANOM"
        Write-PipelineLog -ProjectRoot $projectRoot -TaskId "T-ANOM" -Lines @(
            '{"event":"session_end","timestamp":"2026-07-30T23:00:00Z","task_id":"T-ANOM","phase":"verification","specialist":"reviewer","metrics":{"duration_anomaly":"missing_start_event","phase_wall_seconds":0}}'
        )

        $res = Invoke-AnalyzeJson -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "json duration anomaly shape exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        $anomaly = @($json.duration_anomalies) | Select-Object -First 1
        Assert-Result -Name "json duration anomaly duration property absent" -Condition ($null -ne $anomaly -and $null -eq $anomaly.PSObject.Properties["duration"]) -FailureMessage "did not expect duration property on duration anomaly. Output:`n$output"

        $md = Invoke-AnalyzeMarkdown -ProjectRoot $projectRoot
        $markdown = $md.Output -join "`n"
        Assert-Result -Name "markdown duration anomaly exit code" -Condition ($md.ExitCode -eq 0) -FailureMessage "expected 0, got $($md.ExitCode). Output:`n$markdown"
        Assert-Result -Name "markdown duration anomaly three column header" -Condition ($markdown -match "\| Task \| Specialist \| Type \|" -and $markdown -notmatch "Duration \(s\)") -FailureMessage "expected three-column duration anomaly table. Output:`n$markdown"
    }

    $results += Run-Test -Name "Json enforcement coverage reports unverifiable event" -Body {
        $projectRoot = New-AnalyzeProject -Name "json-unverifiable"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-UNVER"
        Write-PipelineLog -ProjectRoot $projectRoot -TaskId "T-UNVER" -Lines @(
            '{"event":"session_end","task_id":"T-UNVER","specialist":"architect","duration_seconds":120}',
            '{"event":"degraded","task_id":"T-UNVER","kind":"file_affinity_unverifiable","outcome":"unverifiable","notes":"spec declared no affected-files section"}'
        )

        $res = Invoke-AnalyzeJson -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "json unverifiable exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        $coverageTasks = @($json.enforcement_coverage.tasks)
        $coverageTask = @($coverageTasks | Where-Object { $_.task_id -eq "T-UNVER" }) | Select-Object -First 1
        Assert-Result -Name "json unverifiable total" -Condition ($json.enforcement_coverage.gates_unverifiable_total -eq 1) -FailureMessage "expected one unverifiable event. Output:`n$output"
        Assert-Result -Name "json unverifiable task count" -Condition ($json.enforcement_coverage.tasks_with_unverifiable_gate -eq 1) -FailureMessage "expected one task with unverifiable gate. Output:`n$output"
        Assert-Result -Name "json unverifiable task listed" -Condition ($null -ne $coverageTask) -FailureMessage "expected T-UNVER in enforcement coverage. Output:`n$output"
        Assert-Result -Name "json unverifiable kind listed" -Condition (@($coverageTask.kinds) -contains "file_affinity_unverifiable") -FailureMessage "expected file_affinity_unverifiable for T-UNVER. Output:`n$output"
        Assert-Result -Name "json unverifiable degraded kind count" -Condition ($json.degraded_by_kind.file_affinity_unverifiable -eq 1) -FailureMessage "expected degraded_by_kind.file_affinity_unverifiable to be 1. Output:`n$output"
    }

    $results += Run-Test -Name "Warned degraded events do not report declined gates" -Body {
        $projectRoot = New-AnalyzeProject -Name "json-warned-only"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-WARN"
        Write-PipelineLog -ProjectRoot $projectRoot -TaskId "T-WARN" -Lines @(
            '{"event":"session_end","task_id":"T-WARN","specialist":"architect","duration_seconds":120}',
            '{"event":"degraded","task_id":"T-WARN","kind":"task_checklist","outcome":"warned","notes":"optional checklist malformed"}',
            '{"event":"degraded","task_id":"T-WARN","kind":"review_strike_2","outcome":"warned","notes":"reduce scope"}'
        )

        $res = Invoke-AnalyzeJson -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "json warned-only exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        Assert-Result -Name "json warned-only unverifiable total zero" -Condition ($json.enforcement_coverage.gates_unverifiable_total -eq 0) -FailureMessage "expected zero unverifiable events. Output:`n$output"
        Assert-Result -Name "json warned-only task count zero" -Condition ($json.enforcement_coverage.tasks_with_unverifiable_gate -eq 0) -FailureMessage "expected zero tasks with unverifiable gates. Output:`n$output"
        Assert-Result -Name "json warned-only no coverage tasks" -Condition (@($json.enforcement_coverage.tasks).Count -eq 0) -FailureMessage "expected no enforcement coverage task rows. Output:`n$output"
        Assert-Result -Name "json warned-only checklist degraded count" -Condition ($json.degraded_by_kind.task_checklist -eq 1) -FailureMessage "expected one task_checklist degraded event. Output:`n$output"
        Assert-Result -Name "json warned-only strike degraded count" -Condition ($json.degraded_by_kind.review_strike_2 -eq 1) -FailureMessage "expected one review_strike_2 degraded event. Output:`n$output"
    }

    $results += Run-Test -Name "Legacy degraded event without kind buckets unknown" -Body {
        $projectRoot = New-AnalyzeProject -Name "json-legacy-unknown"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-LEGACY"
        Write-PipelineLog -ProjectRoot $projectRoot -TaskId "T-LEGACY" -Lines @(
            '{"event":"session_end","task_id":"T-LEGACY","specialist":"architect","duration_seconds":120}',
            '{"event":"degraded","task_id":"T-LEGACY","outcome":"warned","notes":"legacy pre-kind degraded event"}'
        )

        $res = Invoke-AnalyzeJson -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "json legacy exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        Assert-Result -Name "json legacy unknown degraded count" -Condition ($json.degraded_by_kind.unknown -eq 1) -FailureMessage "expected legacy degraded event to bucket as unknown. Output:`n$output"
        Assert-Result -Name "json legacy unverifiable total zero" -Condition ($json.enforcement_coverage.gates_unverifiable_total -eq 0) -FailureMessage "expected legacy degraded event not to count as unverifiable. Output:`n$output"
        Assert-Result -Name "json legacy task count zero" -Condition ($json.enforcement_coverage.tasks_with_unverifiable_gate -eq 0) -FailureMessage "expected zero legacy tasks with unverifiable gates. Output:`n$output"
    }

    $results += Run-Test -Name "Degraded by kind totals match synthetic input" -Body {
        $projectRoot = New-AnalyzeProject -Name "json-kind-totals"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-KINDS"
        Write-PipelineLog -ProjectRoot $projectRoot -TaskId "T-KINDS" -Lines @(
            '{"event":"session_end","task_id":"T-KINDS","specialist":"architect","duration_seconds":120}',
            '{"event":"degraded","task_id":"T-KINDS","kind":"task_checklist","outcome":"warned","notes":"first"}',
            '{"event":"degraded","task_id":"T-KINDS","kind":"task_checklist","outcome":"warned","notes":"second"}',
            '{"event":"degraded","task_id":"T-KINDS","kind":"file_affinity_scope","outcome":"warned","notes":"scope"}',
            '{"event":"degraded","task_id":"T-KINDS","outcome":"warned","notes":"legacy"}'
        )

        $res = Invoke-AnalyzeJson -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "json kind totals exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        Assert-Result -Name "json kind totals checklist count" -Condition ($json.degraded_by_kind.task_checklist -eq 2) -FailureMessage "expected two task_checklist degraded events. Output:`n$output"
        Assert-Result -Name "json kind totals scope count" -Condition ($json.degraded_by_kind.file_affinity_scope -eq 1) -FailureMessage "expected one file_affinity_scope degraded event. Output:`n$output"
        Assert-Result -Name "json kind totals unknown count" -Condition ($json.degraded_by_kind.unknown -eq 1) -FailureMessage "expected one unknown degraded event. Output:`n$output"
    }

    $results += Run-Test -Name "Markdown report emits enforcement coverage with declined gate" -Body {
        $projectRoot = New-AnalyzeProject -Name "markdown-unverifiable"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-MD-UNVER"
        Write-PipelineLog -ProjectRoot $projectRoot -TaskId "T-MD-UNVER" -Lines @(
            '{"event":"session_end","task_id":"T-MD-UNVER","specialist":"architect","duration_seconds":120}',
            '{"event":"degraded","task_id":"T-MD-UNVER","kind":"file_affinity_unverifiable","outcome":"unverifiable","notes":"spec declared no affected-files section"}'
        )

        $res = Invoke-AnalyzeMarkdown -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "markdown unverifiable exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "markdown unverifiable section heading" -Condition ($output -match "## Enforcement Coverage") -FailureMessage "expected enforcement coverage heading. Output:`n$output"
        Assert-Result -Name "markdown unverifiable task listed" -Condition ($output -match "T-MD-UNVER") -FailureMessage "expected T-MD-UNVER in markdown coverage. Output:`n$output"
        Assert-Result -Name "markdown unverifiable kind listed" -Condition ($output -match "file_affinity_unverifiable") -FailureMessage "expected file_affinity_unverifiable in markdown coverage. Output:`n$output"
        Assert-Result -Name "markdown unverifiable degraded breakdown" -Condition ($output -match "file_affinity_unverifiable: 1") -FailureMessage "expected degraded_by_kind breakdown in markdown. Output:`n$output"
    }

    $results += Run-Test -Name "Markdown report emits enforcement coverage with no declined gates" -Body {
        $projectRoot = New-AnalyzeProject -Name "markdown-none"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-MD-NONE"
        Write-PipelineLog -ProjectRoot $projectRoot -TaskId "T-MD-NONE" -Lines @(
            '{"event":"session_end","task_id":"T-MD-NONE","specialist":"architect","duration_seconds":120}',
            '{"event":"degraded","task_id":"T-MD-NONE","kind":"task_checklist","outcome":"warned","notes":"optional checklist malformed"}'
        )

        $res = Invoke-AnalyzeMarkdown -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "markdown none exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "markdown none section heading" -Condition ($output -match "## Enforcement Coverage") -FailureMessage "expected enforcement coverage heading. Output:`n$output"
        Assert-Result -Name "markdown none explicit zero line" -Condition ($output -match 'No enforcement gate reported `outcome: "unverifiable"`\.') -FailureMessage "expected explicit no-unverifiable line. Output:`n$output"
        Assert-Result -Name "markdown none no declined summary" -Condition ($output -notmatch "Gates declined to run:") -FailureMessage "did not expect declined-gate summary. Output:`n$output"
        Assert-Result -Name "markdown none degraded breakdown" -Condition ($output -match "task_checklist: 1") -FailureMessage "expected warned degraded kind breakdown. Output:`n$output"
    }

    $results += Run-Test -Name "Markdown report emits content" -Body {
        $projectRoot = New-AnalyzeProject -Name "markdown-basic"
        Write-AnalyzeFixture -ProjectRoot $projectRoot

        $res = Invoke-AnalyzeMarkdown -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "markdown basic exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "markdown basic report output" -Condition ($output -match "# Crucible - Eval Report" -and $output -match "T-001") -FailureMessage "markdown report missing expected content. Output:`n$output"
        Assert-Result -Name "markdown basic no average session duration heading" -Condition ($output -notmatch "Average Session Duration") -FailureMessage "did not expect dead average session duration heading. Output:`n$output"
        Assert-Result -Name "markdown basic no phase wall data branch" -Condition ($output -match "\(no phase wall-time data available\)") -FailureMessage "expected no phase wall-time data branch. Output:`n$output"
    }
    $results += Run-Test -Name "Handoffs differing only in phase-field case count as one duplicate" -Body {
        # The assertion whose absence let this file's inline dedupe key drift from
        # Get-HandoffDedupeKey. Crucible normalizes case and whitespace before
        # comparing, so it supersedes these two as duplicates; the report's own copy of
        # the key did neither, so it saw two distinct transitions and reported zero
        # duplicates on records Crucible had already deduplicated.
        $projectRoot = New-AnalyzeProject -Name "dedupe-case"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-010"
        Write-TestHandoffRecord -ProjectRoot $projectRoot -FileName "T-010-20260501T120000Z.json" `
            -TaskId "T-010" -SourcePhase "implementation" -TargetPhase "verification"
        Write-TestHandoffRecord -ProjectRoot $projectRoot -FileName "T-010-20260501T130000Z.json" `
            -TaskId "T-010" -SourcePhase "Implementation" -TargetPhase " verification "

        $res = Invoke-AnalyzeJson -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "dedupe case exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        Assert-Result -Name "both handoffs were read" -Condition ($json.handoff_quality.total_handoffs -eq 2) `
            -FailureMessage "expected 2 handoffs analyzed. Output:`n$output"
        Assert-Result -Name "case and whitespace do not split the transition" -Condition ($json.handoff_quality.duplicate_groups -eq 1) `
            -FailureMessage "expected 1 duplicate group, got $($json.handoff_quality.duplicate_groups). Output:`n$output"
        Assert-Result -Name "the second handoff counts as the duplicate" -Condition ($json.handoff_quality.duplicate_handoffs_total -eq 1) `
            -FailureMessage "expected 1 duplicate handoff, got $($json.handoff_quality.duplicate_handoffs_total). Output:`n$output"
        Assert-Result -Name "the key is reported normalized" -Condition (@($json.handoff_quality.top_duplicate_transition_keys)[0].transition_key -eq "t-010|implementation|verification|0|0|0") `
            -FailureMessage "expected the normalized dedupe key. Output:`n$output"
    }

    $results += Run-Test -Name "A handoff with no target phase is dropped, not grouped with other unkeyables" -Body {
        # Get-HandoffDedupeKey returns null for a record it cannot key. Grouping first and
        # discarding the null-key group has to leave that record out entirely - if the
        # nulls grouped together they would report as duplicates of each other.
        $projectRoot = New-AnalyzeProject -Name "dedupe-unkeyable"
        Write-GateDecision -ProjectRoot $projectRoot -TaskId "T-011"
        Write-TestHandoffRecord -ProjectRoot $projectRoot -FileName "T-011-20260501T120000Z.json" `
            -TaskId "T-011" -SourcePhase "implementation" -TargetPhase ""
        Write-TestHandoffRecord -ProjectRoot $projectRoot -FileName "T-011-20260501T130000Z.json" `
            -TaskId "T-011" -SourcePhase "grooming" -TargetPhase ""

        $res = Invoke-AnalyzeJson -ProjectRoot $projectRoot
        $output = $res.Output -join "`n"
        Assert-Result -Name "unkeyable exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        $json = $output | ConvertFrom-Json
        Assert-Result -Name "unkeyable records report no duplicate groups" -Condition ($json.handoff_quality.duplicate_groups -eq 0) `
            -FailureMessage "expected 0 duplicate groups, got $($json.handoff_quality.duplicate_groups). Output:`n$output"
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
