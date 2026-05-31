# Factory Orchestrator Script
# Validates handoff.json, routes pipeline in code, assembles next prompt from template.
# Usage: .\.crucible\\factory.ps1 [-Target agent|gemini|claude] [-Init|-Health|-Cleanup|-Doctor] [-AutoAdvance] [-TaskId <id>]
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
    [ValidateSet("agent", "gemini", "claude", "antigravity")]
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
    [switch]$NewHandoff,

    [Parameter(Mandatory=$false)]
    # Keep synchronized with $script:FACTORY_PHASES in factory-lib.ps1.
    [ValidateSet("research", "grooming", "implementation", "verification", "deployment")]
    [string]$HandoffSource = "",

    [Parameter(Mandatory=$false)]
    # Keep synchronized with $script:FACTORY_PHASES in factory-lib.ps1.
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

    # Absolute path to the project root (the directory containing .crucible/).
    # Defaults to the current working directory. Specify explicitly when invoking
    # the framework script from outside the project directory.
    [Parameter(Mandatory=$false)]
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"
foreach ($lib in "config-helpers.ps1", "instruction-blocks.ps1", "language-presets.ps1") {
    $libPath = Join-Path $PSScriptRoot "lib/$lib"
    if (-not (Test-Path -LiteralPath $libPath)) {
        throw "Required helper script not found at $libPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
    }
}
. (Join-Path $PSScriptRoot "lib/config-helpers.ps1")
$factoryLibPath = Join-Path $PSScriptRoot "factory-lib.ps1"
. $factoryLibPath

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
# Framework powershell/ directory — used to resolve sibling scripts regardless of CWD.
$FRAMEWORK_POWERSHELL = $PSScriptRoot
# Anchor paths to the project root (where .crucible/ lives).
# Default is CWD; -ProjectRoot overrides for explicit invocation from elsewhere.
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $REPO_ROOT = (Get-Location).Path
} else {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) {
        Write-Host ("Error: -ProjectRoot path does not exist: " + $ProjectRoot) -ForegroundColor Red
        exit 1
    }
    $REPO_ROOT = (Resolve-Path -LiteralPath $ProjectRoot).Path
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
    $doctorScript = "$FRAMEWORK_POWERSHELL/factory-doctor.ps1"
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

$factoryContext = @{
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
    NextFactoryCommand = $null
}

function Get-PrimaryBranchName {
    git show-ref --verify --quiet refs/heads/main
    if ($LASTEXITCODE -eq 0) { return "main" }
    return "master"
}

if ($Health -or $Cleanup) {
    $healthScript = "$FRAMEWORK_POWERSHELL/factory-health.ps1"
    if (-not (Test-Path -LiteralPath $healthScript)) {
        Write-Host ("Error: Health script not found at " + $healthScript) -ForegroundColor Red
        exit 1
    }
    & $healthScript -Health:$Health -Cleanup:$Cleanup -Force:$Force -Quiet:$Quiet -TaskId $TaskId
    exit $LASTEXITCODE
}

