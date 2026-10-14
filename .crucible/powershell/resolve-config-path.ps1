# Resolves one .crucible/config.yaml path key and prints it on stdout.
#
# This exists so non-PowerShell callers - the sh pre-commit hook and CI, which
# must hand `crucible_lint` a backlog directory - can use the one config parser in
# lib/config-helpers.ps1 so supported config formatting cannot silently disable lints.
#
# Stdout carries the resolved absolute path and nothing else, so the caller can
# capture it directly. Diagnostics go to stderr. An unreadable config exits 1
# rather than printing a default, so callers never act on a guessed path.
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("backlog", "session", "workspaces", "prompts", "personas", "sops")]
    [string]$Key,
    [Parameter(Mandatory=$false)][string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/config-helpers.ps1")

try {
    $resolved = Get-ConfiguredPath -Key $Key -ProjectRoot $ProjectRoot
} catch {
    [Console]::Error.WriteLine("resolve-config-path: cannot resolve '" + $Key + "': " + $_.Exception.Message)
    exit 1
}

if ([string]::IsNullOrWhiteSpace($resolved)) {
    [Console]::Error.WriteLine("resolve-config-path: '" + $Key + "' resolved to an empty path.")
    exit 1
}

[Console]::Out.WriteLine($resolved)
exit 0
