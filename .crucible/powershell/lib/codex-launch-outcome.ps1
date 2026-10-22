# The Codex launcher's outcome: one classifier that turns a run's evidence into one status
# record, and one emitter that writes that record to stdout and to codex-launch-status.txt.
# Before item 246 each outcome arm decided and wrote its own STATUS, and each evidence helper
# made its own assumptions about encoding and field presence (items 167, 177, 203, 209, 211,
# 238). Policy section 8, I14.

# Infrastructure-failure markers. If any appears in the output of a failed run, the reason
# names it; the scan never fails a run that exited 0.
$script:InfraMarkers = @(
    "orchestrator_helper_launch_failed",
    "program not found",
    "codex-windows-sandbox-setup",
    "not logged in",
    "please run codex login",
    "unauthorized",
    "error sending request",
    "command not found"
)

$script:CodexLaunchPhases = @("research", "grooming", "implementation", "verification", "deployment")
# The apostrophe in "You've" as Codex writes it (U+2019) or a user types it, and the U+2019
# UTF-8 bytes as an OEM (code page 437) or ANSI (1252) host decodes them. Item 211.
$script:CodexUsageLimitApostrophes = @(
    "'",
    [string][char]0x2019,
    ([string][char]0x0393 + [char]0x00C7 + [char]0x00D6),
    ([string][char]0x00E2 + [char]0x20AC + [char]0x2122)
)
$script:CodexUsageLimitPattern = "You(?:" + (($script:CodexUsageLimitApostrophes | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")ve hit your usage limit"

$script:CodexLaunchEvidenceKeys = @(
    "ExitCode", "Output", "LastMessage", "UseSchema", "Adhoc", "Phase", "LogEvents", "SinceUtc",
    "TranscriptPath", "LastMessagePath", "RecoveryCommand", "InvokeError", "ReadErrors"
)

function Test-InfraFailure {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $lower = $Text.ToLowerInvariant()
    foreach ($marker in $script:InfraMarkers) {
        if ($lower.Contains($marker)) { return $marker }
    }
    return $null
}

# Returns $null, or an object whose ResetTime is the "try again at <time>" text (empty when the
# message gives none) when the tail of a failed run's output is Codex's account usage-limit
# error. That is a quota stop, not a runtime fault, and re-running -Preflight cannot clear it.
# Only the tail is scanned: the agent's own tool output earlier in the transcript can quote the
# phrase. The real message spells "You've" with a typographic apostrophe, which a host on an
# OEM or ANSI code page decodes as other characters; only those spellings match (items 203, 211).
function Get-UsageLimitInfo {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $tail = if ($Text.Length -gt 2000) { $Text.Substring($Text.Length - 2000) } else { $Text }
    if ($tail -notmatch $script:CodexUsageLimitPattern) { return $null }
    $resetTime = ""
    if ($tail -match "(?m)try again at (.+?)\.?\s*$") { $resetTime = $Matches[1].Trim() }
    # Retries wait one full minute past the projected reset, so the limit has certainly lifted.
    # Only a plain clock time is computed; any other shape leaves RetryNotBefore empty and the
    # advice falls back to "one minute after the stated reset".
    $retryNotBefore = ""
    $parsed = [datetime]::MinValue
    $clockFormats = [string[]]@("h:mm tt", "hh:mm tt", "h:mm:ss tt", "H:mm", "HH:mm")
    if ($resetTime -ne "" -and [datetime]::TryParseExact($resetTime, $clockFormats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$parsed)) {
        $retryNotBefore = $parsed.AddMinutes(1).ToString("h:mm tt", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [PSCustomObject]@{ ResetTime = $resetTime; RetryNotBefore = $retryNotBefore }
}

# The task's pipeline log entries, each with every field the classifier reads present: a field
# the entry omits reads as empty, a phase falls back to the older "specialist" key, and an
# unreadable timestamp reads as $null. Lines that are not JSON objects, and entries for another
# task or with no task_id, are skipped. Item 209 was a strict-mode read of an absent field.
function Read-CodexLaunchLogEvents {
    param([string]$LogPath, [string]$TaskIdValue)
    $events = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) { return ,$events.ToArray() }
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    # An unreadable log throws, whatever the caller's preference: read as empty, it would pass.
    foreach ($line in @(Get-Content -LiteralPath $LogPath -Encoding UTF8 -ErrorAction Stop)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $entry = $line | ConvertFrom-Json } catch { continue }
        if ($entry -isnot [System.Management.Automation.PSCustomObject]) { continue }
        $fields = @{}
        foreach ($name in @("event", "task_id", "phase", "specialist", "outcome", "notes")) {
            $property = $entry.PSObject.Properties[$name]
            $fields[$name] = if ($null -ne $property -and $null -ne $property.Value) { [string]$property.Value } else { "" }
        }
        if ($fields["task_id"] -ne $TaskIdValue) { continue }
        # pwsh 7 converts ISO strings to DateTime on parse; Windows PowerShell 5.1 does not.
        $timestampUtc = $null
        $stampProperty = $entry.PSObject.Properties["timestamp"]
        if ($null -ne $stampProperty -and $stampProperty.Value -is [datetime]) {
            $timestampUtc = $stampProperty.Value.ToUniversalTime()
        } elseif ($null -ne $stampProperty -and $null -ne $stampProperty.Value) {
            $ts = [datetime]::MinValue
            if ([datetime]::TryParse([string]$stampProperty.Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$ts)) { $timestampUtc = $ts }
        }
        $events.Add([PSCustomObject]@{
            Event        = $fields["event"]
            Phase        = if ($fields["phase"] -ne "") { $fields["phase"] } else { $fields["specialist"] }
            Outcome      = $fields["outcome"]
            Notes        = $fields["notes"]
            TimestampUtc = $timestampUtc
        })
    }
    return ,$events.ToArray()
}

function Test-CodexLaunchPipelineComplete {
    param([object]$LogEvent)
    return ($LogEvent.Event -eq "session_end" -and $LogEvent.Notes -eq "Pipeline complete")
}

# Returns the phase a handoff named when the specialist's crucible.ps1 -Init ended this phase
# but never started that one, else $null. A Codex session that ends its turn while -Init is
# still running kills it mid-advance: the session_end is logged, the next phase's prompt is not.
function Get-IncompleteAdvanceTarget {
    param([object[]]$LogEvents, [string]$PhaseName, [datetime]$SinceUtc)
    $recent = @($LogEvents | Where-Object { $null -ne $_.TimestampUtc -and $_.TimestampUtc -ge $SinceUtc })
    if ($recent.Count -gt 0 -and (Test-CodexLaunchPipelineComplete -LogEvent $recent[-1])) { return $null }
    $endIndex = -1
    for ($i = $recent.Count - 1; $i -ge 0; $i--) {
        if ($recent[$i].Event -eq "session_end" -and $recent[$i].Phase -eq $PhaseName -and $recent[$i].Outcome -eq "success") {
            $endIndex = $i
            break
        }
    }
    if ($endIndex -lt 0) { return $null }
    if ($recent[$endIndex].Notes -notmatch "^Handoff to (\S+)") { return $null }
    $target = $Matches[1]
    if ($script:CodexLaunchPhases -notcontains $target) { return $null }
    for ($j = $endIndex + 1; $j -lt $recent.Count; $j++) {
        if ($recent[$j].Event -eq "session_start" -and $recent[$j].Phase -eq $target) { return $null }
    }
    return $target
}

# Grooming, implementation and verification must end with a handoff, logged by
# crucible.ps1 -Init as a successful session_end. Research may end at the Research
# Gate and deployment at the Human Gate. Without a phase session_start, this check
# cannot judge the run. Item 177.
function Test-PhaseEndedWithoutHandoff {
    param([object[]]$LogEvents, [string]$PhaseName, [datetime]$SinceUtc)
    if (@("grooming", "implementation", "verification") -notcontains $PhaseName) { return $false }
    $started = $false
    foreach ($logEvent in @($LogEvents)) {
        $pipelineComplete = Test-CodexLaunchPipelineComplete -LogEvent $logEvent
        if ($logEvent.Phase -ne $PhaseName -and -not $pipelineComplete) { continue }
        if ($logEvent.Event -eq "session_start") { $started = $true; continue }
        if ($logEvent.Event -ne "session_end") { continue }
        if (-not $pipelineComplete -and $logEvent.Outcome -ne "success") { continue }
        if ($null -eq $logEvent.TimestampUtc) { continue }
        if ($logEvent.TimestampUtc -ge $SinceUtc) { return $false }
    }
    return $started
}

function New-CodexLaunchRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Color,
        [AllowEmptyCollection()][string[]]$Detail = @(),
        [AllowEmptyCollection()][string[]]$Advice = @()
    )
    return [PSCustomObject]@{ Status = $Status; ExitCode = $ExitCode; Color = $Color; Detail = [string[]]@($Detail); Advice = [string[]]@($Advice) }
}

