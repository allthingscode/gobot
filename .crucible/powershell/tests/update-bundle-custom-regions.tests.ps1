# Tests for powershell/update-bundle.ps1 (custom regions and non-ASCII).

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$SCRIPT = Join-Path $REPO_ROOT "powershell/update-bundle.ps1"
$results = @()

function Write-Utf8File {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Content | Out-File -LiteralPath $Path -Encoding UTF8
}

function Invoke-GitCommit {
    param([Parameter(Mandatory=$true)][string]$Repo, [Parameter(Mandatory=$true)][string]$Message)
    git -C $Repo add install-manifest.json templates docs powershell | Out-Null
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

function Copy-FrameworkToAdopter {
    param(
        [Parameter(Mandatory=$true)][string]$Framework,
        [Parameter(Mandatory=$true)][string]$Adopter,
        [Parameter(Mandatory=$true)][string]$Commit
    )
    New-Item -ItemType Directory -Path (Join-Path $Adopter ".crucible") -Force | Out-Null

    $currentHead = ((git -C $Framework rev-parse HEAD) | Out-String).Trim()
    $useDisk = ($currentHead -eq $Commit)

    foreach ($source in @("install-manifest.json", "templates/project/.crucible/README.md", "docs/guide.md", "powershell/tool.ps1")) {
        $relative = $source
        if ($source.StartsWith("templates/project/.crucible/")) {
            $relative = $source.Substring("templates/project/.crucible/".Length)
        }
        $destPath = Join-Path (Join-Path $Adopter ".crucible") $relative

        if ($useDisk) {
            $sourcePath = Join-Path $Framework $source
            if (Test-Path -LiteralPath $sourcePath) {
                $dir = Split-Path -Parent $destPath
                if (-not (Test-Path -LiteralPath $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
                Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force
            }
        } else {
            $content = (git -C $Framework show ($Commit + ":" + $source))
            Write-Utf8File -Path $destPath -Content ($content -join "`n")
        }
    }
    Write-Utf8File -Path (Join-Path $Adopter ".crucible/config.yaml") -Content ("project: adopter`r`ncrucible_install_commit: `"" + $Commit + "`"")
}

function Invoke-UpdateBundle {
    param(
        [Parameter(Mandatory=$true)][string]$Framework,
        [Parameter(Mandatory=$true)][string]$Adopter,
        [string]$Mode = "report-only",
        [switch]$Prune
    )
    $splat = @{
        FrameworkSource = $Framework
        AdopterRoot = $Adopter
        Mode = $Mode
        Prune = $Prune
    }

    $prevErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $output = @(
        try {
            & $SCRIPT @splat *>&1
        } catch {
            $_
        }
    )
    $exitCode = $LASTEXITCODE

    $ErrorActionPreference = $prevErrorActionPreference

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($output -join "`n")
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-update-bundle-test-custom-regions-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$script:SharedFrameworkPath = $null
$script:SharedFrameworkCommit = $null
$script:SharedAdopterPath = $null

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

function Reset-Framework {
    $fw = Get-SharedFramework
    git -C $fw.Path reset --hard $fw.Commit --quiet | Out-Null
    git -C $fw.Path clean -fdx --quiet | Out-Null
}

function Get-SharedAdopter {
    if ($null -eq $script:SharedAdopterPath) {
        $fw = Get-SharedFramework
        $adopterPath = Join-Path $tempRoot "shared-adopter"
        Copy-FrameworkToAdopter -Framework $fw.Path -Adopter $adopterPath -Commit $fw.Commit
        $script:SharedAdopterPath = $adopterPath
    }
    return $script:SharedAdopterPath
}

try {
    $results += Run-Test -Name "Classification of non-ASCII characters behaves as no-op" -Body {
        Reset-Framework
        $fw = Get-SharedFramework
        $framework = $fw.Path
        $commitA = $fw.Commit
        $adopter = Join-Path $tempRoot "nonascii-adopter"
        if (Test-Path -LiteralPath $adopter) { Remove-Item -LiteralPath $adopter -Recurse -Force | Out-Null }
        Copy-Item -Path (Get-SharedAdopter) -Destination $adopter -Recurse

        # Add a non-ASCII file (with an em-dash, section sign, and smart quotes) to both framework and adopter
        $nonAsciiContent = "Non-ASCII content: em-dash " + [char]0x2014 + " section " + [char]0x00a7 + " smart-quotes " + [char]0x201c + "hello" + [char]0x201d
        Write-Utf8File -Path (Join-Path $framework "docs/nonascii.md") -Content $nonAsciiContent
        $commitB = Invoke-GitCommit -Repo $framework -Message "add nonascii doc"

        # Now, update the install commit in config.yaml so B is the baseline commit
        Write-Utf8File -Path (Join-Path $adopter ".crucible/config.yaml") -Content ("project: adopter`r`ncrucible_install_commit: `"" + $commitB + "`"")
        # And write the exact same content to the adopter file
        Write-Utf8File -Path (Join-Path $adopter ".crucible/docs/nonascii.md") -Content $nonAsciiContent

        # Now check that running update-bundle classifies the file as no-op, not needs-merge
        $result = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "report-only"
        Assert-Result -Name "exit ok" -Condition ($result.ExitCode -eq 0) -FailureMessage $result.Output
        Assert-Result -Name "no needs-merge" -Condition ($result.Output -match 'needs-merge:\s+0') -FailureMessage $result.Output
        Assert-Result -Name "no-op count includes nonascii" -Condition ($result.Output -match 'no-op:\s+5') -FailureMessage $result.Output
    }

    $results += Run-Test -Name "P3 custom-regions are preserved and files with only custom region edits are classified as safe-overwrite or no-op" -Body {
        Reset-Framework
        $fw = Get-SharedFramework
        $framework = $fw.Path
        $commitA = $fw.Commit

        # Create a file with custom regions in framework baseline
        $contentA = "line 1`r`n# >>> CRUCIBLE-CUSTOM`r`ndefault custom region`r`n# <<< CRUCIBLE-CUSTOM`r`nline 3"
        Write-Utf8File -Path (Join-Path $framework "docs/guide.md") -Content $contentA
        $commitA = Invoke-GitCommit -Repo $framework -Message "add guide with custom region"

        $adopter = Join-Path $tempRoot "p3-custom-adopter"
        if (Test-Path -LiteralPath $adopter) { Remove-Item -LiteralPath $adopter -Recurse -Force | Out-Null }
        Copy-FrameworkToAdopter -Framework $framework -Adopter $adopter -Commit $commitA

        # Write adopter-modified custom region
        $contentAdopter = "line 1`r`n# >>> CRUCIBLE-CUSTOM`r`nadopter custom region`r`n# <<< CRUCIBLE-CUSTOM`r`nline 3"
        Write-Utf8File -Path (Join-Path $adopter ".crucible/docs/guide.md") -Content $contentAdopter

        # Scenario A: Framework did NOT change the file.
        # Running update-bundle should classify as no-op.
        $result1 = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "report-only"
        Assert-Result -Name "exit ok for no change" -Condition ($result1.ExitCode -eq 0) -FailureMessage $result1.Output
        Assert-Result -Name "custom region classified as no-op" -Condition ($result1.Output -match 'no-op:\s+4') -FailureMessage $result1.Output
        Assert-Result -Name "custom region not classified as needs-merge" -Condition ($result1.Output -match 'needs-merge:\s+0') -FailureMessage $result1.Output

        # Scenario B: Framework modified the file outside the custom region.
        $contentB = "line 1 changed`r`n# >>> CRUCIBLE-CUSTOM`r`ndefault custom region`r`n# <<< CRUCIBLE-CUSTOM`r`nline 3"
        Write-Utf8File -Path (Join-Path $framework "docs/guide.md") -Content $contentB
        $commitB = Invoke-GitCommit -Repo $framework -Message "update guide outside custom region"

        # Running update-bundle should classify as safe-overwrite.
        $result2 = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "report-only"
        Assert-Result -Name "exit ok for safe-overwrite report" -Condition ($result2.ExitCode -eq 0) -FailureMessage $result2.Output
        Assert-Result -Name "classified as safe-overwrite" -Condition ($result2.Output -match 'safe-overwrite:\s+1') -FailureMessage $result2.Output
        Assert-Result -Name "not classified as needs-merge" -Condition ($result2.Output -match 'needs-merge:\s+0') -FailureMessage $result2.Output

        # Apply in auto-safe mode
        $result3 = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "auto-safe"
        Assert-Result -Name "exit ok for auto-safe apply" -Condition ($result3.ExitCode -eq 0) -FailureMessage $result3.Output

        # Verify the file is updated outside and custom region is preserved!
        $updated = Get-Content -LiteralPath (Join-Path $adopter ".crucible/docs/guide.md") -Raw -Encoding UTF8
        $expected = "line 1 changed`r`n# >>> CRUCIBLE-CUSTOM`r`nadopter custom region`r`n# <<< CRUCIBLE-CUSTOM`r`nline 3"
        # Normalize line endings for comparison
        $normUpdated = $updated.Replace("`r`n", "`n").Trim()
        $normExpected = $expected.Replace("`r`n", "`n").Trim()
        Assert-Result -Name "merged content correct" -Condition ($normUpdated -eq $normExpected) -FailureMessage ("expected:`n" + $normExpected + "`ngot:`n" + $normUpdated)
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed update-bundle-custom-regions test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll update-bundle-custom-regions tests passed." -ForegroundColor Green
exit 0
