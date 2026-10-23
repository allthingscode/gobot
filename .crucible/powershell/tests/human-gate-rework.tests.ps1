# Item 250: rejection must ask I8's row owner before generating a rework handoff.
$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/platform.ps1')
$results = @()
$root = New-TestFixtureRoot -NameHint 'human-gate-rework'
try {
    foreach ($case in @('prefix', 'mention', 'missing', 'read-error', 'late-read-error', 'late-missing-row', 'plain', 'linked')) {
        $results += Run-Test -Name "Rework exact backlog ID: $case" -Body {
            $dir = Join-Path $root $case
            $lib = Join-Path $dir 'powershell/lib'
            New-Item -ItemType Directory -Path $lib -Force | Out-Null
            Copy-Item -Path (Join-Path $REPO_ROOT 'powershell/lib/*.ps1') -Destination $lib
            $row = switch ($case) {
                { $_ -in @('prefix', 'late-missing-row') } { '| F-10 | In Progress | Other task |' }
                'mention' { '| F-20 | In Progress | Replaces F-1 |' }
                { $_ -in @('plain', 'late-read-error') } { '| F-1 | In Progress | Task |' }
                'linked' { '| [F-1](features/active/F-1_task.md) | In Progress | Task |' }
            }
            if ($case -eq 'late-missing-row') {
                $specDir = Join-Path $dir 'features/active'
                New-Item -ItemType Directory -Path $specDir -Force | Out-Null
                "---`nitem_id: F-1`ntype: Feature`nstatus: In Progress`n---`n# Task" | Set-Content -LiteralPath (Join-Path $specDir 'F-1_task.md') -Encoding utf8NoBOM
            }
            if ($case -ne 'missing') {
                @('# F-1 rework', '| ID | Status | Title |', '|---|---|---|', $row) |
                    Set-Content -LiteralPath (Join-Path $dir 'BACKLOG.md') -Encoding utf8NoBOM
            }
            # Isolate the dispatch boundary: git unwind/restore are covered by the human
            # gate suite, and the generator records whether it was called at all.
            'param($TaskId, $Source, $Target, $Reason, $ReviewStrikeCount, $RebaseCount, $ProjectRoot, $SessionCycleId, $Artifacts); Set-Content -LiteralPath (Join-Path $PSScriptRoot "../generated.txt") -Value $TaskId' |
                Set-Content -LiteralPath (Join-Path $dir 'powershell/new-handoff.ps1') -Encoding utf8NoBOM
            $runner = @'
param($Root, $Framework, $Case)
$ErrorActionPreference = 'Stop'
. (Join-Path $Framework 'powershell/lib/backlog-io.ps1')
. (Join-Path $Root 'powershell/lib/crucible-gates-human.ps1')
function Get-HumanGateRejectUnwind { @{ CurrentHead = 'tip'; ParentList = @(); HeadIsTaskMerge = $false; UnwindTarget = '' } }
function Test-GitDiscardSafe { $true }
function Invoke-GitChecked { $global:LASTEXITCODE = 0 }
function Restore-BacklogTask {}
function Restore-ImplementationWorktree {}
function Get-ConfiguredPath { $Root }
function Write-Quiet { param($Message) Write-Host $Message }
if ($Case -eq 'late-read-error') {
    $ErrorActionPreference = 'Continue'
    $global:backlogReads = 0
    function Get-Content {
        [CmdletBinding()]
        param($LiteralPath, $Encoding)
        $global:backlogReads++
        if ($global:backlogReads -ge 2) { Write-Error 'injected late read error' }
        Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Encoding $Encoding
    }
}
if ($Case -eq 'read-error') {
    $ErrorActionPreference = 'Continue'
    function Get-Content {
        [CmdletBinding()]
        param($LiteralPath, $Encoding)
        Write-Error 'injected backlog read error'
    }
}
$strikeHandoff = [pscustomobject]@{ review_strike_count = 2; session_cycle_id = 'cycle-7' }
try {
    Invoke-HumanGateRejectAbandon -TaskId F-1 -Outcome rejected -ProjectRoot $Root -PrimaryBranch main -GateReason 'rework' -Handoff $strikeHandoff
} catch { Write-Host "Caller caught: $_" }
Write-Host 'CALLER_CONTINUED'
exit 0
'@
            $script = Join-Path $dir 'run.ps1'
            Set-Content -LiteralPath $script -Value $runner -Encoding utf8NoBOM
            $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $script $dir $REPO_ROOT $case }
            if ($case -in @('late-read-error', 'late-missing-row')) {
                Assert-Result -Name 'late refusal prints the recovery command with the incremented strike count' -Condition ($run.Output -match 'new-handoff\.ps1' -and $run.Output -match '-ReviewStrikeCount 3\b' -and $run.Output -match '-ProjectRoot ' -and $run.Output -match '-SessionCycleId cycle-7\b' -and $run.Output -match 'already recorded and task/F-1 restored') -FailureMessage $run.Output
                Assert-Result -Name 'late refusal does not tell the human to reject again' -Condition ($run.Output -notmatch 'then reject again' -and $run.Output -match 'do not reject again') -FailureMessage $run.Output
            }
            if ($case -eq 'late-read-error') {
                Assert-Result -Name 'late read error names the state it leaves and a remedy' -Condition ($run.Output -match 'injected late read error' -and $run.Output -match 'already recorded and task/F-1 restored' -and $run.Output -match 'new-handoff\.ps1\W+-TaskId F-1\b' -and $run.Output -match 'do not reject again' -and $run.Output -notmatch 'then reject again') -FailureMessage $run.Output
            }
            if ($case -eq 'read-error') {
                Assert-Result -Name 'read error is diagnosed under Continue preference' -Condition ($run.Output -match 'Cannot read backlog for rework of F-1:.*injected backlog read error' -and $run.Output -notmatch 'no exact ID row') -FailureMessage $run.Output
            }
            $present = $case -in @('plain', 'linked')
            Assert-Result -Name "$case handoff dispatch matches exact ID cell" -Condition ((Test-Path (Join-Path $dir 'generated.txt')) -eq $present) -FailureMessage $run.Output
            Assert-Result -Name "$case refusal cannot become caller success" -Condition (($run.ExitCode -eq 0) -eq $present) -FailureMessage $run.Output
            if ($case -eq 'late-missing-row') {
                Assert-Result -Name 'late missing row names the absent exact row' -Condition ($run.Output -match 'F-1 has no exact ID row' -and $run.Output -notmatch 'CALLER_CONTINUED') -FailureMessage $run.Output
            } elseif ($case -eq 'missing') {
                Assert-Result -Name 'missing refusal names absent backlog file' -Condition ($run.Output -match 'Backlog file .* is missing' -and $run.Output -notmatch 'no exact ID row|CALLER_CONTINUED') -FailureMessage $run.Output
            } elseif (-not $present -and $case -notin @('read-error', 'late-read-error', 'late-missing-row')) {
                Assert-Result -Name "$case refusal names missing exact row" -Condition ($run.Output -match 'F-1 has no exact ID row' -and $run.Output -notmatch 'CALLER_CONTINUED') -FailureMessage $run.Output
            }
        }
    }
    foreach ($case in @('prefix', 'lookalike-spec', 'missing', 'read-error', 'active-spec', 'archived-spec')) {
        $results += Run-Test -Name "Rejection intake is atomic: $case" -Body {
            $dir = Join-Path $root ("intake-" + $case)
            $lib = Join-Path $dir 'powershell/lib'
            $gate = Join-Path $dir 'session/global/gate_decisions'
            New-Item -ItemType Directory -Path $lib, $gate -Force | Out-Null
            Copy-Item -Path (Join-Path $REPO_ROOT 'powershell/lib/*.ps1') -Destination $lib
            $backlog = Join-Path $dir 'BACKLOG.md'
            if ($case -ne 'missing') {
                "## Features`n| ID | Priority | Status | Title | Specialist |`n|---|---|---|---|---|`n| F-10 | P2 | In Progress | Mentions F-1 | Operator |" |
                    Set-Content -LiteralPath $backlog -Encoding utf8NoBOM
            }
            if ($case -in @('active-spec', 'archived-spec')) {
                $state = if ($case -eq 'active-spec') { 'active' } else { 'archived' }
                $specDir = Join-Path $dir "features/$state"
                New-Item -ItemType Directory -Path $specDir -Force | Out-Null
                "---`nitem_id: F-1`ntype: Feature`nstatus: Production`n---`n# Task" |
                    Set-Content -LiteralPath (Join-Path $specDir 'F-1_task.md') -Encoding utf8NoBOM
            }
            if ($case -eq 'lookalike-spec') {
                $specDir = Join-Path $dir 'features/active'
                New-Item -ItemType Directory -Path $specDir -Force | Out-Null
                "---`nitem_id: F-10`ntype: Feature`nstatus: In Progress`n---`n# Other" |
                    Set-Content -LiteralPath (Join-Path $specDir 'F-10_task.md') -Encoding utf8NoBOM
            }
            $pending = Join-Path $dir 'pending.json'
            '{"outcome":"rejected","reason":"Needs a concrete correction"}' |
                Set-Content -LiteralPath $pending -Encoding utf8NoBOM
            $pendingBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pending))
            $backlogBytes = if (Test-Path $backlog) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($backlog)) } else { '' }
            'param($TaskId, $Source, $Target, $Reason, $ReviewStrikeCount, $RebaseCount, $ProjectRoot, $SessionCycleId, $Artifacts); Set-Content -LiteralPath (Join-Path $PSScriptRoot "../generated.txt") -Value generated' |
                Set-Content -LiteralPath (Join-Path $dir 'powershell/new-handoff.ps1') -Encoding utf8NoBOM
            $runner = @'
