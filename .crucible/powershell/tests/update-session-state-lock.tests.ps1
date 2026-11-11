# Tests for update-session-state.ps1's lock and its first write. The writer holds the shared
# exclusive-handle lock (I5) for the whole update: a live holder is waited out however old its
# lock file looks, a dead holder's lock is taken at once, and contending writers both persist.
# Item 263; the first-write cases are item 234 (I10).

$ErrorActionPreference = "Stop"

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
Set-StrictMode -Version Latest

$scriptUnderTest = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) "update-session-state.ps1"
if (-not (Test-Path -LiteralPath $scriptUnderTest)) {
    throw "Missing script under test: $scriptUnderTest"
}

$tempRoot = New-TestFixtureRoot -NameHint "stale-lock-test"

$LockFile = Join-Path $tempRoot ".crucible/session/global/session_state.lock"
$StateFile = Join-Path $tempRoot ".crucible/session/global/session_state.json"
$StateBackup = Join-Path $tempRoot ".crucible/session/global/session_state.c223-test-backup.json"
$TaskId = "{task_id}"

# Ensure lock directory exists
New-Item -ItemType Directory -Path (Split-Path -Parent $LockFile) -Force | Out-Null

function Backup-State {
    if (Test-Path -LiteralPath $StateFile) {
        Copy-Item -LiteralPath $StateFile -Destination $StateBackup -Force
    }
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
}

function Restore-State {
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $StateBackup) {
        Move-Item -LiteralPath $StateBackup -Destination $StateFile -Force
    }
}

# Its own root rather than $tempRoot: $tempRoot is the ProjectRoot handed to the script under test,
# and a stray json inside it would be a file the subject can see.
$payloadFile = Join-Path (New-TestFixtureRoot -NameHint "stale-lock-payload") "update.json"
'{"status":"locktest"}' | Out-File -LiteralPath $payloadFile -Encoding UTF8

function Invoke-ScriptUnderTest {
    $commandArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $scriptUnderTest,
        "-Specialist", "implementation",
        "-TaskId", $TaskId,
        "-UpdateJsonFile", $payloadFile,
        "-ProjectRoot", $tempRoot
    )
    # Wrap in try so a non-zero exit doesn't trip $ErrorActionPreference=Stop in the
    # parent harness. We assert exit codes explicitly in each test.
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = Invoke-ExternalCommand -AsLines { & (Get-PwshCommand) @commandArgs 2>&1 }
        $exit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevPref
    }
    # Explicitly stringify each element (WarningRecord, ErrorRecord, etc.)
    # so console-formatting artifacts don't leak into the joined text.
    $stringified = @($output | ForEach-Object { "$_" })
    return @{ Output = ($stringified -join "`n"); ExitCode = $exit }
}

