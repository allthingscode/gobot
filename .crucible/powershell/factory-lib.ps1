Set-StrictMode -Version Latest

$helpersPath = Join-Path $PSScriptRoot "lib/config-helpers.ps1"
if (-not (Test-Path -LiteralPath $helpersPath)) {
    throw "Required helper script not found at $helpersPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $helpersPath

$taskChecklistPath = Join-Path $PSScriptRoot "lib/task-checklist.ps1"
if (-not (Test-Path -LiteralPath $taskChecklistPath)) {
    throw "Required helper script not found at $taskChecklistPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $taskChecklistPath

# Canonical runtime FSM phase list. PowerShell ValidateSet attributes still need
# string literals, so keep those literals synchronized with this constant.
$script:FACTORY_PHASES = @("research", "grooming", "implementation", "verification", "deployment")

# Map FSM phase to assigned actor persona
$script:PHASE_ROLE_MAP = @{
    "research"       = "researcher"
    "grooming"       = "groomer"
    "implementation" = "architect"
    "verification"   = "reviewer"
    "deployment"     = "operator"
}

function Write-Quiet {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$ForegroundColor = "White"
    )
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(ValueFromRemainingArguments=$true)]$Arguments
    )
    $output = & $Command @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "[$Command] command failed with exit code $LASTEXITCODE. Output: $output"
    }
    return $output
}

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

$eventLogPath = Join-Path $PSScriptRoot "lib/event-log.ps1"
if (-not (Test-Path -LiteralPath $eventLogPath)) {
    throw "Required helper script not found at $eventLogPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $eventLogPath

$blockedPath = Join-Path $PSScriptRoot "lib/blocked.ps1"
if (-not (Test-Path -LiteralPath $blockedPath)) {
    throw "Required helper script not found at $blockedPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $blockedPath

$handoffPath = Join-Path $PSScriptRoot "lib/handoff.ps1"
if (-not (Test-Path -LiteralPath $handoffPath)) {
    throw "Required helper script not found at $handoffPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $handoffPath

$worktreePath = Join-Path $PSScriptRoot "lib/worktree.ps1"
if (-not (Test-Path -LiteralPath $worktreePath)) {
    throw "Required helper script not found at $worktreePath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $worktreePath

$factoryGatesPath = Join-Path $PSScriptRoot "lib/factory-gates.ps1"
if (-not (Test-Path -LiteralPath $factoryGatesPath)) {
    throw "Required helper script not found at $factoryGatesPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $factoryGatesPath

$sessionOutputPath = Join-Path $PSScriptRoot "lib/session-output.ps1"
if (-not (Test-Path -LiteralPath $sessionOutputPath)) {
    throw "Required helper script not found at $sessionOutputPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $sessionOutputPath
