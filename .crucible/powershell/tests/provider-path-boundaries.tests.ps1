$ErrorActionPreference = 'Stop'
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").ProviderPath
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/archive-task.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/gitignore-conformance.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/line-ending-conformance.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/install-manifest.ps1')
$results = @()
$root = New-TestFixtureRoot -NameHint 'provider-boundaries'
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-FixtureFile($Path, $Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, $utf8)
}
try {
    New-PSDrive -Name Item329 -PSProvider FileSystem -Root $root | Out-Null
    foreach ($rootForm in @('native', 'alias')) {
    foreach ($site in @('committable', 'gitignore', 'line-ending', 'archive', 'copy')) {
        $results += Run-Test ("$site accepts a FileSystem PSDrive alias with $rootForm project root") {
            $project = Join-Path $root ($site + '-' + $rootForm)
            $bundle = Join-Path $project 'bundle'
            New-Item -ItemType Directory -Path $bundle -Force | Out-Null
            $projectAlias = (Resolve-Path -LiteralPath ("Item329:/" + $site + '-' + $rootForm)).Path
            $projectArgument = if ($rootForm -eq 'native') { $project } else { $projectAlias }
            $bundleAlias = Join-Path $projectAlias 'bundle'
            Assert-Result 'fixture retains alias' ($projectAlias -match '^Item329:') $projectAlias
            switch ($site) {
                'committable' {
                    Write-FixtureFile (Join-Path $bundle 'README.md') 'leaf'
                    Write-FixtureFile (Join-Path $bundle 'docs/Guide.md') 'tree'
                    $paths = Get-BundleCommittablePath -ProjectRoot $projectArgument -BundleRoot $bundleAlias
                    Assert-Result 'leaf and enumerated native path' ($paths.Count -eq 2 -and $paths -ccontains 'bundle/README.md' -and $paths -ccontains 'bundle/docs/Guide.md') ($paths -join ', ')
                    Write-FixtureFile (Join-Path $root 'committable-old/bundle/README.md') 'outside'
                    $paths = Get-BundleCommittablePath -ProjectRoot $projectArgument -BundleRoot 'Item329:/committable-old/bundle'
                    Assert-Result 'outside bundle stays outside' ($paths.Count -eq 0) ($paths -join ', ')
                }
                'gitignore' {
                    $null = Invoke-Git @('init', '--quiet', $project)
                    Write-FixtureFile (Join-Path $project '.gitignore') 'Guide.md'
                    Write-FixtureFile (Join-Path $bundle 'docs/Guide.md') 'ignored by project'
                    Write-FixtureFile (Join-Path $bundle '.gitignore') 'README.md'
                    Write-FixtureFile (Join-Path $bundle 'README.md') 'ignored by bundle'
                    $report = Test-GitignoreConformance -ProjectRoot $projectArgument -BundleRoot $bundleAlias
                    Assert-Result 'project violation only' ($report.Status -eq 'ok' -and $report.Checked -eq 3 -and $report.Violations.Count -eq 1 -and $report.Violations[0].Path -ceq 'bundle/docs/Guide.md') ($report | Out-String)
                    $outside = Join-Path $root 'gitignore-old/bundle'
                    Write-FixtureFile (Join-Path $outside 'README.md') 'outside'
                    $report = Test-GitignoreConformance -ProjectRoot $projectArgument -BundleRoot 'Item329:/gitignore-old/bundle'
                    Assert-Result 'outside skip is explicit' ($report.Status -eq 'skipped' -and $report.Reason -match 'outside the project') ($report | Out-String)
                }
                'line-ending' {
                    $null = Invoke-Git @('init', '--quiet', $project)
                    $null = Invoke-Git @('config', 'core.autocrlf', 'false') -Directory $project
                    Write-FixtureFile (Join-Path $bundle 'inside.txt') "inside`r`n"
                    Write-FixtureFile (Join-Path $project 'bundle-old/outside.txt') "outside`r`n"
                    $null = Invoke-Git @('add', '-A') -Directory $project
                    $report = Test-LineEndingConformance -ProjectRoot $projectArgument -BundleRoot $bundleAlias
                    Assert-Result 'bundle excluded and sibling checked' ($report.Status -eq 'ok' -and $report.Checked -eq 1 -and $report.Violations.Count -eq 1 -and $report.Violations[0].Path -ceq 'bundle-old/outside.txt') ($report | Out-String)
                }
                'archive' {
                    $rel = 'chores/active/C-001_Test.md'
                    Write-FixtureFile (Join-Path $bundle $rel) "---`nitem_id: C-001`npriority: P2`nstatus: Ready for Deploy`n---`n# Inert`n"
                    Write-FixtureFile (Join-Path $bundle 'BACKLOG.md') "| ID | Priority | Status | Title |`n|---|---|---|---|`n| [C-001]($rel) | P2 | Ready for Deploy | Inert |`n"
                    $report = Invoke-BacklogTaskArchive -BacklogPath (Join-Path $projectArgument 'bundle/BACKLOG.md') -SpecPath (Join-Path $bundleAlias 'chores/active/C-001_*.md') -Status Resolved
                    Assert-Result 'wildcard archive suffix' ($report.ArchivedRelPath -ceq 'chores/archived/C-001_Test.md') ($report | Out-String)
                    Assert-Result 'archive exists and active removed' ((Test-Path -LiteralPath $report.ArchivedPath) -and -not (Test-Path -LiteralPath (Join-Path $bundle $rel))) 'archive did not move the spec'
                    $outside = Join-Path $project 'bundle-old/chores/active/C-002_Test.md'
                    Write-FixtureFile $outside 'outside'
                    $message = ''
                    try { Invoke-BacklogTaskArchive -BacklogPath (Join-Path $projectArgument 'bundle/BACKLOG.md') -SpecPath (Join-Path $projectAlias 'bundle-old/chores/active/C-002_Test.md') -Status Resolved } catch { $message = $_.Exception.Message }
                    Assert-Result 'outside archive refused before mutation' ($message -match 'not under backlog directory' -and (Test-Path -LiteralPath $outside)) $message
                }
                'copy' {
                    $source = [IO.File]::ReadAllText((Join-Path $REPO_ROOT 'powershell/init-project.ps1'))
                    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
                    $copy = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-TemplateDirectory' }, $true)
                    . ([scriptblock]::Create($copy.Extent.Text))
                    $manifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT
                    Write-FixtureFile (Join-Path $bundle 'README.md') 'copy me'
                    Write-FixtureFile (Join-Path $bundle 'docs/Guide.md') 'nested copy'
                    Write-FixtureFile (Join-Path $bundle '.crucible/session/inert.txt') 'runtime'
                    $REPO_ROOT = $projectArgument
                    Copy-TemplateDirectory -Source $bundleAlias -Destination (Join-Path $project 'copied') -AllowOverwrite $false -Manifest $manifest
                    Assert-Result 'native suffixes copied' ((Test-Path -LiteralPath (Join-Path $project 'copied/README.md')) -and (Test-Path -LiteralPath (Join-Path $project 'copied/docs/Guide.md'))) 'alias length corrupted copy suffix'
                    Assert-Result 'nested runtime excluded' (-not (Test-Path -LiteralPath (Join-Path $project 'copied/.crucible/session/inert.txt'))) 'runtime copied'
                }
            }
        }
    }
    }
} finally {
    Remove-PSDrive Item329 -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-TestFileSummary -Results $results
