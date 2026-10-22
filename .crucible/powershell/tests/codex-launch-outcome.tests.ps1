# Item 246: the Codex launcher decides its STATUS in one classifier and writes it with one
# emitter. Table-driven over every STATUS value; each row feeds evidence to the classifier,
# emits the record, reads the status file line by line, and requires stdout to agree with it.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/codex-launch-outcome.ps1")
$LAUNCHER = Join-Path $REPO_ROOT "powershell/launch-codex-specialist.ps1"
$OUTCOME_LIB = Join-Path $REPO_ROOT "powershell/lib/codex-launch-outcome.ps1"

$results = @()
$tempRoot = New-TestFixtureRoot -NameHint "codex-outcome"
$enc = New-Object System.Text.UTF8Encoding($false)
$since = [datetime]::UtcNow.AddMinutes(-5)
$now = [datetime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture)
$usageText = "fake codex working`nERROR: You" + [char]0x2019 + "ve hit your usage limit. Upgrade to Pro or try again at 11:37 PM.`n"
$cp437Text = [System.Text.Encoding]::GetEncoding(437).GetString([System.Text.Encoding]::UTF8.GetBytes($usageText))
$cp1252Text = [System.Text.Encoding]::GetEncoding(1252).GetString([System.Text.Encoding]::UTF8.GetBytes($usageText))

function New-Evidence {
    param([hashtable]$Overrides = @{})
    $evidence = @{
        ExitCode = 0; Output = "fake codex transcript"; LastMessage = ""; UseSchema = $false; Adhoc = $false
        Phase = "verification"; LogEvents = @(); SinceUtc = $since
        TranscriptPath = "/s/T-246/verification/codex-transcript.txt"
        LastMessagePath = "/s/T-246/verification/codex-last-message.txt"
        RecoveryCommand = "pwsh -File crucible.ps1 -Init -TaskId T-246"
        InvokeError = ""; ReadErrors = @{}
    }
    foreach ($key in $Overrides.Keys) { $evidence[$key] = $Overrides[$key] }
    return $evidence
}

function Read-LogFixture {
    param([string]$Name, [string[]]$Lines)
    $path = Join-Path $tempRoot ($Name + ".jsonl")
    [System.IO.File]::WriteAllText($path, (($Lines -join "`n") + "`n"), $enc)
    return Read-CodexLaunchLogEvents -LogPath $path -TaskIdValue "T-246"
}

$startImpl = '{"event":"session_start","task_id":"T-246","phase":"implementation","timestamp":"2020-01-01T00:00:00Z"}'
$startVer = '{"event":"session_start","task_id":"T-246","phase":"verification","timestamp":"2020-01-01T00:00:00Z"}'