param($Root, $Framework, $Case)
$ErrorActionPreference = 'Continue'
. (Join-Path $Framework 'powershell/crucible-lib.ps1')
. (Join-Path $Root 'powershell/lib/crucible-gates-human.ps1')
function Get-ConfiguredPath { $Root }
function Resolve-ConfigProjectRoot { $Root }
function Get-ConfiguredPrimaryBranch { 'main' }
function Get-HumanGateRejectUnwind { @{ CurrentHead = 'tip'; ParentList = @('base', 'task'); HeadIsTaskMerge = $true; UnwindTarget = 'base' } }
function Test-GitDiscardSafe { $true }
function Invoke-GitChecked { param($Command) Add-Content -LiteralPath (Join-Path $Root 'git-actions.txt') -Value $Command.ToString(); $global:LASTEXITCODE = 0 }
function Restore-ImplementationWorktree { Set-Content -LiteralPath (Join-Path $Root 'worktree-restored.txt') -Value restored }
function Write-Quiet { param($Message) Write-Host $Message }
if ($Case -eq 'read-error') {
    function Get-Content {
        [CmdletBinding()]
        param($LiteralPath, $Encoding)
        Write-Error 'injected backlog read error'
    }
}
$context = @{ Handoff = [pscustomobject]@{ task_id = 'F-1'; source_phase = 'deployment' }; SessionDir = (Join-Path $Root 'session') }
$pending = Join-Path $Root 'pending.json'
$decision = [pscustomobject]@{ outcome = 'rejected'; reason = 'Needs a concrete correction' }
# The real Restore-BacklogTask must synthesize the row from an active/archived spec.
Write-HumanGateDecision -Context $context -Decision $decision -ProjectRoot $Root -SessionCycleId '' -PendingTemplate $pending
Invoke-HumanGateRejectAbandon -TaskId F-1 -Outcome rejected -ProjectRoot $Root -PrimaryBranch main -GateReason $decision.reason
'@
            $script = Join-Path $dir 'run.ps1'
            Set-Content -LiteralPath $script -Value $runner -Encoding utf8NoBOM
            $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $script $dir $REPO_ROOT $case }
            $records = @(Get-ChildItem -LiteralPath $gate -File)
            if ($case -in @('active-spec', 'archived-spec')) {
                Assert-Result -Name "$case real restore allows rejection" -Condition ($run.ExitCode -eq 0 -and $records.Count -eq 1 -and (Test-Path (Join-Path $dir 'generated.txt'))) -FailureMessage $run.Output
                $rows = @(Get-Content -LiteralPath $backlog | Where-Object { $_ -match '^\| \[F-1\]' })
                Assert-Result -Name "$case real restore synthesizes exact row" -Condition ($rows.Count -eq 1 -and (Test-Path (Join-Path $dir 'features/active/F-1_task.md'))) -FailureMessage (Get-Content $backlog -Raw)
            } else {
                $pendingIntact = (Test-Path $pending) -and ([Convert]::ToBase64String([IO.File]::ReadAllBytes($pending)) -ceq $pendingBytes)
                $backlogIntact = if ($backlogBytes) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($backlog)) -ceq $backlogBytes } else { -not (Test-Path $backlog) }
                Assert-Result -Name "$case refusal precedes all decision and restore effects" -Condition ($run.ExitCode -ne 0 -and $records.Count -eq 0 -and $pendingIntact -and $backlogIntact -and -not (Test-Path (Join-Path $dir 'git-actions.txt')) -and -not (Test-Path (Join-Path $dir 'worktree-restored.txt')) -and -not (Test-Path (Join-Path $dir 'generated.txt'))) -FailureMessage $run.Output
                $message = switch ($case) {
                    'missing' { 'Backlog file .* is missing' }
                    'read-error' { 'Cannot read backlog for rework of F-1:.*injected backlog read error' }
                    default { 'F-1 has no exact ID row' }
                }
                Assert-Result -Name "$case intake refusal names cause and retry remedy" -Condition ($run.Output -match $message -and $run.Output -match 'then reject again') -FailureMessage $run.Output
            }
        }
    }
    $results += Run-Test -Name "Merge-conflict recovery propagates a refused rework handoff" -Body {
        $dir = Join-Path $root 'merge-refusal'
        $gate = Join-Path $dir 'global/gate_decisions'
        New-Item -ItemType Directory -Path $gate, (Join-Path $dir '.crucible') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir '.crucible/config.yaml'), "paths:`n  backlog: .`n", [Text.UTF8Encoding]::new($false))
        "| ID | Status | Title |`n|---|---|---|`n| F-10 | In Progress | Other |" | Set-Content -LiteralPath (Join-Path $dir 'BACKLOG.md') -Encoding utf8NoBOM
        '{"task_id":"F-1","outcome":"accepted"}' | Set-Content -LiteralPath (Join-Path $gate 'F-1-20260101T000000Z.json') -Encoding utf8NoBOM
        $runner = @'
