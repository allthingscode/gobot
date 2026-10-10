# Offline table-driven tests. No scanner installation, database or network access.
param([ValidateSet('linux', 'windows')][string]$TargetOS = 'linux')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/check_security.ps1"
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('security fixture ' + [guid]::NewGuid())
New-Item -ItemType Directory $fixture | Out-Null
$original = Get-Location
$names = @('GOFLAGS', 'GOBIN', 'GOOS', 'GOARCH', 'CGO_ENABLED')
$before = @{}
foreach ($name in $names) { $before[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Assert-Security($condition, $message) { if (-not $condition) { throw $message } }
function Get-Command {
    param($Name, $CommandType, $ErrorAction)
    if ($Name -eq 'govulncheck') {
        if ($script:case.Identity -ne 'missing') { [pscustomobject]@{ Source = (Join-Path $fixture 'old scanner.exe') } }
    } else { Microsoft.PowerShell.Core\Get-Command @PSBoundParameters }
}
function Invoke-SecurityNative {
    param([string]$Command, [string[]]$Arguments)
    $script:calls += ,@($Command, ($Arguments -join ' '))
    if ($Arguments[0] -eq 'version') {
        $script:identityCount++
        if ($script:case.Identity -eq 'metadata-error' -or ($script:case.Name -eq 'revalidation failure' -and $script:identityCount -gt 1)) {
            return [pscustomobject]@{ Output = @('metadata unavailable'); Code = 2 }
        }
        $version = if ($script:case.Identity -eq 'old' -and $script:identityCount -eq 1) { 'v1.2.0' } else { 'v1.8.0' }
        $module = if ($script:case.Identity -eq 'wrong-module' -and $script:identityCount -eq 1) { 'example.org/wrong' } else { 'golang.org/x/vuln' }
        $path = if ($script:case.Identity -eq 'wrong-path' -and $script:identityCount -eq 1) { 'example.org/tool' } else { 'golang.org/x/vuln/cmd/govulncheck' }
        return [pscustomobject]@{ Output = @("path`t$path", "mod`t$module`t$version") ; Code = 0 }
    }
    if ($Arguments[0] -eq 'install') {
        Assert-Security ($Arguments[1] -eq 'golang.org/x/vuln/cmd/govulncheck@v1.8.0') 'Wrong install pin'
        Assert-Security (-not $env:GOOS -and -not $env:GOARCH) 'Install must target host'
        return [pscustomobject]@{ Output = @(); Code = $script:case.InstallCode }
    }
    Assert-Security ([IO.Path]::IsPathRooted($Command)) 'Scanner must use absolute path'
    if ($script:binaryMode) { Assert-Security ($Arguments.Count -eq 2 -and $Arguments[0] -eq '-mode=binary' -and $Arguments[1] -eq $script:binaryFile) 'Wrong binary arguments' } else { Assert-Security (($Arguments -join ' ') -eq './internal/... ./cmd/...') 'Wrong production scopes' }
    Assert-Security ($env:GOFLAGS -eq '-tags=test -mod=readonly') 'Readonly flags not preserved'
    Assert-Security ($env:CGO_ENABLED -eq '0' -and $env:GOOS -eq $TargetOS -and $env:GOARCH -eq 'amd64') 'Wrong scan target'
    Assert-Security ((Get-Location).Path -eq (Split-Path $PSScriptRoot -Parent)) 'Wrong repository location'
    return [pscustomobject]@{ Output = @('fake scan'); Code = $script:case.ScanCode }
}
$cases = @(
    @{Name='selected'; Identity='selected'; InstallCode=0; ScanCode=0; Expected=0; Installs=0},
    @{Name='missing'; Identity='missing'; InstallCode=0; ScanCode=0; Expected=0; Installs=1},
    @{Name='old'; Identity='old'; InstallCode=0; ScanCode=0; Expected=0; Installs=1},
    @{Name='wrong module'; Identity='wrong-module'; InstallCode=0; ScanCode=0; Expected=0; Installs=1},
    @{Name='wrong path'; Identity='wrong-path'; InstallCode=0; ScanCode=0; Expected=0; Installs=1},
    @{Name='install failure'; Identity='missing'; InstallCode=3; ScanCode=0; Expected=3; Installs=1},
    @{Name='metadata failure'; Identity='metadata-error'; InstallCode=0; ScanCode=0; Expected=1; Installs=1},
    @{Name='revalidation failure'; Identity='old'; InstallCode=0; ScanCode=0; Expected=1; Installs=1},
    @{Name='reachable finding'; Identity='selected'; InstallCode=0; ScanCode=3; Expected=3; Installs=0},
    @{Name='database failure'; Identity='selected'; InstallCode=0; ScanCode=2; Expected=2; Installs=0},
    @{Name='tool failure'; Identity='selected'; InstallCode=0; ScanCode=1; Expected=1; Installs=0}
)
try {
    $script:binaryFile = Join-Path $fixture 'selected gobot.exe'
    Set-Content -LiteralPath $script:binaryFile -Value 'not executable'
    foreach ($binaryMode in @($false, $true)) {
        $script:binaryMode = $binaryMode
        foreach ($case in $cases) {
            $script:case = $case; $script:calls = @(); $script:identityCount = 0
            $env:GOFLAGS='-tags=test'; $env:GOBIN='original bin'; $env:GOOS=$TargetOS; $env:GOARCH='amd64'; $env:CGO_ENABLED='1'
            Set-Location $fixture
            $binaryArgument = if ($binaryMode) { 'selected gobot.exe' } else { '' }
            $result = Invoke-SecurityCheck -ToolDirectory (Join-Path $fixture 'tools with spaces') -BinaryPath $binaryArgument
            Assert-Security ($result -eq $case.Expected) ($case.Name + ': unexpected exit ' + $result)
            $installs = @($script:calls | Where-Object { $_[1] -like 'install *' }).Count
            Assert-Security ($installs -eq $case.Installs) ($case.Name + ': wrong install count')
            Assert-Security ((Get-Location).Path -eq $fixture) 'Location not restored'
            Assert-Security ($env:GOFLAGS -eq '-tags=test' -and $env:GOBIN -eq 'original bin' -and $env:GOOS -eq $TargetOS -and $env:GOARCH -eq 'amd64' -and $env:CGO_ENABLED -eq '1') 'Environment not restored'
            Write-Host ('PASS: ' + $case.Name)
        }
    }
    $script:calls = @()
    $invalid = Invoke-SecurityCheck -BinaryPath (Join-Path $fixture 'missing.exe')
    Assert-Security ($invalid -ne 0 -and $script:calls.Count -eq 0) 'Missing binary reached native scanner/provisioning'
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process') }
    Set-Location $original
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host ('All ' + ($cases.Count * 2) + ' offline source/binary security cases passed.')
