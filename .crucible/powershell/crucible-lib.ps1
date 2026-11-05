Set-StrictMode -Version Latest

$helpersPath = Join-Path $PSScriptRoot "lib/config-helpers.ps1"
if (-not (Test-Path -LiteralPath $helpersPath)) {
    [Console]::Error.WriteLine("Required helper script not found at $helpersPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository.")
    exit 1
}
. $helpersPath

$taskChecklistPath = Join-Path $PSScriptRoot "lib/task-checklist.ps1"
if (-not (Test-Path -LiteralPath $taskChecklistPath)) {
    [Console]::Error.WriteLine("Required helper script not found at $taskChecklistPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository.")
    exit 1
}
. $taskChecklistPath

$timePath = Join-Path $PSScriptRoot "lib/time.ps1"
if (-not (Test-Path -LiteralPath $timePath)) {
    [Console]::Error.WriteLine("Required helper script not found at $timePath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository.")
    exit 1
}
. $timePath

# Canonical runtime FSM phase list. PowerShell ValidateSet attributes still need
# string literals, so keep those literals synchronized with this constant.
$script:CRUCIBLE_PHASES = @("research", "grooming", "implementation", "verification", "deployment")

# Handoff ceilings per tier. Sized so a task can absorb normal review-fix cycles before
# tripping the budget breaker: the minimal happy path is ~5 handoffs (bootstrap -> grooming ->
# implementation -> verification -> deployment -> done) and each CHANGES_REQUESTED review cycle
# adds 2 (verification -> implementation -> verification). 'low' therefore allows ~2 review
# cycles plus the terminal deployment->done handoff; higher tiers scale up for research and
# more iteration.
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
# for the active -Target (claude/codex/antigravity/grok), reading the editable `models:` block in
# config.yaml. This keeps provider-specific model names out of the routing logic and in
# config, where they are easy to update as models change. Default to the 'default' tier and
# escalate to 'strong' only where the activity warrants deeper reasoning: open-ended research,
# novel design, or high/extended budget. The Operator's work is procedural and does not grow
# with the item, so it runs on the 'light' tier whatever the budget, and moves to 'default'
# only when the deployment itself is in trouble: a rebase re-entry or a retried handoff.
# The orchestrator reads the printed [RECOMMENDED MODEL] line rather than hard-coding a table.
$script:TIER_STRONG  = "strong"
$script:TIER_DEFAULT = "default"
$script:TIER_LIGHT   = "light"
$script:MODEL_ESCALATION_TIERS = @("high", "extended")
# For a codex target a tier is a level, a model and an effort together: Get-CodexLevel
# (lib/config-helpers.ps1) resolves both halves at once.

function Get-SpecialistModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TargetPhase,
        [string]$BudgetTier = "medium",
        [bool]$DesignRequired = $false,
        [int]$RebaseCount = 0,
        [int]$HandoffRetryCount = 0
    )

    $phase = if ($null -ne $TargetPhase) { $TargetPhase.Trim().ToLowerInvariant() } else { "" }
    $tier  = if ([string]::IsNullOrWhiteSpace($BudgetTier)) { "medium" } else { $BudgetTier.Trim().ToLowerInvariant() }
    $tierEscalates = $script:MODEL_ESCALATION_TIERS -contains $tier

    switch ($phase) {
        "research"       { return $script:TIER_STRONG }
        "grooming"       { if ($tierEscalates) { return $script:TIER_STRONG } else { return $script:TIER_DEFAULT } }
        "implementation" { if ($DesignRequired -or $tierEscalates) { return $script:TIER_STRONG } else { return $script:TIER_DEFAULT } }
        "verification"   { if ($tierEscalates) { return $script:TIER_STRONG } else { return $script:TIER_DEFAULT } }
        "deployment"     { if ($RebaseCount -gt 0 -or $HandoffRetryCount -gt 0) { return $script:TIER_DEFAULT } else { return $script:TIER_LIGHT } }
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
        if (@("agent", "claude", "codex", "antigravity", "grok") -contains $stored) {
            return $stored
        }
    }
    return $Target
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


. (Join-Path $PSScriptRoot "lib/file-lock.ps1")
. (Join-Path $PSScriptRoot "lib/crucible-command.ps1")

$crucibleContextPath = Join-Path $PSScriptRoot "lib/crucible-context.ps1"
if (-not (Test-Path -LiteralPath $crucibleContextPath)) {
    [Console]::Error.WriteLine("Required helper script not found at $crucibleContextPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository.")
    exit 1
}
. $crucibleContextPath

$eventLogPath = Join-Path $PSScriptRoot "lib/event-log.ps1"
if (-not (Test-Path -LiteralPath $eventLogPath)) {
    [Console]::Error.WriteLine("Required helper script not found at $eventLogPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository.")
    exit 1
}
. $eventLogPath

$blockedPath = Join-Path $PSScriptRoot "lib/blocked.ps1"
if (-not (Test-Path -LiteralPath $blockedPath)) {
    [Console]::Error.WriteLine("Required helper script not found at $blockedPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository.")
    exit 1
}
. $blockedPath

$handoffPath = Join-Path $PSScriptRoot "lib/handoff.ps1"
if (-not (Test-Path -LiteralPath $handoffPath)) {
    [Console]::Error.WriteLine("Required helper script not found at $handoffPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository.")
    exit 1
}
. $handoffPath

$worktreePath = Join-Path $PSScriptRoot "lib/worktree.ps1"
if (-not (Test-Path -LiteralPath $worktreePath)) {
    [Console]::Error.WriteLine("Required helper script not found at $worktreePath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository.")
    exit 1
}
. $worktreePath

$pipelineDagPath = Join-Path $PSScriptRoot "lib/pipeline-dag.ps1"
if (-not (Test-Path -LiteralPath $pipelineDagPath)) {
    [Console]::Error.WriteLine("Required helper script not found at $pipelineDagPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository.")
    exit 1
}
. $pipelineDagPath

$crucibleGatesPath = Join-Path $PSScriptRoot "lib/crucible-gates.ps1"
if (-not (Test-Path -LiteralPath $crucibleGatesPath)) {
    [Console]::Error.WriteLine("Required helper script not found at $crucibleGatesPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository.")
    exit 1
}
. $crucibleGatesPath

$sessionOutputPath = Join-Path $PSScriptRoot "lib/session-output.ps1"
if (-not (Test-Path -LiteralPath $sessionOutputPath)) {
    [Console]::Error.WriteLine("Required helper script not found at $sessionOutputPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository.")
    exit 1
}
. $sessionOutputPath

. (Join-Path $PSScriptRoot "lib/platform.ps1")

$taskRewindPath = Join-Path $PSScriptRoot "lib/task-rewind.ps1"
if (-not (Test-Path -LiteralPath $taskRewindPath)) {
    [Console]::Error.WriteLine("Required helper script not found at $taskRewindPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository.")
    exit 1
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
