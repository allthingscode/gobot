# Deprecated entrypoint. The orchestrator is powershell/crucible.ps1; this file
# only forwards to it.
#
# It exists because adopters merge the invocation line from
# templates/project/.crucible/agent-instructions/AGENTS.md into their own root
# instruction files, which Crucible does not own and update-bundle.ps1 never
# touches. A bare rename would break the most common invocation path silently.
# Keeping a framework-owned file here also makes the rename classify as
# safe-overwrite rather than review-removal, so an update replaces the old
# implementation with this forwarder instead of stranding it behind -Prune.
#
# Deliberately declares no param() block: every argument must reach crucible.ps1
# exactly as written, and a param() block here would bind and reshape them.
#
# Deletion criterion is measured, not timed - see docs/proposals/crucible-rename-and-factory-migration.md, D2.

$crucibleScript = Join-Path $PSScriptRoot "crucible.ps1"
if (-not (Test-Path -LiteralPath $crucibleScript)) {
    [Console]::Error.WriteLine("[DEPRECATED] factory.ps1 forwards to crucible.ps1, which is missing at $crucibleScript. Your Crucible bundle is incomplete; see docs/updating.md.")
    exit 1
}

[Console]::Error.WriteLine("[DEPRECATED] factory.ps1 is deprecated and will be removed. Invoke powershell/crucible.ps1 instead; forwarding this call unchanged.")

# Telemetry is what makes D2's deletion criterion measurable rather than a guess,
# but it must never be able to fail the call it is only observing.
try {
    & {
        . (Join-Path $PSScriptRoot "crucible-lib.ps1")
        $Quiet = $true

        $taskId = "unknown"
        for ($i = 0; $i -lt $args.Count - 1; $i++) {
            if ("$($args[$i])" -eq "-TaskId") { $taskId = "$($args[$i + 1])"; break }
        }
        $projectRoot = ""
        for ($i = 0; $i -lt $args.Count - 1; $i++) {
            if ("$($args[$i])" -eq "-ProjectRoot") { $projectRoot = "$($args[$i + 1])"; break }
        }
        if ([string]::IsNullOrWhiteSpace($projectRoot)) {
            $derivedParent = Split-Path -Path $PSScriptRoot -Parent
            if ((Split-Path -Path $derivedParent -Leaf) -eq ".crucible") {
                $derivedParent = Split-Path -Path $derivedParent -Parent
            }
            $projectRoot = (Resolve-Path -LiteralPath $derivedParent).Path
        }

        $sessionDir = Get-ConfiguredPath -Key "session" -ProjectRoot $projectRoot
        $logFile = if ($taskId -eq "unknown") {
            Join-Path $sessionDir "global/pipeline.log.jsonl"
        } else {
            Join-Path $sessionDir ($taskId + "/pipeline.log.jsonl")
        }
        Write-EventLog -Event "deprecated_entrypoint" -TaskId $taskId -Phase "crucible" `
            -Kind "deprecated_entrypoint_factory_ps1" `
            -Notes "Invoked via the deprecated powershell/factory.ps1 entrypoint; forwarded to crucible.ps1." `
            -LogFile $logFile `
            -CircuitBreakerHistoryFile (Join-Path $sessionDir "global/circuit_breakers.jsonl")
    } @args
} catch {
    [Console]::Error.WriteLine("[DEPRECATED] Could not record the deprecated_entrypoint event: " + $_.Exception.Message)
}

# Invoked in-process rather than as a child process so arguments cross as objects.
# Re-launching pwsh would re-quote them, and PowerShell 5.1's native-argument
# quoting mangles embedded quotes - which -GateReason routinely carries.
$global:LASTEXITCODE = 0
& $crucibleScript @args
exit $LASTEXITCODE
