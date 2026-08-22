# Platform resolver helper to handle powershell vs pwsh executable names.

$script:MockPlatformIsWindows = $null
$script:MockPwshCommandExists = $null

function Test-PlatformIsWindows {
    if ($null -ne $script:MockPlatformIsWindows) {
        return $script:MockPlatformIsWindows
    }
    $isCore = $PSVersionTable.PSEdition -eq 'Core'
    $onWindows = -not $isCore -or (Get-Variable IsWindows -ValueOnly -EA SilentlyContinue) -ne $false
    return $onWindows
}

function Get-PwshCommand {
    <#
    .SYNOPSIS
        Resolves the PowerShell host command or executable path for the current platform.
    .DESCRIPTION
        Returns 'powershell.exe' on Windows and 'pwsh' on non-Windows platforms.
        Throws an error on non-Windows platforms if 'pwsh' is not found on PATH.
    .EXAMPLE
        & (Get-PwshCommand) -NoProfile -File ./script.ps1
    #>
    if (Test-PlatformIsWindows) {
        return "powershell.exe"
    } else {
        if ($null -ne $script:MockPwshCommandExists) {
            if (-not $script:MockPwshCommandExists) {
                throw "PowerShell Core executable 'pwsh' was not found on your PATH. Please install PowerShell 7+ on your Unix platform to run Crucible."
            }
            return "pwsh"
        }

        $cmd = Get-Command "pwsh" -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            throw "PowerShell Core executable 'pwsh' was not found on your PATH. Please install PowerShell 7+ on your Unix platform to run Crucible."
        }
        return "pwsh"
    }
}

function Invoke-Git {
    <#
    .SYNOPSIS
        Executes a git command safely across platforms without PowerShell 5.1 NativeCommandError traps.
    .DESCRIPTION
        Under $ErrorActionPreference = "Stop", Windows PowerShell 5.1 promotes native stderr output
        to terminating NativeCommandError exceptions. Invoke-Git sets ErrorActionPreference to
        'Continue' during execution, redirects stderr with 2>$null, and returns a structured object
        containing ExitCode, Lines, and Raw output. Success should always be judged by ExitCode -eq 0.
    .PARAMETER GitArgs
        The arguments to pass to git.
    .PARAMETER Directory
        Optional working directory (-C <Directory>). Also aliased as -Repo.
    .OUTPUTS
        [PSCustomObject]@{ ExitCode = [int]; Lines = [string[]]; Raw = [string] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position=0, ValueFromRemainingArguments=$true)]
        [object[]]$GitArgs = @(),
        [Alias("Repo")]
        [string]$Directory = ""
    )

    $flattenedArgs = @()
    foreach ($arg in $GitArgs) {
        if ($arg -is [System.Collections.IEnumerable] -and $arg -isnot [string]) {
            foreach ($sub in $arg) { $flattenedArgs += [string]$sub }
        } else {
            $flattenedArgs += [string]$arg
        }
    }

    $allArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($Directory)) {
        $allArgs += @("-C", $Directory)
    }
    if ($flattenedArgs.Count -gt 0) {
        $allArgs += $flattenedArgs
    }

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rawOutput = @(& git @allArgs 2>$null)
        $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    } finally {
        $ErrorActionPreference = $prevEAP
    }

    $lines = [string[]]@($rawOutput | ForEach-Object { [string]$_ })
    $raw = $lines -join "`n"

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Lines    = $lines
        Raw      = $raw
    }
}