try {
    $rows = @(
        @{ Name = "running"; Status = "RUNNING"; Exit = 0; Evidence = @{ Running = $true; Level = "gpt-6-sol at low effort" }; Field = "level: gpt-6-sol at low effort" },
        @{ Name = "success"; Status = "SUCCESS"; Exit = 0; Evidence = (New-Evidence); Field = "exit code: 0" },
        @{ Name = "no handoff"; Status = "NO_HANDOFF"; Exit = 4; Field = "phase ended without a handoff: implementation"
           Evidence = (New-Evidence @{ Phase = "implementation"; LogEvents = (Read-LogFixture "nohandoff" @($startImpl)) }) },
        @{ Name = "advance incomplete"; Status = "ADVANCE_INCOMPLETE"; Exit = 3; Field = "next phase never started: deployment"
           Evidence = (New-Evidence @{ LogEvents = (Read-LogFixture "advance" @('{"event":"session_end","task_id":"T-246","phase":"verification","timestamp":"' + $now + '","outcome":"success","notes":"Handoff to deployment"}')) }) },
        @{ Name = "usage limit"; Status = "USAGE_LIMIT"; Exit = 5; Field = "retry_not_before: 11:38 PM"
           Evidence = (New-Evidence @{ ExitCode = 1; Output = $usageText }) },
        @{ Name = "usage limit decoded under code page 437"; Status = "USAGE_LIMIT"; Exit = 5; Field = "resets: 11:37 PM"
           Evidence = (New-Evidence @{ ExitCode = 1; Output = $cp437Text }) },
        @{ Name = "usage limit decoded under code page 1252"; Status = "USAGE_LIMIT"; Exit = 5; Field = "resets: 11:37 PM"
           Evidence = (New-Evidence @{ ExitCode = 1; Output = $cp1252Text }) },
        @{ Name = "usage limit with an unreadable pipeline log"; Status = "USAGE_LIMIT"; Exit = 5; Field = "evidence not read: pipeline log: log is locked"
           Evidence = (New-Evidence @{ ExitCode = 1; Output = $usageText; ReadErrors = @{ "pipeline log" = "log is locked" } }) },
        @{ Name = "exit-0 run with an unreadable pipeline log"; Status = "LAUNCH_FAILED"; Exit = 1; Field = "reason: launcher could not classify the run: could not read the pipeline log: log is locked"
           Evidence = (New-Evidence @{ ReadErrors = @{ "pipeline log" = "log is locked" } }) },
        @{ Name = "review verdict with an unreadable final message"; Status = "LAUNCH_FAILED"; Exit = 1; Field = "reason: launcher could not classify the run: could not read the final message: busy"
           Evidence = (New-Evidence @{ UseSchema = $true; ReadErrors = @{ "last message" = "busy" } }) },
        @{ Name = "codex invocation threw"; Status = "LAUNCH_FAILED"; Exit = 1; Field = "reason: codex invocation failed: injected fault"
           Evidence = (New-Evidence @{ ExitCode = $null; Output = ""; InvokeError = "injected fault" }) },
        @{ Name = "a banner that spells out You have"; Status = "LAUNCH_FAILED"; Exit = 1; Field = "reason: non-zero exit code (1)"
           Evidence = (New-Evidence @{ ExitCode = 1; Output = "test output: You have hit your usage limit. try again at 1:00 AM." }) },
        @{ Name = "infra failure"; Status = "LAUNCH_FAILED"; Exit = 1; Field = "reason: infrastructure failure (exit 1, marker: not logged in)"
           Evidence = (New-Evidence @{ ExitCode = 1; Output = "error: not logged in" }) },
        @{ Name = "codex absent"; Status = "LAUNCH_FAILED"; Exit = 1; Field = "reason: codex not found on PATH"
           Evidence = (New-Evidence @{ ExitCode = 127; Output = "'codex' was not found on PATH." }) },
        @{ Name = "invalid review verdict"; Status = "LAUNCH_FAILED"; Exit = 1; Field = "reason: final message is not a valid review verdict (verdict not APPROVED/CHANGES_REQUESTED)"
           Evidence = (New-Evidence @{ UseSchema = $true; LastMessage = "5" }) },
        @{ Name = "outcome-less terminal entry"; Status = "SUCCESS"; Exit = 0; Field = "exit code: 0"
           Evidence = (New-Evidence @{ LogEvents = (Read-LogFixture "terminal" @($startVer, ('{"event":"session_end","task_id":"T-246","phase":"verification","timestamp":"' + $now + '","notes":"Pipeline complete"}'))) }) },
        @{ Name = "outcome-less phase end"; Status = "NO_HANDOFF"; Exit = 4; Field = "phase ended without a handoff: implementation"
           Evidence = (New-Evidence @{ Phase = "implementation"; LogEvents = (Read-LogFixture "nooutcome" @($startImpl, ('{"event":"session_end","task_id":"T-246","phase":"implementation","timestamp":"' + $now + '"}'))) }) },
        @{ Name = "entries with no task_id or an older specialist key"; Status = "ADVANCE_INCOMPLETE"; Exit = 3; Field = "next phase never started: deployment"
           Evidence = (New-Evidence @{ LogEvents = (Read-LogFixture "oldfields" @(
               ('{"event":"heartbeat","timestamp":"' + $now + '"}'),
               ('{"event":"session_end","task_id":"T-246","specialist":"verification","timestamp":"' + $now + '","outcome":"success","notes":"Handoff to deployment"}'))) }) },
        @{ Name = "log lines that are not JSON objects"; Status = "SUCCESS"; Exit = 0; Field = "exit code: 0"
           Evidence = (New-Evidence @{ Phase = "implementation"; LogEvents = (Read-LogFixture "nonobjects" @('5', '"text"', '[1,2]', '{broken', 'null')) }) },
        @{ Name = "evidence missing a key"; Status = "LAUNCH_FAILED"; Exit = 1; Field = "reason: launcher could not classify the run: evidence is missing 'LogEvents'"
           Evidence = (& { $e = New-Evidence; $e.Remove("LogEvents"); $e }) },
        @{ Name = "no exit code"; Status = "LAUNCH_FAILED"; Exit = 1; Field = "reason: launcher could not classify the run: codex returned no exit code"
           Evidence = (New-Evidence @{ ExitCode = $null }) }
    )

    $seen = @{}
    foreach ($row in $rows) {
        $results += Run-Test -Name ("Classifier and emitter agree: " + $row.Name) -Body {
            $thrown = ""
            try { $record = Get-CodexLaunchOutcome -Evidence $row.Evidence } catch { $record = $null; $thrown = $_.Exception.Message }
            Assert-Result -Name ($row.Name + " classifier returns a record") -Condition ($null -ne $record) -FailureMessage ("the classifier threw: " + $thrown)
            Assert-Result -Name ($row.Name + " status") -Condition ($record.Status -eq $row.Status) -FailureMessage ("expected " + $row.Status + ", got " + $record.Status + ": " + ($record.Detail -join " | "))
            Assert-Result -Name ($row.Name + " exit code") -Condition ($record.ExitCode -eq $row.Exit) -FailureMessage ("expected exit " + $row.Exit + ", got " + $record.ExitCode)
            $statusPath = Join-Path $tempRoot (($row.Name -replace '[^A-Za-z0-9]', '-') + "/codex-launch-status.txt")
            $stdout = @(& { Write-CodexLaunchStatus -Record $record -StatusPath $statusPath } 6>&1 | ForEach-Object { [string]$_ })
            $raw = [System.IO.File]::ReadAllText($statusPath)
            Assert-Result -Name ($row.Name + " file ends in one newline") -Condition ($raw.EndsWith("`n") -and -not $raw.EndsWith("`n`n")) -FailureMessage "status file: $raw"
            $fileLines = @($raw.TrimEnd("`n") -split "`n")
            Assert-Result -Name ($row.Name + " file status line") -Condition ($fileLines[0] -ceq ("STATUS=" + $row.Status)) -FailureMessage "status file: $raw"
            Assert-Result -Name ($row.Name + " file process fields") -Condition ($fileLines[1] -match "^launcher_pid: \d+$" -and $fileLines[2] -match "^updated: \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$") -FailureMessage "status file: $raw"
            Assert-Result -Name ($row.Name + " file carries the detail") -Condition ($fileLines -ccontains $row.Field) -FailureMessage ("expected '" + $row.Field + "' in: " + $raw)
            $statusIdx = @(for ($n = 0; $n -lt $stdout.Count; $n++) { if ($stdout[$n] -match "STATUS=") { $n } })
            Assert-Result -Name ($row.Name + " one stdout status line") -Condition ($statusIdx.Count -eq 1 -and $stdout[$statusIdx[0]] -ceq ("[CODEX SPECIALIST] " + $fileLines[0])) -FailureMessage ("stdout:`n" + ($stdout -join "`n"))
            $block = @($fileLines[0])
            for ($n = $statusIdx[0] + 1; $n -lt $stdout.Count -and $stdout[$n] -match "^  \S"; $n++) { $block += $stdout[$n].Substring(2) }
            Assert-Result -Name ($row.Name + " stdout and file agree line for line") -Condition (($block -join "`n") -ceq ($fileLines -join "`n")) -FailureMessage ("stdout block:`n" + ($block -join "`n") + "`nfile:`n" + $raw)
            $seen[$row.Status] = $true
        }
    }

    $results += Run-Test -Name "The table covers every STATUS value" -Body {
        foreach ($status in @("RUNNING", "SUCCESS", "NO_HANDOFF", "ADVANCE_INCOMPLETE", "USAGE_LIMIT", "LAUNCH_FAILED")) {
            Assert-Result -Name ("covered " + $status) -Condition ($seen.ContainsKey($status)) -FailureMessage ("no row produced " + $status)
        }
    }

    $results += Run-Test -Name "The usage-limit text matches only real apostrophe spellings" -Body {
        $rest = " hit your usage limit. Try again at 2:15 AM."
        foreach ($apostrophe in @("'", [string][char]0x2019)) {
            $text = "You" + $apostrophe + "ve" + $rest
            foreach ($decoded in @($text, [System.Text.Encoding]::GetEncoding(437).GetString([System.Text.Encoding]::UTF8.GetBytes($text)), [System.Text.Encoding]::GetEncoding(1252).GetString([System.Text.Encoding]::UTF8.GetBytes($text)))) {
                $info = Get-UsageLimitInfo -Text $decoded
                Assert-Result -Name ("usage limit read from: " + $decoded) -Condition ($null -ne $info -and $info.ResetTime -eq "2:15 AM") -FailureMessage ("not recognised: " + $decoded)
            }
        }
        foreach ($text in @("You have hit your usage limit.", "Youve hit your usage limit.", "You  ve hit your usage limit.", "You'd've hit your usage limit.", "Your've hit your usage limit.", "You-ve hit your usage limit.")) {
            Assert-Result -Name ("not a usage limit: " + $text) -Condition ($null -eq (Get-UsageLimitInfo -Text $text)) -FailureMessage ("matched: " + $text)
        }
    }

    $results += Run-Test -Name "An exception inside classification yields LAUNCH_FAILED with its reason" -Body {
        $original = ${function:Get-UsageLimitInfo}
        try {
            ${function:script:Get-UsageLimitInfo} = { throw "usage parser exploded" }
            $thrown = ""
            try { $record = Get-CodexLaunchOutcome -Evidence (New-Evidence @{ ExitCode = 1; Output = "anything" }) } catch { $record = $null; $thrown = $_.Exception.Message }
        } finally {
            ${function:script:Get-UsageLimitInfo} = $original
        }
        Assert-Result -Name "exception does not escape the classifier" -Condition ($null -ne $record) -FailureMessage ("the classifier threw: " + $thrown)
        Assert-Result -Name "exception status" -Condition ($record.Status -eq "LAUNCH_FAILED" -and $record.ExitCode -eq 1) -FailureMessage ("got " + $record.Status)
        Assert-Result -Name "exception reason" -Condition ($record.Detail -ccontains "reason: launcher could not classify the run: usage parser exploded") -FailureMessage ($record.Detail -join " | ")
        Assert-Result -Name "exception keeps exit and transcript" -Condition (($record.Detail -ccontains "exit code: 1") -and ($record.Detail -ccontains "transcript: /s/T-246/verification/codex-transcript.txt")) -FailureMessage ($record.Detail -join " | ")
        $nullRecord = Get-CodexLaunchOutcome -Evidence $null
        Assert-Result -Name "null evidence status" -Condition ($nullRecord.Status -eq "LAUNCH_FAILED") -FailureMessage ("got " + $nullRecord.Status)
    }

    $results += Run-Test -Name "The launcher states no STATUS of its own" -Body {
        $launcherText = [System.IO.File]::ReadAllText($LAUNCHER)
        $libText = [System.IO.File]::ReadAllText($OUTCOME_LIB)
        Assert-Result -Name "no STATUS literal in the launcher" -Condition (-not $launcherText.Contains("STATUS=")) -FailureMessage "launch-codex-specialist.ps1 writes a STATUS line outside Write-CodexLaunchStatus"
        Assert-Result -Name "one STATUS literal in the lib" -Condition ([regex]::Matches($libText, [regex]::Escape('"STATUS="')).Count -eq 1) -FailureMessage "lib/codex-launch-outcome.ps1 must build the STATUS line in one place"
        $runAnchor = '$result = Invoke-CodexExec -CodexArgs $codexArgs'
        Assert-Result -Name "one phase run anchor" -Condition ([regex]::Matches($launcherText, [regex]::Escape($runAnchor)).Count -eq 1) -FailureMessage "expected one '$runAnchor' in the launcher"
        $afterRun = $launcherText.Substring($launcherText.IndexOf($runAnchor))
        $exits = @([regex]::Matches($afterRun, '(?m)^\s*exit\b.*$') | ForEach-Object { $_.Value.Trim() })
        Assert-Result -Name "one exit after the run, from the record" -Condition ($exits.Count -eq 1 -and $exits[0] -eq 'exit $outcome.ExitCode') -FailureMessage ("exits after the run: " + ($exits -join " | "))
        Assert-Result -Name "the record is emitted before that exit" -Condition ($afterRun -match 'Write-CodexLaunchStatus -StatusPath \$statusPath -Record \$outcome\s+exit \$outcome\.ExitCode') -FailureMessage "the outcome must be emitted immediately before the launcher exits"

        # Nothing between the RUNNING record and the outcome may throw past the emitter: after
        # RUNNING the launcher builds the evidence from plain values, runs everything else inside
        # one try whose catch yields a record, emits, and exits.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($LAUNCHER, [ref]$null, [ref]$null)
        $top = @($ast.EndBlock.Statements)
        $runningIdx = -1
        for ($n = 0; $n -lt $top.Count; $n++) { if ($top[$n].Extent.Text -match '^Write-CodexLaunchStatus\b.*Running = \$true') { $runningIdx = $n } }
        Assert-Result -Name "RUNNING emitted at the top level" -Condition ($runningIdx -ge 0) -FailureMessage "no top-level Write-CodexLaunchStatus for RUNNING"
        $after = @($top[($runningIdx + 1)..($top.Count - 1)])
        $shape = ($after | ForEach-Object { $_.GetType().Name }) -join ","
        Assert-Result -Name "after RUNNING: evidence, one try, emit, exit" -Condition ($shape -eq "AssignmentStatementAst,TryStatementAst,PipelineAst,ExitStatementAst") -FailureMessage ("top-level statements after RUNNING: " + $shape)
        $evidenceCommands = @($after[0].FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
        Assert-Result -Name "evidence built from plain values" -Condition ($after[0].Left.Extent.Text -eq '$evidence' -and $evidenceCommands.Count -eq 0) -FailureMessage ("the evidence assignment runs commands: " + $after[0].Extent.Text)
        Assert-Result -Name "the try yields a record" -Condition (@($after[1].CatchClauses).Count -ge 1 -and $after[1].CatchClauses[-1].Body.Extent.Text -match '\$outcome = New-CodexLaunchUnclassifiedRecord') -FailureMessage "the outer catch must set the outcome"
        $invoke = @($after[1].FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq "Invoke-CodexExec" }, $true))
        Assert-Result -Name "codex runs inside the try" -Condition ($invoke.Count -eq 1) -FailureMessage ("Invoke-CodexExec calls inside the outer try: " + $invoke.Count)
        $all = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq "Invoke-CodexExec" -and $node.Extent.Text -match '\$codexArgs' }, $true))
        Assert-Result -Name "no phase run outside the try" -Condition ($all.Count -eq 1) -FailureMessage ("phase runs of Invoke-CodexExec: " + $all.Count)
        Assert-Result -Name "emit and exit use the outcome" -Condition ($after[2].Extent.Text -eq 'Write-CodexLaunchStatus -StatusPath $statusPath -Record $outcome' -and $after[3].Extent.Text -eq 'exit $outcome.ExitCode') -FailureMessage ("emit: " + $after[2].Extent.Text + " exit: " + $after[3].Extent.Text)
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
