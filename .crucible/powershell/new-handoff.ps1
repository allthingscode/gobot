param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [Parameter(Mandatory = $true)]
    # Keep synchronized with $script:FACTORY_PHASES in factory-lib.ps1.
    [ValidateSet("research", "grooming", "implementation", "verification", "deployment")]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    # Keep synchronized with $script:FACTORY_PHASES in factory-lib.ps1.
    [ValidateSet("research", "grooming", "implementation", "verification", "deployment", "done")]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [string]$Reason,

    [int]$HandoffRetryCount = -1,
    [int]$ReviewStrikeCount = -1,
    [int]$RebaseCount = -1,
    [ValidateSet("low", "medium", "high")]
    [string]$BudgetTier = "",
    [int]$CumulativeHandoffCount = -1,
    [string]$PromptVersion = "",
    [string]$SessionCycleId = "",
    [string]$CycleId = "",
    [string]$SuspiciousContent = "",
    [string]$CommitHash = "",
    [string[]]$Artifacts = @(),
    [string[]]$FileAffinity = @(),
    [string[]]$ReviewerChecksPassed = @(),
    [string[]]$HumanApproved = @(),
    [string[]]$HumanDeferred = @(),
    [string[]]$HumanRejected = @(),
    [string[]]$StubSpecsCreated = @(),
    [string]$SchemaPath = "",
    [string]$OutputPath = "",

    [Parameter(Mandatory = $false)]
    [string]$ProjectRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $repoRootVar = Get-Variable -Name "REPO_ROOT" -ErrorAction SilentlyContinue
    if ($null -ne $repoRootVar) {
        $ProjectRoot = $repoRootVar.Value
    } else {
        $ProjectRoot = (Get-Location).Path
    }
}
$REPO_ROOT = $ProjectRoot
Push-Location $REPO_ROOT
try {
    $factoryLibPath = Join-Path $PSScriptRoot "factory-lib.ps1"
    . $factoryLibPath

# Default schema location: framework's own schemas/ directory (one level up from powershell/).
if ([string]::IsNullOrWhiteSpace($SchemaPath)) {
    $SchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) "schemas/handoff.schema.json"
}

function Get-CycleIdFromTaskFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }
    $raw = Get-Content -LiteralPath $Path -Raw
    if ($raw -match '(?m)^Cycle ID:\s*(.+?)\s*$') {
        return $Matches[1].Trim()
    }
    return ""
}

function Get-PromptVersionFromPromptFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }
    $raw = Get-Content -LiteralPath $Path -Raw
    if ($raw -match '<!--\s*prompt_version:\s*(.+?)\s*-->') {
        return $Matches[1].Trim()
    }
    return ""
}

