# Tests for powershell/update-bundle.ps1 (core).

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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-update-bundle-test-core-" + [guid]::NewGuid().ToString("N"))
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
    $results += Run-Test -Name "Happy path safe-overwrite applies and updates install commit" -Body {
        Reset-Framework
        $fw = Get-SharedFramework
        $framework = $fw.Path
        $commitA = $fw.Commit
        $adopter = Join-Path $tempRoot "safe-adopter"
        if (Test-Path -LiteralPath $adopter) { Remove-Item -LiteralPath $adopter -Recurse -Force | Out-Null }
        Copy-Item -Path (Get-SharedAdopter) -Destination $adopter -Recurse

        Write-Utf8File -Path (Join-Path $framework "powershell/tool.ps1") -Content 'Write-Host "head"'
        $commitB = Invoke-GitCommit -Repo $framework -Message "head"

        $result = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "auto-safe"
        Assert-Result -Name "exit ok" -Condition ($result.ExitCode -eq 0) -FailureMessage $result.Output
        Assert-Result -Name "safe reported" -Condition ($result.Output -match 'safe-overwrite:\s+1') -FailureMessage $result.Output
        $updated = Get-Content -LiteralPath (Join-Path $adopter ".crucible/powershell/tool.ps1") -Raw -Encoding UTF8
        Assert-Result -Name "file updated" -Condition ($updated -match 'head') -FailureMessage "safe-overwrite did not copy head content"
        Assert-Result -Name "scaffold snapshot present" -Condition (Test-Path -LiteralPath (Join-Path $adopter ".crucible/templates/project/.crucible/README.md")) -FailureMessage "scaffold snapshot was not installed"
        $config = Get-Content -LiteralPath (Join-Path $adopter ".crucible/config.yaml") -Raw -Encoding UTF8
        Assert-Result -Name "commit updated" -Condition ($config -match [regex]::Escape($commitB)) -FailureMessage "install commit was not advanced"
    }

    $results += Run-Test -Name "Needs-merge detection does not apply local-overwritten file" -Body {
        Reset-Framework
        $fw = Get-SharedFramework
        $framework = $fw.Path
        $commitA = $fw.Commit
        $adopter = Join-Path $tempRoot "merge-adopter"
        if (Test-Path -LiteralPath $adopter) { Remove-Item -LiteralPath $adopter -Recurse -Force | Out-Null }
        Copy-Item -Path (Get-SharedAdopter) -Destination $adopter -Recurse

        Write-Utf8File -Path (Join-Path $adopter ".crucible/powershell/tool.ps1") -Content 'Write-Host "local"'
        Write-Utf8File -Path (Join-Path $framework "powershell/tool.ps1") -Content 'Write-Host "upstream"'
        $null = Invoke-GitCommit -Repo $framework -Message "upstream"

        $result = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "auto-safe"
        Assert-Result -Name "exit advisory" -Condition ($result.ExitCode -eq 2) -FailureMessage $result.Output
        Assert-Result -Name "needs merge reported" -Condition ($result.Output -match 'needs-merge:\s+1') -FailureMessage $result.Output
        $content = Get-Content -LiteralPath (Join-Path $adopter ".crucible/powershell/tool.ps1") -Raw -Encoding UTF8
        Assert-Result -Name "local preserved" -Condition ($content -match 'local') -FailureMessage "needs-merge file was overwritten"
    }

    $results += Run-Test -Name "No-op classification at framework head exits zero" -Body {
        Reset-Framework
        $fw = Get-SharedFramework
        $adopter = Get-SharedAdopter

        $result = Invoke-UpdateBundle -Framework $fw.Path -Adopter $adopter -Mode "report-only"
        Assert-Result -Name "exit ok" -Condition ($result.ExitCode -eq 0) -FailureMessage $result.Output
        Assert-Result -Name "no safe updates" -Condition ($result.Output -match 'safe-overwrite:\s+0') -FailureMessage $result.Output
        Assert-Result -Name "no merges" -Condition ($result.Output -match 'needs-merge:\s+0') -FailureMessage $result.Output
    }

    $results += Run-Test -Name "Missing baseline stamp fails with actionable message" -Body {
        Reset-Framework
        $fw = Get-SharedFramework
        $framework = $fw.Path
        $adopter = Join-Path $tempRoot "unstamped-adopter"
        if (Test-Path -LiteralPath $adopter) { Remove-Item -LiteralPath $adopter -Recurse -Force | Out-Null }
        New-Item -ItemType Directory -Path (Join-Path $adopter ".crucible") -Force | Out-Null
        Write-Utf8File -Path (Join-Path $adopter ".crucible/config.yaml") -Content 'project: unstamped'

        $result = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "report-only"
        Assert-Result -Name "exit failure" -Condition ($result.ExitCode -eq 1) -FailureMessage $result.Output
        Assert-Result -Name "stamp guidance" -Condition ($result.Output -match 'StampVersionOnly') -FailureMessage $result.Output
    }

    $results += Run-Test -Name "Added upstream file is classified and applied" -Body {
        Reset-Framework
        $fw = Get-SharedFramework
        $framework = $fw.Path
        $adopter = Join-Path $tempRoot "add-adopter"
        if (Test-Path -LiteralPath $adopter) { Remove-Item -LiteralPath $adopter -Recurse -Force | Out-Null }
        Copy-Item -Path (Get-SharedAdopter) -Destination $adopter -Recurse
        Write-Utf8File -Path (Join-Path $framework "docs/new.md") -Content 'new upstream doc'
        $commitB = Invoke-GitCommit -Repo $framework -Message "new doc"

        $result = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "auto-safe"
        Assert-Result -Name "exit ok" -Condition ($result.ExitCode -eq 0) -FailureMessage $result.Output
        Assert-Result -Name "add reported" -Condition ($result.Output -match 'add:\s+4') -FailureMessage $result.Output
        Assert-Result -Name "new file copied" -Condition (Test-Path -LiteralPath (Join-Path $adopter ".crucible/docs/new.md")) -FailureMessage "added file was not copied"
        $config = Get-Content -LiteralPath (Join-Path $adopter ".crucible/config.yaml") -Raw -Encoding UTF8
        Assert-Result -Name "commit updated" -Condition ($config -match [regex]::Escape($commitB)) -FailureMessage "install commit was not advanced after add"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed update-bundle-core test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll update-bundle-core tests passed." -ForegroundColor Green
exit 0
