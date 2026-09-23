# Crucible Orchestrator Script
# Validates handoff.json, routes pipeline in code, assembles next prompt from template.
# Usage: .\.crucible\\crucible.ps1 [-Target agent|claude|codex|antigravity] [-Init|-Health|-Cleanup|-Doctor] [-AutoAdvance] [-TaskId <id>] [-ProjectRoot <path>]
#
# Dual-use note: -Init serves two purposes depending on call site:
#   Session START: validates incoming handoff, scaffolds worktree + task.md, logs session_start event.
#   Session END:   called after writing handoff.json to route the pipeline to the next specialist.
# Both uses pass -TaskId. The script detects which is appropriate from the handoff state.
#
# -AutoAdvance: non-gate transitions emit [AUTO-ADVANCE] marker; orchestrators execute the next
#   specialist immediately. Gate transitions (operator, researcher) always pause for human input.

param (
    [Parameter(Mandatory=$false)]
    [ValidateSet("agent", "claude", "codex", "antigravity")]
    [string]$Target = "agent",

    [Parameter(Mandatory=$false)]
    [switch]$Init,

    [Parameter(Mandatory=$false)]
    [switch]$Health,

    [Parameter(Mandatory=$false)]
    [switch]$Doctor,

    [Parameter(Mandatory=$false)]
    [switch]$Cleanup,

    [Parameter(Mandatory=$false)]
    [switch]$Force,

    [Parameter(Mandatory=$false)]
    [string]$TaskId = "",

    [Parameter(Mandatory=$false)]
    [switch]$Status,

    [Parameter(Mandatory=$false)]
    [switch]$NewHandoff,

    [Parameter(Mandatory=$false)]
    # Keep synchronized with $script:CRUCIBLE_PHASES in crucible-lib.ps1.
    [ValidateSet("research", "grooming", "implementation", "verification", "deployment")]
    [string]$HandoffSource = "",

    [Parameter(Mandatory=$false)]
    # Keep synchronized with $script:CRUCIBLE_PHASES in crucible-lib.ps1.
    [ValidateSet("research", "grooming", "implementation", "verification", "deployment", "done")]
    [string]$HandoffTarget = "",

    [Parameter(Mandatory=$false)]
    [string]$HandoffReason = "",

    [Parameter(Mandatory=$false)]
    [string[]]$HandoffArtifacts = @(),

    [Parameter(Mandatory=$false)]
    [string[]]$HandoffFileAffinity = @(),

    [Parameter(Mandatory=$false)]
    [string[]]$HandoffReviewerChecksPassed = @(),

    [Parameter(Mandatory=$false)]
    [string[]]$HandoffStubSpecsCreated = @(),

    [Parameter(Mandatory=$false)]
    [string[]]$HumanApproved = @(),
    [Parameter(Mandatory=$false)]
    [string[]]$HumanDeferred = @(),
    [Parameter(Mandatory=$false)]
    [string[]]$HumanRejected = @(),
    [Parameter(Mandatory=$false)]
    [ValidateSet("accepted", "rejected", "redirected", "abandoned", "1", "2", "3", "4")]
    [string]$GateOutcome = "",

    [Parameter(Mandatory=$false)]
    [string]$GateRedirectTarget = "",

    [Parameter(Mandatory=$false)]
    [string]$GateReason = "",

    [Parameter(Mandatory=$false)]
    [switch]$Recover,

    [Parameter(Mandatory=$false)]
    [switch]$Quiet,

    # When set, non-gate transitions output [AUTO-ADVANCE] instead of [NEXT SESSION COMMAND].
    # Orchestrators check this marker to chain the next specialist without waiting for human confirmation.
    # Gate transitions (operator -> *, researcher -> *) always pause regardless of this flag.
    [Parameter(Mandatory=$false)]
    [switch]$AutoAdvance,

    [Parameter(Mandatory=$false)]
    [switch]$Rewind,

    [Parameter(Mandatory=$false)]
    [ValidateSet("grooming")]
    [string]$ToPhase = "",

    [Parameter(Mandatory=$false)]
    [switch]$ResetBudget,

    # Absolute path to the project root (the directory containing .crucible/).
    # Defaults to the root derived from this script's location (never the caller's cwd).
    # Specify explicitly only to target a project other than the one this script ships in.
    [Parameter(Mandatory=$false)]
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"
foreach ($lib in "config-helpers.ps1", "instruction-blocks.ps1", "language-presets.ps1", "project-root.ps1") {
    $libPath = Join-Path $PSScriptRoot "lib/$lib"
    if (-not (Test-Path -LiteralPath $libPath)) {
        throw "Required helper script not found at $libPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
    }
}
. (Join-Path $PSScriptRoot "lib/config-helpers.ps1")
. (Join-Path $PSScriptRoot "lib/project-root.ps1")
$crucibleLibPath = Join-Path $PSScriptRoot "crucible-lib.ps1"
. $crucibleLibPath

function Get-CrucibleRoot {
    param([string]$ProjectRoot = "")
    $root = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $REPO_ROOT } else { $ProjectRoot }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }
    $configPath = Join-Path $root ".crucible/config.yaml"
    if (Test-Path -LiteralPath $configPath) {
        try {
            $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
            if ($content -match '(?m)^crucible_root:\s*["'']([^"''\r\n]+)["'']\s*$') {
                return $Matches[1].Trim()
            }
        } catch {}
    }
    return ".crucible"
}
# Framework powershell/ directory - used to resolve sibling scripts regardless of CWD.
$FRAMEWORK_POWERSHELL = $PSScriptRoot
# Anchor paths to the project root (where .crucible/ lives). -ProjectRoot overrides for
# explicit invocation from elsewhere; otherwise the root derived from THIS script's location
# is preferred over the caller's cwd. crucible.ps1 ships to adopters at
# <root>/.crucible/powershell/ and lives in the framework repo at <root>/powershell/, so
# $PSScriptRoot names the target repo unambiguously no matter where the orchestrator invoked
# us from. Defaulting to cwd silently targeted the wrong repo when the gate ran from a
# different checkout.
#
# This entrypoint kept its own copy of that resolution after item 60 moved the other three
# callers onto the shared helper, because the copy ended in an unvalidated fall back to the
# working directory and the helper refuses instead. The reason recorded for keeping it was
# that the framework's own fixtures invoke this script from a directory that is not an
# adopter - but every one of them passes -ProjectRoot today, so the fallback was serving
# nobody and guessing for everybody. It is the most expensive place in the codebase to
# guess: -Init against a guessed root boots a phase for a repository nobody named, and the
# framework checkout is not itself an adopter, so the guess landed there.
try {
    $REPO_ROOT = Resolve-CrucibleProjectRoot -ProjectRoot $ProjectRoot -ScriptRoot $PSScriptRoot
} catch {
    # Reported the way this entrypoint reports its other startup failures rather than as an
    # unhandled exception. $ErrorActionPreference = "Stop" would exit non-zero either way,
    # but the operator would be reading a stack trace instead of the one sentence that says
    # which parameter to pass.
    Write-Host ("Error: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
$crucibleRoot = Get-CrucibleRoot -ProjectRoot $ProjectRoot
Push-Location $REPO_ROOT

# Display a one-line Crucible version banner from the project's installed config,
# if version metadata is present. Silent on $Quiet or when config is missing/unstamped.
if (-not $Quiet) {
    $bannerCfg = Join-Path $REPO_ROOT ".crucible/config.yaml"
    if (Test-Path -LiteralPath $bannerCfg) {
        try {
            $bannerContent = Get-Content -LiteralPath $bannerCfg -Raw -Encoding UTF8
            $bannerVersion = $null
            $bannerCommit = $null
            if ($bannerContent -match '(?m)^crucible_version:\s+["'']([^"''\r\n]+)["'']\s*$') {
                $bannerVersion = $Matches[1].Trim()
            }
            if ($bannerContent -match '(?m)^crucible_install_commit:\s+["'']([^"''\r\n]+)["'']\s*$') {
                $bannerCommit = $Matches[1].Trim()
            }
            if ($bannerVersion -and $bannerVersion -match '^[0-9]+\.[0-9]+\.[0-9]+') {
                if ($bannerCommit -and $bannerCommit -match '^[0-9a-f]{40}$') {
                    Write-Host ("Crucible v" + $bannerVersion + " (commit " + $bannerCommit.Substring(0, 7) + ")") -ForegroundColor DarkGray
                    $frameworkSource = ""
                    if (-not [string]::IsNullOrWhiteSpace($env:CRUCIBLE_DEV_ROOT) -and (Test-Path -LiteralPath (Join-Path $env:CRUCIBLE_DEV_ROOT ".git"))) {
                        $frameworkSource = $env:CRUCIBLE_DEV_ROOT
                    } elseif (-not [string]::IsNullOrWhiteSpace($env:CRUCIBLE_FRAMEWORK_DIR) -and (Test-Path -LiteralPath (Join-Path $env:CRUCIBLE_FRAMEWORK_DIR ".git"))) {
                        $frameworkSource = $env:CRUCIBLE_FRAMEWORK_DIR
                    } else {
                        $siblingCandidate = Join-Path (Split-Path -Parent $REPO_ROOT) "crucible"
                        if (Test-Path -LiteralPath (Join-Path $siblingCandidate ".git")) {
                            $frameworkSource = $siblingCandidate
                        }
                    }
                    if ($frameworkSource) {
                        $gitMainResult = git -C $frameworkSource rev-parse --verify --quiet main
                        $frameworkHead = if ($LASTEXITCODE -eq 0 -and $gitMainResult) { ($gitMainResult | Out-String).Trim() } else { "" }
                        if (-not ($frameworkHead -match '^[0-9a-f]{40}$')) {
                            $gitHeadResult = git -C $frameworkSource rev-parse HEAD 2>$null
                            $frameworkHead = if ($LASTEXITCODE -eq 0 -and $gitHeadResult) { ($gitHeadResult | Out-String).Trim() } else { "" }
                        }
                        if ($frameworkHead -match '^[0-9a-f]{40}$' -and $bannerCommit -ne $frameworkHead) {
                            $null = git -C $frameworkSource merge-base --is-ancestor $bannerCommit $frameworkHead 2>$null
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host ("WARNING: Installed Crucible bundle lags framework HEAD. Installed: " + $bannerCommit.Substring(0, 7) + " | Upstream HEAD: " + $frameworkHead.Substring(0, 7)) -ForegroundColor Yellow
                                Write-Host ("  Run 'update-bundle.ps1 -FrameworkSource " + $frameworkSource + "' to bring it current.") -ForegroundColor Yellow
                            }
                        }
                    }
                } else {
                    Write-Host ("Crucible v" + $bannerVersion) -ForegroundColor DarkGray
                }
            } else {
                Write-Host "Crucible (unversioned install)" -ForegroundColor DarkGray
            }
        } catch {
            # Banner is informational; never block on a malformed config.
        }
    }
}

# Optional utility mode: readiness diagnostics.
if ($Doctor) {
    $doctorScript = "$FRAMEWORK_POWERSHELL/crucible-doctor.ps1"
    if (-not (Test-Path -LiteralPath $doctorScript)) {
        Write-Host ("Error: Doctor script not found at " + $doctorScript) -ForegroundColor Red
        exit 1
    }
    & $doctorScript
    exit $LASTEXITCODE
}

# Optional utility mode: deterministic handoff generation via dedicated script.
if ($NewHandoff) {
    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        Write-Host "Error: -TaskId is required when using -NewHandoff." -ForegroundColor Red
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($HandoffSource) -or
        [string]::IsNullOrWhiteSpace($HandoffTarget) -or
        [string]::IsNullOrWhiteSpace($HandoffReason)) {
        Write-Host "Error: -HandoffSource, -HandoffTarget, and -HandoffReason are required with -NewHandoff." -ForegroundColor Red
        exit 1
    }

    $generatorScript = "$FRAMEWORK_POWERSHELL/new-handoff.ps1"
    if (-not (Test-Path -LiteralPath $generatorScript)) {
        Write-Host ("Error: Handoff generator script not found at " + $generatorScript) -ForegroundColor Red
        exit 1
    }

    $genParams = @{
        TaskId = $TaskId
        Source = $HandoffSource
        Target = $HandoffTarget
        Reason = $HandoffReason
    }
    if ($HandoffArtifacts.Count -gt 0) {
        $genParams.Artifacts = $HandoffArtifacts
    }
    if ($HandoffFileAffinity.Count -gt 0) {
        $genParams.FileAffinity = $HandoffFileAffinity
    }
    if ($HandoffReviewerChecksPassed.Count -gt 0) {
        $genParams.ReviewerChecksPassed = $HandoffReviewerChecksPassed
    }
    if ($HandoffStubSpecsCreated.Count -gt 0) {
        $genParams.StubSpecsCreated = $HandoffStubSpecsCreated
    }

    if ($HumanApproved.Count -gt 0) { $genParams.HumanApproved = [string[]]$HumanApproved }
    if ($HumanDeferred.Count -gt 0) { $genParams.HumanDeferred = [string[]]$HumanDeferred }
    if ($HumanRejected.Count -gt 0) { $genParams.HumanRejected = [string[]]$HumanRejected }

    & $generatorScript @genParams
    exit $LASTEXITCODE
}