function Get-LatestActiveHandoffForTask {
    param([string]$HandoffDir, [string]$Task)
    $candidates = @(Get-ChildItem -Path $HandoffDir -Filter ($Task + "-*.json") -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    foreach ($file in $candidates) {
        try {
            $obj = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if (-not ($obj.PSObject.Properties["superseded"] -and $obj.superseded -eq $true)) {
                return $obj
            }
        } catch {
            continue
        }
    }
    return $null
}

$sessionDir = Get-ConfiguredPath -Key "session"
$handoffDir = Join-Path $sessionDir "handoffs"
if (-not (Test-Path -LiteralPath $handoffDir)) {
    New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
}

$latest = Get-LatestActiveHandoffForTask -HandoffDir $handoffDir -Task $TaskId
$sourceTaskPath = Join-Path $sessionDir "$TaskId/$Source/task.md"
$sourcePromptPath = Join-Path $sessionDir "$TaskId/$Source/prompt.md"
$taskCycleId = Get-CycleIdFromTaskFile -Path $sourceTaskPath
$promptVersionFromPrompt = Get-PromptVersionFromPromptFile -Path $sourcePromptPath
$specBudgetTier = Get-SpecBudgetTier -Task $TaskId

$resolvedHandoffRetry = if ($HandoffRetryCount -ge 0) {
    $HandoffRetryCount
} else {
    0
}

$resolvedReviewStrike = if ($ReviewStrikeCount -ge 0) {
    $ReviewStrikeCount
} elseif ($null -ne $latest -and $latest.PSObject.Properties["review_strike_count"]) {
    [int]$latest.review_strike_count
} else {
    0
}

$resolvedRebase = if ($RebaseCount -ge 0) {
    $RebaseCount
} elseif ($null -ne $latest -and $latest.PSObject.Properties["rebase_count"]) {
    [int]$latest.rebase_count
} else {
    0
}

$resolvedBudgetTier = if (-not [string]::IsNullOrWhiteSpace($BudgetTier)) {
    $BudgetTier.ToLowerInvariant()
} elseif (-not [string]::IsNullOrWhiteSpace($specBudgetTier)) {
    $specBudgetTier
} elseif ($null -ne $latest -and $latest.PSObject.Properties["budget_tier"] -and -not [string]::IsNullOrWhiteSpace([string]$latest.budget_tier)) {
    [string]$latest.budget_tier
} else {
    "medium"
}

$resolvedCumulativeCount = if ($CumulativeHandoffCount -ge 1) {
    $CumulativeHandoffCount
} elseif ($null -ne $latest -and $latest.PSObject.Properties["cumulative_handoff_count"]) {
    ([int]$latest.cumulative_handoff_count + 1)
} else {
    1
}

$resolvedPromptVersion = if (-not [string]::IsNullOrWhiteSpace($PromptVersion)) {
    $PromptVersion
} elseif (-not [string]::IsNullOrWhiteSpace($promptVersionFromPrompt)) {
    $promptVersionFromPrompt
} elseif ($null -ne $latest -and $latest.PSObject.Properties["prompt_version"] -and -not [string]::IsNullOrWhiteSpace([string]$latest.prompt_version)) {
    [string]$latest.prompt_version
} else {
    "unknown"
}

$resolvedSessionCycle = if (-not [string]::IsNullOrWhiteSpace($SessionCycleId)) {
    $SessionCycleId
} elseif (-not [string]::IsNullOrWhiteSpace($taskCycleId)) {
    $taskCycleId
} elseif ($null -ne $latest -and $latest.PSObject.Properties["session_cycle_id"] -and -not [string]::IsNullOrWhiteSpace([string]$latest.session_cycle_id)) {
    [string]$latest.session_cycle_id
} elseif ($null -ne $latest -and $latest.PSObject.Properties["cycle_id"] -and -not [string]::IsNullOrWhiteSpace([string]$latest.cycle_id)) {
    [string]$latest.cycle_id
} else {
    ""
}

$resolvedCycle = if (-not [string]::IsNullOrWhiteSpace($CycleId)) {
    $CycleId
} elseif ($null -ne $latest -and $latest.PSObject.Properties["cycle_id"] -and -not [string]::IsNullOrWhiteSpace([string]$latest.cycle_id)) {
    [string]$latest.cycle_id
} elseif (-not [string]::IsNullOrWhiteSpace($resolvedSessionCycle)) {
    $resolvedSessionCycle
} else {
    $null
}

$resolvedCommitHash = if (-not [string]::IsNullOrWhiteSpace($CommitHash)) {
    $CommitHash
} elseif ($null -ne $latest -and $latest.PSObject.Properties["commit_hash"] -and -not [string]::IsNullOrWhiteSpace([string]$latest.commit_hash)) {
    [string]$latest.commit_hash
} else {
    $null
}

[string[]]$resolvedArtifacts = @(if ($null -ne $Artifacts -and $Artifacts.Count -gt 0) {
    @($Artifacts | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
} elseif ($null -ne $latest -and $latest.PSObject.Properties["artifacts"] -and $null -ne $latest.artifacts) {
    @($latest.artifacts)
} else {
    @()
})

$workspacesDir = Get-ConfiguredPath -Key "workspaces" -ProjectRoot $REPO_ROOT
$wtPath = Resolve-ImplementationWorktreePath -TaskId $TaskId -WorkspacesDir $workspacesDir

$resolvedWtPath = if (Test-Path $wtPath) { (Resolve-Path $wtPath).Path } else { $wtPath }
$resolvedRepoRoot = if (Test-Path $REPO_ROOT) { (Resolve-Path $REPO_ROOT).Path } else { $REPO_ROOT }

$normalizedArtifacts = @()
foreach ($art in $resolvedArtifacts) {
    if ([string]::IsNullOrWhiteSpace($art)) { continue }
    $fullArtPath = $art
    if (-not [System.IO.Path]::IsPathRooted($art)) {
        $wtCheck = Join-Path $resolvedWtPath $art
        if (Test-Path $wtCheck) {
            $fullArtPath = (Resolve-Path $wtCheck).Path
        } else {
            $repoCheck = Join-Path $resolvedRepoRoot $art
            if (Test-Path $repoCheck) {
                $fullArtPath = (Resolve-Path $repoCheck).Path
            }
        }
    } else {
        if (Test-Path $art) {
            $fullArtPath = (Resolve-Path $art).Path
        }
    }
    $relPath = $art
    if ([System.IO.Path]::IsPathRooted($fullArtPath)) {
        if ($fullArtPath.StartsWith($resolvedWtPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relPath = $fullArtPath.Substring($resolvedWtPath.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar).TrimStart([System.IO.Path]::AltDirectorySeparatorChar)
        } elseif ($fullArtPath.StartsWith($resolvedRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relPath = $fullArtPath.Substring($resolvedRepoRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar).TrimStart([System.IO.Path]::AltDirectorySeparatorChar)
        }
    } else {
        $wtRelPattern = "(\.crucible/)?\.agent-workspaces/implementation-[^/]+/(.+)"
        if ($relPath.Replace("\", "/") -match $wtRelPattern) {
            $relPath = $Matches[2]
        }
    }
    $relPath = $relPath.Replace("\", "/").Trim()
    while ($relPath.StartsWith("./")) {
        $relPath = $relPath.Substring(2)
    }
    $relPath = $relPath.TrimStart("/")
    if (-not [string]::IsNullOrWhiteSpace($relPath)) {
        $normalizedArtifacts += $relPath
    }
}
$resolvedArtifacts = $normalizedArtifacts

[string[]]$resolvedFileAffinity = @(if ($null -ne $FileAffinity -and $FileAffinity.Count -gt 0) {
    @($FileAffinity | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
} elseif ($null -ne $latest -and $latest.PSObject.Properties["file_affinity"] -and $null -ne $latest.file_affinity) {
    @($latest.file_affinity)
} else {
    @()
})

[string[]]$resolvedStubSpecsCreated = @(if ($null -ne $StubSpecsCreated -and $StubSpecsCreated.Count -gt 0) {
    @($StubSpecsCreated | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
} elseif ($null -ne $latest -and $latest.PSObject.Properties["stub_specs_created"] -and $null -ne $latest.stub_specs_created) {
    @($latest.stub_specs_created)
} else {
    @()
})

$payload = [ordered]@{
    task_id                  = $TaskId
    source_phase             = $Source
    target_phase             = $Target
    reason                   = $Reason
    handoff_retry_count      = $resolvedHandoffRetry
    review_strike_count      = $resolvedReviewStrike
    rebase_count             = $resolvedRebase
    budget_tier              = $resolvedBudgetTier
    cumulative_handoff_count = $resolvedCumulativeCount
    prompt_version           = $resolvedPromptVersion
    session_cycle_id         = $resolvedSessionCycle
    cycle_id                 = $resolvedCycle
    suspicious_content       = if ([string]::IsNullOrWhiteSpace($SuspiciousContent)) { $null } else { $SuspiciousContent }
    commit_hash              = $resolvedCommitHash
    artifacts                = $resolvedArtifacts
}

if ($Source -eq "grooming" -or @($resolvedFileAffinity).Count -gt 0) {
    $payload.file_affinity = $resolvedFileAffinity
}
if (@($resolvedStubSpecsCreated).Count -gt 0) {
    $payload.stub_specs_created = $resolvedStubSpecsCreated
}
if (@($ReviewerChecksPassed).Count -gt 0) {
    $payload.reviewer_checks_passed = @($ReviewerChecksPassed)
}
if (@($HumanApproved).Count -gt 0 -or @($HumanDeferred).Count -gt 0 -or @($HumanRejected).Count -gt 0) {
    $payload.human_decisions = [ordered]@{
        approved = @($HumanApproved)
        deferred = @($HumanDeferred)
        rejected = @($HumanRejected)
    }
}

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$resolvedOutputPath = if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath
} else {
    Join-Path $handoffDir ($TaskId + "-" + $timestamp + ".json")
}
$tempOutputPath = $resolvedOutputPath + ".tmp"

try {
    $json = $payload | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $tempOutputPath -Value $json -Encoding UTF8

    $validatorPath = Join-Path $PSScriptRoot "validate-handoff.ps1"
    if (-not (Test-Path -LiteralPath $validatorPath)) {
        throw "Validator not found: $validatorPath"
    }

    $validationRaw = & $validatorPath -HandoffFile $tempOutputPath -SchemaPath $SchemaPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        $validationText = ($validationRaw -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($validationText)) {
            $validationText = "unknown validation error"
        }
        throw "Schema validation failed: $validationText"
    }

    Move-Item -LiteralPath $tempOutputPath -Destination $resolvedOutputPath -Force

    [ordered]@{
        ok           = $true
        handoff_file = $resolvedOutputPath
        task_id      = $TaskId
        source       = $Source
        target       = $Target
    } | ConvertTo-Json
} catch {
    if (Test-Path -LiteralPath $tempOutputPath) {
        Remove-Item -LiteralPath $tempOutputPath -Force -ErrorAction SilentlyContinue
    }
    throw
}
} finally {
    Pop-Location
}
