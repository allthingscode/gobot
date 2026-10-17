# Declare the moved setup's wrapper dependency without relying on sibling load order. TODO item 197.
# Requires: Get-ConfiguredPrimaryBranch and Write-Quiet (loaded by crucible-lib.ps1).
if (-not (Get-Command Invoke-GitChecked -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "git.ps1")
}

function Normalize-RepoRelativePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $normalized = $Path.Replace("\", "/").Trim()
    while ($normalized.StartsWith("./")) {
        $normalized = $normalized.Substring(2)
    }
    return $normalized.TrimStart("/")
}

function Test-PathMatchesAffinity {
    param(
        [Parameter(Mandatory=$true)][string]$ChangedPath,
        [Parameter(Mandatory=$true)][string]$Affinity
    )

    $changed = Normalize-RepoRelativePath -Path $ChangedPath
    $scope = Normalize-RepoRelativePath -Path $Affinity
    if ([string]::IsNullOrWhiteSpace($changed) -or [string]::IsNullOrWhiteSpace($scope)) {
        return $false
    }

    if ($scope -match '[\*\?]') {
        return [System.Management.Automation.WildcardPattern]::Get($scope, [System.Management.Automation.WildcardOptions]::IgnoreCase).IsMatch($changed)
    }

    $scopePrefix = $scope.TrimEnd("/")

    if ($changed -like "*_test.go") {
        $changedDir = ""
        $lastSlash = $changed.LastIndexOf("/")
        if ($lastSlash -ge 0) {
            $changedDir = $changed.Substring(0, $lastSlash)
        }

        $scopeDir = ""
        $lastScopeSlash = $scopePrefix.LastIndexOf("/")
        if ($lastScopeSlash -ge 0) {
            $scopeDir = $scopePrefix.Substring(0, $lastScopeSlash)
        }

        if ($changedDir -eq $scopeDir) {
            return $true
        }
    }

    return ($changed -eq $scopePrefix -or $changed.StartsWith($scopePrefix + "/", [System.StringComparison]::OrdinalIgnoreCase))
}

# The one reader of a spec's file_affinity. Scope consumers get bare paths; backlog
# validation passes -KeepNewMarker to see which entries are planned files. Item 231.
function Get-SpecFrontmatterAffinity {
    param(
        [AllowEmptyString()][string]$SpecContent,
        [switch]$KeepNewMarker
    )

    $affinity = @()
    if ([string]::IsNullOrEmpty($SpecContent)) { return $affinity }
    $specLines = $SpecContent -split '\r?\n'
    if ($specLines.Count -lt 2 -or $specLines[0].Trim() -ne "---") { return $affinity }

    $frontmatterLines = @()
    $foundEnd = $false
    for ($i = 1; $i -lt $specLines.Count; $i++) {
        if ($specLines[$i].Trim() -eq "---") {
            $foundEnd = $true
            break
        }
        $frontmatterLines += $specLines[$i]
    }
    if (-not $foundEnd) { return $affinity }

    $inAffinityBlock = $false
    foreach ($line in $frontmatterLines) {
        if ($line -match '^\s*file_affinity:\s*(.*)$') {
            $rest = $Matches[1].Trim()
            if ($rest -match '^\[(.*)\]$') {
                foreach ($item in ($Matches[1] -split ',')) {
                    $clean = $item.Trim().Trim('"' + "'")
                    if (-not [string]::IsNullOrWhiteSpace($clean)) {
                        # Keep creation metadata out of every scope consumer. Item 220.
                        $affinity += $(if ($KeepNewMarker) { $clean } else { ($clean -creplace '\s+\(new\)$', '').TrimEnd() })
                    }
                }
                $inAffinityBlock = $false
            } else {
                $inAffinityBlock = $true
            }
            continue
        }
        if ($inAffinityBlock) {
            if ($line -match '^\s*-\s*(.*)$') {
                $item = $Matches[1].Trim().Trim('"' + "'")
                if (-not [string]::IsNullOrWhiteSpace($item)) {
                    $affinity += $(if ($KeepNewMarker) { $item } else { ($item -creplace '\s+\(new\)$', '').TrimEnd() })
                }
            } elseif ($line.Trim() -eq "" -or $line -match '^\s*#') {
                continue
            } else {
                $inAffinityBlock = $false
            }
        }
    }
    return $affinity
}

# A handoff entry is a widening when no declared path covers it, judged by the same
# matcher the scope gate uses. B-022 widened three files to two whole packages under
# the same top-level directory, which a top-level comparison cannot see.
function Get-AffinityWidening {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Affinity,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Declared
    )

    $declaredPaths = @($Declared | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $widened = @()
    foreach ($entry in @($Affinity | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $covered = $false
        foreach ($declaredPath in $declaredPaths) {
            if (Test-PathMatchesAffinity -ChangedPath $entry -Affinity $declaredPath) {
                $covered = $true
                break
            }
        }
        if (-not $covered) {
            $widened += $entry
        }
    }
    return $widened
}

function Resolve-ImplementationWorktreePath {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$WorkspacesDir = $workspacesDir
    )

    return Join-Path $WorkspacesDir ("implementation-" + $TaskId)
}