$sessionDir = Get-ConfiguredPath -Key "session"
$backlogDir = Get-ConfiguredPath -Key "backlog"
$workspacesDir = Get-ConfiguredPath -Key "workspaces"
$HANDOFF_DIR = Join-Path $sessionDir "handoffs"
$PROMPT_LIB = Get-ConfiguredPath -Key "prompts"
$budgetCeilings = Get-BudgetCeilings
$ceiling = 0
$promptText = ""

# When $TaskId is provided, log to per-task file; otherwise global.
if (-not [string]::IsNullOrEmpty($TaskId)) {
    $LOG_FILE = Join-Path $sessionDir ($TaskId + "/pipeline.log.jsonl")
    # Ensure the directory exists
    $logDir = Split-Path $LOG_FILE
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
} else {
    $LOG_FILE = Join-Path $sessionDir "global/pipeline.log.jsonl"
    # Ensure the directory exists
    $logDir = Split-Path $LOG_FILE
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
}
$GLOBAL_DIR = Join-Path $sessionDir "global"
if (-not (Test-Path $GLOBAL_DIR)) { New-Item -ItemType Directory -Force -Path $GLOBAL_DIR | Out-Null }
$CB_HISTORY_FILE = Join-Path $GLOBAL_DIR "circuit_breakers.jsonl"

