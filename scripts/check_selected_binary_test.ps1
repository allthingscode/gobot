# Offline fixtures: native calls are intercepted; Gobot never runs.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/check_selected_binary.ps1"
$nativeAdapter = ${function:Invoke-BinaryNative}
$nativeResult = & $nativeAdapter 'git' @('--version')
if ($nativeResult.Code -ne 0) { throw 'Native adapter did not capture successful inspection' }
$nativeResult = & $nativeAdapter 'missing-binary-fixture-command' @()
if ($nativeResult.Code -eq 0) { throw 'Native adapter did not preserve missing tool failure' }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('selected binary fixture ' + [guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $fixture 'bin') -Force | Out-Null
$original = Get-Location
$script:selected = Join-Path $fixture 'bin/gobot.exe'
$rootBinary = Join-Path $fixture 'gobot.exe'
$script:revision = '1234567890123456789012345678901234567890'
$script:baseMetadata = @(
    ($script:selected + ': go1.26.9'),
    "path`tgithub.com/allthingscode/gobot/cmd/gobot",
    "mod`tgithub.com/allthingscode/gobot`t(devel)",
    "dep`texample.org/library`tv1.0.0`thash",
    "build`tGOOS=windows", "build`tGOARCH=amd64", "build`tCGO_ENABLED=0",
    "build`tvcs=git", "build`tvcs.revision=$script:revision",
    "build`tvcs.time=2026-10-10T12:00:00Z", "build`tvcs.modified=false"
)
$script:baseGraph = '{"Path":"github.com/allthingscode/gobot","Main":true}' + "`n" + '{"Path":"example.org/library","Version":"v1.0.0"}'
function Assert-Binary($condition, $message) { if (-not $condition) { throw $message } }
function Invoke-BinaryNative {
    param([string]$Command, [string[]]$Arguments)
    Assert-Binary ($Command -eq 'go' -or $Command -eq 'git') 'Selected executable used as command!'
    $script:calls += ,@($Command, $Arguments)
    if ($Arguments[0] -eq 'version') {
        Assert-Binary ($Arguments.Count -eq 3 -and $Arguments[1] -eq '-m' -and $Arguments[2] -eq $script:selected) 'Wrong metadata input'
        if ($script:case -eq 'native throw') { throw 'go missing' }
        return [pscustomobject]@{ Code=$script:metadataCode; Output=$script:metadata }
    }
    if ($Command -eq 'git') { return [pscustomobject]@{ Code=$script:headCode; Output=@($script:revision) } }
    if ($Arguments[0] -eq 'env') { return [pscustomobject]@{ Code=$script:goCode; Output=@('go1.26.9') } }
    Assert-Binary (($Arguments -join ' ') -eq 'list -mod=readonly -m -json all') 'Graph must be readonly'
    return [pscustomobject]@{ Code=$script:graphCode; Output=@($script:graph) }
}
function Invoke-SecurityNative {
    param([string]$Command, [string[]]$Arguments)
    if ($Arguments[0] -eq 'version') {
        return [pscustomobject]@{ Code=0; Output=@('path golang.org/x/vuln/cmd/govulncheck', 'mod golang.org/x/vuln v1.8.0') }
    }
    Assert-Binary ($Command -ne $script:selected) 'Selected executable used as scanner!'
    Assert-Binary ($Arguments.Count -eq 2 -and $Arguments[0] -eq '-mode=binary' -and $Arguments[1] -eq $script:selected) 'Wrong scan input'
    $script:scans++
    return [pscustomobject]@{ Code=$script:scanCode; Output=@('fixture retained-symbol result') }
}
function Get-Command {
    param($Name, $CommandType, $ErrorAction)
    if ($Name -eq 'govulncheck') { return [pscustomobject]@{ Source=(Join-Path $fixture 'scanner.exe') } }
    Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
}
try {
    Set-Content -LiteralPath (Join-Path $fixture 'go.mod') -Value "module github.com/allthingscode/gobot`ngo 1.26.9"
    Set-Content -LiteralPath $script:selected -Value 'inspection input only'
    Set-Content -LiteralPath $rootBinary -Value 'inspection input only'
    Set-Location $env:TEMP
    $callerLocation = (Get-Location).Path
    Assert-Binary ((Resolve-SelectedBinary $fixture) -eq $script:selected) 'bin preference/caller location'
    Set-Location $fixture
    Assert-Binary ((Resolve-SelectedBinary '.') -eq $script:selected) 'Relative root must use caller location'
    Set-Location $callerLocation
    Remove-Item -LiteralPath $script:selected
    Assert-Binary ((Resolve-SelectedBinary $fixture) -eq $rootBinary) 'root fallback'
    Remove-Item -LiteralPath $rootBinary
    foreach ($selection in @('missing', 'non-file bin', 'non-file root')) {
        if ($selection -eq 'non-file bin') { New-Item -ItemType Directory -Path $script:selected | Out-Null }
        if ($selection -eq 'non-file root') { New-Item -ItemType Directory -Path $rootBinary | Out-Null }
        $failed = $false
        try { Resolve-SelectedBinary $fixture | Out-Null } catch { $failed = $true }
        Assert-Binary $failed $selection
        if ($selection -eq 'non-file bin') { Remove-Item -LiteralPath $script:selected }
        if ($selection -eq 'non-file root') { Remove-Item -LiteralPath $rootBinary }
    }
    Set-Content -LiteralPath $script:selected -Value 'inspection input only'
    $script:scans=0
    Remove-Item -LiteralPath $script:selected
    $missingReport=@(Invoke-SelectedBinaryCheck -ProjectRoot $fixture 6>&1)
    Assert-Binary ($missingReport[-1] -ne 0 -and ($missingReport -join ' ') -match 'Missing gobot.exe') 'Missing binary preflight status'
    New-Item -ItemType Directory -Path $script:selected | Out-Null
    Set-Content -LiteralPath $rootBinary -Value 'fallback must not hide invalid preferred candidate'
    $invalidReport=@(Invoke-SelectedBinaryCheck -ProjectRoot $fixture 6>&1)
    Assert-Binary ($invalidReport[-1] -ne 0 -and ($invalidReport -join ' ') -match 'not a file') 'Non-file preferred binary status'
    Assert-Binary ($script:scans -eq 0) 'Invalid binary reached scanner'
    Remove-Item -LiteralPath $script:selected
    Set-Content -LiteralPath $script:selected -Value 'inspection input only'
    $cases = @('clean', 'dirty', 'revision', 'toolchain', 'dependency', 'replacement', 'replacement clean', 'replacement original', 'local replacement', 'omitted setting', 'omitted path', 'malformed', 'native error', 'native throw', 'finding', 'database', 'git error', 'go error', 'graph error', 'graph malformed', 'graph duplicate', 'wrong main', 'wrong module', 'wrong OS', 'wrong CGO', 'bad modified', 'bad time', 'main replacement')
    foreach ($case in $cases) {
        $script:case=$case; $script:metadata=@($script:baseMetadata); $script:graph=$script:baseGraph
        $script:metadataCode=0; $script:scanCode=0; $script:headCode=0; $script:goCode=0; $script:graphCode=0
        $script:scans=0; $script:calls=@()
        $expected=1; $expectedScans=1
        switch ($case) {
            'clean' { $expected=0 }
            'dirty' { $script:metadata=$script:metadata -replace 'vcs.modified=false','vcs.modified=true' }
            'revision' { $script:metadata=$script:metadata -replace $script:revision,('a' * 40) }
            'toolchain' { $script:metadata=$script:metadata -replace 'go1.26.9','go1.26.4' }
            'dependency' { $script:graph=$script:graph -replace 'v1.0.0','v1.1.0' }
            'replacement' { $script:metadata = @($script:metadata[0..3]) + @("=>`texample.org/fork`tv2.0.0") + @($script:metadata[4..10]) }
            'replacement clean' {
                $script:metadata = @($script:metadata[0..3]) + @("=>`texample.org/fork`tv2.0.0") + @($script:metadata[4..10])
                $script:graph=$script:graph -replace '"Version":"v1.0.0"','"Version":"v1.0.0","Replace":{"Path":"example.org/fork","Version":"v2.0.0"}'
                $expected=0
            }
            'replacement original' { $script:graph=$script:graph -replace '"Version":"v1.0.0"','"Version":"v1.0.0","Replace":{"Path":"example.org/fork","Version":"v2.0.0"}' }
            'local replacement' {
                $script:metadata = @($script:metadata[0..3]) + @("=>`t../local`t(devel)") + @($script:metadata[4..10])
                $script:graph=$script:graph -replace '"Version":"v1.0.0"','"Version":"v1.0.0","Replace":{"Path":"../local"}'
            }
            'omitted setting' { $script:metadata=@($script:metadata | Where-Object { $_ -notmatch 'GOARCH=' }) }
            'omitted path' { $script:metadata=@($script:metadata | Where-Object { $_ -notmatch '^path' }); $expectedScans=0 }
            'malformed' { $script:metadata+= 'build broken'; $expectedScans=0 }
            'native error' { $script:metadataCode=2; $expectedScans=0 }
            'native throw' { $expectedScans=0 }
            'finding' { $script:scanCode=3; $expected=3 }
            'database' { $script:scanCode=2; $expected=2 }
            'git error' { $script:headCode=1 }
            'go error' { $script:goCode=1 }
            'graph error' { $script:graphCode=1 }
            'graph malformed' { $script:graph='{"Path":' }
            'graph duplicate' { $script:graph += $script:graph }
            'wrong main' { $script:metadata=$script:metadata -replace '/cmd/gobot','/cmd/other' }
            'wrong module' { $script:metadata=$script:metadata -replace 'mod\s+github.com/allthingscode/gobot',"mod`twrong.org/module" }
            'wrong OS' { $script:metadata=$script:metadata -replace 'GOOS=windows','GOOS=linux' }
            'wrong CGO' { $script:metadata=$script:metadata -replace 'CGO_ENABLED=0','CGO_ENABLED=1' }
            'bad modified' { $script:metadata=$script:metadata -replace 'modified=false','modified=unknown' }
            'bad time' { $script:metadata=$script:metadata -replace '2026-10-10T12:00:00Z','nonsense' }
            'main replacement' { $script:metadata = @($script:metadata[0..2]) + @("=>`t../main`t(devel)") + @($script:metadata[3..10]) }
        }
        $report=@(Invoke-SelectedBinaryCheck -ProjectRoot $fixture 6>&1)
        $result=$report[-1]
        $reportText=($report -join "`n")
        if ($expected -ne 0) {
            Assert-Binary ($reportText -match 'Rebuild:.*build.ps1' -and $reportText -match 'Recheck:.*check_selected_binary.ps1') 'Missing recovery instructions'
        }
        if ($case -eq 'toolchain') { Assert-Binary ($reportText -match 'Go toolchain mismatch' -and $reportText -match 'below go.mod') 'Independent toolchain/minimum reports' }
        if ($expectedScans -eq 0) { Assert-Binary ($reportText -match 'scan not performed') 'Unreadable evidence scan status missing' }
        Assert-Binary ($result -eq $expected) "$case status: $result expected $expected"
        Assert-Binary ($script:scans -eq $expectedScans) "$case scans: $script:scans"
        Assert-Binary ((Get-Location).Path -eq $callerLocation) 'Location not restored'
        Write-Host "PASS: $case"
    }
    # Preserve the actual early branch in a temporary launcher. A sentinel makes
    # every later runtime action fail; the fixture helper returns only a status.
    $launcherRoot=Join-Path $fixture 'launcher'
    New-Item -ItemType Directory -Path (Join-Path $launcherRoot 'scripts') -Force | Out-Null
    $launcher=Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'start_gobot.ps1') -Raw
    $marker=$launcher.IndexOf('[Console]')
    Assert-Binary ($marker -gt 0) 'Launcher branch absent'
    $prefix=$launcher.Substring(0,$marker)
    Set-Content -LiteralPath (Join-Path $launcherRoot 'start_gobot.ps1') -Value ($prefix + "throw 'Runtime action reached'")
    foreach ($code in @(0, 3)) {
        $stub='function Invoke-SelectedBinaryCheck { param($ProjectRoot); if ($ProjectRoot -ne (Split-Path $PSScriptRoot -Parent)) { throw ''wrong project root'' }; return ' + $code + ' }'
        Set-Content -LiteralPath (Join-Path $launcherRoot 'scripts/check_selected_binary.ps1') -Value $stub
        $hostPath=(Get-Process -Id $PID).Path
        & $hostPath -NoProfile -File (Join-Path $launcherRoot 'start_gobot.ps1') -CheckBinaryOnly
        Assert-Binary ($LASTEXITCODE -eq $code) 'CheckBinaryOnly status/early exit'
    }
    # Exercise build environment restoration with fake Go/git commands. No real
    # compilation, resources, binary or service operations are performed.
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'build.ps1') -Destination (Join-Path $launcherRoot 'scripts/build.ps1')
    $buildHarness = @'
