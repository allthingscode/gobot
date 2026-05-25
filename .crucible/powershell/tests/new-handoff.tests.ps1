$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$realRepoRoot = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$generator = Join-Path $realRepoRoot "powershell/new-handoff.ps1"
$schemaPath = Join-Path $realRepoRoot "schemas/handoff.schema.json"

# Isolate execution in a temp directory to prevent repo-root test pollution
$origLocation = Get-Location
$tempRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

# Copy the powershell directory so relative file path artifacts exist for testing
Copy-Item -Path (Join-Path $realRepoRoot "powershell") -Destination (Join-Path $tempRoot "powershell") -Recurse -Force | Out-Null

# Set REPO_ROOT to temp root so new-handoff.ps1 resolves its target path to the temp directory
$REPO_ROOT = $tempRoot

Set-Location -LiteralPath $tempRoot

$handoffDir = ".crucible/session/handoffs"
$testTaskPrefix = "{task_id}"
$createdFiles = @()
$createdSpecFiles = @()

function Invoke-Test {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Script
    )
    Write-Host "`n[TEST] $Name" -ForegroundColor Cyan
    & $Script
    Write-Host "[PASS] $Name" -ForegroundColor Green
}

function New-TestTaskId {
    param([string]$Suffix)
    return "$testTaskPrefix-$Suffix"
}

function Invoke-Generator {
    param([hashtable]$InputArgs)
    try {
        $output = & $generator @InputArgs 2>&1
        return @{
            ExitCode = 0
            Output   = ($output -join "`n")
        }
    } catch {
        return @{
            ExitCode = 1
            Output   = $_.Exception.Message
        }
    }
}

function Track-HandoffFile {
    param([string]$TaskId)
    $latest = Get-ChildItem -Path $handoffDir -Filter ($TaskId + "-*.json") -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if ($null -ne $latest) {
        $script:createdFiles += $latest.FullName
        return $latest.FullName
    }
    return $null
}

