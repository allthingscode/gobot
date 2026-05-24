# Smoke tests for powershell/validate-config.ps1.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$INIT_SCRIPT = Join-Path $REPO_ROOT "powershell/init-project.ps1"
$VALIDATE_SCRIPT = Join-Path $REPO_ROOT "powershell/validate-config.ps1"
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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-config-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $projectRoot = Join-Path $tempRoot "app"
    $null = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $INIT_SCRIPT -ProjectRoot $projectRoot -ProjectName "Config Test" -Quiet 2>&1)
    $configPath = Join-Path $projectRoot ".crucible/config.yaml"

    $results += Run-Test -Name "Template config fails until placeholders are replaced" -Body {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $configPath 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "placeholder exit" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit 2, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "placeholder message" -Condition ($output -match "placeholder") -FailureMessage ("expected placeholder warning. Output: " + $output)
    }

    $results += Run-Test -Name "Configured config passes" -Body {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $config = $config.Replace("replace-with-project-quick-test-command", "go test ./...")
        $config = $config.Replace("replace-with-project-full-test-command", "go test ./...")
        $config = $config.Replace("Replace with project-specific engineering rules.", "Keep project-specific mandates current.")
        $config | Out-File -LiteralPath $configPath -Encoding UTF8

        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $configPath 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "configured exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)
        Assert-Result -Name "configured message" -Condition ($output -match "CONFIG VALIDATION PASSED") -FailureMessage ("missing pass message. Output: " + $output)
    }

    $results += Run-Test -Name "Missing crucible_root fails" -Body {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $configWithoutRoot = $config -replace '(?m)^crucible_root:.+$', ''
        $testPath = Join-Path $projectRoot ".crucible/config-no-root.yaml"
        $configWithoutRoot | Out-File -LiteralPath $testPath -Encoding UTF8

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPath 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "no-root exit" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit 2, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "no-root message" -Condition ($output -match "Missing or invalid config field: crucible_root") -FailureMessage ("missing missing-crucible_root message. Output: " + $output)
    }

    $results += Run-Test -Name "Non-existent crucible_root fails" -Body {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $badPath = Join-Path $projectRoot "nonexistent-dir-12345"
        $configBadRoot = $config -replace '(?m)^crucible_root:.+$', "crucible_root: `"$badPath`""
        $testPath = Join-Path $projectRoot ".crucible/config-bad-root.yaml"
        $configBadRoot | Out-File -LiteralPath $testPath -Encoding UTF8

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPath 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "bad-root exit" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit 2, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "bad-root message" -Condition ($output -match "crucible_root path does not exist") -FailureMessage ("missing non-existent crucible_root message. Output: " + $output)
    }

    $results += Run-Test -Name "Invalid crucible_root structure fails" -Body {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $configInvalidRoot = $config -replace '(?m)^crucible_root:.+$', "crucible_root: `"$projectRoot`""
        $testPath = Join-Path $projectRoot ".crucible/config-invalid-root.yaml"
        $configInvalidRoot | Out-File -LiteralPath $testPath -Encoding UTF8

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPath 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "invalid-root exit" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit 2, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "invalid-root message" -Condition ($output -match "is not a complete installed Crucible bundle") -FailureMessage ("missing invalid-crucible_root message. Output: " + $output)
    }

    $results += Run-Test -Name "Missing config fails" -Body {
        $missingPath = Join-Path $projectRoot ".crucible/missing.yaml"
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $missingPath 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "missing exit" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit 2, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "missing message" -Condition ($output -match "file not found") -FailureMessage ("missing file-not-found message. Output: " + $output)
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
