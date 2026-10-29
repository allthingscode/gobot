$ErrorActionPreference = 'Stop'
$framework = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $framework 'powershell/lib/crucible-command.ps1')
$results = @()
$root = New-TestFixtureRoot -NameHint 'command-path-boundaries'
try {
    New-Item -ItemType Directory -Path (Join-Path $root 'powershell') | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'powershell/init-project.ps1'), 'param([string]$ProjectRoot, [switch]$Force)')
    New-PSDrive -Name Item333 -PSProvider FileSystem -Root $root | Out-Null
    foreach ($shape in @('native', 'alias', 'relative', 'root-relative')) {
        $results += Run-Test "Command binding uses native paths: $shape" {
            if ($shape -eq 'root-relative' -and -not $IsWindows) { Skip-Test 'Windows root-relative filesystem paths.' }
            Push-Location (Split-Path -Parent $root)
            try {
                $bundle = switch ($shape) {
                    native { $root }
                    alias { 'Item333:/' }
                    relative { Split-Path -Leaf $root }
                    root-relative { Push-Location 'Item333:/'; '/' }
                }
                try {
                    $script:CrucibleCommandParameterCache = @{}
                    $bound = Get-CrucibleScriptParameters -Script 'powershell/init-project.ps1' -BundleRoot $bundle
                    Assert-Result 'value and switch bind' ($bound.ContainsKey('ProjectRoot') -and -not $bound.ProjectRoot -and $bound.Force) ($bound.Keys -join ',')
                    $keys = @($script:CrucibleCommandParameterCache.Keys)
                    Assert-Result 'cache uses native canonical path' ($keys.Count -eq 1 -and $keys[0] -ceq (Join-Path $root 'powershell/init-project.ps1')) ($keys -join ',')
                    $again = Get-CrucibleScriptParameters -Script 'powershell/init-project.ps1' -BundleRoot $root
                    Assert-Result 'native and alias share cache' ($script:CrucibleCommandParameterCache.Count -eq 1 -and $again.Force) 'cache split'
                } finally { if ($shape -eq 'root-relative') { Pop-Location } }
            } finally { Pop-Location }
        }
    }
    $results += Run-Test 'Unavailable command remains an I15 comment' {
        $line = New-CrucibleCommand -Script 'powershell/init-project.ps1' -BundleRoot $root -CrucibleRoot $root -Parameters ([ordered]@{ NoSuchParameter = 'inert' })
        Assert-Result 'unavailable fallback' ($line -like '# (command unavailable:*') $line
    }
} finally {
    Remove-PSDrive Item333 -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-TestFileSummary -Results $results
