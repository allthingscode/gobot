#Requires -Version 5.1
# analyze-evals.ps1 - Mine gate decisions and pipeline logs for factory performance metrics
# Usage: powershell/analyze-evals.ps1 [-Json]

param([switch]$Json)

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$GateDir     = ".crucible/session/global/gate_decisions"
$LogDir      = ".crucible/session/archived"
$EvalDir     = ".crucible/session/eval"
$HandoffDirs = @(".crucible/session/handoffs", ".crucible/session/handoffs/archived")

$AutoReasonPattern = "Automated gate passage via CLI flag"

# ?? Gate Decisions ????????????????????????????????????????????????????????????
$latest = @{}
Get-ChildItem "$GateDir/*.json" -ErrorAction SilentlyContinue | ForEach-Object {
	try {
		$d = Get-Content $_.FullName -Raw | ConvertFrom-Json
		if ($d.task_id) {
			if (-not $latest[$d.task_id] -or
				[string]$d.gate_fired_at -gt [string]$latest[$d.task_id].gate_fired_at) {
				$latest[$d.task_id] = $d
			}
		}
	} catch { }
}
$decisions = @($latest.Values | Sort-Object gate_fired_at)
$total     = $decisions.Count

# ?? Pipeline Logs ?????????????????????????????????????????????????????????????
$pipelineMetrics = @{}
$durationStats   = @{} # specialist -> [active durations, when explicitly logged]
$phaseWallStats  = @{} # specialist -> [phase-open wall times]
$anomalies       = @() # {tid, specialist, type, duration}

Get-ChildItem "$LogDir/pipeline-*.log.jsonl" -ErrorAction SilentlyContinue | ForEach-Object {
	$tid = $null; $archSessions = 0; $degraded = 0; $budgetPct = $null; $budgetCeiling = $null
	Get-Content $_.FullName | ForEach-Object {
		try {
			$cleaned = $_ -replace "^$([char]0xFEFF)", ""
			$e = $cleaned | ConvertFrom-Json
			if (-not $tid -and $e.task_id) { $tid = $e.task_id }
			
			if ($e.event -eq "session_end") {
				$logPhase = if ($e.PSObject.Properties["phase"]) { $e.phase } else { $e.specialist }
				if ($logPhase -eq "implementation" -or $logPhase -eq "architect") { $archSessions++ }
				
				# Capture duration ({task_id})
				if ($null -ne $e.duration_seconds) {
					if (-not $durationStats[$logPhase]) { $durationStats[$logPhase] = @() }
					$durationStats[$logPhase] += $e.duration_seconds
				}
				if ($e.metrics -and $null -ne $e.metrics.phase_wall_seconds) {
					if (-not $phaseWallStats[$logPhase]) { $phaseWallStats[$logPhase] = @() }
					$phaseWallStats[$logPhase] += $e.metrics.phase_wall_seconds
				}

				# Capture anomalies ({task_id})
				if ($e.metrics -and $e.metrics.duration_anomaly) {
					$anomalies += [PSCustomObject]@{
						task_id    = $e.task_id
						specialist = $logPhase
						type       = $e.metrics.duration_anomaly
						duration   = if ($null -ne $e.duration_seconds) { $e.duration_seconds } else { $e.metrics.phase_wall_seconds }
					}
				}

				if ($e.metrics) {
					$budgetPct     = $e.metrics.budget_pct_used
					$budgetCeiling = $e.metrics.budget_ceiling
				}
			}
			if ($e.event -eq "degraded") { $degraded++ }
		} catch { }
	}
	if ($tid -and (-not $pipelineMetrics[$tid] -or $pipelineMetrics[$tid].budget_pct -eq $null)) {
		$pipelineMetrics[$tid] = @{
			review_cycles  = $archSessions
			degraded       = $degraded
			budget_pct     = $budgetPct
			budget_ceiling = $budgetCeiling
		}
	}
}