$fileLockLib = Join-Path $REPO_ROOT "powershell/lib/file-lock.ps1"
$workDir = New-TestFixtureRoot -NameHint "state-lock-work"
$holderScript = Join-Path $workDir "holder.ps1"
[IO.File]::WriteAllText($holderScript, (@(
    'param([string]$FileLock, [string]$LockPath, [string]$AckPath, [string]$ReleasePath)',
    '$ErrorActionPreference = "Stop"',
    '. $FileLock',
    'Invoke-FileLock -LockPath $LockPath -ScriptBlock {',
    '    [System.IO.File]::WriteAllText($AckPath, "$PID")',
    '    while (-not (Test-Path -LiteralPath $ReleasePath)) { Start-Sleep -Milliseconds 50 }',
    '}'
) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
# The marker is written before the writer starts, so a wait measured from it covers the writer's
# whole attempt. Its output goes to a file, read after it exits.
$writerScript = Join-Path $workDir "writer.ps1"
[IO.File]::WriteAllText($writerScript, (@(
    'param([string]$Script, [string]$Root, [string]$TaskId, [string]$StartedPath, [string]$OutPath)',
    '[System.IO.File]::WriteAllText($StartedPath, "$PID")',
    '& $Script -Specialist implementation -TaskId $TaskId -UpdateJson ''{"status":"active"}'' -ProjectRoot $Root *> $OutPath',
    'exit $LASTEXITCODE'
) -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
$spawned = [Collections.Generic.List[object]]::new()
$fixtureRoots = [Collections.Generic.List[string]]::new()

function Get-StateLockPath { param([string]$Root) Join-Path $Root ".crucible/session/global/session_state.lock" }
function Get-StatePath { param([string]$Root) Join-Path $Root ".crucible/session/global/session_state.json" }

function Wait-ForPath {
    param([string]$Path, [int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while (-not (Test-Path -LiteralPath $Path) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    return (Test-Path -LiteralPath $Path)
}

function Start-StateLockHolder {
    param([string]$Root, [string]$Tag)
    $holder = [pscustomobject]@{
        Ack = Join-Path $workDir "$Tag.ack"; Release = Join-Path $workDir "$Tag.release"; Process = $null
    }
    $holder.Process = Start-HiddenHostProcess -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$holderScript`"", "-FileLock", "`"$fileLockLib`"", "-LockPath", "`"$(Get-StateLockPath $Root)`"", "-AckPath", "`"$($holder.Ack)`"", "-ReleasePath", "`"$($holder.Release)`"")
    $null = $holder.Process.Handle
    $spawned.Add($holder.Process)
    # Generous: pwsh startup alone can exceed 5s on a loaded parallel run.
    if (-not (Wait-ForPath -Path $holder.Ack -Seconds 60)) { throw "the lock holder $Tag did not acknowledge within 60 seconds" }
    return $holder
}

function Start-StateWriter {
    param([string]$Root, [string]$TaskId)
    $writer = [pscustomobject]@{
        Started = Join-Path $workDir "$TaskId.started"; Out = Join-Path $workDir "$TaskId.out"; Process = $null
    }
    $writer.Process = Start-HiddenHostProcess -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$writerScript`"", "-Script", "`"$scriptUnderTest`"", "-Root", "`"$Root`"", "-TaskId", $TaskId, "-StartedPath", "`"$($writer.Started)`"", "-OutPath", "`"$($writer.Out)`"")
    $null = $writer.Process.Handle
    $spawned.Add($writer.Process)
    if (-not (Wait-ForPath -Path $writer.Started -Seconds 60)) { throw "the writer for $TaskId did not start within 60 seconds" }
    return $writer
}

function Get-WriterOutput {
    param($Writer)
    if (-not (Test-Path -LiteralPath $Writer.Out)) { return "" }
    # A writer still running holds its output file open for writing.
    $stream = [IO.File]::Open($Writer.Out, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { return ([IO.StreamReader]::new($stream)).ReadToEnd() } finally { $stream.Dispose() }
}

function Get-StateTaskIds {
    param([string]$Root)
    $path = Get-StatePath $Root
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    return @($state.tasks.PSObject.Properties | ForEach-Object { $_.Name })
}

# Longer than the old writer's five-second lock timeout, so a writer that refused or stole the
# lock has exited by the end of it.
$LiveHolderWaitMs = 10000

$results = @()

function Assert-True {
    param([string]$Name, [bool]$Cond, [string]$Detail)
    if ($Cond) {
        Write-Host "PASS: $Name" -ForegroundColor Green
        $script:results += $true
    } else {
        Write-Host "FAIL: $Name -- $Detail" -ForegroundColor Red
        $script:results += $false
    }
}

Backup-State
try {
    # A successful in-process invocation must define its status under strict mode.
    foreach ($initialStatus in @('unset', 'stale')) {
        $caller = Join-Path $tempRoot "strict-success-$initialStatus.ps1"
        $initialization = if ($initialStatus -eq 'unset') {
            'Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue'
        } else { '$global:LASTEXITCODE = 7' }
        $callerBody = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
$initialization
& '$($scriptUnderTest.Replace("'", "''"))' -Specialist implementation -TaskId F-261 -UpdateJson '{"status":"active"}' -ProjectRoot '$($tempRoot.Replace("'", "''"))'
if (`$LASTEXITCODE -ne 0) { throw "Unexpected update exit: `$LASTEXITCODE" }
Write-Host 'CALLER_CONTINUED'
"@
        [IO.File]::WriteAllText($caller, $callerBody.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
        $shell = Get-PwshCommand
        $r = Invoke-ExternalCommand { & $shell -NoProfile -File $caller 2>&1 }
        Assert-True -Name "strict caller continues after success ($initialStatus status)" -Cond ($r.ExitCode -eq 0 -and $r.Output -match 'CALLER_CONTINUED') -Detail ("exit=" + $r.ExitCode + " :: " + $r.Output)
        $saved = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        Assert-True -Name "strict caller persisted update ($initialStatus status)" -Cond ($saved.tasks.'F-261'.phases.implementation.status -eq 'active') -Detail 'successful update must be written'
    }

    # Item 263: the writer deleted any lock file older than two minutes without asking whether
    # its holder was alive, so a slow writer lost its lock to a waiter.
    Write-Host "`nTest 1: A live holder keeps the lock however old its file looks" -ForegroundColor Cyan
    $root = New-TestFixtureRoot -NameHint "state-lock-aged"; $fixtureRoots.Add($root)
    $lock = Get-StateLockPath $root
    New-Item -ItemType Directory -Path (Split-Path -Parent $lock) -Force | Out-Null
    [IO.File]::WriteAllText((Get-StatePath $root), '{"tasks":{"F-OLD":{"phases":{"implementation":{"status":"active"}}}}}', [Text.UTF8Encoding]::new($false))
    $holder = Start-StateLockHolder -Root $root -Tag "aged"
    # Make the held lock look abandoned by age. A refused timestamp change would itself be the
    # guarantee; either way the writer must wait.
    try { (Get-Item -LiteralPath $lock).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-10) } catch {}
    $writer = Start-StateWriter -Root $root -TaskId "F-263"
    $exitedEarly = $writer.Process.WaitForExit($LiveHolderWaitMs)
    $earlyDetail = if ($exitedEarly) { "writer exited " + $writer.Process.ExitCode + ": " + (Get-WriterOutput $writer) } else { "" }
    Assert-True -Name "aged: the writer waits while the holder lives" -Cond (-not $exitedEarly) -Detail $earlyDetail
    Assert-True -Name "aged: nothing is written under a live holder" -Cond ((Get-StateTaskIds $root) -notcontains "F-263") -Detail ((Get-StateTaskIds $root) -join ",")
    Assert-True -Name "aged: the holder's lock path survives" -Cond (Test-Path -LiteralPath $lock) -Detail "the live holder's lock path was removed"
    [IO.File]::WriteAllText($holder.Release, "release")
    $holderDone = $holder.Process.WaitForExit(60000)
    $writerDone = $writer.Process.WaitForExit(60000)
    $writerOutput = Get-WriterOutput $writer
    Assert-True -Name "aged: holder and writer both finish" -Cond ($holderDone -and $writerDone) -Detail ("holder=" + $holderDone + " writer=" + $writerDone)
    Assert-True -Name "aged: the writer succeeds after the release" -Cond ($writerDone -and $writer.Process.ExitCode -eq 0) -Detail $writerOutput
    Assert-True -Name "aged: the writer reported its wait" -Cond ($writerOutput.Contains("[SESSION STATE] Waiting")) -Detail $writerOutput
    $ids = @(Get-StateTaskIds $root)
    Assert-True -Name "aged: the existing task and the new one persist" -Cond ($ids -contains "F-OLD" -and $ids -contains "F-263") -Detail ($ids -join ",")
    Assert-True -Name "aged: the lock is released" -Cond (-not (Test-Path -LiteralPath $lock)) -Detail "lock still present"

    # Two writers queue behind an acknowledged holder, so both contend for the same lock, and the
    # state file is missing, so the first write is the item 234 shape (I10) under contention.
    Write-Host "`nTest 2: Two queued writers both persist from a missing state file" -ForegroundColor Cyan
    $root = New-TestFixtureRoot -NameHint "state-lock-pair"; $fixtureRoots.Add($root)
    $lock = Get-StateLockPath $root
    New-Item -ItemType Directory -Path (Split-Path -Parent $lock) -Force | Out-Null
    $holder = Start-StateLockHolder -Root $root -Tag "pair"
    $first = Start-StateWriter -Root $root -TaskId "F-901"
    $second = Start-StateWriter -Root $root -TaskId "F-902"
    $exitedEarly = $first.Process.WaitForExit($LiveHolderWaitMs) -or $second.Process.HasExited
    Assert-True -Name "pair: both writers wait while the holder lives" -Cond (-not $exitedEarly) -Detail ((Get-WriterOutput $first) + " | " + (Get-WriterOutput $second))
    Assert-True -Name "pair: no state file is written under a live holder" -Cond (-not (Test-Path -LiteralPath (Get-StatePath $root))) -Detail "state file written while the lock was held"
    [IO.File]::WriteAllText($holder.Release, "release")
    $done = $holder.Process.WaitForExit(60000) -and $first.Process.WaitForExit(60000) -and $second.Process.WaitForExit(60000)
    Assert-True -Name "pair: holder and writers finish" -Cond $done -Detail "a process did not finish within 60 seconds"
    Assert-True -Name "pair: both writers succeed" -Cond ($done -and $first.Process.ExitCode -eq 0 -and $second.Process.ExitCode -eq 0) -Detail ((Get-WriterOutput $first) + " | " + (Get-WriterOutput $second))
    $ids = @(Get-StateTaskIds $root)
    Assert-True -Name "pair: both registrations persist" -Cond ($ids -contains "F-901" -and $ids -contains "F-902") -Detail ($ids -join ",")
    Assert-True -Name "pair: the lock is released" -Cond (-not (Test-Path -LiteralPath $lock)) -Detail "lock still present"

    # A holder killed inside its lock: the OS closes its handle, which frees the lock; on Unix the
    # pathname can remain, and a file without an open handle holds no lock.
    Write-Host "`nTest 3: A dead holder's lock is taken at once" -ForegroundColor Cyan
    $root = New-TestFixtureRoot -NameHint "state-lock-dead"; $fixtureRoots.Add($root)
    $lock = Get-StateLockPath $root
    New-Item -ItemType Directory -Path (Split-Path -Parent $lock) -Force | Out-Null
    $holder = Start-StateLockHolder -Root $root -Tag "dead"
    Stop-Process -Id $holder.Process.Id -Force
    $null = $holder.Process.WaitForExit(60000)
    $writer = Start-StateWriter -Root $root -TaskId "F-264"
    $writerDone = $writer.Process.WaitForExit(30000)
    $writerOutput = Get-WriterOutput $writer
    Assert-True -Name "dead: the writer succeeds" -Cond ($writerDone -and $writer.Process.ExitCode -eq 0) -Detail ("done=" + $writerDone + " :: " + $writerOutput)
    Assert-True -Name "dead: the writer did not wait" -Cond (-not $writerOutput.Contains("[SESSION STATE] Waiting")) -Detail $writerOutput
    Assert-True -Name "dead: the registration persists" -Cond ((Get-StateTaskIds $root) -contains "F-264") -Detail ((Get-StateTaskIds $root) -join ",")
    Assert-True -Name "dead: the lock is released" -Cond (-not (Test-Path -LiteralPath $lock)) -Detail "lock still present"

    # A lock file left by a writer that died before item 263, fresh or old, has no open handle:
    # it is taken at once, with no age judgement and no timeout.
    foreach ($age in @("fresh", "aged")) {
        Write-Host "`nTest 4 ($age): An orphaned lock file is taken without a timeout or removal warning" -ForegroundColor Cyan
        Set-Content -LiteralPath $LockFile -Value "999999" -Encoding UTF8
        if ($age -eq "aged") { (Get-Item -LiteralPath $LockFile).LastWriteTime = (Get-Date).AddMinutes(-5) }
        $r = Invoke-ScriptUnderTest
        Assert-True -Name "$age orphan: exit code 0" -Cond ($r.ExitCode -eq 0) -Detail ("got " + $r.ExitCode + " :: " + $r.Output)
        Assert-True -Name "$age orphan: no stale-lock removal" -Cond ($r.Output -notmatch "Auto-removing|\[WARN\] Stale") -Detail $r.Output
        Assert-True -Name "$age orphan: no wait" -Cond (-not $r.Output.Contains("[SESSION STATE] Waiting")) -Detail $r.Output
        Assert-True -Name "$age orphan: lock released after success" -Cond (-not (Test-Path -LiteralPath $LockFile)) -Detail "lock still present"
    }

    Write-Host "`nTest 5: Normal acquisition (no lock present)" -ForegroundColor Cyan
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    $r3 = Invoke-ScriptUnderTest
    Assert-True -Name "exit code 0 with no contention" -Cond ($r3.ExitCode -eq 0) -Detail ("got " + $r3.ExitCode + " :: " + $r3.Output)
    Assert-True -Name "no warning when lock absent" -Cond ($r3.Output -notmatch "\[WARN\] Stale lock") -Detail $r3.Output

    # Item 234: the first write to a missing state file used to report success and store
    # nothing, so the affinity check could not see the task it should conflict with.
    foreach ($seed in @("missing", "existing")) {
        Write-Host "`nTest 6 ($seed state file): registrations survive and conflict" -ForegroundColor Cyan
        $root = New-TestFixtureRoot -NameHint "state-first-write-$seed"
        $state = Join-Path $root ".crucible/session/global/session_state.json"
        New-Item -ItemType Directory -Path (Split-Path -Parent $state) -Force | Out-Null
        if ($seed -eq "existing") { [IO.File]::WriteAllText($state, '{"tasks":{}}', [Text.UTF8Encoding]::new($false)) }
        $shell = Get-PwshCommand
        $register = {
            param($Id)
            Invoke-ExternalCommand -AsLines { & $shell -NoProfile -ExecutionPolicy Bypass -File $scriptUnderTest -Specialist implementation -TaskId $Id -UpdateJson '{"status":"active","file_affinity":["internal/app/"]}' -ProjectRoot $root 2>&1 } | Out-Null
            return $LASTEXITCODE
        }
        $e1 = Invoke-ExternalCommand -AsLines { & $register "F-901" }
        $afterFirst = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
        Assert-True -Name "$seed : first write exits 0" -Cond ($e1 -eq 0) -Detail ("got " + $e1)
        Assert-True -Name "$seed : first write is stored" -Cond ($null -ne $afterFirst.tasks.PSObject.Properties["F-901"] -and $afterFirst.tasks."F-901".phases.implementation.status -eq "active") -Detail (Get-Content -LiteralPath $state -Raw)
        $conflict = Invoke-ExternalCommand -AsLines { & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Split-Path -Parent $scriptUnderTest) "check-file-affinity.ps1") -TaskId "F-902" -Affinity "internal/app/" -ProjectRoot $root 2>&1 }
        Assert-True -Name "$seed : overlapping task is refused" -Cond ($LASTEXITCODE -eq 1) -Detail ("got " + $LASTEXITCODE + " :: " + ($conflict -join " "))
        $e2 = Invoke-ExternalCommand -AsLines { & $register "F-902" }
        $afterSecond = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
        Assert-True -Name "$seed : second task keeps the first" -Cond ($e2 -eq 0 -and $null -ne $afterSecond.tasks.PSObject.Properties["F-901"] -and $null -ne $afterSecond.tasks.PSObject.Properties["F-902"]) -Detail (Get-Content -LiteralPath $state -Raw)
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
finally {
    foreach ($process in $spawned) { if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } }
    foreach ($fixture in @($fixtureRoots) + @($workDir)) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
    Restore-State
    Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

$failed = $results -contains $false
if ($failed) {
    Write-Host "`nSOME TESTS FAILED ($($results.Count) total)" -ForegroundColor Red
    exit 1
}
Write-Host "`nALL TESTS PASSED ($($results.Count) total)" -ForegroundColor Green
exit 0
