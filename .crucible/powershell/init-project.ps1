param(
    [Parameter(Mandatory=$true)][string]$ProjectRoot,
    [Parameter(Mandatory=$false)][string]$ProjectName = "",
    [Parameter(Mandatory=$false)][string]$Description = "",
    [Parameter(Mandatory=$false)][string]$DefaultBranch = "main",
    [Parameter(Mandatory=$false)][string]$BacklogDir = "",
    [Parameter(Mandatory=$false)][ValidateSet("go", "node", "python", "rust")][string]$Language = "",
    [Parameter(Mandatory=$false)][switch]$WithSampleTask,
    [Parameter(Mandatory=$false)][switch]$AppendInstructions,
    [Parameter(Mandatory=$false)][switch]$StampVersionOnly,
    [Parameter(Mandatory=$false)][switch]$Force,
    [Parameter(Mandatory=$false)][switch]$Quiet
)

$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path -Parent $PSScriptRoot
$templateRoot = Join-Path $REPO_ROOT "templates/project/.crucible"

foreach ($lib in "instruction-blocks.ps1", "language-presets.ps1", "config-helpers.ps1", "install-manifest.ps1") {
    $libPath = Join-Path $PSScriptRoot "lib/$lib"
    if (-not (Test-Path -LiteralPath $libPath)) {
        throw "Required helper script not found at $libPath; your Crucible source directory is incomplete."
    }
}
. (Join-Path $PSScriptRoot "lib/instruction-blocks.ps1")
. (Join-Path $PSScriptRoot "lib/language-presets.ps1")
. (Join-Path $PSScriptRoot "lib/config-helpers.ps1")
. (Join-Path $PSScriptRoot "lib/install-manifest.ps1")

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

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Content
    )
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-CrucibleSourceStamp {
    $versionFile = Join-Path $REPO_ROOT "VERSION"
    $crucibleVersion = ""
    if (Test-Path -LiteralPath $versionFile) {
        $crucibleVersion = (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
    }
    $installCommit = ""
    try {
        Push-Location $REPO_ROOT
        $gitOutput = git rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $gitOutput) {
            $installCommit = ($gitOutput | Out-String).Trim()
        }
    } catch {
        $installCommit = ""
    } finally {
        Pop-Location
    }

    return @{
        Version = $crucibleVersion
        Commit = $installCommit
    }
}

