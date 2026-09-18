param(
    [Parameter(Mandatory=$false)][string]$ConfigPath = ".crucible/config.yaml",
    [Parameter(Mandatory=$false)][switch]$Quiet
)

$ErrorActionPreference = "Stop"
$errors = @()
$warnings = @()

function Write-Result {
    param(
        [Parameter(Mandatory=$false)][string]$Message = "",
        [string]$ForegroundColor = "White"
    )
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
}

# The validator reads the config through the same primitive the runtime uses. It used
# to carry its own pinned regexes - `^\s{2}<key>:` and a bespoke `paths:` block matcher
# - so the two could disagree about what one file said. Both directions were wrong: a
# key the validator could not see was silently not validated (the whole review.ci_*
# family was in that category), and an indent the runtime reads without trouble made
# the validator report present fields as missing.
. (Join-Path $PSScriptRoot "lib/config-helpers.ps1")

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Result ("CONFIG VALIDATION FAILED: file not found: " + $ConfigPath) -ForegroundColor Red
    exit 2
}

$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$content = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
$entries = @(Get-ConfigEntries -Content $content)

# A key that is present but unreadable is reported as such. Treating it as absent is
# what let a malformed value pass validation and then read as its default at runtime.
function Read-Value {
    param([Parameter(Mandatory=$true)][string[]]$Path)
    try {
        $value = Get-ConfigBlockValue -Content $script:content -Path $Path -Source $script:ConfigPath
        return [pscustomobject]@{ Ok = $true; Value = $value }
    } catch {
        $script:errors += $_.Exception.Message
        return [pscustomobject]@{ Ok = $false; Value = $null }
    }
}

function Find-Node {
    param([Parameter(Mandatory=$true)][string[]]$Path)
    try {
        return Find-ConfigNode -Entries $script:entries -Path $Path -Source $script:ConfigPath
    } catch {
        $script:errors += $_.Exception.Message
        return $null
    }
}

