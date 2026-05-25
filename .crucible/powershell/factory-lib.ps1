Set-StrictMode -Version Latest

$helpersPath = Join-Path $PSScriptRoot "lib/config-helpers.ps1"
if (-not (Test-Path -LiteralPath $helpersPath)) {
    throw "Required helper script not found at $helpersPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $helpersPath

# Canonical runtime specialist list. PowerShell ValidateSet attributes still need
# string literals, so keep those literals synchronized with this constant.
$script:FACTORY_SPECIALISTS = @("groomer", "architect", "reviewer", "operator", "researcher")

function Get-BacklogItemPathForTask {
    param([Parameter(Mandatory = $true)][string]$Task)

    $typeDir = if ($Task -match "^F-") {
        "features"
    } elseif ($Task -match "^B-") {
        "bugs"
    } elseif ($Task -match "^C-") {
        "chores"
    } else {
        ""
    }

    $typeDirs = if ([string]::IsNullOrWhiteSpace($typeDir)) {
        @("features", "bugs", "chores")
    } else {
        @($typeDir)
    }

    $backlogDir = Get-ConfiguredPath -Key "backlog"
    foreach ($dir in $typeDirs) {
        $activeMatch = Get-ChildItem -Path (Join-Path $backlogDir ($dir + "/active")) -Filter ($Task + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $activeMatch) {
            return $activeMatch.FullName
        }

        $rootMatch = Get-ChildItem -Path (Join-Path $backlogDir $dir) -Filter ($Task + "_*.md") -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $rootMatch) {
            return $rootMatch.FullName
        }
    }

    return ""
}

function Get-SpecBudgetTier {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [switch]$IncludePath
    )

    $specPath = Get-BacklogItemPathForTask -Task $Task
    if ([string]::IsNullOrWhiteSpace($specPath) -or -not (Test-Path -LiteralPath $specPath)) {
        if ($IncludePath) {
            return @{ Tier = ""; Path = "" }
        }
        return ""
    }

    $tier = ""
    $frontmatter = Get-Content -LiteralPath $specPath -Head 30
    foreach ($line in $frontmatter) {
        if ($line -match '^\s*budget_tier:\s*"?(\w+)"?\s*$') {
            $tier = $matches[1].ToLowerInvariant()
            break
        }
    }

    if ($IncludePath) {
        return @{ Tier = $tier; Path = $specPath }
    }
    return $tier
}

function Invoke-FileLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [int]$TimeoutMs = 5000,
        [string]$TimeoutMessage = "[LOCK] Timeout reached; removing stale lock."
    )

    $lockAcquired = $false
    $lockWaitTime = 0
    while (-not $lockAcquired) {
        try {
            $fileStream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew)
            $fileStream.Close()
            $lockAcquired = $true
        } catch [System.IO.IOException] {
            if ($lockWaitTime -ge $TimeoutMs) {
                Write-Quiet $TimeoutMessage -ForegroundColor Yellow
                Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
                $lockWaitTime = 0
            } else {
                Start-Sleep -Milliseconds 100
                $lockWaitTime += 100
            }
        }
    }

    try {
        & $ScriptBlock
    } finally {
        if (Test-Path $LockPath) {
            Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
        }
    }
}
