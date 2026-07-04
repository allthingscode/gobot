function Get-ConfiguredPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("backlog", "session", "workspaces", "prompts", "personas", "sops")]
        [string]$Key,
        [string]$ProjectRoot = ""
    )

    # 1. Resolve Project Root
    $root = ""
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $root = $ProjectRoot
    } else {
        # Safely query variables under strict mode using dynamic scope search
        $repoRootVar = Get-Variable -Name "REPO_ROOT" -ErrorAction SilentlyContinue
        if ($null -ne $repoRootVar) {
            $root = $repoRootVar.Value
        } else {
            $root = (Get-Location).Path
        }
    }

    if ($root -and (Test-Path -LiteralPath $root)) {
        $root = (Resolve-Path -LiteralPath $root).Path
    }

    # If root is still empty, fall back to current location
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = (Get-Location).Path
    }

    $configPath = Join-Path $root ".crucible/config.yaml"
    
    # Defaults
    $defaults = @{
        backlog    = ".crucible/backlog"
        session    = ".crucible/session"
        workspaces = ".crucible/.agent-workspaces"
        prompts    = ".crucible/prompts"
        personas   = ".crucible/personas"
        sops       = ".crucible/sops"
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        return (Join-Path $root $defaults[$Key])
    }

    # Parse config.yaml manually to extract the key value
    try {
        $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        # Search for: key: value inside paths: block
        if ($content -match '(?ms)^paths:\s*\r?\n(.*?)(?=\r?\n\S|\z)') {
            $pathsBlock = $Matches[1]
            if ($pathsBlock -match ('(?m)^\s{2}' + [regex]::Escape($Key) + ':\s*["'']?([^"''\r\n]+)["'']?\s*$')) {
                $val = $Matches[1].Trim()
                if ([System.IO.Path]::IsPathRooted($val)) {
                    return $val
                }
                return (Join-Path $root $val)
            }
        }
    } catch {}

    return (Join-Path $root $defaults[$Key])
}

function Get-ConfiguredReview {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("diff_tool", "editor", "auto_push", "require_green_ci", "ci_timeout_minutes")]
        [string]$Key,
        [string]$ProjectRoot = ""
    )

    # 1. Resolve Project Root
    $root = ""
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $root = $ProjectRoot
    } else {
        $repoRootVar = Get-Variable -Name "REPO_ROOT" -ErrorAction SilentlyContinue
        if ($null -ne $repoRootVar) {
            $root = $repoRootVar.Value
        } else {
            $root = (Get-Location).Path
        }
    }

    if ($root -and (Test-Path -LiteralPath $root)) {
        $root = (Resolve-Path -LiteralPath $root).Path
    }

    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = (Get-Location).Path
    }

    $configPath = Join-Path $root ".crucible/config.yaml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        if ($Key -eq "auto_push" -or $Key -eq "require_green_ci") { return "false" }
        if ($Key -eq "ci_timeout_minutes") { return "20" }
        return ""
    }

    try {
        $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        # Search for: key: value inside review: block
        if ($content -match '(?ms)^review:\s*\r?\n(.*?)(?=\r?\n\S|\z)') {
            $reviewBlock = $Matches[1]
            if ($reviewBlock -match ('(?m)^\s{2}' + [regex]::Escape($Key) + ':\s*["'']?([^"''\r\n]+)["'']?\s*$')) {
                return $Matches[1].Trim()
            }
        }
    } catch {}

    if ($Key -eq "auto_push" -or $Key -eq "require_green_ci") { return "false" }
    if ($Key -eq "ci_timeout_minutes") { return "20" }
    return ""
}

function Get-ConfiguredManifestFiles {
    param(
        [string]$ProjectRoot = ""
    )

    $root = ""
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $root = $ProjectRoot
    } else {
        $repoRootVar = Get-Variable -Name "REPO_ROOT" -ErrorAction SilentlyContinue
        if ($null -ne $repoRootVar) {
            $root = $repoRootVar.Value
        } else {
            $root = (Get-Location).Path
        }
    }

    if ($root -and (Test-Path -LiteralPath $root)) {
        $root = (Resolve-Path -LiteralPath $root).Path
    }

    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = (Get-Location).Path
    }

    $configPath = Join-Path $root ".crucible/config.yaml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return @()
    }

    try {
        $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        if ($content -match '(?ms)^manifest_files:\s*\r?\n(.*?)(?=\r?\n\S|\z)') {
            $block = $Matches[1]
            $list = @()
            $lines = $block -split '\r?\n'
            foreach ($line in $lines) {
                if ($line -match '^\s*-\s*(.*)$') {
                    $item = $Matches[1].Trim().Trim('"' + "'")
                    if (-not [string]::IsNullOrWhiteSpace($item)) {
                        $list += $item
                    }
                }
            }
            if ($list.Count -gt 0) {
                return $list
            }
        }
        if ($content -match '(?m)^manifest_files:\s*\[(.*?)\]\s*$') {
            $items = $Matches[1] -split ','
            $list = @()
            foreach ($item in $items) {
                $clean = $item.Trim().Trim('"' + "'")
                if (-not [string]::IsNullOrWhiteSpace($clean)) {
                    $list += $clean
                }
            }
            return $list
        }
    } catch {}

    return @()
}