# Specialist duration averages ({task_id})
$specialistDurationSummary = $durationStats.GetEnumerator() | ForEach-Object {
	$avg = if ($_.Value.Count) { [math]::Round(($_.Value | Measure-Object -Average).Average / 60, 1) } else { 0 }
	$confidence = if ($_.Value.Count -ge 5) { "High" } elseif ($_.Value.Count -ge 3) { "Medium" } else { "Low" }
	[PSCustomObject]@{ specialist = $_.Key; avg_minutes = $avg; count = $_.Value.Count; confidence = $confidence }
} | Sort-Object avg_minutes -Descending

$phaseWallSummary = $phaseWallStats.GetEnumerator() | ForEach-Object {
	$avg = if ($_.Value.Count) { [math]::Round(($_.Value | Measure-Object -Average).Average / 60, 1) } else { 0 }
	[PSCustomObject]@{ specialist = $_.Key; avg_minutes = $avg; count = $_.Value.Count }
} | Sort-Object avg_minutes -Descending

# ?? Operator Eval Records ?????????????????????????????????????????????????????
$evalResults = @{}
if (Test-Path $EvalDir) {
	Get-ChildItem "$EvalDir/eval-*.json" -ErrorAction SilentlyContinue | ForEach-Object {
		try {
			$ev = Get-Content $_.FullName -Raw | ConvertFrom-Json
			if ($ev.task_id) { $evalResults[$ev.task_id] = $ev }
		} catch { }
	}
}

# ?? Prompt Version Correlation ????????????????????????????????????????????????
# Collect handoff records for prompt/version and duplication metrics
$handoffRecords = @()
foreach ($dir in $HandoffDirs) {
	Get-ChildItem "$dir/*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {
		try {
			if (-not (Test-Path -LiteralPath $_.FullName)) { return }
			$h = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
			$handoffRecords += [PSCustomObject]@{
				task_id                  = $h.task_id
				source_phase             = if ($h.PSObject.Properties["source_phase"]) { $h.source_phase } else {
					# legacy compat read of pre-rename event log
					$legacy = $h.source_specialist.ToLowerInvariant()
					if ($legacy -eq "groomer") { "grooming" }
					elseif ($legacy -eq "architect") { "implementation" }
					elseif ($legacy -eq "reviewer") { "verification" }
					elseif ($legacy -eq "operator") { "deployment" }
					elseif ($legacy -eq "researcher") { "research" }
					else { $legacy }
				}
				target_phase             = if ($h.PSObject.Properties["target_phase"]) { $h.target_phase } else {
					# legacy compat read of pre-rename event log
					$legacy = $h.target_specialist.ToLowerInvariant()
					if ($legacy -eq "groomer") { "grooming" }
					elseif ($legacy -eq "architect") { "implementation" }
					elseif ($legacy -eq "reviewer") { "verification" }
					elseif ($legacy -eq "operator") { "deployment" }
					elseif ($legacy -eq "researcher") { "research" }
					elseif ($legacy -eq "done") { "done" }
					else { $legacy }
				}
				handoff_retry_count      = if ($h.PSObject.Properties["handoff_retry_count"] -and $null -ne $h.handoff_retry_count) { [int]$h.handoff_retry_count } else { 0 }
				review_strike_count      = if ($h.PSObject.Properties["review_strike_count"] -and $null -ne $h.review_strike_count) { [int]$h.review_strike_count } else { 0 }
				rebase_count             = if ($h.PSObject.Properties["rebase_count"] -and $null -ne $h.rebase_count) { [int]$h.rebase_count } else { 0 }
				cumulative_handoff_count = $h.cumulative_handoff_count
				prompt_version           = $h.prompt_version
				superseded               = ($h.PSObject.Properties["superseded"] -and $h.superseded -eq $true)
				file_name                = $_.Name
				last_write_time          = $_.LastWriteTimeUtc
			}
		} catch { }
	}
}

# Use latest non-superseded handoff per (task_id, source_phase) pair
$handoffsByTask = @{}
foreach ($record in ($handoffRecords | Sort-Object last_write_time -Descending)) {
	if (-not $record.task_id -or -not $record.source_phase -or -not $record.prompt_version) { continue }
	if ($record.superseded) { continue }
	$key = "$($record.task_id)|$($record.source_phase)"
	if (-not $handoffsByTask[$key]) { $handoffsByTask[$key] = $record }
}

