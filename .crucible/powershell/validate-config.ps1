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
Test-Pattern -Name "crucible_root" -Pattern '(?m)^crucible_root[:]\s+["'']?[^"''\r\n]+["'']?\s*$' -Content $content

if ($content -match '(?m)^crucible_root[:]\s+["'']?([^"''\r\n]+)["'']?\s*$') {
    $crucibleRootPath = $Matches[1].Trim()
    
    $resolvedCrucibleRoot = $crucibleRootPath
    if (-not [System.IO.Path]::IsPathRooted($crucibleRootPath)) {
        $configDir = Split-Path -Parent $ConfigPath
        $projRoot = Split-Path -Parent $configDir
        $resolvedCrucibleRoot = Join-Path $projRoot $crucibleRootPath
    }

    if ([System.IO.Path]::IsPathRooted($crucibleRootPath)) {
        $errors += "crucible_root must point to a relative path inside the project, typically .crucible."
    }
    if ($crucibleRootPath -notmatch "^\.crucible($|[\\/])") {
        $errors += "crucible_root must point inside the installed project .crucible directory."
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

foreach ($section in @("project", "paths", "roles", "verification", "project_mandates")) {
    Test-Pattern -Name ($section + " section") -Pattern ("(?m)^" + [regex]::Escape($section) + ":\s*$") -Content $content
}

foreach ($field in @("name", "description", "default_branch")) {
    Test-Pattern -Name ("project." + $field) -Pattern ("(?m)^\s{2}" + [regex]::Escape($field) + ":\s+.+$") -Content $content
}

foreach ($field in @("backlog", "session", "workspaces", "prompts", "personas", "sops")) {
    Test-Pattern -Name ("paths." + $field) -Pattern ("(?m)^\s{2}" + [regex]::Escape($field) + ":\s+\.crucible/.+$") -Content $content
}

foreach ($role in @("researcher", "groomer", "architect", "reviewer", "operator")) {
    Test-Pattern -Name ("roles." + $role) -Pattern ("(?m)^\s{2}" + [regex]::Escape($role) + ":\s*$") -Content $content
}

foreach ($tier in @("fast", "high-capability")) {
    if ($content -notmatch ("model_tier[:]\s+" + [regex]::Escape($tier))) {
        $warnings += "No role currently uses model_tier '$tier'. Confirm this is intentional."
    }
}

Test-Pattern -Name "verification.quick" -Pattern "(?m)^\s{2}quick[:]\s*$" -Content $content
Test-Pattern -Name "verification.full" -Pattern "(?m)^\s{2}full[:]\s*$" -Content $content
Test-Pattern -Name "verification command" -Pattern "(?m)^\s{6}command[:]\s+.+$" -Content $content

if ($content -match "replace-with-project-") {
    $errors += "Verification commands still contain scaffold placeholder values."
}

if ($content -match "Replace with project-specific engineering rules") {
    $warnings += "project_mandates still contains the scaffold placeholder."
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
