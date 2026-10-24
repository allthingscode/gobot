# Each converted Resolve-Path consumer keeps its result with case and parent segments.
$ErrorActionPreference = 'Stop'
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/platform.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/archive-task.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/install-manifest.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/gitignore-conformance.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/line-ending-conformance.ps1')
$results = @()
$root = New-TestFixtureRoot -NameHint 'path-owner-sites'
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-FixtureFile($Path, $Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, $utf8)
}
function Convert-TestSpelling($Path, $Variant) {
    if ($Variant -eq 'case') { return $Path.ToUpperInvariant() }
    return (Join-Path $Path '../' (Split-Path -Leaf $Path))
}
try {
    foreach ($variant in @('parent', 'case')) {
        foreach ($site in @('archive', 'install-manifest', 'gitignore', 'line-ending', 'init')) {
            $results += Run-Test ($site + ' accepts ' + $variant + ' spelling') {
                if ($variant -eq 'case' -and -not (Test-PlatformIsWindows)) { Skip-Test 'Case variants require a case-insensitive Windows filesystem.' }
                $project = Join-Path $root ($site + '-' + $variant)
                $bundle = Join-Path $project '.crucible'
                New-Item -ItemType Directory -Path $bundle -Force | Out-Null
                $projectSpelling = Convert-TestSpelling $project $variant
                $bundleSpelling = Convert-TestSpelling $bundle $variant
                switch ($site) {
                    'archive' {
                        $rel = 'chores/active/C-001_Test.md'
                        Write-FixtureFile (Join-Path $bundle $rel) "---`nitem_id: C-001`npriority: P2`nstatus: Ready for Deploy`n---`n# Test`n"
                        Write-FixtureFile (Join-Path $bundle 'BACKLOG.md') "| ID | Priority | Status | Title |`n|---|---|---|---|`n| [C-001]($rel) | P2 | Ready for Deploy | Test |`n"
                        $result = Invoke-BacklogTaskArchive -BacklogPath (Join-Path $bundleSpelling 'BACKLOG.md') -SpecPath (Join-Path $bundleSpelling $rel) -Status Resolved
                        Assert-Result 'archive suffix' ($result.ArchivedRelPath -ceq 'chores/archived/C-001_Test.md') $result.ArchivedRelPath
                        Assert-Result 'archived file exists' (Test-Path -LiteralPath $result.ArchivedPath) 'spec not moved'
                    }
                    'install-manifest' {
                        $null = Invoke-Git @('init', '--quiet', $project)
                        Write-FixtureFile (Join-Path $project '.gitignore') "/.crucible/ignored.txt`n"
                        Write-FixtureFile (Join-Path $bundle 'ignored.txt') 'ignored'
                        Write-FixtureFile (Join-Path $bundle 'kept.txt') 'kept'
                        Assert-Result 'ignored suffix reaches git' (Test-CrucibleGitIgnored -BundleRoot $bundleSpelling -RelativePath 'ignored.txt') 'ignored path missed'
                        Assert-Result 'kept path stays visible' (-not (Test-CrucibleGitIgnored -BundleRoot $bundleSpelling -RelativePath 'kept.txt')) 'kept path classified ignored'
                    }
                    'gitignore' {
                        Write-FixtureFile (Join-Path $bundle 'README.md') 'bundle'
                        $paths = @(Get-BundleCommittablePath -ProjectRoot $projectSpelling -BundleRoot $bundleSpelling)
                        Assert-Result 'committable suffix' ($paths.Count -eq 1 -and $paths[0] -ieq '.crucible/README.md') ($paths -join ', ')
                    }
                    'line-ending' {
                        $null = Invoke-Git @('init', '--quiet', $project)
                        $null = Invoke-Git @('config', 'core.autocrlf', 'false') -Directory $project
                        Write-FixtureFile (Join-Path $bundle 'inside.txt') "bundle`r`n"
                        Write-FixtureFile (Join-Path $project 'outside.txt') "project`r`n"
                        $null = Invoke-Git @('add', '-A') -Directory $project
                        $report = Test-LineEndingConformance -ProjectRoot $projectSpelling -BundleRoot $bundleSpelling
                        Assert-Result 'outside CRLF only' ($report.Status -eq 'ok' -and $report.Checked -eq 1 -and $report.Violations.Count -eq 1 -and $report.Violations[0].Path -ceq 'outside.txt') ($report | Out-String)
                    }
                    'init' {
                        # Execute the actual copy function and the actual backlog display block
                        # without installing a full bundle for each spelling variant.
                        $source = [IO.File]::ReadAllText((Join-Path $REPO_ROOT 'powershell/init-project.ps1'))
                        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
                        $copy = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-TemplateDirectory' }, $true)
                        . ([scriptblock]::Create($copy.Extent.Text))
                        $manifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT
                        Write-FixtureFile (Join-Path $project 'source/README.md') 'copy me'
                        Write-FixtureFile (Join-Path $project 'source/.crucible/session/secret.txt') 'exclude me'
                        # Give the copier a differently spelled framework root too.
                        $REPO_ROOT = $projectSpelling
                        Copy-TemplateDirectory -Source (Join-Path $projectSpelling 'source') -Destination (Join-Path $project 'copied') -AllowOverwrite $false -Manifest $manifest
                        Assert-Result 'copy visible file' (Test-Path (Join-Path $project 'copied/README.md')) 'copy missing'
                        Assert-Result 'copy excludes nested runtime' (-not (Test-Path (Join-Path $project 'copied/.crucible/session/secret.txt'))) 'runtime copied'
                        Write-FixtureFile (Join-Path $bundle 'config.yaml') "paths:`n  backlog: .crucible/backlog`n"
                        $resolvedProjectRoot = $projectSpelling
                        $start = $source.IndexOf('$backlogDirForRel =')
                        $end = $source.IndexOf('Write-Info "Ignored by default', $start)
                        Assert-Result 'display block found' ($start -ge 0 -and $end -gt $start) 'init display block moved'
                        . ([scriptblock]::Create($source.Substring($start, $end - $start)))
                        Assert-Result 'displayed backlog suffix' ($relativeBacklogPath -ieq '.crucible/backlog/') $relativeBacklogPath
                    }
                }
            }
        }
    }
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
Write-TestFileSummary -Results $results