# Build per-task prompt version map: task_id -> { implementation: "v1", verification: "v1", ... }
$taskPromptVersions = @{}
foreach ($entry in $handoffsByTask.GetEnumerator()) {
	$parts   = $entry.Key -split '\|'
	$tid     = $parts[0]
	$role    = $parts[1]
	$version = $entry.Value.prompt_version
	if (-not $taskPromptVersions[$tid]) { $taskPromptVersions[$tid] = @{} }
	$taskPromptVersions[$tid][$role] = $version
}

# Group tasks by implementation prompt_version, compute avg review_cycles for each
$versionStats = @{}
foreach ($tid in $taskPromptVersions.Keys) {
	$archVer = $taskPromptVersions[$tid]["implementation"]
	if ($archVer -and $pipelineMetrics[$tid]) {
		if (-not $versionStats[$archVer]) { $versionStats[$archVer] = @() }
		$versionStats[$archVer] += $pipelineMetrics[$tid].review_cycles
	}
}
$versionSummary = $versionStats.GetEnumerator() | ForEach-Object {
	$avg = if ($_.Value.Count) { [math]::Round(($_.Value | Measure-Object -Average).Average, 2) } else { 0 }
	[PSCustomObject]@{ version = $_.Key; tasks = $_.Value.Count; avg_review_cycles = $avg }
} | Sort-Object version

# Duplicate/Superseded Handoff Metrics
$dedupeCandidates = @($handoffRecords | Where-Object {
	$_.task_id -and $_.source_phase -and $_.target_phase
})
$dedupeGroups = @($dedupeCandidates | Group-Object -Property {
	"{0}|{1}|{2}|{3}|{4}|{5}" -f $_.task_id, $_.source_phase, $_.target_phase, [string]$_.review_strike_count, [string]$_.rebase_count, [string]$_.handoff_retry_count
})
$duplicateGroups = @($dedupeGroups | Where-Object { $_.Count -gt 1 })
$duplicateGroupCount = $duplicateGroups.Count
$duplicateHandoffsTotal = (@($duplicateGroups | ForEach-Object { $_.Count - 1 }) | Measure-Object -Sum).Sum
if ($null -eq $duplicateHandoffsTotal) { $duplicateHandoffsTotal = 0 }
$supersededHandoffsTotal = @($handoffRecords | Where-Object { $_.superseded -eq $true }).Count
$supersedeRate = if ($handoffRecords.Count -gt 0) { [math]::Round(($supersededHandoffsTotal / $handoffRecords.Count) * 100, 1) } else { 0 }
$unsupersededDuplicateIncidents = @($duplicateGroups | Where-Object {
	(@($_.Group | Where-Object { $_.superseded -ne $true })).Count -gt 1
}).Count

$topDuplicateTransitionKeys = @(
	$duplicateGroups |
		Sort-Object Count -Descending |
		Select-Object -First 10 |
		ForEach-Object {
			[PSCustomObject]@{
				transition_key  = $_.Name
				duplicate_count = $_.Count - 1
			}
		}
)

$duplicatesByPhase = @(
	$duplicateGroups |
		ForEach-Object {
			$src = ($_.Group | Select-Object -First 1).source_phase
			[PSCustomObject]@{ phase = $src; duplicate_count = $_.Count - 1 }
		} |
		Group-Object phase |
		ForEach-Object {
			[PSCustomObject]@{
				phase = $_.Name
				duplicate_count = (@($_.Group | ForEach-Object { $_.duplicate_count }) | Measure-Object -Sum).Sum
			}
		} |
		Sort-Object duplicate_count -Descending
)

$duplicatesByPhasePair = @(
	$duplicateGroups |
		ForEach-Object {
			$first = $_.Group | Select-Object -First 1
			[PSCustomObject]@{
				pair            = ("{0}->{1}" -f $first.source_phase, $first.target_phase)
				duplicate_count = $_.Count - 1
			}
		} |
		Group-Object pair |
		ForEach-Object {
			[PSCustomObject]@{
				pair            = $_.Name
				duplicate_count = (@($_.Group | ForEach-Object { $_.duplicate_count }) | Measure-Object -Sum).Sum
			}
		} |
		Sort-Object duplicate_count -Descending
)

