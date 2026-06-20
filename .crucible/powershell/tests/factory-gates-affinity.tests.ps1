# Tests for factory gate orchestration helpers.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$FACTORY_LIB = Join-Path $REPO_ROOT "powershell/factory-lib.ps1"
$Quiet = $true
. $FACTORY_LIB
$pwshCmd = Get-PwshCommand

$results = @()

function Write-TestHandoff {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][hashtable]$Values
    )

    if (-not $Values.ContainsKey("generated_by")) {
        $Values.generated_by = "new-handoff.ps1"
    }
    if (-not $Values.ContainsKey("tool_version")) {
        $Values.tool_version = "1.0.0"
    }

    $Values | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-TestContext {
    param(
        [Parameter(Mandatory=$true)][string]$TempRoot,
        [string]$TaskId = "F-001"
    )

    $sessionDir = Join-Path $TempRoot "session"
    $handoffDir = Join-Path $sessionDir "handoffs"
    $backlogDir = Join-Path $TempRoot "backlog"
    $frameworkDir = Join-Path $TempRoot "powershell"
    New-Item -ItemType Directory -Path $handoffDir, $backlogDir, $frameworkDir -Force | Out-Null

    return @{
        RepoRoot = $TempRoot
        CrucibleRoot = ".crucible"
        FrameworkPowerShell = $frameworkDir
        SessionDir = $sessionDir
        BacklogDir = $backlogDir
        WorkspacesDir = Join-Path $TempRoot "workspaces"
        HandoffDir = $handoffDir
        PromptLib = Join-Path $TempRoot "prompts"
        LogFile = Join-Path $sessionDir "$TaskId/pipeline.log.jsonl"
        CircuitBreakerHistoryFile = Join-Path $sessionDir "global/circuit_breakers.jsonl"
        TaskId = $TaskId
        Target = "agent"
        Init = $true
        Recover = $false
        Quiet = $true
        AutoAdvance = $false
        GateOutcome = $null
        GateRedirectTarget = $null
        GateReason = $null
        BudgetCeilings = $null
        Ceiling = $null
        BudgetTierKey = ""
        InvalidBudgetTier = ""
        Handoff = $null
        LatestHandoff = $null
        RelativeHandoffPath = $null
        CumulativeHandoffCount = 0
        IsBootstrap = $false
        Transition = $null
        NextFactoryCommand = $null
    }
}
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-factory-gates-affinity-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $results += Run-Test -Name "Invoke-HandoffPreflightValidation D19: warn when file_affinity is overbroad relative to spec" -Body {
        $caseRoot = Join-Path $tempRoot "d19-regression"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        # Initialize Git repo so that Assert-CrucibleFrameworkIntegrity does not fail
        Push-Location $caseRoot
        try {
            git init --quiet
            git config core.autocrlf false
            git config core.safecrlf false
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            Set-Content -Path "README.md" -Value "# Temp"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        # 1. Setup mock backlog dir with a spec that has "Affected Files"
        $backlogDir = Join-Path $caseRoot "backlog"
        $activeDir = Join-Path $backlogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null

        $crucibleActiveDir = Join-Path $caseRoot ".crucible/backlog/features/active"
        New-Item -ItemType Directory -Path $crucibleActiveDir -Force | Out-Null

        $specPath = Join-Path $activeDir "F-020_test.md"
        $specPath2 = Join-Path $crucibleActiveDir "F-020_test.md"
        $specContent = @"
---
item_id: "F-020"
status: "Ready"
---
## Affected Files
- ``docs/METRICS.md``
- ``AGENTS.md``
"@
        $specContent | Set-Content -LiteralPath $specPath -Encoding UTF8
        $specContent | Set-Content -LiteralPath $specPath2 -Encoding UTF8

        # 2. Setup mock validate-handoff.ps1 script
        $frameworkDir = Join-Path $caseRoot "powershell"
        New-Item -ItemType Directory -Path $frameworkDir -Force | Out-Null
        @'
param([string]$HandoffFile, [string]$SchemaPath)
Write-Output '{"ok":true}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $frameworkDir "validate-handoff.ps1") -Encoding UTF8

        # 3. Setup context with overbroad file_affinity
        $handoffDir = Join-Path $caseRoot "handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $handoffPath = Join-Path $handoffDir "F-020-20260526T120000Z.json"

        $handoffObj = @{
            task_id = "F-020"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            file_affinity = @("cmd/gobot/", "docs/")
            budget_tier = "low"
            reason = "test"
            prompt_version = "1.0.0"
        }
        $handoffObj | ConvertTo-Json -Compress | Set-Content -LiteralPath $handoffPath -Encoding UTF8

        $ctx = @{
            TaskId = "F-020"
            SessionDir = Join-Path $caseRoot "session"
            Init = $false
            Quiet = $true
            RepoRoot = $caseRoot
            BacklogDir = $backlogDir
            HandoffDir = $handoffDir
            LogFile = Join-Path $caseRoot "pipeline.log.jsonl"
            CircuitBreakerHistoryFile = Join-Path $caseRoot "circuit_breakers.jsonl"
            FrameworkPowerShell = $frameworkDir
            CrucibleRoot = "powershell"
            LatestHandoff = Get-Item $handoffPath
            Handoff = [PSCustomObject]$handoffObj
        }

        # Clear log file first
        Set-Content -LiteralPath $ctx.LogFile -Value "" -Encoding UTF8

        # Invoke validation - it should warning but not exit
        $origRepoRoot = $REPO_ROOT
        $REPO_ROOT = $caseRoot
        try {
            Invoke-HandoffPreflightValidation -Context $ctx
        } finally {
            $REPO_ROOT = $origRepoRoot
        }

        # Verify that warning degraded event is written in log file
        $logContent = Get-Content -LiteralPath $ctx.LogFile -Raw -Encoding UTF8
        Assert-Result -Name "D19 warning logged" -Condition ($logContent -match "Handoff file_affinity contains paths.*not mentioned in spec") -FailureMessage ("expected degraded warning in log, got: " + $logContent)
    }

    $results += Run-Test -Name "D19: prose and command bullets in affected files do not trigger affinity warning" -Body {
        $caseRoot = Join-Path $tempRoot "d19-prose-regression"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-021"

        Push-Location $caseRoot
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            Set-Content -Path "README.md" -Value "# Temp"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        $backlogDir = Join-Path $caseRoot ".crucible/backlog"
        $activeDir = Join-Path $backlogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        $specPath = Join-Path $activeDir "F-021_test.md"
        $specContent = @"
---
item_id: "F-021"
status: "Ready"
---
## Affected Files
- ``go mod verify``
- ``gobot doctor``
- Local-only: delete vendor
"@
        $specContent | Set-Content -LiteralPath $specPath -Encoding UTF8

        $frameworkDir = Join-Path $caseRoot "powershell"
        New-Item -ItemType Directory -Path $frameworkDir -Force | Out-Null
        @'
param([string]$HandoffFile, [string]$SchemaPath)
Write-Output '{"ok":true}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $frameworkDir "validate-handoff.ps1") -Encoding UTF8

        $handoffDir = Join-Path $caseRoot "handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $handoffPath = Join-Path $handoffDir "F-021-20260526T120000Z.json"
        $handoffObj = @{
            task_id = "F-021"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            file_affinity = @("vendor/")
            budget_tier = "low"
            reason = "test"
            prompt_version = "1.0.0"
        }
        $handoffObj | ConvertTo-Json -Compress | Set-Content -LiteralPath $handoffPath -Encoding UTF8

        $ctx.TaskId = "F-021"
        $ctx.BacklogDir = $backlogDir
        $ctx.FrameworkPowerShell = $frameworkDir
        $ctx.LatestHandoff = Get-Item $handoffPath
        $ctx.Handoff = [PSCustomObject]$handoffObj

        $origRepoRoot = $REPO_ROOT
        $REPO_ROOT = $caseRoot
        try {
            Invoke-HandoffPreflightValidation -Context $ctx
        } finally {
            $REPO_ROOT = $origRepoRoot
        }

        $logContent = ""
        if (Test-Path -LiteralPath $ctx.LogFile) {
            $logContent = Get-Content -LiteralPath $ctx.LogFile -Raw -Encoding UTF8
        }
        Assert-Result -Name "D19 prose warning not logged" -Condition ($logContent -notmatch "Handoff file_affinity contains paths") -FailureMessage ("expected no overbroad affinity warning, got: " + $logContent)
    }

    $results += Run-Test -Name "D23: warning degraded event on missing affected files/packages section in spec" -Body {
        $caseRoot = Join-Path $tempRoot "d23-test"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-044"

        # Initialize Git repo so that Assert-CrucibleFrameworkIntegrity does not fail
        Push-Location $caseRoot
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            Set-Content -Path "README.md" -Value "# Temp"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        # Setup spec file with NO affected section
        $backlogDir = Join-Path $caseRoot ".crucible/backlog"
        $activeDir = Join-Path $backlogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        $specPath = Join-Path $activeDir "F-044_test.md"
        $specContent = @"
---
item_id: "F-044"
status: "Ready"
---
## Title
No affected files list here.
"@
        $specContent | Set-Content -LiteralPath $specPath -Encoding UTF8

        # Create mock validate-handoff.ps1
        $frameworkDir = Join-Path $caseRoot "powershell"
        New-Item -ItemType Directory -Path $frameworkDir -Force | Out-Null
        @'
param([string]$HandoffFile, [string]$SchemaPath)
Write-Output '{"ok":true}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $frameworkDir "validate-handoff.ps1") -Encoding UTF8

        # Setup handoff file on disk and set LatestHandoff
        $handoffDir = Join-Path $caseRoot "handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $handoffPath = Join-Path $handoffDir "F-044-20260530T120000Z.json"

        $handoffObj = @{
            task_id = "F-044"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            file_affinity = @("cmd/")
            budget_tier = "low"
            reason = "test"
            prompt_version = "1.0.0"
        }
        $handoffObj | ConvertTo-Json -Compress | Set-Content -LiteralPath $handoffPath -Encoding UTF8

        $ctx.TaskId = "F-044"
        $ctx.BacklogDir = $backlogDir
        $ctx.FrameworkPowerShell = $frameworkDir
        $ctx.LatestHandoff = Get-Item $handoffPath
        $ctx.Handoff = [PSCustomObject]$handoffObj

        $origRepoRoot = $REPO_ROOT
        $REPO_ROOT = $caseRoot
        try {
            Invoke-HandoffPreflightValidation -Context $ctx
        } finally {
            $REPO_ROOT = $origRepoRoot
        }

        # Check log file for degraded warning event
        $logContent = Get-Content -LiteralPath $ctx.LogFile -Raw -Encoding UTF8
        Assert-Result -Name "D23 warning logged" -Condition ($logContent -match "Spec file does not declare an affected files/packages section") -FailureMessage "expected spec missing affected warning in log"
    }

    $results += Run-Test -Name "D40: spec with multiple affected sections and trailing prose containing affected" -Body {
        $caseRoot = Join-Path $tempRoot "d40-test"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-045"

        # Initialize Git repo
        Push-Location $caseRoot
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            Set-Content -Path "README.md" -Value "# Temp"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        # Setup spec file with BOTH sections and trailing prose containing "affected"
        $backlogDir = Join-Path $caseRoot ".crucible/backlog"
        $activeDir = Join-Path $backlogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        $specPath = Join-Path $activeDir "F-045_test.md"
        $specContent = @"
---
item_id: "F-045"
status: "Ready"
---
## Affected Packages
- ``pkg1``

## Affected Files
- ``cmd/gobot/main.go``

### Linter Thresholds
This is trailing prose. It mentions that some rules are affected by this.
"@
        $specContent | Set-Content -LiteralPath $specPath -Encoding UTF8

        # Create mock validate-handoff.ps1
        $frameworkDir = Join-Path $caseRoot "powershell"
        New-Item -ItemType Directory -Path $frameworkDir -Force | Out-Null
        @'
param([string]$HandoffFile, [string]$SchemaPath)
Write-Output '{"ok":true}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $frameworkDir "validate-handoff.ps1") -Encoding UTF8

        # Setup handoff file on disk and set LatestHandoff
        $handoffDir = Join-Path $caseRoot "handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $handoffPath = Join-Path $handoffDir "F-045-20260530T120000Z.json"

        $handoffObj = @{
            task_id = "F-045"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            file_affinity = @("cmd/gobot/")
            budget_tier = "low"
            reason = "test"
            prompt_version = "1.0.0"
        }
        $handoffObj | ConvertTo-Json -Compress | Set-Content -LiteralPath $handoffPath -Encoding UTF8

        $ctx.TaskId = "F-045"
        $ctx.BacklogDir = $backlogDir
        $ctx.FrameworkPowerShell = $frameworkDir
        $ctx.LatestHandoff = Get-Item $handoffPath
        $ctx.Handoff = [PSCustomObject]$handoffObj

        $origRepoRoot = $REPO_ROOT
        $REPO_ROOT = $caseRoot
        try {
            Invoke-HandoffPreflightValidation -Context $ctx
        } finally {
            $REPO_ROOT = $origRepoRoot
        }

        # Check log file: there should be NO degraded warning event saying "does not declare an affected"
        $logContent = ""
        if (Test-Path -LiteralPath $ctx.LogFile) {
            $logContent = Get-Content -LiteralPath $ctx.LogFile -Raw -Encoding UTF8
        }
        Assert-Result -Name "D40 warning NOT logged" -Condition ($logContent -notmatch "Spec file does not declare an affected files/packages section") -FailureMessage "expected spec missing affected warning NOT to be in log"
    }

    $results += Run-Test -Name "Research Read-Only Scope Check" -Body {
        $caseRoot = Join-Path $tempRoot "rh3-scope-check"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null

        $localRepo = Join-Path $caseRoot "local"
        New-Item -ItemType Directory -Path $localRepo -Force | Out-Null

        Push-Location $localRepo
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false

            # Create a tracked project file
            New-Item -ItemType Directory -Path "src" -Force | Out-Null
            Set-Content -Path "src/x.txt" -Value "initial tracked file"

            # Create a tracked backlog spec file to test disallowed backlog writes
            $backlogDir = Join-Path $localRepo ".crucible/backlog"
            New-Item -ItemType Directory -Path (Join-Path $backlogDir "features/active") -Force | Out-Null
            Set-Content -Path (Join-Path $backlogDir "features/active/R-123_Spec.md") -Value "initial backlog spec"

            # git add and commit them to track them
            git add .
            git commit -m "init commit" --quiet
        } finally {
            Pop-Location
        }

        # Setup session folders
        $sessionDir = Join-Path $localRepo ".crucible/session"
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
        $gateDir = Join-Path $sessionDir "global/gate_decisions"
        New-Item -ItemType Directory -Path $gateDir -Force | Out-Null

        # Setup standard context and handoff for the test script
        $scriptPath = Join-Path $caseRoot "run-scope-check-test.ps1"
        $libPath = $FACTORY_LIB.Replace("'", "''")
        $scriptContent = @"
`$ErrorActionPreference = "Stop"
`$Quiet = `$false
. '$libPath'

`$ctx = @{
    IsBootstrap = `$false
    SessionDir = '$sessionDir'
    CrucibleRoot = '$localRepo'
    RepoRoot = '$localRepo'
    FrameworkPowerShell = '$PSScriptRoot'
    LogFile = (Join-Path '$sessionDir' 'global/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path '$sessionDir' 'global/circuit_breakers.jsonl')
    BacklogDir = '$backlogDir'
    WorkspacesDir = (Join-Path '$localRepo' '.crucible/.agent-workspaces')
    Quiet = `$false
    Handoff = [PSCustomObject]@{
        task_id = 'R-123'
        source_phase = 'research'
        target_phase = 'grooming'
        cumulative_handoff_count = 1
        artifacts = @()
        session_cycle_id = 'cycle-123'
    }
}

Push-Location '$localRepo'
try {
    Invoke-FactoryScopeGates -Context `$ctx
} finally {
    Pop-Location
}
"@
        $scriptContent | Set-Content -LiteralPath $scriptPath -Encoding UTF8

        # --- Test case 1: Clean research handoff ---
        # No modifications made (or only ignored/allowed writes). Let's write to .crucible/research/ (which is ignored/allowed)
        $researchDir = Join-Path $localRepo ".crucible/research"
        New-Item -ItemType Directory -Path $researchDir -Force | Out-Null
        Set-Content -Path (Join-Path $researchDir "R-123_Findings.md") -Value "some research findings"

        $outputClean = (& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1) -join "`n"
        $exitCodeClean = $LASTEXITCODE

        Assert-Result -Name "Clean research: exit code is 0" -Condition ($exitCodeClean -eq 0) -FailureMessage "expected clean research gate to run with exit code 0"
        Assert-Result -Name "Clean research: no warning emitted" -Condition ($outputClean -notmatch "Research phase modified files outside the read-only boundary") -FailureMessage ("expected no warning for clean research, got: " + $outputClean)

        # --- Test case 2: Research handoff with modified tracked file ---
        # Modify the tracked project file src/x.txt
        Set-Content -Path (Join-Path $localRepo "src/x.txt") -Value "modified tracked file"

        $outputModified = (& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1) -join "`n"
        $exitCodeModified = $LASTEXITCODE

        Assert-Result -Name "Modified research: exit code is 0" -Condition ($exitCodeModified -eq 0) -FailureMessage "expected modified research gate to run with exit code 0 (WARN-only)"
        Assert-Result -Name "Modified research: warning emitted" -Condition ($outputModified -match "Research phase modified files outside the read-only boundary") -FailureMessage ("expected warning for modified tracked file, got: " + $outputModified)
        Assert-Result -Name "Modified research: lists modified file" -Condition ($outputModified -match "src/x.txt") -FailureMessage ("expected warning to list modified file, got: " + $outputModified)

        # Revert change to src/x.txt so it doesn't affect the next sub-test
        Push-Location $localRepo
        try {
            git checkout -- src/x.txt
        } finally {
            Pop-Location
        }

        # --- Test case 3: Research handoff with modified backlog file ---
        # Modify the tracked backlog spec
        Set-Content -Path (Join-Path $backlogDir "features/active/R-123_Spec.md") -Value "modified backlog spec"

        $outputBacklog = (& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1) -join "`n"
        $exitCodeBacklog = $LASTEXITCODE

        Assert-Result -Name "Backlog modified: exit code is 0" -Condition ($exitCodeBacklog -eq 0) -FailureMessage "expected backlog modified research gate to run with exit code 0 (WARN-only)"
        Assert-Result -Name "Backlog modified: warning emitted" -Condition ($outputBacklog -match "Research phase modified files outside the read-only boundary") -FailureMessage ("expected warning for modified backlog file, got: " + $outputBacklog)
        Assert-Result -Name "Backlog modified: lists backlog file" -Condition ($outputBacklog -match "\.crucible/backlog/features/active/R-123_Spec\.md") -FailureMessage ("expected warning to list backlog file, got: " + $outputBacklog)
    }

    # D23: Frontmatter fallback test cases
    $results += Run-Test -Name "D23: Spec with NO prose affected section but frontmatter matches handoff" -Body {
        $caseRoot = Join-Path $tempRoot "d23-fallback-clean"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-046"

        Push-Location $caseRoot
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            Set-Content -Path "README.md" -Value "# Temp"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        $backlogDir = Join-Path $caseRoot ".crucible/backlog"
        $activeDir = Join-Path $backlogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        $specPath = Join-Path $activeDir "F-046_test.md"
        $specContent = @'
---
item_id: "F-046"
status: "Ready"
file_affinity:
  - cmd/
---
## Title
No affected prose heading here.
'@
        $specContent | Set-Content -LiteralPath $specPath -Encoding UTF8

        $frameworkDir = Join-Path $caseRoot "powershell"
        New-Item -ItemType Directory -Path $frameworkDir -Force | Out-Null
        @'
param([string]$HandoffFile, [string]$SchemaPath)
Write-Output '{"ok":true}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $frameworkDir "validate-handoff.ps1") -Encoding UTF8

        $handoffDir = Join-Path $caseRoot "handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $handoffPath = Join-Path $handoffDir "F-046-20260530T120000Z.json"
        $handoffObj = @{
            task_id = "F-046"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            file_affinity = @("cmd/")
            budget_tier = "low"
            reason = "test"
            prompt_version = "1.0.0"
        }
        $handoffObj | ConvertTo-Json -Compress | Set-Content -LiteralPath $handoffPath -Encoding UTF8

        $ctx.TaskId = "F-046"
        $ctx.BacklogDir = $backlogDir
        $ctx.FrameworkPowerShell = $frameworkDir
        $ctx.LatestHandoff = Get-Item $handoffPath
        $ctx.Handoff = [PSCustomObject]$handoffObj

        $origRepoRoot = $REPO_ROOT
        $REPO_ROOT = $caseRoot
        try {
            Invoke-HandoffPreflightValidation -Context $ctx
        } finally {
            $REPO_ROOT = $origRepoRoot
        }

        $logContent = ""
        if (Test-Path -LiteralPath $ctx.LogFile) {
            $logContent = Get-Content -LiteralPath $ctx.LogFile -Raw -Encoding UTF8
        }
        Assert-Result -Name "D23 fallback: clean validation" -Condition ($logContent -notmatch "degraded" -and $logContent -notmatch "cannot be validated") -FailureMessage "expected clean validation from frontmatter, got log: $logContent"
    }

    $results += Run-Test -Name "D23: Spec with Scope only + frontmatter, handoff overbroad vs frontmatter" -Body {
        $caseRoot = Join-Path $tempRoot "d23-fallback-overbroad"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-047"

        Push-Location $caseRoot
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            Set-Content -Path "README.md" -Value "# Temp"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        $backlogDir = Join-Path $caseRoot ".crucible/backlog"
        $activeDir = Join-Path $backlogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        $specPath = Join-Path $activeDir "F-047_test.md"
        $specContent = @'
---
item_id: "F-047"
status: "Ready"
file_affinity:
  - cmd/
---
## Scope
Only `cmd/` is allowed.
'@
        $specContent | Set-Content -LiteralPath $specPath -Encoding UTF8

        $frameworkDir = Join-Path $caseRoot "powershell"
        New-Item -ItemType Directory -Path $frameworkDir -Force | Out-Null
        @'
param([string]$HandoffFile, [string]$SchemaPath)
Write-Output '{"ok":true}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $frameworkDir "validate-handoff.ps1") -Encoding UTF8

        $handoffDir = Join-Path $caseRoot "handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $handoffPath = Join-Path $handoffDir "F-047-20260530T120000Z.json"
        $handoffObj = @{
            task_id = "F-047"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            file_affinity = @("cmd/", "src/")
            budget_tier = "low"
            reason = "test"
            prompt_version = "1.0.0"
        }
        $handoffObj | ConvertTo-Json -Compress | Set-Content -LiteralPath $handoffPath -Encoding UTF8

        $ctx.TaskId = "F-047"
        $ctx.BacklogDir = $backlogDir
        $ctx.FrameworkPowerShell = $frameworkDir
        $ctx.LatestHandoff = Get-Item $handoffPath
        $ctx.Handoff = [PSCustomObject]$handoffObj

        $origRepoRoot = $REPO_ROOT
        $REPO_ROOT = $caseRoot
        try {
            Invoke-HandoffPreflightValidation -Context $ctx
        } finally {
            $REPO_ROOT = $origRepoRoot
        }

        $logContent = Get-Content -LiteralPath $ctx.LogFile -Raw -Encoding UTF8
        Assert-Result -Name "D23 fallback: overbroad detected" -Condition ($logContent -match "degraded" -and $logContent -match "Handoff file_affinity contains paths") -FailureMessage "expected overbroad validation warning in log: $logContent"
    }

    $results += Run-Test -Name "D23: Spec with neither prose section nor frontmatter" -Body {
        $caseRoot = Join-Path $tempRoot "d23-fallback-absent"
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $ctx = New-TestContext -TempRoot $caseRoot -TaskId "F-048"

        Push-Location $caseRoot
        try {
            git init --quiet
            git config user.name "Test"
            git config user.email "test@example.com"
            git config commit.gpgSign false
            Set-Content -Path "README.md" -Value "# Temp"
            git add README.md
            git commit -m "init" --quiet
        } finally {
            Pop-Location
        }

        $backlogDir = Join-Path $caseRoot ".crucible/backlog"
        $activeDir = Join-Path $backlogDir "features/active"
        New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
        $specPath = Join-Path $activeDir "F-048_test.md"
        $specContent = @'
---
item_id: "F-048"
status: "Ready"
---
## Title
Neither prose section nor frontmatter file_affinity.
'@
        $specContent | Set-Content -LiteralPath $specPath -Encoding UTF8

        $frameworkDir = Join-Path $caseRoot "powershell"
        New-Item -ItemType Directory -Path $frameworkDir -Force | Out-Null
        @'
param([string]$HandoffFile, [string]$SchemaPath)
Write-Output '{"ok":true}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $frameworkDir "validate-handoff.ps1") -Encoding UTF8

        $handoffDir = Join-Path $caseRoot "handoffs"
        New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null
        $handoffPath = Join-Path $handoffDir "F-048-20260530T120000Z.json"
        $handoffObj = @{
            task_id = "F-048"
            source_phase = "grooming"
            target_phase = "implementation"
            cumulative_handoff_count = 1
            file_affinity = @("cmd/")
            budget_tier = "low"
            reason = "test"
            prompt_version = "1.0.0"
        }
        $handoffObj | ConvertTo-Json -Compress | Set-Content -LiteralPath $handoffPath -Encoding UTF8

        $ctx.TaskId = "F-048"
        $ctx.BacklogDir = $backlogDir
        $ctx.FrameworkPowerShell = $frameworkDir
        $ctx.LatestHandoff = Get-Item $handoffPath
        $ctx.Handoff = [PSCustomObject]$handoffObj

        $origRepoRoot = $REPO_ROOT
        $REPO_ROOT = $caseRoot
        try {
            Invoke-HandoffPreflightValidation -Context $ctx
        } finally {
            $REPO_ROOT = $origRepoRoot
        }

        $logContent = Get-Content -LiteralPath $ctx.LogFile -Raw -Encoding UTF8
        Assert-Result -Name "D23 fallback: absent warning logged" -Condition ($logContent -match "Spec file does not declare an affected files/packages section") -FailureMessage "expected absent warning in log, got: $logContent"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed factory gate test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll factory gate tests passed." -ForegroundColor Green
exit 0