# --- 0a. Require -TaskId for all pipeline operations ---
if ([string]::IsNullOrEmpty($TaskId)) {
    Write-Host "`n[ERROR] -TaskId is required." -ForegroundColor Red
    Write-Host "Usage: .\.crucible\\factory.ps1 -Init -TaskId {task_id}" -ForegroundColor Yellow
    Write-Host "       .\.crucible\\factory.ps1 -Health  (no -TaskId needed for health checks)" -ForegroundColor DarkGray
    Write-Host "       .\.crucible\\factory.ps1 -Doctor  (no -TaskId needed for readiness checks)" -ForegroundColor DarkGray
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
    $dependencySources = @(
        @{ Path = Join-Path $backlogDir "BACKLOG.md"; Name = "BACKLOG.md" },
        @{ Path = Join-Path $backlogDir "ARCHIVED.md"; Name = "ARCHIVED.md" }
    )
    if (-not ($dependencySources | Where-Object { Test-Path $_.Path })) { return }

    $unsatisfied = @()
    foreach ($dep in $dependsOn) {
        $found = $false
        $depStatus = $null
        $depSource = $null
        foreach ($source in $dependencySources) {
            if (-not (Test-Path $source.Path)) { continue }

            $lines = Get-Content -Path $source.Path -Encoding UTF8
            $statusColumnIndex = -1
            $escapedDep = [regex]::Escape($dep)

            foreach ($line in $lines) {
                if ($line -match '^\|\s*ID\s*\|') {
                    $headerCols = ($line -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne "" }
                    $statusColumnIndex = [Array]::IndexOf($headerCols, "Status")
                    continue
                }
                if ($line -match '^\|\s*[-: ]+\|') { continue }

                if ($line -match "^\|\s*(:\[$escapedDep\]\([^)]+\)|$escapedDep)\s*\|") {
                    $rowCols = ($line -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne "" }
                    if ($statusColumnIndex -ge 0 -and $statusColumnIndex -lt $rowCols.Count) {
                        $depStatus = $rowCols[$statusColumnIndex]
                    } elseif ($rowCols.Count -gt 0) {
                        $depStatus = $rowCols[$rowCols.Count - 1]
                    } else {
                        $depStatus = ""
                    }
                    $depSource = $source.Name
                    $found = $true
                    break
                }
            }

            if ($found) {
                break
            }
        }

        if (-not $found) {
            $unsatisfied += "$dep (Not found in BACKLOG.md or ARCHIVED.md)"
            continue
        }

        $statusNormalized = ($depStatus | ForEach-Object { $_.Trim() }).ToLowerInvariant()
        if ($statusNormalized -ne "production" -and $statusNormalized -ne "resolved") {
            $statusLabel = if ([string]::IsNullOrWhiteSpace($depStatus)) { "(empty)" } else { $depStatus }
            $unsatisfied += "$dep (Status: $statusLabel in $depSource)"
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

Resolve-FactoryInputHandoff -Context $factoryContext
$latestHandoff = $factoryContext.LatestHandoff
$isBootstrap = $factoryContext.IsBootstrap

Read-FactoryHandoffContext -Context $factoryContext
$handoff = $factoryContext.Handoff
$relativeHandoffPath = $factoryContext.RelativeHandoffPath
$budgetCeilings = $factoryContext.BudgetCeilings
$ceiling = $factoryContext.Ceiling
$cumulativeHandoffCount = $factoryContext.CumulativeHandoffCount
$isBootstrap = $factoryContext.IsBootstrap
$handoffFile = $latestHandoff.FullName
$handoffRaw = Get-Content $handoffFile -Raw -Encoding UTF8

Invoke-HandoffPreflightValidation -Context $factoryContext
$latestHandoff = $factoryContext.LatestHandoff
$handoff = $factoryContext.Handoff
$relativeHandoffPath = $factoryContext.RelativeHandoffPath
$nextFactoryCmd = $factoryContext.NextFactoryCommand
$handoffFile = $latestHandoff.FullName
$handoffRaw = Get-Content $handoffFile -Raw -Encoding UTF8

Complete-FactorySourceSession -Context $factoryContext
# --- 2. Runtime Validation (complements schema preflight) ---
Invoke-FactoryRuntimeValidation -Context $factoryContext

Invoke-FactoryScopeGates -Context $factoryContext

Test-CompletionArtifactGate -Context $factoryContext

Normalize-FactoryInputState -Context $factoryContext
$handoff = $factoryContext.Handoff

Invoke-CircuitBreakerGates -Context $factoryContext

Invoke-HumanGate -Context $factoryContext

Invoke-RepositoryIntegrityGates -Context $factoryContext

$transitionDecision = Resolve-FactoryTransition -Context $factoryContext
if ($transitionDecision.ShouldExit) {
    if (-not [string]::IsNullOrEmpty($transitionDecision.Reason)) {
        Write-Quiet $transitionDecision.Reason -ForegroundColor Cyan
    }
    exit $transitionDecision.ExitCode
}
$factoryContext.Transition = $transitionDecision.Transition
$factoryContext.NextFactoryCommand = $transitionDecision.NextFactoryCommand
$factoryContext.IsBootstrap = $transitionDecision.IsBootstrap

$nextFactoryCmd = $factoryContext.NextFactoryCommand
$isBootstrap = $factoryContext.IsBootstrap
New-FactoryPromptText -Context $factoryContext
Write-FactoryPromptOutput -Context $factoryContext
Initialize-FactoryTargetSession -Context $factoryContext
Write-FactoryCiStatusBanner -Context $factoryContext
Start-FactoryTargetSessionLog -Context $factoryContext
