$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$DOCTOR_SCRIPT = Join-Path $REPO_ROOT "powershell/factory-doctor.ps1"

$results = @()

function Assert-Result {
    param([string]$Name, [bool]$Condition, [string]$FailureMessage)
    if (-not $Condition) { throw ("FAILED: " + $Name + " - " + $FailureMessage) }
}

function Run-Test {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ("`nTest: " + $Name) -ForegroundColor Cyan
    try {
        & $Body
        Write-Host "PASSED" -ForegroundColor Green
        return $true
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        return $false
    }
}

function Invoke-ExternalCommand {
    param([Parameter(Mandatory=$true)][scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Command 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [PSCustomObject]@{ Output = $output; ExitCode = $exitCode }
}

function Write-DoctorFixture {
    param([string]$ProjectRoot)
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot ".crucible") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot "scripts/hooks") -Force | Out-Null

    @(
        'crucible_root: ".crucible"',
        'crucible_version: "test"',
        'crucible_install_commit: "test"',
        '',
        'project:',
        '  name: "Doctor Test"',
        '  description: "Synthetic doctor fixture."',
        '  default_branch: "main"',
        '',
        'paths:',
        '  backlog: .crucible/backlog',
        '  session: .crucible/session',
        '  workspaces: .crucible/.agent-workspaces',
        '  prompts: .crucible/prompts',
        '',
        'verification:',
        '  quick:',
        '    - name: test',
        '      command: powershell.exe -NoProfile -Command "exit 0"'
    ) | Set-Content -LiteralPath (Join-Path $ProjectRoot ".crucible/config.yaml") -Encoding UTF8

    @(
        '#!/bin/sh',
        'exit 0'
    ) | Set-Content -LiteralPath (Join-Path $ProjectRoot "scripts/hooks/pre-commit") -Encoding UTF8
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-factory-doctor-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Doctor emits structured results" -Body {
        $projectRoot = Join-Path $tempRoot "project"
        Write-DoctorFixture -ProjectRoot $projectRoot

        $res = Invoke-ExternalCommand {
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File $DOCTOR_SCRIPT -ProjectRoot $projectRoot
        }
        $output = $res.Output -join "`n"

        Assert-Result -Name "readiness header" -Condition ($output -match "\[DOCTOR\] Factory Readiness Check") -FailureMessage "doctor did not emit the readiness header. Output:`n$output"
        Assert-Result -Name "pass section" -Condition ($output -match "PASS \(") -FailureMessage "doctor did not emit a PASS section. Output:`n$output"
        Assert-Result -Name "warn section" -Condition ($output -match "WARN \(") -FailureMessage "doctor did not emit a WARN section. Output:`n$output"
        Assert-Result -Name "fail section" -Condition ($output -match "FAIL \(") -FailureMessage "doctor did not emit a FAIL section. Output:`n$output"
        Assert-Result -Name "at least one pass" -Condition ($output -match "PASS \([1-9]") -FailureMessage "doctor emitted no passing checks. Output:`n$output"
        Assert-Result -Name "result line" -Condition ($output -match "\[DOCTOR\] Result:") -FailureMessage "doctor did not run to completion. Output:`n$output"
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