# Relative core.hooksPath resolves against the worktree root, so run its branch's hooks.
# Remove legacy per-worktree overrides that point at non-executable hook directories.
# Without extensions.worktreeConfig, --worktree targets shared config; leave it alone
# because no per-worktree override can exist. Item 155.
#
# On Unix it also marks the worktree's hooks executable. git skips a hook without the
# bit, and a fresh worktree checks hooks out with the recorded mode, which is 100644 for
# a bundle committed on Windows; install-hooks.ps1 fixes only the main checkout's copy.
# Item 155.
function Initialize-ImplementationWorktreeHooks {
    param([Parameter(Mandatory=$true)][string]$WorktreePath)

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ((git -C $WorktreePath config --get extensions.worktreeConfig 2>$null) -eq "true") {
            $override = git -C $WorktreePath config --worktree --get core.hooksPath 2>$null
            if (-not [string]::IsNullOrWhiteSpace($override)) {
                git -C $WorktreePath config --worktree --unset core.hooksPath 2>$null
            }
        }

        $onWindows = $true
        if ($PSVersionTable.PSEdition -eq "Core") {
            $onWindows = (Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -ne $false
        }
        if (-not $onWindows) {
            $hooksPath = git -C $WorktreePath config --get core.hooksPath 2>$null
            if (-not [string]::IsNullOrWhiteSpace($hooksPath)) {
                $hooksDir = $hooksPath.Trim()
                if (-not [System.IO.Path]::IsPathRooted($hooksDir)) { $hooksDir = Join-Path $WorktreePath $hooksDir }
                if (Test-Path -LiteralPath $hooksDir -PathType Container) {
                    Get-ChildItem -LiteralPath $hooksDir -File | ForEach-Object { & chmod "+x" $_.FullName }
                }
            }
        }
    } finally {
        $ErrorActionPreference = $prevEAP
        $global:LASTEXITCODE = 0
    }
}

function Initialize-ImplementationWorktree {
    param(
        [Parameter(Mandatory=$true)][string]$WorktreePath,
        [Parameter(Mandatory=$true)][string]$TaskId
    )

    # Prune stale worktrees first
    Invoke-GitChecked { git worktree prune }

    if (-not (Test-Path $WorktreePath)) {
        Write-Quiet ("[INIT] Creating git worktree at " + $WorktreePath + "...") -ForegroundColor Yellow
        $mainBranch = Get-ConfiguredPrimaryBranch
        $taskBranch = "task/" + $TaskId
        git show-ref --verify --quiet ("refs/heads/" + $taskBranch)
        # git worktree add prints "Preparing worktree" to stderr on success; under Windows
        # PowerShell 5.1 with EAP=Stop that benign stderr becomes a terminating
        # NativeCommandError and aborts -Init before task.md is written. Invoke-GitChecked
        # localizes EAP, demotes exit-0 stderr to a notice, and preserves $LASTEXITCODE.
        if ($LASTEXITCODE -eq 0) {
            Invoke-GitChecked { git worktree add $WorktreePath $taskBranch }
        } else {
            Invoke-GitChecked { git worktree add $WorktreePath -b $taskBranch $mainBranch }
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("Error: Failed to create implementation worktree at " + $WorktreePath) -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Quiet ("[INIT] Worktree already exists at $WorktreePath.") -ForegroundColor Cyan
    }
    Initialize-ImplementationWorktreeHooks -WorktreePath $WorktreePath
}

# Tracked edits and untracked files that are not ignored. The merge ships only commits, so
# these are work the checks may have tested but nothing will merge. Item 221.
function Get-WorktreeUncommittedPaths {
    param([Parameter(Mandatory=$true)][string]$WorktreePath)
    $lines = @(git -C $WorktreePath status --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw ("git status failed in " + $WorktreePath)
    }
    return @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# Keep human-gate worktree side effects with worktree setup. TODO item 197.
# Returns $true when the worktree is gone, so the caller deletes the task branch only then.
function Remove-ImplementationWorktree {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$ProjectRoot
    )

    $workspacesDir = Get-ConfiguredPath -Key "workspaces" -ProjectRoot $ProjectRoot
    $wtPath = Resolve-ImplementationWorktreePath -TaskId $TaskId -WorkspacesDir $workspacesDir
    if (-not (Test-Path $wtPath)) { return $true }

    Write-Quiet "[HUMAN GATE] Removing implementation worktree at $wtPath..."
    Invoke-GitChecked { git worktree prune }
    if (-not (Test-Path $wtPath)) { return $true }

    # Never --force: uncommitted work was not merged, and deleting it is unrecoverable. Item 221.
    $uncommitted = @()
    try {
        $uncommitted = @(Get-WorktreeUncommittedPaths -WorktreePath $wtPath)
    } catch {
        Write-Host "[HUMAN GATE] Could not read the state of $wtPath ($($_.Exception.Message)); left it and task/$TaskId in place." -ForegroundColor Yellow
        return $false
    }
    if ($uncommitted.Count -gt 0) {
        Write-Host "[HUMAN GATE] Worktree at $wtPath has uncommitted changes that were not merged; left it and task/$TaskId in place:" -ForegroundColor Yellow
        foreach ($line in $uncommitted) { Write-Host "  $line" -ForegroundColor Yellow }
        Write-Host "  Keep them by committing them for a new task, or discard them, then run: git worktree remove `"$wtPath`"; git branch -d task/$TaskId" -ForegroundColor Yellow
        return $false
    }

    $null = git worktree remove $wtPath 2>$null
    if (Test-Path $wtPath) {
        Write-Host "[HUMAN GATE] Worktree at $wtPath is locked (likely a gopls/test handle); left it and task/$TaskId in place. Run 'git worktree remove `"$wtPath`"' and 'git branch -d task/$TaskId' later to reclaim them." -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Restore-ImplementationWorktree {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$ProjectRoot
    )

    # Auto-recreate the implementation worktree from the restored branch
    $workspacesDir = Get-ConfiguredPath -Key "workspaces" -ProjectRoot $ProjectRoot
    $wtPath = Resolve-ImplementationWorktreePath -TaskId $TaskId -WorkspacesDir $workspacesDir

    # Prune stale worktrees first
    Invoke-GitChecked { git worktree prune }

    if (-not (Test-Path $wtPath)) {
        Invoke-GitChecked { git worktree add $wtPath "task/$TaskId" }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Warning: Failed to recreate implementation worktree at $wtPath" -ForegroundColor Yellow
        } else {
            Initialize-ImplementationWorktreeHooks -WorktreePath $wtPath
            Write-Quiet "[HUMAN GATE] Recreated implementation worktree at $wtPath"
        }
    }
}

