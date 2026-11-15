# Shared required-key contract for the $Context hashtable passed through gates.
# A single checkable contract prevents inconsistent keys and ambient event destinations. Item 16.
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

# The root a printed re-run command should carry as -ProjectRoot. RepoRoot is optional in
# most gate contexts, and a missing key throws under StrictMode, so this reads it guardedly.
# The fallback is the placeholder rather than the current directory: a guessed path would
# look authoritative, and a wrong root is the defect -ProjectRoot is there to prevent.
function Get-RecoveryProjectRoot {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    if ($Context.ContainsKey("RepoRoot") -and -not [string]::IsNullOrWhiteSpace([string]$Context.RepoRoot)) {
        return [string]$Context.RepoRoot
    }
    return "{project_root}"
}

# The bundle a printed command for a Crucible script is rooted at, read the same guarded way
# and for the same reason: a context without CrucibleRoot prints the placeholder. Item 247.
function Get-RecoveryCrucibleRoot {
    param([Parameter(Mandatory=$true)][hashtable]$Context)

    if ($Context.ContainsKey("CrucibleRoot") -and -not [string]::IsNullOrWhiteSpace([string]$Context.CrucibleRoot)) {
        return [string]$Context.CrucibleRoot
    }
    return "{crucible_root}"
}