function Get-CodexLaunchEvidenceValue {
    param([object]$Evidence, [string]$Key)
    if ($Evidence -is [hashtable] -and $Evidence.ContainsKey($Key)) { return $Evidence[$Key] }
    return $null
}

# The record for a run whose outcome the launcher could not decide. It is never SUCCESS:
# the run may have done its work, but nothing checked that it did.
function New-CodexLaunchUnclassifiedRecord {
    param([object]$Evidence, [string]$Reason)
    $detail = @()
    $exitCode = Get-CodexLaunchEvidenceValue -Evidence $Evidence -Key "ExitCode"
    if ($null -ne $exitCode) { $detail += ("exit code: " + $exitCode) }
    $detail += ("reason: launcher could not classify the run: " + $Reason)
    $transcript = Get-CodexLaunchEvidenceValue -Evidence $Evidence -Key "TranscriptPath"
    if (-not [string]::IsNullOrWhiteSpace([string]$transcript)) { $detail += ("transcript: " + $transcript) }
    return New-CodexLaunchRecord -Status "LAUNCH_FAILED" -ExitCode 1 -Color "Red" -Detail $detail -Advice @(
        "This is NOT a review verdict. The launcher failed while deciding the outcome, so it",
        "does not know whether the specialist finished. Read the transcript and the task's",
        "pipeline log before re-dispatching; do not record this as CHANGES_REQUESTED."
    )
}

