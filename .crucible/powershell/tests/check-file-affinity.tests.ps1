# Smoke tests for powershell/check-file-affinity.ps1.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$SCRIPT = Join-Path $REPO_ROOT "powershell/check-file-affinity.ps1"
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
        Write-Host $_.Exception.Message -ForegroundColor Red
        return $false
    }
}

# Create a temporary environment
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-affinity-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $projectRoot = Join-Path $tempRoot "app"
    $sessionGlobalDir = Join-Path $projectRoot ".crucible/session/global"
    New-Item -ItemType Directory -Path $sessionGlobalDir -Force | Out-Null
    $stateFilePath = Join-Path $sessionGlobalDir "session_state.json"

    $mockState = @{
        tasks = @{
            "TASK-1" = @{
                phases = @{
                    deployment = @{
                        status = "In Progress"
                        phase  = "Development"
                    }
                    grooming = @{
                        file_affinity = @("src/main.go", "internal/utils/")
                    }
                }
            }
            "TASK-2" = @{
                phases = @{
                    deployment = @{
                        status = "Complete"
                        phase  = "Production"
                    }
                    implementation = @{
                        file_affinity = @("src/db/")
                    }
                }
            }
            "TASK-3" = @{
                phases = @{
                    deployment = @{
                        status = "In Progress"
                        phase  = "Testing"
                    }
                    implementation = @{
                        file_affinity = @("config/*.yaml")
                    }
                }
            }
        }
    }
    $mockState | ConvertTo-Json -Depth 100 | Out-File -LiteralPath $stateFilePath -Encoding UTF8

    $results += Run-Test -Name "Exits 0 when state file does not exist" -Body {
        $nonExistentRoot = Join-Path $tempRoot "empty-app"
        New-Item -ItemType Directory -Path $nonExistentRoot -Force | Out-Null
        Push-Location $nonExistentRoot
        try {
            $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
                -TaskId "TASK-4" `
                -Affinity @("src/main.go") 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "no-state exit" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit 0, got " + $exitCode + ". Output: " + $output)
    }

    $results += Run-Test -Name "Detects overlap with active groomer task" -Body {
        Push-Location $projectRoot
        try {
            $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
                -TaskId "TASK-4" `
                -Affinity @("src/main.go") 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "groomer conflict exit" -Condition ($exitCode -eq 1) -FailureMessage ("expected exit 1, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "groomer conflict message" -Condition ($output -match "CONFLICT: src/main.go overlaps with active task TASK-1") -FailureMessage ("missing conflict message. Output: " + $output)
    }

    $results += Run-Test -Name "Ignores overlaps with completed tasks" -Body {
        Push-Location $projectRoot
        try {
            $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
                -TaskId "TASK-4" `
                -Affinity @("src/db/query.go") 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "completed task exit" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit 0, got " + $exitCode + ". Output: " + $output)
    }

    $results += Run-Test -Name "Detects prefix overlap with glob pattern" -Body {
        Push-Location $projectRoot
        try {
            $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
                -TaskId "TASK-4" `
                -Affinity @("config/app.yaml") 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "glob prefix conflict exit" -Condition ($exitCode -eq 1) -FailureMessage ("expected exit 1, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "glob prefix conflict message" -Condition ($output -match "CONFLICT: config/app.yaml overlaps with active task TASK-3") -FailureMessage ("missing conflict message. Output: " + $output)
    }

    $results += Run-Test -Name "Succeeds when there is no overlap" -Body {
        Push-Location $projectRoot
        try {
            $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
                -TaskId "TASK-4" `
                -Affinity @("src/auth/") 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "no overlap exit" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit 0, got " + $exitCode + ". Output: " + $output)
    }

    $results += Run-Test -Name "Ignores current task's own affinity list" -Body {
        Push-Location $projectRoot
        try {
            # TASK-1 checking its own affinity list (src/main.go)
            $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
                -TaskId "TASK-1" `
                -Affinity @("src/main.go") 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "own task exit" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit 0, got " + $exitCode + ". Output: " + $output)
    }

    $results += Run-Test -Name "Handles empty and missing tasks state shapes" -Body {
        Push-Location $projectRoot
        try {
            '{}' | Set-Content -LiteralPath $stateFilePath -Encoding UTF8
            $missingOutputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
                -TaskId "TASK-4" `
                -Affinity @("src/main.go") 2>&1)
            $missingExitCode = $LASTEXITCODE

            '{"tasks":{}}' | Set-Content -LiteralPath $stateFilePath -Encoding UTF8
            $emptyOutputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
                -TaskId "TASK-4" `
                -Affinity @("src/main.go") 2>&1)
            $emptyExitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $missingOutput = $missingOutputLines -join "`n"
        $emptyOutput = $emptyOutputLines -join "`n"
        Assert-Result -Name "missing tasks exit" -Condition ($missingExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $missingExitCode + ". Output: " + $missingOutput)
        Assert-Result -Name "empty tasks exit" -Condition ($emptyExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $emptyExitCode + ". Output: " + $emptyOutput)
    }
}
finally {
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