# Sticky per-task specialist target: the human picks -Target once (e.g. codex) and the
# whole pipeline should keep recommending it. Without this, every phase's -Init defaults
# -Target back to "agent", so the printed [NEXT SESSION COMMAND]/[RECOMMENDED MODEL]
# mislabels a Codex-run pipeline. Persist an explicit -Target and reload it when omitted.
$Target = Resolve-StickyTarget -TaskId $TaskId -SessionDir $sessionDir -Target $Target `
    -Explicit ($PSBoundParameters.ContainsKey('Target'))

$crucibleContext = @{
    RepoRoot = $REPO_ROOT
    CrucibleRoot = $crucibleRoot
    FrameworkPowerShell = $FRAMEWORK_POWERSHELL
    SessionDir = $sessionDir
    BacklogDir = $backlogDir
    WorkspacesDir = $workspacesDir
    HandoffDir = $HANDOFF_DIR
    PromptLib = $PROMPT_LIB
    LogFile = $LOG_FILE
    CircuitBreakerHistoryFile = $CB_HISTORY_FILE
    TaskId = $TaskId
    Target = $Target
    Init = [bool]$Init
    Recover = [bool]$Recover
    Quiet = [bool]$Quiet
    AutoAdvance = [bool]$AutoAdvance
    GateOutcome = $GateOutcome
    GateRedirectTarget = $GateRedirectTarget
    GateReason = $GateReason
    BudgetCeilings = $null
    Ceiling = $null
    Handoff = $null
    LatestHandoff = $null
    RelativeHandoffPath = $null
    CumulativeHandoffCount = 0
    IsBootstrap = $false
    Transition = $null
    NextCrucibleCommand = $null
}

function Get-PrimaryBranchName {
    git show-ref --verify --quiet refs/heads/main
    if ($LASTEXITCODE -eq 0) { return "main" }
    return "master"
}

if ($Health -or $Cleanup) {
    $healthScript = "$FRAMEWORK_POWERSHELL/crucible-health.ps1"
    if (-not (Test-Path -LiteralPath $healthScript)) {
        Write-Host ("Error: Health script not found at " + $healthScript) -ForegroundColor Red
        exit 1
    }
    & $healthScript -Health:$Health -Cleanup:$Cleanup -Force:$Force -Quiet:$Quiet -TaskId $TaskId
    exit $LASTEXITCODE
}

if ($Status) {
    $statusScript = "$FRAMEWORK_POWERSHELL/crucible-status.ps1"
    if (-not (Test-Path -LiteralPath $statusScript)) {
        Write-Host ("Error: Status script not found at " + $statusScript) -ForegroundColor Red
        exit 1
    }
    & $statusScript
    exit $LASTEXITCODE
}

if ($Rewind) {
    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        Write-Host "Error: -TaskId is required when using -Rewind." -ForegroundColor Red
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($ToPhase)) {
        Write-Host "Error: -ToPhase is required when using -Rewind." -ForegroundColor Red
        exit 1
    }
    if ($ToPhase -ne "grooming") {
        Write-Host "Error: Only '-ToPhase grooming' is supported in this version." -ForegroundColor Red
        exit 1
    }

    Invoke-TaskRewind -TaskId $TaskId -ToPhase $ToPhase -ResetBudget:$ResetBudget -SessionDir $sessionDir -HandoffDir $HANDOFF_DIR -LogFile $LOG_FILE -CircuitBreakerHistoryFile $CB_HISTORY_FILE -Quiet:$Quiet -WorkspacesDir $workspacesDir -ProjectRoot $REPO_ROOT
    exit 0
}

# --- 0a. Require -TaskId for all pipeline operations ---
if ([string]::IsNullOrEmpty($TaskId)) {
    Write-Host "`n[ERROR] -TaskId is required." -ForegroundColor Red
    Write-Host "Usage: .\.crucible\\crucible.ps1 -Init -TaskId {task_id} -ProjectRoot `"{project_root}`"" -ForegroundColor Yellow
    Write-Host "       .\.crucible\\crucible.ps1 -Health  (no -TaskId needed for health checks)" -ForegroundColor DarkGray
    Write-Host "       .\.crucible\\crucible.ps1 -Doctor  (no -TaskId needed for readiness checks)" -ForegroundColor DarkGray
    exit 1
}

function Check-Dependencies {
    param([string]$BacklogItemPath, [string]$TargetSpecialist, [string]$TaskId)

    if (-not (Test-Path $BacklogItemPath)) { return }

    $frontmatter = Get-Content -LiteralPath $BacklogItemPath -Head 20 -Encoding UTF8
    $dependsOn = @()
    $parsing = $false
    foreach ($line in $frontmatter) {
        if ($line -match 'depends_on:\s*\[([^\]]*)\]') {
            $rawDeps = $matches[1].Split(',') | ForEach-Object { $_.Trim().Replace('"', '').Replace("'", "") }
            $dependsOn = @($rawDeps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            break
        }
        if ($line -match 'depends_on:') {
            $parsing = $true
            continue
        }
        if ($parsing) {
            if ($line -match '^\s*-\s*([A-Z][A-Z0-9\-]+)') {
                $dependsOn += $matches[1]
            } elseif ($line -match '^[a-z_]+:') {
                $parsing = $false
            }
        }
    }

    if ($dependsOn.Count -eq 0) { return }

    Write-Quiet "`n[DEPENDENCY] Checking dependencies for $TaskId..." -ForegroundColor Cyan
    # Gate on the backlog directory rather than on the two index files: a backlog whose
    # status lives only in spec frontmatter is still a backlog worth checking.
    if (-not (Test-Path $backlogDir)) { return }

    $unsatisfied = @()
    foreach ($dep in $dependsOn) {
        # Resolved through the shared lookup: spec frontmatter first, then the indexes.
        # Measured on the dogfood adopter 2026-09-05: R-029 was archived with status
        # "Resolved" on disk but had no BACKLOG.md row, and the old table-only lookup
        # called that dependency unsatisfied - which blocks the Operator phase - while
        # validate-backlog.ps1 passed on the same run.
        $depInfo = Get-BacklogTaskStatus -Task $dep -ProjectRoot $ProjectRoot -BacklogDir $backlogDir

        if (-not $depInfo.Found) {
            # Name only what was actually searched. The old text named ARCHIVED.md
            # unconditionally, so an adopter with no such file was told to look in it.
            $unsatisfied += ("$dep (not found - searched " + ($depInfo.Searched -join ", ") + ")")
            continue
        }

        if (-not (Test-BacklogTaskTerminal $depInfo.Status)) {
            $statusLabel = if ([string]::IsNullOrWhiteSpace($depInfo.Status)) { "(empty)" } else { $depInfo.Status }
            $unsatisfied += ("$dep (Status: $statusLabel in " + $depInfo.Source + ")")
        }
    }

    if ($unsatisfied.Count -gt 0) {
        if ($TargetSpecialist -eq "deployment" -or $TargetSpecialist -eq "operator") {
            Write-Host "[DEPENDENCY] BLOCKING: Unsatisfied dependencies detected:" -ForegroundColor Red
            $unsatisfied | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
            Write-Host "`n[STOP] Prerequisite tasks must be in 'Production' or 'Resolved' before deployment." -ForegroundColor Red
            exit 2
        } else {
            Write-Quiet "[DEPENDENCY] WARNING: Unsatisfied dependencies detected:" -ForegroundColor Yellow
            $unsatisfied | ForEach-Object { Write-Quiet "  - $_" -ForegroundColor Yellow }
            Write-Quiet "  (Proceeding - only the Operator phase is blocked by dependencies)`n" -ForegroundColor Gray
        }
    } else {
        Write-Quiet "[DEPENDENCY] All prerequisites satisfied." -ForegroundColor Green
    }
}