param($Root, $Framework)
$ErrorActionPreference = 'Stop'
. (Join-Path $Framework 'powershell/crucible-lib.ps1')
. (Join-Path $Framework 'powershell/lib/crucible-gates-human.ps1')
function Test-GitDiscardSafe { $true }
function Invoke-GitChecked { param($Command) if ($Command.ToString() -match 'merge --no-ff') { $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 } }
function Get-ConfiguredPath { param($Key, $ProjectRoot) $Root }
function Resolve-ImplementationWorktreePath { param($TaskId, $WorkspacesDir) Join-Path $Root 'no-such-worktree' }
function Write-Quiet { param($Message) Write-Host $Message }
$result = Invoke-HumanGateMerge -TaskId F-1 -PrimaryBranch main -ProjectRoot $Root -LogFile (Join-Path $Root 'log.jsonl') -CircuitBreakerHistoryFile (Join-Path $Root 'cb.jsonl')
Write-Host "CALLER_RESULT=$result"
exit 3
'@
        $script = Join-Path $dir 'run.ps1'
        Set-Content -LiteralPath $script -Value $runner -Encoding utf8NoBOM
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $script $dir $REPO_ROOT }
        Assert-Result -Name 'refused handoff exits 2, not a rework result' -Condition ($run.ExitCode -eq 2 -and $run.Output -notmatch 'CALLER_RESULT') -FailureMessage ("exit " + $run.ExitCode + ": " + $run.Output)
        Assert-Result -Name 'refusal names the missing exact row and claims no rework' -Condition ($run.Output -match 'no exact row for F-1' -and $run.Output -match 'no rework was queued') -FailureMessage $run.Output
        Assert-Result -Name 'premature accepted decision is removed' -Condition (@(Get-ChildItem -LiteralPath $gate -File).Count -eq 0) -FailureMessage $run.Output
    }

    $results += Run-Test -Name "Printed recovery command binds two spaced artifact paths" -Body {
        $dir = Join-Path $root 'printed $root command'
        New-Item -ItemType Directory -Path (Join-Path $dir '.crucible') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir '.crucible/config.yaml'), ("crucible_root: `"" + $REPO_ROOT.Replace('\','/') + "`"`npaths:`n  backlog: .`n"), [Text.UTF8Encoding]::new($false))
        "| ID | Status | Title |`n|---|---|---|`n| F-10 | In Progress | Other |" | Set-Content -LiteralPath (Join-Path $dir 'BACKLOG.md') -Encoding utf8NoBOM
        $runner = @'
param($Root, $Framework)
$ErrorActionPreference = 'Stop'
. (Join-Path $Framework 'powershell/crucible-lib.ps1')
. (Join-Path $Framework 'powershell/lib/crucible-gates-human.ps1')
$h = [pscustomobject]@{ review_strike_count = 1; artifacts = @('one file.md', 'two file.md') }
Get-HumanGateReworkRecoveryCommand -TaskId F-1 -ProjectRoot $Root -GateReason 'r' -Handoff $h
'@
        $script = Join-Path $dir 'print.ps1'
        Set-Content -LiteralPath $script -Value $runner -Encoding utf8NoBOM
        $printed = (& (Get-PwshCommand) -NoProfile -File $script $dir $REPO_ROOT | Out-String).Trim()
        Assert-Result -Name 'command carries both artifacts' -Condition ($printed -match 'one file\.md' -and $printed -match 'two file\.md' -and $printed -match '-ReviewStrikeCount 2') -FailureMessage $printed
        $exec = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -Command ($printed + '; exit $LASTEXITCODE') }
        Assert-Result -Name 'printed command binds and reaches the row check (exit 2, not a binding failure)' -Condition ($exec.ExitCode -eq 2 -and $exec.Output -match 'no exact row for F-1') -FailureMessage ("exit " + $exec.ExitCode + ": " + $exec.Output)
    }

} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
if (@($results | Where-Object { -not $_ }).Count -gt 0) { exit 1 }
Write-Host "ALL TESTS PASSED ($($results.Count) tests)"
