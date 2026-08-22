$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")

$SCRIPT = Join-Path $REPO_ROOT "powershell/gates/check-policy-drift.ps1"
$results = @()

function Invoke-TestGit {
    param([string]$Directory, [string[]]$GitArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(git -C $Directory @GitArgs 2>$null)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        throw ("git " + ($GitArgs -join " ") + " failed with exit " + $exitCode + ". Output:`n" + (($output | Out-String).Trim()))
    }
    return $output
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function New-PolicyDriftFixture {
    param(
        [string]$Root,
        [bool]$IgnoreCrucible
    )
    New-Item -ItemType Directory -Path (Join-Path $Root "powershell/gates") -Force | Out-Null
    Copy-Item -LiteralPath $SCRIPT -Destination (Join-Path $Root "powershell/gates/check-policy-drift.ps1") -Force
    Write-Utf8NoBom -Path (Join-Path $Root "docs/policy.md") -Content "# Policy`n"
    if ($IgnoreCrucible) {
        Write-Utf8NoBom -Path (Join-Path $Root ".gitignore") -Content ".crucible/`n"
    }
    Invoke-TestGit -Directory $Root -GitArgs @("init") | Out-Null
    Invoke-TestGit -Directory $Root -GitArgs @("config", "user.email", "crucible-test@example.invalid") | Out-Null
    Invoke-TestGit -Directory $Root -GitArgs @("config", "user.name", "Crucible Test") | Out-Null
}

function Invoke-PolicyDriftCheck {
    param([string]$Root)
    $scriptPath = Join-Path $Root "powershell/gates/check-policy-drift.ps1"
    return Invoke-ExternalCommand {
        & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $scriptPath
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-policy-drift-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Gitignored root .crucible runtime state is not policy pollution" -Body {
        $projectRoot = Join-Path $tempRoot "ignored"
        New-PolicyDriftFixture -Root $projectRoot -IgnoreCrucible $true
        Write-Utf8NoBom -Path (Join-Path $projectRoot ".crucible/session/x.jsonl") -Content "{} `n"

        $res = Invoke-PolicyDriftCheck -Root $projectRoot
        Assert-Result -Name "ignored runtime exits 0" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected exit 0, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "ignored runtime no pollution error" -Condition (-not ($res.Output -match "Test pollution detected")) -FailureMessage "fully ignored .crucible should not be pollution. Output:`n$($res.Output)"
    }

    $results += Run-Test -Name "Committable root .crucible content is policy pollution" -Body {
        $projectRoot = Join-Path $tempRoot "committable"
        New-PolicyDriftFixture -Root $projectRoot -IgnoreCrucible $false
        Write-Utf8NoBom -Path (Join-Path $projectRoot ".crucible/session/x.jsonl") -Content "{} `n"

        $res = Invoke-PolicyDriftCheck -Root $projectRoot
        Assert-Result -Name "committable runtime exits 2" -Condition ($res.ExitCode -eq 2) -FailureMessage "expected exit 2, got $($res.ExitCode). Output:`n$($res.Output)"
        Assert-Result -Name "committable pollution error" -Condition ($res.Output -match "committable files exist under a stray '.crucible'" -and $res.Output -match ".crucible/session/x.jsonl") -FailureMessage "expected committable .crucible path in error. Output:`n$($res.Output)"
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