$ErrorActionPreference = 'Stop'
function git { $global:LASTEXITCODE=0; return 'fixture' }
function go {
    if ($env:CGO_ENABLED -ne '0') { throw 'Build enabled CGO' }
    if ($script:failBuild) { throw 'fixture build failure' }
    $global:LASTEXITCODE=0
}
function Get-Command { return $null }
$env:CGO_ENABLED='1'
$script:failBuild=$false
$before=(Get-Location).Path
. (Join-Path $PSScriptRoot 'scripts/build.ps1')
if ($env:CGO_ENABLED -ne '1' -or (Get-Location).Path -ne $before) { throw 'Build environment/location not restored' }
[Environment]::SetEnvironmentVariable('CGO_ENABLED', $null, 'Process')
. (Join-Path $PSScriptRoot 'scripts/build.ps1')
if ($env:CGO_ENABLED) { throw 'Absent CGO environment not restored' }
$env:CGO_ENABLED='1'
$script:failBuild=$true
$failed=$false
try { . (Join-Path $PSScriptRoot 'scripts/build.ps1') } catch { $failed=$true }
if (-not $failed -or $env:CGO_ENABLED -ne '1' -or (Get-Location).Path -ne $before) { throw 'Failed build environment/location not restored' }
'@
    Set-Content -LiteralPath (Join-Path $launcherRoot 'build_harness.ps1') -Value $buildHarness
    & $hostPath -NoProfile -File (Join-Path $launcherRoot 'build_harness.ps1')
    Assert-Binary ($LASTEXITCODE -eq 0) 'Pure-Go build fixture failed'
} finally {
    Set-Location $original
    $resolved=[IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'All selected-binary offline cases passed.'