function Set-CrucibleConfigStamp {
    param(
        [Parameter(Mandatory=$true)][string]$ConfigPath,
        [Parameter(Mandatory=$true)][string]$Version,
        [Parameter(Mandatory=$true)][string]$Commit,
        [Parameter(Mandatory=$true)][bool]$AllowExisting
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Cannot stamp Crucible metadata because config.yaml does not exist at $ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    $hasVersion = ($config -match '(?m)^crucible_version:\s*')
    $hasCommit = ($config -match '(?m)^crucible_install_commit:\s*')
    if (($hasVersion -or $hasCommit) -and -not $AllowExisting) {
        throw "config.yaml already has Crucible version metadata. Re-run with -Force to update crucible_version and crucible_install_commit."
    }

    if ($Version -match '^[0-9]+\.[0-9]+\.[0-9]+') {
        if ($hasVersion) {
            $config = $config -replace '(?m)^crucible_version: .+$', ('crucible_version: ' + (ConvertTo-YamlScalar -Value $Version))
        } else {
            $config = $config.TrimEnd() + "`r`ncrucible_version: " + (ConvertTo-YamlScalar -Value $Version) + "`r`n"
        }
    } elseif ($hasVersion) {
        $config = $config -replace '(?m)^crucible_version: .+\r?\n', ''
    }

    if ($Commit -match '^[0-9a-f]{40}$') {
        if ($hasCommit) {
            $config = $config -replace '(?m)^crucible_install_commit: .+$', ('crucible_install_commit: ' + (ConvertTo-YamlScalar -Value $Commit))
        } else {
            $config = $config.TrimEnd() + "`r`ncrucible_install_commit: " + (ConvertTo-YamlScalar -Value $Commit) + "`r`n"
        }
    } elseif ($hasCommit) {
        $config = $config -replace '(?m)^crucible_install_commit: .+\r?\n', ''
    }

    Write-Utf8NoBomFile -Path $ConfigPath -Content $config
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

        # Never copy a nested .crucible directory. Framework source dirs (e.g.
        # powershell/) can accumulate gitignored runtime state under their own
        # .crucible/ when the framework is exercised in place; -Recurse -Force
        # would otherwise drag that stale state into every adopter install.
        if (($relative -split '[\\/]') -contains ".crucible") {
            continue
        }

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
$installManifest = Get-InstallManifest -FrameworkRoot $REPO_ROOT

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
$configPath = Join-Path $targetCrucible "config.yaml"

if ($StampVersionOnly) {
    $stamp = Get-CrucibleSourceStamp
    Set-CrucibleConfigStamp -ConfigPath $configPath -Version $stamp.Version -Commit $stamp.Commit -AllowExisting ([bool]$Force)
    Write-Info ("Stamped Crucible metadata in " + $configPath) -ForegroundColor Green
    exit 0
}

# Detect existing backlog_dir config before overwriting
$detectedBacklogDir = ""
$existingConfigPath = $configPath
if (Test-Path -LiteralPath $existingConfigPath) {
    try {
        $existingContent = Get-Content -LiteralPath $existingConfigPath -Raw -Encoding UTF8
        if ($existingContent -match '(?ms)^paths:\s*\r?\n(.*?)(?=\r?\n\S|\z)') {
            $pathsBlock = $Matches[1]
            if ($pathsBlock -match '(?m)^\s{2}backlog:\s*["''\r\n]?([^"''\r\n]+)["''\r\n]?\s*$') {
                $detectedBacklogDir = $Matches[1].Trim()
            }
        }
    } catch {}
}

if ((Test-Path -LiteralPath (Join-Path $targetCrucible "config.yaml")) -and -not $Force) {
    throw "An installed Crucible bundle already exists at $targetCrucible. To update individual files, see docs/updating.md (selective-copy workflow). To reinstall from scratch, delete .crucible/ first or pass -Force."
}
Copy-TemplateDirectory -Source $templateRoot -Destination $targetCrucible -AllowOverwrite ([bool]$Force)

# Copy active framework directories to make the installation self-contained
foreach ($dirName in @($installManifest.copied_dirs)) {
    $srcDir = Join-Path $REPO_ROOT $dirName
    $destDir = Join-Path $targetCrucible $dirName
    Copy-TemplateDirectory -Source $srcDir -Destination $destDir -AllowOverwrite ([bool]$Force)
}

foreach ($fileName in @($installManifest.root_files)) {
    $srcFile = Join-Path $REPO_ROOT $fileName
    $destFile = Join-Path $targetCrucible $fileName
    if (-not (Test-Path -LiteralPath $srcFile -PathType Leaf)) {
        throw "Install manifest root file not found: $srcFile"
    }
    $destDir = Split-Path -Parent $destFile
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    if ((Test-Path -LiteralPath $destFile) -and -not $Force) {
        throw "Refusing to overwrite existing file: $destFile. Re-run with -Force to overwrite framework-managed files."
    }
    Copy-Item -LiteralPath $srcFile -Destination $destFile -Force:$Force
}

if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Bootstrap failed: expected config file was not created at $configPath"
}

$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
$config = $config -replace '(?m)^  name: .+$', ('  name: ' + (ConvertTo-YamlScalar -Value $ProjectName))
$config = $config -replace '(?m)^  description: .+$', ('  description: ' + (ConvertTo-YamlScalar -Value $Description))
$config = $config -replace '(?m)^  default_branch: .+$', ('  default_branch: ' + (ConvertTo-YamlScalar -Value $DefaultBranch))
$config = $config -replace '(?m)^crucible_root: .+$', ('crucible_root: ' + (ConvertTo-YamlScalar -Value ".crucible"))

$stamp = Get-CrucibleSourceStamp
if ($stamp.Version -match '^[0-9]+\.[0-9]+\.[0-9]+') {
    $config = $config -replace '(?m)^crucible_version: .+$', ('crucible_version: ' + (ConvertTo-YamlScalar -Value $stamp.Version))
} else {
    $config = $config -replace '(?m)^crucible_version: .+\r?\n', ''
}

if ($stamp.Commit -match '^[0-9a-f]{40}$') {
    $config = $config -replace '(?m)^crucible_install_commit: .+$', ('crucible_install_commit: ' + (ConvertTo-YamlScalar -Value $stamp.Commit))
} else {
    $config = $config -replace '(?m)^crucible_install_commit: .+\r?\n', ''
}

if (![string]::IsNullOrEmpty($Language)) {
    $presets = Get-LanguagePresets
    $preset = $presets[$Language.ToLower()]
    
    $verifYaml = "verification:`r`n  quick:"
    foreach ($step in $preset.quick) {
        $verifYaml += "`r`n    - name: $($step.name)`r`n      command: $($step.command)"
    }
    $verifYaml += "`r`n  full:"
    foreach ($step in $preset.full) {
        $verifYaml += "`r`n    - name: $($step.name)`r`n      command: $($step.command)"
    }
    
    $config = $config -replace '(?ms)^verification:.*?(?=\r?\n\r?\n|\z|\r?\n[a-zA-Z_])', $verifYaml
}

$finalBacklogDir = $BacklogDir
if ([string]::IsNullOrEmpty($finalBacklogDir) -and ![string]::IsNullOrEmpty($detectedBacklogDir)) {
    $finalBacklogDir = $detectedBacklogDir
}

if (![string]::IsNullOrEmpty($finalBacklogDir)) {
    $backlogVal = ConvertTo-YamlScalar -Value $finalBacklogDir
    $pathsBlock = "`r`npaths:`r`n  backlog: $backlogVal`r`n  session: .crucible/session`r`n  workspaces: .crucible/.agent-workspaces`r`n  prompts: .crucible/prompts`r`n  personas: .crucible/personas`r`n  sops: .crucible/sops"
    $config += $pathsBlock
}

Write-Utf8NoBomFile -Path $configPath -Content $config

# Resolve custom backlog directory
$backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $resolvedProjectRoot
$defaultBacklogDir = Join-Path $targetCrucible "backlog"
if ($backlogDir -ne $defaultBacklogDir) {
    # If custom backlog directory is configured, move scaffolded backlog files there
    if (Test-Path -LiteralPath $defaultBacklogDir) {
        if (-not (Test-Path -LiteralPath $backlogDir)) {
            New-Item -ItemType Directory -Path $backlogDir -Force | Out-Null
        }
        # Copy files/folders recursively
        Get-ChildItem -Path $defaultBacklogDir -Recurse | ForEach-Object {
            $dest = Join-Path $backlogDir $_.FullName.Substring($defaultBacklogDir.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
            if ($_.PSIsContainer) {
                if (-not (Test-Path -LiteralPath $dest)) {
                    New-Item -ItemType Directory -Path $dest -Force | Out-Null
                }
            } else {
                if (-not (Test-Path -LiteralPath $dest) -or $Force) {
                    Copy-Item -LiteralPath $_.FullName -Destination $dest -Force | Out-Null
                }
            }
        }
        # Clean up default template backlog folder
        Remove-Item -LiteralPath $defaultBacklogDir -Recurse -Force | Out-Null
    }
}

if ($WithSampleTask) {
    # 1. Resolve sample criteria based on language
    $criteria = ""
    if ($Language -eq "go") {
        $criteria = '  - [ ] Implement a function `GetHello` that returns "Hello, World!"' + "`r`n" +
                    '  - [ ] Add a unit test verifying `GetHello` returns "Hello, World!"' + "`r`n" +
                    '  - [ ] Verification command `go test ./...` passes'
    } elseif ($Language -eq "node") {
        $criteria = '  - [ ] Implement a function `getHello` that returns "Hello, World!"' + "`r`n" +
                    '  - [ ] Add a unit test verifying `getHello` returns "Hello, World!"' + "`r`n" +
                    '  - [ ] Verification command `npm test` passes'
    } elseif ($Language -eq "python") {
        $criteria = '  - [ ] Implement a function `get_hello` that returns "Hello, World!"' + "`r`n" +
                    '  - [ ] Add a unit test verifying `get_hello` returns "Hello, World!"' + "`r`n" +
                    '  - [ ] Verification command `pytest` passes'
    } elseif ($Language -eq "rust") {
        $criteria = '  - [ ] Implement a function `get_hello` that returns "Hello, World!"' + "`r`n" +
                    '  - [ ] Add a unit test verifying `get_hello` returns "Hello, World!"' + "`r`n" +
                    '  - [ ] Verification command `cargo test` passes'
    } else {
        $criteria = '  - [ ] Create a file named `hello.txt` at the root of the project' + "`r`n" +
                    '  - [ ] The file `hello.txt` must contain the text "Hello, World!"'
    }

    $sampleTaskTemplate = Join-Path $REPO_ROOT "templates/sample-task/F-001_Hello_World.md"
    if (-not (Test-Path -LiteralPath $sampleTaskTemplate)) {
        throw "Sample task template not found at $sampleTaskTemplate"
    }

    $taskContent = Get-Content -LiteralPath $sampleTaskTemplate -Raw -Encoding UTF8
    $taskContent = $taskContent.Replace("{{LANGUAGE_CRITERIA}}", $criteria)

    $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $resolvedProjectRoot
    $targetBacklogDir = Join-Path $backlogDir "features/active"
    if (-not (Test-Path -LiteralPath $targetBacklogDir)) {
        New-Item -ItemType Directory -Path $targetBacklogDir -Force | Out-Null
    }

    $targetTaskPath = Join-Path $targetBacklogDir "F-001_Hello_World.md"
    if ((Test-Path -LiteralPath $targetTaskPath) -and -not $Force) {
        throw "Refusing to overwrite existing sample task: $targetTaskPath. Re-run with -Force to overwrite."
    }
    $taskContent | Out-File -LiteralPath $targetTaskPath -Encoding UTF8

    # 2. Update BACKLOG.md
    $backlogFilePath = Join-Path $backlogDir "BACKLOG.md"
    if (Test-Path -LiteralPath $backlogFilePath) {
        $backlogContent = Get-Content -LiteralPath $backlogFilePath -Raw -Encoding UTF8
        $row = "| [F-001](features/active/F-001_Hello_World.md) | P1 | Ready | Hello World Smoke Test | Groomer |"
        
        $newBacklogContent = $backlogContent -replace "(?m)(^\|\s*---\s*\|\s*---\s*\|\s*---\s*\|\s*---\s*\|\s*---\s*\|\s*$)", "`$1`r`n$row"
        if ($newBacklogContent -eq $backlogContent) {
            $newBacklogContent = $backlogContent -replace "(?m)(^\|\s*---\s*\|\s*---\s*\|\s*---\s*\|\s*---\s*\|\s*---\s*\|\s*$)", "`$1`n$row"
        }
        $newBacklogContent | Out-File -LiteralPath $backlogFilePath -Encoding UTF8

        # 3. Call validate-backlog.ps1 -FixSummary
        $validateQuiet = $true
        if ($PSBoundParameters.ContainsKey('Verbose')) {
            $validateQuiet = $false
        }
        if ($Quiet) {
            $validateQuiet = $true
        }
        & (Join-Path $PSScriptRoot "validate-backlog.ps1") -FixSummary -BacklogPath $backlogFilePath -Quiet:$validateQuiet | Out-Null
    }
}

if ($stamp.Commit -match '^[0-9a-f]{40}$') {
    try {
        $provenance = New-ProvenanceManifest -FrameworkRoot $REPO_ROOT -Commit $stamp.Commit -Manifest $installManifest
        $provenancePath = Write-ProvenanceManifest -BundleRoot $targetCrucible -ProvenanceManifest $provenance
        Write-Info ("Wrote provenance manifest: " + $provenancePath) -ForegroundColor DarkGray
    } catch {
        Write-Warning ("Could not write provenance manifest: " + $_.Exception.Message)
    }
}

if ($AppendInstructions) {
    Install-CrucibleInstructions -ProjectRoot $resolvedProjectRoot -Quiet:$Quiet | Out-Null
}

# Set git hooks path for the adopter
if (Test-Path -LiteralPath (Join-Path $resolvedProjectRoot ".git")) {
    Push-Location $resolvedProjectRoot
    try {
        git config core.hooksPath ".crucible/scripts/hooks"
        Write-Info "Set git core.hooksPath to '.crucible/scripts/hooks'" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to set git core.hooksPath: $_"
    } finally {
        Pop-Location
    }
}

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
$backlogDirForRel = Get-ConfiguredPath -Key "backlog" -ProjectRoot $resolvedProjectRoot
$relativeBacklogPath = $backlogDirForRel
if ($backlogDirForRel.StartsWith($resolvedProjectRoot)) {
    $relativeBacklogPath = $backlogDirForRel.Substring($resolvedProjectRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}
$relativeBacklogPath = $relativeBacklogPath -replace '\\', '/'
if (-not $relativeBacklogPath.EndsWith('/')) { $relativeBacklogPath += '/' }

Write-Info "Ignored by default (data and runtime state):" -ForegroundColor Cyan
Write-Info "  - $relativeBacklogPath (tickets are data, not code)"
Write-Info "  - .crucible/session/, .agent-workspaces/, locks/"
Write-Info "  - .crucible/tmp/, cache/, archive/, archived/, history/"
Write-Info "  - .crucible/research/, dev-logs/"
Write-Info "  - generated logs, JSONL, handoffs, eval output"
Write-Info ""
Write-Info "crucible_root auto-set to: .crucible" -ForegroundColor DarkGray
Write-Info ""
Write-Info "Next edits:" -ForegroundColor Cyan
if (![string]::IsNullOrEmpty($Language)) {
    Write-Info "  1. (done) Verification commands for $Language configured in .crucible/config.yaml. Review mandates." -ForegroundColor DarkGray
} else {
    Write-Info "  1. Edit .crucible/config.yaml verification commands and project mandates."
}
if ($AppendInstructions) {
    Write-Info "  2. (done) Crucible instruction blocks appended to AGENTS.md, CLAUDE.md, GEMINI.md." -ForegroundColor DarkGray
    Write-Info "  3. (done) Tool-specific forwarding snippets included." -ForegroundColor DarkGray
} else {
    Write-Info "  2. Merge .crucible/agent-instructions/AGENTS.md into the project root AGENTS.md."
    Write-Info "  3. Add CLAUDE.md or GEMINI.md forwarding snippets if those tools are used."
}
Write-Info "  4. From the project root, run .crucible/powershell/validate-config.ps1 -ConfigPath .crucible/config.yaml."
if ($WithSampleTask) {
    Write-Info "  5. F-001 sample task installed. Run '.\.crucible\powershell\factory.ps1 -Init -TaskId F-001' to smoke-test the pipeline. Add your own backlog items afterward." -ForegroundColor DarkGray
} else {
    Write-Info "  5. Add initial backlog items under $relativeBacklogPath."
}
Write-Info "  6. Commit durable .crucible files and root instruction-file updates."
