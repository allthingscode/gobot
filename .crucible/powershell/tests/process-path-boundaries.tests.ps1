$ErrorActionPreference = 'Stop'
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").ProviderPath
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/platform.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/install-manifest.ps1')
$results = @()
$root = New-TestFixtureRoot -NameHint 'process-boundaries'
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-BoundaryFile($Path, $Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, $utf8)
}
function Get-BoundarySpelling($Leaf, $Shape) {
    switch ($Shape) {
        'alias' { return "Item330:/$Leaf" }
        'relative' { return $Leaf }
        '/' { return "/$Leaf" }
        '\' { return ('\' + $Leaf.Replace('/', '\')) }
    }
}
$initSource = [IO.File]::ReadAllText((Join-Path $REPO_ROOT 'powershell/init-project.ps1'))
$displayStart = $initSource.IndexOf('$backlogDirForRel =')
$displayEnd = $initSource.IndexOf('Write-Info "Ignored by default', $displayStart)
$display = [scriptblock]::Create($initSource.Substring($displayStart, $displayEnd - $displayStart))
$updateSource = [IO.File]::ReadAllText((Join-Path $REPO_ROOT 'powershell/update-bundle.ps1'))
$ast = [Management.Automation.Language.Parser]::ParseInput($updateSource, [ref]$null, [ref]$null)
$prune = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-EmptiedBundleDirectory' }, $true)
. ([scriptblock]::Create($prune.Extent.Text))
$gate = Join-Path $REPO_ROOT 'powershell/gates/check-mojibake.ps1'
$wrapper = Join-Path $root 'staged-owner/powershell/gates/caller.ps1'
$gateSource = [IO.File]::ReadAllText($gate)
$ast = [Management.Automation.Language.Parser]::ParseInput($gateSource, [ref]$null, [ref]$null)
$stagedBlock = $ast.Find({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '$Staged' }, $true)
# Exercise the actual staged boundary with provider-dependent operands; the public
# -Staged entrypoint constructs its default operands from its native script directory.
$callerHeader = @'
param($RepoRoot, $FixtureRoot, $ContentRoot, $ScopeRoot, $BadScope)
$ErrorActionPreference = 'Stop'
New-PSDrive -Name Item330 -PSProvider FileSystem -Root $FixtureRoot | Out-Null
Push-Location 'Item330:/'
$gate = Join-Path $RepoRoot 'powershell/gates/check-mojibake.ps1'
$Staged = $true
$Paths = @($ScopeRoot)
if ($BadScope -eq 'yes') { $Paths = @('Env:CRUCIBLE_ITEM330_INERT') }
$contentRoot = $ContentRoot
try {
'@
$callerFooter = @'
    Write-Host ('SCOPED=' + $Paths.Count)
    if ($Paths.Count -ne 1 -or (Split-Path -Leaf $Paths[0]) -cne 'Guide.md') { exit 93 }
    . ([scriptblock]::Create([IO.File]::ReadAllText($gate))) -Paths $Paths
    Write-Host 'RETURNED_AFTER_GATE'
} catch {
    Write-Host ('CAUGHT_GATE: ' + $_.Exception.Message)
    exit 94
}
'@
Write-BoundaryFile $wrapper ($callerHeader + "`n" + $stagedBlock.Extent.Text + "`n" + $callerFooter)
$fixtureLib = Join-Path $root 'staged-owner/powershell/lib'
New-Item -ItemType Directory -Path $fixtureLib -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $REPO_ROOT 'powershell/lib/config-helpers.ps1') -Destination (Join-Path $fixtureLib 'config-helpers.ps1')
try {
    New-PSDrive -Name Item330 -PSProvider FileSystem -Root $root | Out-Null
    Push-Location 'Item330:/'
    try {
        foreach ($shape in @('alias', 'relative', '/', '\')) {
            foreach ($site in @('gitignore', 'display', 'prune-root', 'prune-candidate', 'staged-scope', 'staged-candidate')) {
                $results += Run-Test ("$site qualifies $shape paths in the PowerShell filesystem context") {
                    if ($shape -in @('/', '\') -and -not $IsWindows) { Skip-Test 'Root-relative Windows paths require a Windows filesystem drive.' }
                    $leaf = $site + '-' + [array]::IndexOf(@('alias', 'relative', '/', '\'), $shape)
                    $native = Join-Path $root $leaf
                    $inputPath = Get-BoundarySpelling $leaf $shape
                    New-Item -ItemType Directory -Path $native -Force | Out-Null
                    Assert-Result 'fixture distinguishes process context' ([IO.Path]::GetFullPath($inputPath) -cne $native) 'process and provider paths agree'
                    switch ($site) {
                        'gitignore' {
                            $null = Invoke-Git @('init', '--quiet', $native)
                            Write-BoundaryFile (Join-Path $native '.gitignore') "/bundle/ignored.txt`n"
                            Write-BoundaryFile (Join-Path $native 'bundle/ignored.txt') 'ignored'
                            Write-BoundaryFile (Join-Path $native 'bundle/visible.txt') 'visible'
                            $bundleInput = Join-Path $inputPath 'bundle'
                            Assert-Result 'ignored file found' (Test-CrucibleGitIgnored -BundleRoot $bundleInput -RelativePath 'ignored.txt') 'wrong git root selected'
                            Assert-Result 'visible file stays visible' (-not (Test-CrucibleGitIgnored -BundleRoot $bundleInput -RelativePath 'visible.txt')) 'visible file ignored'
                            Assert-Result 'parent escape stays outside git root' (-not (Test-CrucibleGitIgnored -BundleRoot $bundleInput -RelativePath '../../outside.txt')) 'outside path passed to git'
                        }
                        'display' {
                            $configured = if ($shape -in @('/', '\')) { Join-Path $inputPath 'backlog' } else { Join-Path $native 'backlog' }
                            Write-BoundaryFile (Join-Path $native '.crucible/config.yaml') ("paths:`n  backlog: '" + $configured + "'`n")
                            $resolvedProjectRoot = if ($shape -in @('/', '\')) { $native } else { $inputPath }
                            . $display
                            Assert-Result 'contained backlog suffix' ($relativeBacklogPath -ceq 'backlog/') $relativeBacklogPath
                            $outside = Join-Path $root ($leaf + '-old/../outside')
                            Write-BoundaryFile (Join-Path $native '.crucible/config.yaml') ("paths:`n  backlog: '" + $outside + "'`n")
                            . $display
                            $expected = [IO.Path]::GetFullPath($outside).Replace('\', '/').TrimEnd('/') + '/'
                            Assert-Result 'outside display stays absolute and canonical' ($relativeBacklogPath -ceq $expected) $relativeBacklogPath
                        }
                        { $_ -in @('prune-root', 'prune-candidate') } {
                            $bundle = Join-Path $native 'bundle'
                            $candidate = Join-Path $bundle 'old/nested'
                            New-Item -ItemType Directory -Path $candidate -Force | Out-Null
                            $sibling = Join-Path $native 'bundle-old/empty'
                            New-Item -ItemType Directory -Path $sibling -Force | Out-Null
                            Write-BoundaryFile (Join-Path $bundle 'kept/.hidden') 'keep'
                            $rootArgument = if ($site -eq 'prune-root') { Join-Path $inputPath 'bundle' } else { $bundle }
                            $candidateArgument = if ($site -eq 'prune-candidate') { Join-Path $inputPath 'bundle/old/nested' } else { $candidate }
                            $removed = Remove-EmptiedBundleDirectory -BundleRoot $rootArgument -Candidates @($candidateArgument, $sibling, (Join-Path $bundle 'kept'), $rootArgument)
                            Assert-Result 'two empty levels pruned' ($removed -eq 2 -and -not (Test-Path -LiteralPath (Join-Path $bundle 'old'))) "removed=$removed"
                            Assert-Result 'bundle root and sibling retained' ((Test-Path -LiteralPath $bundle) -and (Test-Path -LiteralPath $sibling)) 'pruning escaped bundle'
                            Assert-Result 'hidden contents retained' (Test-Path -LiteralPath (Join-Path $bundle 'kept/.hidden')) 'hidden file pruned'
                        }
                        { $_ -in @('staged-scope', 'staged-candidate') } {
                            $null = Invoke-Git @('init', '--quiet', $native)
                            Write-BoundaryFile (Join-Path $native 'docs/Guide.md') ([string][char]0x00C3)
                            Write-BoundaryFile (Join-Path $native 'docs-old/Outside.md') ([string][char]0x00C3)
                            $null = Invoke-Git @('add', '-A') -Directory $native
                            $contentArgument = if ($site -eq 'staged-candidate') { $inputPath } else { $native }
                            $scopeArgument = if ($site -eq 'staged-scope') { Join-Path $inputPath 'docs' } else { Join-Path $native 'docs' }
                            $output = & (Get-PwshCommand) -NoProfile -NonInteractive -File $wrapper $REPO_ROOT $root $contentArgument $scopeArgument no 2>&1 | Out-String
                            Assert-Result 'staged marker refuses with exit 1' ($LASTEXITCODE -eq 1) $output
                            Assert-Result 'one scoped file scanned' ($output -match 'SCOPED=1' -and $output -match '\[FAIL\].*mojibake' -and $output -notmatch 'Outside.md') $output
                            Assert-Result 'refusal cannot be caught or return' ($output -notmatch 'CAUGHT_GATE|RETURNED_AFTER_GATE') $output
                        }
                    }
                }
            }
        }
        $results += Run-Test 'Staged qualification failure refuses unconditionally' {
            $native = Join-Path $root 'staged-error'
            New-Item -ItemType Directory -Path $native | Out-Null
            $null = Invoke-Git @('init', '--quiet', $native)
            $output = & (Get-PwshCommand) -NoProfile -NonInteractive -File $wrapper $REPO_ROOT $root $native $native yes 2>&1 | Out-String
            Assert-Result 'qualification refusal exit 1' ($LASTEXITCODE -eq 1) $output
            Assert-Result 'explicit failure and no catch or return' ($output -match '\[FAIL\] Cannot qualify staged scope:' -and $output -notmatch 'CAUGHT_GATE|SCOPED=|RETURNED_AFTER_GATE') $output
        }
        $results += Run-Test 'Public staged entrypoint scans the native default scope' {
            $native = Join-Path $root 'staged-public'
            $gateDir = Join-Path $native 'powershell/gates'
            $libDir = Join-Path $native 'powershell/lib'
            New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
            New-Item -ItemType Directory -Path $libDir -Force | Out-Null
            Copy-Item -LiteralPath $gate -Destination $gateDir
            Copy-Item -LiteralPath (Join-Path $REPO_ROOT 'powershell/lib/config-helpers.ps1') -Destination $libDir
            $null = Invoke-Git @('init', '--quiet', $native)
            $doc = Join-Path $native 'docs/Guide.md'
            Write-BoundaryFile $doc ([string][char]0x00C3)
            Write-BoundaryFile (Join-Path $native 'docs-old/Outside.md') ([string][char]0x00C3)
            $null = Invoke-Git @('add', 'docs', 'docs-old') -Directory $native
            $installedGate = Join-Path $gateDir 'check-mojibake.ps1'
            $output = & (Get-PwshCommand) -NoProfile -NonInteractive -File $installedGate -Staged 2>&1 | Out-String
            Assert-Result 'public staged marker refusal' ($LASTEXITCODE -eq 1 -and $output -match 'Guide.md' -and $output -notmatch 'Outside.md') $output
            Write-BoundaryFile $doc 'clean'
            $null = Invoke-Git @('add', 'docs') -Directory $native
            $output = & (Get-PwshCommand) -NoProfile -NonInteractive -File $installedGate -Staged 2>&1 | Out-String
            Assert-Result 'public staged clean scan' ($LASTEXITCODE -eq 0 -and $output -match 'in 1 scoped file') $output
            Remove-Item -LiteralPath (Join-Path $libDir 'config-helpers.ps1')
            $output = & (Get-PwshCommand) -NoProfile -NonInteractive -File $installedGate -Staged 2>&1 | Out-String
            Assert-Result 'missing qualification owner refuses explicitly' ($LASTEXITCODE -eq 1 -and $output -match '\[FAIL\] Cannot qualify staged scope: Filesystem qualification helper not found') $output
        }
    } finally { Pop-Location }
} finally {
    Remove-PSDrive Item330 -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-TestFileSummary -Results $results
