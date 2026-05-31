$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$HEALTH_SCRIPT = Join-Path $REPO_ROOT "powershell/factory-health.ps1"

$results = @()

function Assert-Result {
    param([string]$Name, [bool]$Condition, [string]$FailureMessage)
    if (-not $Condition) { throw ("FAILED: " + $Name + " - " + $FailureMessage) }
}

function Run-Test {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ("`nTest: " + $Name) -ForegroundColor Cyan
    try {
        & $Body
        Write-Host "PASSED" -ForegroundColor Green
        return $true
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        return $false
    }
}

function Invoke-ExternalCommand {
    param([Parameter(Mandatory=$true)][scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Command 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [PSCustomObject]@{ Output = $output; ExitCode = $exitCode }
}

function Write-HealthFixture {
    param([string]$ProjectRoot)
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot ".crucible/session/global/gate_decisions") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot ".crucible/backlog") -Force | Out-Null

    Push-Location $ProjectRoot
    try {
        git init -q
        git config user.name "Test User"
        git config user.email "test@example.com"
    } finally {
        Pop-Location
    }

    @(
        "project: FactoryHealthTest",
        "paths:",
        "  backlog: .crucible/backlog",
        "  session: .crucible/session",
        "  workspaces: .crucible/.agent-workspaces",
        "  prompts: .crucible/prompts"
    ) | Set-Content -LiteralPath (Join-Path $ProjectRoot ".crucible/config.yaml") -Encoding UTF8

    @(
        "# Backlog",
        "",
        "| ID | Title | Category | Status | Specialist | Priority |",
        "| --- | --- | --- | --- | --- | --- |",
        "| F-001 | [Synthetic Task 1](features/active/F-001.md) | Feature | In Progress | architect | P1 |",
        "| F-002 | [Synthetic Task 2](features/active/F-002.md) | Feature | Resolved | architect | P1 |"
    ) | Set-Content -LiteralPath (Join-Path $ProjectRoot ".crucible/backlog/BACKLOG.md") -Encoding UTF8
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-factory-health-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$projectRoot = Join-Path $tempRoot "project"

try {
    Write-HealthFixture -ProjectRoot $projectRoot

    # Create pending gate file for F-001 (active status: In Progress) -> Should NOT be cleaned up
    $pendingF1 = Join-Path $projectRoot ".crucible/session/global/gate_decisions/gate_decision_F-001_pending.json"
    "{}" | Set-Content -LiteralPath $pendingF1 -Encoding UTF8

    # Create pending gate file for F-002 (inactive status: Resolved) -> Should be cleaned up
    $pendingF2 = Join-Path $projectRoot ".crucible/session/global/gate_decisions/gate_decision_F-002_pending.json"
    "{}" | Set-Content -LiteralPath $pendingF2 -Encoding UTF8

    # Create pending gate file for F-003 (not in backlog) -> Should be cleaned up
    $pendingF3 = Join-Path $projectRoot ".crucible/session/global/gate_decisions/gate_decision_F-003_pending.json"
    "{}" | Set-Content -LiteralPath $pendingF3 -Encoding UTF8

    # Set up task session dirs for F-001 (active), F-002 (Resolved/inactive), F-003 (not in backlog)
    $sessionF1_arch = Join-Path $projectRoot ".crucible/session/F-001/architect"
    $sessionF1_impl = Join-Path $projectRoot ".crucible/session/F-001/implementation"
    $sessionF2_arch = Join-Path $projectRoot ".crucible/session/F-002/architect"
    $sessionF2_impl = Join-Path $projectRoot ".crucible/session/F-002/implementation"
    $sessionF3_arch = Join-Path $projectRoot ".crucible/session/F-003/architect"
    $sessionF3_impl = Join-Path $projectRoot ".crucible/session/F-003/implementation"

    New-Item -ItemType Directory -Path $sessionF1_arch -Force | Out-Null
    New-Item -ItemType Directory -Path $sessionF1_impl -Force | Out-Null
    New-Item -ItemType Directory -Path $sessionF2_arch -Force | Out-Null
    New-Item -ItemType Directory -Path $sessionF2_impl -Force | Out-Null
    New-Item -ItemType Directory -Path $sessionF3_arch -Force | Out-Null
    New-Item -ItemType Directory -Path $sessionF3_impl -Force | Out-Null

    "F-001 task content" | Set-Content -LiteralPath (Join-Path $sessionF1_arch "task.md") -Encoding UTF8
    "F-001 task content" | Set-Content -LiteralPath (Join-Path $sessionF1_impl "task.md") -Encoding UTF8
    "F-002 task content" | Set-Content -LiteralPath (Join-Path $sessionF2_arch "task.md") -Encoding UTF8
    "F-002 task content" | Set-Content -LiteralPath (Join-Path $sessionF2_impl "task.md") -Encoding UTF8
    "F-003 task content" | Set-Content -LiteralPath (Join-Path $sessionF3_arch "task.md") -Encoding UTF8
    "F-003 task content" | Set-Content -LiteralPath (Join-Path $sessionF3_impl "task.md") -Encoding UTF8

    $results += Run-Test -Name "Health identifies stale pending files and task dirs" -Body {
        Push-Location $projectRoot
        try {
            $res = Invoke-ExternalCommand {
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File $HEALTH_SCRIPT -Health -ProjectRoot $projectRoot
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "orphaned count warning" -Condition ($output -match "Orphaned Pending Gate Files: 2") -FailureMessage "expected 2 orphaned files detected. Output:`n$output"
        Assert-Result -Name "stale scratchpad count" -Condition ($output -match "Stale Session Scratchpads: 4") -FailureMessage "expected 4 stale scratchpads detected. Output:`n$output"
    }

    $results += Run-Test -Name "Cleanup removes stale pending files and task dirs in a single pass" -Body {
        Push-Location $projectRoot
        try {
            $res = Invoke-ExternalCommand {
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File $HEALTH_SCRIPT -Cleanup -Force -ProjectRoot $projectRoot
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "F-001 pending remains" -Condition (Test-Path $pendingF1) -FailureMessage "expected F-001 pending file to remain"
        Assert-Result -Name "F-001 session dir remains" -Condition (Test-Path (Join-Path $projectRoot ".crucible/session/F-001")) -FailureMessage "expected F-001 session dir to remain"
        Assert-Result -Name "F-002 pending removed" -Condition (-not (Test-Path $pendingF2)) -FailureMessage "expected F-002 pending file to be removed"
        Assert-Result -Name "F-002 session dir archived" -Condition (-not (Test-Path (Join-Path $projectRoot ".crucible/session/F-002"))) -FailureMessage "expected F-002 session dir to be archived/removed"
        Assert-Result -Name "F-003 pending removed" -Condition (-not (Test-Path $pendingF3)) -FailureMessage "expected F-003 pending file to be removed"
        Assert-Result -Name "F-003 session dir archived" -Condition (-not (Test-Path (Join-Path $projectRoot ".crucible/session/F-003"))) -FailureMessage "expected F-003 session dir to be archived/removed"
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
