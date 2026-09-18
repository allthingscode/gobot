# Regression tests for culture-invariant persisted timestamps.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$CRUCIBLE_LIB = Join-Path $REPO_ROOT "powershell/crucible-lib.ps1"
$NEWHANDOFF_SCRIPT = Join-Path $REPO_ROOT "powershell/new-handoff.ps1"
$Quiet = $true
. $CRUCIBLE_LIB

$results = @()
$tempRoot = New-TestFixtureRoot -NameHint "culture-timestamps-test"
$isoPattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
# Matches the timestamp as it is written to disk. Asserting against the raw JSON rather
# than a parsed object keeps these tests engine-independent: PowerShell 7's
# ConvertFrom-Json turns a well-formed ISO-8601 string into a [DateTime], which stringifies
# culture-formatted, so a parsed assertion fails on exactly the values that are correct.
$isoField = { param($Field) '"' + $Field + '":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"' }

function Write-TestHandoffFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][hashtable]$Values
    )

    if (-not $Values.ContainsKey("generated_by")) {
        $Values.generated_by = "new-handoff.ps1"
    }
    if (-not $Values.ContainsKey("tool_version")) {
        $Values.tool_version = "1.0.0"
    }

    $Values | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-HandoffEmitterProject {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$TaskId
    )

    $projectRoot = Join-Path $Root ("handoff-emitter-" + $TaskId)
    $activeDir = Join-Path $projectRoot ".crucible/backlog/features/active"
    $sessionDir = Join-Path $projectRoot ".crucible/session"
    New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sessionDir "handoffs") -Force | Out-Null

    @(
        "project: HandoffEmitterCultureTest",
        "paths:",
        "  backlog: .crucible/backlog",
        "  session: .crucible/session",
        "  workspaces: .crucible/.agent-workspaces",
        "  prompts: .crucible/prompts"
    ) | Set-Content -LiteralPath (Join-Path $projectRoot ".crucible/config.yaml") -Encoding UTF8

    $specPath = Join-Path $activeDir ($TaskId + "_CultureTest.md")
    @(
        "---",
        "item_id: $TaskId",
        "title: Culture Test",
        "status: Ready",
        "target_phase: grooming",
        "budget_tier: low",
        "file_affinity: [src/]",
        "---",
        "",
        "# Culture Test"
    ) | Set-Content -LiteralPath $specPath -Encoding UTF8

    @(
        "# Backlog",
        "",
        "| ID | Title | Category | Status | Specialist | Priority |",
        "| --- | --- | --- | --- | --- | --- |",
        "| $TaskId | [Culture Test](features/active/${TaskId}_CultureTest.md) | Feature | Ready | Groomer | P1 |"
    ) | Set-Content -LiteralPath (Join-Path $projectRoot ".crucible/backlog/BACKLOG.md") -Encoding UTF8

    return $projectRoot
}

