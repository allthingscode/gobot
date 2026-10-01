# Tests that a commit in an implementation worktree created by -Init runs the git hooks.
# Item 155.
#
# -Init used to set a per-worktree core.hooksPath at scripts/hooks/architect. In an
# adopter that resolved to an empty directory it created in the project tree, and the
# intended directory held only a .ps1 git never runs, so no Crucible hook and no chained
# project hook ran in any implementation worktree: gobot B-017's Architect commit took
# about a second with no hook output. The old version of this test set the path itself
# and read it back, so it could not see that. Every case here makes a real commit in a
# worktree -Init created and checks which hooks actually ran.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/time.ps1")
Initialize-GitTestIsolation

$results = @()
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-LfFile {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), $script:utf8)
}

function Invoke-RepoGit {
    param([string]$Repo, [string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & git -C $Repo @GitArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ ExitCode = $code; Output = (@($out) -join "`n") }
}

# A worktree's .git is a file, so the records go under the worktree's own git dir.
$recordingPreCommit = @'
#!/bin/sh
echo "project pre-commit ran" > "$(git rev-parse --git-dir)/chain-pre-commit"
exit 0
'@
$recordingCommitMsg = @'
#!/bin/sh
echo "project commit-msg ran" > "$(git rev-parse --git-dir)/chain-commit-msg"
exit 0
'@

function Write-TaskFixture {
    param([string]$Root, [string]$TaskId)
    Write-LfFile -Path (Join-Path $Root ".crucible/backlog/chores/active/${TaskId}_Task.md") -Text (@(
        "---",
        "item_id: `"$TaskId`"",
        "priority: `"P3`"",
        "status: `"Ready`"",
        "target_phase: `"grooming`"",
        "budget_tier: `"low`"",
        "file_affinity: [`"src/$TaskId.txt`"]",
        "created_at: `"2026-09-30`"",
        "---",
        "# $TaskId",
        ""
    ) -join "`n")
    Write-LfFile -Path (Join-Path $Root ".crucible/backlog/BACKLOG.md") -Text (@(
        "# Backlog",
        "",
        "## Priority Summary",
        "| Priority | Count | Items |",
        "| --- | ---: | --- |",
        "| **P0** | 0 | - |",
        "| **P1** | 0 | - |",
        "| **P2** | 0 | - |",
        "| **P3** | 1 | $TaskId |",
        "",
        "## Active Items",
        "| ID | Title | Type | Priority | Status | Link |",
        "| --- | --- | --- | --- | --- | --- |",
        "| $TaskId | $TaskId | Chore | P3 | Ready | [Spec](chores/active/${TaskId}_Task.md) |",
        ""
    ) -join "`n")
}

function Write-GroomerHandoff {
    param([string]$Root, [string]$TaskId)
    $handoffDir = Join-Path $Root ".crucible/session/handoffs"
    New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
    $handoff = [ordered]@{
        task_id                  = $TaskId
        source_phase             = "grooming"
        target_phase             = "implementation"
        reason                   = "Ready for implementation"
        generated_by             = "new-handoff.ps1"
        tool_version             = "1.0.0"
        handoff_retry_count      = 0
        review_strike_count      = 0
        rebase_count             = 0
        budget_tier              = "low"
        cumulative_handoff_count = 2
        prompt_version           = "test-v1"
        session_cycle_id         = "test-cycle"
        cycle_id                 = "test-cycle"
        artifacts                = @(".crucible/backlog/chores/active/${TaskId}_Task.md")
        file_affinity            = @("src/$TaskId.txt")
    }
    $path = Join-Path $handoffDir ("${TaskId}-" + (Get-UtcFileTimestampMs) + ".json")
    [System.IO.File]::WriteAllText($path, ($handoff | ConvertTo-Json -Depth 10), $script:utf8)
}

function Invoke-ImplementationInit {
    param([string]$CrucibleScript, [string]$Root, [string]$TaskId)
    Write-GroomerHandoff -Root $Root -TaskId $TaskId
    $env:CRUCIBLE_CYCLE_ID = "test-cycle"
    $r = Invoke-ExternalCommand {
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CrucibleScript -Init -TaskId $TaskId -ProjectRoot $Root -Quiet
    }
    if ($r.ExitCode -ne 0) { throw ("-Init failed for " + $TaskId + ": " + ($r.Output -join "`n")) }
}

function Invoke-WorktreeCommit {
    param([string]$Worktree, [string]$Name)
    Write-LfFile -Path (Join-Path $Worktree "src/$Name.txt") -Text "$Name`n"
    $null = Invoke-RepoGit -Repo $Worktree -GitArgs @("add", "-A")
    return Invoke-RepoGit -Repo $Worktree -GitArgs @("commit", "-m", "worktree commit $Name")
}

function Get-WorktreeGitDir {
    param([string]$Worktree)
    $dir = (Invoke-RepoGit -Repo $Worktree -GitArgs @("rev-parse", "--absolute-git-dir")).Output.Trim()
    return $dir
}

$tempRoot = New-TestFixtureRoot -NameHint "impl-hooks"
$app = $null
$fw = $null
$adopterWorktrees = @()
$frameworkWorktrees = @()
try {
    # A real adopter: the bundle installed and committed, project hooks chained, as gobot.
    $app = Join-Path $tempRoot "app"
    New-Item -ItemType Directory -Path $app -Force | Out-Null
    & git init --quiet $app | Out-Null
    Write-LfFile -Path (Join-Path $app "README.md") -Text "# App`n"
    $null = Invoke-RepoGit -Repo $app -GitArgs @("add", "README.md")
    $null = Invoke-RepoGit -Repo $app -GitArgs @("commit", "--quiet", "-m", "initial")
    $init = Invoke-ExternalCommand {
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $REPO_ROOT "powershell/init-project.ps1") -ProjectRoot $app -ProjectName "App" -Quiet
    }
    if ($init.ExitCode -ne 0) { throw ("init-project failed: " + ($init.Output -join "`n")) }
    $configPath = Join-Path $app ".crucible/config.yaml"
    Write-LfFile -Path $configPath -Text ([System.IO.File]::ReadAllText($configPath).TrimEnd() + "`n`nhooks:`n  project_dir: scripts/hooks`n")
    Write-LfFile -Path (Join-Path $app "scripts/hooks/pre-commit") -Text $recordingPreCommit
    Write-LfFile -Path (Join-Path $app "scripts/hooks/commit-msg") -Text $recordingCommitMsg
    Write-TaskFixture -Root $app -TaskId "C-HK-A"
    $null = Invoke-RepoGit -Repo $app -GitArgs @("add", "-A")
    $base = Invoke-RepoGit -Repo $app -GitArgs @("commit", "--quiet", "-m", "install crucible")
    if ($base.ExitCode -ne 0) { throw ("baseline commit failed: " + $base.Output) }
    $adopterCrucible = Join-Path $app ".crucible/powershell/crucible.ps1"

    $results += Run-Test -Name "An adopter worktree -Init created runs Crucible's hooks and the chained project hooks" -Body {
        Invoke-ImplementationInit -CrucibleScript $adopterCrucible -Root $app -TaskId "C-HK-A"
        $wt = Join-Path $app ".crucible/.agent-workspaces/implementation-C-HK-A"
        $script:adopterWorktrees += $wt
        Assert-Result -Name "worktree exists" -Condition (Test-Path -LiteralPath $wt) -FailureMessage ("-Init did not create " + $wt)
        $c = Invoke-WorktreeCommit -Worktree $wt -Name "C-HK-A"
        Assert-Result -Name "commit succeeds" -Condition ($c.ExitCode -eq 0) -FailureMessage ("worktree commit failed: " + $c.Output)
        Assert-Result -Name "Crucible pre-commit ran" -Condition ($c.Output -match "Pre-commit: all verification tests passed") -FailureMessage ("no Crucible pre-commit output in the worktree commit: " + $c.Output)
        Assert-Result -Name "Crucible commit-msg ran" -Condition ($c.Output -match "Commit-msg: all verification tests passed") -FailureMessage ("no Crucible commit-msg output in the worktree commit: " + $c.Output)
        $gitDir = Get-WorktreeGitDir -Worktree $wt
        Assert-Result -Name "project pre-commit ran" -Condition (Test-Path -LiteralPath (Join-Path $gitDir "chain-pre-commit")) -FailureMessage ("the chained project pre-commit did not run: " + $c.Output)
        Assert-Result -Name "project commit-msg ran" -Condition (Test-Path -LiteralPath (Join-Path $gitDir "chain-commit-msg")) -FailureMessage ("the chained project commit-msg did not run: " + $c.Output)
        Assert-Result -Name "no scripts/hooks/architect in the project tree" -Condition (-not (Test-Path -LiteralPath (Join-Path $app "scripts/hooks/architect"))) -FailureMessage "-Init created scripts/hooks/architect in the adopter's project tree"
    }

    $results += Run-Test -Name "Re-running -Init clears a legacy architect override from an existing worktree" -Body {
        $wt = Join-Path $app ".crucible/.agent-workspaces/implementation-C-HK-A"
        $legacy = Join-Path $app "scripts/hooks/architect"
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        $null = Invoke-RepoGit -Repo $app -GitArgs @("config", "extensions.worktreeConfig", "true")
        $null = Invoke-RepoGit -Repo $wt -GitArgs @("config", "--worktree", "core.hooksPath", $legacy)
        $before = Invoke-WorktreeCommit -Worktree $wt -Name "legacy"
        Assert-Result -Name "the legacy override runs no hook" -Condition (($before.ExitCode -eq 0) -and ($before.Output -notmatch "Pre-commit: all verification")) -FailureMessage ("the fixture's legacy override did not reproduce the bug: " + $before.Output)

        Invoke-ImplementationInit -CrucibleScript $adopterCrucible -Root $app -TaskId "C-HK-A"
        $override = (Invoke-RepoGit -Repo $wt -GitArgs @("config", "--worktree", "--get", "core.hooksPath")).Output.Trim()
        Assert-Result -Name "override removed" -Condition ([string]::IsNullOrWhiteSpace($override)) -FailureMessage ("-Init left the per-worktree override: " + $override)
        $shared = (Invoke-RepoGit -Repo $app -GitArgs @("config", "--get", "core.hooksPath")).Output.Trim()
        Assert-Result -Name "shared hooksPath untouched" -Condition ($shared -eq ".crucible/scripts/hooks") -FailureMessage ("clearing the override changed the shared hooksPath to '" + $shared + "'")
        $after = Invoke-WorktreeCommit -Worktree $wt -Name "healed"
        Assert-Result -Name "hooks run again" -Condition (($after.ExitCode -eq 0) -and ($after.Output -match "Pre-commit: all verification tests passed")) -FailureMessage ("hooks still do not run after -Init: " + $after.Output)
        Remove-Item -LiteralPath $legacy -Recurse -Force
    }

    # The framework layout: a tracked scripts/hooks named by a relative core.hooksPath, the
    # source crucible.ps1 driving -Init. The real framework hooks build crucible_lint and
    # read the framework tree, so recording hooks stand in for them; what is under test is
    # that git runs the worktree's scripts/hooks, which is the same resolution either way.
# The hooks are committed without the executable bit, as a bundle committed on Windows
# records them, so on Linux this also covers -Init marking the worktree's copies
# executable: the first Linux leg after the fix failed here with git's "hook was ignored
# because it's not set as executable".
    $fw = Join-Path $tempRoot "fw"
    New-Item -ItemType Directory -Path $fw -Force | Out-Null
    & git init --quiet $fw | Out-Null
    Write-LfFile -Path (Join-Path $fw ".crucible/config.yaml") -Text (@(
        "project: FrameworkLayout",
        "paths:",
        "  backlog: .crucible/backlog",
        "  session: .crucible/session",
        "  workspaces: .crucible/.agent-workspaces",
        "  prompts: .crucible/prompts",
        ""
    ) -join "`n")
    Write-LfFile -Path (Join-Path $fw ".gitignore") -Text ".crucible/.agent-workspaces/`n.crucible/session/`n"
    Write-LfFile -Path (Join-Path $fw "scripts/hooks/pre-commit") -Text $recordingPreCommit
    Write-LfFile -Path (Join-Path $fw "scripts/hooks/commit-msg") -Text $recordingCommitMsg
    Write-TaskFixture -Root $fw -TaskId "C-HK-F"
    $null = Invoke-RepoGit -Repo $fw -GitArgs @("add", "-A")
    $fwBase = Invoke-RepoGit -Repo $fw -GitArgs @("commit", "--quiet", "-m", "framework layout")
    if ($fwBase.ExitCode -ne 0) { throw ("framework baseline commit failed: " + $fwBase.Output) }
    $null = Invoke-RepoGit -Repo $fw -GitArgs @("config", "core.hooksPath", "scripts/hooks")

    $results += Run-Test -Name "A framework-layout worktree -Init created runs its scripts/hooks" -Body {
        Invoke-ImplementationInit -CrucibleScript (Join-Path $REPO_ROOT "powershell/crucible.ps1") -Root $fw -TaskId "C-HK-F"
        $wt = Join-Path $fw ".crucible/.agent-workspaces/implementation-C-HK-F"
        $script:frameworkWorktrees += $wt
        $c = Invoke-WorktreeCommit -Worktree $wt -Name "C-HK-F"
        Assert-Result -Name "commit succeeds" -Condition ($c.ExitCode -eq 0) -FailureMessage ("worktree commit failed: " + $c.Output)
        $gitDir = Get-WorktreeGitDir -Worktree $wt
        Assert-Result -Name "pre-commit ran" -Condition (Test-Path -LiteralPath (Join-Path $gitDir "chain-pre-commit")) -FailureMessage ("scripts/hooks/pre-commit did not run in the worktree: " + $c.Output)
        Assert-Result -Name "commit-msg ran" -Condition (Test-Path -LiteralPath (Join-Path $gitDir "chain-commit-msg")) -FailureMessage ("scripts/hooks/commit-msg did not run in the worktree: " + $c.Output)
        Assert-Result -Name "no scripts/hooks/architect" -Condition (-not (Test-Path -LiteralPath (Join-Path $fw "scripts/hooks/architect"))) -FailureMessage "-Init created scripts/hooks/architect"
    }
}
finally {
    Remove-Item env:CRUCIBLE_CYCLE_ID -ErrorAction SilentlyContinue
    foreach ($pair in @(@($app, $adopterWorktrees), @($fw, $frameworkWorktrees))) {
        foreach ($wt in @($pair[1])) {
            if ($wt -and (Test-Path -LiteralPath $wt)) { $null = Invoke-RepoGit -Repo $pair[0] -GitArgs @("worktree", "remove", "--force", $wt) }
        }
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-TestFileSummary -Results $results
