$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$VALIDATE_SCRIPT = Join-Path $REPO_ROOT "powershell/validate_dev_log.ps1"

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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-validate-dev-log-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Clean dev log passes scan" -Body {
        $logPath = Join-Path $tempRoot "clean-dev-log.md"
        @(
            "# Dev Log",
            "",
            "Implemented the requested feature and verified the test suite."
        ) | Set-Content -LiteralPath $logPath -Encoding UTF8

        $res = Invoke-ExternalCommand {
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -FileToPublish $logPath
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 0) -FailureMessage "expected 0, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "scan passed" -Condition ($output -match "Scan Passed") -FailureMessage "expected Scan Passed message. Output:`n$output"
    }

    $results += Run-Test -Name "Synthetic Google API key is rejected" -Body {
        $logPath = Join-Path $tempRoot "secret-dev-log.md"
        Set-Content -LiteralPath $logPath -Value "Synthetic key: AIzaSyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" -Encoding UTF8

        $res = Invoke-ExternalCommand {
            powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VALIDATE_SCRIPT -FileToPublish $logPath
        }
        $output = $res.Output -join "`n"
        Assert-Result -Name "exit code" -Condition ($res.ExitCode -eq 1) -FailureMessage "expected 1, got $($res.ExitCode). Output:`n$output"
        Assert-Result -Name "secret message" -Condition ($output -match "Secret or API key detected") -FailureMessage "expected secret detection message. Output:`n$output"
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
