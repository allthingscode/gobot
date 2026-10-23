# Item 250: rejection must ask I8's row owner before generating a rework handoff.
$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/platform.ps1')
$results = @()
$root = New-TestFixtureRoot -NameHint 'human-gate-rework'
try {
    foreach ($case in @('prefix', 'mention', 'missing', 'read-error', 'plain', 'linked')) {
        $results += Run-Test -Name "Rework exact backlog ID: $case" -Body {
            $dir = Join-Path $root $case
            $lib = Join-Path $dir 'powershell/lib'
            New-Item -ItemType Directory -Path $lib -Force | Out-Null
            Copy-Item -Path (Join-Path $REPO_ROOT 'powershell/lib/*.ps1') -Destination $lib
            $row = switch ($case) {
                'prefix' { '| F-10 | In Progress | Other task |' }
                'mention' { '| F-20 | In Progress | Replaces F-1 |' }
                'plain' { '| F-1 | In Progress | Task |' }
                'linked' { '| [F-1](features/active/F-1_task.md) | In Progress | Task |' }
            }
            if ($case -ne 'missing') {
                @('# F-1 rework', '| ID | Status | Title |', '|---|---|---|', $row) |
                    Set-Content -LiteralPath (Join-Path $dir 'BACKLOG.md') -Encoding utf8NoBOM
            }
            # Isolate the dispatch boundary: git unwind/restore are covered by the human
            # gate suite, and the generator records whether it was called at all.
            'Set-Content -LiteralPath (Join-Path $PSScriptRoot "../generated.txt") -Value ($args -join " ")' |
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
if ($Case -eq 'read-error') {
    $ErrorActionPreference = 'Continue'
    function Get-Content {
        [CmdletBinding()]
        param($LiteralPath, $Encoding)
        Write-Error 'injected backlog read error'
    }
}
try {
    Invoke-HumanGateRejectAbandon -TaskId F-1 -Outcome rejected -ProjectRoot $Root -PrimaryBranch main -GateReason 'rework'
} catch { Write-Host "Caller caught: $_" }
Write-Host 'CALLER_CONTINUED'
exit 0
'@
            $script = Join-Path $dir 'run.ps1'
            Set-Content -LiteralPath $script -Value $runner -Encoding utf8NoBOM
            $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $script $dir $REPO_ROOT $case }
            if ($case -eq 'read-error') {
                Assert-Result -Name 'read error is diagnosed under Continue preference' -Condition ($run.Output -match 'Cannot read backlog for rework of F-1:.*injected backlog read error' -and $run.Output -notmatch 'no exact ID row') -FailureMessage $run.Output
            }
            $present = $case -in @('plain', 'linked')
            Assert-Result -Name "$case handoff dispatch matches exact ID cell" -Condition ((Test-Path (Join-Path $dir 'generated.txt')) -eq $present) -FailureMessage $run.Output
            Assert-Result -Name "$case refusal cannot become caller success" -Condition (($run.ExitCode -eq 0) -eq $present) -FailureMessage $run.Output
            if ($case -eq 'missing') {
                Assert-Result -Name 'missing refusal names absent backlog file' -Condition ($run.Output -match 'Backlog file .* is missing' -and $run.Output -notmatch 'no exact ID row|CALLER_CONTINUED') -FailureMessage $run.Output
            } elseif (-not $present -and $case -ne 'read-error') {
                Assert-Result -Name "$case refusal names missing exact row" -Condition ($run.Output -match 'F-1 has no exact ID row' -and $run.Output -notmatch 'CALLER_CONTINUED') -FailureMessage $run.Output
            }
        }
    }
    foreach ($case in @('prefix', 'missing', 'read-error', 'active-spec', 'archived-spec')) {
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
            $pending = Join-Path $dir 'pending.json'
            '{"outcome":"rejected","reason":"Needs a concrete correction"}' |
                Set-Content -LiteralPath $pending -Encoding utf8NoBOM
            $pendingBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pending))
            $backlogBytes = if (Test-Path $backlog) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($backlog)) } else { '' }
            'Set-Content -LiteralPath (Join-Path $PSScriptRoot "../generated.txt") -Value generated' |
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
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
if (@($results | Where-Object { -not $_ }).Count -gt 0) { exit 1 }
Write-Host "ALL TESTS PASSED ($($results.Count) tests)"
