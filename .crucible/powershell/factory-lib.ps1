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

# Handoff ceilings per tier. Sized so a task can absorb normal review-fix cycles before
# tripping the budget breaker: the minimal happy path is ~5 handoffs (bootstrap -> grooming ->
# implementation -> verification -> deployment -> done) and each CHANGES_REQUESTED review cycle
# adds 2 (verification -> implementation -> verification). 'low' therefore allows ~2 review
# cycles plus the terminal deployment->done handoff; higher tiers scale up for research and
# more iteration. (Raised 2026-06-27: low 6->10/medium 10->16/high 24->28/extended 32->40 after
# a clean, approved low-tier task tripped the breaker at deployment->done with a single review cycle.)
$script:BUDGET_TIERS = @("low", "medium", "high", "extended")
$script:BUDGET_CEILINGS = @{ low = 10; medium = 16; high = 28; extended = 40 }

# A framework-forced rebase-conflict rework (accept-gate auto-rebase routing back to
# implementation) consumes a full re-run -- re-entry -> implementation -> verification
# -> deployment -> done, ~5 handoffs -- that is NOT quality churn. Each such cycle
# (tracked by rebase_count) earns this much headroom on top of the tier ceiling so a
# task that merely collided on a line is not blocked by the quality budget breaker.
$script:REBASE_CYCLE_ALLOWANCE = 5

function Get-RebaseCycleAllowance {
    return $script:REBASE_CYCLE_ALLOWANCE
}

function Get-BudgetCeilings {
    return $script:BUDGET_CEILINGS.Clone()
}

function Test-BudgetTier {
    param([AllowNull()][string]$BudgetTier)

    if ([string]::IsNullOrWhiteSpace($BudgetTier)) {
        return $false
    }

    return $script:BUDGET_CEILINGS.ContainsKey($BudgetTier.Trim().ToLowerInvariant())
}

function Get-BudgetTierList {
    return [string[]]$script:BUDGET_TIERS
}

# Map FSM phase to assigned actor persona
$script:PHASE_ROLE_MAP = @{
    "research"       = "researcher"
    "grooming"       = "groomer"
    "implementation" = "architect"
    "verification"   = "reviewer"
    "deployment"     = "operator"
}

# Model selection is two stage. Get-SpecialistModel maps the activity (target_phase,
# budget_tier, design_required) to an abstract CAPABILITY TIER (strong/default/light);
# Get-ConfiguredModel (lib/config-helpers.ps1) then resolves that tier to a concrete model
# for the active -Target (claude/codex/antigravity), reading the editable `models:` block in
# config.yaml. This keeps provider-specific model names out of the routing logic and in
# config, where they are easy to update as models change. Default to the 'default' tier and
# escalate to 'strong' only where the activity warrants deeper reasoning: open-ended research,
# novel design, or high/extended budget. The mechanical Operator runs on the 'light' tier.
# The orchestrator reads the printed [RECOMMENDED MODEL] line rather than hard-coding a table.
$script:TIER_STRONG  = "strong"
$script:TIER_DEFAULT = "default"
$script:TIER_LIGHT   = "light"
$script:MODEL_ESCALATION_TIERS = @("high", "extended")

# Codex reasoning effort, keyed by the same abstract tier as the model. Claude's Agent dispatch
# has no effort knob (effort is encoded in the model tier), so this is consumed only when the
# dispatch target is codex, via launch-codex-specialist.ps1 -Effort. The light tier carries
# 'high' deliberately: the cheaper light-tier model is given more reasoning to compensate.
$script:TIER_EFFORT = @{ strong = "high"; default = "medium"; light = "high" }

