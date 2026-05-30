# Smoke tests for powershell/init-project.ps1.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$SCRIPT = Join-Path $REPO_ROOT "powershell/init-project.ps1"
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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-init-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $projectRoot = Join-Path $tempRoot "app"

    $results += Run-Test -Name "Installs scaffold with configured project metadata" -Body {
        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
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
            $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
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
        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
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
            foreach ($path in $ignoredPaths) {
                # Create the file dummy first so git check-ignore can check correctly
                $dummyPath = Join-Path $projectRoot $path
                $dummyDir = Split-Path -Parent $dummyPath
                if (-not (Test-Path -LiteralPath $dummyDir)) {
                    New-Item -ItemType Directory -Path $dummyDir -Force | Out-Null
                }
                Set-Content -LiteralPath $dummyPath -Value "dummy"

                $isIgnored = Get-IsIgnored -path $path
                Assert-Result -Name "$path ignored" -Condition ($isIgnored) -FailureMessage ("path $path was not ignored")
            }

            # Test durable (not ignored) paths
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

    # --- AppendInstructions tests ---
    # Use a separate project root to avoid interference with earlier scaffold tests
    $appendRoot = Join-Path $tempRoot "append-app"

    $results += Run-Test -Name "AppendInstructions creates instruction files with sentinel markers" -Body {
        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
            -ProjectRoot $appendRoot `
            -ProjectName "Append Test" `
            -AppendInstructions `
            -Quiet 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "append exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)

        foreach ($fileName in @("AGENTS.md", "CLAUDE.md", "GEMINI.md")) {
            $filePath = Join-Path $appendRoot $fileName
            Assert-Result -Name "$fileName exists" -Condition (Test-Path -LiteralPath $filePath) -FailureMessage "$fileName was not created"

            $content = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
            $startCount = ([regex]::Matches($content, "crucible-instructions-start")).Count
            $endCount   = ([regex]::Matches($content, "crucible-instructions-end")).Count
            Assert-Result -Name "$fileName has start marker" -Condition ($startCount -eq 1) -FailureMessage ("expected 1 start marker, got " + $startCount)
            Assert-Result -Name "$fileName has end marker"   -Condition ($endCount -eq 1) -FailureMessage ("expected 1 end marker, got " + $endCount)
        }

        # Verify AGENTS.md contains canonical content
        $agentsContent = Get-Content -LiteralPath (Join-Path $appendRoot "AGENTS.md") -Raw -Encoding UTF8
        Assert-Result -Name "AGENTS has crucible heading" -Condition ($agentsContent -match "## Crucible") -FailureMessage "AGENTS.md missing Crucible heading"
        Assert-Result -Name "AGENTS has factory snippet" -Condition ($agentsContent -match "factory\.ps1") -FailureMessage "AGENTS.md missing factory.ps1 snippet"
        Assert-Result -Name "AGENTS has commit list" -Condition ($agentsContent -match "Commit durable Crucible files") -FailureMessage "AGENTS.md missing commit list"
    }

    $results += Run-Test -Name "AppendInstructions skips when block already exists (idempotent)" -Body {
        # appendRoot already has instruction files from the previous test

        # Capture file contents before re-run
        $beforeAgents = Get-Content -LiteralPath (Join-Path $appendRoot "AGENTS.md") -Raw -Encoding UTF8
        $beforeClaude = Get-Content -LiteralPath (Join-Path $appendRoot "CLAUDE.md") -Raw -Encoding UTF8
        $beforeGemini = Get-Content -LiteralPath (Join-Path $appendRoot "GEMINI.md") -Raw -Encoding UTF8

        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
            -ProjectRoot $appendRoot `
            -AppendInstructions `
            -Force `
            -Quiet 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "rerun exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)

        # Marker count unchanged
        $agentsContent = Get-Content -LiteralPath (Join-Path $appendRoot "AGENTS.md") -Raw -Encoding UTF8
        $startCount = ([regex]::Matches($agentsContent, "crucible-instructions-start")).Count
        Assert-Result -Name "still one marker" -Condition ($startCount -eq 1) -FailureMessage ("expected 1 start marker after rerun, got " + $startCount)

        # Content byte-identical
        $afterAgents = Get-Content -LiteralPath (Join-Path $appendRoot "AGENTS.md") -Raw -Encoding UTF8
        $afterClaude = Get-Content -LiteralPath (Join-Path $appendRoot "CLAUDE.md") -Raw -Encoding UTF8
        $afterGemini = Get-Content -LiteralPath (Join-Path $appendRoot "GEMINI.md") -Raw -Encoding UTF8
        Assert-Result -Name "AGENTS unchanged" -Condition ($beforeAgents -eq $afterAgents) -FailureMessage "AGENTS.md content changed on rerun"
        Assert-Result -Name "CLAUDE unchanged" -Condition ($beforeClaude -eq $afterClaude) -FailureMessage "CLAUDE.md content changed on rerun"
        Assert-Result -Name "GEMINI unchanged" -Condition ($beforeGemini -eq $afterGemini) -FailureMessage "GEMINI.md content changed on rerun"
    }

    $results += Run-Test -Name "AppendInstructions aborts on corrupt sentinel markers" -Body {
        $corruptRoot = Join-Path $tempRoot "corrupt-app"

        # First create a valid scaffold
        $null = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
            -ProjectRoot $corruptRoot `
            -ProjectName "Corrupt Test" `
            -Quiet 2>&1)

        # Create an AGENTS.md with only the start marker (no end marker)
        $corruptAgents = Join-Path $corruptRoot "AGENTS.md"
        Set-Content -LiteralPath $corruptAgents -Value "# My Project`n`n<!-- crucible-instructions-start -->`nSome content without end marker" -Encoding UTF8

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
                -ProjectRoot $corruptRoot `
                -AppendInstructions `
                -Force `
                -Quiet 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "corrupt exit" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit on corrupt markers. Output: " + $output)
        Assert-Result -Name "corrupt message" -Condition ($output -match "corrupted|mismatched") -FailureMessage ("expected corruption error message. Output: " + $output)
    }

    $results += Run-Test -Name "AppendInstructions preserves personal content byte-for-byte" -Body {
        $preserveRoot = Join-Path $tempRoot "preserve-app"

        # Create scaffold first (without AppendInstructions)
        $null = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
            -ProjectRoot $preserveRoot `
            -ProjectName "Preserve Test" `
            -Quiet 2>&1)

        # Create an AGENTS.md with personal content above and below where block will land
        $personalAgents = Join-Path $preserveRoot "AGENTS.md"
        $personalContent = "# My Personal Rules`n`nThese are my private workflow notes.`nDo not touch this content.`n`n## My Other Section`n`nMore personal content here.`n"
        [System.IO.File]::WriteAllText($personalAgents, $personalContent, [System.Text.UTF8Encoding]::new($false))

        # Run AppendInstructions
        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
            -ProjectRoot $preserveRoot `
            -AppendInstructions `
            -Force `
            -Quiet 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "preserve exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)

        # Read back and verify personal content is preserved at the start
        $result = Get-Content -LiteralPath $personalAgents -Raw -Encoding UTF8
        Assert-Result -Name "starts with personal" -Condition ($result.StartsWith("# My Personal Rules")) -FailureMessage "personal content header was modified"
        Assert-Result -Name "has personal notes" -Condition ($result -match "These are my private workflow notes\.") -FailureMessage "personal workflow notes were modified"
        Assert-Result -Name "has other section" -Condition ($result -match "## My Other Section") -FailureMessage "personal section was modified"
        Assert-Result -Name "has more personal" -Condition ($result -match "More personal content here\.") -FailureMessage "trailing personal content was modified"

        # Also verify the block was appended
        Assert-Result -Name "has crucible block" -Condition ($result -match "crucible-instructions-start") -FailureMessage "Crucible block was not appended"
        Assert-Result -Name "has crucible end" -Condition ($result -match "crucible-instructions-end") -FailureMessage "Crucible end marker was not appended"
    }

    $results += Run-Test -Name "Configures language presets correctly" -Body {
        foreach ($lang in 'go','node','python','rust') {
            $langRoot = Join-Path $tempRoot "lang-$lang"
            $null = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
                -ProjectRoot $langRoot `
                -ProjectName "Lang App $lang" `
                -Language $lang `
                -Quiet 2>&1)
            $configPath = Join-Path $langRoot ".crucible/config.yaml"
            Assert-Result -Name "config exists for $lang" -Condition (Test-Path -LiteralPath $configPath) -FailureMessage "config.yaml not created for $lang"
            $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
            
            Assert-Result -Name "no placeholders for $lang" -Condition ($config -notmatch "replace-with-project") -FailureMessage "placeholders remained in config for $lang"
            
            if ($lang -eq "go") {
                Assert-Result -Name "go test command" -Condition ($config -match 'command:\s*"?go test \./\.\.\."?') -FailureMessage "missing go test command"
            } elseif ($lang -eq "node") {
                Assert-Result -Name "node test command" -Condition ($config -match 'command:\s*"?npm test"?') -FailureMessage "missing npm test command"
            }
        }
    }

    $results += Run-Test -Name "Scaffolds sample task F-001 correctly" -Body {
        $sampleRoot = Join-Path $tempRoot "sample-task-app"
        $null = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
            -ProjectRoot $sampleRoot `
            -ProjectName "Sample App" `
            -Language "go" `
            -WithSampleTask `
            -Quiet 2>&1)
        
        $taskPath = Join-Path $sampleRoot ".crucible/backlog/features/active/F-001_Hello_World.md"
        Assert-Result -Name "sample task exists" -Condition (Test-Path -LiteralPath $taskPath) -FailureMessage "F-001_Hello_World.md was not created"
        
        $taskContent = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8
        Assert-Result -Name "has go criteria" -Condition ($taskContent -match 'go test \./\.\.\..* passes') -FailureMessage "missing go specific criteria in sample task"
        
        $backlogFile = Join-Path $sampleRoot ".crucible/backlog/BACKLOG.md"
        $backlogContent = Get-Content -LiteralPath $backlogFile -Raw -Encoding UTF8
        Assert-Result -Name "backlog links task" -Condition ($backlogContent -match '\[F-001\]\(features/active/F-001_Hello_World\.md\)') -FailureMessage "BACKLOG.md missing F-001 link"
        Assert-Result -Name "backlog summary counts updated" -Condition ($backlogContent -match '\|\s*\*\*P1\*\*\s*\|\s*1\s*\|') -FailureMessage "BACKLOG.md P1 summary count was not updated"
    }

    $results += Run-Test -Name "Verifies no drift between language-presets and config-reference.md" -Body {
        $presetsPath = Join-Path $REPO_ROOT "powershell/lib/language-presets.ps1"
        . $presetsPath
        $presets = Get-LanguagePresets
        
        $docPath = Join-Path $REPO_ROOT "docs/config-reference.md"
        $docContent = Get-Content -LiteralPath $docPath -Raw -Encoding UTF8
        
        foreach ($lang in $presets.Keys) {
            $preset = $presets[$lang]
            foreach ($step in $preset.quick) {
                $cmdEsc = [regex]::Escape($step.command)
                Assert-Result -Name "doc matches quick command $lang ($($step.command))" -Condition ($docContent -match $cmdEsc) -FailureMessage "docs/config-reference.md does not contain quick verification command preset: $($step.command)"
            }
            foreach ($step in $preset.full) {
                $cmdEsc = [regex]::Escape($step.command)
                Assert-Result -Name "doc matches full command $lang ($($step.command))" -Condition ($docContent -match $cmdEsc) -FailureMessage "docs/config-reference.md does not contain full verification command preset: $($step.command)"
            }
        }
    }

    $results += Run-Test -Name "Stamps crucible_version and crucible_install_commit from upstream" -Body {
        $stampRoot = Join-Path $tempRoot "version-stamp-app"
        $null = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
            -ProjectRoot $stampRoot `
            -ProjectName "Stamp Test" `
            -Quiet 2>&1)
        Assert-Result -Name "stamp exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE)

        $configPath = Join-Path $stampRoot ".crucible/config.yaml"
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $configBytes = [System.IO.File]::ReadAllBytes($configPath)

        Assert-Result -Name "version stamped" -Condition ($config -match '(?m)^crucible_version:\s+"\d+\.\d+\.\d+') -FailureMessage "crucible_version was not stamped with a semver value"
        Assert-Result -Name "commit stamped" -Condition ($config -match '(?m)^crucible_install_commit:\s+"[0-9a-f]{40}"') -FailureMessage "crucible_install_commit was not stamped with a 40-char SHA"
        Assert-Result -Name "no version placeholder" -Condition ($config -notmatch 'REPLACE_WITH_VERSION') -FailureMessage "REPLACE_WITH_VERSION placeholder remained"
        Assert-Result -Name "no commit placeholder" -Condition ($config -notmatch 'REPLACE_WITH_COMMIT') -FailureMessage "REPLACE_WITH_COMMIT placeholder remained"
        Assert-Result -Name "config has no UTF-8 BOM" -Condition (-not ($configBytes.Length -ge 3 -and $configBytes[0] -eq 0xEF -and $configBytes[1] -eq 0xBB -and $configBytes[2] -eq 0xBF)) -FailureMessage "config.yaml was written with a UTF-8 BOM"
        Assert-Result -Name "manifest installed" -Condition (Test-Path -LiteralPath (Join-Path $stampRoot ".crucible/install-manifest.json")) -FailureMessage "install-manifest.json was not installed into .crucible"
    }

    $results += Run-Test -Name "StampVersionOnly stamps pre-existing config without scaffolding" -Body {
        $stampOnlyRoot = Join-Path $tempRoot "stamp-only-app"
        $configDir = Join-Path $stampOnlyRoot ".crucible"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        $configPath = Join-Path $configDir "config.yaml"
        @"
project:
  name: "Existing App"
custom_value: "preserve me"
"@ | Out-File -LiteralPath $configPath -Encoding UTF8

        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
            -ProjectRoot $stampOnlyRoot `
            -StampVersionOnly `
            -Quiet 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "stamp-only exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)

        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $configBytes = [System.IO.File]::ReadAllBytes($configPath)
        $head = ((git -C $REPO_ROOT rev-parse HEAD) | Out-String).Trim()
        Assert-Result -Name "version stamped" -Condition ($config -match '(?m)^crucible_version:\s+"\d+\.\d+\.\d+') -FailureMessage "crucible_version was not stamped"
        Assert-Result -Name "commit stamped" -Condition ($config -match ('(?m)^crucible_install_commit:\s+"' + [regex]::Escape($head) + '"')) -FailureMessage "crucible_install_commit did not match HEAD"
        Assert-Result -Name "custom key preserved" -Condition ($config -match 'custom_value: "preserve me"') -FailureMessage "custom config content was not preserved"
        Assert-Result -Name "stamp-only config has no UTF-8 BOM" -Condition (-not ($configBytes.Length -ge 3 -and $configBytes[0] -eq 0xEF -and $configBytes[1] -eq 0xBB -and $configBytes[2] -eq 0xBF)) -FailureMessage "StampVersionOnly wrote config.yaml with a UTF-8 BOM"
        Assert-Result -Name "no scaffold copied" -Condition (-not (Test-Path -LiteralPath (Join-Path $stampOnlyRoot ".crucible/powershell"))) -FailureMessage "StampVersionOnly copied scaffold files"

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $secondOutput = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
                -ProjectRoot $stampOnlyRoot `
                -StampVersionOnly `
                -Quiet 2>&1)
            $secondExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $second = $secondOutput -join "`n"
        Assert-Result -Name "refuses existing stamp" -Condition ($secondExit -ne 0) -FailureMessage ("expected non-zero exit on existing stamp. Output: " + $second)
        Assert-Result -Name "force guidance" -Condition ($second -match '-Force') -FailureMessage ("missing -Force guidance. Output: " + $second)
    }

    $results += Run-Test -Name "Default install output has no validate-backlog chatter" -Body {
        $quietRoot = Join-Path $tempRoot "quiet-output-app"
        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
            -ProjectRoot $quietRoot `
            -ProjectName "Quiet Output Test" `
            -Language "go" `
            -WithSampleTask 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "install exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)
        Assert-Result -Name "no BACKLOG VALIDATION START" -Condition ($output -notmatch "BACKLOG VALIDATION START") -FailureMessage "BACKLOG VALIDATION chatter appeared in default install output"
        Assert-Result -Name "no Scanning directory chatter" -Condition ($output -notmatch "Scanning features directory") -FailureMessage "validate-backlog scan chatter appeared in default install output"
        Assert-Result -Name "output under 40 lines" -Condition ($outputLines.Count -le 40) -FailureMessage ("install output was " + $outputLines.Count + " lines; expected <= 40")
    }

    $results += Run-Test -Name "Step 5 shows sample-task hint when -WithSampleTask" -Body {
        $step5Root = Join-Path $tempRoot "step5-with-sample-app"
        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
            -ProjectRoot $step5Root `
            -ProjectName "Step5 Sample Test" `
            -Language "go" `
            -WithSampleTask 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "exit ok" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)
        Assert-Result -Name "F-001 hint in step 5" -Condition ($output -match "F-001 sample task installed") -FailureMessage ("step 5 missing F-001 hint. Output: " + $output)
        Assert-Result -Name "no generic step 5 wording" -Condition ($output -notmatch "Add initial backlog items") -FailureMessage ("step 5 still shows generic wording. Output: " + $output)
    }

    $results += Run-Test -Name "Step 5 shows generic hint when no -WithSampleTask" -Body {
        $step5Root = Join-Path $tempRoot "step5-no-sample-app"
        $outputLines = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
            -ProjectRoot $step5Root `
            -ProjectName "Step5 NoSample Test" 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "exit ok" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)
        Assert-Result -Name "generic step 5 wording" -Condition ($output -match "Add initial backlog items") -FailureMessage ("step 5 missing generic wording. Output: " + $output)
        Assert-Result -Name "no F-001 hint" -Condition ($output -notmatch "F-001 sample task installed") -FailureMessage ("step 5 shows F-001 hint unexpectedly. Output: " + $output)
    }

    $results += Run-Test -Name "Supports configurable backlog directory and moves scaffold files" -Body {
        $customAppRoot = Join-Path $tempRoot "custom-backlog-app"
        New-Item -ItemType Directory -Path $customAppRoot -Force | Out-Null
        
        # Pre-create config.yaml with custom backlog path configured
        # This simulates adopter setting up config first
        $configDir = Join-Path $customAppRoot ".crucible"
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        
        $initialConfig = @"
crucible_root: ".crucible"
paths:
  backlog: "custom-backlog"
  session: .crucible/session
  workspaces: .crucible/.agent-workspaces
  prompts: .crucible/prompts
  personas: .crucible/personas
  sops: .crucible/sops
project:
  name: "Custom Backlog App"
  description: "Test App"
  default_branch: "main"
roles:
  researcher:
    model_tier: fast
  groomer:
    model_tier: fast
  architect:
    model_tier: high-capability
  reviewer:
    model_tier: high-capability
  operator:
    model_tier: fast
verification:
  quick:
    - name: test
      command: echo quick
  full:
    - name: test
      command: echo full
project_mandates:
  - rule 1
"@
        $initialConfig | Out-File -LiteralPath (Join-Path $configDir "config.yaml") -Encoding UTF8

        # Run init-project.ps1 with -Force to overwrite and respect custom config
        $null = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT `
            -ProjectRoot $customAppRoot `
            -Force `
            -WithSampleTask `
            -Language go `
            -Quiet 2>&1)
        Assert-Result -Name "custom backlog init exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE)

        # 1. Assert default backlog directory DOES NOT exist
        $defaultBacklog = Join-Path $customAppRoot ".crucible/backlog"
        Assert-Result -Name "default backlog dir absent" -Condition (-not (Test-Path $defaultBacklog)) -FailureMessage "default backlog dir was unexpectedly created"

        # 2. Assert custom backlog directory DOES exist and contains scaffold files
        $customBacklog = Join-Path $customAppRoot "custom-backlog"
        Assert-Result -Name "custom backlog dir exists" -Condition (Test-Path $customBacklog) -FailureMessage "custom backlog dir custom-backlog was not created"
        Assert-Result -Name "BACKLOG.md exists in custom path" -Condition (Test-Path (Join-Path $customBacklog "BACKLOG.md")) -FailureMessage "BACKLOG.md not found in custom backlog directory"
        Assert-Result -Name "sample task exists in custom path" -Condition (Test-Path (Join-Path $customBacklog "features/active/F-001_Hello_World.md")) -FailureMessage "sample task F-001 not found in custom backlog features/active directory"

        # 3. Assert config validation passes on custom backlog config
        $valScript = Join-Path $REPO_ROOT "powershell/validate-config.ps1"
        $valConfig = Join-Path $customAppRoot ".crucible/config.yaml"
        $valResult = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $valScript -ConfigPath $valConfig 2>&1)
        Assert-Result -Name "custom config validation exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected validate-config exit 0, got " + $LASTEXITCODE + ". Output: " + ($valResult -join "`n"))

        # 4. Assert factory_lint passes in the custom app root context (dynamic linter check)
        $linterScript = Join-Path $REPO_ROOT "scripts/factory_lint.go"
        $origCwd = Get-Location
        Set-Location -LiteralPath $customAppRoot
        $lintResult = @(go run $linterScript $REPO_ROOT 2>&1)
        Set-Location -LiteralPath $origCwd
        Assert-Result -Name "custom backlog linter exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected factory_lint exit 0, got " + $LASTEXITCODE + ". Output: " + ($lintResult -join "`n"))

        # 5. Assert factory-health checks pass using the custom backlog directory (dynamic health check)
        $healthScript = Join-Path $REPO_ROOT "powershell/factory-health.ps1"
        $healthResult = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $healthScript -ProjectRoot $customAppRoot 2>&1)
        Assert-Result -Name "custom backlog health exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected factory-health exit 0, got " + $LASTEXITCODE + ". Output: " + ($healthResult -join "`n"))
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