function Get-CodexLaunchOutcomeCore {
    param([hashtable]$Evidence)
    if ($null -eq $Evidence) { throw "no evidence was supplied" }
    if ($Evidence.ContainsKey("Running") -and $Evidence["Running"]) {
        if (-not $Evidence.ContainsKey("Level")) { throw "evidence is missing 'Level'" }
        return New-CodexLaunchRecord -Status "RUNNING" -ExitCode 0 -Color "Cyan" -Detail @("level: " + $Evidence["Level"])
    }
    foreach ($key in $script:CodexLaunchEvidenceKeys) {
        if (-not $Evidence.ContainsKey($key)) { throw ("evidence is missing '" + $key + "'") }
    }
    $readErrors = $Evidence["ReadErrors"]
    if ($readErrors -isnot [hashtable]) { throw "evidence 'ReadErrors' is not a hashtable" }
    if (-not [string]::IsNullOrWhiteSpace([string]$Evidence["InvokeError"])) {
        return New-CodexLaunchRecord -Status "LAUNCH_FAILED" -ExitCode 1 -Color "Red" `
            -Detail @(("reason: codex invocation failed: " + $Evidence["InvokeError"]), ("transcript: " + $Evidence["TranscriptPath"])) -Advice @(
            "This is an INFRASTRUCTURE failure, NOT a review verdict. The launcher could not run",
            "codex to completion. Do not record it as CHANGES_REQUESTED. Re-run",
            "launch-codex-specialist.ps1 -Preflight, fix the runtime, then re-dispatch."
        )
    }
    if ($null -eq $Evidence["ExitCode"]) { throw "codex returned no exit code" }
    $exitCode = [int]$Evidence["ExitCode"]
    $output = [string]$Evidence["Output"]
    $lastMessage = [string]$Evidence["LastMessage"]
    $phase = [string]$Evidence["Phase"]
    $exitLine = "exit code: " + $exitCode
    $lastMessageLine = "last message: " + $Evidence["LastMessagePath"]
    $transcriptLine = "transcript: " + $Evidence["TranscriptPath"]

    # A codex exec run that exits 0 AND captures a final message succeeded: codex's own
    # auth/runtime failures exit non-zero and write no last-message. The infra-marker scan only
    # enriches the reason on an already-failed run; broad markers ("unauthorized", "command not
    # found") occur routinely in the agent's own tool output and would fail a successful phase.
    $failReason = ""
    if ($exitCode -eq 127) {
        $failReason = "codex not found on PATH"
    } elseif ($exitCode -ne 0) {
        $usageLimit = Get-UsageLimitInfo -Text $output
        if ($null -ne $usageLimit) {
            $resetText = if ([string]::IsNullOrWhiteSpace($usageLimit.ResetTime)) { "not stated in the message (see the transcript)" } else { $usageLimit.ResetTime }
            $retryText = if ([string]::IsNullOrWhiteSpace($usageLimit.RetryNotBefore)) { "one minute after the stated reset" } else { $usageLimit.RetryNotBefore }
            return New-CodexLaunchRecord -Status "USAGE_LIMIT" -ExitCode 5 -Color "Yellow" `
                -Detail @($exitLine, ("resets: " + $resetText), ("retry_not_before: " + $retryText), $transcriptLine) -Advice @(
                "The Codex account hit its usage limit. This is NOT a runtime fault and NOT a review",
                "verdict; -Preflight and a runtime fix will not help. Stop, tell the human the reset time,",
                ("and do not relaunch or rerun before " + $retryText + " (at least one full minute past the reset)."),
                "After that, re-dispatch this phase: any uncommitted work the run left in the working",
                "tree is kept and can be continued."
            )
        }
        $marker = Test-InfraFailure -Text $output
        if ($null -ne $marker) {
            $failReason = "infrastructure failure (exit " + $exitCode + ", marker: " + $marker + ")"
        } else {
            $failReason = "non-zero exit code (" + $exitCode + ")"
        }
    } elseif ($Evidence["UseSchema"]) {
        if ($readErrors.ContainsKey("last message")) { throw ("could not read the final message: " + $readErrors["last message"]) }
        $verdictOk = $false
        if (-not [string]::IsNullOrWhiteSpace($lastMessage)) {
            try {
                $parsed = $lastMessage | ConvertFrom-Json
                if ($parsed -is [System.Management.Automation.PSCustomObject] -and $parsed.PSObject.Properties["verdict"]) {
                    $verdict = [string]$parsed.verdict
                    if ($verdict -eq "APPROVED" -or $verdict -eq "CHANGES_REQUESTED") { $verdictOk = $true }
                }
            } catch {
                $verdictOk = $false
            }
        }
        if (-not $verdictOk) {
            $failReason = "final message is not a valid review verdict (verdict not APPROVED/CHANGES_REQUESTED)"
        }
    }

    if ($failReason -ne "") {
        return New-CodexLaunchRecord -Status "LAUNCH_FAILED" -ExitCode 1 -Color "Red" `
            -Detail @($exitLine, ("reason: " + $failReason), $transcriptLine) -Advice @(
            "This is an INFRASTRUCTURE failure, NOT a review verdict. Do not record it as",
            "CHANGES_REQUESTED. Re-run launch-codex-specialist.ps1 -Preflight, fix the",
            "runtime/auth, then re-dispatch; or escalate to the human."
        )
    }

    if (-not $Evidence["Adhoc"]) {
        # A failed run is classified from its transcript above; only an exit-0 run needs the log.
        if ($readErrors.ContainsKey("pipeline log")) { throw ("could not read the pipeline log: " + $readErrors["pipeline log"]) }
        $logEvents = @($Evidence["LogEvents"])
        $sinceUtc = [datetime]$Evidence["SinceUtc"]
        $advanceTarget = Get-IncompleteAdvanceTarget -LogEvents $logEvents -PhaseName $phase -SinceUtc $sinceUtc
        if ($null -ne $advanceTarget) {
            return New-CodexLaunchRecord -Status "ADVANCE_INCOMPLETE" -ExitCode 3 -Color "Yellow" `
                -Detail @($exitLine, ("next phase never started: " + $advanceTarget), $lastMessageLine, $transcriptLine) -Advice @(
                ("Crucible ended the " + $phase + " phase but never started " + $advanceTarget + ":"),
                "the specialist's crucible.ps1 -Init was cut off before it finished.",
                "The handoff is intact. Finish the advance, then dispatch the next phase:",
                ("  " + $Evidence["RecoveryCommand"])
            )
        }
        if (Test-PhaseEndedWithoutHandoff -LogEvents $logEvents -PhaseName $phase -SinceUtc $sinceUtc) {
            return New-CodexLaunchRecord -Status "NO_HANDOFF" -ExitCode 4 -Color "Yellow" `
                -Detail @($exitLine, ("phase ended without a handoff: " + $phase), $lastMessageLine, $transcriptLine) -Advice @(
                ("The run ended but Crucible logged no completed " + $phase + " phase: no handoff was"),
                "processed. Read the last message: the specialist may have stopped to ask a question,",
                "escalated to the human (see backlog/blocked/), or quit early. This is not a verdict.",
                "After the human decides, re-dispatch this phase on the same working directory: the",
                "uncommitted work this run left is recognised and continued."
            )
        }
    }

    return New-CodexLaunchRecord -Status "SUCCESS" -ExitCode 0 -Color "Green" `
        -Detail @($exitLine, $lastMessageLine, $transcriptLine) -Advice @(
        "The Codex run completed. Now verify the handoff JSON + task.md checkpoints",
        "per the orchestrator SOP before trusting any verdict."
    )
}

