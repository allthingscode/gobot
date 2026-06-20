# Tests for crucible status --drift (the -Drift switch on factory-status.ps1).

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/install-manifest.ps1")
$STATUS_SCRIPT = Join-Path $REPO_ROOT "powershell/factory-status.ps1"
$results = @()







function Write-Utf8File {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-GitCommit {
    param([Parameter(Mandatory=$true)][string]$Repo, [Parameter(Mandatory=$true)][string]$Message)
    git -C $Repo add -A | Out-Null
    git -C $Repo -c user.name="Crucible Tests" -c user.email="tests@example.invalid" commit -m $Message --quiet | Out-Null
    return ((git -C $Repo rev-parse HEAD) | Out-String).Trim()
}

function New-FrameworkFixture {
    param([Parameter(Mandatory=$true)][string]$Root)
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    git -C $Root init --quiet | Out-Null
    git -C $Root config core.autocrlf false | Out-Null
    git -C $Root config core.safecrlf false | Out-Null
    Write-Utf8File -Path (Join-Path $Root "install-manifest.json") -Content @'
{
  "scaffold_source": "templates/project/.crucible",
  "root_files": ["install-manifest.json"],
  "copied_dirs": ["docs", "powershell", "templates"],
  "adopter_owned_excludes": ["config.yaml", "backlog/**", "session/**", "research/**", ".gemini/**", ".private/**", ".agent-workspaces/**"]
}
'@
    Write-Utf8File -Path (Join-Path $Root "templates/project/.crucible/config.yaml") -Content 'project: fixture'
    Write-Utf8File -Path (Join-Path $Root "templates/project/.crucible/README.md") -Content 'readme baseline'
    Write-Utf8File -Path (Join-Path $Root "docs/guide.md") -Content 'guide baseline'
    Write-Utf8File -Path (Join-Path $Root "docs/other.md") -Content 'other baseline'
    Write-Utf8File -Path (Join-Path $Root "powershell/tool.ps1") -Content 'Write-Host "baseline"'
    return Invoke-GitCommit -Repo $Root -Message "baseline"
}

function New-AdopterBundle {
    param(
        [Parameter(Mandatory=$true)][string]$Framework,
        [Parameter(Mandatory=$true)][string]$BundleRoot,
        [Parameter(Mandatory=$true)][string]$Commit,
        [switch]$WriteManifest,
        [switch]$Crlf
    )
    New-Item -ItemType Directory -Path $BundleRoot -Force | Out-Null
    $manifest = Get-InstallManifest -FrameworkRoot $Framework
    foreach ($entry in @(Get-ProvenanceBundlePaths -FrameworkRoot $Framework -Manifest $manifest -Commit $Commit)) {
        $content = Get-GitFileContent -Repo $Framework -Commit $Commit -Path $entry.SourcePath
        if ($null -eq $content) { continue }
        if ($Crlf) { $content = ($content -replace "`r`n", "`n") -replace "`n", "`r`n" }
        Write-Utf8File -Path (Join-Path $BundleRoot $entry.AdopterPath) -Content $content
    }
    Write-Utf8File -Path (Join-Path $BundleRoot "config.yaml") -Content ("project: adopter`r`ncrucible_install_commit: `"" + $Commit + "`"")
    if ($WriteManifest) {
        $provenance = New-ProvenanceManifest -FrameworkRoot $Framework -Commit $Commit
        $null = Write-ProvenanceManifest -BundleRoot $BundleRoot -ProvenanceManifest $provenance
    }
}

function Invoke-Drift {
    param(
        [Parameter(Mandatory=$true)][string]$BundleRoot,
        [Parameter(Mandatory=$true)][string]$Framework
    )
    $callArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $STATUS_SCRIPT, "-Drift", "-BundleRoot", $BundleRoot, "-FrameworkSource", $Framework)
    $output = @(& (Get-PwshCommand) @callArgs 2>&1)
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join "`n")
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-drift-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$script:SharedFrameworkPath = $null
$script:SharedFrameworkCommit = $null
$script:SharedPristineBundlePath = $null
$script:SharedCrlfBundlePath = $null
$script:SharedNoManifestBundlePath = $null

function Get-SharedFramework {
    if ($null -eq $script:SharedFrameworkPath) {
        $fwPath = Join-Path $tempRoot "shared-fw"
        $script:SharedFrameworkCommit = New-FrameworkFixture -Root $fwPath
        $script:SharedFrameworkPath = $fwPath
    }
    return [pscustomobject]@{
        Path = $script:SharedFrameworkPath
        Commit = $script:SharedFrameworkCommit
    }
}

function Get-SharedPristineBundle {
    if ($null -eq $script:SharedPristineBundlePath) {
        $fw = Get-SharedFramework
        $bundlePath = Join-Path $tempRoot "shared-bundle"
        New-AdopterBundle -Framework $fw.Path -BundleRoot $bundlePath -Commit $fw.Commit -WriteManifest
        $script:SharedPristineBundlePath = $bundlePath
    }
    return $script:SharedPristineBundlePath
}

function Get-SharedCrlfBundle {
    if ($null -eq $script:SharedCrlfBundlePath) {
        $fw = Get-SharedFramework
        $bundlePath = Join-Path $tempRoot "shared-crlf-bundle"
        New-AdopterBundle -Framework $fw.Path -BundleRoot $bundlePath -Commit $fw.Commit -WriteManifest -Crlf
        $script:SharedCrlfBundlePath = $bundlePath
    }
    return $script:SharedCrlfBundlePath
}

function Get-SharedNoManifestBundle {
    if ($null -eq $script:SharedNoManifestBundlePath) {
        $fw = Get-SharedFramework
        $bundlePath = Join-Path $tempRoot "shared-nomanifest-bundle"
        New-AdopterBundle -Framework $fw.Path -BundleRoot $bundlePath -Commit $fw.Commit
        $script:SharedNoManifestBundlePath = $bundlePath
    }
    return $script:SharedNoManifestBundlePath
}

try {
    $results += Run-Test -Name "Pristine bundle reports zero customizations and exits zero" -Body {
        $fw = Get-SharedFramework
        $bundle = Get-SharedPristineBundle

        $r = Invoke-Drift -BundleRoot $bundle -Framework $fw.Path
        Assert-Result -Name "exit zero" -Condition ($r.ExitCode -eq 0) -FailureMessage $r.Output
        Assert-Result -Name "customized 0" -Condition ($r.Output -match 'customized:\s+0') -FailureMessage $r.Output
        Assert-Result -Name "adopter-added 0" -Condition ($r.Output -match 'adopter-added:\s+0') -FailureMessage $r.Output
        Assert-Result -Name "framework-removed 0" -Condition ($r.Output -match 'framework-removed:\s+0') -FailureMessage $r.Output
    }

    $results += Run-Test -Name "EOL-only differences stay pristine, never customized" -Body {
        $fw = Get-SharedFramework
        $bundle = Get-SharedCrlfBundle

        $r = Invoke-Drift -BundleRoot $bundle -Framework $fw.Path
        Assert-Result -Name "exit zero" -Condition ($r.ExitCode -eq 0) -FailureMessage $r.Output
        Assert-Result -Name "customized 0" -Condition ($r.Output -match 'customized:\s+0') -FailureMessage $r.Output
    }

    $results += Run-Test -Name "Customized file is named and command exits non-zero" -Body {
        $fw = Get-SharedFramework
        $bundle = Join-Path $tempRoot "custom-bundle"
        Copy-Item -Path (Get-SharedPristineBundle) -Destination $bundle -Recurse
        Write-Utf8File -Path (Join-Path $bundle "powershell/tool.ps1") -Content 'Write-Host "ADOPTER EDIT"'

        $r = Invoke-Drift -BundleRoot $bundle -Framework $fw.Path
        Assert-Result -Name "exit non-zero" -Condition ($r.ExitCode -eq 1) -FailureMessage $r.Output
        Assert-Result -Name "customized 1" -Condition ($r.Output -match 'customized:\s+1') -FailureMessage $r.Output
        Assert-Result -Name "names the file" -Condition ($r.Output -match 'powershell/tool\.ps1') -FailureMessage $r.Output
    }

    $results += Run-Test -Name "Adopter-added file is classified, not customized" -Body {
        $fw = Get-SharedFramework
        $bundle = Join-Path $tempRoot "added-bundle"
        Copy-Item -Path (Get-SharedPristineBundle) -Destination $bundle -Recurse
        Write-Utf8File -Path (Join-Path $bundle "docs/my-notes.md") -Content 'adopter notes'

        $r = Invoke-Drift -BundleRoot $bundle -Framework $fw.Path
        Assert-Result -Name "exit zero (added is not customization)" -Condition ($r.ExitCode -eq 0) -FailureMessage $r.Output
        Assert-Result -Name "adopter-added 1" -Condition ($r.Output -match 'adopter-added:\s+1') -FailureMessage $r.Output
        Assert-Result -Name "names added file" -Condition ($r.Output -match 'docs/my-notes\.md') -FailureMessage $r.Output
    }

    $results += Run-Test -Name "Framework-removed file is classified" -Body {
        $fw = Get-SharedFramework
        $bundle = Join-Path $tempRoot "removed-bundle"
        Copy-Item -Path (Get-SharedPristineBundle) -Destination $bundle -Recurse
        Remove-Item -LiteralPath (Join-Path $bundle "docs/other.md") -Force

        $r = Invoke-Drift -BundleRoot $bundle -Framework $fw.Path
        Assert-Result -Name "exit zero (removal is not customization)" -Condition ($r.ExitCode -eq 0) -FailureMessage $r.Output
        Assert-Result -Name "framework-removed 1" -Condition ($r.Output -match 'framework-removed:\s+1') -FailureMessage $r.Output
        Assert-Result -Name "names removed file" -Condition ($r.Output -match 'docs/other\.md') -FailureMessage $r.Output
    }

    $results += Run-Test -Name "Backfills from crucible_install_commit when no manifest is present" -Body {
        $fw = Get-SharedFramework
        $bundle = Join-Path $tempRoot "backfill-bundle"
        Copy-Item -Path (Get-SharedNoManifestBundle) -Destination $bundle -Recurse
        # No manifest written. Customize a file so backfill must report it.
        Write-Utf8File -Path (Join-Path $bundle "docs/guide.md") -Content 'adopter changed guide'

        Assert-Result -Name "no manifest exists" -Condition (-not (Test-Path -LiteralPath (Join-Path $bundle "install-provenance.json"))) -FailureMessage "manifest unexpectedly present"
        $r = Invoke-Drift -BundleRoot $bundle -Framework $fw.Path
        Assert-Result -Name "backfill notice" -Condition ($r.Output -match 'backfilling from crucible_install_commit') -FailureMessage $r.Output
        Assert-Result -Name "customized 1" -Condition ($r.Output -match 'customized:\s+1') -FailureMessage $r.Output
        Assert-Result -Name "exit non-zero" -Condition ($r.ExitCode -eq 1) -FailureMessage $r.Output
    }

    $results += Run-Test -Name "Fails backfill if install commit is missing in the framework source" -Body {
        $fw = Get-SharedFramework

        $wrongFw = Join-Path $tempRoot "wrong-fw"
        New-Item -ItemType Directory -Path $wrongFw -Force | Out-Null
        git -C $wrongFw init --quiet | Out-Null
        Write-Utf8File -Path (Join-Path $wrongFw "install-manifest.json") -Content @'
{
  "scaffold_source": "templates/project/.crucible",
  "root_files": ["install-manifest.json"],
  "copied_dirs": ["docs", "powershell", "templates"],
  "adopter_owned_excludes": ["config.yaml", "backlog/**", "session/**", "research/**", ".gemini/**", ".private/**", ".agent-workspaces/**"]
}
'@
        git -C $wrongFw add -A | Out-Null
        git -C $wrongFw -c user.name="Crucible Tests" -c user.email="tests@example.invalid" commit -m "init" --quiet | Out-Null

        $bundle = Join-Path $tempRoot "missing-commit-bundle"
        Copy-Item -Path (Get-SharedNoManifestBundle) -Destination $bundle -Recurse

        $r = Invoke-Drift -BundleRoot $bundle -Framework $wrongFw
        Assert-Result -Name "exit non-zero on missing commit" -Condition ($r.ExitCode -eq 1) -FailureMessage $r.Output
        Assert-Result -Name "error message shows commit missing" -Condition ($r.Output -match 'not present in the framework source') -FailureMessage $r.Output
    }

    $results += Run-Test -Name "Excludes gitignored files and install-provenance.json from drift classification" -Body {
        $fw = Get-SharedFramework

        $adopterRoot = Join-Path $tempRoot "ignored-adopter-root"
        New-Item -ItemType Directory -Path $adopterRoot -Force | Out-Null
        $bundle = Join-Path $adopterRoot "ignored-bundle"
        Copy-Item -Path (Get-SharedPristineBundle) -Destination $bundle -Recurse

        git -C $adopterRoot init --quiet | Out-Null
        git -C $adopterRoot config core.autocrlf false | Out-Null
        git -C $adopterRoot config core.safecrlf false | Out-Null
        Write-Utf8File -Path (Join-Path $adopterRoot ".gitignore") -Content "ignored-bundle/docs/ignored_file.md"
        Write-Utf8File -Path (Join-Path $bundle "docs/ignored_file.md") -Content "should be ignored"

        $r = Invoke-Drift -BundleRoot $bundle -Framework $fw.Path
        Assert-Result -Name "exit zero" -Condition ($r.ExitCode -eq 0) -FailureMessage $r.Output
        Assert-Result -Name "adopter-added 0" -Condition ($r.Output -match 'adopter-added:\s+0') -FailureMessage $r.Output
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed status-drift test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll status-drift tests passed." -ForegroundColor Green
exit 0
