# Smoke tests for powershell/validate-config.ps1.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$INIT_SCRIPT = Join-Path $REPO_ROOT "powershell/init-project.ps1"
$VALIDATE_SCRIPT = Join-Path $REPO_ROOT "powershell/validate-config.ps1"
$results = @()







$tempRoot = New-TestFixtureRoot -NameHint "config-test"

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
        # Copy the installed .crucible bundle to a differently-named directory (.crucible-bundle)
        $altBundleRoot = Join-Path $projectRoot ".crucible-bundle"
        Copy-Item -LiteralPath (Join-Path $projectRoot ".crucible") -Destination $altBundleRoot -Recurse -Force

        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $configAltBundle = $config -replace '(?m)^crucible_root:.+$', 'crucible_root: ".crucible-bundle"'
        $testPath = Join-Path $projectRoot ".crucible/config-alt-bundle.yaml"
        $configAltBundle | Out-File -LiteralPath $testPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPath 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "alt-bundle exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)
        Assert-Result -Name "alt-bundle message" -Condition ($output -match "CONFIG VALIDATION PASSED") -FailureMessage ("missing pass message. Output: " + $output)
    }

    $results += Run-Test -Name "Non-.crucible bundle name without bundle structure fails" -Body {
        $emptyRoot = Join-Path $projectRoot ".my-bundle"
        New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null

        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $configEmptyRoot = $config -replace '(?m)^crucible_root:.+$', 'crucible_root: ".my-bundle"'
        $testPath = Join-Path $projectRoot ".crucible/config-empty-bundle.yaml"
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
        Assert-Result -Name "empty-bundle exit" -Condition ($exitCode -eq 2) -FailureMessage ("expected exit 2, got " + $exitCode + ". Output: " + $output)
        Assert-Result -Name "empty-bundle message" -Condition ($output -match "is not a complete installed Crucible bundle") -FailureMessage ("missing bundle-structure message. Output: " + $output)
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

    $results += Run-Test -Name "Nested custom crucible_root (e.g. tools/crucible) is accepted when bundle structure exists" -Body {
        $toolsCrucibleRoot = Join-Path $projectRoot "tools/crucible"
        New-Item -ItemType Directory -Path (Split-Path -Parent $toolsCrucibleRoot) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot ".crucible") -Destination $toolsCrucibleRoot -Recurse -Force

        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $configToolsCrucible = $config -replace '(?m)^crucible_root:.+$', 'crucible_root: "tools/crucible"'
        $testPath = Join-Path $projectRoot ".crucible/config-tools-crucible.yaml"
        $configToolsCrucible | Out-File -LiteralPath $testPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPath 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "tools-crucible exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)
        Assert-Result -Name "tools-crucible message" -Condition ($output -match "CONFIG VALIDATION PASSED") -FailureMessage ("missing pass message. Output: " + $output)
    }

    $results += Run-Test -Name "Escaping or absolute crucible_root fails" -Body {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8

        # 1. Escaping path
        $configEsc = $config -replace '(?m)^crucible_root:.+$', 'crucible_root: "../escaped"'
        $testPathEsc = Join-Path $projectRoot ".crucible/config-esc-root.yaml"
        $configEsc | Out-File -LiteralPath $testPathEsc -Encoding UTF8

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLinesEsc = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPathEsc 2>&1)
            $exitCodeEsc = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $outputEsc = $outputLinesEsc -join "`n"
        Assert-Result -Name "esc-root exit" -Condition ($exitCodeEsc -eq 2) -FailureMessage ("expected exit 2, got " + $exitCodeEsc + ". Output: " + $outputEsc)
        Assert-Result -Name "esc-root message" -Condition ($outputEsc -match "crucible_root must not escape the project root") -FailureMessage ("expected escaping error message. Output: " + $outputEsc)

        # 2. Windows drive-rooted path
        $configWin = $config -replace '(?m)^crucible_root:.+$', 'crucible_root: "C:\some\path"'
        $testPathWin = Join-Path $projectRoot ".crucible/config-win-root.yaml"
        $configWin | Out-File -LiteralPath $testPathWin -Encoding UTF8

        $ErrorActionPreference = "Continue"
        try {
            $outputLinesWin = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPathWin 2>&1)
            $exitCodeWin = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $outputWin = $outputLinesWin -join "`n"
        Assert-Result -Name "win-root exit" -Condition ($exitCodeWin -eq 2) -FailureMessage ("expected exit 2, got " + $exitCodeWin + ". Output: " + $outputWin)
        Assert-Result -Name "win-root message" -Condition ($outputWin -match "crucible_root must be a relative path") -FailureMessage ("expected relative path error message. Output: " + $outputWin)

        # 3. Unix absolute path
        $configUnix = $config -replace '(?m)^crucible_root:.+$', 'crucible_root: "/tmp/crucible"'
        $testPathUnix = Join-Path $projectRoot ".crucible/config-unix-root.yaml"
        $configUnix | Out-File -LiteralPath $testPathUnix -Encoding UTF8

        $ErrorActionPreference = "Continue"
        try {
            $outputLinesUnix = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPathUnix 2>&1)
            $exitCodeUnix = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $outputUnix = $outputLinesUnix -join "`n"
        Assert-Result -Name "unix-root exit" -Condition ($exitCodeUnix -eq 2) -FailureMessage ("expected exit 2, got " + $exitCodeUnix + ". Output: " + $outputUnix)
        Assert-Result -Name "unix-root message" -Condition ($outputUnix -match "crucible_root must be a relative path") -FailureMessage ("expected relative path error message. Output: " + $outputUnix)
    }

    $results += Run-Test -Name "Config with manifest_files validates correctly" -Body {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        
        # 1. Valid config with manifest_files block syntax
        $configWithManifest = $config + "`nmanifest_files:`n  - go.mod`n  - go.sum`n"
        $testPathWith = Join-Path $projectRoot ".crucible/config-with-manifest.yaml"
        $configWithManifest | Out-File -LiteralPath $testPathWith -Encoding UTF8

        $outputLinesWith = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPathWith 2>&1)
        $exitCodeWith = $LASTEXITCODE
        $outputWith = $outputLinesWith -join "`n"
        Assert-Result -Name "valid manifest exit" -Condition ($exitCodeWith -eq 0) -FailureMessage ("expected exit 0 for valid manifest_files config, got " + $exitCodeWith + ". Output: " + $outputWith)

        # 2. Invalid config with malformed manifest_files scalar syntax
        $configBadManifest = $config + "`nmanifest_files: go.mod`n"
        $testPathBad = Join-Path $projectRoot ".crucible/config-bad-manifest.yaml"
        $configBadManifest | Out-File -LiteralPath $testPathBad -Encoding UTF8

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLinesBad = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $testPathBad 2>&1)
            $exitCodeBad = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $outputBad = $outputLinesBad -join "`n"
        Assert-Result -Name "bad manifest exit" -Condition ($exitCodeBad -eq 2) -FailureMessage ("expected exit 2 for invalid manifest_files, got " + $exitCodeBad + ". Output: " + $outputBad)
        Assert-Result -Name "bad manifest message" -Condition ($outputBad -match "manifest_files must be an array") -FailureMessage ("expected array validation error message. Output: " + $outputBad)
    }

    # The review block was validated three keys deep - diff_tool, editor, auto_push -
    # and everything the CI publish gate reads went unchecked. A malformed value there
    # validated clean and then read as its default at runtime, which for
    # require_green_ci means the gate is off in a file that says it is on.
    $goodReview = @"

