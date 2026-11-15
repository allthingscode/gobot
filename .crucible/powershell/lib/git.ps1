# Checked native-command execution: run a scriptblock, separate stderr from stdout, and
# report the exit code without letting Windows PowerShell 5.1 turn benign git stderr into
# a terminating NativeCommandError. CONTRIBUTING.md names this the project-wide idiom.
#
# Keep this separate from platform.ps1: standalone scripts and pre-commit gates load
# that library without crucible-lib.ps1, which defines Write-Quiet. Item 14.
#
# Requires: Write-Quiet (powershell/crucible-lib.ps1).
. (Join-Path $PSScriptRoot "platform.ps1")
. (Join-Path $PSScriptRoot "config-helpers.ps1")

function Test-GitDiscardSafe {
    # I2's single guard. Call before starting a reversible merge/rebase, or immediately
    # before discarding. Cleanup can leave the worktree; gate callers exit 2 (I11).
    # Default to protecting every path. Only operations that preserve ordinary
    # untracked files opt out; reset callers must also supply their target.
    # Runtime exemptions apply only to the primary checkout, never worktree deletion.
    param(
        [Parameter(Mandatory=$true)][string]$Directory,
        [string]$Operation = "git discard",
        [switch]$AllowConfiguredRuntime,
        [switch]$IncludeUntracked = $true,
        [string]$ResetTarget = "",
        [switch]$Refuse
    )
    $unsafe = @()
    $failure = ""
    $status = Invoke-Git -Directory $Directory status --porcelain=v1 -z --untracked-files=all --ignored
    if ($status.ExitCode -ne 0) {
        $failure = "git status failed; safety could not be established"
    } else {
        $targetPaths = @()
        if ($ResetTarget) {
            $tree = Invoke-Git -Directory $Directory -GitArgs @('ls-tree', '-r', '--name-only', '-z', $ResetTarget)
            if ($tree.ExitCode -ne 0) { $failure = "could not read reset target $ResetTarget" }
            $targetPaths = @($tree.Raw -split "`0" | Where-Object { $_ })
        }
        $entries = @($status.Raw -split "`0")
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $entry = $entries[$i]
            if ($entry.Length -lt 4) { continue }
            $code = $entry.Substring(0, 2)
            $paths = @($entry.Substring(3))
            if ($code -match '[RC]') { $i++; $paths += $entries[$i] }
            foreach ($path in $paths) {
                $path = $path.TrimEnd('/')
                if ($AllowConfiguredRuntime -and (Test-ConfiguredRuntimePath -Path $path -ProjectRoot $Directory)) { continue }
                if ($code -in @('??', '!!') -and -not $IncludeUntracked) {
                    # reset --hard can delete an untracked/ignored obstruction to a
                    # target path. Other untracked files are untouched and may remain.
                    $collisions = @($targetPaths | Where-Object {
                        $_ -eq $path -or $_.StartsWith($path + '/', [StringComparison]::OrdinalIgnoreCase) -or
                        $path.StartsWith($_ + '/', [StringComparison]::OrdinalIgnoreCase)
                    })
                    if ($collisions.Count -eq 0) { continue }
                }
                $unsafe += $path
            }
        }
    }
    if ($failure -or $unsafe.Count -gt 0) {
        Write-Host "Error: refusing $Operation in $Directory; uncommitted changes must be preserved." -ForegroundColor Red
        if ($failure) { Write-Host "  $failure" -ForegroundColor Yellow }
        foreach ($path in @($unsafe | Sort-Object -Unique)) { Write-Host "  $path" -ForegroundColor Yellow }
        Write-Host "Commit or stash these paths (including untracked/ignored files when listed), then rerun the decision or operation. Nothing was discarded." -ForegroundColor Yellow
        if ($Refuse) { exit 2 }
        return $false
    }
    return $true
}

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
