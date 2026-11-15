# Retires one not-run line for a check that was renamed or removed (item 259). Such a check
# never runs again under its old name, so its line would never clear on its own, and its
# absence from the config is not evidence that it ran. A human decides; this records it.
#
# The line moves from checks-not-run.txt to checks-not-run-retired.txt with the UTC time, the
# reason and the replacing check when one is named. The Human Gate menu shows the history;
# the Reviewer prompt does not. Refused: no matching line, and a reason that is empty or only a
# stock phrase (the Human Gate's rule), judged after line breaks are flattened as stored.
#
# Usage:
#   retire-check-not-run.ps1 -TaskId F-012 -Source "isolated checks" -Check "lint: go" `
#     -Reason "lint: go was renamed lint-go in config.yaml" -ReplacedBy "lint-go"

param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    # The bracketed source on the line, for example "isolated checks" or "scope gate".
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Check,

    [Parameter(Mandatory = $true)]
    [string]$Reason,

    [string]$ReplacedBy = "",

    [Parameter(Mandatory = $false)]
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"

# I11: the helpers keep their exceptions; this command owns refusal.
trap {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

$Quiet = $true
. (Join-Path $PSScriptRoot "crucible-lib.ps1")
. (Join-Path $PSScriptRoot "lib/project-root.ps1")


$REPO_ROOT = Resolve-CrucibleProjectRoot -ProjectRoot $ProjectRoot -ScriptRoot $PSScriptRoot
$sessionRoot = Get-ConfiguredPath -Key "session" -ProjectRoot $REPO_ROOT

$entries = @(Move-CheckNotRunToRetired -SessionDir $sessionRoot -TaskId $TaskId -Source $Source -Check $Check -Reason $Reason -ReplacedBy $ReplacedBy)

Write-Host ("[CHECK RETIRED] " + $TaskId) -ForegroundColor Green
foreach ($entry in $entries) { Write-Host ("  " + $entry) }
Write-Host ("  history: " + (Get-ChecksNotRunRetiredPath -SessionDir $sessionRoot -TaskId $TaskId))
exit 0
