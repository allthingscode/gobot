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

function Resolve-ImplementationWorktreePath {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$WorkspacesDir = $workspacesDir
    )

    return Join-Path $WorkspacesDir ("implementation-" + $TaskId)
}

function Get-ImplementationChangedFiles {
    param(
        [Parameter(Mandatory=$true)][string]$WorktreePath,
        [Parameter(Mandatory=$true)][string]$TaskId
    )

    $candidateBaseRefs = @("main", "master", "origin/main", "origin/master")
    $baseRef = $null
    foreach ($candidate in $candidateBaseRefs) {
        $null = git -C $WorktreePath rev-parse --verify --quiet $candidate 2>$null
        if ($LASTEXITCODE -eq 0) {
            $baseRef = $candidate
            break
        }
    }

    $changed = @()
    if ($null -ne $baseRef) {
        $committed = @(git -C $WorktreePath diff --name-only "$baseRef...HEAD" 2>$null)
        if ($LASTEXITCODE -ne 0 -or @($committed).Count -eq 0) {
            $committed = @(git -C $WorktreePath diff --name-only "$baseRef..task/$TaskId" 2>$null)
        }
        $changed += $committed
    }

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
        [Parameter(Mandatory=$true)][object[]]$FileAffinity
    )

    $changedFiles = @(Get-ImplementationChangedFiles -WorktreePath $WorktreePath -TaskId $TaskId)
    if ($changedFiles.Count -eq 0) { return @() }

    $affinity = @($FileAffinity |
        ForEach-Object { Normalize-RepoRelativePath -Path ([string]$_) } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($affinity.Count -eq 0) { return $changedFiles }

    return @($changedFiles | Where-Object {
        $changedPath = $_
        $canonicalPath = $changedPath
        if ($changedPath.StartsWith("examples/gobot/.crucible/", [System.StringComparison]::OrdinalIgnoreCase)) {
            $canonicalPath = $changedPath.Substring(25)
        }
        -not (@($affinity | Where-Object {
            (Test-PathMatchesAffinity -ChangedPath $changedPath -Affinity $_) -or
            (Test-PathMatchesAffinity -ChangedPath $canonicalPath -Affinity $_)
        }).Count -gt 0)
    })
}
