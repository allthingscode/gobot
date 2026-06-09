# Tests for crucible status --drift (the -Drift switch on factory-status.ps1).

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/install-manifest.ps1")
$STATUS_SCRIPT = Join-Path $REPO_ROOT "powershell/factory-status.ps1"
$results = @()

function Assert-Result {
    param([string]$Name, [bool]$Condition, [string]$FailureMessage)
    if (-not $Condition) {
        throw ("FAILED: " + $Name + " - " + $FailureMessage)
    }
}

function Run-Test {
    param([string]$Name, [scriptblock]$Body)
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

try {
    $results += Run-Test -Name "Pristine bundle reports zero customizations and exits zero" -Body {
        $framework = Join-Path $tempRoot "pristine-fw"
        $commit = New-FrameworkFixture -Root $framework
        $bundle = Join-Path $tempRoot "pristine-bundle"
        New-AdopterBundle -Framework $framework -BundleRoot $bundle -Commit $commit -WriteManifest

        $r = Invoke-Drift -BundleRoot $bundle -Framework $framework
        Assert-Result -Name "exit zero" -Condition ($r.ExitCode -eq 0) -FailureMessage $r.Output
        Assert-Result -Name "customized 0" -Condition ($r.Output -match 'customized:\s+0') -FailureMessage $r.Output
        Assert-Result -Name "adopter-added 0" -Condition ($r.Output -match 'adopter-added:\s+0') -FailureMessage $r.Output
        Assert-Result -Name "framework-removed 0" -Condition ($r.Output -match 'framework-removed:\s+0') -FailureMessage $r.Output
    }

    $results += Run-Test -Name "EOL-only differences stay pristine, never customized" -Body {
        $framework = Join-Path $tempRoot "eol-fw"
        $commit = New-FrameworkFixture -Root $framework
        $bundle = Join-Path $tempRoot "eol-bundle"
        New-AdopterBundle -Framework $framework -BundleRoot $bundle -Commit $commit -WriteManifest -Crlf

        $r = Invoke-Drift -BundleRoot $bundle -Framework $framework
        Assert-Result -Name "exit zero" -Condition ($r.ExitCode -eq 0) -FailureMessage $r.Output
        Assert-Result -Name "customized 0" -Condition ($r.Output -match 'customized:\s+0') -FailureMessage $r.Output
    }

    $results += Run-Test -Name "Customized file is named and command exits non-zero" -Body {
        $framework = Join-Path $tempRoot "custom-fw"
        $commit = New-FrameworkFixture -Root $framework
        $bundle = Join-Path $tempRoot "custom-bundle"
        New-AdopterBundle -Framework $framework -BundleRoot $bundle -Commit $commit -WriteManifest
        Write-Utf8File -Path (Join-Path $bundle "powershell/tool.ps1") -Content 'Write-Host "ADOPTER EDIT"'

        $r = Invoke-Drift -BundleRoot $bundle -Framework $framework
        Assert-Result -Name "exit non-zero" -Condition ($r.ExitCode -eq 1) -FailureMessage $r.Output
        Assert-Result -Name "customized 1" -Condition ($r.Output -match 'customized:\s+1') -FailureMessage $r.Output
        Assert-Result -Name "names the file" -Condition ($r.Output -match 'powershell/tool\.ps1') -FailureMessage $r.Output
    }

    $results += Run-Test -Name "Adopter-added file is classified, not customized" -Body {
        $framework = Join-Path $tempRoot "added-fw"
        $commit = New-FrameworkFixture -Root $framework
        $bundle = Join-Path $tempRoot "added-bundle"
        New-AdopterBundle -Framework $framework -BundleRoot $bundle -Commit $commit -WriteManifest
        Write-Utf8File -Path (Join-Path $bundle "docs/my-notes.md") -Content 'adopter notes'

        $r = Invoke-Drift -BundleRoot $bundle -Framework $framework
        Assert-Result -Name "exit zero (added is not customization)" -Condition ($r.ExitCode -eq 0) -FailureMessage $r.Output
        Assert-Result -Name "adopter-added 1" -Condition ($r.Output -match 'adopter-added:\s+1') -FailureMessage $r.Output
        Assert-Result -Name "names added file" -Condition ($r.Output -match 'docs/my-notes\.md') -FailureMessage $r.Output
    }

    $results += Run-Test -Name "Framework-removed file is classified" -Body {
        $framework = Join-Path $tempRoot "removed-fw"
        $commit = New-FrameworkFixture -Root $framework
        $bundle = Join-Path $tempRoot "removed-bundle"
        New-AdopterBundle -Framework $framework -BundleRoot $bundle -Commit $commit -WriteManifest
        Remove-Item -LiteralPath (Join-Path $bundle "docs/other.md") -Force

        $r = Invoke-Drift -BundleRoot $bundle -Framework $framework
        Assert-Result -Name "exit zero (removal is not customization)" -Condition ($r.ExitCode -eq 0) -FailureMessage $r.Output
        Assert-Result -Name "framework-removed 1" -Condition ($r.Output -match 'framework-removed:\s+1') -FailureMessage $r.Output
        Assert-Result -Name "names removed file" -Condition ($r.Output -match 'docs/other\.md') -FailureMessage $r.Output
    }

    $results += Run-Test -Name "Backfills from crucible_install_commit when no manifest is present" -Body {
        $framework = Join-Path $tempRoot "backfill-fw"
        $commit = New-FrameworkFixture -Root $framework
        $bundle = Join-Path $tempRoot "backfill-bundle"
        New-AdopterBundle -Framework $framework -BundleRoot $bundle -Commit $commit
        # No manifest written. Customize a file so backfill must report it.
        Write-Utf8File -Path (Join-Path $bundle "docs/guide.md") -Content 'adopter changed guide'

        Assert-Result -Name "no manifest exists" -Condition (-not (Test-Path -LiteralPath (Join-Path $bundle "install-provenance.json"))) -FailureMessage "manifest unexpectedly present"
        $r = Invoke-Drift -BundleRoot $bundle -Framework $framework
        Assert-Result -Name "backfill notice" -Condition ($r.Output -match 'backfilling from crucible_install_commit') -FailureMessage $r.Output
        Assert-Result -Name "customized 1" -Condition ($r.Output -match 'customized:\s+1') -FailureMessage $r.Output
        Assert-Result -Name "exit non-zero" -Condition ($r.ExitCode -eq 1) -FailureMessage $r.Output
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