review:
  diff_tool: zed
  editor: zed
  auto_push: false
  require_green_ci: true
  ci_post_push_watch: false
  ci_timeout_minutes: 20
  ci_queued_grace_minutes: 15
  ci_staging_branch_prefix: staging/
  ci_required_checks: build
"@

    function New-ReviewConfig {
        param([string]$Name, [string]$Review)
        $base = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $path = Join-Path $projectRoot (".crucible/config-" + $Name + ".yaml")
        [System.IO.File]::WriteAllText($path, ($base + $Review), (New-Object System.Text.UTF8Encoding($false)))
        return $path
    }

    $results += Run-Test -Name "A well-formed review block passes" -Body {
        $path = New-ReviewConfig -Name "review-good" -Review $goodReview
        $cmd = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $path }
        Assert-Result -Name "good review exit" -Condition ($cmd.ExitCode -eq 0) -FailureMessage ("expected exit 0, got " + $cmd.ExitCode + ". Output: " + $cmd.Output)
    }

    $results += Run-Test -Name "A non-boolean review CI flag fails validation" -Body {
        $path = New-ReviewConfig -Name "review-bad-bool" -Review ($goodReview -replace "require_green_ci: true", "require_green_ci: yes")
        $cmd = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $path }
        Assert-Result -Name "bad bool exit" -Condition ($cmd.ExitCode -eq 2) -FailureMessage ("expected exit 2 for require_green_ci: yes, got " + $cmd.ExitCode + ". Output: " + $cmd.Output)
        Assert-Result -Name "bad bool message" -Condition ($cmd.Output -match "review\.require_green_ci must be true or false") -FailureMessage ("expected the boolean message. Output: " + $cmd.Output)
    }

    $results += Run-Test -Name "A non-numeric review CI timeout fails validation" -Body {
        $path = New-ReviewConfig -Name "review-bad-timeout" -Review ($goodReview -replace "ci_timeout_minutes: 20", "ci_timeout_minutes: soon")
        $cmd = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $path }
        Assert-Result -Name "bad timeout exit" -Condition ($cmd.ExitCode -eq 2) -FailureMessage ("expected exit 2 for ci_timeout_minutes: soon, got " + $cmd.ExitCode + ". Output: " + $cmd.Output)
        Assert-Result -Name "bad timeout message" -Condition ($cmd.Output -match "review\.ci_timeout_minutes must be a positive whole number") -FailureMessage ("expected the numeric message. Output: " + $cmd.Output)
    }

    $results += Run-Test -Name "A review key present but valueless is reported, not treated as absent" -Body {
        $path = New-ReviewConfig -Name "review-valueless" -Review ($goodReview -replace "require_green_ci: true", "require_green_ci:")
        $cmd = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $path }
        Assert-Result -Name "valueless exit" -Condition ($cmd.ExitCode -eq 2) -FailureMessage ("expected exit 2 for a valueless require_green_ci, got " + $cmd.ExitCode + ". Output: " + $cmd.Output)
        Assert-Result -Name "valueless message" -Condition ($cmd.Output -match "present but carries no value") -FailureMessage ("expected the unreadable-key message. Output: " + $cmd.Output)
    }

    $results += Run-Test -Name "Indent width does not change the verdict" -Body {
        # The runtime reads this file indent-agnostically. A validator that only
        # understands two spaces disagrees with it about the same config, and reports
        # fields as missing that the runtime reads without trouble.
        $base = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $widened = (($base + $goodReview) -split "`r?`n" | ForEach-Object {
            if ($_ -match '^( +)(.*)$') { (" " * ($Matches[1].Length * 2)) + $Matches[2] } else { $_ }
        }) -join "`n"
        $path = Join-Path $projectRoot ".crucible/config-wide-indent.yaml"
        [System.IO.File]::WriteAllText($path, $widened, (New-Object System.Text.UTF8Encoding($false)))

        $cmd = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $path }
        Assert-Result -Name "wide indent exit" -Condition ($cmd.ExitCode -eq 0) -FailureMessage ("expected a 4-space config to validate the same as a 2-space one, got exit " + $cmd.ExitCode + ". Output: " + $cmd.Output)
    }

    $results += Run-Test -Name "Schema config.schema.json pattern regression test" -Body {
        $schemaPath = Join-Path $REPO_ROOT "schemas/config.schema.json"
        Assert-Result -Name "schema exists" -Condition (Test-Path -LiteralPath $schemaPath) -FailureMessage "config.schema.json not found"
        $schemaContent = Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8

        $obsoletePatternString = '"pattern": "^\\.crucible($|[\\\\/])"'
        Assert-Result -Name "obsolete pattern gone" -Condition (-not $schemaContent.Contains($obsoletePatternString)) -FailureMessage "config.schema.json still contains the obsolete crucible_root pattern string"

        $newPatternString = '"pattern": "^(?![A-Za-z]:)(?![\\\\/])(?!.*(^|[\\\\/])\\.\\.($|[\\\\/])).+"'
        Assert-Result -Name "new pattern present" -Condition ($schemaContent.Contains($newPatternString)) -FailureMessage "config.schema.json does not contain the new pattern string"
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
