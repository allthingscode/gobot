# Adopter smoke tests for Crucible.
# Verifies that a new project can adopt Crucible, ignore data/runtime, validate configuration, and pass factory linting.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$INIT_SCRIPT = Join-Path $REPO_ROOT "powershell/init-project.ps1"
$VALIDATE_SCRIPT = Join-Path $REPO_ROOT "powershell/validate-config.ps1"
$LINT_SCRIPT = Join-Path $REPO_ROOT "scripts/factory_lint.go"

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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-adopter-smoke-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $projectRoot = Join-Path $tempRoot "adopter-app"

    $results += Run-Test -Name "Adopts Crucible and verifies layout" -Body {
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        Push-Location $projectRoot
        try {
            git init --quiet
        } finally {
            Pop-Location
        }

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $INIT_SCRIPT `
            -ProjectRoot $projectRoot `
            -ProjectName "Adopter App" `
            -Description "Smoke testing the adopter adoption path." `
            -DefaultBranch "main" `
            -Quiet 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "init-project exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)

        $durablePaths = @(
            ".crucible/config.yaml",
            ".crucible/.gitignore",
            ".crucible/README.md",
            ".crucible/agent-instructions/AGENTS.md",
            ".crucible/agent-instructions/CLAUDE.md",
            ".crucible/agent-instructions/GEMINI.md"
        )
        foreach ($path in $durablePaths) {
            $fullPath = Join-Path $projectRoot $path
            Assert-Result -Name "$path exists" -Condition (Test-Path -LiteralPath $fullPath) -FailureMessage ("expected $path to exist")
        }

        $backlogDirs = @(
            ".crucible/backlog/features/active",
            ".crucible/backlog/features/archived",
            ".crucible/backlog/bugs/active",
            ".crucible/backlog/bugs/archived",
            ".crucible/backlog/chores/active",
            ".crucible/backlog/chores/archived"
        )
        foreach ($dir in $backlogDirs) {
            $fullPath = Join-Path $projectRoot $dir
            Assert-Result -Name "$dir exists" -Condition (Test-Path -LiteralPath $fullPath) -FailureMessage ("expected $dir to exist")
        }
    }

    $results += Run-Test -Name "Verifies Git ignore behavior in adopter app" -Body {
        Push-Location $projectRoot
        try {
            function Get-IsIgnored {
                param([string]$path)
                $out = @(git check-ignore -v $path 2>&1)
                $code = $LASTEXITCODE
                if ($code -ne 0) { return $false }
                $line = $out[0]
                $tabParts = $line -split "`t"
                $patternPart = $tabParts[0]
                $colonParts = $patternPart -split ":"
                if ($colonParts.Count -ge 3) {
                    $pattern = $colonParts[2..($colonParts.Count-1)] -join ":"
                } else {
                    $pattern = $patternPart
                }
                if ($pattern.StartsWith("!")) { return $false }
                return $true
            }

            $ignoredPaths = @(
                ".crucible/session/example.jsonl",
                ".crucible/backlog/BACKLOG.md",
                ".crucible/backlog/blocked/example.json",
                ".crucible/.agent-workspaces/example",
                ".crucible/locks/example.lock",
                ".crucible/tmp/example",
                ".crucible/cache/example",
                ".crucible/research/example.md",
                ".crucible/dev-logs/UNPUBLISHED_LOGS.md"
            )
            foreach ($path in $ignoredPaths) {
                $dummyPath = Join-Path $projectRoot $path
                $dummyDir = Split-Path -Parent $dummyPath
                if (-not (Test-Path -LiteralPath $dummyDir)) {
                    New-Item -ItemType Directory -Path $dummyDir -Force | Out-Null
                }
                Set-Content -LiteralPath $dummyPath -Value "dummy data"

                $isIgnored = Get-IsIgnored -path $path
                Assert-Result -Name "$path ignored" -Condition ($isIgnored) -FailureMessage ("path $path was not ignored")
            }

            $durablePaths = @(
                ".crucible/config.yaml",
                ".crucible/.gitignore",
                ".crucible/README.md",
                ".crucible/agent-instructions/AGENTS.md",
                ".crucible/agent-instructions/CLAUDE.md",
                ".crucible/agent-instructions/GEMINI.md"
            )
            foreach ($path in $durablePaths) {
                $isIgnored = Get-IsIgnored -path $path
                Assert-Result -Name "$path not ignored" -Condition (-not $isIgnored) -FailureMessage ("durable path $path was unexpectedly ignored")
            }
        } finally {
            Pop-Location
        }
    }

    $results += Run-Test -Name "Configures and validates config in adopter app" -Body {
        $configPath = Join-Path $projectRoot ".crucible/config.yaml"
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $config = $config.Replace("replace-with-project-quick-test-command", "go test ./...")
        $config = $config.Replace("replace-with-project-full-test-command", "go test ./...")
        $config = $config.Replace("Replace with project-specific engineering rules.", "Keep project-specific mandates current.")
        $config | Out-File -LiteralPath $configPath -Encoding UTF8

        $outputLines = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -ConfigPath $configPath 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "validate-config exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)
    }

    $results += Run-Test -Name "Runs factory_lint in adopter context" -Body {
        Push-Location $projectRoot
        try {
            $outputLines = @(go run $LINT_SCRIPT $REPO_ROOT 2>&1)
            $exitCode = $LASTEXITCODE
            $output = $outputLines -join "`n"
            Assert-Result -Name "factory_lint exit" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit 0, got " + $exitCode + ". Output: " + $output)
        } finally {
            Pop-Location
        }
    }

    $results += Run-Test -Name "Install does not copy a framework dir's nested .crucible runtime leak" -Body {
        # Seed a gitignored runtime leak under a framework source dir (as happens
        # when the framework is exercised in place), then assert the installer
        # does not drag it into the adopter bundle. The seed path is gitignored,
        # so this does not dirty the source tree.
        $seedDir = Join-Path $REPO_ROOT "powershell/.crucible/session/global"
        $seedFile = Join-Path $seedDir "session_state.json"
        $leakApp = Join-Path $tempRoot "leak-guard-app"
        try {
            New-Item -ItemType Directory -Path $seedDir -Force | Out-Null
            Set-Content -LiteralPath $seedFile -Value '{"seeded":"leak"}' -Encoding UTF8

            New-Item -ItemType Directory -Path $leakApp -Force | Out-Null
            $out = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $INIT_SCRIPT -ProjectRoot $leakApp -ProjectName "Leak Guard" -Quiet 2>&1)
            Assert-Result -Name "init exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("init failed: " + ($out -join "`n"))

            $nested = Join-Path $leakApp ".crucible/powershell/.crucible"
            Assert-Result -Name "no nested .crucible copied" -Condition (-not (Test-Path -LiteralPath $nested)) -FailureMessage ("installer copied a nested .crucible leak into the bundle: " + $nested)
        } finally {
            $srcLeak = Join-Path $REPO_ROOT "powershell/.crucible"
            if (Test-Path -LiteralPath $srcLeak) {
                Remove-Item -LiteralPath $srcLeak -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
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
