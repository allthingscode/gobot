param(
    [Parameter(Mandatory = $true)]
    [string]$HandoffFile,

    [string]$SchemaPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$factoryLibPath = Join-Path $PSScriptRoot "factory-lib.ps1"
. $factoryLibPath

# Default schema location: framework's own schemas/ directory (one level up from powershell/).
if ([string]::IsNullOrWhiteSpace($SchemaPath)) {
    $SchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) "schemas/handoff.schema.json"
}

function Write-ValidationResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Ok,
        [string]$ReasonCode = "",
        [string]$Message = "",
        [hashtable]$Details = @{}
    )

    $result = [ordered]@{
        ok          = $Ok
        reason_code = $ReasonCode
        message     = $Message
        details     = $Details
    }

    $result | ConvertTo-Json -Compress
    if ($Ok) { exit 0 } else { exit 1 }
}

function Test-RequiredField {
    param(
        [Parameter(Mandatory = $true)]$Handoff,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    if ($null -eq $Handoff.PSObject.Properties[$FieldName]) {
        return $false
    }

    $value = $Handoff.$FieldName
    if ($null -eq $value) {
        if ($FieldName -eq "suspicious_content") {
            return $true
        }
        return $false
    }

    if ($value -is [string]) {
        return -not [string]::IsNullOrWhiteSpace($value)
    }

    return $true
}

function Get-MatchingContractClauses {
    param(
        [Parameter(Mandatory = $true)]$Schema,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $matches = @()
    if ($null -eq $Schema.PSObject.Properties["allOf"] -or $null -eq $Schema.allOf) {
        return $matches
    }

    foreach ($clause in @($Schema.allOf)) {
        if ($null -eq $clause.PSObject.Properties["if"] -or $null -eq $clause.PSObject.Properties["then"]) {
            continue
        }

        $ifNode = $clause.if
        $thenNode = $clause.then
        $isMatch = $true

        if ($ifNode.PSObject.Properties["properties"] -and $null -ne $ifNode.properties) {
            $props = $ifNode.properties
            if ($props.PSObject.Properties["source_phase"]) {
                $spNode = $props.source_phase
                if ($spNode.PSObject.Properties["const"]) {
                    if ($Source -ne ([string]$spNode.const).Trim().ToLowerInvariant()) {
                        $isMatch = $false
                    }
                } elseif ($spNode.PSObject.Properties["enum"]) {
                    $enumList = @($spNode.enum | ForEach-Object { $_.Trim().ToLowerInvariant() })
                    if ($enumList -notcontains $Source.Trim().ToLowerInvariant()) {
                        $isMatch = $false
                    }
                }
            }
            if ($props.PSObject.Properties["target_phase"]) {
                $tpNode = $props.target_phase
                if ($tpNode.PSObject.Properties["const"]) {
                    if ($Target -ne ([string]$tpNode.const).Trim().ToLowerInvariant()) {
                        $isMatch = $false
                    }
                } elseif ($tpNode.PSObject.Properties["enum"]) {
                    $enumList = @($tpNode.enum | ForEach-Object { $_.Trim().ToLowerInvariant() })
                    if ($enumList -notcontains $Target.Trim().ToLowerInvariant()) {
                        $isMatch = $false
                    }
                }
            }
        }

        if ($isMatch) {
            $matches += $thenNode
        }
    }

    return $matches
}

function Assert-SchemaContract {
    param(
        [Parameter(Mandatory = $true)]$Handoff,
        [Parameter(Mandatory = $true)]$Schema,
        [Parameter(Mandatory = $true)][string]$HandoffFile,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $matchedClauses = Get-MatchingContractClauses -Schema $Schema -Source $Source -Target $Target
    foreach ($thenNode in @($matchedClauses)) {
        if ($thenNode.PSObject.Properties["required"] -and $null -ne $thenNode.required) {
            foreach ($field in @($thenNode.required)) {
                if (-not (Test-RequiredField -Handoff $Handoff -FieldName ([string]$field))) {
                    $reasonCode = "missing_required_field"
                    if ([string]$field -eq "reviewer_checks_passed") {
                        $reasonCode = "reviewer_contract_failed"
                    }

                    Write-ValidationResult -Ok $false `
                        -ReasonCode $reasonCode `
                        -Message ("Missing required field: " + $field) `
                        -Details @{ field = $field; source_phase = $Source; target_phase = $Target; handoff_file = $HandoffFile }
                }
            }
        }

        if ($thenNode.PSObject.Properties["not"] -and $null -ne $thenNode.not) {
            $notNode = $thenNode.not

            if ($notNode.PSObject.Properties["required"] -and $null -ne $notNode.required) {
                foreach ($field in @($notNode.required)) {
                    if ($null -ne $Handoff.PSObject.Properties[[string]$field]) {
                        Write-ValidationResult -Ok $false `
                            -ReasonCode "invalid_field" `
                            -Message ("Field is not allowed for this transition: " + $field) `
                            -Details @{ field = $field; source_phase = $Source; target_phase = $Target; handoff_file = $HandoffFile }
                    }
                }
            }

            if ($notNode.PSObject.Properties["anyOf"] -and $null -ne $notNode.anyOf) {
                foreach ($forbiddenRule in @($notNode.anyOf)) {
                    if ($forbiddenRule.PSObject.Properties["required"] -and $null -ne $forbiddenRule.required) {
                        foreach ($field in @($forbiddenRule.required)) {
                            if ($null -ne $Handoff.PSObject.Properties[[string]$field]) {
                                Write-ValidationResult -Ok $false `
                                    -ReasonCode "invalid_field" `
                                    -Message ("Field is not allowed for this transition: " + $field) `
                                    -Details @{ field = $field; source_phase = $Source; target_phase = $Target; handoff_file = $HandoffFile }
                            }
                        }
                    }
                }
            }
        }
    }
}

if (-not (Test-Path -LiteralPath $HandoffFile)) {
    Write-ValidationResult -Ok $false `
        -ReasonCode "invalid_json" `
        -Message "Handoff file not found." `
        -Details @{ field = "handoff_file"; handoff_file = $HandoffFile }
}

if (-not (Test-Path -LiteralPath $SchemaPath)) {
    Write-ValidationResult -Ok $false `
        -ReasonCode "invalid_json" `
        -Message "Handoff schema not found." `
        -Details @{ field = "schema_path"; schema_path = $SchemaPath }
}

try {
    $handoffRaw = Get-Content -LiteralPath $HandoffFile -Raw
    $handoff = $handoffRaw | ConvertFrom-Json
} catch {
    Write-ValidationResult -Ok $false `
        -ReasonCode "invalid_json" `
        -Message "Handoff JSON is invalid and could not be parsed." `
        -Details @{ handoff_file = $HandoffFile }
}

try {
    $schemaRaw = Get-Content -LiteralPath $SchemaPath -Raw
    $schema = $schemaRaw | ConvertFrom-Json
} catch {
    Write-ValidationResult -Ok $false `
        -ReasonCode "missing_required_field" `
        -Message "Handoff schema JSON is invalid and could not be parsed." `
        -Details @{ schema_path = $SchemaPath }
}

# Provenance verification (Part B)
if ($null -eq $handoff.PSObject.Properties["generated_by"] -or $handoff.generated_by -ne "new-handoff.ps1") {
    Write-ValidationResult -Ok $false `
        -ReasonCode "handoff_not_tool_generated" `
        -Message "Handoff must be generated using new-handoff.ps1. Direct hand-authoring is forbidden." `
        -Details @{ handoff_file = $HandoffFile }
}
$allowedToolVersions = @("1.0.0")
if ($null -eq $handoff.PSObject.Properties["tool_version"] -or $allowedToolVersions -notcontains $handoff.tool_version) {
    Write-ValidationResult -Ok $false `
        -ReasonCode "handoff_not_tool_generated" `
        -Message ("Handoff tool_version '" + $handoff.tool_version + "' is not recognized. Allowed versions: " + ($allowedToolVersions -join ", ")) `
        -Details @{ handoff_file = $HandoffFile; tool_version = $handoff.tool_version }
}

$requiredFields = @()
if ($schema.PSObject.Properties["required"] -and $null -ne $schema.required) {
    $requiredFields = @($schema.required)
}

foreach ($field in $requiredFields) {
    if (-not (Test-RequiredField -Handoff $handoff -FieldName $field)) {
        Write-ValidationResult -Ok $false `
            -ReasonCode "missing_required_field" `
            -Message ("Missing required field: " + $field) `
            -Details @{ field = $field; handoff_file = $HandoffFile }
    }
}

$deploymentSuccessors = [System.Collections.Generic.List[string]]::new()
$deploymentSuccessors.Add("grooming")
$deploymentSuccessors.Add("done")

$resolvedProjectRoot = $null
$repoRootVar = Get-Variable -Name "REPO_ROOT" -ErrorAction SilentlyContinue
if ($null -ne $repoRootVar) {
    $resolvedProjectRoot = $repoRootVar.Value
}
if ([string]::IsNullOrEmpty($resolvedProjectRoot)) {
    $resolvedProjectRoot = (Get-Location).Path
}

$sessionDir = Get-ConfiguredPath -Key "session" -ProjectRoot $resolvedProjectRoot
$gateDir = Join-Path $sessionDir "global/gate_decisions"
$isRework = $false
$taskId = ""
if ($null -ne $handoff -and $null -ne $handoff.task_id) {
    $taskId = ([string]$handoff.task_id).Trim()
}

if (-not [string]::IsNullOrEmpty($taskId) -and (Test-Path $gateDir)) {
    $decisions = @(Get-ChildItem -Path $gateDir -Filter ($taskId + "-*.json") -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "gate_decision_.*_pending.json" } |
        Sort-Object LastWriteTime -Descending)
    if ($decisions.Count -gt 0) {
        try {
            $latestDecision = Get-Content $decisions[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($latestDecision.outcome -eq "rejected" -and $latestDecision.rework_requested -eq $true) {
                $isRework = $true
            }
        } catch {}
    }
}

# A deployment -> implementation handoff carrying rebase_count >= 1 is a
# rebase-conflict re-entry emitted by the accept gate when a merge could not be
# auto-rebased cleanly (see Invoke-HumanGateMerge). The authorizing gate decision
# is "accepted" (not "rejected"), so recognize the rebase counter directly.
if (-not $isRework -and $null -ne $handoff -and $handoff.PSObject.Properties["rebase_count"]) {
    $rebaseCountVal = 0
    if ([int]::TryParse([string]$handoff.rebase_count, [ref]$rebaseCountVal) -and $rebaseCountVal -ge 1) {
        $isRework = $true
    }
}

if ($isRework) {
    $deploymentSuccessors.Add("implementation")
}

$validTransitions = @{
    grooming       = @("implementation", "research", "verification", "done")
    implementation = @("verification")
    verification   = @("deployment", "implementation")
    deployment     = $deploymentSuccessors.ToArray()
    research       = @("grooming")
}

$source = ([string]$handoff.source_phase).Trim().ToLowerInvariant()
$target = ([string]$handoff.target_phase).Trim().ToLowerInvariant()
$validPhases = @($script:FACTORY_PHASES)

if ($validPhases -notcontains $source -or
    ($validPhases -notcontains $target -and $target -ne "done") -or
    -not $validTransitions.ContainsKey($source) -or
    -not ($validTransitions[$source] -contains $target)) {
    Write-ValidationResult -Ok $false `
        -ReasonCode "invalid_transition" `
        -Message ("Invalid phase transition: " + $source + " -> " + $target) `
        -Details @{ source_phase = $source; target_phase = $target; handoff_file = $HandoffFile }
}

# Phase-specific transition required fields check (Part C)
if ($source -eq "research") {
    if (-not (Test-RequiredField -Handoff $handoff -FieldName "human_decisions")) {
        Write-ValidationResult -Ok $false -ReasonCode "missing_required_field" -Message "Research handoff requires human_decisions." -Details @{ field = "human_decisions"; handoff_file = $HandoffFile }
    }
    if (-not (Test-RequiredField -Handoff $handoff -FieldName "artifacts")) {
        Write-ValidationResult -Ok $false -ReasonCode "missing_required_field" -Message "Research handoff requires artifacts." -Details @{ field = "artifacts"; handoff_file = $HandoffFile }
    }
    if ($null -ne $handoff.PSObject.Properties["reviewer_checks_passed"]) {
        Write-ValidationResult -Ok $false -ReasonCode "invalid_field" -Message "Research handoff must not contain reviewer_checks_passed." -Details @{ field = "reviewer_checks_passed"; handoff_file = $HandoffFile }
    }
}
elseif ($source -eq "grooming") {
    if (-not (Test-RequiredField -Handoff $handoff -FieldName "artifacts")) {
        Write-ValidationResult -Ok $false -ReasonCode "missing_required_field" -Message "Grooming handoff requires artifacts." -Details @{ field = "artifacts"; handoff_file = $HandoffFile }
    }
    if ($target -eq "implementation") {
        if (-not (Test-RequiredField -Handoff $handoff -FieldName "file_affinity")) {
            Write-ValidationResult -Ok $false -ReasonCode "missing_required_field" -Message "Grooming to implementation handoff requires file_affinity." -Details @{ field = "file_affinity"; handoff_file = $HandoffFile }
        }
    }
    elseif ($target -eq "verification") {
        if (-not (Test-RequiredField -Handoff $handoff -FieldName "stub_specs_created")) {
            Write-ValidationResult -Ok $false -ReasonCode "missing_required_field" -Message "Grooming shortcut to verification requires stub_specs_created." -Details @{ field = "stub_specs_created"; handoff_file = $HandoffFile }
        }
    }
    if ($null -ne $handoff.PSObject.Properties["reviewer_checks_passed"]) {
        Write-ValidationResult -Ok $false -ReasonCode "invalid_field" -Message "Grooming handoff must not contain reviewer_checks_passed." -Details @{ field = "reviewer_checks_passed"; handoff_file = $HandoffFile }
    }
    if ($null -ne $handoff.PSObject.Properties["human_decisions"]) {
        Write-ValidationResult -Ok $false -ReasonCode "invalid_field" -Message "Grooming handoff must not contain human_decisions." -Details @{ field = "human_decisions"; handoff_file = $HandoffFile }
    }
}
elseif ($source -eq "implementation") {
    if (-not (Test-RequiredField -Handoff $handoff -FieldName "session_cycle_id")) {
        Write-ValidationResult -Ok $false -ReasonCode "missing_required_field" -Message "Implementation handoff requires session_cycle_id." -Details @{ field = "session_cycle_id"; handoff_file = $HandoffFile }
    }
    if (-not (Test-RequiredField -Handoff $handoff -FieldName "artifacts")) {
        Write-ValidationResult -Ok $false -ReasonCode "missing_required_field" -Message "Implementation handoff requires artifacts." -Details @{ field = "artifacts"; handoff_file = $HandoffFile }
    }
    if ($null -ne $handoff.PSObject.Properties["reviewer_checks_passed"]) {
        Write-ValidationResult -Ok $false -ReasonCode "invalid_field" -Message "Implementation handoff must not contain reviewer_checks_passed." -Details @{ field = "reviewer_checks_passed"; handoff_file = $HandoffFile }
    }
    if ($null -ne $handoff.PSObject.Properties["human_decisions"]) {
        Write-ValidationResult -Ok $false -ReasonCode "invalid_field" -Message "Implementation handoff must not contain human_decisions." -Details @{ field = "human_decisions"; handoff_file = $HandoffFile }
    }
}
elseif ($source -eq "verification") {
    if (-not (Test-RequiredField -Handoff $handoff -FieldName "session_cycle_id")) {
        Write-ValidationResult -Ok $false -ReasonCode "missing_required_field" -Message "Verification handoff requires session_cycle_id." -Details @{ field = "session_cycle_id"; handoff_file = $HandoffFile }
    }
    if (-not (Test-RequiredField -Handoff $handoff -FieldName "artifacts")) {
        Write-ValidationResult -Ok $false -ReasonCode "missing_required_field" -Message "Verification handoff requires artifacts." -Details @{ field = "artifacts"; handoff_file = $HandoffFile }
    }
    if ($target -eq "deployment") {
        if (-not (Test-RequiredField -Handoff $handoff -FieldName "reviewer_checks_passed")) {
            Write-ValidationResult -Ok $false -ReasonCode "reviewer_contract_failed" -Message "Verification approval handoff requires reviewer_checks_passed." -Details @{ field = "reviewer_checks_passed"; handoff_file = $HandoffFile }
        }
    }
    if ($null -ne $handoff.PSObject.Properties["human_decisions"]) {
        Write-ValidationResult -Ok $false -ReasonCode "invalid_field" -Message "Verification handoff must not contain human_decisions." -Details @{ field = "human_decisions"; handoff_file = $HandoffFile }
    }
}
elseif ($source -eq "deployment") {
    if (-not (Test-RequiredField -Handoff $handoff -FieldName "session_cycle_id")) {
        Write-ValidationResult -Ok $false -ReasonCode "missing_required_field" -Message "Deployment handoff requires session_cycle_id." -Details @{ field = "session_cycle_id"; handoff_file = $HandoffFile }
    }
    if (-not (Test-RequiredField -Handoff $handoff -FieldName "artifacts")) {
        Write-ValidationResult -Ok $false -ReasonCode "missing_required_field" -Message "Deployment handoff requires artifacts." -Details @{ field = "artifacts"; handoff_file = $HandoffFile }
    }
    if ($target -eq "done" -and -not (Test-RequiredField -Handoff $handoff -FieldName "commit_hash")) {
        Write-ValidationResult -Ok $false -ReasonCode "missing_required_field" -Message "Deployment completed handoff requires commit_hash." -Details @{ field = "commit_hash"; handoff_file = $HandoffFile }
    }
    if ($null -ne $handoff.PSObject.Properties["reviewer_checks_passed"]) {
        Write-ValidationResult -Ok $false -ReasonCode "invalid_field" -Message "Deployment handoff must not contain reviewer_checks_passed." -Details @{ field = "reviewer_checks_passed"; handoff_file = $HandoffFile }
    }
    if ($null -ne $handoff.PSObject.Properties["human_decisions"]) {
        Write-ValidationResult -Ok $false -ReasonCode "invalid_field" -Message "Deployment handoff must not contain human_decisions." -Details @{ field = "human_decisions"; handoff_file = $HandoffFile }
    }
}

Assert-SchemaContract -Handoff $handoff -Schema $schema -HandoffFile $HandoffFile -Source $source -Target $target

$taskId = ([string]$handoff.task_id).Trim()
$handoffBudgetTier = ""
if ($handoff.PSObject.Properties["budget_tier"] -and $null -ne $handoff.budget_tier) {
    $handoffBudgetTier = ([string]$handoff.budget_tier).Trim().ToLowerInvariant()
}

if (-not [string]::IsNullOrWhiteSpace($handoffBudgetTier) -and -not (Test-BudgetTier -BudgetTier $handoffBudgetTier)) {
    Write-ValidationResult -Ok $false `
        -ReasonCode "invalid_budget_tier" `
        -Message ("Invalid budget_tier: " + $handoffBudgetTier + ". Allowed values: " + ((Get-BudgetTierList) -join ", ")) `
        -Details @{
            handoff_file = $HandoffFile
            task_id = $taskId
            handoff_budget_tier = $handoffBudgetTier
            allowed_budget_tiers = Get-BudgetTierList
        }
}

if (-not [string]::IsNullOrWhiteSpace($taskId) -and -not [string]::IsNullOrWhiteSpace($handoffBudgetTier)) {
    $specBudget = Get-SpecBudgetTier -Task $taskId -IncludePath
    $specBudgetTier = [string]$specBudget.Tier
    if (-not [string]::IsNullOrWhiteSpace($specBudgetTier) -and $specBudgetTier -ne $handoffBudgetTier) {
        Write-ValidationResult -Ok $false `
            -ReasonCode "budget_tier_mismatch" `
            -Message ("budget_tier mismatch: handoff=" + $handoffBudgetTier + ", spec=" + $specBudgetTier) `
            -Details @{
                handoff_file = $HandoffFile
                spec_file = [string]$specBudget.Path
                task_id = $taskId
                handoff_budget_tier = $handoffBudgetTier
                spec_budget_tier = $specBudgetTier
            }
    }
}

if ($handoff.PSObject.Properties["artifacts"] -and $null -ne $handoff.artifacts) {
    foreach ($artifact in @($handoff.artifacts)) {
        if ([string]::IsNullOrWhiteSpace([string]$artifact)) {
            Write-ValidationResult -Ok $false `
                -ReasonCode "missing_artifact" `
                -Message "Artifact path is empty." `
                -Details @{ artifact = $artifact; handoff_file = $HandoffFile }
        }
    }
}

if ($source -eq "reviewer" -and $target -eq "operator") {
    $expectedChecks = @()
    if ($schema.PSObject.Properties["properties"] -and
        $schema.properties.PSObject.Properties["reviewer_checks_passed"] -and
        $schema.properties.reviewer_checks_passed.PSObject.Properties["items"] -and
        $schema.properties.reviewer_checks_passed.items.PSObject.Properties["enum"]) {
        $expectedChecks = @($schema.properties.reviewer_checks_passed.items.enum)
    }

    if ($expectedChecks.Count -eq 0) {
        Write-ValidationResult -Ok $false `
            -ReasonCode "reviewer_contract_failed" `
            -Message "Schema reviewer_checks_passed enum is missing." `
            -Details @{ field = "reviewer_checks_passed"; schema_path = $SchemaPath }
    }

    if ($null -eq $handoff.PSObject.Properties["reviewer_checks_passed"] -or $null -eq $handoff.reviewer_checks_passed) {
        Write-ValidationResult -Ok $false `
            -ReasonCode "reviewer_contract_failed" `
            -Message "Reviewer handoff to Operator must include reviewer_checks_passed." `
            -Details @{ field = "reviewer_checks_passed"; handoff_file = $HandoffFile }
    }

    $checks = @($handoff.reviewer_checks_passed)
    $missingChecks = @()
    foreach ($check in $expectedChecks) {
        if ($checks -notcontains $check) {
            $missingChecks += $check
        }
    }

    if ($missingChecks.Count -gt 0) {
        Write-ValidationResult -Ok $false `
            -ReasonCode "reviewer_contract_failed" `
            -Message "Reviewer handoff contract is incomplete." `
            -Details @{ missing_checks = $missingChecks; handoff_file = $HandoffFile }
    }
}

Write-ValidationResult -Ok $true -Message "Preflight validation passed."
