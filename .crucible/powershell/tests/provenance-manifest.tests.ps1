# Tests for the provenance manifest generator in powershell/lib/install-manifest.ps1.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/install-manifest.ps1")
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
    Write-Utf8File -Path (Join-Path $Root "templates/project/.crucible/backlog/F-000.md") -Content 'template backlog'
    Write-Utf8File -Path (Join-Path $Root "docs/guide.md") -Content 'guide baseline'
    Write-Utf8File -Path (Join-Path $Root "powershell/tool.ps1") -Content 'Write-Host "baseline"'
    return Invoke-GitCommit -Repo $Root -Message "baseline"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-provenance-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Manifest maps bundle paths to LF-normalized hashes with version and source_commit" -Body {
        $framework = Join-Path $tempRoot "gen-framework"
        $commit = New-FrameworkFixture -Root $framework
        $provenance = New-ProvenanceManifest -FrameworkRoot $framework -Commit $commit

        Assert-Result -Name "manifest_version is 1" -Condition ($provenance.manifest_version -eq 1) -FailureMessage "manifest_version not 1"
        Assert-Result -Name "source_commit recorded" -Condition ($provenance.source_commit -eq $commit) -FailureMessage "source_commit mismatch"

        $names = @($provenance.files.PSObject.Properties.Name)
        Assert-Result -Name "docs/guide.md present" -Condition ($names -contains "docs/guide.md") -FailureMessage ("paths: " + ($names -join ","))
        Assert-Result -Name "powershell/tool.ps1 present" -Condition ($names -contains "powershell/tool.ps1") -FailureMessage ("paths: " + ($names -join ","))

        $expected = Get-GitFileNormalizedHash -Repo $framework -Commit $commit -Path "docs/guide.md"
        Assert-Result -Name "hash matches normalized source" -Condition ($provenance.files."docs/guide.md".hash -eq $expected) -FailureMessage "hash mismatch for docs/guide.md"
        Assert-Result -Name "hash is hex sha256" -Condition ($provenance.files."docs/guide.md".hash -match '^[0-9a-f]{64}$') -FailureMessage "hash is not a sha256 hex string"
    }

    $results += Run-Test -Name "Adopter-owned paths are excluded from the manifest" -Body {
        $framework = Join-Path $tempRoot "exclude-framework"
        $commit = New-FrameworkFixture -Root $framework
        $provenance = New-ProvenanceManifest -FrameworkRoot $framework -Commit $commit
        $names = @($provenance.files.PSObject.Properties.Name)

        # config.yaml (scaffold-derived adopter-owned) and template backlog must be absent
        Assert-Result -Name "config.yaml excluded" -Condition ($names -notcontains "config.yaml") -FailureMessage ("config.yaml leaked: " + ($names -join ","))
        Assert-Result -Name "backlog excluded" -Condition (-not ($names | Where-Object { $_ -like "backlog/*" })) -FailureMessage ("backlog leaked: " + ($names -join ","))
    }

    $results += Run-Test -Name "EOL differences hash identically (CRLF vs LF)" -Body {
        $framework = Join-Path $tempRoot "eol-framework"
        $commit = New-FrameworkFixture -Root $framework
        $provenance = New-ProvenanceManifest -FrameworkRoot $framework -Commit $commit
        $manifestHash = $provenance.files."docs/guide.md".hash

        # Write the same logical content with CRLF line endings to a working file
        $crlf = Join-Path $tempRoot "eol-working/guide.md"
        Write-Utf8File -Path $crlf -Content "guide baseline`r`n"
        $workingHash = Get-FileNormalizedHash -Path $crlf

        Assert-Result -Name "CRLF hashes equal to manifest" -Condition ($workingHash -eq $manifestHash) -FailureMessage "EOL difference produced a different hash"
    }

    $results += Run-Test -Name "Write/Read round-trips the manifest as UTF-8 without BOM" -Body {
        $framework = Join-Path $tempRoot "io-framework"
        $commit = New-FrameworkFixture -Root $framework
        $provenance = New-ProvenanceManifest -FrameworkRoot $framework -Commit $commit

        $bundleRoot = Join-Path $tempRoot "io-bundle"
        New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null
        $path = Write-ProvenanceManifest -BundleRoot $bundleRoot -ProvenanceManifest $provenance
        Assert-Result -Name "manifest written" -Condition (Test-Path -LiteralPath $path) -FailureMessage "manifest not written"

        $bytes = [System.IO.File]::ReadAllBytes($path)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Assert-Result -Name "no BOM" -Condition (-not $hasBom) -FailureMessage "manifest has a UTF-8 BOM"

        $roundTrip = Read-ProvenanceManifest -BundleRoot $bundleRoot
        Assert-Result -Name "source_commit round-trips" -Condition ($roundTrip.source_commit -eq $commit) -FailureMessage "source_commit lost on round-trip"
        Assert-Result -Name "hash round-trips" -Condition ($roundTrip.files."docs/guide.md".hash -eq $provenance.files."docs/guide.md".hash) -FailureMessage "hash lost on round-trip"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed provenance-manifest test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll provenance-manifest tests passed." -ForegroundColor Green
exit 0
