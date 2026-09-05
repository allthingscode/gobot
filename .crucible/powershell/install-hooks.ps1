# Installs git hooks for the Crucible framework repository or an adopter repository.
$ErrorActionPreference = "Stop"

# Determine if we are in the framework repo or an adopter
$parentDir = (Resolve-Path -Path "$PSScriptRoot/..").Path
$grandParentDir = (Resolve-Path -Path "$PSScriptRoot/../..").Path

if (Test-Path -LiteralPath (Join-Path $parentDir ".git")) {
    # Framework repo mode
    $repoRoot = $parentDir
    $hooksPath = "scripts/hooks"
} elseif (Test-Path -LiteralPath (Join-Path $grandParentDir ".git")) {
    # Adopter repo mode
    $repoRoot = $grandParentDir
    $hooksPath = ".crucible/scripts/hooks"
} else {
    throw "Not a git repository (missing .git directory)."
}

# Verify the hooks directory actually exists
$fullHooksDir = Join-Path $repoRoot $hooksPath
if (-not (Test-Path -LiteralPath $fullHooksDir)) {
    throw "Hooks directory not found: $fullHooksDir"
}

# Configure core.hooksPath in Git
Push-Location $repoRoot
try {
    git config core.hooksPath $hooksPath
    Write-Host "Success: Set git core.hooksPath to '$hooksPath' in $repoRoot" -ForegroundColor Green
} finally {
    Pop-Location
}

# Setting core.hooksPath shadows the repo's own hooks directory rather than
# emptying it, so a hook installed the old way stays on disk and stops running.
# That is fine until the config is lost - a `git config --unset core.hooksPath`,
# a tool that rewrites local config, a worktree that never inherited it - at
# which point the stale file becomes live again, and the ones this project has
# left behind reference gates that were since renamed or deleted. Report them by
# name rather than removing them: in an adopter repo the contents of .git/hooks
# may be the adopter's own, and deleting another project's hooks is not this
# script's call to make.
$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"
Push-Location $repoRoot
try {
    # --git-dir, not --git-path hooks. `--git-path hooks` resolves through
    # core.hooksPath, which the block above has just set, so it would hand back
    # scripts/hooks - the directory being installed to - and this check would
    # inspect the wrong place, find it holds no strays, and report nothing. It
    # resolves correctly when .git is a file, which it is in a worktree.
    $gitDirRel = git rev-parse --git-dir
    $gitPathCode = $LASTEXITCODE
} finally {
    Pop-Location
    $ErrorActionPreference = $prev
}

if ($gitPathCode -ne 0 -or [string]::IsNullOrWhiteSpace($gitDirRel)) {
    Write-Host "Warning: could not resolve the repository git directory; skipped the shadowed-hook check." -ForegroundColor Yellow
} else {
    # Relative (".git") from the repo root, but absolute inside a linked worktree.
    $gitDir = ([string]$gitDirRel).Trim()
    if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
        $gitDir = Join-Path $repoRoot $gitDir
    }
    $gitHooksDir = Join-Path $gitDir "hooks"
    if (Test-Path -LiteralPath $gitHooksDir) {
        # .sample files ship with every git init and are inert by name.
        $shadowed = @(Get-ChildItem -LiteralPath $gitHooksDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike "*.sample" })
        if ($shadowed.Count -gt 0) {
            Write-Host ("Warning: " + $shadowed.Count + " hook file(s) in " + $gitHooksDir + " are now shadowed by core.hooksPath and will not run:") -ForegroundColor Yellow
            foreach ($h in $shadowed) {
                Write-Host ("    - " + $h.Name) -ForegroundColor Yellow
            }
            Write-Host "    Delete them once you have confirmed they are not yours to keep." -ForegroundColor Yellow
        }
    }
}

# On Unix, git only runs hooks that carry the executable bit. A bundle installed
# or committed on Windows records mode 100644, so a clone on Linux/macOS would
# silently skip every gate. Ensure the activated hooks are executable here. This
# is self-healing per clone because core.hooksPath is local (uncommitted) config,
# so this script already runs after every fresh clone.
$onWindows = $true
if ($PSVersionTable.PSEdition -eq "Core") {
    $onWindows = (Get-Variable IsWindows -ValueOnly -ErrorAction SilentlyContinue) -ne $false
}
if (-not $onWindows) {
    Get-ChildItem -LiteralPath $fullHooksDir -File | ForEach-Object {
        & chmod "+x" $_.FullName
    }
    Write-Host "Marked hook scripts executable for this platform." -ForegroundColor Green
}

