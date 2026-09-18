# One answer to "which files in this repository should a scan-based check read?", asked of
# git rather than of the filesystem.
#
# The distinction is not academic. Agent tooling creates real git worktrees under
# .claude/worktrees/<agent-id>/, and a worktree is a full second checkout, so a recursive
# Get-ChildItem from the repository root returns two copies of every tracked file. A lint
# that reports a file path then names one inside a directory that is deleted the moment the
# agent exits: the failure reads as a real violation in a real file, the evidence is gone
# before anyone can look, and the run gets written off as flake. Not hypothetical - a full
# suite run went 96/97 this way, naming eighteen paths under a worktree. Item 87.
#
# Asking git makes .gitignore the single definition of what a scan skips, with git itself as
# the implementation. The alternative this replaces was a list of directory prefixes copied
# into each scanning test: native-stderr-idiom.tests.ps1 carried three - .private/,
# .agent-workspaces/ and .crucible/ - each one restating a line of .gitignore, and none of
# them .claude/worktrees/, because a hand-kept list only ever covers the hazards somebody
# remembered.
#
# Two independent git behaviours keep an agent worktree out, and they cover different shapes.
# A real worktree holds a .git file, so git treats it as a separate repository and reports the
# directory itself instead of descending - which means an extension-filtered scan never sees
# inside one even with no ignore rule at all. Plain files under the same path, such as the
# residue of a worktree whose directory outlived its registration, are excluded only by
# .gitignore. framework-gitignore.tests.ps1 pins the two separately, because a fixture built
# only from the worktree shape would still pass with the ignore rule deleted.
#
# --others is not optional. Without it a file that exists but has never been git add-ed is
# invisible, and a check that stops reading brand-new code is a worse trade than one that
# reads a worktree. --exclude-standard is what applies .gitignore to those untracked files.
#
# Requires: Invoke-Git (powershell/lib/platform.ps1). Loaded here rather than left to the
# caller, for the reason native-stderr-idiom.tests.ps1 pins for Invoke-GitChecked: dot-sourcing
# flattens scope, so a file that relies on a sibling having loaded first works by accident of
# load order until it is the first thing loaded.
. (Join-Path $PSScriptRoot "platform.ps1")

function Get-RepoScannableFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        # Scope, not noise. A caller narrowing to powershell/ is stating what its rule is
        # about; it is not compensating for directories git already excludes. The two kinds
        # of filtering are separated on purpose - noise is .gitignore's job and is applied
        # above, before any caller is consulted.
        [string[]]$IncludePrefix = @(),
        [string[]]$ExcludePrefix = @(),
        [string[]]$Extension = @()
    )

    if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
        throw ("Get-RepoScannableFile: RepoRoot '" + $RepoRoot + "' is not a directory.")
    }
    $rootFull = (Resolve-Path -LiteralPath $RepoRoot).Path

    $listed = Invoke-Git @("ls-files", "--cached", "--others", "--exclude-standard") -Directory $rootFull
    if ($listed.ExitCode -ne 0) {
        throw ("Get-RepoScannableFile: git ls-files failed in '" + $rootFull + "' with exit " +
            $listed.ExitCode + ". Returning an empty list here would report every check built on " +
            "this enumeration clean, so it throws instead.")
    }

    $all = @($listed.Lines |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { ([string]$_).Trim().Replace("\", "/") } |
        # A trailing slash is git reporting a nested repository it declined to enter - an
        # agent worktree, in practice. It is a directory, not a file, and a caller that
        # applied no extension filter would otherwise be handed one as if it were.
        Where-Object { -not $_.EndsWith("/") })

    if ($all.Count -eq 0) {
        throw ("Get-RepoScannableFile: git reported no files at all in '" + $rootFull +
            "'. That is a broken premise rather than a clean result - every check built on " +
            "this enumeration would pass having read nothing.")
    }

    $selected = @($all)

    if (@($IncludePrefix).Count -gt 0) {
        $keep = @(Get-NormalizedScanPrefix -Prefix $IncludePrefix)
        $selected = @($selected | Where-Object { Test-ScanPathUnderPrefix -Path $_ -Prefix $keep })
    }
    if (@($ExcludePrefix).Count -gt 0) {
        $drop = @(Get-NormalizedScanPrefix -Prefix $ExcludePrefix)
        $selected = @($selected | Where-Object { -not (Test-ScanPathUnderPrefix -Path $_ -Prefix $drop) })
    }
    if (@($Extension).Count -gt 0) {
        $wanted = @($Extension |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ } |
            ForEach-Object { if ($_.StartsWith(".")) { $_ } else { "." + $_ } })
        $selected = @($selected | Where-Object { [System.IO.Path]::GetExtension($_) -in $wanted })
    }

    $separator = [string][System.IO.Path]::DirectorySeparatorChar
    return @($selected | Sort-Object | ForEach-Object {
        [pscustomobject]@{
            RelativePath = $_
            FullName     = (Join-Path $rootFull $_.Replace("/", $separator))
            Name         = [System.IO.Path]::GetFileName($_)
            Extension    = [System.IO.Path]::GetExtension($_)
        }
    } | Where-Object {
        # An index entry whose file is gone - deleted in the working tree without being
        # staged - would hand every caller a path that Get-Content cannot open. Dropping it
        # is the honest reading: the file is not there to be scanned. This is after the
        # emptiness check above, so it cannot be the thing that empties the list quietly.
        Test-Path -LiteralPath $_.FullName -PathType Leaf
    })
}

function Get-NormalizedScanPrefix {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Prefix)
    return @($Prefix |
        ForEach-Object { ([string]$_).Trim().Replace("\", "/").TrimEnd("/") } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-ScanPathUnderPrefix {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Prefix
    )
    foreach ($candidate in $Prefix) {
        if ($Path -eq $candidate) { return $true }
        if ($Path.StartsWith($candidate + "/", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
