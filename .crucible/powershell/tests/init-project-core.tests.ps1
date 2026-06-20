# Smoke tests for powershell/init-project.ps1 (Core Scaffolding).

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$env:CRUCIBLE_SKIP_PROVENANCE = "true"
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$SCRIPT = Join-Path $REPO_ROOT "powershell/init-project.ps1"
$results = @()

function Invoke-InitScript {
    $cleanArray = @()
    $i = 0
    while ($i -lt $args.Count) {
        $arg = $args[$i]
        if ($arg -eq "-AsSubprocess") {
            $i++
            continue
        }
        $cleanArray += $arg
        $i++
    }

    $output = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $SCRIPT @cleanArray 2>&1)
    return $output
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-init-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $projectRoot = Join-Path $tempRoot "app"

    $results += Run-Test -Name "Installs scaffold with configured project metadata" -Body {
        $outputLines = @(Invoke-InitScript `
            -ProjectRoot $projectRoot `
            -ProjectName "Test App" `
            -Description "Temporary app for init-project tests." `
            -DefaultBranch "trunk" `
            -Quiet 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "install exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)

        $configPath = Join-Path $projectRoot ".crucible/config.yaml"
        $ignorePath = Join-Path $projectRoot ".crucible/.gitignore"
        $backlogPath = Join-Path $projectRoot ".crucible/backlog/BACKLOG.md"
        $agentsMd = Join-Path $projectRoot ".crucible/agent-instructions/AGENTS.md"
        $claudeMd = Join-Path $projectRoot ".crucible/agent-instructions/CLAUDE.md"
        $geminiMd = Join-Path $projectRoot ".crucible/agent-instructions/GEMINI.md"
        $configHelpersPath = Join-Path $projectRoot ".crucible/powershell/lib/config-helpers.ps1"
        Assert-Result -Name "config-helpers.ps1 exists" -Condition (Test-Path -LiteralPath $configHelpersPath) -FailureMessage "config-helpers.ps1 was not created"
        Assert-Result -Name "config exists" -Condition (Test-Path -LiteralPath $configPath) -FailureMessage "config.yaml was not created"
        Assert-Result -Name "ignore exists" -Condition (Test-Path -LiteralPath $ignorePath) -FailureMessage ".gitignore was not created"
        Assert-Result -Name "backlog exists" -Condition (Test-Path -LiteralPath $backlogPath) -FailureMessage "BACKLOG.md was not created"
        Assert-Result -Name "AGENTS.md exists" -Condition (Test-Path -LiteralPath $agentsMd) -FailureMessage "AGENTS.md was not created"
        Assert-Result -Name "CLAUDE.md exists" -Condition (Test-Path -LiteralPath $claudeMd) -FailureMessage "CLAUDE.md was not created"
        Assert-Result -Name "GEMINI.md exists" -Condition (Test-Path -LiteralPath $geminiMd) -FailureMessage "GEMINI.md was not created"

        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        Assert-Result -Name "project name" -Condition ($config -match 'name: "Test App"') -FailureMessage "project name was not replaced"
        Assert-Result -Name "description" -Condition ($config -match 'description: "Temporary app for init-project tests\."') -FailureMessage "description was not replaced"
        Assert-Result -Name "default branch" -Condition ($config -match 'default_branch: "trunk"') -FailureMessage "default branch was not replaced"
    }

    $results += Run-Test -Name "Refuses to overwrite without Force" -Body {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(Invoke-InitScript `
                -ProjectRoot $projectRoot `
                -ProjectName "Second App" `
                -Quiet 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "overwrite exit" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit. Output: " + $output)
        Assert-Result -Name "overwrite message" -Condition ($output -match 'An installed Crucible bundle already exists') -FailureMessage ("missing overwrite refusal. Output: " + $output)
    }

    $results += Run-Test -Name "Force overwrites scaffold-managed files" -Body {
        $outputLines = @(Invoke-InitScript `
            -ProjectRoot $projectRoot `
            -ProjectName "Forced App" `
            -Description "Forced scaffold refresh." `
            -Force `
            -Quiet 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "force exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)
        $config = Get-Content -LiteralPath (Join-Path $projectRoot ".crucible/config.yaml") -Raw -Encoding UTF8
        Assert-Result -Name "force project name" -Condition ($config -match 'name: "Forced App"') -FailureMessage "force did not refresh config"
    }

    $results += Run-Test -Name "Nested ignore distinguishes runtime from durable config" -Body {
        Push-Location $projectRoot
        try {
            git init --quiet

            # Test ignored paths
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

            # Test durable (not ignored) paths
            $durablePaths = @(
                ".crucible/config.yaml",
                ".crucible/.gitignore",
                ".crucible/README.md",
                ".crucible/agent-instructions/AGENTS.md",
                ".crucible/agent-instructions/CLAUDE.md",
                ".crucible/agent-instructions/GEMINI.md"
            )

            # Pre-create all ignored path dummy files so git check-ignore matches correctly
            foreach ($path in $ignoredPaths) {
                $dummyPath = Join-Path $projectRoot $path
                $dummyDir = Split-Path -Parent $dummyPath
                if (-not (Test-Path -LiteralPath $dummyDir)) {
                    New-Item -ItemType Directory -Path $dummyDir -Force | Out-Null
                }
                Set-Content -LiteralPath $dummyPath -Value "dummy"
            }

            # Batch check ignore status in a single process to avoid CPU overhead
            $allPaths = $ignoredPaths + $durablePaths
            $ignoredSet = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

            $checkIgnoreOutput = @(git check-ignore -v $allPaths 2>$null)
            foreach ($line in $checkIgnoreOutput) {
                # Format of git check-ignore -v is: <file>:<line>:<pattern><tab><path>
                if ($line -match "^([^:]+):([^:]+):([^`t]+)`t(.*)$") {
                    $pattern = $Matches[3]
                    $matchedPath = $Matches[4].Trim()
                    if (-not $pattern.StartsWith("!")) {
                        [void]$ignoredSet.Add($matchedPath)
                    }
                }
            }

            foreach ($path in $ignoredPaths) {
                $isIgnored = $ignoredSet.Contains($path)
                Assert-Result -Name "$path ignored" -Condition ($isIgnored) -FailureMessage ("path $path was not ignored")
            }

            foreach ($path in $durablePaths) {
                $isIgnored = $ignoredSet.Contains($path)
                Assert-Result -Name "$path not ignored" -Condition (-not $isIgnored) -FailureMessage ("durable path $path was unexpectedly ignored")
            }
        } finally {
            Pop-Location
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
