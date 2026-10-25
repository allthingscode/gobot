$ErrorActionPreference = 'Stop'
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/config-helpers.ps1')
$results = @()
$root = New-TestFixtureRoot -NameHint 'filesystem-qualification'
try {
    $results += Run-Test 'Qualification keeps full outside paths verbatim' {
        $paths = @((Join-Path $root 'outside/../missing.md'))
        if ($IsWindows) { $paths += @('\\server\share\missing.md', '\\?\C:\missing\file.md', 'D:\outside\missing.md') }
        else { $paths += '/outside/missing.md' }
        foreach ($path in $paths) {
            Assert-Result $path ((Resolve-FilesystemPath -Path $path) -ceq $path) 'fully qualified spelling changed'
        }
        Write-Host ("Executed full-path cases: " + $paths.Count)
    }
    $results += Run-Test 'Qualification uses the PowerShell location for relative missing paths' {
        Push-Location $root
        try {
            Assert-Result 'relative missing path' ((Resolve-FilesystemPath 'missing.md') -ceq (Join-Path $root 'missing.md')) 'process directory selected'
        } finally { Pop-Location }
    }
    $results += Run-Test 'Qualification rejects a non-filesystem provider' {
        $message = ''
        try { Resolve-FilesystemPath 'Env:CRUCIBLE_ITEM328_INERT' } catch { $message = $_.Exception.Message }
        Assert-Result 'provider diagnostic' ($message -match 'Cannot qualify a filesystem path from provider') $message
    }
    foreach ($separator in @('/', '\')) {
        foreach ($exists in @($false, $true)) {
            $results += Run-Test ("Root-relative provider path: separator=$separator existing=$exists") {
                if (-not $IsWindows) { Skip-Test 'Root-relative paths depend on a Windows filesystem drive.' }
                New-PSDrive -Name Item328 -PSProvider FileSystem -Root $root | Out-Null
                Push-Location 'Item328:\'
                try {
                    $leaf = if ($exists) { 'existing.md' } else { 'missing.md' }
                    $expected = Join-Path $root $leaf
                    if ($exists) { [IO.File]::WriteAllText($expected, 'inert') }
                    $inputPath = $separator + $leaf
                    $resolved = Resolve-PathFromRoot -Root 'C:\unused' -Path $inputPath
                    Assert-Result 'rooted resolver stays verbatim' ($resolved -ceq $inputPath) $resolved
                    $full = Resolve-FilesystemPath -Path $resolved
                    Assert-Result 'provider drive selected' ($full -ceq $expected) $full
                    Assert-Result 'process drive differs' ([IO.Path]::GetFullPath($inputPath) -cne $full) 'fixture did not distinguish process from PowerShell drive'
                    Assert-Result 'containment accepts qualified input' (Test-PathWithinDirectory -Path $full -Directory $root) $full
                    Assert-Result 'relative suffix' ((Get-PathRelativeToDirectory -Path $full -Directory $root) -ceq $leaf) $full
                    $message = ''
                    try { Test-PathWithinDirectory -Path $inputPath -Directory $root } catch { $message = $_.Exception.Message }
                    Assert-Result 'containment still requires full inputs' ($message -match 'must both be absolute') $message
                } finally {
                    Pop-Location
                    Remove-PSDrive Item328
                }
            }
        }
    }
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
Write-TestFileSummary -Results $results