function Test-RequiredValue {
    param(
        [Parameter(Mandatory=$true)][string[]]$Path,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $result = Read-Value -Path $Path
    if ($result.Ok -and $null -eq $result.Value) {
        $script:errors += "Missing or invalid config field: $Name"
    }
    return $result.Value
}

function Test-RequiredSection {
    param(
        [Parameter(Mandatory=$true)][string[]]$Path,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $node = Find-Node -Path $Path
    if ($null -eq $node) {
        $script:errors += "Missing or invalid config field: $Name"
    }
    return $node
}

$crucibleRootPath = Test-RequiredValue -Path @("crucible_root") -Name "crucible_root"

if (-not [string]::IsNullOrWhiteSpace($crucibleRootPath)) {
    $isRooted = [System.IO.Path]::IsPathRooted($crucibleRootPath) -or $crucibleRootPath -match '^([A-Za-z]:|[\\/])'
    $resolvedCrucibleRoot = $crucibleRootPath
    if (-not $isRooted) {
        $configDir = Split-Path -Parent $ConfigPath
        $projRoot = Split-Path -Parent $configDir
        $resolvedCrucibleRoot = Join-Path $projRoot $crucibleRootPath
    }

    if ($isRooted) {
        $errors += "crucible_root must be a relative path inside the project (e.g. .crucible, .crucible-bundle, tools/crucible)."
    }
    if ($crucibleRootPath -match "^\.\." -or $crucibleRootPath -match "[\\/]\.\.") {
        $errors += "crucible_root must not escape the project root (path contains '..')."
    }
    if (-not (Test-Path -LiteralPath $resolvedCrucibleRoot)) {
        $errors += "crucible_root path does not exist: $crucibleRootPath"
    } else {
        $resolvedPath = (Resolve-Path -LiteralPath $resolvedCrucibleRoot).Path
        $docsPath = Join-Path $resolvedPath "docs"
        $promptsPath = Join-Path $resolvedPath "prompts"
        $personasPath = Join-Path $resolvedPath "personas"
        $schemasPath = Join-Path $resolvedPath "schemas"
        $sopsPath = Join-Path $resolvedPath "sops"
        $powershellPath = Join-Path $resolvedPath "powershell"
        if (-not ((Test-Path -LiteralPath $docsPath -PathType Container) -and `
                  (Test-Path -LiteralPath $promptsPath -PathType Container) -and `
                  (Test-Path -LiteralPath $personasPath -PathType Container) -and `
                  (Test-Path -LiteralPath $schemasPath -PathType Container) -and `
                  (Test-Path -LiteralPath $sopsPath -PathType Container) -and `
                  (Test-Path -LiteralPath $powershellPath -PathType Container))) {
            $errors += "crucible_root path is not a complete installed Crucible bundle: $crucibleRootPath (missing docs, prompts, personas, schemas, sops, or powershell directory)"
        }
    }
}

foreach ($section in @("project", "roles", "verification", "project_mandates")) {
    $null = Test-RequiredSection -Path @($section) -Name ($section + " section")
}

foreach ($field in @("name", "description", "default_branch")) {
    $null = Test-RequiredValue -Path @("project", $field) -Name ("project." + $field)
}

$pathsNode = Find-Node -Path @("paths")
if ($null -ne $pathsNode) {
    # Session and framework assets must stay under the bundle directory.
    foreach ($field in @("session", "workspaces", "prompts", "personas", "sops")) {
        $value = Test-RequiredValue -Path @("paths", $field) -Name ("paths." + $field)
        if ((-not [string]::IsNullOrWhiteSpace($value)) -and ($value -notmatch '^\.crucible/.+')) {
            $errors += "Missing or invalid config field: paths." + $field
        }
    }

    # backlog may live anywhere relative to the project root, but it must be non-empty
    # and must not escape.
    $backlogVal = Test-RequiredValue -Path @("paths", "backlog") -Name "paths.backlog"
    if (-not [string]::IsNullOrWhiteSpace($backlogVal)) {
        if ([System.IO.Path]::IsPathRooted($backlogVal) -or $backlogVal -match '^([A-Za-z]:|[\\/])') {
            $errors += "paths.backlog must be a relative path inside the project."
        }
        if ($backlogVal -match "^\.\." -or $backlogVal -match "[\\/]\.\.") {
            $errors += "paths.backlog must not escape the project root (path contains '..')."
        }
    }
}

$manifestNode = Find-Node -Path @("manifest_files")
if ($null -ne $manifestNode) {
    try {
        $null = Get-ConfigBlockList -Content $content -Path @("manifest_files") -Source $ConfigPath
    } catch {
        $errors += "manifest_files must be an array of files (either block or inline format)."
    }
}

# Every review key below is optional, so absence is legitimate and silent. A key the
# adopter did write, however, is checked - including the CI family, which decides
# whether a push is gated on green CI. The old validator looked only at diff_tool,
# editor and auto_push, so `require_green_ci: yes` validated clean and then read as
# false at runtime, turning the publish gate off in a file that says it is on.
$reviewNode = Find-Node -Path @("review")
if ($null -ne $reviewNode) {
    foreach ($field in @("diff_tool", "editor", "ci_staging_branch_prefix", "ci_required_checks")) {
        $result = Read-Value -Path @("review", $field)
        if ($result.Ok -and $null -ne $result.Value -and [string]::IsNullOrWhiteSpace($result.Value)) {
            $errors += "Missing or invalid config field: review." + $field
        }
    }

    foreach ($field in @("auto_push", "require_green_ci", "ci_post_push_watch")) {
        $result = Read-Value -Path @("review", $field)
        if ($result.Ok -and $null -ne $result.Value -and $result.Value -notmatch '^(true|false)$') {
            $errors += "review." + $field + " must be true or false (got '" + $result.Value + "')."
        }
    }

    foreach ($field in @("ci_timeout_minutes", "ci_queued_grace_minutes")) {
        $result = Read-Value -Path @("review", $field)
        if ($result.Ok -and $null -ne $result.Value) {
            if ($result.Value -notmatch '^[0-9]+$') {
                $errors += "review." + $field + " must be a positive whole number of minutes (got '" + $result.Value + "')."
            } elseif ([double]$result.Value -le 0) {
                $errors += "review." + $field + " must be a positive whole number of minutes (got '" + $result.Value + "')."
            }
        }
    }
}

foreach ($role in @("researcher", "groomer", "architect", "reviewer", "operator")) {
    $null = Test-RequiredSection -Path @("roles", $role) -Name ("roles." + $role)
}

foreach ($tier in @("fast", "high-capability")) {
    if ($content -notmatch ("model_tier:\s+" + [regex]::Escape($tier))) {
        $warnings += "No role currently uses model_tier '$tier'. Confirm this is intentional."
    }
}

$null = Test-RequiredSection -Path @("verification", "quick") -Name "verification.quick"
$null = Test-RequiredSection -Path @("verification", "full") -Name "verification.full"

# The verification entries are a list of maps, so command: is not reachable as a
# mapping key path; it is looked for anywhere inside the verification block instead.
$verificationNode = Find-Node -Path @("verification")
$hasVerificationCommand = $false
if ($null -ne $verificationNode) {
    for ($i = $verificationNode.SpanStart; $i -lt $verificationNode.SpanEnd; $i++) {
        if ($entries[$i].Key -eq "command" -and -not [string]::IsNullOrWhiteSpace($entries[$i].Value)) {
            $hasVerificationCommand = $true
        }
    }
}
if (-not $hasVerificationCommand) {
    $errors += "Missing or invalid config field: verification command"
}

if ($content -match "replace-with-project-") {
    $errors += "Verification commands still contain scaffold placeholder values."
}

if ($content -match "Replace with project-specific engineering rules") {
    $warnings += "TODO before first task: edit project_mandates in .crucible/config.yaml to add project-specific rules (currently using scaffold placeholder)."
}

# Version metadata: warn (do not error) if missing or unstamped.
$hasVersion = $false
$versionResult = Read-Value -Path @("crucible_version")
if ($versionResult.Ok -and $null -ne $versionResult.Value) {
    if (($versionResult.Value -match '^[0-9]+\.[0-9]+\.[0-9]+') -and ($versionResult.Value -ne "REPLACE_WITH_VERSION")) {
        $hasVersion = $true
    }
}
$hasCommit = $false
$commitResult = Read-Value -Path @("crucible_install_commit")
if ($commitResult.Ok -and $null -ne $commitResult.Value) {
    if ($commitResult.Value -match '^[0-9a-f]{40}$') {
        $hasCommit = $true
    }
}
if (-not ($hasVersion -and $hasCommit)) {
    $warnings += "Crucible version/commit metadata is unstamped or incomplete. Re-run init-project.ps1 from a Crucible source repo to stamp crucible_version + crucible_install_commit."
}

if ($errors.Count -gt 0) {
    Write-Result "CONFIG VALIDATION FAILED:" -ForegroundColor Red
    foreach ($entry in $errors) {
        Write-Result ("  - " + $entry) -ForegroundColor Red
    }
    if ($warnings.Count -gt 0) {
        Write-Result ""
        Write-Result "WARNINGS:" -ForegroundColor Yellow
        foreach ($warning in $warnings) {
            Write-Result ("  - " + $warning) -ForegroundColor Yellow
        }
    }
    exit 2
}

if ($warnings.Count -gt 0) {
    Write-Result "CONFIG VALIDATION PASSED WITH WARNINGS:" -ForegroundColor Yellow
    foreach ($warning in $warnings) {
        Write-Result ("  - " + $warning) -ForegroundColor Yellow
    }
    exit 0
}

Write-Result "CONFIG VALIDATION PASSED" -ForegroundColor Green
exit 0
