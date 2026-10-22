# Tests for Crucible gate orchestration helpers.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$CRUCIBLE_LIB = Join-Path $REPO_ROOT "powershell/crucible-lib.ps1"
$Quiet = $true
. $CRUCIBLE_LIB
$pwshCmd = Get-PwshCommand

$results = @()

function Write-TestHandoff {
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

function New-TestContext {
    param(
        [Parameter(Mandatory=$true)][string]$TempRoot,
        [string]$TaskId = "F-001"
    )

    $sessionDir = Join-Path $TempRoot "session"
    $handoffDir = Join-Path $sessionDir "handoffs"
    $backlogDir = Join-Path $TempRoot "backlog"
    $frameworkDir = Join-Path $TempRoot "powershell"
    New-Item -ItemType Directory -Path $handoffDir, $backlogDir, $frameworkDir -Force | Out-Null

    return @{
        RepoRoot = $TempRoot
        CrucibleRoot = ".crucible"
        FrameworkPowerShell = $frameworkDir
        SessionDir = $sessionDir
        BacklogDir = $backlogDir
        WorkspacesDir = Join-Path $TempRoot "workspaces"
        HandoffDir = $handoffDir
        PromptLib = Join-Path $TempRoot "prompts"
        LogFile = Join-Path $sessionDir "$TaskId/pipeline.log.jsonl"
        CircuitBreakerHistoryFile = Join-Path $sessionDir "global/circuit_breakers.jsonl"
        TaskId = $TaskId
        Target = "agent"
        Init = $true
        Recover = $false
        Quiet = $true
        AutoAdvance = $false
        GateOutcome = $null
        GateRedirectTarget = $null
        GateReason = $null
        BudgetCeilings = $null
        Ceiling = $null
        BudgetTierKey = ""
        InvalidBudgetTier = ""
        Handoff = $null
        LatestHandoff = $null
        RelativeHandoffPath = $null
        CumulativeHandoffCount = 0
        IsBootstrap = $false
        Transition = $null
        NextCrucibleCommand = $null
    }
}
$tempRoot = New-TestFixtureRoot -NameHint "crucible-gates-integrity-test"
try {
    $results += Run-Test -Name "Framework integrity guard flags framework-owned bundle edits only" -Body {
        $repo = Join-Path $tempRoot "framework-integrity"
        $crucible = Join-Path $repo ".crucible"
        New-Item -ItemType Directory -Path (Join-Path $crucible "powershell"), (Join-Path $crucible "session"), (Join-Path $crucible "backlog") -Force | Out-Null
        @'
{
  "adopter_owned_excludes": [
    "config.yaml",
    "backlog/**",
    "session/**",
    "research/**",
    ".gemini/**",
    ".private/**",
    ".agent-workspaces/**"
  ]
}
'@ | Set-Content -LiteralPath (Join-Path $crucible "install-manifest.json") -Encoding UTF8
        "version: 1" | Set-Content -LiteralPath (Join-Path $crucible "config.yaml") -Encoding UTF8
        "framework" | Set-Content -LiteralPath (Join-Path $crucible "powershell/crucible.ps1") -Encoding UTF8
        "state" | Set-Content -LiteralPath (Join-Path $crucible "session/state.txt") -Encoding UTF8

        git -C $repo init | Out-Null
        git -C $repo config user.email "test@example.com" | Out-Null
        git -C $repo config user.name "Test User" | Out-Null
        git -C $repo config core.autocrlf false | Out-Null
        git -C $repo config core.safecrlf false | Out-Null
        git -C $repo add . | Out-Null
        git -C $repo commit -m "baseline" | Out-Null
        $baseSha = (git -C $repo rev-parse HEAD).Trim()

        "changed config" | Set-Content -LiteralPath (Join-Path $crucible "config.yaml") -Encoding UTF8
        "changed state" | Set-Content -LiteralPath (Join-Path $crucible "session/state.txt") -Encoding UTF8

        $ctx = New-TestContext -TempRoot $repo -TaskId "F-020"
        $ctx.RepoRoot = $repo
        $ctx.CrucibleRoot = ".crucible"
        $ctx.Handoff = [pscustomobject]@{ task_id = "F-020"; base_commit = $baseSha }
        $excluded = @(Get-CrucibleFrameworkStatusChanges -Context $ctx)
        Assert-Result -Name "adopter changes excluded" -Condition ($excluded.Count -eq 0) -FailureMessage ("expected no framework changes, got: " + ($excluded -join ", "))

        "changed framework" | Set-Content -LiteralPath (Join-Path $crucible "powershell/crucible.ps1") -Encoding UTF8
        $flagged = @(Get-CrucibleFrameworkStatusChanges -Context $ctx)
        Assert-Result -Name "framework change flagged" -Condition (($flagged -join "`n") -match "\.crucible/powershell/crucible.ps1") -FailureMessage ("expected framework file to be flagged, got: " + ($flagged -join ", "))
    }

    function New-IntegrityRepo {
        param([Parameter(Mandatory=$true)][string]$Path)

        $crucible = Join-Path $Path ".crucible"
        New-Item -ItemType Directory -Path (Join-Path $crucible "powershell"), (Join-Path $crucible "backlog") -Force | Out-Null
        "framework" | Set-Content -LiteralPath (Join-Path $crucible "powershell/crucible.ps1") -Encoding UTF8
        "item" | Set-Content -LiteralPath (Join-Path $crucible "backlog/F-001.md") -Encoding UTF8
        git -C $Path init | Out-Null
        git -C $Path config user.email "test@example.com" | Out-Null
        git -C $Path config user.name "Test User" | Out-Null
        git -C $Path config core.autocrlf false | Out-Null
        git -C $Path config core.safecrlf false | Out-Null
        git -C $Path add . | Out-Null
        git -C $Path commit -m "baseline" | Out-Null
        return (git -C $Path rev-parse HEAD).Trim()
    }

    $results += Run-Test -Name "A framework edit committed during the task is flagged" -Body {
        # The evasion this leg closes: edit a vendored framework file, commit it, and the
        # working tree is clean again. The old gate read only `git status`, so it passed -
        # and its own remediation text told the specialist to commit.
        $repo = Join-Path $tempRoot "integrity-committed"
        $baseSha = New-IntegrityRepo -Path $repo

        "tampered" | Set-Content -LiteralPath (Join-Path $repo ".crucible/powershell/crucible.ps1") -Encoding UTF8
        "groomed" | Set-Content -LiteralPath (Join-Path $repo ".crucible/backlog/F-001.md") -Encoding UTF8
        git -C $repo add . | Out-Null
        git -C $repo commit -m "specialist edits a vendored framework file" | Out-Null

        $worktree = @(git -C $repo status --porcelain)
        Assert-Result -Name "working tree is clean" -Condition ($worktree.Count -eq 0) -FailureMessage ("fixture is not clean, so this would pass for the wrong reason: " + ($worktree -join ", "))

        $ctx = New-TestContext -TempRoot $repo -TaskId "F-030"
        $ctx.RepoRoot = $repo
        $ctx.CrucibleRoot = ".crucible"
        $ctx.Handoff = [pscustomobject]@{ task_id = "F-030"; base_commit = $baseSha }

        $flagged = @(Get-CrucibleFrameworkStatusChanges -Context $ctx)
        $joined = ($flagged -join "`n")
        Assert-Result -Name "committed framework edit flagged" -Condition ($joined -match "committed \.crucible/powershell/crucible.ps1") -FailureMessage ("expected the committed framework edit to be flagged, got: " + $joined)
        Assert-Result -Name "committed adopter edit not flagged" -Condition ($joined -notmatch "backlog/F-001\.md") -FailureMessage ("adopter-owned backlog edit must stay excluded on the committed leg too, got: " + $joined)
    }

    $results += Run-Test -Name "The task branch merge-base is the baseline when the handoff has none" -Body {
        $repo = Join-Path $tempRoot "integrity-mergebase"
        $null = New-IntegrityRepo -Path $repo
        git -C $repo branch -m master | Out-Null
        git -C $repo checkout -b "task/F-031" | Out-Null

        "tampered on the task branch" | Set-Content -LiteralPath (Join-Path $repo ".crucible/powershell/crucible.ps1") -Encoding UTF8
        git -C $repo add . | Out-Null
        git -C $repo commit -m "framework edit on the task branch" | Out-Null

        $ctx = New-TestContext -TempRoot $repo -TaskId "F-031"
        $ctx.RepoRoot = $repo
        $ctx.CrucibleRoot = ".crucible"
        # No base_commit, so resolution has to fall through to the task branch merge-base.
        $ctx.Handoff = [pscustomobject]@{ task_id = "F-031" }

        $flagged = @(Get-CrucibleFrameworkStatusChanges -Context $ctx)
        Assert-Result -Name "merge-base baseline flags the edit" -Condition (($flagged -join "`n") -match "committed \.crucible/powershell/crucible.ps1") -FailureMessage ("expected the task-branch edit to be flagged, got: " + ($flagged -join ", "))
    }

    $results += Run-Test -Name "An unresolvable task baseline is counted as unverifiable, not passed" -Body {
        # base_commit is optional and nullable in handoff.schema.json, so a handoff
        # without one on a task with no task/<id> branch is a legitimate shape - and
        # this gate runs on every Crucible invocation, including the first bootstrap.
        # Failing here would block valid pipelines. The committed leg is skipped and
        # reported on the degraded/unverifiable channel so it is counted, not silent.
        $repo = Join-Path $tempRoot "integrity-nobase"
        $null = New-IntegrityRepo -Path $repo

        "tampered" | Set-Content -LiteralPath (Join-Path $repo ".crucible/powershell/crucible.ps1") -Encoding UTF8
        git -C $repo add . | Out-Null
        git -C $repo commit -m "framework edit with no baseline to compare against" | Out-Null

        $ctx = New-TestContext -TempRoot $repo -TaskId "F-032"
        $ctx.RepoRoot = $repo
        $ctx.CrucibleRoot = ".crucible"
        $ctx.Handoff = $null

        $changes = @(Get-CrucibleFrameworkStatusChanges -Context $ctx)
        Assert-Result -Name "no baseline does not block" -Condition ($changes.Count -eq 0) -FailureMessage ("expected the working-tree leg to report nothing, got: " + ($changes -join ", "))
        Assert-Result -Name "missing baseline is recorded on the context" -Condition ($ctx.ContainsKey("FrameworkIntegrityBaseline") -and $null -eq $ctx["FrameworkIntegrityBaseline"]) -FailureMessage "expected FrameworkIntegrityBaseline to be recorded as null so the caller can report the unrun leg"

        Assert-CrucibleFrameworkIntegrity -Context $ctx

        $logFile = $ctx.LogFile
        $logged = if (Test-Path -LiteralPath $logFile) { Get-Content -LiteralPath $logFile -Raw } else { "" }
        Assert-Result -Name "unverifiable gate is logged with a kind" -Condition ($logged -match "framework_integrity_no_baseline" -and $logged -match '"outcome":"unverifiable"') -FailureMessage ("expected a degraded/unverifiable event naming the kind, got: " + $logged)
        $notRun = @(Get-ChecksNotRun -SessionDir $ctx.SessionDir -TaskId "F-032") -join "`n"
        Assert-Result -Name "I12 unrun committed leg reaches the not-run record (item 258)" `
            -Condition ($notRun.Contains("[integrity gate v2] framework integrity committed-change check: no task baseline")) -FailureMessage ("record: " + $notRun)

        $ctx.Handoff = [pscustomobject]@{ task_id = "F-032"; base_commit = (git -C $repo rev-parse HEAD).Trim() }
        Assert-CrucibleFrameworkIntegrity -Context $ctx
        $afterBaseline = @(Get-ChecksNotRun -SessionDir $ctx.SessionDir -TaskId "F-032") -join "`n"
        Assert-Result -Name "the record clears once the committed leg runs" -Condition (-not $afterBaseline.Contains("[integrity gate v2]")) -FailureMessage ("record: " + $afterBaseline)
    }

    $results += Run-Test -Name "The not-run record keeps each source's lines apart (item 258)" -Body {
        $session = Join-Path $tempRoot "not-run-record/session"
        $record = Get-ChecksNotRunPath -SessionDir $session -TaskId "F-258"
        New-Item -ItemType Directory -Path (Split-Path -Parent $record) -Force | Out-Null
        [System.IO.File]::WriteAllText($record, "legacy check: written before item 258`n", (New-Object System.Text.UTF8Encoding($false)))
        Write-CheckNotRun -SessionDir $session -TaskId "F-258" -Source "scope gate" -Check "implementation scope check" -Reason "first reason"
        Write-CheckNotRun -SessionDir $session -TaskId "F-258" -Source "scope gate" -Check "implementation scope check" -Reason "second reason"
        Write-CheckNotRun -SessionDir $session -TaskId "F-258" -Source "isolated checks" -Check "gpu check" -Reason "requires command 'gpu-tool' on PATH"
        $lines = @(Get-ChecksNotRun -SessionDir $session -TaskId "F-258")
        Assert-Result -Name "a check is recorded once, with its latest reason" -Condition (@($lines | Where-Object { $_ -like "[[]scope gate v2] implementation scope check: *" }).Count -eq 1 -and ($lines -contains "[scope gate v2] implementation scope check: second reason")) -FailureMessage ($lines -join " | ")

        Clear-ChecksNotRun -SessionDir $session -TaskId "F-258" -Source "isolated checks" -Check "gpu check"
        Clear-ChecksNotRun -SessionDir $session -TaskId "F-258" -Source "isolated checks" -Check "legacy check"
        $lines = @(Get-ChecksNotRun -SessionDir $session -TaskId "F-258")
        Assert-Result -Name "isolated checks clear their own and pre-258 lines only" -Condition ($lines.Count -eq 1 -and $lines[0] -eq "[scope gate v2] implementation scope check: second reason") -FailureMessage ($lines -join " | ")

        Write-CheckNotRun -SessionDir $session -TaskId "F-258" -Source "isolated checks" -Check "lint" -Reason "plain lint not run"
        Write-CheckNotRun -SessionDir $session -TaskId "F-258" -Source "isolated checks" -Check "lint: go" -Reason "go lint not run"
        $lines = @(Get-ChecksNotRun -SessionDir $session -TaskId "F-258")
        Assert-Result -Name "a check named like another's prefix keeps its own line" -Condition (($lines -contains "[isolated checks v2] lint: plain lint not run") -and ($lines -contains "[isolated checks v2] lint\: go: go lint not run")) -FailureMessage ($lines -join " | ")
        Clear-ChecksNotRun -SessionDir $session -TaskId "F-258" -Source "isolated checks" -Check "lint"
        $lines = @(Get-ChecksNotRun -SessionDir $session -TaskId "F-258")
        Assert-Result -Name "clearing lint keeps lint: go" -Condition (($lines -notcontains "[isolated checks v2] lint: plain lint not run") -and ($lines -contains "[isolated checks v2] lint\: go: go lint not run")) -FailureMessage ($lines -join " | ")
        Write-CheckNotRun -SessionDir $session -TaskId "F-258" -Source "isolated checks" -Check "lint" -Reason "plain lint not run"
        Clear-ChecksNotRun -SessionDir $session -TaskId "F-258" -Source "isolated checks" -Check "lint: go"
        $lines = @(Get-ChecksNotRun -SessionDir $session -TaskId "F-258")
        Assert-Result -Name "clearing lint: go keeps lint" -Condition (($lines -contains "[isolated checks v2] lint: plain lint not run") -and -not ($lines -match 'go lint not run')) -FailureMessage ($lines -join " | ")

        $refused = $false
        try { Write-CheckNotRun -SessionDir $session -TaskId "F-258" -Source "scope gate" -Check "x" -Reason " " } catch { $refused = $true }
        Assert-Result -Name "a skip without a reason is refused" -Condition $refused -FailureMessage "blank reason was recorded"
    }

    foreach ($legacy in @('[isolated checks] lint: go: previous skip', 'lint: go: previous skip', '[isolated checks] lint\: go: previous skip')) {
        foreach ($checkName in @('lint', 'lint: go')) {
            $results += Run-Test -Name ("Ambiguous legacy identity survives clearing " + $checkName + ': ' + $legacy) -Body {
                $session = Join-Path $tempRoot 'not-run-legacy/session'
                $record = Get-ChecksNotRunPath -SessionDir $session -TaskId F-258
                New-Item -ItemType Directory -Path (Split-Path -Parent $record) -Force | Out-Null
                [IO.File]::WriteAllText($record, $legacy + "`n", [Text.UTF8Encoding]::new($false))
                Clear-ChecksNotRun -SessionDir $session -TaskId F-258 -Source 'isolated checks' -Check $checkName
                $after = @(Get-ChecksNotRun -SessionDir $session -TaskId F-258)
                Assert-Result -Name ("ambiguous legacy line retained for " + $checkName + ': ' + $legacy) -Condition ($after.Count -eq 1 -and $after[0] -ceq $legacy) -FailureMessage ($after -join ' | ')
                Write-CheckNotRun -SessionDir $session -TaskId F-258 -Source 'isolated checks' -Check $checkName -Reason 'new reason: with a delimiter'
                $afterWrite = @(Get-ChecksNotRun -SessionDir $session -TaskId F-258)
                Assert-Result -Name 'replacement preserves ambiguous history beside the new identity' -Condition ($afterWrite.Count -eq 2 -and $afterWrite -contains $legacy) -FailureMessage ($afterWrite -join ' | ')
                Clear-ChecksNotRun -SessionDir $session -TaskId F-258 -Source 'isolated checks' -Check $checkName
                $afterClear = @(Get-ChecksNotRun -SessionDir $session -TaskId F-258)
                Assert-Result -Name 'versioned identity clears despite a delimiter in its reason' -Condition ($afterClear.Count -eq 1 -and $afterClear[0] -ceq $legacy) -FailureMessage ($afterClear -join ' | ')
            }
        }
    }

    function Start-RecordWorker {
        param([string]$Directory, [string]$Name, [string]$Body)
        $scriptPath = Join-Path $Directory ($Name + '.ps1')
        [IO.File]::WriteAllText($scriptPath, @'
param($Library, $Session, $Record, $Ready, $Release, $Blocked)
$ErrorActionPreference = 'Stop'
. $Library
'@ + "`n" + $Body, [Text.UTF8Encoding]::new($false))
        $psi = [Diagnostics.ProcessStartInfo]::new($pwshCmd)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        foreach ($arg in @('-NoProfile', '-File', $scriptPath, (Join-Path $REPO_ROOT 'powershell/lib/checks-not-run.ps1'), $session, $record, $ready, $release, $blocked)) { $psi.ArgumentList.Add($arg) }
        return [Diagnostics.Process]::Start($psi)
    }

    function Wait-RecordSignal {
        param([string]$Path, [Diagnostics.Process]$Process)
        $deadline = [datetime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $Path) -and -not $Process.HasExited -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
        return (Test-Path -LiteralPath $Path)
    }

    # The reader body below is a scheduling seam: it keeps the same non-delete-sharing
    # handle as ReadAllLines open until the parent releases it. Get-ChecksNotRun must
    # coordinate that entire read, not just the existence check or publication.
    foreach ($holderKind in @('record lock', 'record reader')) {
        $results += Run-Test -Name ("A writer waits for an acknowledged " + $holderKind + ' in another process') -Body {
            $caseDir = Join-Path $tempRoot ('not-run-held-' + $holderKind.Replace(' ', '-'))
            $session = Join-Path $caseDir 'session'
            $record = Get-ChecksNotRunPath -SessionDir $session -TaskId F-258
            New-Item -ItemType Directory -Path (Split-Path -Parent $record) -Force | Out-Null
            $original = "[scope gate] old check: still skipped`n"
            [IO.File]::WriteAllText($record, $original, [Text.UTF8Encoding]::new($false))
            $ready = Join-Path $caseDir 'ready'
            $release = Join-Path $caseDir 'release'
            $blocked = Join-Path $caseDir 'blocked'
            $holderBody = if ($holderKind -eq 'record lock') {
                @'
Invoke-FileLock -LockPath ($Record + '.lock') -ScriptBlock {
    [IO.File]::WriteAllText($Ready, 'locked')
    while (-not (Test-Path -LiteralPath $Release)) { Start-Sleep -Milliseconds 20 }
}
'@
            } else {
                @'
function Read-ChecksNotRunFile {
    param([string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        [IO.File]::WriteAllText($Ready, 'reader open')
        while (-not (Test-Path -LiteralPath $Release)) { Start-Sleep -Milliseconds 20 }
        $reader = [IO.StreamReader]::new($stream)
        try { $reader.ReadToEnd().TrimEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}
Get-ChecksNotRun -SessionDir $Session -TaskId F-258
'@
            }
            $writerBody = @'
$lockImplementation = ${function:Invoke-FileLock}
function Invoke-FileLock {
    param($LockPath, $ScriptBlock, $TimeoutMessage)
    & $lockImplementation -LockPath $LockPath -ScriptBlock $ScriptBlock -TimeoutMs 100 -TimeoutMessage $TimeoutMessage
}
function Write-Quiet {
    param($Message, $ForegroundColor)
    [IO.File]::WriteAllText($Blocked, $Message)
}
Write-CheckNotRun -SessionDir $Session -TaskId F-258 -Source 'isolated checks' -Check 'new check' -Reason 'writer published'
'@
            $holder = $null
            $writer = $null
            try {
                $holder = Start-RecordWorker -Directory $caseDir -Name holder -Body $holderBody
                $holderReady = Wait-RecordSignal -Path $ready -Process $holder
                Assert-Result -Name 'holder acknowledges acquisition before writer starts' -Condition $holderReady -FailureMessage 'holder did not open its handle'
                $writer = Start-RecordWorker -Directory $caseDir -Name writer -Body $writerBody
                $writerBlocked = Wait-RecordSignal -Path $blocked -Process $writer
                $writerError = if ($writer.HasExited) { $writer.StandardError.ReadToEnd() } else { '' }
                Assert-Result -Name ("writer acknowledges contention on " + $holderKind) -Condition $writerBlocked -FailureMessage $writerError
                Assert-Result -Name 'writer cannot publish before holder release' -Condition (-not $writer.HasExited -and [IO.File]::ReadAllText($record) -ceq $original) -FailureMessage 'writer published or exited while holder was active'
                [IO.File]::WriteAllText($release, 'release')
                $holderDone = $holder.WaitForExit(30000)
                $writerDone = $writer.WaitForExit(30000)
                Assert-Result -Name 'holder and writer exit successfully after release' -Condition ($holderDone -and $writerDone -and $holder.ExitCode -eq 0 -and $writer.ExitCode -eq 0) -FailureMessage 'holder or writer failed after release'
                $published = @(Get-ChecksNotRun -SessionDir $session -TaskId F-258)
                Assert-Result -Name 'publication after release preserves both records' -Condition ($published.Count -eq 2 -and ($published -join "`n").Contains('new check: writer published')) -FailureMessage ($published -join ' | ')
                Assert-Result -Name 'record lock is released after publication' -Condition (-not (Test-Path -LiteralPath ($record + '.lock'))) -FailureMessage 'lock pathname remains'
            } finally {
                [IO.File]::WriteAllText($release, 'release')
                foreach ($proc in @($writer, $holder)) {
                    if ($null -ne $proc) {
                        if (-not $proc.WaitForExit(5000)) { $proc.Kill($true); $proc.WaitForExit() }
                        $proc.Dispose()
                    }
                }
            }
        }
    }

    $results += Run-Test -Name 'A permanent lock open error is not retried as contention' -Body {
        $caseDir = Join-Path $tempRoot 'not-run-missing-directory'
        New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
        $session = Join-Path $caseDir 'session'
        $record = Join-Path $caseDir 'missing/record'
        $ready = Join-Path $caseDir 'entered'
        $release = Join-Path $caseDir 'unused-release'
        $blocked = Join-Path $caseDir 'unused-blocked'
        $body = @'
[IO.File]::WriteAllText($Ready, 'started')
Invoke-FileLock -LockPath ($Record + '.lock') -TimeoutMs 100 -ScriptBlock { throw 'must not execute protected body' }
'@
        $proc = Start-RecordWorker -Directory $caseDir -Name missing -Body $body
        try {
            Assert-Result -Name 'missing-directory worker reaches lock call' -Condition (Wait-RecordSignal -Path $ready -Process $proc) -FailureMessage 'worker did not start'
            $done = $proc.WaitForExit(5000)
            Assert-Result -Name 'missing directory fails promptly instead of retrying forever' -Condition $done -FailureMessage 'lock acquisition kept retrying a permanent open error'
            $errText = $proc.StandardError.ReadToEnd()
            Assert-Result -Name 'permanent lock error names the failed path' -Condition ($proc.ExitCode -ne 0 -and $errText.Contains('Cannot acquire lock') -and $errText.Contains($record) -and -not $errText.Contains('must not execute protected body')) -FailureMessage $errText
        } finally {
            if (-not $proc.HasExited) { $proc.Kill($true); $proc.WaitForExit() }
            $proc.Dispose()
        }
    }

    $results += Run-Test -Name "Not-run writers in separate processes do not lose each other's lines (I5, item 258)" -Body {
        $session = Join-Path $tempRoot "not-run-concurrent/session"
        $go = Join-Path $tempRoot "not-run-concurrent/go"
        New-Item -ItemType Directory -Path $session -Force | Out-Null
        $libText = (Join-Path $REPO_ROOT "powershell/lib/checks-not-run.ps1").Replace("'", "''")
        $procs = @()
        foreach ($source in @("scope gate", "isolated checks")) {
            $script = Join-Path $tempRoot ("not-run-concurrent/" + $source.Replace(" ", "-") + ".ps1")
            $body = @(
                "`$ErrorActionPreference = 'Stop'",
                ". '$libText'",
                "while (-not (Test-Path -LiteralPath '$go')) { Start-Sleep -Milliseconds 10 }",
                "for (`$i = 0; `$i -lt 25; `$i++) { Write-CheckNotRun -SessionDir '$session' -TaskId 'F-259' -Source '$source' -Check (""check "" + `$i) -Reason ""writer race"" }"
            ) -join "`n"
            [System.IO.File]::WriteAllText($script, $body, (New-Object System.Text.UTF8Encoding($false)))
            $procs += Start-Process -FilePath $pwshCmd -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script) -PassThru -NoNewWindow -RedirectStandardError ($script + ".err")
        }
        Start-Sleep -Milliseconds 1500
        [System.IO.File]::WriteAllText($go, "go")
        foreach ($p in $procs) { $p.WaitForExit(120000) | Out-Null }
        $errors = @($procs | ForEach-Object { $_.ExitCode }) -join ","
        $errText = (@(Get-ChildItem -LiteralPath (Join-Path $tempRoot "not-run-concurrent") -Filter "*.err" | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n")
        Assert-Result -Name "both writers exit cleanly" -Condition ($errors -eq "0,0") -FailureMessage ("exit codes " + $errors + "`n" + $errText)
        $lines = @(Get-ChecksNotRun -SessionDir $session -TaskId "F-259")
        Assert-Result -Name "every line from both writers survives" -Condition ($lines.Count -eq 50) -FailureMessage ("kept " + $lines.Count + " of 50 lines")
        $leftovers = @(Get-ChildItem -LiteralPath (Split-Path -Parent (Get-ChecksNotRunPath -SessionDir $session -TaskId "F-259")) -File | Where-Object { $_.Name -ne "checks-not-run.txt" })
        Assert-Result -Name "no temporary or lock file is left" -Condition ($leftovers.Count -eq 0) -FailureMessage (($leftovers | ForEach-Object { $_.Name }) -join ", ")
    }

    $results += Run-Test -Name "The empty-affinity conflict check is recorded wherever it applies, and clears only when it runs (item 258)" -Body {
        $caseRoot = Join-Path $tempRoot "conflict-applies"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-260"
        $ctx.Handoff = [pscustomobject]@{ task_id = "F-260"; source_phase = "verification"; target_phase = "deployment"; file_affinity = @() }
        $null = (& { Invoke-CrucibleScopeGates -Context $ctx } 6>&1 | Out-String)
        $lines = @(Get-ChecksNotRun -SessionDir $ctx.SessionDir -TaskId "F-260") -join "`n"
        Assert-Result -Name "I12 verification to deployment without affinity records the conflict check" -Condition ($lines.Contains("[scope gate v2] file affinity conflict check: no file_affinity declared")) -FailureMessage ("record: " + $lines)

        $research = New-TestContext -TempRoot $caseRoot -TaskId "R-260"
        $research.Handoff = [pscustomobject]@{ task_id = "R-260"; source_phase = "research"; target_phase = "grooming"; file_affinity = @() }
        $research.RepoRoot = $caseRoot
        $null = (& { Invoke-CrucibleScopeGates -Context $research } 6>&1 | Out-String)
        $researchLines = @(Get-ChecksNotRun -SessionDir $research.SessionDir -TaskId "R-260") -join "`n"
        Assert-Result -Name "research to grooming has no files to overlap and records no conflict skip" -Condition (-not $researchLines.Contains("file affinity conflict check")) -FailureMessage ("record: " + $researchLines)

        # A stub that leaves a marker proves the check executed before its line clears.
        $marker = Join-Path $caseRoot "affinity-ran.txt"
        [System.IO.File]::WriteAllText((Join-Path $ctx.FrameworkPowerShell "check-file-affinity.ps1"), ("param(`$TaskId, `$Affinity)`n[System.IO.File]::WriteAllText('" + $marker.Replace("'", "''") + "', `$TaskId)`nexit 0`n"), (New-Object System.Text.UTF8Encoding($false)))
        $ctx.Handoff = [pscustomobject]@{ task_id = "F-260"; source_phase = "verification"; target_phase = "deployment"; file_affinity = @("src/a.txt") }
        $null = (& { Invoke-CrucibleScopeGates -Context $ctx } 6>&1 | Out-String)
        $after = @(Get-ChecksNotRun -SessionDir $ctx.SessionDir -TaskId "F-260") -join "`n"
        Assert-Result -Name "a check that ran clears its line" -Condition ((Test-Path -LiteralPath $marker) -and -not $after.Contains("file affinity conflict check")) -FailureMessage ("marker present: " + (Test-Path -LiteralPath $marker) + "; record: " + $after)
    }
    $results += Run-Test -Name "Scope gate skips that are not the empty-affinity one are recorded too (item 258)" -Body {
        $caseRoot = Join-Path $tempRoot "scope-skips"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "R-258"
        # FrameworkPowerShell has no check-file-affinity.ps1, and RepoRoot is not a git repository.
        $ctx.Handoff = [pscustomobject]@{ task_id = "R-258"; source_phase = "research"; target_phase = "grooming"; file_affinity = @("src/a.txt") }
        $ctx.RepoRoot = $caseRoot
        $out = (& { Invoke-CrucibleScopeGates -Context $ctx } 6>&1 | Out-String)
        $lines = @(Get-ChecksNotRun -SessionDir $ctx.SessionDir -TaskId "R-258") -join "`n"
        Assert-Result -Name "I12 missing affinity script is recorded" -Condition ($lines.Contains("[scope gate v2] file affinity conflict check: check-file-affinity.ps1 not found")) -FailureMessage ($lines + "`n" + $out)
        Assert-Result -Name "I12 unreadable research scope is recorded" -Condition ($lines.Contains("[scope gate v2] research scope check: could not read the changed files")) -FailureMessage ($lines + "`n" + $out)
    }

    $results += Run-Test -Name "A tree the integrity check cannot read is reported, not passed" -Body {
        # Each case below used to return an empty array, which is the same value the
        # function returns for a genuinely clean tree. The circuit breaker therefore
        # reported a passing integrity check on a tree it had never looked at.
        $unreadable = Join-Path $tempRoot "integrity-unreadable"
        New-Item -ItemType Directory -Path (Join-Path $unreadable ".crucible/powershell") -Force | Out-Null
        "framework" | Set-Content -LiteralPath (Join-Path $unreadable ".crucible/powershell/crucible.ps1") -Encoding UTF8

        $cases = @(
            @{ Name = "blank RepoRoot"; Ctx = @{ RepoRoot = ""; CrucibleRoot = ".crucible" }; Expect = "Context.RepoRoot is empty" },
            @{ Name = "blank CrucibleRoot"; Ctx = @{ RepoRoot = $unreadable; CrucibleRoot = "" }; Expect = "Context.CrucibleRoot is empty" },
            @{ Name = "missing bundle"; Ctx = @{ RepoRoot = $unreadable; CrucibleRoot = ".no-such-bundle" }; Expect = "no Crucible bundle at" },
            # Not a git repository, so git status exits non-zero. Before the fix this
            # surfaced as a raw "fatal: not a git repository" NativeCommandError under
            # the $ErrorActionPreference = "Stop" that crucible.ps1 sets, so asserting on
            # the gate's own wording is what separates a verdict from a crash.
            @{ Name = "git status fails"; Ctx = @{ RepoRoot = $unreadable; CrucibleRoot = ".crucible" }; Expect = "'git status' exited" }
        )

        foreach ($case in $cases) {
            $thrown = ""
            try {
                $null = @(Get-CrucibleFrameworkStatusChanges -Context $case.Ctx)
            } catch {
                $thrown = $_.Exception.Message
            }
            Assert-Result -Name ($case.Name + " throws") -Condition ($thrown -ne "") -FailureMessage ("expected " + $case.Name + " to throw, but it returned without error")
            Assert-Result -Name ($case.Name + " names the reason") -Condition ($thrown -match [regex]::Escape($case.Expect)) -FailureMessage ("expected message matching '" + $case.Expect + "', got: " + $thrown)
        }
    }

    $results += Run-Test -Name "The circuit breaker blocks when the integrity check cannot run" -Body {
        $unreadable = Join-Path $tempRoot "integrity-breaker"
        New-Item -ItemType Directory -Path (Join-Path $unreadable ".crucible/powershell") -Force | Out-Null
        "framework" | Set-Content -LiteralPath (Join-Path $unreadable ".crucible/powershell/crucible.ps1") -Encoding UTF8

        # Run in a child process because the gate blocks with exit 2, and match
        # crucible.ps1:112 so the preference under test is the production one.
        $driver = Join-Path $tempRoot "breaker-driver.ps1"
        $driverText = @"
`$Quiet = `$true
. (Join-Path '$REPO_ROOT' 'powershell/crucible-lib.ps1')
`$ErrorActionPreference = 'Stop'
Assert-CrucibleFrameworkIntegrity -Context @{
    RepoRoot = '$unreadable'
    CrucibleRoot = '.crucible'
    TaskId = 'F-021'
    LogFile = (Join-Path '$unreadable' 'session/F-021/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$unreadable' 'session/global/circuit_breakers.jsonl')
    Handoff = `$null
}
Write-Host 'GATE PASSED WITHOUT CHECKING'
exit 0
"@
        [System.IO.File]::WriteAllText($driver, $driverText, (New-Object System.Text.UTF8Encoding($false)))

        $run = Invoke-ExternalCommand { & $pwshCmd -NoProfile -ExecutionPolicy Bypass -File $driver }
        $output = ($run.Output -join "`n")
        Assert-Result -Name "breaker exits 2" -Condition ($run.ExitCode -eq 2) -FailureMessage ("expected exit 2, got " + $run.ExitCode + ". Output: " + $output)
        Assert-Result -Name "breaker names the failure" -Condition ($output -match "integrity check could not run") -FailureMessage ("expected the check-could-not-run message, got: " + $output)
        Assert-Result -Name "breaker did not pass" -Condition ($output -notmatch "GATE PASSED WITHOUT CHECKING") -FailureMessage "the gate returned instead of blocking"

        $cbHistory = Join-Path $unreadable "session/global/circuit_breakers.jsonl"
        Assert-Result -Name "breaker is recorded distinctly" -Condition ((Test-Path -LiteralPath $cbHistory) -and ((Get-Content -LiteralPath $cbHistory -Raw) -match "framework_integrity_check_failed")) -FailureMessage "expected a framework_integrity_check_failed circuit-breaker event, distinct from a real violation"
    }

    $results += Run-Test -Name "Extracted functions enforce required context keys" -Body {
        # Test null context
        try {
            Invoke-CrucibleRuntimeValidation -Context $null
            Assert-Result -Name "null context check" -Condition $false -FailureMessage "Did not fail on null context"
        } catch {
            Assert-Result -Name "null context check passed" -Condition ($true) -FailureMessage "Null check failed"
        }

        # Test missing key for Invoke-CrucibleRuntimeValidation
        $badCtx = @{ RepoRoot = "foo" }
        try {
            Invoke-CrucibleRuntimeValidation -Context $badCtx
            Assert-Result -Name "runtime missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "runtime key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Invoke-CrucibleScopeGates
        try {
            Invoke-CrucibleScopeGates -Context $badCtx
            Assert-Result -Name "scope missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "scope key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Test-CompletionArtifactGate
        try {
            Test-CompletionArtifactGate -Context $badCtx
            Assert-Result -Name "artifact missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "artifact key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Normalize-CrucibleInputState
        try {
            Normalize-CrucibleInputState -Context $badCtx
            Assert-Result -Name "normalize missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "normalize key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Invoke-CircuitBreakerGates
        try {
            Invoke-CircuitBreakerGates -Context $badCtx
            Assert-Result -Name "breaker missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "breaker key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Invoke-HumanGate
        try {
            Invoke-HumanGate -Context $badCtx
            Assert-Result -Name "human gate missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "human gate key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Invoke-RepositoryIntegrityGates
        try {
            Invoke-RepositoryIntegrityGates -Context $badCtx
            Assert-Result -Name "integrity gates missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "integrity gates key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }

        # Test missing key for Resolve-CrucibleTransition
        try {
            Resolve-CrucibleTransition -Context $badCtx
            Assert-Result -Name "transition missing key check" -Condition $false -FailureMessage "Did not fail on missing keys"
        } catch {
            Assert-Result -Name "transition key check passed" -Condition ($_.Exception.Message -match "Required key '.*' is missing") -FailureMessage "Incorrect missing key error message"
        }
    }

} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed Crucible gate test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll Crucible gate tests passed." -ForegroundColor Green
exit 0
