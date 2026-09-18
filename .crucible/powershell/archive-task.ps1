param(
    [Parameter(Mandatory=$true)][string]$BacklogPath,
    [Parameter(Mandatory=$true)][string]$SpecPath,
    [ValidateSet("Production","Resolved","Abandoned")][string]$Status,
    # Required unless -Status is given or the spec already carries a terminal status: state
    # whether the task merged code. The archive refuses rather than infer it from the item's
    # directory, which is not evidence of whether anything deployed.
    #
    # Spelled as an explicit "true"/"false" rather than a switch because -Switch:$false does
    # not survive PowerShell's -File argument parsing, and a [bool] would read the string
    # "false" as true.
    [ValidateSet("true","false")][string]$ShippedCode = "",
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$libPath = Join-Path $PSScriptRoot "lib/archive-task.ps1"
if (-not (Test-Path -LiteralPath $libPath)) {
    throw "Required helper script not found at $libPath; your Crucible bundle is incomplete. Please see docs/updating.md to sync your bundle from the source repository."
}
. $libPath

$params = @{
    BacklogPath = $BacklogPath
    SpecPath = $SpecPath
}
if ($PSBoundParameters.ContainsKey('Status')) {
    $params['Status'] = $Status
}
if (-not [string]::IsNullOrEmpty($ShippedCode)) {
    $params['ShippedCode'] = ($ShippedCode -eq "true")
}

$result = Invoke-BacklogTaskArchive @params
if (-not $Quiet) {
    Write-Host ("Archived {0} as {1}: {2}" -f $result.Type, $result.Status, $result.ArchivedRelPath) -ForegroundColor Green
}
