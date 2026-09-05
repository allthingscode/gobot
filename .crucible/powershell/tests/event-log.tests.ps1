# Tests for the shared event log helper.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$FACTORY_LIB = Join-Path $REPO_ROOT "powershell/factory-lib.ps1"
$HELPER = Join-Path $REPO_ROOT "powershell/lib/event-log.ps1"
$Quiet = $true
. $FACTORY_LIB
. $HELPER

$results = @()







$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-event-log-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Invoke-FileLock does not admit a waiter while a slow holder is still in its critical section" -Body {
        $lockPath = Join-Path $tempRoot "slow-holder/shared.lock"
        $eventsPath = Join-Path $tempRoot "slow-holder/events.txt"
        $workerPath = Join-Path $tempRoot "slow-holder/lock-worker.ps1"
        New-Item -ItemType Directory -Path (Split-Path -Parent $lockPath) -Force | Out-Null

        $worker = @'
param(
    [string]$FactoryLib,
    [string]$LockPath,
    [string]$EventsPath,
    [string]$Name,
    [int]$HoldMs
)

$ErrorActionPreference = "Stop"
$Quiet = $true
. $FactoryLib

Invoke-FileLock -LockPath $LockPath -TimeoutMs 200 -ScriptBlock {
    [System.IO.File]::AppendAllText($EventsPath, $Name + "-enter`n", [System.Text.UTF8Encoding]::new($false))
    Start-Sleep -Milliseconds $HoldMs
    [System.IO.File]::AppendAllText($EventsPath, $Name + "-exit`n", [System.Text.UTF8Encoding]::new($false))
}
'@
        [System.IO.File]::WriteAllText($workerPath, $worker, [System.Text.UTF8Encoding]::new($false))

        $shell = (Get-Process -Id $PID).Path
        $startWorker = {
            param([string]$Name, [int]$HoldMs)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $shell
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$workerPath`" -FactoryLib `"$FACTORY_LIB`" -LockPath `"$lockPath`" -EventsPath `"$eventsPath`" -Name $Name -HoldMs $HoldMs"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi
            [void]$process.Start()
            return $process
        }

        $holder = & $startWorker "holder" 1400
        $deadline = (Get-Date).AddSeconds(5)
        while ((-not (Test-Path -LiteralPath $eventsPath)) -and ((Get-Date) -lt $deadline)) {
            Start-Sleep -Milliseconds 25
        }
        Assert-Result -Name "holder entered critical section" -Condition (Test-Path -LiteralPath $eventsPath) -FailureMessage "holder did not enter within five seconds"

        $waiter = & $startWorker "waiter" 100
        $holder.WaitForExit()
        $waiter.WaitForExit()
        $holderOutput = $holder.StandardOutput.ReadToEnd() + $holder.StandardError.ReadToEnd()
        $waiterOutput = $waiter.StandardOutput.ReadToEnd() + $waiter.StandardError.ReadToEnd()
        Assert-Result -Name "holder worker exits successfully" -Condition ($holder.ExitCode -eq 0) -FailureMessage $holderOutput
        Assert-Result -Name "waiter worker exits successfully" -Condition ($waiter.ExitCode -eq 0) -FailureMessage $waiterOutput

        $events = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8)
        $holderExit = [array]::IndexOf($events, "holder-exit")
        $waiterEnter = [array]::IndexOf($events, "waiter-enter")
        Assert-Result -Name "waiter enters only after the slow holder exits" -Condition (($holderExit -ge 0) -and ($waiterEnter -gt $holderExit)) -FailureMessage ("events: " + ($events -join ", "))
    }

    $results += Run-Test -Name "Invoke-FileLock recovers an orphaned legacy lock pathname" -Body {
        $lockPath = Join-Path $tempRoot "orphaned-lock/legacy.lock"
        New-Item -ItemType Directory -Path (Split-Path -Parent $lockPath) -Force | Out-Null
        [System.IO.File]::WriteAllText($lockPath, "orphaned by a crashed pre-handle holder", [System.Text.UTF8Encoding]::new($false))
        $script:orphanedLockRecovered = $false

        Invoke-FileLock -LockPath $lockPath -TimeoutMs 200 -ScriptBlock {
            $script:orphanedLockRecovered = $true
        }

        Assert-Result -Name "orphaned lock admits a new holder" -Condition $script:orphanedLockRecovered -FailureMessage "orphaned lock was not recovered"
        Assert-Result -Name "orphaned lock pathname is removed on close" -Condition (-not (Test-Path -LiteralPath $lockPath)) -FailureMessage "orphaned lock pathname remained after the holder closed"
    }

    $results += Run-Test -Name "Write-EventLog appends JSON line and creates parent directory" -Body {
        $logFile = Join-Path $tempRoot "nested/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $tempRoot "global/circuit_breakers.jsonl"

        Write-EventLog -Event "session_start" -TaskId "F-001" -Phase "implementation" -Outcome "started" -Notes "hello" -LogFile $logFile -CircuitBreakerHistoryFile $cbHistoryFile

        Assert-Result -Name "log exists" -Condition (Test-Path -LiteralPath $logFile) -FailureMessage "log file was not created"
        $lines = @(Get-Content -LiteralPath $logFile -Encoding UTF8)
        Assert-Result -Name "single line" -Condition ($lines.Count -eq 1) -FailureMessage "expected one JSONL entry"
        $entry = $lines[0] | ConvertFrom-Json
        Assert-Result -Name "event" -Condition ($entry.event -eq "session_start") -FailureMessage "event changed"
        Assert-Result -Name "task id" -Condition ($entry.task_id -eq "F-001") -FailureMessage "task id changed"
        Assert-Result -Name "phase" -Condition ($entry.phase -eq "implementation") -FailureMessage "phase changed"
        Assert-Result -Name "outcome" -Condition ($entry.outcome -eq "started") -FailureMessage "outcome missing"
        Assert-Result -Name "notes" -Condition ($entry.notes -eq "hello") -FailureMessage "notes missing"
    }

    $results += Run-Test -Name "Circuit breaker event also appends history file" -Body {
        $logFile = Join-Path $tempRoot "task/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $tempRoot "global/circuit_breakers.jsonl"

        Write-EventLog -Event "circuit_breaker" -TaskId "F-002" -Phase "factory" -Outcome "blocked" -LogFile $logFile -CircuitBreakerHistoryFile $cbHistoryFile

        Assert-Result -Name "history exists" -Condition (Test-Path -LiteralPath $cbHistoryFile) -FailureMessage "circuit breaker history was not created"
        $entry = (Get-Content -LiteralPath $cbHistoryFile -Encoding UTF8 -Tail 1) | ConvertFrom-Json
        Assert-Result -Name "history event" -Condition ($entry.event -eq "circuit_breaker") -FailureMessage "history event changed"
        Assert-Result -Name "history task" -Condition ($entry.task_id -eq "F-002") -FailureMessage "history task id changed"
    }

    $results += Run-Test -Name "Write-EventLog emits kind when supplied" -Body {
        $logFile = Join-Path $tempRoot "kind/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $tempRoot "kind/circuit_breakers.jsonl"

        Write-EventLog -Event "degraded" -TaskId "F-003" -Phase "factory" -Outcome "warned" -Kind "task_checklist" -LogFile $logFile -CircuitBreakerHistoryFile $cbHistoryFile

        $entry = (Get-Content -LiteralPath $logFile -Encoding UTF8 -Tail 1) | ConvertFrom-Json
        Assert-Result -Name "kind property emitted" -Condition ($entry.PSObject.Properties["kind"] -and $entry.kind -eq "task_checklist") -FailureMessage "kind field was not emitted with expected value"
    }

    $results += Run-Test -Name "Write-EventLog omits kind when not supplied" -Body {
        $logFile = Join-Path $tempRoot "no-kind/pipeline.log.jsonl"
        $cbHistoryFile = Join-Path $tempRoot "no-kind/circuit_breakers.jsonl"

        Write-EventLog -Event "session_start" -TaskId "F-003" -Phase "factory" -Outcome "started" -LogFile $logFile -CircuitBreakerHistoryFile $cbHistoryFile

        $entry = (Get-Content -LiteralPath $logFile -Encoding UTF8 -Tail 1) | ConvertFrom-Json
        Assert-Result -Name "kind property absent" -Condition (-not $entry.PSObject.Properties["kind"]) -FailureMessage "kind field should be absent when omitted"
    }

    # The destination must come from the argument, never from the caller's frame. These
    # two tests are the regression proof for the whole item: -LogFile used to default to
    # $LOG_FILE, a name resolved at call time against the dynamic scope chain, so an
    # omitted argument silently picked up an ancestor's log and a supplied one was never
    # distinguishable from it. Restoring that default kills both.
    $results += Run-Test -Name "Write-EventLog refuses to guess a destination from an ancestor frame" -Body {
        $ambientLog = Join-Path $tempRoot "ambient/pipeline.log.jsonl"
        $ambientCb = Join-Path $tempRoot "ambient/circuit_breakers.jsonl"
        # Initialised before the call: without this, a mutation that makes the call
        # succeed fails on a StrictMode "variable has not been set" instead of on the
        # named assertion, and the mutation report attributes the kill to the wrong line.
        $script:__elThrew = $false
        $script:__elMessage = ""
        & {
            # Deliberately shadowing the historic ambient names in the calling frame.
            $LOG_FILE = $ambientLog
            $CB_HISTORY_FILE = $ambientCb
            try {
                Write-EventLog -Event "session_start" -TaskId "F-006" -Phase "implementation"
            } catch {
                $script:__elThrew = $true
                $script:__elMessage = $_.Exception.Message
            }
        }
        $threw = [bool]$script:__elThrew
        $message = [string]$script:__elMessage
        $script:__elThrew = $false
        $script:__elMessage = ""

        Assert-Result -Name "omitted destination throws" -Condition $threw -FailureMessage "Write-EventLog accepted a call with no -LogFile"
        Assert-Result -Name "omitted destination names the parameter" -Condition ($message -match "LogFile") -FailureMessage ("expected the binding error to name LogFile, got: " + $message)
        Assert-Result -Name "nothing was written to the ambient log" -Condition (-not (Test-Path -LiteralPath $ambientLog)) -FailureMessage ("Write-EventLog wrote to the ancestor frame's log at " + $ambientLog)
    }

    $results += Run-Test -Name "Write-EventLog writes to the supplied destination, not the ancestor frame's" -Body {
        $ambientLog = Join-Path $tempRoot "explicit-wins/ambient.log.jsonl"
        $ambientCb = Join-Path $tempRoot "explicit-wins/ambient-breakers.jsonl"
        $explicitLog = Join-Path $tempRoot "explicit-wins/explicit.log.jsonl"
        $explicitCb = Join-Path $tempRoot "explicit-wins/explicit-breakers.jsonl"

        & {
            $LOG_FILE = $ambientLog
            $CB_HISTORY_FILE = $ambientCb
            Write-EventLog -Event "circuit_breaker" -TaskId "F-007" -Phase "factory" -Outcome "blocked" `
                -LogFile $explicitLog -CircuitBreakerHistoryFile $explicitCb
        }

        Assert-Result -Name "explicit log received the event" -Condition (Test-Path -LiteralPath $explicitLog) -FailureMessage ("expected the event at " + $explicitLog)
        Assert-Result -Name "explicit breaker history received the event" -Condition (Test-Path -LiteralPath $explicitCb) -FailureMessage ("expected the breaker record at " + $explicitCb)
        Assert-Result -Name "ambient log stayed empty" -Condition (-not (Test-Path -LiteralPath $ambientLog)) -FailureMessage ("the ancestor frame's log was written at " + $ambientLog)
        Assert-Result -Name "ambient breaker history stayed empty" -Condition (-not (Test-Path -LiteralPath $ambientCb)) -FailureMessage ("the ancestor frame's breaker history was written at " + $ambientCb)
    }

    $results += Run-Test -Name "Get-LastEntry refuses to guess a log from an ancestor frame" -Body {
        $ambientLog = Join-Path $tempRoot "ambient-read/pipeline.log.jsonl"
        New-Item -ItemType Directory -Path (Split-Path -Parent $ambientLog) -Force | Out-Null
        (@{ event = "session_start"; task_id = "F-008"; phase = "implementation" } | ConvertTo-Json -Compress) |
            Set-Content -LiteralPath $ambientLog -Encoding UTF8
        $script:__glThrew = $false
        & {
            $LOG_FILE = $ambientLog
            try {
                Get-LastEntry -TaskId "F-008" -Phase "implementation" -Event "session_start" | Out-Null
            } catch {
                $script:__glThrew = $true
            }
        }
        $threw = [bool]$script:__glThrew
        $script:__glThrew = $false
        Assert-Result -Name "omitted log throws" -Condition $threw -FailureMessage "Get-LastEntry read an ancestor frame's log instead of requiring -LogFile"
    }

    $results += Run-Test -Name "Get-LastEntry returns null when log is missing" -Body {
        $missingLog = Join-Path $tempRoot "missing/pipeline.log.jsonl"
        $entry = Get-LastEntry -TaskId "F-003" -Phase "verification" -Event "session_start" -LogFile $missingLog
        Assert-Result -Name "null result" -Condition ($null -eq $entry) -FailureMessage "missing log should return null"
    }

    $results += Run-Test -Name "Get-LastEntry finds latest matching event" -Body {
        $logFile = Join-Path $tempRoot "lookup/pipeline.log.jsonl"
        New-Item -ItemType Directory -Path (Split-Path -Parent $logFile) -Force | Out-Null
        @(
            (@{ event = "session_start"; task_id = "F-004"; phase = "implementation"; marker = "old" } | ConvertTo-Json -Compress),
            (@{ event = "session_end"; task_id = "F-004"; phase = "implementation"; marker = "wrong event" } | ConvertTo-Json -Compress),
            (@{ event = "session_start"; task_id = "F-004"; phase = "implementation"; marker = "new" } | ConvertTo-Json -Compress)
        ) | Set-Content -LiteralPath $logFile -Encoding UTF8

        $entry = Get-LastEntry -TaskId "F-004" -Phase "implementation" -Event "session_start" -LogFile $logFile
        Assert-Result -Name "entry found" -Condition ($null -ne $entry) -FailureMessage "matching entry was not found"
        Assert-Result -Name "latest marker" -Condition ($entry.marker -eq "new") -FailureMessage "did not return latest matching entry"
    }

    $results += Run-Test -Name "Get-LastEntry accepts legacy specialist field" -Body {
        $logFile = Join-Path $tempRoot "legacy/pipeline.log.jsonl"
        New-Item -ItemType Directory -Path (Split-Path -Parent $logFile) -Force | Out-Null
        @(
            (@{ event = "session_start"; task_id = "F-000"; specialist = "grooming"; marker = "other" } | ConvertTo-Json -Compress),
            (@{ event = "session_start"; task_id = "F-005"; specialist = "grooming"; marker = "legacy" } | ConvertTo-Json -Compress)
        ) | Set-Content -LiteralPath $logFile -Encoding UTF8

        $entry = Get-LastEntry -TaskId "F-005" -Phase "grooming" -Event "session_start" -LogFile $logFile
        Assert-Result -Name "legacy found" -Condition ($null -ne $entry) -FailureMessage "legacy specialist entry was not found"
        Assert-Result -Name "legacy marker" -Condition ($entry.marker -eq "legacy") -FailureMessage "legacy entry changed"
    }

    $results += Run-Test -Name "the legacy factory phase value canonicalises to crucible" -Body {
        Assert-Result -Name "legacy value maps" -Condition ((ConvertTo-CanonicalPhase "factory") -eq "crucible") -FailureMessage "ConvertTo-CanonicalPhase did not map the legacy value"
        Assert-Result -Name "canonical value is stable" -Condition ((ConvertTo-CanonicalPhase "crucible") -eq "crucible") -FailureMessage "ConvertTo-CanonicalPhase rewrote the canonical value"
        Assert-Result -Name "unrelated phase untouched" -Condition ((ConvertTo-CanonicalPhase "implementation") -eq "implementation") -FailureMessage "ConvertTo-CanonicalPhase rewrote an unrelated phase"
        Assert-Result -Name "null survives" -Condition ($null -eq (ConvertTo-CanonicalPhase $null)) -FailureMessage "ConvertTo-CanonicalPhase invented a value for a null phase"

        $legacyPhase = @{ event = "gate"; task_id = "F-100"; phase = "factory" } | ConvertTo-Json -Compress | ConvertFrom-Json
        $currentPhase = @{ event = "gate"; task_id = "F-100"; phase = "crucible" } | ConvertTo-Json -Compress | ConvertFrom-Json
        $legacyField = @{ event = "gate"; task_id = "F-100"; specialist = "factory" } | ConvertTo-Json -Compress | ConvertFrom-Json
        Assert-Result -Name "legacy value reads canonical" -Condition ((Get-EntryPhase $legacyPhase) -eq "crucible") -FailureMessage "Get-EntryPhase returned the legacy value"
        Assert-Result -Name "current value reads canonical" -Condition ((Get-EntryPhase $currentPhase) -eq "crucible") -FailureMessage "Get-EntryPhase altered a current entry"
        Assert-Result -Name "legacy field reads canonical" -Condition ((Get-EntryPhase $legacyField) -eq "crucible") -FailureMessage "Get-EntryPhase did not canonicalise the legacy specialist field"
    }

    $results += Run-Test -Name "Get-LastEntry matches a legacy factory entry when asked for crucible" -Body {
        $logFile = Join-Path $tempRoot "phase-rename/pipeline.log.jsonl"
        New-Item -ItemType Directory -Path (Split-Path -Parent $logFile) -Force | Out-Null
        @(
            (@{ event = "session_start"; task_id = "F-006"; phase = "factory"; marker = "legacy" } | ConvertTo-Json -Compress)
        ) | Set-Content -LiteralPath $logFile -Encoding UTF8

        $byCanonical = Get-LastEntry -TaskId "F-006" -Phase "crucible" -Event "session_start" -LogFile $logFile
        Assert-Result -Name "found by canonical name" -Condition ($null -ne $byCanonical -and $byCanonical.marker -eq "legacy") -FailureMessage "a legacy factory entry was invisible to a crucible query"

        $byLegacy = Get-LastEntry -TaskId "F-006" -Phase "factory" -Event "session_start" -LogFile $logFile
        Assert-Result -Name "found by legacy name" -Condition ($null -ne $byLegacy -and $byLegacy.marker -eq "legacy") -FailureMessage "a legacy factory entry was invisible to a factory query"
    }

    $results += Run-Test -Name "no production emit site writes the legacy factory phase value" -Body {
        # Readers accept both values permanently, which is exactly what would let a
        # re-introduced emit site sit unnoticed: reports keep looking right while the
        # written data drifts back to the old name.
        $productionFiles = @(Get-ChildItem -Path (Join-Path $REPO_ROOT "powershell") -Recurse -Filter *.ps1 |
            Where-Object { $_.FullName -notmatch "[\\/]tests[\\/]" })
        Assert-Result -Name "production scan is non-empty" -Condition ($productionFiles.Count -ge 20) -FailureMessage ("expected to scan the production scripts, found " + $productionFiles.Count)

        $offenders = @($productionFiles | Where-Object {
            (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match '-(?:Specialist|Phase)\s+"factory"'
        } | ForEach-Object { $_.Name })
        Assert-Result -Name "no legacy emit site" -Condition ($offenders.Count -eq 0) -FailureMessage ("these files still stamp the legacy phase value: " + ($offenders -join ", "))
    }

    $results += Run-Test -Name "every emitted degraded kind is in the policy taxonomy" -Body {
        # docs/policy.md 2.2 calls its table the known degraded kinds. Nothing compared
        # it to the code, so a kind could be emitted for months and never appear there -
        # and a reader consulting the taxonomy for an undocumented kind gets silence,
        # which reads as "no such signal exists" rather than "this doc is behind".
        $sourceText = (Get-ChildItem -Path (Join-Path $REPO_ROOT "powershell") -Recurse -Filter *.ps1 |
            Where-Object { $_.FullName -notmatch "[\\/]tests[\\/]" } |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
        $emittedKinds = @([regex]::Matches($sourceText, '-Kind\s+"([a-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        Assert-Result -Name "source scan finds emitted kinds" -Condition ($emittedKinds.Count -ge 5) -FailureMessage ("expected the source scan to find emitted -Kind literals, found " + $emittedKinds.Count)

        $policyText = Get-Content -LiteralPath (Join-Path $REPO_ROOT "docs/policy.md") -Raw -Encoding UTF8
        $documentedKinds = @([regex]::Matches($policyText, '(?m)^\|\s*`([a-z0-9_]+)`\s*\|\s*`(?:warned|unverifiable)`\s*\|') | ForEach-Object { $_.Groups[1].Value })
        Assert-Result -Name "policy taxonomy table parses" -Condition ($documentedKinds.Count -ge 5) -FailureMessage ("expected to parse the degraded-kind rows out of docs/policy.md, found " + $documentedKinds.Count)

        foreach ($kind in $emittedKinds) {
            Assert-Result -Name ("policy documents " + $kind) -Condition ($documentedKinds -contains $kind) -FailureMessage ("code emits degraded kind '" + $kind + "' but docs/policy.md 2.2 does not list it")
        }
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed event log test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll event log tests passed." -ForegroundColor Green
exit 0
