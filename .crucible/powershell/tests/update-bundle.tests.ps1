# Tests for powershell/update-bundle.ps1.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$SCRIPT = Join-Path $REPO_ROOT "powershell/update-bundle.ps1"
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
    Write-Utf8File -Path (Join-Path $Root "install-manifest.json") -Content @'
{
  "scaffold_source": "templates/project/.crucible",
  "copied_dirs": ["docs", "powershell"],
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
    foreach ($source in @("templates/project/.crucible/README.md", "docs/guide.md", "powershell/tool.ps1")) {
        $content = (git -C $Framework show ($Commit + ":" + $source))
        $relative = $source
        if ($source.StartsWith("templates/project/.crucible/")) {
            $relative = $source.Substring("templates/project/.crucible/".Length)
        }
        Write-Utf8File -Path (Join-Path (Join-Path $Adopter ".crucible") $relative) -Content ($content -join "`n")
    }
    Write-Utf8File -Path (Join-Path $Adopter ".crucible/config.yaml") -Content ("project: adopter`r`ncrucible_install_commit: `"" + $Commit + "`"")
}

function Invoke-UpdateBundle {
    param(
        [Parameter(Mandatory=$true)][string]$Framework,
        [Parameter(Mandatory=$true)][string]$Adopter,
        [string]$Mode = "report-only"
    )
    $output = @(powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SCRIPT -FrameworkSource $Framework -AdopterRoot $Adopter -Mode $Mode 2>&1)
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join "`n")
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-update-bundle-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Happy path safe-overwrite applies and updates install commit" -Body {
        $framework = Join-Path $tempRoot "safe-framework"
        $commitA = New-FrameworkFixture -Root $framework
        $adopter = Join-Path $tempRoot "safe-adopter"
        Copy-FrameworkToAdopter -Framework $framework -Adopter $adopter -Commit $commitA
        Write-Utf8File -Path (Join-Path $framework "powershell/tool.ps1") -Content 'Write-Host "head"'
        $commitB = Invoke-GitCommit -Repo $framework -Message "head"

        $result = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "auto-safe"
        Assert-Result -Name "exit ok" -Condition ($result.ExitCode -eq 0) -FailureMessage $result.Output
        Assert-Result -Name "safe reported" -Condition ($result.Output -match 'safe-overwrite:\s+1') -FailureMessage $result.Output
        $updated = Get-Content -LiteralPath (Join-Path $adopter ".crucible/powershell/tool.ps1") -Raw -Encoding UTF8
        Assert-Result -Name "file updated" -Condition ($updated -match 'head') -FailureMessage "safe-overwrite did not copy head content"
        $config = Get-Content -LiteralPath (Join-Path $adopter ".crucible/config.yaml") -Raw -Encoding UTF8
        Assert-Result -Name "commit updated" -Condition ($config -match [regex]::Escape($commitB)) -FailureMessage "install commit was not advanced"
    }

    $results += Run-Test -Name "Needs-merge detection does not apply local-overwritten file" -Body {
        $framework = Join-Path $tempRoot "merge-framework"
        $commitA = New-FrameworkFixture -Root $framework
        $adopter = Join-Path $tempRoot "merge-adopter"
        Copy-FrameworkToAdopter -Framework $framework -Adopter $adopter -Commit $commitA
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
        $framework = Join-Path $tempRoot "noop-framework"
        $commitA = New-FrameworkFixture -Root $framework
        $adopter = Join-Path $tempRoot "noop-adopter"
        Copy-FrameworkToAdopter -Framework $framework -Adopter $adopter -Commit $commitA

        $result = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "report-only"
        Assert-Result -Name "exit ok" -Condition ($result.ExitCode -eq 0) -FailureMessage $result.Output
        Assert-Result -Name "no safe updates" -Condition ($result.Output -match 'safe-overwrite:\s+0') -FailureMessage $result.Output
        Assert-Result -Name "no merges" -Condition ($result.Output -match 'needs-merge:\s+0') -FailureMessage $result.Output
    }

    $results += Run-Test -Name "Missing baseline stamp fails with actionable message" -Body {
        $framework = Join-Path $tempRoot "unstamped-framework"
        $null = New-FrameworkFixture -Root $framework
        $adopter = Join-Path $tempRoot "unstamped-adopter"
        New-Item -ItemType Directory -Path (Join-Path $adopter ".crucible") -Force | Out-Null
        Write-Utf8File -Path (Join-Path $adopter ".crucible/config.yaml") -Content 'project: unstamped'

        $result = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "report-only"
        Assert-Result -Name "exit failure" -Condition ($result.ExitCode -eq 1) -FailureMessage $result.Output
        Assert-Result -Name "stamp guidance" -Condition ($result.Output -match 'StampVersionOnly') -FailureMessage $result.Output
    }

    $results += Run-Test -Name "Out-of-scope backlog paths are preserved and not enumerated" -Body {
        $framework = Join-Path $tempRoot "scope-framework"
        $commitA = New-FrameworkFixture -Root $framework
        $adopter = Join-Path $tempRoot "scope-adopter"
        Copy-FrameworkToAdopter -Framework $framework -Adopter $adopter -Commit $commitA
        Write-Utf8File -Path (Join-Path $adopter ".crucible/backlog/F-001_test.md") -Content 'adopter backlog'

        $result = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "report-only"
        Assert-Result -Name "exit ok" -Condition ($result.ExitCode -eq 0) -FailureMessage $result.Output
        Assert-Result -Name "backlog not reported" -Condition ($result.Output -notmatch 'F-001_test') -FailureMessage $result.Output
        $content = Get-Content -LiteralPath (Join-Path $adopter ".crucible/backlog/F-001_test.md") -Raw -Encoding UTF8
        Assert-Result -Name "backlog preserved" -Condition ($content -match 'adopter backlog') -FailureMessage "backlog file changed"
    }

    $results += Run-Test -Name "Added upstream file is classified and applied" -Body {
        $framework = Join-Path $tempRoot "add-framework"
        $commitA = New-FrameworkFixture -Root $framework
        $adopter = Join-Path $tempRoot "add-adopter"
        Copy-FrameworkToAdopter -Framework $framework -Adopter $adopter -Commit $commitA
        Write-Utf8File -Path (Join-Path $framework "docs/new.md") -Content 'new upstream doc'
        $commitB = Invoke-GitCommit -Repo $framework -Message "new doc"

        $result = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "auto-safe"
        Assert-Result -Name "exit ok" -Condition ($result.ExitCode -eq 0) -FailureMessage $result.Output
        Assert-Result -Name "add reported" -Condition ($result.Output -match 'add:\s+1') -FailureMessage $result.Output
        Assert-Result -Name "new file copied" -Condition (Test-Path -LiteralPath (Join-Path $adopter ".crucible/docs/new.md")) -FailureMessage "added file was not copied"
        $config = Get-Content -LiteralPath (Join-Path $adopter ".crucible/config.yaml") -Raw -Encoding UTF8
        Assert-Result -Name "commit updated" -Condition ($config -match [regex]::Escape($commitB)) -FailureMessage "install commit was not advanced after add"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed update-bundle test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll update-bundle tests passed." -ForegroundColor Green
exit 0
