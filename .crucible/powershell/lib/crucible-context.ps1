# The required-key contract for the $Context hashtable that Crucible threads through
# its gate functions. This exists as one function because it used to exist as fourteen
# hand-rolled copies, and thirteen of them agreed while the fourteenth (Invoke-HumanGate)
# quietly made LogFile optional - which is how event destinations came to be decided by
# dynamic scope. A convention repeated in every function is not checkable; a declared
# contract is.
#
# Two lists rather than one because the distinction is real: GateRedirectTarget and
# GateReason are $null on every run that is not a redirect, so requiring them to be
# non-null would reject the normal case, while requiring them to be *present* still
# catches a caller that built the context wrong.
function Assert-CrucibleContextKeys {
    param(
        [Parameter(Mandatory=$true)][AllowNull()][hashtable]$Context,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$RequiredKeys,
        [AllowEmptyCollection()][string[]]$NonNullKeys = @()
    )

    if ($null -eq $Context) {
        throw "CrucibleContext is null."
    }
    foreach ($key in $RequiredKeys) {
        if (-not $Context.ContainsKey($key)) {
            throw "Required key '$key' is missing from CrucibleContext."
        }
    }
    foreach ($key in $NonNullKeys) {
        if (-not $Context.ContainsKey($key)) {
            throw "Required key '$key' is missing from CrucibleContext."
        }
        if ($null -eq $Context[$key]) {
            throw "Required key '$key' is null in CrucibleContext."
        }
    }
}
