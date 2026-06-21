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

function Test-Pattern {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Pattern,
        [Parameter(Mandatory=$true)][string]$Content
    )
    if ($Content -notmatch $Pattern) {
        $script:errors += "Missing or invalid config field: $Name"
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Result ("CONFIG VALIDATION FAILED: file not found: " + $ConfigPath) -ForegroundColor Red
    exit 2
}

$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$content = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8

# Top-level scalar fields (have a value on the same line).
Test-Pattern -Name "crucible_root" -Pattern '(?m)^crucible_root:\s+["'']?[^"''\r\n]+["'']?\s*$' -Content $content

if ($content -match '(?m)^crucible_root:\s+["'']?([^"''\r\n]+)["'']?\s*$') {
    $crucibleRootPath = $Matches[1].Trim()
    
    $isRooted = [System.IO.Path]::IsPathRooted($crucibleRootPath) -or $crucibleRootPath -match '^([A-Za-z]:|[\\/])'
    $resolvedCrucibleRoot = $crucibleRootPath
    if (-not $isRooted) {
        $configDir = Split-Path -Parent $ConfigPath
        $projRoot = Split-Path -Parent $configDir
        $resolvedCrucibleRoot = Join-Path $projRoot $crucibleRootPath
    }

    if ($isRooted) {
        $errors += "crucible_root must be a relative path inside the project (e.g. .crucible, .dev-factory, tools/crucible)."
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
    Test-Pattern -Name ($section + " section") -Pattern ("(?m)^" + [regex]::Escape($section) + ":\s*$") -Content $content
}

foreach ($field in @("name", "description", "default_branch")) {
    Test-Pattern -Name ("project." + $field) -Pattern ("(?m)^\s{2}" + [regex]::Escape($field) + ":\s+.+$") -Content $content
}

if ($content -match '(?m)^paths:\s*$') {
    # Check that session and framework assets are rooted under .crucible/
    foreach ($field in @("session", "workspaces", "prompts", "personas", "sops")) {
        Test-Pattern -Name ("paths." + $field) -Pattern ("(?m)^\s{2}" + [regex]::Escape($field) + ":\s+\.crucible/.+$") -Content $content
    }
    # backlog is allowed to reside anywhere relative to the project root, but it must be non-empty
    Test-Pattern -Name "paths.backlog" -Pattern "(?m)^\s{2}backlog:\s+.+$" -Content $content
}

if ($content -match '(?m)^review:\s*$') {
    foreach ($field in @("diff_tool", "editor")) {
        if ($content -match ("(?m)^\s{2}" + [regex]::Escape($field) + ":\s*")) {
            Test-Pattern -Name ("review." + $field) -Pattern ("(?m)^\s{2}" + [regex]::Escape($field) + ":\s+.+$") -Content $content
        }
    }
}

# Parse and validate paths block details
if ($content -match '(?ms)^paths:\s*\r?\n(.*?)(?=\r?\n\S|\z)') {
    $pathsBlock = $Matches[1]
    if ($pathsBlock -match '(?m)^\s{2}backlog:\s*["'']?([^"''\r\n]+)["'']?\s*$') {
        $backlogVal = $Matches[1].Trim()
        if ([System.IO.Path]::IsPathRooted($backlogVal) -or $backlogVal -match '^([A-Za-z]:|[\\/])') {
            $errors += "paths.backlog must be a relative path inside the project."
        }
        if ($backlogVal -match "^\.\." -or $backlogVal -match "[\\/]\.\.") {
            $errors += "paths.backlog must not escape the project root (path contains '..')."
        }
    }
}

foreach ($role in @("researcher", "groomer", "architect", "reviewer", "operator")) {
    Test-Pattern -Name ("roles." + $role) -Pattern ("(?m)^\s{2}" + [regex]::Escape($role) + ":\s*$") -Content $content
}

foreach ($tier in @("fast", "high-capability")) {
    if ($content -notmatch ("model_tier:\s+" + [regex]::Escape($tier))) {
        $warnings += "No role currently uses model_tier '$tier'. Confirm this is intentional."
    }
}

Test-Pattern -Name "verification.quick" -Pattern "(?m)^\s{2}quick:\s*$" -Content $content
Test-Pattern -Name "verification.full" -Pattern "(?m)^\s{2}full:\s*$" -Content $content
Test-Pattern -Name "verification command" -Pattern "(?m)^\s{6}command:\s+.+$" -Content $content

if ($content -match "replace-with-project-") {
    $errors += "Verification commands still contain scaffold placeholder values."
}

if ($content -match "Replace with project-specific engineering rules") {
    $warnings += "TODO before first task: edit project_mandates in .crucible/config.yaml to add project-specific rules (currently using scaffold placeholder)."
}

# Version metadata: warn (do not error) if missing or unstamped.
$hasVersion = $false
if ($content -match '(?m)^crucible_version:\s+["'']?([^"''\r\n]+)["'']?\s*$') {
    $versionValue = $Matches[1].Trim()
    if (($versionValue -match '^[0-9]+\.[0-9]+\.[0-9]+') -and ($versionValue -ne "REPLACE_WITH_VERSION")) {
        $hasVersion = $true
    }
}
$hasCommit = $false
if ($content -match '(?m)^crucible_install_commit:\s+["'']?([^"''\r\n]+)["'']?\s*$') {
    $commitValue = $Matches[1].Trim()
    if ($commitValue -match '^[0-9a-f]{40}$') {
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