try {
    Invoke-Test -Name "groomer->architect success" -Script {
        $taskId = New-TestTaskId "GA"
        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "groomer"
            Target = "architect"
            Reason = "groomer handoff test"
            PromptVersion = "architect_prompt-v21"
            Artifacts = @("powershell/factory.ps1")
            FileAffinity = @("powershell/", "schemas/handoff.schema.json")
            SchemaPath = $schemaPath
        }
        if ($result.ExitCode -ne 0) {
            throw "Generator failed: $($result.Output)"
        }
        $path = Track-HandoffFile -TaskId $taskId
        if (-not $path) { throw "No handoff file created for $taskId" }
        $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($obj.source_specialist -ne "groomer" -or $obj.target_specialist -ne "architect") {
            throw "Unexpected transition payload in $path"
        }
        if (-not $obj.PSObject.Properties["file_affinity"]) {
            throw "Expected file_affinity for groomer payload"
        }
    }

    Invoke-Test -Name "reviewer->operator success with reviewer checks" -Script {
        $taskId = New-TestTaskId "RO"
        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "reviewer"
            Target = "operator"
            Reason = "review complete"
            PromptVersion = "reviewer_prompt-v1"
            SessionCycleId = "cycle-test"
            Artifacts = @("powershell/factory.ps1")
            ReviewerChecksPassed = @("tests_pass", "vet_pass", "acceptance_criteria_met", "scope_bounded", "no_regressions", "no_hard_mandates_violated")
            SchemaPath = $schemaPath
        }
        if ($result.ExitCode -ne 0) {
            throw "Generator failed: $($result.Output)"
        }
        $path = Track-HandoffFile -TaskId $taskId
        if (-not $path) { throw "No handoff file created for $taskId" }
        $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($obj.reviewer_checks_passed.Count -lt 6) {
            throw "Expected reviewer_checks_passed in $path"
        }
    }

    Invoke-Test -Name "researcher->groomer success with human decisions" -Script {
        $taskId = New-TestTaskId "RH"
        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "researcher"
            Target = "groomer"
            Reason = "research complete with human decisions"
            PromptVersion = "researcher_prompt-v1"
            Artifacts = @("powershell/factory.ps1")
            HumanApproved = @("alice", "bob")
            HumanDeferred = @("carol")
            HumanRejected = @("dave")
            SchemaPath = $schemaPath
        }
        if ($result.ExitCode -ne 0) { throw "Generator failed: $($result.Output)" }
        $path = Track-HandoffFile -TaskId $taskId
        if (-not $path) { throw "No handoff file created for $taskId" }
        $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($obj.source_specialist -ne "researcher" -or $obj.target_specialist -ne "groomer") { throw "Unexpected transition payload in $path" }
        if (-not $obj.human_decisions) { throw "Expected human_decisions object" }
        if ($obj.human_decisions.approved.Count -ne 2) { throw "Expected 2 approved entries" }
    }

    Invoke-Test -Name "schema failure path (researcher->groomer missing human_decisions)" -Script {
        $taskId = New-TestTaskId "FAIL"
        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "researcher"
            Target = "groomer"
            Reason = "research complete"
            PromptVersion = "researcher_prompt-v1"
            Artifacts = @("docs/operating-manual.md")
            SchemaPath = $schemaPath
        }
        if ($result.ExitCode -eq 0) {
            throw "Expected failure but generator succeeded"
        }
        if ($result.Output -notmatch "Schema validation failed") {
            throw "Expected schema validation failure message, got: $($result.Output)"
        }
    }

    Invoke-Test -Name "budget tier defaults from spec when not provided" -Script {
        $taskId = New-TestTaskId "BUDGET-DEFAULT"
        $specPath = ".crucible/backlog/chores/active/$($taskId)_Budget_Default.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $specPath) -Force | Out-Null
        @"
---
item_id: "$taskId"
type: "Chore"
status: "Ready"
target_specialist: "Architect"
priority: "P2"
created_at: "2026-04-28"
budget_tier: "low"
---
"@ | Set-Content -LiteralPath $specPath -Encoding UTF8
        $script:createdSpecFiles += $specPath

        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "groomer"
            Target = "architect"
            Reason = "budget default test"
            PromptVersion = "groomer_prompt-v16"
            Artifacts = @($specPath)
            FileAffinity = @("powershell/")
            SchemaPath = $schemaPath
        }
        if ($result.ExitCode -ne 0) {
            throw "Generator failed: $($result.Output)"
        }
        $path = Track-HandoffFile -TaskId $taskId
        if (-not $path) { throw "No handoff file created for $taskId" }
        $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($obj.budget_tier -ne "low") {
            throw "Expected budget_tier=low, got: $($obj.budget_tier)"
        }
    }

    Invoke-Test -Name "groomer->reviewer success (Pattern C stub-only pass)" -Script {
        $taskId = New-TestTaskId "GR"
        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "groomer"
            Target = "reviewer"
            Reason = "Pattern C: stub rows filed, parent task closed - no implementation work"
            PromptVersion = "groomer-sop-v1"
            Artifacts = @("powershell/factory.ps1")
            StubSpecsCreated = @("backlog/features/active/F-001_Stub.md")
            SchemaPath = $schemaPath
        }
        if ($result.ExitCode -ne 0) {
            throw "Generator failed: $($result.Output)"
        }
        $path = Track-HandoffFile -TaskId $taskId
        if (-not $path) { throw "No handoff file created for $taskId" }
        $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($obj.source_specialist -ne "groomer" -or $obj.target_specialist -ne "reviewer") {
            throw "Unexpected transition in $path"
        }
        if ($null -eq $obj.stub_specs_created -or $obj.stub_specs_created.Count -eq 0 -or $obj.stub_specs_created[0] -ne "backlog/features/active/F-001_Stub.md") {
            throw "Expected stub_specs_created to contain mock spec, got: $($obj.stub_specs_created)"
        }
        $validationResult = & "$REPO_ROOT/powershell/validate-handoff.ps1" -HandoffFile $path -SchemaPath $schemaPath 2>&1
        $validationJson = $validationResult | Where-Object { $_ -match '^\{' } | Select-Object -First 1
        if (-not $validationJson) { throw "Validator produced no JSON output" }
        $validated = $validationJson | ConvertFrom-Json
        if (-not $validated.ok) {
            throw "Validator rejected groomer->reviewer handoff: $($validated.message)"
        }
    }

    Invoke-Test -Name "groomer->reviewer rejected when stub_specs_created missing" -Script {
        $taskId = New-TestTaskId "GR-MISSING-STUB"
        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "groomer"
            Target = "reviewer"
            Reason = "should fail - stub_specs_created is required"
            PromptVersion = "groomer-sop-v1"
            Artifacts = @("powershell/factory.ps1")
            SchemaPath = $schemaPath
        }
        if ($result.ExitCode -eq 0) {
            $path = Track-HandoffFile -TaskId $taskId
            throw "Expected failure but generator succeeded - file: $path"
        }
        if ($result.Output -notmatch "Schema validation failed") {
            throw "Expected schema validation failure, got: $($result.Output)"
        }
    }

    Invoke-Test -Name "groomer->reviewer rejected when reviewer_checks_passed present" -Script {
        $taskId = New-TestTaskId "GR-INVALID"
        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "groomer"
            Target = "reviewer"
            Reason = "should fail - reviewer_checks_passed not allowed from groomer"
            PromptVersion = "groomer-sop-v1"
            Artifacts = @("powershell/factory.ps1")
            StubSpecsCreated = @("backlog/features/active/F-001_Stub.md")
            ReviewerChecksPassed = @("tests_pass", "vet_pass", "acceptance_criteria_met", "scope_bounded", "no_regressions", "no_hard_mandates_violated")
            SchemaPath = $schemaPath
        }
        if ($result.ExitCode -eq 0) {
            $path = Track-HandoffFile -TaskId $taskId
            throw "Expected failure but generator succeeded - file: $path"
        }
        if ($result.Output -notmatch "Schema validation failed") {
            throw "Expected schema validation failure, got: $($result.Output)"
        }
    }

    Invoke-Test -Name "budget tier mismatch is rejected by validator" -Script {
        $taskId = New-TestTaskId "BUDGET-MISMATCH"
        $specPath = ".crucible/backlog/chores/active/$($taskId)_Budget_Mismatch.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $specPath) -Force | Out-Null
        @"
---
item_id: "$taskId"
type: "Chore"
status: "Ready"
target_specialist: "Architect"
priority: "P2"
created_at: "2026-04-28"
budget_tier: "low"
---
"@ | Set-Content -LiteralPath $specPath -Encoding UTF8
        $script:createdSpecFiles += $specPath

        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "groomer"
            Target = "architect"
            Reason = "budget mismatch test"
            PromptVersion = "groomer_prompt-v16"
            BudgetTier = "high"
            Artifacts = @($specPath)
            FileAffinity = @("powershell/")
            SchemaPath = $schemaPath
        }
        if ($result.ExitCode -eq 0) {
            throw "Expected mismatch failure but generator succeeded"
        }
        if ($result.Output -notmatch "budget_tier_mismatch") {
            throw "Expected budget_tier_mismatch, got: $($result.Output)"
        }
    }

    Write-Host "`nALL TESTS PASSED" -ForegroundColor Green
} finally {
    Set-Location -LiteralPath $origLocation
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
    }
}
exit 0
