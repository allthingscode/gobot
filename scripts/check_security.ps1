#!/usr/bin/env pwsh
# check_security.ps1 — Local security validation. Mirrors the CI govulncheck job.
# Usage: ./scripts/check_security.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Ensure UTF-8 output for Windows PowerShell
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "Running govulncheck..." -ForegroundColor Cyan

# Check if govulncheck is in the PATH
if (-not (Get-Command govulncheck -ErrorAction SilentlyContinue)) {
    # If not in PATH, check if it exists in GOPATH/bin
    $gopath = go env GOPATH
    $vulnCheckPath = Join-Path $gopath "bin" "govulncheck"
    if (Test-Path "$vulnCheckPath.exe") {
        Write-Host "govulncheck found in GOPATH/bin. Adding to session PATH." -ForegroundColor Yellow
        $env:PATH += ";$gopath\bin"
    } else {
        Write-Host "govulncheck not found. Installing..." -ForegroundColor Yellow
        go install golang.org/x/vuln/cmd/govulncheck@latest
        # Ensure it's in the PATH for this session
        $env:PATH += ";$gopath\bin"
    }
}

# Run govulncheck with package scopes that work with this repository layout.
# Avoid bare ./... from repo root due known package-pattern failures in scripts/.
govulncheck ./internal/... ./cmd/...

if ($LASTEXITCODE -ne 0) {
    Write-Host "`nSECURITY: Reachable vulnerabilities detected. Fix before pushing." -ForegroundColor Red
    exit 1
}

Write-Host "`nNo reachable vulnerabilities found." -ForegroundColor Green
exit 0
