# Checked native-command execution: run a scriptblock, separate stderr from stdout, and
# report the exit code without letting Windows PowerShell 5.1 turn benign git stderr into
# a terminating NativeCommandError. CONTRIBUTING.md names this the project-wide idiom.
#
# Keep this separate from platform.ps1: standalone scripts and pre-commit gates load
# that dependency-free library without crucible-lib.ps1, which defines Write-Quiet. Item 14.
#
# Requires: Write-Quiet (powershell/crucible-lib.ps1).

function Invoke-GitChecked {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $stdout = @()
        $stderr = @()
        
        $pipeline = & $ScriptBlock 2>&1
        
        foreach ($item in $pipeline) {
            if ($item -is [System.Management.Automation.ErrorRecord]) {
                $stderr += $item.ToString()
            } else {
                $stdout += $item
            }
        }
        
        $exitCode = $LASTEXITCODE
        
        if ($stderr.Count -gt 0) {
            $errMessage = $stderr -join "`n"
            if ($exitCode -eq 0) {
                Write-Quiet $errMessage.Trim()
            } else {
                Write-Error -Message $errMessage.Trim() -ErrorAction Continue
            }
        }
        
        if ($stdout.Count -gt 0) {
            $stdout
        }
    } finally {
        $ErrorActionPreference = $prevEAP
        $global:LASTEXITCODE = $exitCode
    }
}
