#requires -Version 5.1
<#
.SYNOPSIS
Run the Crucible test suite under pwsh 7 in WSL - a local mirror of the CI
ubuntu-latest leg - against your CURRENT Windows working tree.

.DESCRIPTION
Syncs this repo (including uncommitted changes) into a WSL ext4 directory via
rsync, then runs run-all-tests.ps1 there with CI-parity concurrency. All paths
are derived at runtime from the script's own location; nothing machine-specific
is stored in this file. Requires WSL2 with a provisioned distro - see
scripts/wsl-bootstrap.sh.

.PARAMETER Distro
WSL distro to target. Defaults to your default distro.

.PARAMETER WslDir
Destination inside the distro. A leading ~ expands to the distro user's home.
Defaults to ~/crucible.

.PARAMETER Jobs
CRUCIBLE_TEST_JOBS value. Defaults to 3 (what CI uses on Linux).

.PARAMETER SyncOnly
Sync the working tree into WSL but do not run the suite.

.EXAMPLE
scripts/test-linux.ps1
#>
[CmdletBinding()]
param(
    [string]$Distro = '',
    [string]$WslDir = '~/crucible',
    [int]$Jobs = 3,
    [switch]$SyncOnly
)
$ErrorActionPreference = 'Stop'

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Write-Error 'WSL not found. Install with: wsl --install -d Ubuntu (see CONTRIBUTING.md).'
    exit 1
}

function Invoke-Wsl([string[]]$WslArgs) {
    if ($Distro) { & wsl.exe -d $Distro @WslArgs } else { & wsl.exe @WslArgs }
}

# Pass bash via base64 so no PowerShell/wsl.exe quoting can corrupt it.
function Invoke-WslBash([string]$Script) {
    $enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    Invoke-Wsl @('--', 'bash', '-lc', "printf %s '$enc' | base64 -d | bash")
}
function Get-WslBash([string]$Script) {
    $enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    if ($Distro) { (& wsl.exe -d $Distro -- bash -lc "printf %s '$enc' | base64 -d | bash") }
    else { (& wsl.exe -- bash -lc "printf %s '$enc' | base64 -d | bash") }
}

# Repo root from this script's own location - no hardcoded path.
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($repoRoot -notmatch '^[A-Za-z]:\\') {
    Write-Error "Repo root '$repoRoot' is not a local drive path; cannot map to /mnt. Run the suite inside WSL by hand."
    exit 1
}
# C:\path -> /mnt/c/path (default WSL automount layout).
$wslSrc = '/mnt/' + $repoRoot.Substring(0, 1).ToLower() + ($repoRoot.Substring(2) -replace '\\', '/')

Invoke-Wsl @('--', 'bash', '-lc', 'command -v rsync >/dev/null')
if ($LASTEXITCODE -ne 0) {
    Write-Error 'rsync not found in the distro. Provision it with: bash scripts/wsl-bootstrap.sh'
    exit 1
}

# Resolve a leading ~ against the distro user's actual home.
$dest = $WslDir
if ($WslDir.StartsWith('~')) {
    $wslHome = (Get-WslBash 'printf %s "$HOME"')
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wslHome)) {
        Write-Error 'Could not resolve the distro user home directory.'
        exit 1
    }
    $dest = "$($wslHome.Trim())$($WslDir.Substring(1))"
}

Write-Host "Syncing working tree -> $dest (WSL)..."
$syncScript = "set -e`nmkdir -p '$dest'`nrsync -a --delete --exclude=.git/index.lock '$wslSrc/' '$dest/'"
Invoke-WslBash $syncScript
if ($LASTEXITCODE -ne 0) { Write-Error 'Sync (rsync) failed.'; exit 1 }

if ($SyncOnly) { Write-Host 'Sync complete (-SyncOnly); skipping tests.'; exit 0 }

Write-Host "Running suite under pwsh 7 (CRUCIBLE_TEST_JOBS=$Jobs)..."
$runScript = "cd '$dest'`nCRUCIBLE_TEST_JOBS=$Jobs pwsh -NoProfile -File powershell/run-all-tests.ps1"
Invoke-WslBash $runScript
exit $LASTEXITCODE
