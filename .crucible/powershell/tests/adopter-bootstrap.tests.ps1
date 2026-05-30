# End-to-end integration tests for the Crucible adopter path bootstrap.
# Verifies that a new project can adopt Crucible, write a backlog item, validate it,
# create a new handoff, and boot the factory for the first time.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$INIT_SCRIPT = Join-Path $REPO_ROOT "powershell/init-project.ps1"
$VALIDATE_BACKLOG = Join-Path $REPO_ROOT "powershell/validate-backlog.ps1"
$VALIDATE_CONFIG = Join-Path $REPO_ROOT "powershell/validate-config.ps1"
$FACTORY_SCRIPT = Join-Path $REPO_ROOT "powershell/factory.ps1"
$NEWHANDOFF_SCRIPT = Join-Path $REPO_ROOT "powershell/new-handoff.ps1"
$FACTORY_LINT = Join-Path $REPO_ROOT "scripts/factory_lint.go"

$results = @()

function Assert-Result {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$FailureMessage
    )
    if (-not $Condition) {
        throw ("FAILED: " + $Name + " - " + $FailureMessage)
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$Command
    )
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

function Run-Test {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    Write-Host ("`nTest: " + $Name) -ForegroundColor Cyan
    try {
        & $Body
        Write-Host "PASSED" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "EXCEPTION OCCURRED: $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        return $false
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-adopter-bootstrap-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $projectRoot = Join-Path $tempRoot "bootstrap-app"

    $results += Run-Test -Name "Runs end-to-end adopter bootstrap pipeline" -Body {
        # 1. Initialize project
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        Push-Location $projectRoot
        try {
            git init --quiet
            git config user.name "Test User"
            git config user.email "test@example.com"
            Set-Content -Path "README.md" -Value "# Bootstrap App"
            git add README.md
            git commit -m "initial commit" --quiet
        } finally {
            Pop-Location
        }

        $initCmd = Invoke-ExternalCommand {
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File $INIT_SCRIPT `
                -ProjectRoot $projectRoot `
                -ProjectName "Bootstrap App" `
                -Quiet
        }
        Assert-Result -Name "init-project exit" -Condition ($initCmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $initCmd.ExitCode + ". Output: " + ($initCmd.Output -join "`n"))

        # 2. Configure verification commands (to avoid validation failures)
        $configPath = Join-Path $projectRoot ".crucible/config.yaml"
        $configContent = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $configContent = $configContent.Replace("replace-with-project-quick-test-command", "echo 'quick test pass'")
        $configContent = $configContent.Replace("replace-with-project-full-test-command", "echo 'full test pass'")
        $configContent = $configContent.Replace("Replace with project-specific engineering rules.", "Rules updated.")
        $configContent | Out-File -LiteralPath $configPath -Encoding UTF8

        # 3. Create a backlog item with unquoted YAML frontmatter (testing G!)
        $specPath = Join-Path $projectRoot ".crucible/backlog/features/active/F-001_Add_Health.md"
        $specContent = @"
---
item_id: F-001
title: Add Health Endpoint
status: Ready
priority: P1
target_phase: grooming
budget_tier: low
---

## Summary
Add a health endpoint.
"@
        Set-Content -LiteralPath $specPath -Value $specContent -Encoding UTF8

        # 4. Add the entry to BACKLOG.md
        $backlogFile = Join-Path $projectRoot ".crucible/backlog/BACKLOG.md"
        $backlogLines = Get-Content -LiteralPath $backlogFile
        $newBacklogLines = @()
        foreach ($line in $backlogLines) {
            $newBacklogLines += $line
            if ($line -match '^\s*\|\s*ID\s*\|') {
                $newBacklogLines += "| [F-001](features/active/F-001_Add_Health.md) | P1 | Ready | Add Health Endpoint | Groomer |"
            }
        }
        $newBacklogLines | Set-Content -LiteralPath $backlogFile -Encoding UTF8

        # 5. Validate Backlog (runs with -FixSummary to test F!)
        Push-Location $projectRoot
        try {
            $validateCmd = Invoke-ExternalCommand {
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_BACKLOG `
                    -BacklogPath ".crucible/backlog/BACKLOG.md" -FixSummary
            }
        } finally {
            Pop-Location
        }
        Assert-Result -Name "validate-backlog exit" -Condition ($validateCmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $validateCmd.ExitCode + ". Output: " + ($validateCmd.Output -join "`n"))

        # Run the same pre-commit lint used by adopters. It requires active backlog item
        # filenames to appear in BACKLOG.md, so Active Items must use markdown links.
        Push-Location $projectRoot
        try {
            $factoryLintCmd = Invoke-ExternalCommand {
                go run $FACTORY_LINT $REPO_ROOT
            }
        } finally {
            Pop-Location
        }
        Assert-Result -Name "factory_lint exit" -Condition ($factoryLintCmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $factoryLintCmd.ExitCode + ". Output: " + ($factoryLintCmd.Output -join "`n"))

        # Check that BACKLOG.md priority summary counts were updated
        $updatedBacklog = Get-Content -LiteralPath $backlogFile -Raw
        if ($updatedBacklog -notmatch '\|\s*\*\*P1\*\*\s*\|\s*1\s*\|') {
            Write-Host "Updated BACKLOG.md content:" -ForegroundColor Yellow
            Write-Host $updatedBacklog -ForegroundColor Yellow
            Assert-Result -Name "P1 count updated in BACKLOG.md" -Condition ($false) -FailureMessage "expected P1 count to be updated to 1"
        }

        # 6. Verify config validation passes
        $validateConfigCmd = Invoke-ExternalCommand {
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_CONFIG `
                -ConfigPath $configPath
        }
        Assert-Result -Name "validate-config exit" -Condition ($validateConfigCmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $validateConfigCmd.ExitCode + ". Output: " + ($validateConfigCmd.Output -join "`n"))

        # 7. Create a new handoff (groomer -> architect) using factory -NewHandoff (testing C!)
        Push-Location $projectRoot
        try {
            $newHandoffCmd = Invoke-ExternalCommand {
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT `
                    -NewHandoff `
                    -TaskId "F-001" `
                    -HandoffSource "grooming" `
                    -HandoffTarget "implementation" `
                    -HandoffReason "Bootstrap tests" `
                    -HandoffArtifacts ".crucible/backlog/features/active/F-001_Add_Health.md" `
                    -HandoffFileAffinity "README.md"
            }
        } finally {
            Pop-Location
        }
        Assert-Result -Name "new-handoff exit" -Condition ($newHandoffCmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $newHandoffCmd.ExitCode + ". Output: " + ($newHandoffCmd.Output -join "`n"))

        # Verify handoff file exists and artifacts/file_affinity are correctly formatted arrays (testing C!)
        $handoffDir = Join-Path $projectRoot ".crucible/session/handoffs"
        $handoffFiles = @(Get-ChildItem -Path $handoffDir -Filter "F-001-*.json")
        Assert-Result -Name "Handoff file created" -Condition ($handoffFiles.Count -eq 1) -FailureMessage "expected 1 handoff file"
        
        $handoffJson = Get-Content -LiteralPath $handoffFiles[0].FullName -Raw | ConvertFrom-Json
        Assert-Result -Name "handoff artifacts is array" -Condition ($handoffJson.artifacts.GetType().BaseType.Name -eq "Array" -or $handoffJson.artifacts -is [System.Array]) -FailureMessage ("expected artifacts to be Array, got " + $handoffJson.artifacts.GetType().Name)
        Assert-Result -Name "handoff file_affinity is array" -Condition ($handoffJson.file_affinity.GetType().BaseType.Name -eq "Array" -or $handoffJson.file_affinity -is [System.Array]) -FailureMessage ("expected file_affinity to be Array, got " + $handoffJson.file_affinity.GetType().Name)

        # 8. Run factory -Init on the task (testing D & E & H!)
        Push-Location $projectRoot
        try {
            $factoryInitCmd = Invoke-ExternalCommand {
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FACTORY_SCRIPT `
                    -Init -TaskId "F-001"
            }
        } finally {
            Pop-Location
        }
        Assert-Result -Name "factory -Init exit" -Condition ($factoryInitCmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $factoryInitCmd.ExitCode + ". Output: " + ($factoryInitCmd.Output -join "`n"))

        # Verify prompt and task folders scaffolded
        $architectPrompt = Join-Path $projectRoot ".crucible/session/F-001/implementation/prompt.md"
        $architectTask = Join-Path $projectRoot ".crucible/session/F-001/implementation/task.md"
        Assert-Result -Name "Architect prompt scaffolded" -Condition (Test-Path -LiteralPath $architectPrompt) -FailureMessage "expected implementation/prompt.md to exist"
        Assert-Result -Name "Architect task scaffolded" -Condition (Test-Path -LiteralPath $architectTask) -FailureMessage "expected implementation/task.md to exist"

        # 9. Verify hooksPath is set and hooks work for adopter (testing TODO #31)
        Push-Location $projectRoot
        try {
            $hooksPathConfig = (git config core.hooksPath).Trim()
            Assert-Result -Name "core.hooksPath config is set" -Condition ($hooksPathConfig -eq ".crucible/scripts/hooks") -FailureMessage "expected core.hooksPath config to be '.crucible/scripts/hooks'"

            # Verify that a commit runs the hooks and passes
            $testCommitFile = "test-hook-file.md"
            Set-Content -Path $testCommitFile -Value "# Test Commit File" -Encoding UTF8
            git add $testCommitFile
            $commitCmd = Invoke-ExternalCommand {
                git commit -m "Testing adopter pre-commit hook"
            }
            Assert-Result -Name "adopter commit with hook passes" -Condition ($commitCmd.ExitCode -eq 0) -FailureMessage ("expected commit exit 0, got " + $commitCmd.ExitCode + ". Output: " + ($commitCmd.Output -join "`n"))

            # Create a file with mojibake markers and verify the pre-commit hook catches it
            $mojibakeFile = "mojibake-test.md"
            $mojibakeMarker = [string]([char]0x00C3)
            Set-Content -Path $mojibakeFile -Value "# Mojibake $mojibakeMarker test" -Encoding UTF8
            git add $mojibakeFile
            $commitMojiCmd = Invoke-ExternalCommand {
                git commit -m "Testing adopter pre-commit hook mojibake failure"
            }
            Assert-Result -Name "adopter commit with mojibake hook fails" -Condition ($commitMojiCmd.ExitCode -ne 0) -FailureMessage "expected commit to fail due to mojibake markers, but it succeeded"
            Assert-Result -Name "mojibake failure output contains marker info" -Condition (($commitMojiCmd.Output -join "`n") -match "Mojibake markers detected") -FailureMessage ("expected output to indicate mojibake detection, got: " + ($commitMojiCmd.Output -join "`n"))

            # Clean up the staged/committed mojibake file to leave the test repo clean
            git reset HEAD $mojibakeFile | Out-Null
            if (Test-Path $mojibakeFile) {
                Remove-Item -Path $mojibakeFile -Force | Out-Null
            }
        } finally {
            Pop-Location
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