Resolve-CrucibleInputHandoff -Context $crucibleContext
$latestHandoff = $crucibleContext.LatestHandoff
$isBootstrap = $crucibleContext.IsBootstrap

Read-CrucibleHandoffContext -Context $crucibleContext
$handoff = $crucibleContext.Handoff
$relativeHandoffPath = $crucibleContext.RelativeHandoffPath
$budgetCeilings = $crucibleContext.BudgetCeilings
$ceiling = $crucibleContext.Ceiling
$cumulativeHandoffCount = $crucibleContext.CumulativeHandoffCount
$isBootstrap = $crucibleContext.IsBootstrap
$handoffFile = $latestHandoff.FullName
$handoffRaw = Get-Content $handoffFile -Raw -Encoding UTF8

Invoke-HandoffPreflightValidation -Context $crucibleContext
$latestHandoff = $crucibleContext.LatestHandoff
$handoff = $crucibleContext.Handoff
$relativeHandoffPath = $crucibleContext.RelativeHandoffPath
$nextCrucibleCmd = $crucibleContext.NextCrucibleCommand
$handoffFile = $latestHandoff.FullName
$handoffRaw = Get-Content $handoffFile -Raw -Encoding UTF8

Complete-CrucibleSourceSession -Context $crucibleContext
# --- 2. Runtime Validation (complements schema preflight) ---
Invoke-CrucibleRuntimeValidation -Context $crucibleContext