# ?? Compute Aggregates ????????????????????????????????????????????????????????
$accepted = @($decisions | Where-Object { $_.outcome -eq "accepted"   }).Count
$rejected = @($decisions | Where-Object { $_.outcome -eq "rejected"   }).Count
$redir    = @($decisions | Where-Object { $_.outcome -eq "redirected" }).Count
$abandon  = @($decisions | Where-Object { $_.outcome -eq "abandoned"  }).Count
$rework   = @($decisions | Where-Object { $_.rework_requested -eq $true }).Count

$noSignal    = @($decisions | Where-Object { -not $_.reason -or $_.reason -eq $AutoReasonPattern }).Count
$withSignal  = $total - $noSignal
$signalPct   = if ($total -gt 0) { [math]::Round($withSignal / $total * 100, 1) } else { 0 }

$budgets   = @($pipelineMetrics.Values | Where-Object { $null -ne $_.budget_pct } | ForEach-Object { $_.budget_pct })
$avgBudget = if ($budgets.Count -gt 0) { [math]::Round(($budgets | Measure-Object -Average).Average, 1) } else { $null }

$multiCycle   = @($pipelineMetrics.GetEnumerator() | Where-Object { $_.Value.review_cycles -gt 1 } | ForEach-Object { $_.Key } | Sort-Object)
$highDegraded = @($pipelineMetrics.GetEnumerator() | Where-Object { $_.Value.degraded -gt 2      } | ForEach-Object { $_.Key } | Sort-Object)

if ($Json) {
	@{
		generated_at         = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
		total_tasks          = $total
		gate_outcomes        = @{ accepted = $accepted; rejected = $rejected; redirected = $redir; abandoned = $abandon }
		rework_count         = $rework
		signal_quality       = @{ with_qualitative_reason = $withSignal; auto_placeholder = $noSignal; coverage_pct = $signalPct }
		avg_budget_pct       = $avgBudget
		avg_duration_minutes = @($specialistDurationSummary)
		avg_phase_wall_minutes = @($phaseWallSummary)
		duration_anomalies   = @($anomalies)
		multi_cycle_tasks    = $multiCycle
		high_degraded        = $highDegraded
		handoff_quality      = @{
			total_handoffs            = $handoffRecords.Count
			duplicate_handoffs_total  = $duplicateHandoffsTotal
			duplicate_groups          = $duplicateGroupCount
			superseded_handoffs_total = $supersededHandoffsTotal
			supersede_rate_pct        = $supersedeRate
			unsuperseded_duplicate_incidents = $unsupersededDuplicateIncidents
			top_duplicate_transition_keys = @($topDuplicateTransitionKeys)
			duplicates_by_phase       = @($duplicatesByPhase)
			duplicates_by_phase_pair  = @($duplicatesByPhasePair)
		}
		eval_records         = $evalResults.Count
		prompt_version_stats = @($versionSummary)
	} | ConvertTo-Json -Depth 4
	return
}

# ?? Markdown Report ???????????????????????????????????????????????????????????
$pct = if ($total -gt 0) { { param($n) [math]::Round($n / $total * 100, 1) } } else { { param($n) 0 } }

$report = @()
$report += "# Dev Factory - Eval Report"
$report += "Generated: $((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm")) UTC"
$report += ""

# Gate Summary
$report += "## Gate Decision Summary ($total tasks)"
$report += "| Outcome    | Count | % |"
$report += "|------------|-------|---|"
$report += "| Accepted   | $accepted | $(& $pct $accepted)% |"
$report += "| Rejected   | $rejected | $(& $pct $rejected)% |"
$report += "| Redirected | $redir | $(& $pct $redir)% |"
$report += "| Abandoned  | $abandon | $(& $pct $abandon)% |"
$report += ""
$report += "**Rework requested:** $rework tasks"

