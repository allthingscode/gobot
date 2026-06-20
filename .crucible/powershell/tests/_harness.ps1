# Shared test harness helper functions.
# Name does not contain "test" to prevent runner execution.

function Assert-Result {
    param(
        [Parameter(Position=0, Mandatory=$true)][string]$Name,
        [Parameter(Position=1, Mandatory=$true)][bool]$Condition,
        [Parameter(Position=2, Mandatory=$true)][string]$FailureMessage
    )
    if (-not $Condition) {
        throw ("FAILED: " + $Name + " - " + $FailureMessage)
    }
}

function Run-Test {
    param(
        [Parameter(Position=0, Mandatory=$true)][string]$Name,
        [Parameter(Position=1, Mandatory=$true)][scriptblock]$Body
    )

    Write-Host ("`nTest: " + $Name) -ForegroundColor Cyan
    try {
        & $Body
        Write-Host "PASSED" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "EXCEPTION OCCURRED: $_" -ForegroundColor Red
        if ($null -ne $_.ScriptStackTrace) {
            Write-Host $_.ScriptStackTrace -ForegroundColor Red
        }
        return $false
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$Command
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Command 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [PSCustomObject]@{ Output = ($output -join "`n"); ExitCode = $exitCode }
}