# The one classifier. Evidence is a hashtable: Running and Level while codex runs; afterwards
# the keys in $script:CodexLaunchEvidenceKeys. InvokeError carries an exception that stopped
# codex from running; ReadErrors maps each evidence source the launcher could not read to its
# error, and an outcome that needs that source is not decided without it. An exception while
# classifying yields LAUNCH_FAILED with its reason, never a missing STATUS.
function Get-CodexLaunchOutcome {
    param([AllowNull()][object]$Evidence)
    try {
        if ($null -ne $Evidence -and $Evidence -isnot [hashtable]) { throw "evidence is not a hashtable" }
        $record = Get-CodexLaunchOutcomeCore -Evidence $Evidence
    } catch {
        $record = New-CodexLaunchUnclassifiedRecord -Evidence $Evidence -Reason $_.Exception.Message
    }
    # Evidence that could not be read is named on the record whatever the outcome.
    $readErrors = Get-CodexLaunchEvidenceValue -Evidence $Evidence -Key "ReadErrors"
    if ($readErrors -is [hashtable]) {
        foreach ($source in @($readErrors.Keys | Sort-Object)) {
            $record.Detail = [string[]](@($record.Detail) + ("evidence not read: " + $source + ": " + $readErrors[$source]))
        }
    }
    return $record
}

