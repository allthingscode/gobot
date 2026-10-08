[CmdletBinding(DefaultParameterSetName = "Transition")]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [Parameter(Mandatory = $true, ParameterSetName = "Transition")]
    # Keep synchronized with $script:CRUCIBLE_PHASES in crucible-lib.ps1.
    [ValidateSet("research", "grooming", "implementation", "verification", "deployment")]
    [string]$Source,

    [Parameter(Mandatory = $true, ParameterSetName = "Transition")]
    # Keep synchronized with $script:CRUCIBLE_PHASES in crucible-lib.ps1.
    [ValidateSet("research", "grooming", "implementation", "verification", "deployment", "done")]
    [string]$Target,

    [Parameter(Mandatory = $true, ParameterSetName = "Transition")]
    [string]$Reason,

    # Carries the latest active handoff forward with only base_commit moved to -BaseCommit,
    # for a bundle update committed while the task is in flight (TODO item 139).
    [Parameter(Mandatory = $true, ParameterSetName = "Rebaseline")]
    [switch]$Rebaseline,

    [int]$HandoffRetryCount = -1,
    [int]$ReviewStrikeCount = -1,
    [int]$RebaseCount = -1,
    # Keep synchronized with $script:BUDGET_TIERS in crucible-lib.ps1.
    [ValidateSet("low", "medium", "high", "extended")]
    [string]$BudgetTier = "",
    # Set by the Groomer on a grooming->implementation handoff when the Architect must
    # produce the design (escalates the Architect to the strong model). Omit when the
    # spec already contains a complete design (execution-only, default model).
    [switch]$DesignRequired,
    [int]$CumulativeHandoffCount = -1,
    [string]$PromptVersion = "",
    [string]$SessionCycleId = "",
    [string]$CycleId = "",
    [string]$SuspiciousContent = "",
    [string]$CommitHash = "",
    [string]$BaseCommit = "",
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
. (Join-Path $PSScriptRoot "lib/project-root.ps1")

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    # A dot-sourcing caller that already resolved the project says so through REPO_ROOT.
    $repoRootVar = Get-Variable -Name "REPO_ROOT" -ErrorAction SilentlyContinue
    if ($null -ne $repoRootVar) {
        $ProjectRoot = $repoRootVar.Value
    }
}
$REPO_ROOT = Resolve-CrucibleProjectRoot -ProjectRoot $ProjectRoot -ScriptRoot $PSScriptRoot
Push-Location $REPO_ROOT
try {
    $crucibleLibPath = Join-Path $PSScriptRoot "crucible-lib.ps1"
    . $crucibleLibPath

    # D41: Validate that the resolved bundle actually owns the task
    $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $REPO_ROOT
    if (-not (Test-Path -LiteralPath $backlogDir)) {
        throw "Backlog directory not found at $backlogDir; please check ProjectRoot or REPO_ROOT."
    }
    $backlogPath = Join-Path $backlogDir "BACKLOG.md"
    if (-not (Test-Path -LiteralPath $backlogPath)) {
        throw "BACKLOG.md not found at $backlogPath; please check ProjectRoot or REPO_ROOT."
    }
    $backlogContent = Get-Content -LiteralPath $backlogPath -Raw -Encoding UTF8
    if ($backlogContent -notmatch [regex]::Escape($TaskId)) {
        throw "TaskId $TaskId not found in the bundle at $REPO_ROOT; pass -ProjectRoot pointing at the adopter repo."
    }

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
    $candidates = @(Get-ChildItem -Path $HandoffDir -Filter ($Task + "-*.json") -ErrorAction SilentlyContinue)
    $candidates = @(Sort-HandoffFiles -Files $candidates)
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

function Get-HandoffOutputPath {
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        return $OutputPath
    }
    return (Join-Path $handoffDir ($TaskId + "-" + (Get-UtcFileTimestamp) + ".json"))
}

