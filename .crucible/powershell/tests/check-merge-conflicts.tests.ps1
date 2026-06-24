$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$CHECK_SCRIPT = Join-Path $REPO_ROOT "powershell/check-merge-conflicts.ps1"

$results = @()










function Test-GitInitMainSupported {
    $versionText = git --version
    if ($versionText -notmatch '(\d+)\.(\d+)') { return $false }
    $major = [int]$matches[1]
    $minor = [int]$matches[2]
    return ($major -gt 2 -or ($major -eq 2 -and $minor -ge 28))
}

function Write-TestConfig {
    param([string]$ProjectRoot, [string]$SessionPath = ".crucible/session")
    $configDir = Join-Path $ProjectRoot ".crucible"
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    @(
        "project: MergeConflictTest",
        "paths:",
        "  backlog: .crucible/backlog",
        "  session: $SessionPath",
        "  workspaces: .crucible/.agent-workspaces",
        "  prompts: .crucible/prompts"
    ) | Set-Content -LiteralPath (Join-Path $configDir "config.yaml") -Encoding UTF8
}

function Initialize-Repo {
    param([string]$ProjectRoot, [string]$Branch = "master", [string]$SessionPath = ".crucible/session")
    New-Item -ItemType Directory -Path $ProjectRoot -Force | Out-Null
    Push-Location $ProjectRoot
    try {
        if ($Branch -eq "main") {
            git init -b main --quiet
        } else {
            git init --quiet
        }
        git config user.name "Test"
        git config user.email "test@example.com"
        git config commit.gpgSign false
        Write-TestConfig -ProjectRoot $ProjectRoot -SessionPath $SessionPath
        Set-Content -LiteralPath "README.md" -Value "# merge test" -Encoding UTF8
        Set-Content -LiteralPath "app.txt" -Value "base" -Encoding UTF8
        git add README.md app.txt .crucible/config.yaml
        git commit -m "init" --quiet
    } finally {
        Pop-Location
    }
}

