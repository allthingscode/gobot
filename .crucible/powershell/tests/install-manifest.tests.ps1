# Tests for the shared install manifest helper.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$HELPER = Join-Path $REPO_ROOT "powershell/lib/install-manifest.ps1"
. $HELPER

$results = @()







$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-manifest-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Manifest loads and helper functions are exposed" -Body {
        $manifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT
        Assert-Result -Name "scaffold source" -Condition ($manifest.scaffold_source -eq "templates/project/.crucible") -FailureMessage "unexpected scaffold_source"
        Assert-Result -Name "root manifest file" -Condition (@($manifest.root_files) -contains "install-manifest.json") -FailureMessage "install-manifest.json should be installed as runtime content"
        foreach ($functionName in "Get-InstallManifest", "Get-FrameworkOwnedFiles", "Convert-FrameworkPathToAdopter", "Test-AdopterOwnedPath") {
            Assert-Result -Name "function $functionName" -Condition ($null -ne (Get-Command $functionName -ErrorAction SilentlyContinue)) -FailureMessage "missing helper function"
        }
    }

    $results += Run-Test -Name "Framework-owned files map to files produced by a fresh install" -Body {
        $installRoot = Join-Path $tempRoot "manifest-install"
        $script = Join-Path $REPO_ROOT "powershell/init-project.ps1"
        $output = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $script -ProjectRoot $installRoot -ProjectName "Manifest Test" -Quiet 2>&1)
        Assert-Result -Name "install exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("install failed: " + ($output -join "`n"))

        $manifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT
        $ownedFiles = @(Get-FrameworkOwnedFiles -FrameworkRoot $REPO_ROOT)
        Assert-Result -Name "owned files nonempty" -Condition ($ownedFiles.Count -gt 20) -FailureMessage "expected framework-owned files"
        foreach ($sourcePath in $ownedFiles) {
            $adopterPath = Convert-FrameworkPathToAdopter -SourcePath $sourcePath -Manifest $manifest
            $installedPath = Join-Path (Join-Path $installRoot ".crucible") $adopterPath
            Assert-Result -Name "installed $adopterPath" -Condition (Test-Path -LiteralPath $installedPath) -FailureMessage ("fresh install missing mapped file " + $adopterPath)
        }
    }

    $results += Run-Test -Name "Framework-development-only tests are excluded from shipping" -Body {
        $ownedFiles = @(Get-FrameworkOwnedFiles -FrameworkRoot $REPO_ROOT)
        $devOnlyTest = "powershell/tests/examples-mirror-sync.tests.ps1"
        Assert-Result -Name "excluded from Get-FrameworkOwnedFiles" -Condition ($ownedFiles -notcontains $devOnlyTest) -FailureMessage "expected examples-mirror-sync.tests.ps1 to be excluded from framework-owned files"

        $installRoot = Join-Path $tempRoot "manifest-install-check"
        $script = Join-Path $REPO_ROOT "powershell/init-project.ps1"
        $output = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $script -ProjectRoot $installRoot -ProjectName "Exclusion Check" -Quiet 2>&1)
        Assert-Result -Name "install exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("install failed: " + ($output -join "`n"))

        $installedDevTestPath = Join-Path $installRoot ".crucible/powershell/tests/examples-mirror-sync.tests.ps1"
        Assert-Result -Name "excluded from fresh install" -Condition (-not (Test-Path -LiteralPath $installedDevTestPath)) -FailureMessage "expected examples-mirror-sync.tests.ps1 to not be copied during initialization"
    }

    $results += Run-Test -Name "Manifest path mapping covers scaffold and copied dirs" -Body {
        $manifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT
        Assert-Result -Name "scaffold mapping" -Condition ((Convert-FrameworkPathToAdopter -SourcePath "templates/project/.crucible/README.md" -Manifest $manifest) -eq "README.md") -FailureMessage "scaffold path did not flatten"
        Assert-Result -Name "root file mapping" -Condition ((Convert-FrameworkPathToAdopter -SourcePath "install-manifest.json" -Manifest $manifest) -eq "install-manifest.json") -FailureMessage "root file path did not map into installed bundle root"
        foreach ($dir in @($manifest.copied_dirs)) {
            $source = ([string]$dir).TrimEnd("/") + "/example.txt"
            $expected = $source
            Assert-Result -Name "copied dir $dir" -Condition ((Convert-FrameworkPathToAdopter -SourcePath $source -Manifest $manifest) -eq $expected) -FailureMessage "copied dir mapping changed"
        }
    }

    $results += Run-Test -Name "Adopter-owned excludes match only protected paths" -Body {
        $manifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT
        foreach ($excluded in @("config.yaml", "backlog/F-001.md", "session/run.log", "research/notes.md", ".gemini/cache", ".private/secret", ".agent-workspaces/wt/file.txt")) {
            Assert-Result -Name "excluded $excluded" -Condition (Test-AdopterOwnedPath -RelativePath $excluded -Manifest $manifest) -FailureMessage "expected adopter-owned match"
        }
        foreach ($included in @("README.md", "docs/updating.md", "powershell/factory.ps1", "prompts/README.md")) {
            Assert-Result -Name "included $included" -Condition (-not (Test-AdopterOwnedPath -RelativePath $included -Manifest $manifest)) -FailureMessage "unexpected adopter-owned match"
        }
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed install manifest test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll install manifest tests passed." -ForegroundColor Green
exit 0
