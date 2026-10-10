#!/usr/bin/env pwsh
# Single scanner-version policy for local, CI and release source checks.
param([string]$ToolDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-SecurityNative {
    param([string]$Command, [string[]]$Arguments)
    $output = & $Command @Arguments 2>&1
    $code = $LASTEXITCODE
    [pscustomobject]@{ Output = @($output); Code = $code }
}

function Test-SecurityIdentity {
    param([string]$Path)
    if (-not $Path) { return $false }
    $result = Invoke-SecurityNative 'go' @('version', '-m', $Path)
    return ($result.Code -eq 0 -and (($result.Output -join "`n") -match '(?m)^\s*mod\s+golang\.org/x/vuln\s+v1\.8\.0(?:\s|$)') -and (($result.Output -join "`n") -match '(?m)^\s*path\s+golang\.org/x/vuln/cmd/govulncheck\s*$'))
}

function Invoke-SecurityCheck {
    param([string]$ToolDirectory)
    $oldLocation = Get-Location
    $saved = @{}
    foreach ($name in @('GOFLAGS', 'GOBIN', 'GOOS', 'GOARCH', 'CGO_ENABLED')) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        Set-Location (Split-Path -Parent $PSScriptRoot)
        $env:GOFLAGS = (($env:GOFLAGS, '-mod=readonly') | Where-Object { $_ }) -join ' '
        $env:CGO_ENABLED = '0'
        $candidate = Get-Command govulncheck -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $scanner = if ($candidate) { $candidate.Source } else { $null }
        if (-not (Test-SecurityIdentity $scanner)) {
            if (-not $ToolDirectory) {
                $ToolDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.gobot-tools'
            }
            $ToolDirectory = [IO.Path]::GetFullPath($ToolDirectory)
            New-Item -ItemType Directory -Force -Path $ToolDirectory | Out-Null
            $env:GOBIN = $ToolDirectory
            # Install a host executable even when scanning a different target.
            [Environment]::SetEnvironmentVariable('GOOS', $null, 'Process')
            [Environment]::SetEnvironmentVariable('GOARCH', $null, 'Process')
            $install = Invoke-SecurityNative 'go' @('install', 'golang.org/x/vuln/cmd/govulncheck@v1.8.0')
            $install.Output | ForEach-Object { Write-Host $_ }
            if ($install.Code -ne 0) { return $install.Code }
            $suffix = if ([IO.Path]::DirectorySeparatorChar -eq '\') { '.exe' } else { '' }
            $scanner = Join-Path $ToolDirectory ('govulncheck' + $suffix)
            if (-not (Test-SecurityIdentity $scanner)) { throw 'Installed scanner identity could not be verified as govulncheck v1.8.0.' }
            foreach ($name in @('GOOS', 'GOARCH')) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        }
        Write-Host 'Running verified govulncheck v1.8.0...'
        $scan = Invoke-SecurityNative $scanner @('./internal/...', './cmd/...')
        $scan.Output | ForEach-Object { Write-Host $_ }
        if ($scan.Code -ne 0) { Write-Host 'Security scan failed: findings or scanner/database error. Release/push must stop.' }
        return $scan.Code
    } catch {
        Write-Host ('Security check failed: ' + $_.Exception.Message)
        return 1
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        Set-Location $oldLocation
    }
}

if ($MyInvocation.InvocationName -ne '.') { exit (Invoke-SecurityCheck $ToolDirectory) }
