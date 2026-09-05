# Checked native-command execution: run a scriptblock, separate stderr from stdout, and
# report the exit code without letting Windows PowerShell 5.1 turn benign git stderr into
# a terminating NativeCommandError. CONTRIBUTING.md names this the project-wide idiom.
#
# It lived in factory-gates.ps1 until TODO item 14 step A, findable only by knowing it
# happened to be there. It is not a gate, and lib/session-output.ps1 already called it
# across that boundary.
#
# Deliberately NOT merged into platform.ps1. That file is the one lib with no dependencies
# of its own, which is why some forty scripts dot-source it - including the pre-commit
# gates, which never load factory-lib.ps1. Invoke-GitChecked calls Write-Quiet, defined in
# factory-lib.ps1, so moving it there would put an unresolvable call inside the file whose
# entire value is that everything in it resolves everywhere. It would break only when
# called, in whichever standalone script called it first.
#
# Requires: Write-Quiet (powershell/factory-lib.ps1).

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
