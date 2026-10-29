# Tests for shared worktree and scope helpers.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$CRUCIBLE_LIB = Join-Path $REPO_ROOT "powershell/crucible-lib.ps1"
$Quiet = $true
. $CRUCIBLE_LIB

$results = @()







$tempRoot = New-TestFixtureRoot -NameHint "worktree-test"

function New-ImplementationWorktreeTestRepo {
    param([string]$Name)
    $repoPath = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
    git -C $repoPath init -b main --quiet
    git -C $repoPath config user.name "Test"
    git -C $repoPath config user.email "test@test.com"
    [System.IO.File]::WriteAllText((Join-Path $repoPath "README.md"), "fixture`n", [System.Text.UTF8Encoding]::new($false))
    git -C $repoPath add README.md
    git -C $repoPath commit -m "initial" --quiet
    return $repoPath
}

function New-HumanGateWorktreeTestRepo {
    param([string]$Name)
    $repoPath = New-ImplementationWorktreeTestRepo -Name $Name
    $configDir = Join-Path $repoPath ".crucible"
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $configDir "config.yaml"), "paths:`n  workspaces: workspaces`n", [System.Text.UTF8Encoding]::new($false))
    return $repoPath
}

try {
    # Exercise the moved human-gate operations against disposable repos. TODO item 197.
    $results += Run-Test -Name "Remove-ImplementationWorktree removes an existing worktree" -Body {
        $repoPath = New-HumanGateWorktreeTestRepo -Name "remove-repo"
        $wtPath = Join-Path $repoPath "workspaces/implementation-F-197-remove"
        $oldQuiet = $script:Quiet
        Push-Location $repoPath
        try {
            git worktree add $wtPath -b task/F-197-remove main 2>$null | Out-Null
            $script:Quiet = $false
            $output = Invoke-ExternalCommand -AsLines { & { $script:removedResult = Remove-ImplementationWorktree -TaskId "F-197-remove" -ProjectRoot $repoPath } 6>&1 } | Out-String
            $removed = $script:removedResult
            Assert-Result -Name "removal message" -Condition ($output.Trim() -eq "[HUMAN GATE] Removing implementation worktree at $wtPath...") -FailureMessage $output
            Assert-Result -Name "removal reports success" -Condition ($removed -eq $true) -FailureMessage ("returned " + $removed)
            Assert-Result -Name "clean worktree removed" -Condition (-not (Test-Path -LiteralPath $wtPath)) -FailureMessage "implementation worktree remains"
            Assert-Result -Name "worktree registration removed" -Condition ((Invoke-ExternalCommand -AsLines { git worktree list --porcelain } | Out-String) -notmatch 'implementation-F-197-remove') -FailureMessage "worktree is still registered"
            git show-ref --verify --quiet refs/heads/task/F-197-remove
            Assert-Result -Name "task branch retained for the gate" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "helper deleted the task branch"
        } finally {
            $script:Quiet = $oldQuiet
            Pop-Location
        }
    }

    # Item 221: the merge ships only commits, so uncommitted work must survive cleanup.
    $results += Run-Test -Name "Remove-ImplementationWorktree keeps a worktree with uncommitted changes" -Body {
        $repoPath = New-HumanGateWorktreeTestRepo -Name "remove-dirty-repo"
        $wtPath = Join-Path $repoPath "workspaces/implementation-F-221-dirty"
        $oldQuiet = $script:Quiet
        Push-Location $repoPath
        try {
            git worktree add $wtPath -b task/F-221-dirty main 2>$null | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $wtPath "README.md"), "tracked edit after the last commit`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $wtPath "untracked.txt"), "new work`n", [System.Text.UTF8Encoding]::new($false))
            $script:Quiet = $false
            $output = Invoke-ExternalCommand -AsLines { & { $script:removedResult = Remove-ImplementationWorktree -TaskId "F-221-dirty" -ProjectRoot $repoPath } *>&1 } | Out-String
            Assert-Result -Name "dirty removal reports failure" -Condition ($script:removedResult -eq $false) -FailureMessage ("returned " + $script:removedResult)
            Assert-Result -Name "tracked edit survives" -Condition ((Get-Content -LiteralPath (Join-Path $wtPath "README.md") -Raw) -match 'tracked edit') -FailureMessage "the tracked edit was deleted"
            Assert-Result -Name "untracked file survives" -Condition (Test-Path -LiteralPath (Join-Path $wtPath "untracked.txt")) -FailureMessage "the untracked file was deleted"
            Assert-Result -Name "both paths named" -Condition ($output.Contains("README.md") -and $output.Contains("untracked.txt")) -FailureMessage $output
        } finally {
            $script:Quiet = $oldQuiet
            Pop-Location
        }
    }

    $results += Run-Test -Name "Remove-ImplementationWorktree does nothing when absent" -Body {
        $repoPath = New-HumanGateWorktreeTestRepo -Name "remove-absent-repo"
        $oldQuiet = $script:Quiet
        Push-Location $repoPath
        try {
            # A stale registration proves an absent target does not even prune.
            $stalePath = Join-Path $repoPath "stale"
            git worktree add $stalePath -b task/stale main 2>$null | Out-Null
            Remove-Item -LiteralPath $stalePath -Recurse -Force
            $script:Quiet = $false
            $output = Invoke-ExternalCommand -AsLines { & { $null = Remove-ImplementationWorktree -TaskId "F-197-absent" -ProjectRoot $repoPath } 6>&1 } | Out-String
            Assert-Result -Name "absent removal is silent" -Condition ([string]::IsNullOrWhiteSpace($output)) -FailureMessage $output
            Assert-Result -Name "absent removal leaves stale registration" -Condition ((Invoke-ExternalCommand -AsLines { git worktree list --porcelain } | Out-String) -match 'refs/heads/task/stale') -FailureMessage "absent removal pruned worktrees"
        } finally {
            $script:Quiet = $oldQuiet
            Pop-Location
        }
    }

    $results += Run-Test -Name "Remove-ImplementationWorktree warns when locked even in Quiet mode" -Body {
        $repoPath = New-HumanGateWorktreeTestRepo -Name "remove-locked-repo"
        $wtPath = Join-Path $repoPath "workspaces/implementation-F-197-locked"
        Push-Location $repoPath
        try {
            git worktree add $wtPath -b task/F-197-locked main 2>$null | Out-Null
            git worktree lock $wtPath
            $output = Invoke-ExternalCommand -AsLines { & { $script:removedResult = Remove-ImplementationWorktree -TaskId "F-197-locked" -ProjectRoot $repoPath } 6>&1 } | Out-String
            Assert-Result -Name "locked worktree retained" -Condition (Test-Path -LiteralPath $wtPath) -FailureMessage "locked worktree was removed"
            Assert-Result -Name "locked removal reports failure" -Condition ($script:removedResult -eq $false) -FailureMessage ("returned " + $script:removedResult)
            Assert-Result -Name "locked warning" -Condition ($output.Contains("[HUMAN GATE] Worktree at $wtPath is locked") -and $output.Contains("task/F-197-locked")) -FailureMessage $output
        } finally {
            git worktree unlock $wtPath
            Pop-Location
        }
    }

    $results += Run-Test -Name "Restore-ImplementationWorktree recreates an existing branch with hooks initialized" -Body {
        $repoPath = New-HumanGateWorktreeTestRepo -Name "restore-repo"
        $wtPath = Join-Path $repoPath "workspaces/implementation-F-197-restore"
        $oldQuiet = $script:Quiet
        $initializeHooks = (Get-Command Initialize-ImplementationWorktreeHooks).ScriptBlock
        $hookPaths = [System.Collections.Generic.List[string]]::new()
        # Seed a legacy override at initialization so calling the real installer is observable.
        function Initialize-ImplementationWorktreeHooks {
            param($WorktreePath)
            $hookPaths.Add($WorktreePath)
            git -C $WorktreePath config --worktree core.hooksPath scripts/hooks/architect
            & $initializeHooks -WorktreePath $WorktreePath
        }
        Push-Location $repoPath
        try {
            git branch task/F-197-restore main
            git config extensions.worktreeConfig true
            git config core.hooksPath scripts/hooks
            $script:Quiet = $false
            $output = Invoke-ExternalCommand -AsLines { & { Restore-ImplementationWorktree -TaskId "F-197-restore" -ProjectRoot $repoPath } 6>&1 } | Out-String
            Assert-Result -Name "restored branch checked out" -Condition ((Invoke-ExternalCommand -AsLines { git -C $wtPath branch --show-current }) -eq "task/F-197-restore") -FailureMessage "wrong branch was recreated"
            Assert-Result -Name "restored checkout exists" -Condition (Test-Path -LiteralPath (Join-Path $wtPath "README.md")) -FailureMessage "worktree was not checked out"
            Assert-Result -Name "restored worktree hook installer called" -Condition ($hookPaths.Count -eq 1 -and $hookPaths[0] -eq $wtPath) -FailureMessage "hook installer was not called once for the recreated worktree"
            Assert-Result -Name "restored worktree hooks initialized" -Condition ([string]::IsNullOrWhiteSpace((Invoke-ExternalCommand -AsLines { git -C $wtPath config --worktree --get core.hooksPath }))) -FailureMessage "legacy hook override remains"
            Assert-Result -Name "restored worktree uses shared hooks" -Condition ((Invoke-ExternalCommand -AsLines { git -C $wtPath config --get core.hooksPath }) -eq "scripts/hooks") -FailureMessage "worktree does not use the shared hook path"
            Assert-Result -Name "recreation message" -Condition ($output -match [regex]::Escape("[HUMAN GATE] Recreated implementation worktree at $wtPath")) -FailureMessage $output
        } finally {
            $script:Quiet = $oldQuiet
            Pop-Location
        }
    }

    $results += Run-Test -Name "Restore-ImplementationWorktree leaves an existing worktree alone" -Body {
        $repoPath = New-HumanGateWorktreeTestRepo -Name "restore-existing-repo"
        $wtPath = Join-Path $repoPath "workspaces/implementation-F-197-existing"
        $oldQuiet = $script:Quiet
        Push-Location $repoPath
        try {
            git worktree add $wtPath -b task/F-197-existing main 2>$null | Out-Null
            git config extensions.worktreeConfig true
            git -C $wtPath config --worktree core.hooksPath scripts/hooks/architect
            $script:Quiet = $false
            $output = Invoke-ExternalCommand -AsLines { & { Restore-ImplementationWorktree -TaskId "F-197-existing" -ProjectRoot $repoPath } 6>&1 } | Out-String
            Assert-Result -Name "existing recreation is silent" -Condition ([string]::IsNullOrWhiteSpace($output)) -FailureMessage $output
            Assert-Result -Name "existing recreation skips hook initialization" -Condition ((Invoke-ExternalCommand -AsLines { git -C $wtPath config --worktree --get core.hooksPath }) -eq "scripts/hooks/architect") -FailureMessage "existing worktree hook override was changed"
        } finally {
            $script:Quiet = $oldQuiet
            Pop-Location
        }
    }

    $results += Run-Test -Name "Restore-ImplementationWorktree warns when branch is missing" -Body {
        $repoPath = New-HumanGateWorktreeTestRepo -Name "restore-failure-repo"
        $wtPath = Join-Path $repoPath "workspaces/implementation-F-197-missing"
        Push-Location $repoPath
        try {
            $output = Invoke-ExternalCommand -AsLines { & { Restore-ImplementationWorktree -TaskId "F-197-missing" -ProjectRoot $repoPath } 6>&1 } | Out-String
            Assert-Result -Name "failed recreation warns in Quiet mode" -Condition ($output -match [regex]::Escape("Warning: Failed to recreate implementation worktree at $wtPath")) -FailureMessage $output
            Assert-Result -Name "failed recreation has no success message" -Condition ($output -notmatch 'Recreated implementation worktree') -FailureMessage $output
            Assert-Result -Name "failed recreation leaves no worktree" -Condition (-not (Test-Path -LiteralPath $wtPath)) -FailureMessage "worktree unexpectedly exists"
            Assert-Result -Name "failed recreation preserves exit code" -Condition ($LASTEXITCODE -ne 0) -FailureMessage "failed git exit code was cleared"
        } finally { Pop-Location }
    }

    # Exercise the moved setup directly, including both branch paths and reruns. TODO item 197.
    $results += Run-Test -Name "Initialize-ImplementationWorktree creates a new task branch" -Body {
        $repoPath = New-ImplementationWorktreeTestRepo -Name "new-task-repo"
        $REPO_ROOT = $repoPath
        $wtPath = Join-Path $tempRoot "implementation-F-197-new"
        Push-Location $repoPath
        try {
            Initialize-ImplementationWorktree -WorktreePath $wtPath -TaskId "F-197-new" | Out-Null
            Assert-Result -Name "new worktree exists" -Condition (Test-Path -LiteralPath (Join-Path $wtPath "README.md")) -FailureMessage "worktree was not checked out"
            Assert-Result -Name "new task branch checked out" -Condition ((Invoke-ExternalCommand -AsLines { git -C $wtPath branch --show-current }) -eq "task/F-197-new") -FailureMessage "wrong worktree branch"
            Assert-Result -Name "new task branch starts at primary" -Condition ((Invoke-ExternalCommand -AsLines { git -C $wtPath rev-parse HEAD }) -eq (Invoke-ExternalCommand -AsLines { git rev-parse main })) -FailureMessage "task branch did not start at main"
        } finally { Pop-Location }
    }

    $results += Run-Test -Name "Initialize-ImplementationWorktree reuses an existing task branch" -Body {
        $repoPath = New-ImplementationWorktreeTestRepo -Name "existing-task-repo"
        $REPO_ROOT = $repoPath
        $wtPath = Join-Path $tempRoot "implementation-F-197-reuse"
        Push-Location $repoPath
        try {
            git checkout -b task/F-197-reuse --quiet
            [System.IO.File]::WriteAllText((Join-Path $repoPath "task.txt"), "existing task work`n", [System.Text.UTF8Encoding]::new($false))
            git add task.txt
            git commit -m "task work" --quiet
            $taskHead = Invoke-ExternalCommand -AsLines { git rev-parse HEAD }
            git checkout main --quiet
            Initialize-ImplementationWorktree -WorktreePath $wtPath -TaskId "F-197-reuse" | Out-Null
            Assert-Result -Name "existing task branch checked out" -Condition ((Invoke-ExternalCommand -AsLines { git -C $wtPath branch --show-current }) -eq "task/F-197-reuse") -FailureMessage "wrong worktree branch"
            Assert-Result -Name "existing task commit retained" -Condition ((Invoke-ExternalCommand -AsLines { git -C $wtPath rev-parse HEAD }) -eq $taskHead -and (Test-Path -LiteralPath (Join-Path $wtPath "task.txt"))) -FailureMessage "existing task branch was reset"
        } finally { Pop-Location }
    }

    $results += Run-Test -Name "Initialize-ImplementationWorktree reports an existing worktree" -Body {
        $repoPath = New-ImplementationWorktreeTestRepo -Name "existing-worktree-repo"
        $REPO_ROOT = $repoPath
        $wtPath = Join-Path $tempRoot "implementation-F-197-exists"
        $oldQuiet = $script:Quiet
        Push-Location $repoPath
        try {
            Initialize-ImplementationWorktree -WorktreePath $wtPath -TaskId "F-197-exists" | Out-Null
            git config extensions.worktreeConfig true
            git -C $wtPath config --worktree core.hooksPath scripts/hooks/architect
            $script:Quiet = $false
            $output = Invoke-ExternalCommand -AsLines { & { Initialize-ImplementationWorktree -WorktreePath $wtPath -TaskId "F-197-exists" } 6>&1 } | Out-String
            Assert-Result -Name "existing worktree message" -Condition ($output.Trim() -eq "[INIT] Worktree already exists at $wtPath.") -FailureMessage $output
            Assert-Result -Name "existing worktree hooks initialized" -Condition ([string]::IsNullOrWhiteSpace((Invoke-ExternalCommand -AsLines { git -C $wtPath config --worktree --get core.hooksPath }))) -FailureMessage "legacy hook override remains"
            $script:Quiet = $true
            $quietOutput = Invoke-ExternalCommand -AsLines { & { Initialize-ImplementationWorktree -WorktreePath $wtPath -TaskId "F-197-exists" } 6>&1 } | Out-String
            Assert-Result -Name "existing worktree message respects Quiet" -Condition ([string]::IsNullOrWhiteSpace($quietOutput)) -FailureMessage $quietOutput
        } finally {
            $script:Quiet = $oldQuiet
            Pop-Location
        }
    }

    $results += Run-Test -Name "Normalize-RepoRelativePath normalizes separators and prefixes" -Body {
        Assert-Result -Name "backslashes" -Condition ((Normalize-RepoRelativePath -Path ".\src\app.ps1") -eq "src/app.ps1") -FailureMessage "backslashes or leading ./ were not normalized"
        Assert-Result -Name "leading slash" -Condition ((Normalize-RepoRelativePath -Path "/tests/unit.ps1") -eq "tests/unit.ps1") -FailureMessage "leading slash was not stripped"
        Assert-Result -Name "whitespace" -Condition ((Normalize-RepoRelativePath -Path "   ") -eq "") -FailureMessage "whitespace should normalize to empty"
    }

    $results += Run-Test -Name "Resolve-ImplementationWorktreePath returns phase-named path" -Body {
        $path = Resolve-ImplementationWorktreePath -TaskId "F-101" -WorkspacesDir $tempRoot
        $expected = Join-Path $tempRoot "implementation-F-101"
        Assert-Result -Name "phase path" -Condition ($path -eq $expected) -FailureMessage "should return implementation-named path"
    }

    $results += Run-Test -Name "Resolve-ImplementationWorktreePath ignores legacy architect-named directory" -Body {
        $legacyPath = Join-Path $tempRoot "architect-F-102"
        New-Item -ItemType Directory -Path $legacyPath -Force | Out-Null

        $path = Resolve-ImplementationWorktreePath -TaskId "F-102" -WorkspacesDir $tempRoot
        $expected = Join-Path $tempRoot "implementation-F-102"
        Assert-Result -Name "no legacy fallback" -Condition ($path -eq $expected) -FailureMessage "legacy architect path should no longer be returned"
    }

    $results += Run-Test -Name "Test-PathMatchesAffinity covers exact wildcard prefix and empty inputs" -Body {
        Assert-Result -Name "exact match" -Condition (Test-PathMatchesAffinity -ChangedPath "src/app.ps1" -Affinity "src/app.ps1") -FailureMessage "exact path should match"
        Assert-Result -Name "wildcard match" -Condition (Test-PathMatchesAffinity -ChangedPath "src/app.ps1" -Affinity "src/*.ps1") -FailureMessage "wildcard should match"
        Assert-Result -Name "prefix match" -Condition (Test-PathMatchesAffinity -ChangedPath "src/lib/app.ps1" -Affinity "src/") -FailureMessage "directory prefix should match"
        Assert-Result -Name "empty changed rejected" -Condition (-not (Test-PathMatchesAffinity -ChangedPath " " -Affinity "src/")) -FailureMessage "empty changed path should not match"
        Assert-Result -Name "empty affinity rejected" -Condition (-not (Test-PathMatchesAffinity -ChangedPath "src/app.ps1" -Affinity " ")) -FailureMessage "empty affinity should not match"
    }

    $results += Run-Test -Name "Test-PathMatchesAffinity auto-allows *_test.go sibling files under file-level affinity (D51)" -Body {
        Assert-Result -Name "sibling test match" -Condition (Test-PathMatchesAffinity -ChangedPath "internal/config/vector_index_interval_test.go" -Affinity "internal/config/config.go") -FailureMessage "test sibling should match when affinity is file-level"
        Assert-Result -Name "sibling test root match" -Condition (Test-PathMatchesAffinity -ChangedPath "main_test.go" -Affinity "main.go") -FailureMessage "test sibling in root should match"
        Assert-Result -Name "different dir test mismatch" -Condition (-not (Test-PathMatchesAffinity -ChangedPath "internal/app/vector_index_interval_test.go" -Affinity "internal/config/config.go")) -FailureMessage "test file in different directory should not match"
        Assert-Result -Name "sibling non-test mismatch" -Condition (-not (Test-PathMatchesAffinity -ChangedPath "internal/config/vector_index_interval.go" -Affinity "internal/config/config.go")) -FailureMessage "non-test sibling should not match file-level affinity"
    }

    $results += Run-Test -Name "Get-AffinityWidening finds a widening under the same top-level directory (item 164)" -Body {
        # B-022's shape: three declared files, a handoff carrying the union with two packages.
        $declared = @("internal/agent/session_history.go", "internal/agent/*_test.go", "internal/context/manager_test.go")
        $handoff = @("internal/agent/session_history.go", "internal/agent/*_test.go", "internal/context/manager_test.go", "internal/agent/", "internal/context/")
        $widened = @(Get-AffinityWidening -Affinity $handoff -Declared $declared)
        Assert-Result -Name "both packages widened" -Condition ($widened.Count -eq 2 -and $widened -contains "internal/agent/" -and $widened -contains "internal/context/") -FailureMessage ("expected internal/agent/ and internal/context/, got: " + ($widened -join ", "))

        $covered = @(Get-AffinityWidening -Affinity @("internal/agent/session_history.go", "internal/agent/history_test.go", "internal/app/run.go") -Declared @("internal/agent/session_history.go", "internal/app/"))
        Assert-Result -Name "covered paths are not widenings" -Condition ($covered.Count -eq 0) -FailureMessage ("expected no widening, got: " + ($covered -join ", "))

        $none = @(Get-AffinityWidening -Affinity @() -Declared @("internal/app/"))
        Assert-Result -Name "empty handoff" -Condition ($none.Count -eq 0) -FailureMessage "an empty handoff affinity widens nothing"
    }

    $results += Run-Test -Name "Get-SpecFrontmatterAffinity reads flow and block lists and ignores the body" -Body {
        $flow = @(Get-SpecFrontmatterAffinity -SpecContent "---`nitem_id: `"X`"`nfile_affinity: [`"cmd/`", 'docs/a.md']`n---`nfile_affinity: [`"body/`"]`n")
        Assert-Result -Name "flow list" -Condition ($flow.Count -eq 2 -and $flow[0] -eq "cmd/" -and $flow[1] -eq "docs/a.md") -FailureMessage ("flow list parsed as: " + ($flow -join ", "))

        $block = @(Get-SpecFrontmatterAffinity -SpecContent "---`r`nfile_affinity:`r`n  - `"internal/agent/`"`r`n`r`n  # note`r`n  - internal/app/`r`ncreated_at: `"2026-10-05`"`r`n---`r`n")
        Assert-Result -Name "block list" -Condition ($block.Count -eq 2 -and $block[0] -eq "internal/agent/" -and $block[1] -eq "internal/app/") -FailureMessage ("block list parsed as: " + ($block -join ", "))

        # All spec consumers receive bare paths, including handoff scope checks. Item 220.
        foreach ($yaml in @('file_affinity: ["src/new.go (new)", src/known.go]', "file_affinity:`n  - 'src/new.go (new)'`n  - src/known.go")) {
            $paths = @(Get-SpecFrontmatterAffinity -SpecContent ("---`n" + $yaml + "`n---`n"))
            Assert-Result -Name "new marker stripped" -Condition (($paths -join "|") -eq "src/new.go|src/known.go") -FailureMessage ($paths -join ", ")
            $widened = @(Get-AffinityWidening -Affinity @("src/new.go") -Declared $paths)
            Assert-Result -Name "bare handoff matches new spec" -Condition ($widened.Count -eq 0) -FailureMessage ($widened -join ", ")
        }

        $absent = @(Get-SpecFrontmatterAffinity -SpecContent "## Affected Files`n- ``cmd/```n")
        Assert-Result -Name "no frontmatter" -Condition ($absent.Count -eq 0) -FailureMessage "a spec without frontmatter declares no affinity"
    }

    # Configured primary branches must cover committed changes in clean worktrees. Item 225.
    $results += Run-Test -Name "Configured release branch detects committed scope violations" -Body {
        $repoPath = New-ImplementationWorktreeTestRepo -Name "release-scope"
        git -C $repoPath branch -m release
        New-Item -ItemType Directory -Path (Join-Path $repoPath ".crucible") | Out-Null
        [IO.File]::WriteAllText((Join-Path $repoPath ".crucible/config.yaml"), "project:`n  default_branch: release`n", [Text.UTF8Encoding]::new($false))
        git -C $repoPath add .
        git -C $repoPath commit -m "configure release" --quiet
        git -C $repoPath checkout -b task/F-225 --quiet
        [IO.File]::WriteAllText((Join-Path $repoPath "unrelated.txt"), "changed`n", [Text.UTF8Encoding]::new($false))
        git -C $repoPath add .
        git -C $repoPath commit -m "out of scope" --quiet
        Assert-Result -Name "fixture is clean" -Condition (-not (Invoke-ExternalCommand -AsLines { git -C $repoPath status --porcelain })) -FailureMessage "fixture has uncommitted changes"
        $outside = @(Get-OutOfScopeImplementationFiles -WorktreePath $repoPath -TaskId F-225 -FileAffinity @("powershell/"))
        Assert-Result -Name "release commit violates scope" -Condition ($outside.Count -eq 1 -and $outside[0] -eq "unrelated.txt") -FailureMessage ($outside -join ", ")
    }

    $results += Run-Test -Name "Unreadable committed scope diff throws" -Body {
        $repoPath = New-ImplementationWorktreeTestRepo -Name "unrelated-scope"
        git -C $repoPath checkout --orphan task/F-225-unrelated --quiet
        git -C $repoPath commit -m "unrelated root" --quiet
        $message = ""
        try { Get-ImplementationChangedFiles -WorktreePath $repoPath -TaskId F-225-unrelated | Out-Null }
        catch { $message = $_.Exception.Message }
        Assert-Result -Name "unreadable diff fails closed" -Condition ($message -match "committed diff") -FailureMessage "expected committed diff error, got: $message"
    }

    $results += Run-Test -Name "Get-OutOfScopeImplementationFiles is mirror-aware (issue #4)" -Body {
        $repoPath = Join-Path $tempRoot "mirror-test-repo"
        New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
        git -C $repoPath init --quiet | Out-Null
        git -C $repoPath config user.name "Test" | Out-Null
        git -C $repoPath config user.email "test@test.com" | Out-Null
        
        # Helper write function for test isolation
        $writeHelper = {
            param($Path, $Content)
            $dir = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
        }
        
        & $writeHelper (Join-Path $repoPath "readme.md") "initial"
        git -C $repoPath add . | Out-Null
        git -C $repoPath commit -m "initial" --quiet | Out-Null
        
        # Create and checkout task/dummy branch
        git -C $repoPath checkout -b "task/dummy" --quiet | Out-Null
        
        & $writeHelper (Join-Path $repoPath "powershell/tool.ps1") "changed"
        & $writeHelper (Join-Path $repoPath "examples/gobot/.crucible/powershell/tool.ps1") "changed"
        & $writeHelper (Join-Path $repoPath "unrelated.txt") "changed"
        
        git -C $repoPath add . | Out-Null
        git -C $repoPath commit -m "changes" --quiet | Out-Null
        
        $affinity = @("powershell/")
        
        $outOfScope = @(Get-OutOfScopeImplementationFiles -WorktreePath $repoPath -TaskId "dummy" -FileAffinity $affinity)
        
        Assert-Result -Name "only unrelated is out of scope" -Condition ($outOfScope.Count -eq 1) -FailureMessage "expected exactly 1 out of scope file"
        Assert-Result -Name "unrelated.txt is out of scope" -Condition ($outOfScope[0] -eq "unrelated.txt") -FailureMessage ("expected unrelated.txt to be out of scope, got: " + ($outOfScope -join ", "))
    }

    $results += Run-Test -Name "Get-OutOfScopeImplementationFiles bypasses allowed manifest files" -Body {
        $repoPath = Join-Path $tempRoot "manifest-bypass-repo"
        New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
        git -C $repoPath init --quiet | Out-Null
        git -C $repoPath config user.name "Test" | Out-Null
        git -C $repoPath config user.email "test@test.com" | Out-Null
        
        $writeHelper = {
            param($Path, $Content)
            $dir = Split-Path -Parent $Path
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
        }
        
        $configDir = Join-Path $repoPath ".crucible"
        & $writeHelper (Join-Path $configDir "config.yaml") "manifest_files:`n  - go.mod`n  - go.sum`n"
        & $writeHelper (Join-Path $repoPath "readme.md") "initial"
        
        git -C $repoPath add . | Out-Null
        git -C $repoPath commit -m "initial" --quiet | Out-Null
        git -C $repoPath checkout -b "task/dummy" --quiet | Out-Null
        
        & $writeHelper (Join-Path $repoPath "powershell/tool.ps1") "changed"
        & $writeHelper (Join-Path $repoPath "go.mod") "changed"
        & $writeHelper (Join-Path $repoPath "unrelated.txt") "changed"
        
        git -C $repoPath add . | Out-Null
        git -C $repoPath commit -m "changes" --quiet | Out-Null
        
        $affinity = @("powershell/")
        $outOfScope = @(Get-OutOfScopeImplementationFiles -WorktreePath $repoPath -TaskId "dummy" -FileAffinity $affinity)
        
        Assert-Result -Name "manifest is bypassed" -Condition ($outOfScope.Count -eq 1) -FailureMessage "expected exactly 1 out of scope file (go.mod should be bypassed)"
        Assert-Result -Name "only unrelated.txt out of scope" -Condition ($outOfScope[0] -eq "unrelated.txt") -FailureMessage ("expected unrelated.txt to be the only out of scope file, got: " + ($outOfScope -join ", "))
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed worktree test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll worktree tests passed." -ForegroundColor Green
exit 0
