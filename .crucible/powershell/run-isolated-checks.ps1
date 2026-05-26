param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,
    [ValidateSet("quick", "full", "test")]
    [string]$Mode = "full"
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$worktree = Join-Path ".crucible/.agent-workspaces" ("architect-" + $TaskId)
if (-not (Test-Path $worktree)) {
    Write-Error ("Worktree missing: {0}" -f $worktree)
}
$worktree = (Resolve-Path $worktree).Path

$branch = (& git -C $worktree rev-parse --abbrev-ref HEAD 2>$null).Trim()
$expectedBranch = "task/$TaskId"
if ($branch -ne $expectedBranch) {
    Write-Error ("Worktree branch mismatch. Expected '{0}', found '{1}'." -f $expectedBranch, $branch)
}

$configPath = ".crucible/config.yaml"
if (-not (Test-Path $configPath)) {
    Write-Error ("Configuration file not found: {0}" -f $configPath)
}

# Parse config.yaml for verification commands manually to avoid external module dependencies
$lines = Get-Content $configPath
$commands = @()
$inVerification = $false
$inMode = $false
$currentName = ""

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
            continue
        }
        if ($inMode -and $line -match "^\s{2}[a-zA-Z]") {
            $inMode = $false
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
        throw ("Check failed: {0}" -f $Name)
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
