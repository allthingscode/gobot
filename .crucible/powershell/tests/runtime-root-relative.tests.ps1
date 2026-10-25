$ErrorActionPreference = 'Stop'
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/config-helpers.ps1')
$results = @()
$root = New-TestFixtureRoot -NameHint 'runtime-root-relative'
$utf8 = [Text.UTF8Encoding]::new($false)

function New-RuntimePathProject {
    $project = Join-Path $root ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $project '.crucible') -Force | Out-Null
    return $project
}
try {
    foreach ($key in @('session', 'workspaces')) {
        foreach ($separator in @('/', '\')) {
            foreach ($exists in @($false, $true)) {
                $results += Run-Test ("Runtime directory: key=$key separator=$separator existing=$exists") {
                    if (-not $IsWindows) { Skip-Test 'Root-relative runtime directories require Windows filesystem-drive semantics.' }
                    $project = New-RuntimePathProject
                    $leaf = 'runtime-' + [guid]::NewGuid().ToString('N')
                    $configured = $separator + $leaf
                    $directory = Join-Path $root $leaf
                    if ($exists) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
                    [IO.File]::WriteAllText((Join-Path $project '.crucible/config.yaml'), "paths:`n  ${key}: '$configured'`n", $utf8)
                    New-PSDrive Item326 FileSystem $root | Out-Null
                    Push-Location 'Item326:\'
                    try {
                        Assert-Result 'reader preserves configured spelling' ((Get-ConfiguredPath -Key $key -ProjectRoot $project) -ceq $configured) 'configured-value contract changed'
                        Assert-Result 'fixture existence' ((Test-Path -LiteralPath $directory) -eq $exists) 'wrong fixture shape'
                        Assert-Result 'ordinary git-status path is outside' (-not (Test-ConfiguredRuntimePath -Path 'src/file.md' -ProjectRoot $project)) 'source was exempted'
                        Assert-Result 'native child is runtime' (Test-ConfiguredRuntimePath -Path (Join-Path $directory 'missing.md') -ProjectRoot $project) 'native child missed'
                        Assert-Result 'root-relative child is runtime' (Test-ConfiguredRuntimePath -Path ($configured + $separator + 'missing.md') -ProjectRoot $project) 'candidate operand was not qualified'
                        Assert-Result 'directory itself is runtime' (Test-ConfiguredRuntimePath -Path $configured -ProjectRoot $project) 'directory missed'
                        Assert-Result 'root-relative sibling is outside' (-not (Test-ConfiguredRuntimePath -Path ($configured + '-old' + $separator + 'file.md') -ProjectRoot $project)) 'sibling was exempted'
                        Assert-Result 'native sibling is outside' (-not (Test-ConfiguredRuntimePath -Path ($directory + '-old/file.md') -ProjectRoot $project)) 'native sibling was exempted'
                        Assert-Result 'parent escape is outside' (-not (Test-ConfiguredRuntimePath -Path ($configured + $separator + '..' + $separator + 'outside.md') -ProjectRoot $project)) 'escape was exempted'
                        Assert-Result 'reader still preserves spelling' ((Get-ConfiguredPath -Key $key -ProjectRoot $project) -ceq $configured) 'qualification rewrote the reader'
                    } finally {
                        Pop-Location
                        Remove-PSDrive Item326
                    }
                }
            }
        }
    }
    foreach ($absolute in @($false, $true)) {
        $results += Run-Test ("Relative and native absolute runtime roots: absolute=$absolute") {
            $project = New-RuntimePathProject
            $session = if ($absolute) { Join-Path $project 'runtime/session' } else { 'runtime/session' }
            $workspaces = if ($absolute) { Join-Path $project 'runtime/workspaces' } else { 'runtime/workspaces' }
            [IO.File]::WriteAllText((Join-Path $project '.crucible/config.yaml'), "paths:`n  session: '$session'`n  workspaces: '$workspaces'`n", $utf8)
            foreach ($key in @('session', 'workspaces')) {
                Assert-Result ($key + ' relative child') (Test-ConfiguredRuntimePath -Path ("runtime/$key/missing.md") -ProjectRoot $project) 'relative path missed'
                Assert-Result ($key + ' full child') (Test-ConfiguredRuntimePath -Path (Join-Path $project "runtime/$key/missing.md") -ProjectRoot $project) 'absolute path missed'
                Assert-Result ($key + ' sibling') (-not (Test-ConfiguredRuntimePath -Path ("runtime/$key-old/file.md") -ProjectRoot $project)) 'sibling was exempted'
            }
            Assert-Result 'source path stays outside' (-not (Test-ConfiguredRuntimePath -Path 'src/file.md' -ProjectRoot $project)) 'source was exempted'
        }
    }
    $results += Run-Test 'Unreadable exclusion configuration cannot return a clean-worktree exemption' {
        $project = New-RuntimePathProject
        [IO.File]::WriteAllText((Join-Path $project '.crucible/config.yaml'), "paths:`n  session:`n    nested: invalid scalar`n", $utf8)
        $returned = $false
        $message = ''
        try {
            $null = Test-ConfiguredRuntimePath -Path 'src/file.md' -ProjectRoot $project
            $returned = $true
        } catch { $message = $_.Exception.Message }
        Assert-Result 'unreadable input propagates' (-not $returned -and $message -match 'Unreadable') $message
    }
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
Write-TestFileSummary -Results $results