# Resolve an abstract capability tier (strong/default/light, from Get-SpecialistModel) to a
# concrete model name for the active CLI target. Resolution order:
#   1. the config.yaml `models:` block (operator-editable; models change often)
#   2. the framework default map below (source of truth when config is absent)
#   3. the tier token itself (last resort; never throws)
# 'agent' is the generic default CLI and runs the Claude models. An empty tier (the 'done'
# phase) has no model. Keep the default map in sync with templates/project/.crucible/config.yaml.
function Get-ConfiguredModel {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Tier,
        [string]$ProjectRoot = ""
    )

    if ([string]::IsNullOrWhiteSpace($Tier)) { return "" }

    $target = if ($null -ne $Target) { $Target.Trim().ToLowerInvariant() } else { "" }
    if ([string]::IsNullOrWhiteSpace($target) -or $target -eq "agent") { $target = "claude" }
    $tier = $Tier.Trim().ToLowerInvariant()

    $defaults = @{
        claude      = @{ strong = "opus";                   default = "sonnet";                  light = "haiku" }
        codex       = @{ strong = "gpt-5.5";                 default = "gpt-5.5";                  light = "gpt-5.4" }
        antigravity = @{ strong = "Gemini 3.1 Pro (High)";   default = "Gemini 3.5 Flash (High)";  light = "Gemini 3.5 Flash (Medium)" }
    }

    $configured = Get-ModelFromConfig -Target $target -Tier $tier -ProjectRoot $ProjectRoot
    if (-not [string]::IsNullOrWhiteSpace($configured)) { return $configured }

    if ($defaults.ContainsKey($target) -and $defaults[$target].ContainsKey($tier)) {
        return $defaults[$target][$tier]
    }

    return $tier
}

# Read models.targets.<target>.<tier> from config.yaml. Returns "" when absent. The block is
# 2-space-indented YAML: models: (0) > targets: (2) > <target>: (4) > <tier>: (6).
function Get-ModelFromConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Tier,
        [string]$ProjectRoot = ""
    )

    $root = ""
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $root = $ProjectRoot
    } else {
        $repoRootVar = Get-Variable -Name "REPO_ROOT" -ErrorAction SilentlyContinue
        if ($null -ne $repoRootVar) { $root = $repoRootVar.Value } else { $root = (Get-Location).Path }
    }
    if ($root -and (Test-Path -LiteralPath $root)) { $root = (Resolve-Path -LiteralPath $root).Path }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }

    $configPath = Join-Path $root ".crucible/config.yaml"
    if (-not (Test-Path -LiteralPath $configPath)) { return "" }

    try {
        $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        if ($content -match '(?ms)^models:[ \t]*\r?\n(.*?)(?=\r?\n\S|\z)') {
            $modelsBlock = $Matches[1]
            $targetPattern = '(?ms)^[ ]{4}' + [regex]::Escape($Target) + ':[ \t]*\r?\n(.*?)(?=\r?\n[ ]{0,4}\S|\z)'
            if ($modelsBlock -match $targetPattern) {
                $targetBlock = $Matches[1]
                $tierPattern = '(?m)^[ ]{6}' + [regex]::Escape($Tier) + ':[ \t]*["'']?([^"''\r\n]+)["'']?[ \t]*$'
                if ($targetBlock -match $tierPattern) {
                    return $Matches[1].Trim()
                }
            }
        }
    } catch {}

    return ""
}

function Get-ConfiguredEditorCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EditorOrToolName
    )
    if ([string]::IsNullOrWhiteSpace($EditorOrToolName)) {
        return ""
    }
    
    if (Get-Command $EditorOrToolName -ErrorAction SilentlyContinue) {
        return $EditorOrToolName
    }
    if (Test-Path -LiteralPath $EditorOrToolName) {
        return $EditorOrToolName
    }
    
    if ($EditorOrToolName -eq "zed" -or $EditorOrToolName -eq "zed.exe") {
        $localZed = "$env:LOCALAPPDATA\Programs\Zed\bin\zed.exe"
        if (Test-Path -LiteralPath $localZed) {
            return $localZed
        }
    }
    
    if ($EditorOrToolName -eq "code" -or $EditorOrToolName -eq "code.cmd") {
        $localCode = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd"
        if (Test-Path -LiteralPath $localCode) {
            return $localCode
        }
    }
    
    return $EditorOrToolName
}

function Parse-SemVer {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $null
    }
    if ($Raw -match '(\d+)\.(\d+)\.(\d+)') {
        return [int[]]@([int]$matches[1], [int]$matches[2], [int]$matches[3])
    }
    if ($Raw -match '(\d+)\.(\d+)') {
        return [int[]]@([int]$matches[1], [int]$matches[2], 0)
    }
    return $null
}

function Compare-SemVer {
    param(
        [Parameter(Mandatory=$true)][int[]]$A,
        [Parameter(Mandatory=$true)][int[]]$B
    )

    for ($i = 0; $i -lt 3; $i++) {
        if ($A[$i] -gt $B[$i]) { return 1 }
        if ($A[$i] -lt $B[$i]) { return -1 }
    }
    return 0
}