function Invoke-NewHandoffUnderCulture {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$CultureName
    )

    $childScript = Join-Path $tempRoot ("new-handoff-" + $TaskId + "-" + $CultureName + ".ps1")
    $scriptEscaped = $NEWHANDOFF_SCRIPT.Replace("'", "''")
    $projectEscaped = $ProjectRoot.Replace("'", "''")
    $taskEscaped = $TaskId.Replace("'", "''")
    $cultureEscaped = $CultureName.Replace("'", "''")
    $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$oldCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('$cultureEscaped')
    & '$scriptEscaped' -TaskId '$taskEscaped' -Source grooming -Target implementation -Reason 'Culture filename test' -ProjectRoot '$projectEscaped'
} finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = `$oldCulture
}
"@
    [System.IO.File]::WriteAllText($childScript, $scriptContent, (New-Object System.Text.UTF8Encoding $false))
    return Invoke-ExternalCommand {
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $childScript
    }
}

try {
    $results += Run-Test -Name "Write-EventLog emits ISO timestamp under fi-FI" -Body {
        $oldCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("fi-FI")
            $logFile = Join-Path $tempRoot "event/pipeline.log.jsonl"
            $cbFile = Join-Path $tempRoot "event/circuit_breakers.jsonl"

            Write-EventLog -Event "session_start" -TaskId "C-CULTURE-EVENT" -Phase "implementation" -LogFile $logFile -CircuitBreakerHistoryFile $cbFile

            $rawLine = [string](Get-Content -LiteralPath $logFile -Encoding UTF8 -Tail 1)
            Assert-Result -Name "event log timestamp is ISO under fi-FI" -Condition ($rawLine -match (& $isoField "timestamp")) -FailureMessage ("line on disk was " + $rawLine)
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture
        }
    }

    $results += Run-Test -Name "Handoff supersede writer emits ISO timestamp under fi-FI" -Body {
        $oldCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("fi-FI")
            $handoffDir = Join-Path $tempRoot "handoffs"
            New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
            $oldPath = Join-Path $handoffDir "C-CULTURE-HANDOFF-20260830T010000Z.json"
            $newPath = Join-Path $handoffDir "C-CULTURE-HANDOFF-20260830T020000Z.json"
            $base = @{
                task_id = "C-CULTURE-HANDOFF"
                source_phase = "grooming"
                target_phase = "implementation"
                handoff_retry_count = 0
                review_strike_count = 0
                rebase_count = 0
                summary = "duplicate transition"
            }
            Write-TestHandoffFile -Path $oldPath -Values $base
            Write-TestHandoffFile -Path $newPath -Values $base

            Mark-DuplicateHandoffsAsSuperseded -TaskId "C-CULTURE-HANDOFF" -HandoffDir $handoffDir

            $rawOld = [string](Get-Content -LiteralPath $oldPath -Raw -Encoding UTF8)
            Assert-Result -Name "handoff superseded timestamp is ISO under fi-FI" -Condition ($rawOld -match (& $isoField "superseded_at")) -FailureMessage ("file on disk was " + $rawOld)
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture
        }
    }

    $results += Run-Test -Name "Gate decision writer emits ISO timestamp under fi-FI" -Body {
        $projectRoot = Join-Path $tempRoot "gate-project"
        $sessionDir = Join-Path $projectRoot ".crucible/session"
        New-Item -ItemType Directory -Path (Join-Path $sessionDir "global/gate_decisions") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $projectRoot ".crucible") -Force | Out-Null
        git -C $projectRoot init --initial-branch=master | Out-Null
        git -C $projectRoot config user.name "Tester"
        git -C $projectRoot config user.email "test@example.com"
        "initial" | Set-Content -LiteralPath (Join-Path $projectRoot "README.md") -Encoding UTF8
        git -C $projectRoot add README.md | Out-Null
        git -C $projectRoot commit -m "initial commit" | Out-Null
        @"
project:
  name: Culture Fixture
  description: Culture Fixture
  default_branch: master
review:
  auto_push: false
"@ | Set-Content -LiteralPath (Join-Path $projectRoot ".crucible/config.yaml") -Encoding UTF8

        $childScript = Join-Path $tempRoot "run-gate-culture.ps1"
        $libPath = $CRUCIBLE_LIB.Replace("'", "''")
        $projectEscaped = $projectRoot.Replace("'", "''")
        $sessionEscaped = $sessionDir.Replace("'", "''")
        $logFile = (Join-Path $sessionDir "C-CULTURE-GATE/pipeline.log.jsonl").Replace("'", "''")
        $cbFile = (Join-Path $sessionDir "global/circuit_breakers.jsonl").Replace("'", "''")
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$oldCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("fi-FI")
    `$Quiet = `$true
    . '$libPath'
    `$ctx = @{
        IsBootstrap = `$false
        SessionDir = '$sessionEscaped'
        LogFile = '$logFile'
        CircuitBreakerHistoryFile = '$cbFile'
        GateOutcome = `$null
        GateReason = `$null
        GateRedirectTarget = `$null
        CrucibleRoot = '.crucible'
        Quiet = `$true
        RepoRoot = '$projectEscaped'
        Handoff = [PSCustomObject]@{
            task_id = 'C-CULTURE-GATE'
            source_phase = 'deployment'
            target_phase = 'done'
            cumulative_handoff_count = 1
            artifacts = @()
        }
    }
    Push-Location '$projectEscaped'
    try {
        Invoke-HumanGate -Context `$ctx
    } finally {
        Pop-Location
    }
} finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = `$oldCulture
}
"@
        [System.IO.File]::WriteAllText($childScript, $scriptContent, (New-Object System.Text.UTF8Encoding $false))
        $output = @(& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $childScript)
        Assert-Result -Name "gate decision child exits zero" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("exit=" + $LASTEXITCODE + " output=" + ($output -join "`n"))

        $gatePath = Join-Path $sessionDir "global/gate_decisions/gate_decision_C-CULTURE-GATE_pending.json"
        Assert-Result -Name "gate decision fixture exists" -Condition (Test-Path -LiteralPath $gatePath) -FailureMessage "pending gate decision was not written"
        $rawGate = [string](Get-Content -LiteralPath $gatePath -Raw -Encoding UTF8)
        Assert-Result -Name "gate decision timestamp is ISO under fi-FI" -Condition ($rawGate -match (& $isoField "gate_fired_at")) -FailureMessage ("file on disk was " + $rawGate)
    }

    $results += Run-Test -Name "Timestamp written under fi-FI parses under en-US" -Body {
        $oldCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("fi-FI")
            $logFile = Join-Path $tempRoot "roundtrip/pipeline.log.jsonl"
            $cbFile = Join-Path $tempRoot "roundtrip/circuit_breakers.jsonl"
            Write-EventLog -Event "session_start" -TaskId "C-CULTURE-ROUNDTRIP" -Phase "verification" -LogFile $logFile -CircuitBreakerHistoryFile $cbFile
            $entry = (Get-Content -LiteralPath $logFile -Encoding UTF8 -Tail 1) | ConvertFrom-Json

            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo("en-US")
            $parsed = ConvertFrom-IsoTimestamp -Value $entry.timestamp
            $roundTripped = $parsed.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture)
            # PowerShell 7's ConvertFrom-Json turns the ISO string back into a [DateTime]
            # where 5.1 leaves it a string, so compare normalized forms rather than the raw
            # field, which would otherwise stringify culture-formatted on 7 only.
            $onTheWire = Get-IsoTimestamp $entry.timestamp
            Assert-Result -Name "fi-FI event timestamp parses under en-US" -Condition ($roundTripped -eq $onTheWire) -FailureMessage ("parsed " + $roundTripped + " from " + $onTheWire)
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture
        }
    }

    $results += Run-Test -Name "Get-IsoTimestamp normalizes DateTime and string equally" -Body {
        $iso = "2026-08-30T01:59:51Z"
        $dt = [DateTime]::ParseExact(
            $iso,
            "yyyy-MM-ddTHH:mm:ssZ",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        )

        $fromDateTime = Get-IsoTimestamp $dt
        $fromString = Get-IsoTimestamp $iso
        Assert-Result -Name "Get-IsoTimestamp DateTime equals string" -Condition ($fromDateTime -eq $fromString -and $fromString -eq $iso) -FailureMessage ("DateTime=" + $fromDateTime + " string=" + $fromString)
    }

    $results += Run-Test -Name "New handoff filename emitter uses Gregorian year under th-TH" -Body {
        $taskId = "F-910"
        $projectRoot = New-HandoffEmitterProject -Root $tempRoot -TaskId $taskId
        $result = Invoke-NewHandoffUnderCulture -ProjectRoot $projectRoot -TaskId $taskId -CultureName "th-TH"
        Assert-Result -Name "th-TH handoff emitter exits zero" -Condition ($result.ExitCode -eq 0) -FailureMessage ("exit=" + $result.ExitCode + " output=" + ($result.Output -join "`n"))

        $handoffFile = @(Get-ChildItem -Path (Join-Path $projectRoot ".crucible/session/handoffs") -Filter "$taskId-*.json")[0]
        Assert-Result -Name "th-TH handoff filename shape is UTC file timestamp" -Condition ($handoffFile.Name -match "^$taskId-[0-9]{8}T[0-9]{6}Z\.json$") -FailureMessage ("filename was " + $handoffFile.Name)
        $year = [int]$handoffFile.Name.Substring($taskId.Length + 1, 4)
        Assert-Result -Name "th-TH handoff filename year is Gregorian" -Condition ($year -eq [DateTime]::UtcNow.Year) -FailureMessage ("filename was " + $handoffFile.Name)
    }

    $results += Run-Test -Name "New handoff filename emitter uses Gregorian year under ar-SA" -Body {
        $taskId = "F-911"
        $projectRoot = New-HandoffEmitterProject -Root $tempRoot -TaskId $taskId
        $result = Invoke-NewHandoffUnderCulture -ProjectRoot $projectRoot -TaskId $taskId -CultureName "ar-SA"
        Assert-Result -Name "ar-SA handoff emitter exits zero" -Condition ($result.ExitCode -eq 0) -FailureMessage ("exit=" + $result.ExitCode + " output=" + ($result.Output -join "`n"))

        $handoffFile = @(Get-ChildItem -Path (Join-Path $projectRoot ".crucible/session/handoffs") -Filter "$taskId-*.json")[0]
        Assert-Result -Name "ar-SA handoff filename shape is UTC file timestamp" -Condition ($handoffFile.Name -match "^$taskId-[0-9]{8}T[0-9]{6}Z\.json$") -FailureMessage ("filename was " + $handoffFile.Name)
        $year = [int]$handoffFile.Name.Substring($taskId.Length + 1, 4)
        Assert-Result -Name "ar-SA handoff filename year is Gregorian" -Condition ($year -eq [DateTime]::UtcNow.Year) -FailureMessage ("filename was " + $handoffFile.Name)
    }

    $results += Run-Test -Name "Handoff filename written under th-TH parses to same UTC second" -Body {
        $taskId = "F-912"
        $projectRoot = New-HandoffEmitterProject -Root $tempRoot -TaskId $taskId
        $result = Invoke-NewHandoffUnderCulture -ProjectRoot $projectRoot -TaskId $taskId -CultureName "th-TH"
        Assert-Result -Name "th-TH handoff round trip emitter exits zero" -Condition ($result.ExitCode -eq 0) -FailureMessage ("exit=" + $result.ExitCode + " output=" + ($result.Output -join "`n"))

        $handoffFile = @(Get-ChildItem -Path (Join-Path $projectRoot ".crucible/session/handoffs") -Filter "$taskId-*.json")[0]
        $stamp = $handoffFile.Name.Substring($taskId.Length + 1, 16)
        $expected = [datetime]::ParseExact(
            $stamp,
            "yyyyMMddTHHmmssZ",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        ).ToUniversalTime()
        $parsed = Get-HandoffTimestampFromFileName -Name $handoffFile.Name
        Assert-Result -Name "th-TH handoff filename round trips through parser" -Condition ($parsed -eq $expected) -FailureMessage ("parsed " + $parsed.ToString("o") + " expected " + $expected.ToString("o") + " from " + $handoffFile.Name)
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed culture timestamp test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll culture timestamp tests passed." -ForegroundColor Green
exit 0
