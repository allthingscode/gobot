Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Get-ChildItem -Path (Join-Path $PSScriptRoot "tests") -Filter '*test*.ps1' | ForEach-Object {
    Write-Host "Running $($_.Name)..." -ForegroundColor Cyan
    & $_.FullName
}
