if (-not (Test-Path -LiteralPath Function:Resolve-FilesystemPath)) { . (Join-Path $PSScriptRoot "config-helpers.ps1") }

# Which project is this script operating on?
#
# The answer is derived from the script's own location, not from the caller's working
# directory. A bundled copy sits at <adopter>/.crucible/powershell/, so $PSScriptRoot names
# the adopter unambiguously no matter where the orchestrator was standing when it invoked
# us. The canonical framework copy at <crucible>/powershell/ derives the framework root,
# which is not itself an adopter, so that case falls through to the working directory.
#
# Accept the working directory only when it is a project; guessing an unnamed root
# can validate and report on the wrong repository.

function Test-CrucibleProjectRoot {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return ((Test-Path -LiteralPath (Join-Path $Path ".crucible/backlog")) -or
            (Test-Path -LiteralPath (Join-Path $Path ".crucible/config.yaml")))
}

function Resolve-CrucibleProjectRoot {
    param(
        [AllowEmptyString()][string]$ProjectRoot = "",
        [string]$ScriptRoot = "",
        [string]$AncestorOf = "",
        [bool]$RequireProject = $true,
        [string]$ParameterName = "-ProjectRoot"
    )

    # Blocked records start with a configured backlog, which may live outside the bundle.
    # Preserve their ancestor-marker policy explicitly rather than deriving from a script.
    if ($PSBoundParameters.ContainsKey("AncestorOf")) {
        if ([string]::IsNullOrWhiteSpace($AncestorOf)) { throw "AncestorOf must name a backlog directory." }
        $dir = Split-Path -Parent (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $AncestorOf))
        while (-not [string]::IsNullOrWhiteSpace($dir)) {
            if (Test-CrucibleProjectRoot -Path $dir) { return $dir }
            $nextDir = Split-Path -Parent $dir
            if ($nextDir -eq $dir) { break }
            $dir = $nextDir
        }
        throw "No Crucible project ancestor found for '$AncestorOf'."
    }
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        if (-not (Test-Path -LiteralPath $ProjectRoot)) {
            throw ($ParameterName + " path does not exist: '" + $ProjectRoot + "'.")
        }
        return (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $ProjectRoot))
    }

    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { throw "ScriptRoot is required when deriving a project root." }
    $derivedParent = Split-Path -Path $ScriptRoot -Parent
    if ((Split-Path -Path $derivedParent -Leaf) -eq ".crucible") {
        $derivedParent = Split-Path -Path $derivedParent -Parent
    }
    $derivedRoot = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $derivedParent))
    if (-not $RequireProject) { return $derivedRoot }
    if (Test-CrucibleProjectRoot -Path $derivedRoot) { return $derivedRoot }

    $location = Get-Location
    $cwd = $location.Path
    if ($location.Provider.Name -eq 'FileSystem' -and (Test-CrucibleProjectRoot -Path $cwd)) {
        return $location.ProviderPath
    }

    throw ("Pass " + $ParameterName + " naming the project to operate on. It was omitted, the directory derived from this script ('" + $derivedRoot + "') is not a valid Crucible project, and neither is the current working directory ('" + $cwd + "') - both are missing .crucible/backlog and .crucible/config.yaml.")
}
