# Tests for powershell/update-bundle.ps1 (rename and prune).

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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-update-bundle-test-rename-prune-" + [guid]::NewGuid().ToString("N"))
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
    $results += Run-Test -Name "Upstream rename completes without crashing on a missing source" -Body {
        Reset-Framework
        $fw = Get-SharedFramework
        $framework = $fw.Path
        $commitA = $fw.Commit
        $adopter = Join-Path $tempRoot "rename-adopter"
        if (Test-Path -LiteralPath $adopter) { Remove-Item -LiteralPath $adopter -Recurse -Force | Out-Null }
        Copy-Item -Path (Get-SharedAdopter) -Destination $adopter -Recurse

        git -C $framework mv "docs/guide.md" "docs/guide-renamed.md" | Out-Null
        Write-Utf8File -Path (Join-Path $framework "docs/guide-renamed.md") -Content 'guide head renamed'
        $commitB = Invoke-GitCommit -Repo $framework -Message "rename guide"

        $result = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "auto-safe" -Prune
        Assert-Result -Name "no crash (exit 0)" -Condition ($result.ExitCode -eq 0) -FailureMessage $result.Output
        Assert-Result -Name "no missing-path failure" -Condition ($result.Output -notmatch 'Cannot find path') -FailureMessage $result.Output
        Assert-Result -Name "renamed file added" -Condition (Test-Path -LiteralPath (Join-Path $adopter ".crucible/docs/guide-renamed.md")) -FailureMessage "renamed file was not added to adopter"
        $renamed = Get-Content -LiteralPath (Join-Path $adopter ".crucible/docs/guide-renamed.md") -Raw -Encoding UTF8
        Assert-Result -Name "renamed content is head" -Condition ($renamed -match 'renamed') -FailureMessage "renamed file has wrong content"
    }

    $results += Run-Test -Name "Prune removes obsolete orphans but preserves adopter-owned and gitignored files" -Body {
        Reset-Framework
        $fw = Get-SharedFramework
        $framework = $fw.Path
        $commitA = $fw.Commit

        # Add stale.md and commit as Commit B
        Write-Utf8File -Path (Join-Path $framework "docs/stale.md") -Content 'to be deleted'
        $commitB = Invoke-GitCommit -Repo $framework -Message "commit B with stale"

        # Delete stale.md and commit as Commit C (HEAD)
        Remove-Item -LiteralPath (Join-Path $framework "docs/stale.md") -Force
        $commitC = Invoke-GitCommit -Repo $framework -Message "commit C deleting stale"

        # Create adopter using Copy-FrameworkToAdopter from Commit C (meaning stale.md won't be copied from framework)
        $adopter = Join-Path $tempRoot "prune-adopter"
        if (Test-Path -LiteralPath $adopter) { Remove-Item -LiteralPath $adopter -Recurse -Force | Out-Null }
        Copy-FrameworkToAdopter -Framework $framework -Adopter $adopter -Commit $commitC

        # Manually introduce orphan, adopter-owned, and gitignored files to the adopter
        # 1. An orphan that should be pruned
        Write-Utf8File -Path (Join-Path $adopter ".crucible/docs/stale.md") -Content 'lingering orphan'

        # 2. An adopter-owned file (e.g. in backlog/) which must NEVER be flagged/removed
        Write-Utf8File -Path (Join-Path $adopter ".crucible/backlog/user-backlog.md") -Content 'user backlog'

        # 3. A gitignored orphan file which must NEVER be flagged/removed
        # We need git init on adopter for check-ignore to work
        git -C $adopter init --quiet | Out-Null
        git -C $adopter config core.autocrlf false | Out-Null
        git -C $adopter config core.safecrlf false | Out-Null
        Write-Utf8File -Path (Join-Path $adopter ".gitignore") -Content ".crucible/docs/ignored_orphan.md"
        Write-Utf8File -Path (Join-Path $adopter ".crucible/docs/ignored_orphan.md") -Content 'ignored orphan'

        # Run first: report-only without -Prune
        $result1 = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "report-only"
        Assert-Result -Name "report ok" -Condition ($result1.ExitCode -eq 0) -FailureMessage $result1.Output
        Assert-Result -Name "stale reported for removal" -Condition ($result1.Output -match 'review-removal:\s+1') -FailureMessage $result1.Output
        Assert-Result -Name "stale filename printed" -Condition ($result1.Output -match 'docs/stale.md') -FailureMessage $result1.Output
        Assert-Result -Name "ignored orphan not reported" -Condition ($result1.Output -notmatch 'ignored_orphan.md') -FailureMessage $result1.Output
        Assert-Result -Name "backlog not reported" -Condition ($result1.Output -notmatch 'user-backlog') -FailureMessage $result1.Output

        Assert-Result -Name "stale exists before prune" -Condition (Test-Path -LiteralPath (Join-Path $adopter ".crucible/docs/stale.md")) -FailureMessage "stale.md was deleted prematurely"
        Assert-Result -Name "ignored orphan exists before prune" -Condition (Test-Path -LiteralPath (Join-Path $adopter ".crucible/docs/ignored_orphan.md")) -FailureMessage "ignored orphan was deleted"

        # Run auto-safe without -Prune: stale should still exist
        $result2 = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "auto-safe"
        Assert-Result -Name "auto-safe ok" -Condition ($result2.ExitCode -eq 0) -FailureMessage $result2.Output
        Assert-Result -Name "stale still exists" -Condition (Test-Path -LiteralPath (Join-Path $adopter ".crucible/docs/stale.md")) -FailureMessage "stale.md was pruned without -Prune flag"

        # Run auto-safe with -Prune: stale should be deleted
        $result3 = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "auto-safe" -Prune
        Assert-Result -Name "auto-safe prune ok" -Condition ($result3.ExitCode -eq 0) -FailureMessage $result3.Output
        Assert-Result -Name "stale deleted" -Condition (-not (Test-Path -LiteralPath (Join-Path $adopter ".crucible/docs/stale.md"))) -FailureMessage "stale.md was not pruned"
        Assert-Result -Name "ignored orphan preserved" -Condition (Test-Path -LiteralPath (Join-Path $adopter ".crucible/docs/ignored_orphan.md")) -FailureMessage "ignored orphan was deleted during prune"
        Assert-Result -Name "backlog preserved" -Condition (Test-Path -LiteralPath (Join-Path $adopter ".crucible/backlog/user-backlog.md")) -FailureMessage "backlog was deleted during prune"

        $config = Get-Content -LiteralPath (Join-Path $adopter ".crucible/config.yaml") -Raw -Encoding UTF8
        Assert-Result -Name "commit updated after prune" -Condition ($config -match [regex]::Escape($commitC)) -FailureMessage "install commit did not advance after successful prune"
    }

    $results += Run-Test -Name "P2 renamed-away file classified as review-removal if unmodified, needs-merge if modified" -Body {
        Reset-Framework
        $fw = Get-SharedFramework
        $framework = $fw.Path

        # Write VERSION file to framework root so update-bundle can read/stamp it
        Write-Utf8File -Path (Join-Path $framework "VERSION") -Content "0.4.0"
        # Commit it
        git -C $framework add VERSION | Out-Null
        $commitA = Invoke-GitCommit -Repo $framework -Message "add version"

        $adopter = Join-Path $tempRoot "p2-rename-adopter"
        if (Test-Path -LiteralPath $adopter) { Remove-Item -LiteralPath $adopter -Recurse -Force | Out-Null }
        Copy-FrameworkToAdopter -Framework $framework -Adopter $adopter -Commit $commitA

        # Scenario A: Rename/remove the file in the framework
        git -C $framework mv "docs/guide.md" "docs/guide-renamed.md" | Out-Null
        Write-Utf8File -Path (Join-Path $framework "docs/guide-renamed.md") -Content 'guide head renamed'
        $commitB = Invoke-GitCommit -Repo $framework -Message "rename guide"

        # Adopter has NOT modified docs/guide.md
        # Run in report-only mode first to verify classification
        $result1 = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "report-only" -Prune
        Assert-Result -Name "exit ok for unmodified rename" -Condition ($result1.ExitCode -eq 0) -FailureMessage $result1.Output
        Assert-Result -Name "classified as review-removal" -Condition ($result1.Output -match 'review-removal:\s+1') -FailureMessage $result1.Output
        Assert-Result -Name "not classified as needs-merge" -Condition ($result1.Output -match 'needs-merge:\s+0') -FailureMessage $result1.Output

        # Now actually apply the update in auto-safe mode
        $result2 = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "auto-safe" -Prune
        Assert-Result -Name "exit ok for auto-safe" -Condition ($result2.ExitCode -eq 0) -FailureMessage $result2.Output
        Assert-Result -Name "stale guide.md is pruned" -Condition (-not (Test-Path -LiteralPath (Join-Path $adopter ".crucible/docs/guide.md"))) -FailureMessage "guide.md was not pruned"
        Assert-Result -Name "guide-renamed.md is added" -Condition (Test-Path -LiteralPath (Join-Path $adopter ".crucible/docs/guide-renamed.md")) -FailureMessage "guide-renamed.md was not added"

        # Verify crucible_version is stamped in config.yaml
        $config = Get-Content -LiteralPath (Join-Path $adopter ".crucible/config.yaml") -Raw -Encoding UTF8
        Assert-Result -Name "version stamped" -Condition ($config -match 'crucible_version: "0.4.0"') -FailureMessage ("crucible_version not stamped: " + $config)

        # Scenario B: What if the adopter HAD modified docs/guide.md?
        # Reset adopter
        Remove-Item -LiteralPath $adopter -Recurse -Force -ErrorAction SilentlyContinue
        Copy-FrameworkToAdopter -Framework $framework -Adopter $adopter -Commit $commitA

        # Modify docs/guide.md on adopter
        Write-Utf8File -Path (Join-Path $adopter ".crucible/docs/guide.md") -Content 'adopter modified guide content'

        $result3 = Invoke-UpdateBundle -Framework $framework -Adopter $adopter -Mode "report-only" -Prune
        Assert-Result -Name "exit 2 for modified rename" -Condition ($result3.ExitCode -eq 2) -FailureMessage $result3.Output
        Assert-Result -Name "classified as needs-merge" -Condition ($result3.Output -match 'needs-merge:\s+1') -FailureMessage $result3.Output
        Assert-Result -Name "not classified as review-removal" -Condition ($result3.Output -match 'review-removal:\s+0') -FailureMessage $result3.Output
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed update-bundle-rename-prune test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll update-bundle-rename-prune tests passed." -ForegroundColor Green
exit 0
