# Tests for Invoke-HumanGateMerge: the accept-gate merge path must never leave the
# adopter repo mid-merge on conflict. A clean merge returns "merged"; a genuine
# same-line conflict aborts, leaves the tree clean, and routes the task back to
# implementation ("rework") with rebase_count bumped; the rebase_count backstop trips
# the recurring-conflict circuit breaker ("breaker").

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$Quiet = $true
. (Join-Path $REPO_ROOT "powershell/factory-lib.ps1")

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

# Silence event-log side effects; the merge helper only cares about control flow here.
function Write-EventLog { param([Parameter(ValueFromRemainingArguments=$true)]$Rest) }
function Write-BlockedTaskRecord { param([Parameter(ValueFromRemainingArguments=$true)]$Rest) }

$results += Run-Test "Clean merge returns 'merged' and lands the branch" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mr_a_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
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
            $result = Invoke-HumanGateMerge -TaskId "T-001" -PrimaryBranch "master" -ProjectRoot $repo -Handoff $null
        } finally { Pop-Location }

        Assert-Result "clean-merge-result" ($result -eq "merged") "Expected 'merged', got '$result'"
        Assert-Result "feature-present" (Test-Path (Join-Path $repo "feature.md")) "feature.md should be merged into master"
        Assert-Result "no-merge-head" (-not (Test-Path (Join-Path $repo ".git/MERGE_HEAD"))) "master left mid-merge after a clean merge"
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$results += Run-Test "Same-line conflict routes to 'rework', leaves tree clean, bumps rebase_count" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mr_b_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
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
            $result = Invoke-HumanGateMerge -TaskId "T-002" -PrimaryBranch "master" -ProjectRoot $repo -Handoff $handoff -HandoffScript $fakeHandoff
        } finally { Pop-Location }

        Assert-Result "conflict-result" ($result -eq "rework") "Expected 'rework', got '$result'"
        Assert-Result "no-merge-head" (-not (Test-Path (Join-Path $repo ".git/MERGE_HEAD"))) "master left mid-merge after conflict (the original bug)"
        $readme = Get-Content -LiteralPath (Join-Path $repo "README.md") -Raw
        Assert-Result "primary-preserved" ($readme.Trim() -eq "BBB") "master README should be restored to 'BBB', got '$($readme.Trim())'"
        Assert-Result "no-conflict-markers" ($readme -notmatch '<<<<<<<') "master README still contains conflict markers"
        $status = @(git -C $repo status --porcelain)
        Assert-Result "worktree-clean" ($status.Count -eq 0) "master working tree not clean: $($status -join ',')"
        Assert-Result "branch-intact" (& { git -C $repo show-ref --quiet "refs/heads/task/T-002"; $LASTEXITCODE -eq 0 }) "task/T-002 branch was lost"
        Assert-Result "handoff-written" (Test-Path $marker) "re-entry handoff was not generated"
        $markerText = Get-Content -LiteralPath $marker -Raw
        Assert-Result "handoff-target" ($markerText -match 'Target=implementation') "handoff did not target implementation: $markerText"
        Assert-Result "rebase-bumped" ($markerText -match 'RebaseCount=1') "rebase_count not bumped to 1: $markerText"
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$results += Run-Test "rebase_count backstop trips the recurring-conflict breaker" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mr_c_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
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
            $result = Invoke-HumanGateMerge -TaskId "T-003" -PrimaryBranch "master" -ProjectRoot $repo -Handoff $handoff -MaxRebaseAttempts 3
        } finally { Pop-Location }

        Assert-Result "breaker-result" ($result -eq "breaker") "Expected 'breaker', got '$result'"
        Assert-Result "no-merge-head" (-not (Test-Path (Join-Path $repo ".git/MERGE_HEAD"))) "master left mid-merge after breaker"
        $status = @(git -C $repo status --porcelain)
        Assert-Result "worktree-clean" ($status.Count -eq 0) "master working tree not clean after breaker: $($status -join ',')"
    } finally {
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

$passed = @($results | Where-Object { $_ }).Count
$total = $results.Count
Write-Host ("`n[factory-gates-merge-rebase] {0}/{1} passed" -f $passed, $total) -ForegroundColor Cyan
if ($passed -ne $total) { exit 1 }