Invoke-CrucibleScopeGates -Context $crucibleContext

Test-CompletionArtifactGate -Context $crucibleContext

Normalize-CrucibleInputState -Context $crucibleContext
$handoff = $crucibleContext.Handoff

Invoke-CircuitBreakerGates -Context $crucibleContext

Invoke-HumanGate -Context $crucibleContext

Invoke-RepositoryIntegrityGates -Context $crucibleContext

$transitionDecision = Resolve-CrucibleTransition -Context $crucibleContext
if ($transitionDecision.ShouldExit) {
    if (-not [string]::IsNullOrEmpty($transitionDecision.Reason)) {
        Write-Quiet $transitionDecision.Reason -ForegroundColor Cyan
    }
    exit $transitionDecision.ExitCode
}
$crucibleContext.Transition = $transitionDecision.Transition
$crucibleContext.NextCrucibleCommand = $transitionDecision.NextCrucibleCommand
$crucibleContext.IsBootstrap = $transitionDecision.IsBootstrap

$nextCrucibleCmd = $crucibleContext.NextCrucibleCommand
$isBootstrap = $crucibleContext.IsBootstrap
New-CruciblePromptText -Context $crucibleContext
Write-CruciblePromptOutput -Context $crucibleContext
Initialize-CrucibleTargetSession -Context $crucibleContext
Write-CrucibleCiStatusBanner -Context $crucibleContext
Start-CrucibleTargetSessionLog -Context $crucibleContext
exit 0
