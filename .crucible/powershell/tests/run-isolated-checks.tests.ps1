$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$RUN_CHECKS_SCRIPT = Join-Path $REPO_ROOT "powershell/run-isolated-checks.ps1"

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

function Initialize-Repo {
    param([string]$ProjectRoot)
    New-Item -ItemType Directory -Path $ProjectRoot -Force | Out-Null
    Push-Location $ProjectRoot
    try {
        git init --quiet
        git config user.name "Test"
        git config user.email "test@example.com"
        git config commit.gpgSign false
        New-Item -ItemType Directory -Path ".crucible" -Force | Out-Null
        @(
            "project: RunIsolatedChecksTest",
            "verification:",
            "  quick:",
            "    - name: no-op",
            "      command: cmd /c exit 0"
        ) | Set-Content -LiteralPath ".crucible/config.yaml" -Encoding UTF8
        Set-Content -LiteralPath "README.md" -Value "# run isolated checks test" -Encoding UTF8
        git add README.md .crucible/config.yaml
        git commit -m "init" --quiet
    } finally {
        Pop-Location
    }
}

function Add-ImplementationWorktree {
    param([string]$ProjectRoot, [string]$TaskId)
    $worktreePath = Join-Path $ProjectRoot ".crucible/.agent-workspaces/implementation-$TaskId"
    New-Item -ItemType Directory -Path (Split-Path -Parent $worktreePath) -Force | Out-Null
    git -C $ProjectRoot worktree add -b "task/$TaskId" $worktreePath --quiet
    return $worktreePath
}

function Remove-WorktreeIfPresent {
    param([string]$ProjectRoot, [string]$WorktreePath)
    if (Test-Path -LiteralPath $WorktreePath) {
        git -C $ProjectRoot worktree remove --force $WorktreePath 2>$null
    }
    git -C $ProjectRoot worktree prune 2>$null
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-run-isolated-checks-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$projectRoot = Join-Path $tempRoot "project"
$taskId = "T-001"
$worktreePath = Join-Path $projectRoot ".crucible/.agent-workspaces/implementation-$taskId"

try {
    Initialize-Repo -ProjectRoot $projectRoot
    Add-ImplementationWorktree -ProjectRoot $projectRoot -TaskId $taskId | Out-Null

    $results += Run-Test -Name "Executes configured quick check in worktree" -Body {
        Push-Location $projectRoot
        try {
            $res = Invoke-ExternalCommand {
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode quick
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "check name" -Condition ($output -match "==> no-op") -FailureMessage "expected configured check to run. Output:`n$output"
    }

    $results += Run-Test -Name "Executes when CWD is different using -ProjectRoot" -Body {
        Push-Location $tempRoot
        try {
            $res = Invoke-ExternalCommand {
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RUN_CHECKS_SCRIPT -TaskId $taskId -Mode quick -ProjectRoot $projectRoot
            }
        } finally {
            Pop-Location
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "check name" -Condition ($output -match "==> no-op") -FailureMessage "expected configured check to run. Output:`n$output"
    }
} finally {
    if (Test-Path -LiteralPath $projectRoot) {
        Remove-WorktreeIfPresent -ProjectRoot $projectRoot -WorktreePath $worktreePath
    }
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
