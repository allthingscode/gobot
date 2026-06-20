# Smoke tests for powershell/init-project.ps1 (Config and Versioning).

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
    $results += Run-Test -Name "Configures language presets correctly" -Body {
        foreach ($lang in 'go','node','python','rust') {
            $langRoot = Join-Path $tempRoot "lang-$lang"
            $null = @(Invoke-InitScript `
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
        $null = @(Invoke-InitScript `
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
        $null = @(Invoke-InitScript `
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

    $results += Run-Test -Name "Default install writes provenance when skip env var is unset" -Body {
        $provenanceRoot = Join-Path $tempRoot "default-provenance-app"
        $previousSkip = $env:CRUCIBLE_SKIP_PROVENANCE
        Remove-Item Env:\CRUCIBLE_SKIP_PROVENANCE -ErrorAction SilentlyContinue
        try {
            $outputLines = @(Invoke-InitScript `
                -ProjectRoot $provenanceRoot `
                -ProjectName "Default Provenance Test" `
                -Quiet 2>&1)
            $output = $outputLines -join "`n"
            Assert-Result -Name "default provenance install exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)
        } finally {
            if ($null -ne $previousSkip) {
                $env:CRUCIBLE_SKIP_PROVENANCE = $previousSkip
            } else {
                Remove-Item Env:\CRUCIBLE_SKIP_PROVENANCE -ErrorAction SilentlyContinue
            }
        }

        $bundleRoot = Join-Path $provenanceRoot ".crucible"
        $manifestPath = Join-Path $bundleRoot "install-manifest.json"
        $provenancePath = Join-Path $bundleRoot "install-provenance.json"
        Assert-Result -Name "install manifest written by default" -Condition (Test-Path -LiteralPath $manifestPath) -FailureMessage "install-manifest.json was not written by default install"
        Assert-Result -Name "install provenance written by default" -Condition (Test-Path -LiteralPath $provenancePath) -FailureMessage "install-provenance.json was not written when CRUCIBLE_SKIP_PROVENANCE was unset"

        $provenance = Get-Content -LiteralPath $provenancePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Result -Name "provenance source commit stamped" -Condition ($provenance.source_commit -match '^[0-9a-f]{40}$') -FailureMessage "install-provenance.json did not record a 40-char source_commit"
        Assert-Result -Name "provenance file hashes present" -Condition (@($provenance.files.PSObject.Properties).Count -gt 0) -FailureMessage "install-provenance.json did not record any managed file hashes"
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

        $outputLines = @(Invoke-InitScript `
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
            $secondOutput = @(Invoke-InitScript `
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
        $outputLines = @(Invoke-InitScript -AsSubprocess `
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
        $outputLines = @(Invoke-InitScript -AsSubprocess `
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
        $outputLines = @(Invoke-InitScript -AsSubprocess `
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
        $null = @(Invoke-InitScript `
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
        $valResult = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $valScript -ConfigPath $valConfig 2>&1)
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
        $healthResult = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $healthScript -ProjectRoot $customAppRoot 2>&1)
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
