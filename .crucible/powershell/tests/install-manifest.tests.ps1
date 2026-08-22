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

$expectedScaffoldCount = @(git -C $REPO_ROOT ls-files templates/project/.crucible).Count

try {
    # Guards the counts below against vacuous green: if the scaffold tree ever reads as
    # empty, every count comparison would agree at 0 and prove nothing.
    $results += Run-Test -Name "Expected scaffold count derived from framework tree is non-zero" -Body {
        Assert-Result -Name "derived scaffold count non-zero" -Condition ($expectedScaffoldCount -gt 0) -FailureMessage "Failed to derive scaffold count from framework via git ls-files templates/project/.crucible"
    }

    $results += Run-Test -Name "Manifest loads and helper functions are exposed" -Body {
        $manifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT
        Assert-Result -Name "scaffold source" -Condition ($manifest.scaffold_source -eq "templates/project/.crucible") -FailureMessage "unexpected scaffold_source"
        Assert-Result -Name "root manifest file" -Condition (@($manifest.root_files) -contains "install-manifest.json") -FailureMessage "install-manifest.json should be installed as runtime content"
        foreach ($functionName in "Get-InstallManifest", "Get-FrameworkOwnedFiles", "Convert-FrameworkPathToAdopter", "Test-AdopterOwnedPath", "Test-NestedCrucibleRuntimePath", "Test-ScaffoldTemplateComplete") {
            Assert-Result -Name "function $functionName" -Condition ($null -ne (Get-Command $functionName -ErrorAction SilentlyContinue)) -FailureMessage "missing helper function"
        }
    }

    $results += Run-Test -Name "Get-FrameworkOwnedFiles walk vs AtCommit HEAD parity for scaffold snapshot" -Body {
        $manifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT
        $scaffoldPrefix = (ConvertTo-ManifestRelativePath -Path ([string]$manifest.scaffold_source)).TrimEnd("/") + "/"
        $walkFiles = @(Get-FrameworkOwnedFiles -FrameworkRoot $REPO_ROOT | Where-Object { $_.StartsWith($scaffoldPrefix, [System.StringComparison]::OrdinalIgnoreCase) })
        $gitFiles = @(Get-FrameworkOwnedFiles -FrameworkRoot $REPO_ROOT -AtCommit "HEAD" | Where-Object { $_.StartsWith($scaffoldPrefix, [System.StringComparison]::OrdinalIgnoreCase) })
        Assert-Result -Name "scaffold walk count" -Condition ($walkFiles.Count -eq $expectedScaffoldCount) -FailureMessage ("expected " + $expectedScaffoldCount + " scaffold walk files, got " + $walkFiles.Count)
        Assert-Result -Name "scaffold git count" -Condition ($gitFiles.Count -eq $walkFiles.Count) -FailureMessage ("expected scaffold git count " + $walkFiles.Count + ", got " + $gitFiles.Count)
        $diff = @(Compare-Object -ReferenceObject $walkFiles -DifferenceObject $gitFiles)
        Assert-Result -Name "walk and git scaffold files match" -Condition ($null -eq $diff -or $diff.Count -eq 0) -FailureMessage ("scaffold file mismatch between walk and git: " + ($diff | Format-Table | Out-String))
    }

    $results += Run-Test -Name "Fresh install ships scaffold snapshot and self-hosts downstream init" -Body {
        $gen1Root = Join-Path $tempRoot "gen1-adopter"
        $script = Join-Path $REPO_ROOT "powershell/init-project.ps1"
        $output1 = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $script -ProjectRoot $gen1Root -ProjectName "Gen1 Adopter" -Description "Gen1" -Language go -Quiet 2>&1)
        Assert-Result -Name "gen1 install exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("gen1 install failed: " + ($output1 -join "`n"))

        $snapshotConfigFile = Join-Path $gen1Root ".crucible\templates\project\.crucible\config.yaml"
        Assert-Result -Name "snapshot config.yaml exists" -Condition (Test-Path -LiteralPath $snapshotConfigFile) -FailureMessage "fresh install missing .crucible/templates/project/.crucible/config.yaml"

        $scaffoldSnapshotDir = Join-Path $gen1Root ".crucible\templates\project\.crucible"
        $scaffoldFiles = @(Get-ChildItem -LiteralPath $scaffoldSnapshotDir -Force -Recurse -File)
        Assert-Result -Name "all scaffold files present" -Condition ($scaffoldFiles.Count -eq $expectedScaffoldCount) -FailureMessage ("expected " + $expectedScaffoldCount + " scaffold files in snapshot, got " + $scaffoldFiles.Count)

        # Self-hosting check (Generation 2 from Generation 1's bundled installer)
        $gen2Root = Join-Path $tempRoot "gen2-adopter"
        $gen1InitScript = Join-Path $gen1Root ".crucible\powershell\init-project.ps1"
        $output2 = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $gen1InitScript -ProjectRoot $gen2Root -ProjectName "Gen2 Adopter" -Description "Gen2" -Language go -Quiet 2>&1)
        Assert-Result -Name "gen2 install exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("gen2 self-hosting install failed: " + ($output2 -join "`n"))

        $gen2Config = Join-Path $gen2Root ".crucible\config.yaml"
        Assert-Result -Name "gen2 config.yaml exists" -Condition (Test-Path -LiteralPath $gen2Config) -FailureMessage "gen2 install missing .crucible/config.yaml"
        $gen2SnapshotConfig = Join-Path $gen2Root ".crucible\templates\project\.crucible\config.yaml"
        Assert-Result -Name "gen2 snapshot config.yaml exists" -Condition (Test-Path -LiteralPath $gen2SnapshotConfig) -FailureMessage "gen2 install missing nested scaffold snapshot"
    }

    $results += Run-Test -Name "Nested .crucible runtime directories remain excluded from shipping" -Body {
        $junkDir = Join-Path $REPO_ROOT "powershell\.crucible"
        $junkFile = Join-Path $junkDir "junk.txt"
        New-Item -ItemType Directory -Path $junkDir -Force | Out-Null
        Set-Content -LiteralPath $junkFile -Value "runtime junk" -Encoding UTF8
        try {
            $ownedFiles = @(Get-FrameworkOwnedFiles -FrameworkRoot $REPO_ROOT)
            Assert-Result -Name "junk excluded from Get-FrameworkOwnedFiles" -Condition ($ownedFiles -notcontains "powershell/.crucible/junk.txt") -FailureMessage "expected powershell/.crucible/junk.txt to be excluded from framework-owned files"

            $guardInstallRoot = Join-Path $tempRoot "guard-install-check"
            $script = Join-Path $REPO_ROOT "powershell/init-project.ps1"
            $output = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $script -ProjectRoot $guardInstallRoot -ProjectName "Guard Check" -Quiet 2>&1)
            Assert-Result -Name "guard install exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("guard check install failed: " + ($output -join "`n"))

            $installedJunkPath = Join-Path $guardInstallRoot ".crucible/powershell/.crucible/junk.txt"
            Assert-Result -Name "junk excluded from fresh install" -Condition (-not (Test-Path -LiteralPath $installedJunkPath)) -FailureMessage "expected powershell/.crucible/junk.txt to not be copied during initialization"
        } finally {
            Remove-Item -LiteralPath $junkFile -Force -ErrorAction SilentlyContinue
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

    $results += Run-Test -Name "Test-ScaffoldTemplateComplete validates scaffold source integrity" -Body {
        $check = Test-ScaffoldTemplateComplete -FrameworkRoot $REPO_ROOT
        Assert-Result -Name "framework repo scaffold is complete" -Condition ($check.IsComplete -eq $true) -FailureMessage ("expected complete scaffold in framework repo, missing: " + ($check.MissingFiles -join ", "))
        Assert-Result -Name "framework repo scaffold is authoritative" -Condition ($check.IsAuthoritative -eq $true) -FailureMessage "expected framework repo scaffold check to be authoritative"
        Assert-Result -Name "framework repo scaffold source is authoritative" -Condition ($check.Source -in @("provenance", "git")) -FailureMessage ("expected framework repo scaffold source to be provenance or git, got " + $check.Source)

        $corruptTemp = Join-Path $tempRoot "corrupt-scaffold"
        New-Item -ItemType Directory -Path (Join-Path $corruptTemp "templates/project/.crucible") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $corruptTemp "templates/project/.crucible/backlog") -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $REPO_ROOT "install-manifest.json") -Destination (Join-Path $corruptTemp "install-manifest.json") -Force
        Set-Content -LiteralPath (Join-Path $corruptTemp "templates/project/.crucible/README.md") -Value "only readme" -Encoding UTF8

        $corruptCheck = Test-ScaffoldTemplateComplete -FrameworkRoot $corruptTemp
        Assert-Result -Name "corrupt scaffold reported as non-authoritative" -Condition ($corruptCheck.IsAuthoritative -eq $false) -FailureMessage "expected scaffold in temp directory without git or provenance to be non-authoritative"
        Assert-Result -Name "corrupt scaffold source is disk-walk" -Condition ($corruptCheck.Source -eq "disk-walk") -FailureMessage ("expected source disk-walk, got " + $corruptCheck.Source)

        # A disk walk cannot detect a gutted scaffold: expected is derived from the same
        # directory being tested. Pair the gutted scaffold with a provenance manifest so
        # the file comparison has an independent expectation and must do real work.
        $provTemp = Join-Path $tempRoot "provenance-scaffold"
        New-Item -ItemType Directory -Path (Join-Path $provTemp "templates/project/.crucible/backlog") -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $REPO_ROOT "install-manifest.json") -Destination (Join-Path $provTemp "install-manifest.json") -Force
        Set-Content -LiteralPath (Join-Path $provTemp "templates/project/.crucible/README.md") -Value "only readme" -Encoding UTF8

        $realManifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT
        $scaffoldPrefix = (([string]$realManifest.scaffold_source).TrimEnd("/")) + "/"
        $realScaffold = @((Get-ExpectedScaffoldFiles -FrameworkRoot $REPO_ROOT -Manifest $realManifest).Files)
        $provFiles = New-Object PSObject
        foreach ($rel in $realScaffold) {
            Add-Member -InputObject $provFiles -MemberType NoteProperty -Name ($scaffoldPrefix + $rel) -Value "0000000000000000000000000000000000000000"
        }
        $provManifest = New-Object PSObject
        Add-Member -InputObject $provManifest -MemberType NoteProperty -Name "files" -Value $provFiles
        Write-ProvenanceManifest -BundleRoot $provTemp -ProvenanceManifest $provManifest | Out-Null

        $provCheck = Test-ScaffoldTemplateComplete -FrameworkRoot $provTemp
        Assert-Result -Name "provenance-backed check uses provenance source" -Condition ($provCheck.Source -eq "provenance") -FailureMessage ("expected source provenance, got " + $provCheck.Source)
        Assert-Result -Name "provenance-backed check is authoritative" -Condition ($provCheck.IsAuthoritative -eq $true) -FailureMessage "expected provenance-backed scaffold check to be authoritative"
        Assert-Result -Name "gutted scaffold detected as incomplete" -Condition ($provCheck.IsComplete -eq $false) -FailureMessage "gutted scaffold with a provenance manifest was reported as complete"
        Assert-Result -Name "gutted scaffold reports missing files" -Condition ($provCheck.MissingFiles.Count -gt 1) -FailureMessage ("expected more than one missing file, got " + $provCheck.MissingFiles.Count)
        Assert-Result -Name "gutted scaffold expected count matches framework scaffold" -Condition ($provCheck.ExpectedCount -eq $realScaffold.Count) -FailureMessage ("expected " + $realScaffold.Count + " expected files, got " + $provCheck.ExpectedCount)
        Assert-Result -Name "gutted scaffold on-disk count is 1" -Condition ($provCheck.OnDiskCount -eq 1) -FailureMessage ("expected 1 file on disk, got " + $provCheck.OnDiskCount)

        # The hardcoded backlog/ directory check is the only guard that survives a pure
        # disk walk, so it needs a fixture that actually omits the directory.
        $noBacklogTemp = Join-Path $tempRoot "no-backlog-scaffold"
        New-Item -ItemType Directory -Path (Join-Path $noBacklogTemp "templates/project/.crucible") -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $REPO_ROOT "install-manifest.json") -Destination (Join-Path $noBacklogTemp "install-manifest.json") -Force
        Set-Content -LiteralPath (Join-Path $noBacklogTemp "templates/project/.crucible/README.md") -Value "only readme" -Encoding UTF8

        $noBacklogCheck = Test-ScaffoldTemplateComplete -FrameworkRoot $noBacklogTemp
        Assert-Result -Name "missing backlog directory detected as incomplete" -Condition ($noBacklogCheck.IsComplete -eq $false) -FailureMessage "scaffold without a backlog directory was reported as complete"
        Assert-Result -Name "missing backlog directory reported by name" -Condition ($noBacklogCheck.MissingFiles -contains "backlog/") -FailureMessage ("expected backlog/ in MissingFiles, got: " + ($noBacklogCheck.MissingFiles -join ", "))

        # An absent scaffold directory yields no expectation from any source, so it reports
        # "none" rather than claiming a disk walk that never ran.
        $noScaffoldTemp = Join-Path $tempRoot "no-scaffold"
        New-Item -ItemType Directory -Path $noScaffoldTemp -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $REPO_ROOT "install-manifest.json") -Destination (Join-Path $noScaffoldTemp "install-manifest.json") -Force

        $noScaffoldCheck = Test-ScaffoldTemplateComplete -FrameworkRoot $noScaffoldTemp
        Assert-Result -Name "missing scaffold directory is incomplete" -Condition ($noScaffoldCheck.IsComplete -eq $false) -FailureMessage "missing scaffold directory was reported as complete"
        Assert-Result -Name "missing scaffold directory source is none" -Condition ($noScaffoldCheck.Source -eq "none") -FailureMessage ("expected source none, got " + $noScaffoldCheck.Source)
        Assert-Result -Name "missing scaffold directory is non-authoritative" -Condition ($noScaffoldCheck.IsAuthoritative -eq $false) -FailureMessage "expected missing scaffold directory to be non-authoritative"
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