if ($rework -gt 0) {
	$report += ""
	$report += "### Rework Tasks"
	$decisions | Where-Object { $_.rework_requested -eq $true } | ForEach-Object {
		$date = if ($_.gate_fired_at) { ($_.gate_fired_at -replace 'T.*','') } else { "unknown" }
		$report += "- **$($_.task_id)** ($date): $($_.reason)"
	}
}

# Signal Quality
$report += ""
$report += "## Gate Signal Quality"
$signalBar = if ($signalPct -ge 80) { "GOOD" } elseif ($signalPct -ge 40) { "PARTIAL" } else { "POOR" }
$report += "Qualitative reasons captured: **$withSignal / $total** ($signalPct%) [$signalBar]"
$report += "Auto-placeholder (no signal): **$noSignal** tasks"
if ($noSignal -gt 0) {
	$report += ""
	$report += "Tasks lacking qualitative gate signal:"
	$decisions | Where-Object { -not $_.reason -or $_.reason -eq $AutoReasonPattern } |
		Select-Object -Last 10 | ForEach-Object {
			$date = if ($_.gate_fired_at) { ($_.gate_fired_at -replace 'T.*','') } else { "?" }
			$report += "- $($_.task_id) ($date) [$($_.outcome)]"
		}
	if ($noSignal -gt 10) { $report += "  ... and $($noSignal - 10) more" }
}

# Pipeline Health
$report += ""
$report += "## Pipeline Health"
$report += "**Average budget used at completion:** $(if ($null -ne $avgBudget) { "$avgBudget%" } else { "n/a (no pipeline logs)" })"
$report += "**Tasks with pipeline data:** $($pipelineMetrics.Count)"
$report += ""
$report += "### Average Session Duration (minutes)"
if ($specialistDurationSummary.Count -gt 0) {
	$report += "| Specialist | Avg Minutes | Count | Confidence |"
	$report += "|------------|-------------|-------|------------|"
	foreach ($s in $specialistDurationSummary) {
		$report += "| $($s.specialist) | $($s.avg_minutes) | $($s.count) | $($s.confidence) |"
	}
} else {
	$report += "(no duration data available)"
}

$report += ""
$report += "### Average Phase-Open Wall Time (minutes)"
if ($phaseWallSummary.Count -gt 0) {
	$report += "| Specialist | Avg Minutes | Count |"
	$report += "|------------|-------------|-------|"
	foreach ($s in $phaseWallSummary) {
		$report += "| $($s.specialist) | $($s.avg_minutes) | $($s.count) |"
	}
} else {
	$report += "(no phase wall-time data available)"
}

if ($anomalies.Count -gt 0) {
	$report += ""
	$report += "### Duration Anomalies"
	$report += "| Task | Specialist | Type | Duration (s) |"
	$report += "|------|------------|------|--------------|"
	foreach ($a in $anomalies) {
		$report += "| $($a.task_id) | $($a.specialist) | $($a.type) | $($a.duration) |"
	}
}

if ($multiCycle.Count -gt 0) {
	$report += ""
	$report += "### Multi-Cycle Tasks (Architect sent back for rework)"
	$multiCycle | ForEach-Object {
		$m = $pipelineMetrics[$_]
		$report += "- **$_**: $($m.review_cycles) architect sessions, $($m.degraded) DEGRADED events, $(if ($null -ne $m.budget_pct) { "$($m.budget_pct)% budget" } else { 'budget n/a' })"
	}
}

if ($highDegraded.Count -gt 0) {
	$report += ""
	$report += "### High DEGRADED Event Count (>2)"
	$highDegraded | ForEach-Object {
		$report += "- **$_**: $($pipelineMetrics[$_].degraded) DEGRADED events"
	}
}

