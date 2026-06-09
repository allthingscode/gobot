# Implementation Phase Hooks Verification Test
# This test creates a temporary repo, enables worktreeConfig, adds the architect worktree, and verifies the hooksPath.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Temporary repository root
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-arch-hooks-" + [guid]::NewGuid().ToString("N"))

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
Push-Location $TempRoot
try {
    git init --quiet
    git config core.autocrlf false
    git config core.safecrlf false
    # Enable per‑worktree config extension
    git config extensions.worktreeConfig true
    # Add an initial commit so a worktree can be created
    Set-Content -Path "README.md" -Value "# Temp Repo" -Encoding UTF8
    git add README.md
    git commit -m "init" --quiet

    $CurrentBranch = (git rev-parse --abbrev-ref HEAD).Trim()
    $TaskId = "ARCH-001"
    $wtPath = Join-Path (Get-Location) ".crucible/.agent-workspaces/implementation-$TaskId"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        git worktree add $wtPath -b "task/$TaskId" $CurrentBranch 2>$null
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git worktree add failed with exit code $LASTEXITCODE"
    }
    # Ensure architect hooks directory exists and set absolute path
    $hookDir = Join-Path $TempRoot "scripts/hooks/architect"
    if (-not (Test-Path $hookDir)) { New-Item -ItemType Directory -Force -Path $hookDir | Out-Null }
    git -C $wtPath config --worktree core.hooksPath $hookDir

    $hooksPath = git -C $wtPath config --get core.hooksPath
    if ($hooksPath -ne $hookDir) {
        throw "Unexpected hooksPath: $hooksPath"
    }


    Write-Host "IMPLEMENTATION HOOKS TEST PASSED" -ForegroundColor Green
    exit 0
} finally {
    Pop-Location
    if (Test-Path $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