function Invoke-MergeCheck {
    param([string]$ProjectRoot, [string]$TaskId)
    Push-Location $ProjectRoot
    try {
        return Invoke-ExternalCommand {
            & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CHECK_SCRIPT -TaskId $TaskId -ProjectRoot $ProjectRoot
        }
    } finally {
        Pop-Location
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-merge-conflicts-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$mainSupported = Test-GitInitMainSupported

try {
    $results += Run-Test -Name "Clean merge simulation passes" -Body {
        $projectRoot = Join-Path $tempRoot "clean"
        $taskId = "C-MERGE-CLEAN"
        Initialize-Repo -ProjectRoot $projectRoot
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "feature.txt" -Value "task change" -Encoding UTF8
            git add feature.txt
            git commit -m "task change" --quiet
            git checkout master --quiet
        } finally {
            Pop-Location
        }

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "no report" -Condition (-not (Test-Path (Join-Path $projectRoot ".crucible/session/$taskId/conflict_report.json"))) -FailureMessage "clean merge wrote a conflict report"
    }

    $results += Run-Test -Name "Merge simulation runs from different CWD using -ProjectRoot" -Body {
        $projectRoot = Join-Path $tempRoot "diff-cwd"
        $taskId = "C-MERGE-DIFF-CWD"
        Initialize-Repo -ProjectRoot $projectRoot
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "feature.txt" -Value "task change" -Encoding UTF8
            git add feature.txt
            git commit -m "task change" --quiet
            git checkout master --quiet
        } finally {
            Pop-Location
        }

        Push-Location $tempRoot
        try {
            $res = Invoke-ExternalCommand {
                & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $CHECK_SCRIPT -TaskId $taskId -ProjectRoot $projectRoot
            }
        } finally {
            Pop-Location
        }

        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
    }

    $results += Run-Test -Name "Conflict detected and report written" -Body {
        $projectRoot = Join-Path $tempRoot "conflict"
        $taskId = "C-MERGE-CONFLICT"
        Initialize-Repo -ProjectRoot $projectRoot
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "app.txt" -Value "task edit" -Encoding UTF8
            git add app.txt
            git commit -m "task edit" --quiet
            git checkout master --quiet
            Set-Content -LiteralPath "app.txt" -Value "main edit" -Encoding UTF8
            git add app.txt
            git commit -m "main edit" --quiet
        } finally {
            Pop-Location
        }

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        $reportPath = Join-Path $projectRoot ".crucible/session/$taskId/conflict_report.json"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 1) -FailureMessage "expected 1, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "report exists" -Condition (Test-Path $reportPath) -FailureMessage "report not found at $reportPath"
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
        Assert-Result -Name "report names file" -Condition ($report -match "app.txt") -FailureMessage "report did not include app.txt. Content:`n$report"
    }

    $results += Run-Test -Name "Works on main-default repo" -Body {
        if (-not $mainSupported) {
            Write-Host "SKIPPED: git init -b requires git >= 2.28" -ForegroundColor Yellow
            return
        }
        $projectRoot = Join-Path $tempRoot "main-default"
        $taskId = "C-MERGE-MAIN"
        Initialize-Repo -ProjectRoot $projectRoot -Branch "main"
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "main-feature.txt" -Value "task change" -Encoding UTF8
            git add main-feature.txt
            git commit -m "task change" --quiet
            git checkout main --quiet
        } finally {
            Pop-Location
        }

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
    }

    $results += Run-Test -Name "No-remote case does not fail pull step" -Body {
        $projectRoot = Join-Path $tempRoot "no-remote"
        $taskId = "C-MERGE-NOREMOTE"
        Initialize-Repo -ProjectRoot $projectRoot
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "local-only.txt" -Value "task change" -Encoding UTF8
            git add local-only.txt
            git commit -m "task change" --quiet
            git checkout master --quiet
        } finally {
            Pop-Location
        }

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "no origin message" -Condition ($output -match "No origin remote configured") -FailureMessage "expected explicit no-origin message. Output:`n$output"
    }

    $results += Run-Test -Name "Missing task branch returns clean exit code" -Body {
        $projectRoot = Join-Path $tempRoot "missing-branch"
        $taskId = "C-MERGE-MISSING"
        Initialize-Repo -ProjectRoot $projectRoot
        # Do NOT create the task/C-MERGE-MISSING branch

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "clean message" -Condition ($output -match "No task branch") -FailureMessage "expected no-task-branch message. Output:`n$output"
    }

    $results += Run-Test -Name "Honors configured session path" -Body {
        $projectRoot = Join-Path $tempRoot "custom-session"
        $taskId = "C-MERGE-CUSTOM"
        Initialize-Repo -ProjectRoot $projectRoot -SessionPath ".custom-session"
        Push-Location $projectRoot
        try {
            git checkout -b "task/$taskId" --quiet
            Set-Content -LiteralPath "app.txt" -Value "task edit" -Encoding UTF8
            git add app.txt
            git commit -m "task edit" --quiet
            git checkout master --quiet
            Set-Content -LiteralPath "app.txt" -Value "main edit" -Encoding UTF8
            git add app.txt
            git commit -m "main edit" --quiet
        } finally {
            Pop-Location
        }

        $res = Invoke-MergeCheck -ProjectRoot $projectRoot -TaskId $taskId
        $output = $res.Output -join "`n"
        $configuredReport = Join-Path $projectRoot ".custom-session/$taskId/conflict_report.json"
        $defaultReport = Join-Path $projectRoot ".crucible/session/$taskId/conflict_report.json"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 1) -FailureMessage "expected 1, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "configured report exists" -Condition (Test-Path $configuredReport) -FailureMessage "report not found at $configuredReport"
        Assert-Result -Name "default report absent" -Condition (-not (Test-Path $defaultReport)) -FailureMessage "report was written to default session path"
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