function Get-ImplementationChangedFiles {
    param(
        [Parameter(Mandatory=$true)][string]$WorktreePath,
        [Parameter(Mandatory=$true)][string]$TaskId
    )

    # Use the configured primary and fail closed if its committed diff is unreadable. Item 225.
    $baseRef = Get-ConfiguredPrimaryBranch -ProjectRoot $WorktreePath
    $committed = @(git -C $WorktreePath diff --name-only "$baseRef...HEAD" 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read committed diff against '$baseRef' in '$WorktreePath'."
    }
    $changed = @($committed)

    $changed += @(git -C $WorktreePath diff --name-only --cached 2>$null)
    $changed += @(git -C $WorktreePath diff --name-only 2>$null)
    $changed += @(git -C $WorktreePath ls-files --others --exclude-standard 2>$null)

    return @($changed |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { Normalize-RepoRelativePath -Path ([string]$_) } |
        Sort-Object -Unique)
}

function Get-OutOfScopeImplementationFiles {
    param(
        [Parameter(Mandatory=$true)][string]$WorktreePath,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$FileAffinity
    )

    $changedFiles = @(Get-ImplementationChangedFiles -WorktreePath $WorktreePath -TaskId $TaskId)
    if ($changedFiles.Count -eq 0) { return @() }

    $affinity = @($FileAffinity |
        ForEach-Object { Normalize-RepoRelativePath -Path ([string]$_) } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($affinity.Count -eq 0) { return @() }

    $manifestFiles = @(Get-ConfiguredManifestFiles -ProjectRoot $WorktreePath)

    return @($changedFiles | Where-Object {
        $changedPath = $_
        $canonicalPath = $changedPath
        if ($changedPath.StartsWith("examples/gobot/.crucible/", [System.StringComparison]::OrdinalIgnoreCase)) {
            $canonicalPath = $changedPath.Substring(25)
        }

        # Bypass allowed manifest files (build side effects)
        $isManifest = $false
        foreach ($manifest in $manifestFiles) {
            $cleanManifest = $manifest.Replace("\", "/").Trim().TrimStart("/")
            if ($changedPath -eq $cleanManifest -or $canonicalPath -eq $cleanManifest -or 
                $changedPath -like "*/$cleanManifest" -or $canonicalPath -like "*/$cleanManifest") {
                $isManifest = $true
                break
            }
        }
        if ($isManifest) {
            return $false
        }

        -not (@($affinity | Where-Object {
            (Test-PathMatchesAffinity -ChangedPath $changedPath -Affinity $_) -or
            (Test-PathMatchesAffinity -ChangedPath $canonicalPath -Affinity $_)
        }).Count -gt 0)
    })
}
