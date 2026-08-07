# Tests for shared worktree and scope helpers.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$FACTORY_LIB = Join-Path $REPO_ROOT "powershell/factory-lib.ps1"
$Quiet = $true
. $FACTORY_LIB

$results = @()







$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-worktree-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
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