# The one emitter. The status file and stdout carry the same STATUS line and the same fields,
# in the same order, from the same record; stdout adds the advice. A host shell can lose
# stdout while the launcher keeps running, so the file is the durable copy, and RUNNING names
# this process to tell a live launch from a dead one (item 167).
function Write-CodexLaunchStatus {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][string]$StatusPath
    )
    $stamp = [datetime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture)
    $statusLine = "STATUS=" + $Record.Status
    $fields = @(("launcher_pid: " + $PID), ("updated: " + $stamp)) + @($Record.Detail)
    $fileLines = @($statusLine) + $fields
    try {
        $statusDir = Split-Path -Parent $StatusPath
        if (-not [string]::IsNullOrWhiteSpace($statusDir) -and -not (Test-Path -LiteralPath $statusDir)) {
            New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($StatusPath, (($fileLines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Warning ("Could not write launch status to " + $StatusPath + ": " + $_.Exception.Message)
    }
    Write-Host ""
    Write-Host ("[CODEX SPECIALIST] " + $statusLine) -ForegroundColor $Record.Color
    foreach ($field in $fields) { Write-Host ("  " + $field) }
    if (@($Record.Advice).Count -gt 0) {
        Write-Host ""
        foreach ($line in @($Record.Advice)) { Write-Host ("  " + $line) }
    }
}
