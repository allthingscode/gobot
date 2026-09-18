# Which project is this script operating on?
#
# The answer is derived from the script's own location, not from the caller's working
# directory. A bundled copy sits at <adopter>/.crucible/powershell/, so $PSScriptRoot names
# the adopter unambiguously no matter where the orchestrator was standing when it invoked
# us. The canonical framework copy at <crucible>/powershell/ derives the framework root,
# which is not itself an adopter, so that case falls through to the working directory.
#
# The working directory is accepted only when it really is a project. An omitted root is an
# unanswered question, not permission to guess: the guess silently validated, and reported
# on, a repository nobody had named.

function Test-CrucibleProjectRoot {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return ((Test-Path -LiteralPath (Join-Path $Path ".crucible/backlog")) -or
            (Test-Path -LiteralPath (Join-Path $Path ".crucible/config.yaml")))
}

function Resolve-CrucibleProjectRoot {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$ScriptRoot,
        [string]$ParameterName = "-ProjectRoot"
    )

    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        if (-not (Test-Path -LiteralPath $ProjectRoot)) {
            throw ($ParameterName + " path does not exist: '" + $ProjectRoot + "'.")
        }
        return (Resolve-Path -LiteralPath $ProjectRoot).Path
    }

    $derivedParent = Split-Path -Path $ScriptRoot -Parent
    if ((Split-Path -Path $derivedParent -Leaf) -eq ".crucible") {
        $derivedParent = Split-Path -Path $derivedParent -Parent
    }
    $derivedRoot = (Resolve-Path -LiteralPath $derivedParent).Path
    if (Test-CrucibleProjectRoot -Path $derivedRoot) { return $derivedRoot }

    $cwd = (Get-Location).Path
    if (Test-CrucibleProjectRoot -Path $cwd) { return $cwd }

    throw ("Pass " + $ParameterName + " naming the project to operate on. It was omitted, the directory derived from this script ('" + $derivedRoot + "') is not a valid Crucible project, and neither is the current working directory ('" + $cwd + "') - both are missing .crucible/backlog and .crucible/config.yaml.")
}
