param(
    [Parameter(Mandatory=$true)][string]$BacklogPath,
    [Parameter(Mandatory=$true)][string]$SpecPath,
    [ValidateSet("Production","Resolved","Abandoned")][string]$Status,
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

$result = Invoke-BacklogTaskArchive @params
if (-not $Quiet) {
    Write-Host ("Archived {0} as {1}: {2}" -f $result.Type, $result.Status, $result.ArchivedRelPath) -ForegroundColor Green
}
