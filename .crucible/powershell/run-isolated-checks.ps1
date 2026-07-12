param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,
    [ValidateSet("quick", "full", "test")]
    [string]$Mode = "full",
    [Parameter(Mandatory = $false)]
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Get-Location).Path
} else {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) {
        Write-Error ("-ProjectRoot path does not exist: {0}" -f $ProjectRoot)
    }
    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
}

$worktreeRoot = Join-Path $ProjectRoot ".crucible/.agent-workspaces"
$worktree = Join-Path $worktreeRoot ("implementation-" + $TaskId)
if (-not (Test-Path -LiteralPath $worktree)) {
    Write-Error ("Worktree missing: {0}" -f $worktree)
}
$worktree = (Resolve-Path -LiteralPath $worktree).Path

$branch = (& git -C $worktree rev-parse --abbrev-ref HEAD 2>$null).Trim()
$expectedBranch = "task/$TaskId"
if ($branch -ne $expectedBranch) {
    Write-Error ("Worktree branch mismatch. Expected '{0}', found '{1}'." -f $expectedBranch, $branch)
}

$configPath = Join-Path $ProjectRoot ".crucible/config.yaml"
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Error ("Configuration file not found: {0}" -f $configPath)
}

# Parse config.yaml for verification commands manually to avoid external module dependencies
$lines = Get-Content -LiteralPath $configPath -Encoding UTF8
$commands = @()
$inVerification = $false
$inMode = $false
$inConfigCheck = $false
$currentName = ""
$configCheckName = ""
$configCheckCommand = ""

# Map "test" mode to "quick" if the framework calls it with "test" for backward compatibility
$targetMode = if ($Mode -eq "test") { "quick" } else { $Mode }

foreach ($line in $lines) {
    if ($line -match "^verification:\s*$") {
        $inVerification = $true
        continue
    }
    if ($inVerification -and $line -match "^[a-zA-Z]") {
        $inVerification = $false
    }
    if ($inVerification) {
        if ($line -match "^\s{2}${targetMode}:\s*$") {
            $inMode = $true
            $inConfigCheck = $false
            continue
        }
        if ($line -match "^\s{2}config_check:\s*$") {
            $inConfigCheck = $true
            $inMode = $false
            continue
        }
        if (($inMode -or $inConfigCheck) -and $line -match "^\s{2}[a-zA-Z]") {
            $inMode = $false
            $inConfigCheck = $false
        }
        if ($inMode) {
            if ($line -match "^\s{4}-\s*name:\s*(.+?)\s*$") {
                $currentName = $Matches[1].Trim("`"' ")
            }
            if ($line -match "^\s{6}command:\s*(.+?)\s*$") {
                $commands += @{
                    Name = $currentName
                    Command = $Matches[1].Trim("`"' ")
                }
                $currentName = ""
            }
        }
        if ($inConfigCheck) {
            if ($line -match "^\s{4}name:\s*(.+?)\s*$") {
                $configCheckName = $Matches[1].Trim("`"' ")
            }
            if ($line -match "^\s{4}command:\s*(.+?)\s*$") {
                $configCheckCommand = $Matches[1].Trim("`"' ")
            }
        }
    }
}

if ($targetMode -eq "full" -and $configCheckName -and $configCheckCommand) {
    $commands += @{
        Name = $configCheckName
        Command = $configCheckCommand
    }
}


function Invoke-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$CommandString
    )
    Write-Host ("==> {0}" -f $Name)
    # Execute the string as a command line
    Invoke-Expression $CommandString
    if ($LASTEXITCODE -ne 0) {
        # Emit a stable stdout marker before throwing. The orchestrator parses this line
        # to name the failing check; child-process error rendering differs across
        # PowerShell editions (pwsh on Linux vs powershell.exe on Windows), so relying on
        # the thrown error text is not portable.
        Write-Host ("Check failed: {0}" -f $Name)
        throw ("Check failed: {0}" -f $Name)
    }
}

# Encoding guard (runs in every mode, before config commands and regardless of whether
# any are defined). A specialist can commit a UTF-8 BOM, mojibake, or introduced
# whitespace into an adopter deliverable that the config verification commands (build,
# vet, doc-lint) do not catch; without this the corruption survives to human review and
# costs a review strike. Scan only the files this task changed, so the gate stays fast
# and never flags pre-existing debt. Determine the branch fork point to diff against.
$defaultBranch = $null
foreach ($candidate in @("main", "master")) {
    & git -C $worktree rev-parse --verify --quiet ("refs/heads/" + $candidate) 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $defaultBranch = $candidate; break }
}
$base = $null
if ($defaultBranch) {
    $mergeBase = (& git -C $worktree merge-base HEAD $defaultBranch 2>$null)
    if ($mergeBase) { $base = $mergeBase.Trim() }
}

$changedRel = New-Object System.Collections.Generic.List[string]
if ($base) {
    foreach ($f in (& git -C $worktree diff --name-only --diff-filter=d $base HEAD)) {
        if ($f) { $changedRel.Add($f) }
    }
}
foreach ($f in (& git -C $worktree diff --name-only --diff-filter=d HEAD)) {
    if ($f) { $changedRel.Add($f) }
}
foreach ($f in (& git -C $worktree diff --name-only --cached --diff-filter=d)) {
    if ($f) { $changedRel.Add($f) }
}

$scanFiles = @()
foreach ($rel in ($changedRel | Sort-Object -Unique)) {
    if ($rel -match '\.(md|ps1)$') {
        $abs = Join-Path $worktree $rel
        if (Test-Path -LiteralPath $abs) { $scanFiles += $abs }
    }
}

Write-Host "==> Encoding guard (BOM/mojibake/whitespace on changed files)"
$mojibakeScript = Join-Path $PSScriptRoot "tests/check-mojibake.ps1"
if ($scanFiles.Count -gt 0 -and (Test-Path -LiteralPath $mojibakeScript)) {
    $host_exe = (Get-Process -Id $PID).Path
    & $host_exe -NoProfile -ExecutionPolicy Bypass -File $mojibakeScript @scanFiles
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Check failed: Encoding guard (BOM/mojibake)"
        throw "Check failed: Encoding guard (BOM/mojibake)"
    }
}
# Introduced-whitespace check over the task's own diff (trailing whitespace, blank line
# at EOF, space-before-tab). Only meaningful when the fork point is known.
if ($base) {
    & git -C $worktree diff --check $base HEAD
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Check failed: Encoding guard (whitespace)"
        throw "Check failed: Encoding guard (whitespace)"
    }
}

if ($commands.Count -eq 0) {
    Write-Host "No commands found for verification mode '${targetMode}'. Skipping checks." -ForegroundColor Yellow
    exit 0
}

Push-Location $worktree
try {
    foreach ($cmd in $commands) {
        Invoke-Check -Name $cmd.Name -CommandString $cmd.Command
    }
} finally {
    Pop-Location
}