function Write-ValidatedHandoff {
    param($Payload, [string]$Path)

    $tempPath = $Path + ".tmp"
    try {
        $json = $Payload | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($tempPath, $json, (New-Object System.Text.UTF8Encoding $false))

        $validatorPath = Join-Path $PSScriptRoot "validate-handoff.ps1"
        if (-not (Test-Path -LiteralPath $validatorPath)) {
            throw "Validator not found: $validatorPath"
        }

        $validationRaw = & $validatorPath -HandoffFile $tempPath -SchemaPath $SchemaPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $validationText = ($validationRaw -join "`n").Trim()
            if ([string]::IsNullOrWhiteSpace($validationText)) {
                $validationText = "unknown validation error"
            }
            throw "Schema validation failed: $validationText"
        }

        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    } catch {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

$sessionDir = Get-ConfiguredPath -Key "session"
$handoffDir = Join-Path $sessionDir "handoffs"
if (-not (Test-Path -LiteralPath $handoffDir)) {
    New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
}

# A bundle update committed while a task is in flight lands between the task's
# base_commit and HEAD, so the framework-integrity gate reads it as a specialist edit.
# The human-approved fix is to move the baseline, and nothing else: writing a fresh
# transition would mean re-authoring the specialist's handoff and spending a budget
# handoff on a decision no specialist made. The copy keeps cumulative_handoff_count and
# the transition key, and the budget gate counts session_end events, not files.
if ($Rebaseline) {
    $rebaselineAllowed = @("TaskId", "Rebaseline", "BaseCommit", "ProjectRoot", "SchemaPath", "OutputPath") + [System.Management.Automation.PSCmdlet]::CommonParameters
    $rebaselineExtra = @($PSBoundParameters.Keys | Where-Object { $rebaselineAllowed -notcontains $_ })
    if ($rebaselineExtra.Count -gt 0) {
        throw ("-Rebaseline carries the latest handoff forward with only base_commit changed, so it takes no other handoff fields. Remove: -" + ($rebaselineExtra -join ", -"))
    }
    if ([string]::IsNullOrWhiteSpace($BaseCommit)) {
        throw "-Rebaseline needs -BaseCommit: the commit to re-baseline $TaskId onto, normally the bundle update commit."
    }

    $rebaselineFile = $null
    $rebaselineObj = $null
    foreach ($file in @(Sort-HandoffFiles -Files @(Get-ChildItem -Path $handoffDir -Filter ($TaskId + "-*.json") -ErrorAction SilentlyContinue))) {
        try {
            $obj = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            continue
        }
        if (-not ($obj.PSObject.Properties["superseded"] -and $obj.superseded -eq $true)) {
            $rebaselineFile = $file
            $rebaselineObj = $obj
            break
        }
    }
    if ($null -eq $rebaselineObj) {
        throw "No active handoff for $TaskId in $handoffDir, so there is nothing to re-baseline. A task with no handoff yet takes its base from the primary branch when its first handoff is written."
    }

    $newBase = (git -C $REPO_ROOT rev-parse --verify --quiet ($BaseCommit + "^{commit}") 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($newBase)) {
        throw "-BaseCommit '$BaseCommit' does not name a commit in $REPO_ROOT."
    }
    $newBase = ([string]$newBase).Trim()

    $oldBase = if ($rebaselineObj.PSObject.Properties["base_commit"] -and -not [string]::IsNullOrWhiteSpace([string]$rebaselineObj.base_commit)) { ([string]$rebaselineObj.base_commit).Trim() } else { $null }
    if ($null -ne $oldBase) {
        if ($oldBase -eq $newBase) {
            throw "$TaskId is already based on $newBase ($($rebaselineFile.Name)). Nothing to re-baseline."
        }
        # Forward only. Moving the base sideways or back would also drop task commits
        # from the integrity diff, which is a different decision from accepting an update.
        git -C $REPO_ROOT merge-base --is-ancestor $oldBase $newBase 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "-BaseCommit $newBase does not descend from the current base_commit $oldBase in $($rebaselineFile.Name). A re-baseline moves a task forward onto a bundle update committed after its base; it does not move the base sideways or back."
        }
    }

    $supersedeFields = @("superseded", "superseded_by", "superseded_at", "superseded_reason")
    $rebaselinePayload = [ordered]@{}
    foreach ($prop in $rebaselineObj.PSObject.Properties) {
        if ($supersedeFields -contains $prop.Name) { continue }
        $rebaselinePayload[$prop.Name] = $prop.Value
    }
    $rebaselinePayload["base_commit"] = $newBase
    $rebaselinePayload["rebaselined_from"] = $oldBase

    $rebaselinePath = Get-HandoffOutputPath
    if (Test-Path -LiteralPath $rebaselinePath) {
        throw "$rebaselinePath already exists. Wait a second and re-run: handoff file names carry a one-second timestamp."
    }
    Write-ValidatedHandoff -Payload $rebaselinePayload -Path $rebaselinePath

    $rebaselineObj | Add-Member -MemberType NoteProperty -Name superseded -Value $true -Force
    $rebaselineObj | Add-Member -MemberType NoteProperty -Name superseded_by -Value (Split-Path -Leaf $rebaselinePath) -Force
    $rebaselineObj | Add-Member -MemberType NoteProperty -Name superseded_at -Value (Get-UtcTimestamp) -Force
    $rebaselineObj | Add-Member -MemberType NoteProperty -Name superseded_reason -Value "rebaseline" -Force
    [System.IO.File]::WriteAllText($rebaselineFile.FullName, ($rebaselineObj | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding $false))

    [ordered]@{
        ok                       = $true
        handoff_file             = $rebaselinePath
        task_id                  = $TaskId
        source                   = $rebaselineObj.source_phase
        target                   = $rebaselineObj.target_phase
        base_commit              = $newBase
        rebaselined_from         = $oldBase
        superseded               = $rebaselineFile.Name
        cumulative_handoff_count = $rebaselineObj.cumulative_handoff_count
    } | ConvertTo-Json
    return
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

$inheritedReviewStrike = if ($null -ne $latest -and $latest.PSObject.Properties["review_strike_count"]) {
    [int]$latest.review_strike_count
} else {
    0
}
# A reviewer sending work back (verification -> implementation) is a review failure:
# auto-increment the strike so the review_stalemate breaker (strike >= 3) can fire on a
# repeated review-bounce loop. The Human-Gate REJECT path passes -ReviewStrikeCount
# explicitly; every other caller inherits unchanged.
$resolvedReviewStrike = if ($ReviewStrikeCount -ge 0) {
    $ReviewStrikeCount
} elseif ($Source -eq "verification" -and $Target -eq "implementation") {
    $inheritedReviewStrike + 1
} else {
    $inheritedReviewStrike
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

# The source prompt names the prompt that actually ran, so it wins over a copied -PromptVersion. Item 168.
$resolvedPromptVersion = if (-not [string]::IsNullOrWhiteSpace($promptVersionFromPrompt)) {
    if (-not [string]::IsNullOrWhiteSpace($PromptVersion) -and $PromptVersion -ne $promptVersionFromPrompt) {
        Write-Warning "-PromptVersion '$PromptVersion' does not match '$promptVersionFromPrompt' in $sourcePromptPath; recording '$promptVersionFromPrompt'."
    }
    $promptVersionFromPrompt
} elseif (-not [string]::IsNullOrWhiteSpace($PromptVersion)) {
    $PromptVersion
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
} elseif ($null -eq $latest -and $Source -eq "deployment") {
    # A hand-written task bootstrap: match the cycle id -Init's auto-bootstrap writes.
    "initial"
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

$resolvedBaseCommit = if (-not [string]::IsNullOrWhiteSpace($BaseCommit)) {
    $BaseCommit
} elseif ($null -ne $latest -and $latest.PSObject.Properties["base_commit"] -and -not [string]::IsNullOrWhiteSpace([string]$latest.base_commit)) {
    [string]$latest.base_commit
} else {
    $null
}

$isGitRepo = $false
$checkDir = $REPO_ROOT
while (-not [string]::IsNullOrEmpty($checkDir)) {
    if (Test-Path -LiteralPath (Join-Path $checkDir ".git")) {
        $isGitRepo = $true
        break
    }
    $parent = Split-Path -Parent $checkDir
    if ($parent -eq $checkDir -or [string]::IsNullOrEmpty($parent)) { break }
    $checkDir = $parent
}

if ($isGitRepo) {
    if ([string]::IsNullOrWhiteSpace($resolvedBaseCommit)) {
        $taskBranch = "task/$TaskId"
        git show-ref --verify --quiet "refs/heads/$taskBranch" 2>$null
        if ($LASTEXITCODE -ne 0) {
            $primaryBranch = "master"
            git show-ref --verify --quiet refs/heads/main 2>$null
            if ($LASTEXITCODE -eq 0) { $primaryBranch = "main" }
            
            $primaryHead = (git rev-parse $primaryBranch 2>$null)
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($primaryHead)) {
                $resolvedBaseCommit = $primaryHead.Trim()
            }
        }
    }

    # On deployment -> done the commit being deployed is the tip of the task branch, and git
    # is the only thing that knows it. An inherited hash is stale by construction: it is
    # whatever an earlier phase or deployment attempt recorded, before a rebase moved the
    # branch or a recovery deleted it. No task branch means nothing was built, which is the
    # No-Code Closure the merge-verification gate looks for, so write null and let the gate
    # judge. Inheriting there named a deleted branch's commit, which defeated the closure
    # and passed pre-gate verification because a dangling commit still exists (item 159).
    if ($Source -eq "deployment" -and $Target -eq "done" -and [string]::IsNullOrWhiteSpace($CommitHash)) {
        $resolvedCommitHash = $null
        $deployBranch = "task/$TaskId"
        git show-ref --verify --quiet "refs/heads/$deployBranch" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $deployTip = (git rev-parse "refs/heads/$deployBranch" 2>$null)
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($deployTip)) {
                $resolvedCommitHash = $deployTip.Trim()
            }
        }
    }
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

$baseAffinity = @()
if ($null -ne $FileAffinity -and $FileAffinity.Count -gt 0) {
    $baseAffinity = @($FileAffinity | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    # Quotes escaped for a nested shell arrive as characters, and B-012's Groomer wrote
    # "\"internal/app/\"" into file_affinity that way. Refuse rather than strip: a mangled
    # value should reach the caller, not a handoff that counts against the budget.
    $quotedAffinity = @($baseAffinity | Where-Object { $_ -match "[`"']" })
    if ($quotedAffinity.Count -gt 0) {
        throw ("-FileAffinity entry contains a quote character, which no path can: " + ($quotedAffinity -join ", ") + ". Pass the paths unquoted, as separate arguments or comma-joined.")
    }
} elseif ($null -ne $latest -and $latest.PSObject.Properties["file_affinity"] -and $null -ne $latest.file_affinity -and @($latest.file_affinity).Count -gt 0) {
    $baseAffinity = @($latest.file_affinity)
}

$specPath = Get-BacklogItemPathForTask -Task $TaskId
$frontmatterAffinity = @()
if ($specPath -and (Test-Path -LiteralPath $specPath)) {
    $specContent = Get-Content -LiteralPath $specPath -Raw -Encoding UTF8
    $frontmatterAffinity = @(Get-SpecFrontmatterAffinity -SpecContent $specContent)
}

# The spec's frontmatter is the one record of a task's scope. A Groomer that widens it
# must say so there, or the spec and the scope gate disagree with nothing reporting it.
if ($Source -eq "grooming" -and $Target -eq "implementation" -and $frontmatterAffinity.Count -gt 0) {
    $widenedAffinity = @(Get-AffinityWidening -Affinity $baseAffinity -Declared $frontmatterAffinity)
    if ($widenedAffinity.Count -gt 0) {
        throw ("file_affinity " + ($widenedAffinity -join ", ") + " is not covered by the spec's frontmatter file_affinity (" + ($frontmatterAffinity -join ", ") + "). The frontmatter is the record of scope: add the widened paths to file_affinity in " + $specPath + ", or narrow -FileAffinity, then write the handoff again.")
    }
}

[string[]]$resolvedFileAffinity = @(
    @($baseAffinity + $frontmatterAffinity) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)

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
    reason                   = (ConvertTo-AsciiSafeText -Text $Reason)
    generated_by             = "new-handoff.ps1"
    tool_version             = "1.0.0"
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
    base_commit              = $resolvedBaseCommit
    artifacts                = $resolvedArtifacts
}

if ($Source -eq "grooming" -or @($resolvedFileAffinity).Count -gt 0) {
    $payload.file_affinity = $resolvedFileAffinity
}
if ($Target -eq "implementation") {
    $payload.design_required = [bool]$DesignRequired
}
if (@($resolvedStubSpecsCreated).Count -gt 0) {
    $payload.stub_specs_created = $resolvedStubSpecsCreated
}
[string[]]$resolvedReviewerChecks = @($ReviewerChecksPassed | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
if ($resolvedReviewerChecks.Count -gt 0) {
    $payload.reviewer_checks_passed = $resolvedReviewerChecks
}
if (@($HumanApproved).Count -gt 0 -or @($HumanDeferred).Count -gt 0 -or @($HumanRejected).Count -gt 0) {
    $payload.human_decisions = [ordered]@{
        approved = @($HumanApproved)
        deferred = @($HumanDeferred)
        rejected = @($HumanRejected)
    }
}

$resolvedOutputPath = Get-HandoffOutputPath
Write-ValidatedHandoff -Payload $payload -Path $resolvedOutputPath

[ordered]@{
    ok           = $true
    handoff_file = $resolvedOutputPath
    task_id      = $TaskId
    source       = $Source
    target       = $Target
} | ConvertTo-Json
} finally {
    Pop-Location
}
