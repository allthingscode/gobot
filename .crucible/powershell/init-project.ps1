param(
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [Parameter(Mandatory=$false)][string]$ProjectName = "",
    [Parameter(Mandatory=$false)][string]$Description = "",
    [Parameter(Mandatory=$false)][string]$DefaultBranch = "main",
    [Parameter(Mandatory=$false)][switch]$Force,
    [Parameter(Mandatory=$false)][switch]$Quiet
)

$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path -Parent $PSScriptRoot
$templateRoot = Join-Path $REPO_ROOT "templates/project/.crucible"

function Write-Info {
    param(
        [Parameter(Mandatory=$false)][string]$Message = "",
        [string]$ForegroundColor = "White"
    )
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
}

function ConvertTo-YamlScalar {
    param([Parameter(Mandatory=$true)][string]$Value)
    $escaped = $Value.Replace("\", "\\").Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Copy-TemplateDirectory {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination,
        [Parameter(Mandatory=$true)][bool]$AllowOverwrite
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $sourceRoot = (Resolve-Path -LiteralPath $Source).Path
    $entries = Get-ChildItem -LiteralPath $sourceRoot -Force -Recurse
    foreach ($entry in $entries) {
        $relative = $entry.FullName.Substring($sourceRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $target = Join-Path $Destination $relative

        if ($entry.PSIsContainer) {
            if (-not (Test-Path -LiteralPath $target)) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
            }
            continue
        }

        $targetDir = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        if ((Test-Path -LiteralPath $target) -and -not $AllowOverwrite) {
            throw "Refusing to overwrite existing file: $target. Re-run with -Force to overwrite scaffold-managed files."
        }

        Copy-Item -LiteralPath $entry.FullName -Destination $target -Force:$AllowOverwrite
    }
}

if (-not (Test-Path -LiteralPath $templateRoot)) {
    throw "Crucible project template not found: $templateRoot"
}

$resolvedProjectRoot = $ProjectRoot
if (Test-Path -LiteralPath $ProjectRoot) {
    $resolvedProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
} else {
    New-Item -ItemType Directory -Path $ProjectRoot -Force | Out-Null
    $resolvedProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
}

if ([string]::IsNullOrWhiteSpace($ProjectName)) {
    $ProjectName = Split-Path -Leaf $resolvedProjectRoot
}

if ([string]::IsNullOrWhiteSpace($Description)) {
    $Description = "Project configured to use Crucible."
}

$targetCrucible = Join-Path $resolvedProjectRoot ".crucible"
Copy-TemplateDirectory -Source $templateRoot -Destination $targetCrucible -AllowOverwrite ([bool]$Force)

# Copy active framework directories to make the installation self-contained
foreach ($dirName in "docs", "personas", "sops", "prompts", "schemas", "powershell") {
    $srcDir = Join-Path $REPO_ROOT $dirName
    $destDir = Join-Path $targetCrucible $dirName
    Copy-TemplateDirectory -Source $srcDir -Destination $destDir -AllowOverwrite ([bool]$Force)
}

$configPath = Join-Path $targetCrucible "config.yaml"
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Bootstrap failed: expected config file was not created at $configPath"
}

$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
$config = $config -replace '(?m)^  name: .+$', ('  name: ' + (ConvertTo-YamlScalar -Value $ProjectName))
$config = $config -replace '(?m)^  description: .+$', ('  description: ' + (ConvertTo-YamlScalar -Value $Description))
$config = $config -replace '(?m)^  default_branch: .+$', ('  default_branch: ' + (ConvertTo-YamlScalar -Value $DefaultBranch))
$config = $config -replace '(?m)^crucible_root: .+$', ('crucible_root: ' + (ConvertTo-YamlScalar -Value ".crucible"))
$config | Out-File -LiteralPath $configPath -Encoding UTF8

Write-Info ""
Write-Info "[CRUCIBLE] Project scaffold installed" -ForegroundColor Green
Write-Info ("Project root: " + $resolvedProjectRoot)
Write-Info ("Crucible dir: " + $targetCrucible)
Write-Info ""
Write-Info "Committed by default (configuration and behavior):" -ForegroundColor Cyan
Write-Info "  - .crucible/.gitignore"
Write-Info "  - .crucible/README.md"
Write-Info "  - .crucible/config.yaml"
Write-Info "  - .crucible/agent-instructions/ (copy-ready root instruction snippets)"
Write-Info "  - .crucible/docs/, personas/, sops/, prompts/, schemas/, powershell/"
Write-Info ""
Write-Info "Ignored by default (data and runtime state):" -ForegroundColor Cyan
Write-Info "  - .crucible/backlog/ (tickets are data, not code)"
Write-Info "  - .crucible/session/, .agent-workspaces/, locks/"
Write-Info "  - .crucible/tmp/, cache/, archive/, archived/, history/"
Write-Info "  - .crucible/research/, dev-logs/"
Write-Info "  - generated logs, JSONL, handoffs, eval output"
Write-Info ""
Write-Info "crucible_root auto-set to: .crucible" -ForegroundColor DarkGray
Write-Info ""
Write-Info "Next edits:" -ForegroundColor Cyan
Write-Info "  1. Edit .crucible/config.yaml verification commands and project mandates."
Write-Info "  2. Merge .crucible/agent-instructions/AGENTS.md into the project root AGENTS.md."
Write-Info "  3. Add CLAUDE.md or GEMINI.md forwarding snippets if those tools are used."
Write-Info "  4. From the project root, run .crucible/powershell/validate-config.ps1 -ConfigPath .crucible/config.yaml."
Write-Info "  5. Add initial backlog items under .crucible/backlog/."
Write-Info "  6. Commit durable .crucible files and root instruction-file updates."
