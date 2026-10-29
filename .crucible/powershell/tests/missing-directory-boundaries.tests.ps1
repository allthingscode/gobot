$ErrorActionPreference = 'Stop'
$framework = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $framework 'powershell/crucible-lib.ps1')
$results = @()
$root = New-TestFixtureRoot -NameHint 'missing-directory-boundaries'
try {
    $project = Join-Path $root 'project'
    $worktree = Join-Path $root 'worktree'
    New-Item -ItemType Directory -Path $project, $worktree | Out-Null
    New-PSDrive -Name Item331 -PSProvider FileSystem -Root $root | Out-Null
    $generatorText = [IO.File]::ReadAllText((Join-Path $framework 'powershell/new-handoff.ps1'))
    $start = $generatorText.IndexOf('$resolvedWtPath =')
    $end = $generatorText.IndexOf('$resolvedArtifacts = $normalizedArtifacts', $start)
    $generator = [scriptblock]::Create($generatorText.Substring($start, $end - $start))
    foreach ($caller in @('owner', 'generator')) {
        foreach ($operand in @('worktree', 'project')) {
            foreach ($shape in @('native', '/', '\')) {
                $results += Run-Test "Missing directory qualification: $caller $operand $shape" {
                    if ($shape -ne 'native' -and -not $IsWindows) { Skip-Test 'Windows root-relative directory operands.' }
                    Push-Location 'Item331:/'
                    try {
                        $missing = if ($shape -eq 'native') { Join-Path $root 'missing' } else { $shape + 'missing' }
                        $artifact = $missing + '/Docs/File.md'
                        $wtPath = if ($operand -eq 'worktree') { $missing } else { $worktree }
                        $repoArgument = if ($operand -eq 'project') { $missing } else { $project }
                        $actual = @(if ($caller -eq 'owner') {
                            @(Normalize-HandoffArtifactPaths -Artifacts @($artifact) -WorktreePath $wtPath -ProjectRoot $repoArgument)
                        } else {
                            @(Invoke-ExternalCommand -AsLines { & {
                                $REPO_ROOT = $repoArgument
                                $resolvedArtifacts = @($artifact)
                                . $generator
                                $normalizedArtifacts
                            } })
                        })
                        Assert-Result 'contained suffix retains case' ($actual.Count -eq 1 -and $actual[0] -ceq 'Docs/File.md') ($actual -join ',')
                        $outside = Join-Path $root 'outside/../Other.md'
                        $kept = @(Normalize-HandoffArtifactPaths -Artifacts @($outside) -WorktreePath $wtPath -ProjectRoot $repoArgument)
                        Assert-Result 'outside spelling retained' ($kept.Count -eq 1 -and $kept[0] -ceq $outside.Replace('\', '/')) ($kept -join ',')
                    } finally { Pop-Location }
                }
            }
        }
    }
    $runner = Join-Path $root 'caller.ps1'
    [IO.File]::WriteAllText($runner, @'
param($Framework, $Fixture, $Bundle)
$ErrorActionPreference = 'Stop'
New-PSDrive -Name Item331 -PSProvider FileSystem -Root $Fixture | Out-Null
Set-Location Item331:/
function codex { throw 'A missing phase prompt must not start codex.' }
try {
    . (Join-Path $Framework 'powershell/launch-codex-specialist.ps1') -ProjectRoot 'Item331:/project' -CrucibleRoot $Bundle -TaskId T-331 -Phase research -Model inert
    exit $LASTEXITCODE
} catch { 'CAUGHT_LAUNCH'; throw }
'@, [Text.UTF8Encoding]::new($false))
    foreach ($shape in @('native', '/', '\')) {
        foreach ($outside in @($false, $true)) {
            $results += Run-Test "Missing launcher directory: $shape outside=$outside" {
                if ($shape -ne 'native' -and -not $IsWindows) { Skip-Test 'Windows root-relative bundle directory.' }
                $suffix = if ($outside) { 'outside/missing' } else { 'project/missing' }
                $bundle = if ($shape -eq 'native') { Join-Path $root $suffix } else { $shape + $suffix }
                $output = Invoke-ExternalCommand -AsLines { & (Get-PwshCommand) -NoProfile -NonInteractive -File $runner $framework $root $bundle 2>&1 } | Out-String
                Assert-Result 'CLI refuses with exit 2' ($LASTEXITCODE -eq 2 -and $output -notmatch 'CAUGHT_LAUNCH|must not start codex') $output
                if ($outside) {
                    Assert-Result 'outside refusal stays explicit' ($output -match 'absolute path outside it') $output
                } else {
                    Assert-Result 'inside path reaches missing-prompt diagnostic' ($output -match 'phase prompt not found' -and $output -notmatch 'absolute path outside it') $output
                }
            }
        }
    }
} finally {
    Remove-PSDrive Item331 -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-TestFileSummary -Results $results
