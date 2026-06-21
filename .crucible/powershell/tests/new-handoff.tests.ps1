$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$realRepoRoot = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $realRepoRoot "powershell/lib/platform.ps1")
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
. (Join-Path $PSScriptRoot '_harness.ps1')

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

function Register-TaskId {
    param([string]$TaskId)
    $backlogDir = Join-Path $tempRoot ".crucible/backlog"
    if (-not (Test-Path -LiteralPath $backlogDir)) {
        New-Item -ItemType Directory -Path $backlogDir -Force | Out-Null
    }
    $backlogFile = Join-Path $backlogDir "BACKLOG.md"
    $content = ""
    if (Test-Path -LiteralPath $backlogFile) {
        $content = Get-Content -LiteralPath $backlogFile -Raw -Encoding UTF8
    }
    if ($content -notmatch [regex]::Escape($TaskId)) {
        $content += "`n- $TaskId"
        $content | Set-Content -LiteralPath $backlogFile -Encoding UTF8
    }
}

function Invoke-Generator {
    param([hashtable]$InputArgs, [switch]$NoRegister)
    if ($InputArgs.ContainsKey("TaskId") -and -not $NoRegister) {
        Register-TaskId $InputArgs.TaskId
    }
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
    Invoke-Test -Name "grooming->implementation success" -Script {
        $taskId = New-TestTaskId "GA"
        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "grooming"
            Target = "implementation"
            Reason = "groomer handoff test"
            PromptVersion = "implementation_prompt-v21"
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
        if ($obj.source_phase -ne "grooming" -or $obj.target_phase -ne "implementation") {
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
            Source = "verification"
            Target = "deployment"
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
            Source = "research"
            Target = "grooming"
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
        if ($obj.source_phase -ne "research" -or $obj.target_phase -ne "grooming") { throw "Unexpected transition payload in $path" }
        if (-not $obj.human_decisions) { throw "Expected human_decisions object" }
        if ($obj.human_decisions.approved.Count -ne 2) { throw "Expected 2 approved entries" }
    }

    Invoke-Test -Name "schema failure path (researcher->groomer missing human_decisions)" -Script {
        $taskId = New-TestTaskId "FAIL"
        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "research"
            Target = "grooming"
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
target_phase: "implementation"
priority: "P2"
created_at: "2026-04-28"
budget_tier: "low"
---
"@ | Set-Content -LiteralPath $specPath -Encoding UTF8
        $script:createdSpecFiles += $specPath

        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "grooming"
            Target = "implementation"
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

    Invoke-Test -Name "extended budget tier is accepted by generator" -Script {
        $taskId = New-TestTaskId "BUDGET-EXTENDED"
        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "grooming"
            Target = "implementation"
            Reason = "extended budget test"
            PromptVersion = "groomer_prompt-v16"
            BudgetTier = "extended"
            Artifacts = @("powershell/factory.ps1")
            FileAffinity = @("powershell/")
            SchemaPath = $schemaPath
        }
        if ($result.ExitCode -ne 0) {
            throw "Generator failed: $($result.Output)"
        }
        $path = Track-HandoffFile -TaskId $taskId
        if (-not $path) { throw "No handoff file created for $taskId" }
        $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($obj.budget_tier -ne "extended") {
            throw "Expected budget_tier=extended, got: $($obj.budget_tier)"
        }
    }

    Invoke-Test -Name "groomer->reviewer success (Pattern C stub-only pass)" -Script {
        $taskId = New-TestTaskId "GR"
        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "grooming"
            Target = "verification"
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
        if ($obj.source_phase -ne "grooming" -or $obj.target_phase -ne "verification") {
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
            Source = "grooming"
            Target = "verification"
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
            Source = "grooming"
            Target = "verification"
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
target_phase: "implementation"
priority: "P2"
created_at: "2026-04-28"
budget_tier: "low"
---
"@ | Set-Content -LiteralPath $specPath -Encoding UTF8
        $script:createdSpecFiles += $specPath

        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "grooming"
            Target = "implementation"
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

    Invoke-Test -Name "invalid budget tier is rejected without spec lookup" -Script {
        $taskId = New-TestTaskId "BUDGET-INVALID"
        $handoffPath = Join-Path $handoffDir "$taskId-20260530T120000Z.json"
        New-Item -ItemType Directory -Path (Split-Path -Parent $handoffPath) -Force | Out-Null
        [ordered]@{
            task_id = $taskId
            source_phase = "grooming"
            target_phase = "implementation"
            reason = "invalid budget test"
            generated_by = "new-handoff.ps1"
            tool_version = "1.0.0"
            handoff_retry_count = 0
            review_strike_count = 0
            rebase_count = 0
            budget_tier = "standard"
            cumulative_handoff_count = 2
            prompt_version = "groomer_prompt-v16"
            session_cycle_id = "cycle-invalid"
            artifacts = @("powershell/factory.ps1")
            file_affinity = @("powershell/")
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $handoffPath -Encoding UTF8
        $script:createdFiles += $handoffPath

        $result = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File "$REPO_ROOT/powershell/validate-handoff.ps1" -HandoffFile $handoffPath -SchemaPath $schemaPath
        }

        if ($result.ExitCode -eq 0) {
            throw "Expected invalid budget tier failure but validator passed"
        }
        if ($result.Output -notmatch "invalid_budget_tier") {
            throw "Expected invalid_budget_tier, got: $($result.Output)"
        }
        if ($result.Output -match "budget_tier_mismatch") {
            throw "Invalid tier should not depend on spec mismatch, got: $($result.Output)"
        }
    }

    Invoke-Test -Name "validate-handoff rejects hand-authored handoff lacking provenance" -Script {
        $taskId = New-TestTaskId "NO-PROVENANCE"
        $handoffPath = [System.IO.Path]::Combine($handoffDir, "$taskId-20260526T120000Z.json")
        @{
            task_id = $taskId
            source_phase = "grooming"
            target_phase = "implementation"
            reason = "hand-authored"
            handoff_retry_count = 0
            budget_tier = "low"
            cumulative_handoff_count = 1
            prompt_version = "1.0.0"
            artifacts = @("powershell/factory.ps1")
            file_affinity = @("powershell/")
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $handoffPath -Encoding UTF8
        $script:createdFiles += $handoffPath

        $result = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File "$REPO_ROOT/powershell/validate-handoff.ps1" -HandoffFile $handoffPath -SchemaPath $schemaPath
        }

        if ($result.ExitCode -eq 0) {
            throw "Expected provenance failure but validator passed"
        }
        if ($result.Output -notmatch "handoff_not_tool_generated") {
            throw "Expected handoff_not_tool_generated, got: $($result.Output)"
        }
    }

    Invoke-Test -Name "validate-handoff rejects invalid tool_version" -Script {
        $taskId = New-TestTaskId "BAD-TOOL-VERSION"
        $handoffPath = [System.IO.Path]::Combine($handoffDir, "$taskId-20260526T120000Z.json")
        @{
            task_id = $taskId
            source_phase = "grooming"
            target_phase = "implementation"
            reason = "bad version"
            generated_by = "new-handoff.ps1"
            tool_version = "2.0.0"
            handoff_retry_count = 0
            budget_tier = "low"
            cumulative_handoff_count = 1
            prompt_version = "1.0.0"
            artifacts = @("powershell/factory.ps1")
            file_affinity = @("powershell/")
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $handoffPath -Encoding UTF8
        $script:createdFiles += $handoffPath

        $result = Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File "$REPO_ROOT/powershell/validate-handoff.ps1" -HandoffFile $handoffPath -SchemaPath $schemaPath
        }

        if ($result.ExitCode -eq 0) {
            throw "Expected tool_version failure but validator passed"
        }
        if ($result.Output -notmatch "handoff_not_tool_generated") {
            throw "Expected handoff_not_tool_generated, got: $($result.Output)"
        }
    }

    Invoke-Test -Name "fails when TaskId not in BACKLOG.md" -Script {
        $taskId = New-TestTaskId "NOT-IN-BACKLOG"
        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "grooming"
            Target = "implementation"
            Reason = "should fail because not in backlog"
            SchemaPath = $schemaPath
        } -NoRegister
        if ($result.ExitCode -eq 0) {
            throw "Expected failure for task not in backlog, but succeeded"
        }
        if ($result.Output -notmatch "not found in the bundle") {
            throw "Expected backlog search failure message, got: $($result.Output)"
        }
    }

    Invoke-Test -Name "fails when ProjectRoot is omitted and CWD has no backlog" -Script {
        $taskId = New-TestTaskId "CWD-FAIL"
        
        # Temporarily switch to a completely fresh directory without backlog/config
        $emptyTempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $emptyTempDir -Force | Out-Null
        $origLoc = Get-Location
        Set-Location -LiteralPath $emptyTempDir
        
        try {
            $result = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $generator `
                    -TaskId $taskId `
                    -Source "grooming" `
                    -Target "implementation" `
                    -Reason "should fail CWD fallback" `
                    -SchemaPath $schemaPath
            }
        } finally {
            Set-Location -LiteralPath $origLoc
            if (Test-Path -LiteralPath $emptyTempDir) {
                Remove-Item -Recurse -Force -LiteralPath $emptyTempDir -ErrorAction SilentlyContinue
            }
        }
        
        if ($result.ExitCode -eq 0) {
            throw "Expected failure when ProjectRoot omitted and CWD has no backlog, but succeeded. Output: $($result.Output)"
        }
        if ($result.Output -notmatch "not a valid Crucible project") {
            throw "Expected CWD validation failure message, got: $($result.Output)"
        }
    }

    Invoke-Test -Name "file affinity falls back to spec frontmatter when not provided" -Script {
        $taskId = New-TestTaskId "AFFINITY-SPEC"
        $specPath = ".crucible/backlog/chores/active/$($taskId)_Spec_Affinity.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $specPath) -Force | Out-Null
        @"
---
item_id: "$taskId"
type: "Chore"
status: "Ready"
target_phase: "implementation"
priority: "P2"
created_at: "2026-04-28"
file_affinity: ["internal/cron/", "internal/config/"]
budget_tier: "low"
---
"@ | Set-Content -LiteralPath $specPath -Encoding UTF8
        $script:createdSpecFiles += $specPath

        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "grooming"
            Target = "implementation"
            Reason = "affinity spec fallback test"
            PromptVersion = "groomer_prompt-v16"
            Artifacts = @($specPath)
            SchemaPath = $schemaPath
        }
        if ($result.ExitCode -ne 0) {
            throw "Generator failed: $($result.Output)"
        }
        $path = Track-HandoffFile -TaskId $taskId
        if (-not $path) { throw "No handoff file created for $taskId" }
        $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($obj.file_affinity.Count -ne 2 -or $obj.file_affinity[0] -ne "internal/cron/" -or $obj.file_affinity[1] -ne "internal/config/") {
            throw "Expected file_affinity from spec YAML frontmatter, got: $($obj.file_affinity | Out-String)"
        }
    }

    Invoke-Test -Name "file affinity falls back to spec frontmatter block list when not provided" -Script {
        $taskId = New-TestTaskId "AFFINITY-SPEC-BLOCK"
        $specPath = ".crucible/backlog/chores/active/$($taskId)_Spec_Affinity_Block.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $specPath) -Force | Out-Null
        @"
---
item_id: "$taskId"
type: "Chore"
status: "Ready"
target_phase: "implementation"
priority: "P2"
created_at: "2026-04-28"
file_affinity:
  - internal/cron/
  - internal/config/
budget_tier: "low"
---
"@ | Set-Content -LiteralPath $specPath -Encoding UTF8
        $script:createdSpecFiles += $specPath

        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "grooming"
            Target = "implementation"
            Reason = "affinity spec block fallback test"
            PromptVersion = "groomer_prompt-v16"
            Artifacts = @($specPath)
            SchemaPath = $schemaPath
        }
        if ($result.ExitCode -ne 0) {
            throw "Generator failed: $($result.Output)"
        }
        $path = Track-HandoffFile -TaskId $taskId
        if (-not $path) { throw "No handoff file created for $taskId" }
        $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($obj.file_affinity.Count -ne 2 -or $obj.file_affinity[0] -ne "internal/cron/" -or $obj.file_affinity[1] -ne "internal/config/") {
            throw "Expected file_affinity block list from spec YAML frontmatter, got: $($obj.file_affinity | Out-String)"
        }
    }

    Invoke-Test -Name "file affinity falls back to spec frontmatter when prior handoff has empty affinity" -Script {
        $taskId = New-TestTaskId "AFFINITY-EMPTY-PRIOR"
        $specPath = ".crucible/backlog/chores/active/$($taskId)_Spec_Affinity.md"
        New-Item -ItemType Directory -Path (Split-Path -Parent $specPath) -Force | Out-Null
        @"
---
item_id: "$taskId"
type: "Chore"
status: "Ready"
target_phase: "implementation"
priority: "P2"
created_at: "2026-04-28"
file_affinity: ["internal/cron/", "internal/config/"]
budget_tier: "low"
---
"@ | Set-Content -LiteralPath $specPath -Encoding UTF8
        $script:createdSpecFiles += $specPath

        $handoffPath = Join-Path $handoffDir "$taskId-20260530T120000Z.json"
        New-Item -ItemType Directory -Path (Split-Path -Parent $handoffPath) -Force | Out-Null
        [ordered]@{
            task_id = $taskId
            source_phase = "grooming"
            target_phase = "implementation"
            reason = "prior handoff"
            generated_by = "new-handoff.ps1"
            tool_version = "1.0.0"
            handoff_retry_count = 0
            review_strike_count = 0
            rebase_count = 0
            budget_tier = "low"
            cumulative_handoff_count = 1
            prompt_version = "groomer_prompt-v16"
            session_cycle_id = "cycle-1"
            artifacts = @("powershell/factory.ps1")
            file_affinity = @()
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $handoffPath -Encoding UTF8
        $script:createdFiles += $handoffPath

        $result = Invoke-Generator -InputArgs @{
            TaskId = $taskId
            Source = "implementation"
            Target = "verification"
            Reason = "empty prior fallback test"
            PromptVersion = "impl_prompt-v1"
            Artifacts = @("powershell/factory.ps1")
            SchemaPath = $schemaPath
        }
        if ($result.ExitCode -ne 0) {
            throw "Generator failed: $($result.Output)"
        }
        $path = Track-HandoffFile -TaskId $taskId
        if (-not $path) { throw "No handoff file created for $taskId" }
        $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($obj.file_affinity.Count -ne 2 -or $obj.file_affinity[0] -ne "internal/cron/" -or $obj.file_affinity[1] -ne "internal/config/") {
            throw "Expected file_affinity to fall back to spec frontmatter, got: $($obj.file_affinity | Out-String)"
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
