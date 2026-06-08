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