# Handoff Quality
$report += ""
$report += "## Handoff Quality"
$report += "- Total handoffs analyzed: **$($handoffRecords.Count)**"
$report += "- Duplicate handoffs: **$duplicateHandoffsTotal** across **$duplicateGroupCount** duplicate transition groups"
$report += "- Superseded handoffs: **$supersededHandoffsTotal** (**$supersedeRate%**)"
$report += "- Unsuperseded duplicate incidents: **$unsupersededDuplicateIncidents**"
if ($duplicatesByPhase.Count -gt 0) {
	$report += ""
	$report += "### Duplicates by Source Phase"
	$duplicatesByPhase | ForEach-Object {
		$report += "- **$($_.phase)**: $($_.duplicate_count)"
	}
}
if ($duplicatesByPhasePair.Count -gt 0) {
	$report += ""
	$report += "### Duplicates by Phase Pair"
	$duplicatesByPhasePair | ForEach-Object {
		$report += "- **$($_.pair)**: $($_.duplicate_count)"
	}
}
if ($topDuplicateTransitionKeys.Count -gt 0) {
	$report += ""
	$report += "### Top Duplicate Transition Keys"
	$bt = [char]96
	$topDuplicateTransitionKeys | ForEach-Object {
		$report += ("- " + $bt + $_.transition_key + $bt + ": " + $_.duplicate_count)
	}
}

# Prompt Version Correlation
$report += ""
$report += "## Prompt Version Correlation (Architect)"
if ($versionSummary.Count -gt 0) {
	$report += "| Version | Tasks | Avg Review Cycles |"
	$report += "|---------|-------|-------------------|"
	$versionSummary | ForEach-Object {
		$flag = if ($_.avg_review_cycles -gt 1.5) { " [HIGH]" } else { "" }
		$report += "| $($_.version) | $($_.tasks) | $($_.avg_review_cycles)$flag |"
	}
} else {
	$report += "(no handoff data with prompt_version field found)"
}

# Operator Eval Records
$report += ""
$report += "## Operator Eval Records"
$report += "Structured eval records: **$($evalResults.Count)**"
if ($evalResults.Count -gt 0) {
	$acFailed = @($evalResults.Values | Where-Object { $_.ac_verified -eq $false }).Count
	$report += "AC failures reported: $acFailed"
}
if ($evalResults.Count -eq 0) {
	$report += "(none yet - operator eval step not yet executed on any task)"
}

# Recommendations
$report += ""
$report += "## Recommendations"
$recs = @()
$failRate = if ($total -gt 0) { [math]::Round(($rejected + $abandon) / $total * 100, 1) } else { 0 }
if ($failRate -gt 10)                                                        { $recs += "High failure rate ($failRate%) - review rejected/abandoned task reasons for patterns" }
if ($null -ne $avgBudget -and $avgBudget -gt 75)                             { $recs += "High avg budget usage ($avgBudget%) - consider revising budget tier assignments" }
if ($multiCycle.Count -gt ($total * 0.3))                                    { $recs += ">30% of tasks needed multiple review cycles - Architect prompt or spec quality may need improvement" }
if ($signalPct -lt 80)                                                       { $recs += "Gate signal coverage is $signalPct% - provide qualitative reasons at the Human Gate (see operator SOP Step 9)" }
if ($duplicateHandoffsTotal -gt 0)                                           { $recs += "Duplicate handoffs detected ($duplicateHandoffsTotal). Investigate repeated submit patterns and enforce supersede handling." }
if ($supersedeRate -gt 5)                                                    { $recs += "Supersede rate is $supersedeRate% - review specialist handoff discipline and retry ergonomics." }
if ($unsupersededDuplicateIncidents -gt 0)                                   { $recs += "There are $unsupersededDuplicateIncidents unsuperseded duplicate transition incidents. Factory supersede enforcement should reduce this to zero." }
$highCycleVersions = @($versionSummary | Where-Object { $_.avg_review_cycles -gt 1.5 })
if ($highCycleVersions.Count -gt 0) {
	$vers = ($highCycleVersions | ForEach-Object { $_.version }) -join ", "
	$recs += "Architect prompt version(s) with high review cycles: $vers - consider prompt tuning"
}
if ($recs.Count -eq 0) { $recs += "No critical issues detected. Continue monitoring." }
$recs | ForEach-Object { $report += "- $_" }

$report -join "`n"
