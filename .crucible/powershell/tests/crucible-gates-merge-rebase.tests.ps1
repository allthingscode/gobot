# Tests for Invoke-HumanGateMerge: the accept-gate merge path must never leave the
# adopter repo mid-merge on conflict. A clean merge returns "merged"; a genuine
# same-line conflict aborts, leaves the tree clean, and routes the task back to
# implementation ("rework") with rebase_count bumped; the rebase_count backstop trips
# the recurring-conflict circuit breaker ("breaker").

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$Quiet = $true
. (Join-Path $REPO_ROOT "powershell/crucible-lib.ps1")

# PS 5.1 wraps native-command stderr (e.g. git's "Switched to a new branch") as an
# ErrorRecord; under 'Stop' that terminates. Assert-Result uses throw, which still
# surfaces regardless, so Continue is safe here.
$ErrorActionPreference = "Continue"

$results = @()

function New-MergeRepo {
    param([Parameter(Mandatory=$true)][string]$Root)
    $repo = Join-Path $Root "repo"
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    git -C $repo init --initial-branch=master 2>$null | Out-Null
    git -C $repo config user.name "Tester" 2>$null | Out-Null
    git -C $repo config user.email "test@example.com" 2>$null | Out-Null
    return $repo
}

function New-FakeHandoffScript {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$MarkerPath
    )
    $safeMarker = $MarkerPath.Replace("'", "''")
    @"
param(
    [string]`$TaskId,
    [string]`$Source,
    [string]`$Target,
    [string]`$Reason,
    [int]`$RebaseCount = -1,
    [string]`$ProjectRoot = "",
    [string]`$SessionCycleId = "",
    [string[]]`$Artifacts = @()
)
[System.IO.File]::WriteAllText('$safeMarker', "Target=`$Target;RebaseCount=`$RebaseCount")
"@ | Set-Content -LiteralPath $Path -Encoding UTF8
}

# Item 267: every merge is handed the record Write-HumanGateDecision wrote for it.
function New-DecisionRecord {
    param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$TaskId)
    $dir = Join-Path $Root "session/global/gate_decisions"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir ($TaskId + "-20260902T120000Z.json")
    ('{"task_id":"' + $TaskId + '","outcome":"accepted"}') | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

# Silence event-log side effects; the merge helper only cares about control flow here.
function Write-EventLog { param([Parameter(ValueFromRemainingArguments=$true)]$Rest) }
function Write-BlockedTaskRecord {
    [CmdletBinding()]
    param([string]$ProjectRoot, [string]$BacklogDir, [string]$FrameworkPowerShell,
          [string]$TaskId, [string]$CircuitBreaker, [int]$AttemptCount,
          [string]$LastSpecialist, [string]$Summary)
    $script:blockedCalls++
    Assert-Result 'breaker project root' ($ProjectRoot -eq $repo) "wrong project root: $ProjectRoot"
    Assert-Result 'breaker backlog' ($BacklogDir -eq (Get-ConfiguredPath -Key backlog -ProjectRoot $ProjectRoot)) "wrong backlog: $BacklogDir"
    Assert-Result 'breaker framework' ($FrameworkPowerShell -eq (Join-Path $REPO_ROOT 'powershell')) "wrong framework: $FrameworkPowerShell"
    Assert-Result 'breaker task' ($TaskId -eq $expectedBlockedTaskId) "wrong task: $TaskId"
    Assert-Result 'breaker metadata' ($CircuitBreaker -eq 'recurring_merge_conflicts' -and $AttemptCount -eq 3 -and $LastSpecialist -eq 'deployment' -and $Summary -eq 'Recurring Merge Conflicts at human gate. Manual conflict resolution required.') 'wrong blocked metadata'
}

