# Prints the absolute path of the adopter's own hooks directory, from hooks.project_dir
# in .crucible/config.yaml, for the sh hooks to chain to. Item 150.
#
# Stdout carries the path, or nothing when the key is unset: an unset key means no
# chaining and is not an error. A set key the hook cannot use (absolute, escaping,
# under .crucible, or missing on disk) exits 1 with the reason on stderr, so the hook
# fails instead of silently skipping the project's hooks.
param(
    [Parameter(Mandatory=$false)][string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib/config-helpers.ps1")

try {
    $resolved = Get-ConfiguredProjectHooksDir -ProjectRoot $ProjectRoot
} catch {
    [Console]::Error.WriteLine("resolve-project-hooks-dir: " + $_.Exception.Message)
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($resolved)) {
    [Console]::Out.WriteLine($resolved.Replace('\', '/'))
}
exit 0
