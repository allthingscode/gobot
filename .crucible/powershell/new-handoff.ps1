# Writes a validated handoff. The parameters and body are in lib/new-handoff-core.ps1;
# this entrypoint only binds them inside a protected call.
#
# Deliberately declares no param() block. PowerShell binds a script's parameters before
# its body or trap runs, so a missing mandatory argument, an invalid -Source or a failed
# type conversion would throw to an in-process caller, whose catch could turn the refusal
# into a pass (I11, item 375). Here binding happens inside the call below, and any failure
# becomes a stderr diagnostic and exit 1. The core's own refusals keep their exit codes.
# Follows the factory.ps1 forwarder.

$ErrorActionPreference = 'Stop'
$coreScript = Join-Path $PSScriptRoot "lib/new-handoff-core.ps1"
if (-not (Test-Path -LiteralPath $coreScript)) {
    [Console]::Error.WriteLine("new-handoff.ps1 needs lib/new-handoff-core.ps1, which is missing at $coreScript. Your Crucible bundle is incomplete; see docs/updating.md.")
    exit 1
}

try {
    $forwarderScript = Join-Path $PSScriptRoot "lib/forward-entrypoint.ps1"
    $global:LASTEXITCODE = 0
    & $forwarderScript -TargetScript $coreScript -Arguments $args -Entrypoint 'new-handoff.ps1'
    if (-not $? -and $LASTEXITCODE -eq 0) { exit 1 }
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine("new-handoff.ps1: " + $_.Exception.Message)
    exit 1
}