$results += Run-Test "Clean merge returns 'merged' and lands the branch" {
    $root = New-TestFixtureRoot -NameHint "mr-a"
    try {
        $repo = New-MergeRepo -Root $root
        "base" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "base" 2>$null | Out-Null

        git -C $repo checkout -b "task/T-001" 2>$null | Out-Null
        "feature body" | Set-Content -LiteralPath (Join-Path $repo "feature.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "feature" 2>$null | Out-Null
        git -C $repo checkout master 2>$null | Out-Null

        Push-Location $repo
        try {
            $record = New-DecisionRecord -Root $root -TaskId "T-001"
            $result = Invoke-HumanGateMerge -DecisionRecordPath $record -TaskId "T-001" -PrimaryBranch "master" -ProjectRoot $repo -Handoff $null `
                -LogFile (Join-Path $repo "pipeline.log.jsonl") -CircuitBreakerHistoryFile (Join-Path $repo "circuit_breakers.jsonl")
        } finally { Pop-Location }

        Assert-Result "clean-merge-result" ($result -eq "merged") "Expected 'merged', got '$result'"
        Assert-Result "feature-present" (Test-Path (Join-Path $repo "feature.md")) "feature.md should be merged into master"
        Assert-Result "no-merge-head" (-not (Test-Path (Join-Path $repo ".git/MERGE_HEAD"))) "master left mid-merge after a clean merge"
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$results += Run-Test "Same-line conflict routes to 'rework', leaves tree clean, bumps rebase_count" {
    $root = New-TestFixtureRoot -NameHint "mr-b"
    try {
        $repo = New-MergeRepo -Root $root
        "line0" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "base" 2>$null | Out-Null

        git -C $repo checkout -b "task/T-002" 2>$null | Out-Null
        "AAA" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "task change" 2>$null | Out-Null
        git -C $repo checkout master 2>$null | Out-Null
        "BBB" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "primary change" 2>$null | Out-Null

        $wtPath = Join-Path $root "wt-T-002"
        git -C $repo worktree add $wtPath "task/T-002" 2>$null | Out-Null

        $marker = Join-Path $root "handoff-marker.txt"
        $fakeHandoff = Join-Path $root "fake-new-handoff.ps1"
        New-FakeHandoffScript -Path $fakeHandoff -MarkerPath $marker

        function Get-ConfiguredPath { param($Key, $ProjectRoot) return (Split-Path -Parent $wtPath) }
        function Resolve-ImplementationWorktreePath { param($TaskId, $WorkspacesDir) return $wtPath }

        $handoff = [PSCustomObject]@{ rebase_count = 0; cycle_id = "initial"; artifacts = @() }

        Push-Location $repo
        try {
            $record = New-DecisionRecord -Root $root -TaskId "T-002"
            $result = Invoke-HumanGateMerge -DecisionRecordPath $record -TaskId "T-002" -PrimaryBranch "master" -ProjectRoot $repo -Handoff $handoff -HandoffScript $fakeHandoff `
                -LogFile (Join-Path $repo "pipeline.log.jsonl") -CircuitBreakerHistoryFile (Join-Path $repo "circuit_breakers.jsonl")
        } finally { Pop-Location }

        Assert-Result "conflict-result" ($result -eq "rework") "Expected 'rework', got '$result'"
        Assert-Result "no-merge-head" (-not (Test-Path (Join-Path $repo ".git/MERGE_HEAD"))) "master left mid-merge after conflict (the original bug)"
        $readme = Get-Content -LiteralPath (Join-Path $repo "README.md") -Raw
        Assert-Result "primary-preserved" ($readme.Trim() -eq "BBB") "master README should be restored to 'BBB', got '$($readme.Trim())'"
        Assert-Result "no-conflict-markers" ($readme -notmatch '<<<<<<<') "master README still contains conflict markers"
        $status = @(Invoke-ExternalCommand -AsLines { git -C $repo status --porcelain })
        Assert-Result "worktree-clean" ($status.Count -eq 0) "master working tree not clean: $($status -join ',')"
        Assert-Result "branch-intact" (& { Invoke-ExternalCommand -AsLines { git -C $repo show-ref --quiet "refs/heads/task/T-002" }; $LASTEXITCODE -eq 0 }) "task/T-002 branch was lost"
        Assert-Result "handoff-written" (Test-Path $marker) "re-entry handoff was not generated"
        $markerText = Get-Content -LiteralPath $marker -Raw
        Assert-Result "handoff-target" ($markerText -match 'Target=implementation') "handoff did not target implementation: $markerText"
        Assert-Result "rebase-bumped" ($markerText -match 'RebaseCount=1') "rebase_count not bumped to 1: $markerText"
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$results += Run-Test "rebase_count backstop trips the recurring-conflict breaker" {
    $expectedBlockedTaskId = 'T-003'
    $script:blockedCalls = 0
    $root = New-TestFixtureRoot -NameHint "mr-c"
    try {
        $repo = New-MergeRepo -Root $root
        "line0" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "base" 2>$null | Out-Null

        git -C $repo checkout -b "task/T-003" 2>$null | Out-Null
        "AAA" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "task change" 2>$null | Out-Null
        git -C $repo checkout master 2>$null | Out-Null
        "BBB" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "primary change" 2>$null | Out-Null

        $handoff = [PSCustomObject]@{ rebase_count = 3 }

        Push-Location $repo
        try {
            $record = New-DecisionRecord -Root $root -TaskId "T-003"
            $result = Invoke-HumanGateMerge -DecisionRecordPath $record -TaskId "T-003" -PrimaryBranch "master" -ProjectRoot $repo -Handoff $handoff -MaxRebaseAttempts 3 `
                -LogFile (Join-Path $repo "pipeline.log.jsonl") -CircuitBreakerHistoryFile (Join-Path $repo "circuit_breakers.jsonl")
        } finally { Pop-Location }

        Assert-Result "breaker writer called once" ($script:blockedCalls -eq 1) "blocked writer was skipped or repeated"
        Assert-Result "breaker-result" ($result -eq "breaker") "Expected 'breaker', got '$result'"
        Assert-Result "no-merge-head" (-not (Test-Path (Join-Path $repo ".git/MERGE_HEAD"))) "master left mid-merge after breaker"
        $status = @(Invoke-ExternalCommand -AsLines { git -C $repo status --porcelain })
        Assert-Result "worktree-clean" ($status.Count -eq 0) "master working tree not clean after breaker: $($status -join ',')"
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$results += Run-Test "D40: accepted-decision removal failure stops before stale approval can be honored" {
    $root = New-TestFixtureRoot -NameHint "mr-d40"
    try {
        $repo = New-MergeRepo -Root $root
        "base" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "base" 2>$null | Out-Null

        git -C $repo checkout -b "task/T-040" 2>$null | Out-Null
        "task" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "task change" 2>$null | Out-Null
        git -C $repo checkout master 2>$null | Out-Null
        "primary" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "primary change" 2>$null | Out-Null

        $decisionRoot = Join-Path $root "session"
        $decisionDir = Join-Path $decisionRoot "global/gate_decisions"
        New-Item -ItemType Directory -Path $decisionDir -Force | Out-Null
        $acceptedPath = Join-Path $decisionDir "T-040-20260902T120000Z.json"
        '{"task_id":"T-040","outcome":"accepted"}' | Set-Content -LiteralPath $acceptedPath -Encoding UTF8

        # Force the delete itself to fail. A shared-read file handle denies delete
        # sharing on Windows, but Linux unlink() is unaffected by an open handle, so
        # that trick cannot reproduce the failure cross-platform. Shadow Remove-Item
        # instead: deterministic on every OS. The refusal must be an exit (I11), so
        # the merge runs in a child process inside a caller's catch and next statement.
        $runner = Join-Path $root "d40-refusal.ps1"
        @'
param($Lib, $Repo, $Record)
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
$Quiet = $true
. $Lib
function Write-EventLog {}
function Write-BlockedTaskRecord {}
function Remove-Item {
    param(
        [Parameter(Position = 0)][string]$Path,
        [string]$LiteralPath,
        [switch]$Force,
        [switch]$Recurse
    )
    $target = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($target -eq $Record) {
        throw [System.UnauthorizedAccessException]::new("Access to the path '$target' is denied.")
    }
    $callParams = @{}
    if ($LiteralPath) { $callParams["LiteralPath"] = $LiteralPath }
    if ($Path) { $callParams["Path"] = $Path }
    if ($Force) { $callParams["Force"] = $true }
    if ($Recurse) { $callParams["Recurse"] = $true }
    if ($PSBoundParameters.ContainsKey("ErrorAction")) { $callParams["ErrorAction"] = $PSBoundParameters["ErrorAction"] }
    Microsoft.PowerShell.Management\Remove-Item @callParams
}
Set-Location -LiteralPath $Repo
try {
    $result = Invoke-HumanGateMerge -DecisionRecordPath $Record -TaskId 'T-040' -PrimaryBranch 'master' -ProjectRoot $Repo `
        -Handoff ([pscustomobject]@{ rebase_count = 3 }) -MaxRebaseAttempts 3 `
        -LogFile (Join-Path $Repo 'pipeline.log.jsonl') -CircuitBreakerHistoryFile (Join-Path $Repo 'circuit_breakers.jsonl')
    Write-Host "CALLER_RESULT=$result"
} catch { Write-Host 'CALLER_CAUGHT_REFUSAL' }
Write-Host 'CALLER_CONTINUED'
exit 0
'@ | Set-Content -LiteralPath $runner -Encoding UTF8
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $runner (Join-Path $REPO_ROOT "powershell/crucible-lib.ps1") $repo $acceptedPath }
        $text = $run.Output -join "`n"

        Assert-Result "accepted-cleanup-failure-exits" ($run.ExitCode -ne 0 -and $text -notmatch 'CALLER_RESULT|CALLER_CAUGHT_REFUSAL|CALLER_CONTINUED') ("exit " + $run.ExitCode + ": " + $text)
        Assert-Result "accepted-cleanup-failure-is-honest" ($text -match "Could not inspect or remove premature accepted gate decisions" -and $text -match "is denied") ("expected an honest cleanup failure, got: " + $text)
        Assert-Result "accepted-cleanup-failure-names-surviving-record" ((Test-Path -LiteralPath $acceptedPath) -and $text -match "still in place") $text
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$results += Run-Test "Conflict path survives ErrorActionPreference=Stop (git rebase stderr)" {
    $root = New-TestFixtureRoot -NameHint "mr-d"
    try {
        $repo = New-MergeRepo -Root $root
        "line0" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "base" 2>$null | Out-Null
        git -C $repo checkout -b "task/T-004" 2>$null | Out-Null
        "AAA" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "task change" 2>$null | Out-Null
        git -C $repo checkout master 2>$null | Out-Null
        "BBB" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
        git -C $repo add . 2>$null | Out-Null
        git -C $repo commit -m "primary change" 2>$null | Out-Null

        $wtPath = Join-Path $root "wt-T-004"
        git -C $repo worktree add $wtPath "task/T-004" 2>$null | Out-Null

        $marker = Join-Path $root "handoff-marker.txt"
        $fakeHandoff = Join-Path $root "fake-new-handoff.ps1"
        New-FakeHandoffScript -Path $fakeHandoff -MarkerPath $marker

        function Get-ConfiguredPath { param($Key, $ProjectRoot) return (Split-Path -Parent $wtPath) }
        function Resolve-ImplementationWorktreePath { param($TaskId, $WorkspacesDir) return $wtPath }

        $handoff = [PSCustomObject]@{ rebase_count = 0 }

        # Reproduce the production condition: Crucible runs under 'Stop', where
        # PS 5.1 turns git's stderr into a terminating error unless guarded.
        Push-Location $repo
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Stop"
        try {
            $record = New-DecisionRecord -Root $root -TaskId "T-004"
            $result = Invoke-HumanGateMerge -DecisionRecordPath $record -TaskId "T-004" -PrimaryBranch "master" -ProjectRoot $repo -Handoff $handoff -HandoffScript $fakeHandoff `
                -LogFile (Join-Path $repo "pipeline.log.jsonl") -CircuitBreakerHistoryFile (Join-Path $repo "circuit_breakers.jsonl")
        } finally {
            $ErrorActionPreference = $prev
            Pop-Location
        }

        Assert-Result "stop-result" ($result -eq "rework") "Expected 'rework' under Stop, got '$result'"
        Assert-Result "wt-not-mid-rebase" (-not (Test-Path (Join-Path $repo ".git/worktrees/wt-T-004/rebase-merge"))) "worktree left mid-rebase under Stop"
        $status = @(Invoke-ExternalCommand -AsLines { git -C $repo status --porcelain })
        Assert-Result "primary-clean" ($status.Count -eq 0) "master not clean under Stop: $($status -join ',')"
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

function New-BreakerRepo {
    param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$TaskId)
    $repo = New-MergeRepo -Root $Root
    "base" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
    git -C $repo add . 2>$null | Out-Null
    git -C $repo commit -m "base" 2>$null | Out-Null
    git -C $repo checkout -b "task/$TaskId" 2>$null | Out-Null
    "task" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
    git -C $repo add . 2>$null | Out-Null
    git -C $repo commit -m "task change" 2>$null | Out-Null
    git -C $repo checkout master 2>$null | Out-Null
    "primary" | Set-Content -LiteralPath (Join-Path $repo "README.md") -Encoding UTF8
    git -C $repo add . 2>$null | Out-Null
    git -C $repo commit -m "primary change" 2>$null | Out-Null
    return $repo
}

function Invoke-BreakerMerge {
    param([string]$Repo, [string]$TaskId, [string]$DecisionRecordPath)
    $expectedBlockedTaskId = $TaskId
    $script:blockedCalls = 0
    $outcome = @{ Result = ""; Error = $null }
    Push-Location $Repo
    try {
        $outcome.Result = Invoke-HumanGateMerge -DecisionRecordPath $DecisionRecordPath -TaskId $TaskId -PrimaryBranch "master" -ProjectRoot $Repo `
            -Handoff ([PSCustomObject]@{ rebase_count = 3 }) -MaxRebaseAttempts 3 `
            -LogFile (Join-Path $Repo "pipeline.log.jsonl") -CircuitBreakerHistoryFile (Join-Path $Repo "circuit_breakers.jsonl")
    } catch {
        $outcome.Error = $_.Exception.Message
    } finally {
        Pop-Location
    }
    return $outcome
}

# Item 267: the undo used to delete the newest accepted or redirected record by
# LastWriteTime, in any cycle. A prior cycle's record whose mtime is newer (a restore,
# a sync, an edit) was the one removed, and the current authorization survived.
$results += Run-Test "Merge undo removes only the record this gate wrote, never a prior cycle's (I8)" {
    $root = New-TestFixtureRoot -NameHint "mr-267"
    try {
        $repo = New-BreakerRepo -Root $root -TaskId "T-267"
        $sessionDir = Join-Path $root "session"
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $priorPath = Join-Path $gateDir "T-267-20260101T000000Z.json"
        '{"task_id":"T-267","outcome":"accepted","session_cycle_id":"cycle-prior"}' | Set-Content -LiteralPath $priorPath -Encoding UTF8
        $priorBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($priorPath))

        $ctx = @{ SessionDir = $sessionDir; Handoff = [pscustomobject]@{ task_id = "T-267"; source_phase = "deployment" } }
        $decision = [pscustomobject]@{ outcome = "accepted"; reason = "Reviewed the conflicting change by hand" }
        $currentPath = Write-HumanGateDecision -Context $ctx -Decision $decision -ProjectRoot $repo -SessionCycleId "cycle-current"
        Assert-Result "writer-returns-its-record" (-not [string]::IsNullOrEmpty($currentPath) -and (Test-Path -LiteralPath $currentPath) -and $currentPath -ne $priorPath) "Write-HumanGateDecision returned '$currentPath'"
        (Get-Item -LiteralPath $priorPath).LastWriteTime = (Get-Date).AddHours(1)

        $run = Invoke-BreakerMerge -Repo $repo -TaskId "T-267" -DecisionRecordPath $currentPath

        Assert-Result "breaker writer called once" ($script:blockedCalls -eq 1) "blocked writer was skipped or repeated"
        Assert-Result "breaker-result" ($run.Result -eq "breaker" -and $null -eq $run.Error) "Expected 'breaker', got '$($run.Result)' error '$($run.Error)'"
        Assert-Result "prior-cycle-record-intact" ((Test-Path -LiteralPath $priorPath) -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($priorPath)) -ceq $priorBytes) "the prior cycle's accepted record was removed or changed"
        Assert-Result "current-record-removed" (-not (Test-Path -LiteralPath $currentPath)) "the current cycle's premature accept survived the incomplete merge"
        $remaining = @(Get-ChildItem -LiteralPath $gateDir -Filter "T-267-*.json")
        Assert-Result "only-current-record-removed" ($remaining.Count -eq 1 -and $remaining[0].FullName -eq (Get-Item -LiteralPath $priorPath).FullName) ("remaining: " + (($remaining | ForEach-Object Name) -join ","))
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$results += Run-Test "Merge undo refuses when the record this gate wrote is absent or not this task's (I11)" {
    $root = New-TestFixtureRoot -NameHint "mr-267-absent"
    try {
        $repo = New-BreakerRepo -Root $root -TaskId "T-268"
        $gateDir = Join-Path $root "session/global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
        $priorPath = Join-Path $gateDir "T-268-20260101T000000Z.json"
        '{"task_id":"T-268","outcome":"accepted","session_cycle_id":"cycle-prior"}' | Set-Content -LiteralPath $priorPath -Encoding UTF8
        $otherPath = Join-Path $gateDir "T-999-20260101T000000Z.json"
        '{"task_id":"T-999","outcome":"accepted"}' | Set-Content -LiteralPath $otherPath -Encoding UTF8

        # A refusal must be an exit (I11): an embedding caller's catch and its next
        # statement must not run, so the merge runs in a child process.
        $runner = Join-Path $root "undo-refusal.ps1"
        @'
param($Lib, $Repo, $Record, $Mode = '')
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
$Quiet = $true
. $Lib
function Write-EventLog { Write-Host 'BREAKER_EVENT' }
function Write-BlockedTaskRecord {}
if ($Mode -eq 'missing-blocked') {
    Remove-Item Function:Write-BlockedTaskRecord
    function Remove-Item { param($LiteralPath, [switch]$Force) Write-Host 'ACCEPT_CLEANUP'; Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Force:$Force }
}
if ($Mode -eq 'missing-host') { function Get-RunningPowerShellCommand { throw 'injected no pwsh host' } }
if ($Mode -eq 'probe-fails') {
    # The record's existence probe raises (an access or I/O error under Stop).
    function Test-Path {
        [CmdletBinding()]
        param([string]$LiteralPath, [string]$Path, [string]$PathType)
        if ($LiteralPath -eq $Record) { throw [System.IO.IOException]::new("injected probe failure on '$LiteralPath'") }
        $forward = @{}
        foreach ($name in @('LiteralPath', 'Path', 'PathType')) { if ($PSBoundParameters.ContainsKey($name)) { $forward[$name] = $PSBoundParameters[$name] } }
        Microsoft.PowerShell.Management\Test-Path @forward
    }
}
Set-Location -LiteralPath $Repo
try {
    $result = Invoke-HumanGateMerge -DecisionRecordPath $Record -TaskId 'T-268' -PrimaryBranch 'master' -ProjectRoot $Repo `
        -Handoff ([pscustomobject]@{ rebase_count = 3 }) -MaxRebaseAttempts 3 `
        -LogFile (Join-Path $Repo 'pipeline.log.jsonl') -CircuitBreakerHistoryFile (Join-Path $Repo 'circuit_breakers.jsonl')
    Write-Host "CALLER_RESULT=$result"
} catch { Write-Host 'CALLER_CAUGHT_REFUSAL' }
Write-Host 'CALLER_CONTINUED'
exit 0
'@ | Set-Content -LiteralPath $runner -Encoding UTF8
        $lib = Join-Path $REPO_ROOT "powershell/crucible-lib.ps1"

        $missingRecord = Join-Path $gateDir 'T-268-missing-helper.json'
        '{"task_id":"T-268","outcome":"accepted"}' | Set-Content -LiteralPath $missingRecord
        $missing = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $runner $lib $repo $missingRecord 'missing-blocked' }
        $missingText = (($missing.Output -join "`n") -replace '(?m)^\s*\|\s?', '' -replace '\s+', ' ')
        Assert-Result 'missing blocked helper refuses unconditionally' ($missing.ExitCode -eq 2 -and $missingText -match 'Write-BlockedTaskRecord is unavailable' -and $missing.Output -notmatch 'CALLER_RESULT|CALLER_CAUGHT_REFUSAL|CALLER_CONTINUED') $missing.Output

        Assert-Result 'missing helper refuses before breaker event and cleans before diagnostic' ($missingText -notmatch 'BREAKER_EVENT' -and $missingText -match 'ACCEPT_CLEANUP.*Write-BlockedTaskRecord is unavailable') $missingText
        Assert-Result 'missing helper removes accepted record' (-not (Test-Path -LiteralPath $missingRecord)) 'premature approval blocks retry'

        $hostRecord = New-DecisionRecord -Root $root -TaskId 'T-268'
        $hostRepo = New-MergeRepo -Root (Join-Path $root 'no-host')
        [IO.File]::WriteAllText((Join-Path $hostRepo 'base.txt'), 'base')
        git -C $hostRepo add .
        git -C $hostRepo commit -qm base
        git -C $hostRepo checkout -qb task/T-268
        [IO.File]::WriteAllText((Join-Path $hostRepo 'feature.txt'), 'feature')
        git -C $hostRepo add .
        git -C $hostRepo commit -qm feature
        git -C $hostRepo checkout -q master
        $before = (Invoke-ExternalCommand -AsLines { git -C $hostRepo rev-parse HEAD }).Trim()
        $noHost = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $runner $lib $hostRepo $hostRecord 'missing-host' }
        $hostText = (($noHost.Output -join "`n") -replace '(?m)^\s*\|\s?', '' -replace '\s+', ' ')
        $after = (Invoke-ExternalCommand -AsLines { git -C $hostRepo rev-parse HEAD }).Trim()
        Assert-Result 'missing host removes accepted record' (-not (Test-Path -LiteralPath $hostRecord)) 'premature approval blocks retry'
        Assert-Result 'missing host refuses before merge or breaker event' ($noHost.ExitCode -eq 2 -and $hostText -match 'injected no pwsh host' -and $hostText -notmatch 'BREAKER_EVENT|CALLER_RESULT|CALLER_CAUGHT_REFUSAL|CALLER_CONTINUED' -and $after -eq $before) $hostText

        $absent = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $runner $lib $repo (Join-Path $gateDir "T-268-20260902T120000Z.json") }
        $absentText = $absent.Output -join "`n"
        Assert-Result "absent-record-refusal-exits" ($absent.ExitCode -ne 0 -and $absentText -notmatch 'CALLER_RESULT|CALLER_CAUGHT_REFUSAL|CALLER_CONTINUED') ("exit " + $absent.ExitCode + ": " + $absentText)
        Assert-Result "absent-record-refusal-names-record" ($absentText -match "is absent") $absentText
        Assert-Result "absent-record-spares-prior" (Test-Path -LiteralPath $priorPath) "an absent current record let the undo remove the prior cycle's record"

        $foreign = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $runner $lib $repo $otherPath }
        $foreignText = $foreign.Output -join "`n"
        Assert-Result "foreign-record-refusal-exits" ($foreign.ExitCode -ne 0 -and $foreignText -notmatch 'CALLER_RESULT|CALLER_CAUGHT_REFUSAL|CALLER_CONTINUED') ("exit " + $foreign.ExitCode + ": " + $foreignText)
        Assert-Result "foreign-record-refusal-names-task" ($foreignText -match "not a gate decision for T-268") $foreignText
        Assert-Result "foreign-record-kept" ((Test-Path -LiteralPath $otherPath) -and (Test-Path -LiteralPath $priorPath)) "a record for another task was removed"

        $currentPath = Join-Path $gateDir "T-268-20260902T120000Z.json"
        '{"task_id":"T-268","outcome":"accepted","session_cycle_id":"cycle-current"}' | Set-Content -LiteralPath $currentPath -Encoding UTF8
        $probe = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $runner $lib $repo $currentPath 'probe-fails' }
        $probeText = $probe.Output -join "`n"
        Assert-Result "probe-failure-refusal-exits" ($probe.ExitCode -ne 0 -and $probeText -notmatch 'CALLER_RESULT|CALLER_CAUGHT_REFUSAL|CALLER_CONTINUED') ("exit " + $probe.ExitCode + ": " + $probeText)
        Assert-Result "probe-failure-refusal-names-cause" ($probeText -match "could not be inspected" -and $probeText -match "injected probe failure") $probeText
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$passed = @($results | Where-Object { $_ }).Count
$total = $results.Count
Write-Host ("`n[crucible-gates-merge-rebase] {0}/{1} passed" -f $passed, $total) -ForegroundColor Cyan
if ($passed -ne $total) { exit 1 }
