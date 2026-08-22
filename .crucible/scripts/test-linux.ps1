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

$stampLib = Join-Path $repoRoot 'powershell/lib/linux-leg-stamp.ps1'
if (-not (Test-Path -LiteralPath $stampLib)) {
    $stampLib = Join-Path $repoRoot 'powershell/tests/linux-leg-stamp.ps1'
}
. $stampLib

# Capture start-of-run state before rsync
$saved = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$headAtStartRaw = & git -C $repoRoot rev-parse HEAD 2>$null
$gitCode = $LASTEXITCODE
$ErrorActionPreference = $saved
if ($gitCode -ne 0 -or [string]::IsNullOrWhiteSpace($headAtStartRaw)) {
    Write-Error 'Could not resolve HEAD before test run; cannot verify state.'
    exit 1
}
$headAtStart = ([string]$headAtStartRaw).Trim()

try {
    $digestAtStart = Get-LinuxLegWorkingTreeDigest -RepoRoot $repoRoot
} catch {
    Write-Error "Could not compute working tree digest before test run: $_"
    exit 1
}

$saved = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$untrackedFiles = @(git -C $repoRoot ls-files -o --exclude-standard -- powershell scripts/hooks 2>$null)
$gitCode = $LASTEXITCODE
$ErrorActionPreference = $saved

if ($gitCode -eq 0 -and $untrackedFiles.Count -gt 0) {
    $nonEmptyUntracked = @($untrackedFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($nonEmptyUntracked.Count -gt 0) {
        Write-Host ("[WARN] " + $nonEmptyUntracked.Count + " untracked file(s) under powershell/ or scripts/hooks/ were included in the Linux run but are not covered by the verification digest (they cannot be pushed):") -ForegroundColor Yellow
        foreach ($uf in $nonEmptyUntracked) {
            $normUf = $uf.Trim().Replace('\', '/')
            Write-Host "    - $normUf" -ForegroundColor Yellow
        }
    }
}

Write-Host "Syncing working tree -> $dest (WSL)..."
$syncScript = "set -e`nmkdir -p '$dest'`nrsync -a --delete --exclude=.git/index.lock '$wslSrc/' '$dest/'"
Invoke-WslBash $syncScript
if ($LASTEXITCODE -ne 0) { Write-Error 'Sync (rsync) failed.'; exit 1 }

if ($SyncOnly) { Write-Host 'Sync complete (-SyncOnly); skipping tests.'; exit 0 }

Write-Host "Running suite under pwsh 7 (CRUCIBLE_TEST_JOBS=$Jobs)..."
$runScript = "cd '$dest'`nCRUCIBLE_TEST_JOBS=$Jobs pwsh -NoProfile -File powershell/run-all-tests.ps1"
Invoke-WslBash $runScript
$exitCode = $LASTEXITCODE

# Guard against HEAD or working tree moving during the run (D4)
$saved = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$headAtEndRaw = & git -C $repoRoot rev-parse HEAD 2>$null
$gitCode = $LASTEXITCODE
$ErrorActionPreference = $saved
$headAtEnd = if ($gitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($headAtEndRaw)) { ([string]$headAtEndRaw).Trim() } else { '' }

$digestAtEnd = $null
try {
    $digestAtEnd = Get-LinuxLegWorkingTreeDigest -RepoRoot $repoRoot
} catch {
    Write-Host "[FAIL] Could not recompute working tree digest after test run." -ForegroundColor Red
}

if ($headAtEnd -ne $headAtStart) {
    Write-Host "[FAIL] HEAD moved during the Linux test run (started at $headAtStart, now at $headAtEnd); refusing to stamp." -ForegroundColor Red
    $finalExit = if ($exitCode -ne 0) { $exitCode } else { 1 }
    exit $finalExit
}

if ($null -eq $digestAtEnd -or $digestAtEnd.Digest -ne $digestAtStart.Digest) {
    Write-Host "[FAIL] Working tree content changed during the Linux test run; refusing to stamp." -ForegroundColor Red
    $finalExit = if ($exitCode -ne 0) { $exitCode } else { 1 }
    exit $finalExit
}

if (Set-LinuxLegStamp -RepoRoot $repoRoot -ExitCode $exitCode -Commit $headAtStart -ContentDigest $digestAtStart.Digest -PathCount $digestAtStart.PathCount -Paths $digestAtStart.Map) {
    Write-Host "[OK] Linux leg verification stamp recorded at .private/linux-leg-stamp.json." -ForegroundColor Green
}

exit $exitCode
