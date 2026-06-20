# Tests for platform resolver helper.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
$Quiet = $true

# platform.ps1 is dot-sourced here.
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")

$results = @()







try {
    $results += Run-Test -Name "Get-PwshCommand returns correct command based on platform mock" -Body {
        # Test Windows mock
        $script:MockPlatformIsWindows = $true
        $script:MockPwshCommandExists = $null
        $cmdWin = Get-PwshCommand
        Assert-Result -Name "windows mock returns & (Get-PwshCommand)" -Condition ($cmdWin -eq "powershell" + ".exe") -FailureMessage "expected & (Get-PwshCommand) on Windows"

        # Test Non-Windows mock with pwsh present
        $script:MockPlatformIsWindows = $false
        $script:MockPwshCommandExists = $true
        $cmdUnix = Get-PwshCommand
        Assert-Result -Name "unix mock returns pwsh" -Condition ($cmdUnix -eq "pwsh") -FailureMessage "expected pwsh on Unix"

        # Test Non-Windows mock with pwsh absent
        $script:MockPlatformIsWindows = $false
        $script:MockPwshCommandExists = $false
        $threw = $false
        try {
            $null = Get-PwshCommand
        } catch {
            $threw = $true
            Assert-Result -Name "unix throw message" -Condition ($_.Exception.Message -match "not found on your PATH") -FailureMessage "unexpected exception message: $($_.Exception.Message)"
        }
        Assert-Result -Name "unix mock throws when pwsh absent" -Condition $threw -FailureMessage "expected Get-PwshCommand to throw when pwsh is absent on Unix"
    }

    $results += Run-Test -Name "Real platform execution test" -Body {
        # Restore mock state to use real platform checks
        $script:MockPlatformIsWindows = $null
        $script:MockPwshCommandExists = $null

        $cmd = Get-PwshCommand
        Assert-Result -Name "returns non-empty command" -Condition (-not [string]::IsNullOrWhiteSpace($cmd)) -FailureMessage "command must not be empty"

        # Try to execute the command to verify it runs and returns exit code 0
        & $cmd -NoProfile -Command "exit 0"
        Assert-Result -Name "execution exit code" -Condition ($LASTEXITCODE -eq 0) -FailureMessage "execution of resolved command '$cmd' failed with exit code $LASTEXITCODE"
    }
} finally {
    # Ensure mock state is cleaned up
    $script:MockPlatformIsWindows = $null
    $script:MockPwshCommandExists = $null
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed platform test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll platform tests passed." -ForegroundColor Green
exit 0