function Get-SpecialistModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TargetPhase,
        [string]$BudgetTier = "medium",
        [bool]$DesignRequired = $false
    )

    $phase = if ($null -ne $TargetPhase) { $TargetPhase.Trim().ToLowerInvariant() } else { "" }
    $tier  = if ([string]::IsNullOrWhiteSpace($BudgetTier)) { "medium" } else { $BudgetTier.Trim().ToLowerInvariant() }
    $tierEscalates = $script:MODEL_ESCALATION_TIERS -contains $tier

    switch ($phase) {
        "research"       { return $script:TIER_STRONG }
        "grooming"       { if ($tierEscalates) { return $script:TIER_STRONG } else { return $script:TIER_DEFAULT } }
        "implementation" { if ($DesignRequired -or $tierEscalates) { return $script:TIER_STRONG } else { return $script:TIER_DEFAULT } }
        "verification"   { if ($tierEscalates) { return $script:TIER_STRONG } else { return $script:TIER_DEFAULT } }
        "deployment"     { if ($tierEscalates) { return $script:TIER_DEFAULT } else { return $script:TIER_LIGHT } }
        "done"           { return "" }
        default          { return $script:TIER_DEFAULT }
    }
}

# Sticky per-task specialist target. The human picks -Target once (e.g. codex); persist it
# per task so every later phase's -Init recommends the same specialist instead of resetting
# to the default. An explicit -Target (Explicit=$true) overwrites the stored value; an
# omitted -Target reloads it. Returns the resolved target (unchanged when there is no TaskId
# or no stored value). Silently ignores an unrecognized stored value.
function Resolve-StickyTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SessionDir,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory = $true)][bool]$Explicit
    )
    if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($SessionDir)) {
        return $Target
    }
    $stateFile = Join-Path $SessionDir ($TaskId + "/target.txt")
    if ($Explicit) {
        $stateDir = Split-Path -Parent $stateFile
        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
        }
        Set-Content -LiteralPath $stateFile -Value $Target -Encoding UTF8
        return $Target
    }
    if (Test-Path -LiteralPath $stateFile) {
        $stored = (Get-Content -LiteralPath $stateFile -Raw).Trim()
        if (@("agent", "claude", "codex", "antigravity") -contains $stored) {
            return $stored
        }
    }
    return $Target
}

# Resolve an abstract capability tier (strong/default/light) to a Codex reasoning effort.
# Returns "" for an empty/unknown tier (e.g. the 'done' phase) so the caller emits nothing.
function Get-SpecialistEffort {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Tier)

    $t = if ($null -ne $Tier) { $Tier.Trim().ToLowerInvariant() } else { "" }
    if ($script:TIER_EFFORT.ContainsKey($t)) { return $script:TIER_EFFORT[$t] }
    return ""
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

. (Join-Path $PSScriptRoot "lib/platform.ps1")

$taskRewindPath = Join-Path $PSScriptRoot "lib/task-rewind.ps1"
if (-not (Test-Path -LiteralPath $taskRewindPath)) {
    throw "Required helper script not found at $taskRewindPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $taskRewindPath

function ConvertTo-AsciiSafeText {
    # Transliterate the smart punctuation agents routinely emit (em/en dashes, curly
    # quotes, ellipsis, arrows, bullet, nbsp) to ASCII, then drop any remaining non-ASCII
    # so a reason string survives a UTF-8 JSON round-trip without mojibake. Reasons are
    # short human-readable strings, not content, so lossy transliteration is acceptable.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $map = @{
        [char]0x2013 = '-'; [char]0x2014 = '-'; [char]0x2012 = '-'; [char]0x2015 = '-'
        [char]0x2018 = "'"; [char]0x2019 = "'"; [char]0x201A = "'"; [char]0x2032 = "'"
        [char]0x201C = '"'; [char]0x201D = '"'; [char]0x201E = '"'; [char]0x2033 = '"'
        [char]0x2026 = '...'; [char]0x2192 = '->'; [char]0x2190 = '<-'; [char]0x2022 = '*'
        [char]0x00A0 = ' '
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        if ($map.ContainsKey($ch)) {
            [void]$sb.Append($map[$ch])
        } elseif ([int]$ch -lt 128) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString()
}

