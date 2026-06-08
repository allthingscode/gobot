# Smoke tests for powershell/validate-config.ps1.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
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
    $null = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $INIT_SCRIPT -ProjectRoot $projectRoot -ProjectName "Config Test" -Quiet 2>&1)
    $configPath = Join-Path $projectRoot ".crucible/config.yaml"

    $results += Run-Test -Name "Template config fails until placeholders are replaced" -Body {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $configPath 2>&1)
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

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $configPath 2>&1)
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
            $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPath 2>&1)
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
            $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPath 2>&1)
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
            $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPath 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "invalid-root exit" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit 2, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "invalid-root message" -Condition ($output -match "is not a complete installed Crucible bundle") -FailureMessage ("missing invalid-crucible_root message. Output: " + $output)
    }

    $results += Run-Test -Name "Non-.crucible bundle name is accepted when bundle structure exists" -Body {
        # Copy the installed .crucible bundle to a differently-named directory (.dev-factory)
        $devFactoryRoot = Join-Path $projectRoot ".dev-factory"
        Copy-Item -LiteralPath (Join-Path $projectRoot ".crucible") -Destination $devFactoryRoot -Recurse -Force

        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $configDevFactory = $config -replace '(?m)^crucible_root:.+$', 'crucible_root: ".dev-factory"'
        $testPath = Join-Path $projectRoot ".crucible/config-dev-factory.yaml"
        $configDevFactory | Out-File -LiteralPath $testPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPath 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "dev-factory exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)
        Assert-Result -Name "dev-factory message" -Condition ($output -match "CONFIG VALIDATION PASSED") -FailureMessage ("missing pass message. Output: " + $output)
    }

    $results += Run-Test -Name "Non-.crucible bundle name without bundle structure fails" -Body {
        $emptyRoot = Join-Path $projectRoot ".my-factory"
        New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null

        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $configEmptyRoot = $config -replace '(?m)^crucible_root:.+$', 'crucible_root: ".my-factory"'
        $testPath = Join-Path $projectRoot ".crucible/config-empty-factory.yaml"
        $configEmptyRoot | Out-File -LiteralPath $testPath -Encoding UTF8

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPath 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "empty-factory exit" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit 2, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "empty-factory message" -Condition ($output -match "is not a complete installed Crucible bundle") -FailureMessage ("missing bundle-structure message. Output: " + $output)
    }

    $results += Run-Test -Name "Missing config fails" -Body {
        $missingPath = Join-Path $projectRoot ".crucible/missing.yaml"
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $missingPath 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "missing exit" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit 2, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "missing message" -Condition ($output -match "file not found") -FailureMessage ("missing file-not-found message. Output: " + $output)
    }

    $results += Run-Test -Name "Config passes when paths section is completely omitted" -Body {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        # Ensure it has NO paths: block
        $configNoPaths = $config -replace '(?ms)^paths:\s*\r?\n(\s{2}.*\r?\n)*', ''
        $testPath = Join-Path $projectRoot ".crucible/config-no-paths.yaml"
        $configNoPaths | Out-File -LiteralPath $testPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPath 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "no-paths exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)
        Assert-Result -Name "no-paths message" -Condition ($output -match "CONFIG VALIDATION PASSED") -FailureMessage ("expected pass message. Output: " + $output)
    }

    $results += Run-Test -Name "Config fails when paths section is present but incomplete" -Body {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        # Add an incomplete paths section (only backlog)
        $incompletePaths = "`r`npaths:`r`n  backlog: .crucible/backlog`r`n"
        $configBadPaths = $config + $incompletePaths
        $testPath = Join-Path $projectRoot ".crucible/config-bad-paths.yaml"
        $configBadPaths | Out-File -LiteralPath $testPath -Encoding UTF8

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPath 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "bad-paths exit" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit 2, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "bad-paths message" -Condition ($output -match "Missing or invalid config field: paths.session") -FailureMessage ("missing missing-paths message. Output: " + $output)
    }

    $results += Run-Test -Name "Config passes when paths section contains a custom relative backlog path" -Body {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        # Replace the paths block with a valid custom relative backlog path
        $customPaths = "`r`npaths:`r`n  backlog: custom/backlog`r`n  session: .crucible/session`r`n  workspaces: .crucible/.agent-workspaces`r`n  prompts: .crucible/prompts`r`n  personas: .crucible/personas`r`n  sops: .crucible/sops`r`n"
        $configCustomPaths = ($config -replace '(?ms)^paths:\s*\r?\n(\s{2}.*\r?\n)*', '') + $customPaths
        $testPath = Join-Path $projectRoot ".crucible/config-custom-paths.yaml"
        $configCustomPaths | Out-File -LiteralPath $testPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPath 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "custom-paths exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)
        Assert-Result -Name "custom-paths message" -Condition ($output -match "CONFIG VALIDATION PASSED") -FailureMessage ("expected pass message. Output: " + $output)
    }

    $results += Run-Test -Name "Config fails when backlog path is absolute or escapes project root" -Body {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        
        # 1. Test Absolute backlog path
        $absolutePath = "`r`npaths:`r`n  backlog: C:\Absolute\Path`r`n  session: .crucible/session`r`n  workspaces: .crucible/.agent-workspaces`r`n  prompts: .crucible/prompts`r`n  personas: .crucible/personas`r`n  sops: .crucible/sops`r`n"
        $configAbsPaths = ($config -replace '(?ms)^paths:\s*\r?\n(\s{2}.*\r?\n)*', '') + $absolutePath
        $testPathAbs = Join-Path $projectRoot ".crucible/config-abs-paths.yaml"
        $configAbsPaths | Out-File -LiteralPath $testPathAbs -Encoding UTF8

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLinesAbs = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPathAbs 2>&1)
            $exitCodeAbs = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $outputAbs = $outputLinesAbs -join "`n"
        Assert-Result -Name "abs-paths exit" -Condition ($exitCodeAbs -eq 2) -FailureMessage ("expected exit 2, got " + $exitCodeAbs + ". Output: " + $outputAbs)
        Assert-Result -Name "abs-paths message" -Condition ($outputAbs -match "paths.backlog must be a relative path") -FailureMessage ("expected relative path error message. Output: " + $outputAbs)

        # 2. Test escaping backlog path
        $escapingPath = "`r`npaths:`r`n  backlog: ../escaped`r`n  session: .crucible/session`r`n  workspaces: .crucible/.agent-workspaces`r`n  prompts: .crucible/prompts`r`n  personas: .crucible/personas`r`n  sops: .crucible/sops`r`n"
        $configEscPaths = ($config -replace '(?ms)^paths:\s*\r?\n(\s{2}.*\r?\n)*', '') + $escapingPath
        $testPathEsc = Join-Path $projectRoot ".crucible/config-esc-paths.yaml"
        $configEscPaths | Out-File -LiteralPath $testPathEsc -Encoding UTF8

        $ErrorActionPreference = "Continue"
        try {
            $outputLinesEsc = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPathEsc 2>&1)
            $exitCodeEsc = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $outputEsc = $outputLinesEsc -join "`n"
        Assert-Result -Name "esc-paths exit" -Condition ($exitCodeEsc -eq 2) -FailureMessage ("expected exit 2, got " + $exitCodeEsc + ". Output: " + $outputEsc)
        Assert-Result -Name "esc-paths message" -Condition ($outputEsc -match "paths.backlog must not escape the project root") -FailureMessage ("expected escaping error message. Output: " + $outputEsc)
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
