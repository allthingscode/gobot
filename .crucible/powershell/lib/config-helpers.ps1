# --- config.yaml reader -------------------------------------------------------
# One parser backs every accessor below. It keeps three outcomes distinct, because
# collapsing the third into the second is what let a valid config silently disable a
# gate: every accessor used to pin the indent to exactly two spaces, so a 3- or
# 4-space `review:` block read as absent and `require_green_ci` fell back to false.
#   - key present and readable -> the value
#   - key genuinely absent     -> $null, and the caller's default is legitimate
#   - key present, unreadable  -> throw
# Indent is compared relatively rather than pinned, so 2-space, 3-space, 4-space and
# tab-indented YAML all read alike.

function Get-ConfigEntries {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $entries = @()
    if ([string]::IsNullOrEmpty($Content)) { return $entries }

    # A UTF-8 BOM survives Get-Content -Raw on Windows PowerShell and would otherwise be
    # glued to the first key, making line 1 unmatchable.
    $text = $Content -replace '^\uFEFF', ''

    foreach ($line in ($text -split '\r?\n')) {
        if ($line -match '^[ \t]*$') { continue }
        if ($line -match '^[ \t]*#') { continue }

        $indent = 0
        while ($indent -lt $line.Length -and ($line[$indent] -eq ' ' -or $line[$indent] -eq "`t")) { $indent++ }

        $key = $null
        $value = $null
        if ($line -match '^[ \t]*([A-Za-z0-9_.-]+):[ \t]*(.*)$') {
            $key = $Matches[1]
            $value = $Matches[2]
        }

        $entries += [pscustomobject]@{
            Indent = $indent
            Key    = $key
            Value  = $value
            Text   = $line.Trim()
        }
    }

    return $entries
}

# Unquote a scalar and drop a trailing comment. A quoted value is taken verbatim so a
# '#' inside it survives.
function ConvertFrom-ConfigScalar {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Raw)

    $text = $Raw.Trim()
    if ($text -match '^"([^"]*)"') { return $Matches[1] }
    if ($text -match "^'([^']*)'") { return $Matches[1] }
    if ($text -match '^(.*?)[ \t]+#') { $text = $Matches[1] }
    return $text.Trim()
}

# A key the caller asked for that appears in the block but is not a 'key: value' pair is
# a malformed config, not an absent one. Saying so is the whole point of item 34.
function Assert-ReadableConfigKey {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory = $true)][int]$Start,
        [Parameter(Mandatory = $true)][int]$End,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Source
    )

    for ($i = $Start; $i -lt $End; $i++) {
        if ($null -ne $Entries[$i].Key) { continue }
        if ($Entries[$i].Text -match ('^' + [regex]::Escape($Key) + '\b')) {
            throw ("Unreadable " + $Source + ": line '" + $Entries[$i].Text + "' names '" + $Key + "' but is not a 'key: value' pair.")
        }
    }
}

# Walk Path as nested mapping keys. Returns $null when a key along the path is absent,
# or the matched entry's index plus the span of its child lines.
function Find-ConfigNode {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory = $true)][string[]]$Path,
        [Parameter(Mandatory = $true)][string]$Source
    )

    $start = 0
    $end = $Entries.Count
    $parentIndent = -1
    $matchIdx = -1

    foreach ($key in $Path) {
        $childIndent = -1
        $matchIdx = -1
        for ($i = $start; $i -lt $end; $i++) {
            $entry = $Entries[$i]
            if ($entry.Indent -le $parentIndent) { break }
            if ($childIndent -lt 0) { $childIndent = $entry.Indent }
            if ($entry.Indent -ne $childIndent) { continue }
            if ($entry.Key -eq $key) { $matchIdx = $i; break }
        }

        if ($matchIdx -lt 0) {
            Assert-ReadableConfigKey -Entries $Entries -Start $start -End $end -Key $key -Source $Source
            return $null
        }

        $parentIndent = $Entries[$matchIdx].Indent
        $start = $matchIdx + 1
        $span = $start
        while ($span -lt $end -and $Entries[$span].Indent -gt $parentIndent) { $span++ }
        $end = $span
    }

    return [pscustomobject]@{
        Index     = $matchIdx
        SpanStart = $start
        SpanEnd   = $end
    }
}

function Get-ConfigBlockValue {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string[]]$Path,
        [Parameter(Mandatory = $true)][string]$Source
    )

    $entries = @(Get-ConfigEntries -Content $Content)
    $node = Find-ConfigNode -Entries $entries -Path $Path -Source $Source
    if ($null -eq $node) { return $null }

    $value = ConvertFrom-ConfigScalar $entries[$node.Index].Value
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw ("Unreadable " + $Source + ": '" + ($Path -join ".") + "' is present but carries no value.")
    }
    return $value
}

function Get-ConfigBlockList {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string[]]$Path,
        [Parameter(Mandatory = $true)][string]$Source
    )

    $entries = @(Get-ConfigEntries -Content $Content)
    $node = Find-ConfigNode -Entries $entries -Path $Path -Source $Source
    if ($null -eq $node) { return $null }

    $items = @()
    $inline = $entries[$node.Index].Value
    if (-not [string]::IsNullOrWhiteSpace($inline)) {
        if (-not ($inline.Trim() -match '^\[(.*)\]$')) {
            throw ("Unreadable " + $Source + ": '" + ($Path -join ".") + "' is not a list.")
        }
        foreach ($part in ($Matches[1] -split ',')) {
            $clean = ConvertFrom-ConfigScalar $part
            if (-not [string]::IsNullOrWhiteSpace($clean)) { $items += $clean }
        }
        return $items
    }

    for ($i = $node.SpanStart; $i -lt $node.SpanEnd; $i++) {
        if ($entries[$i].Text -match '^-[ \t]*(.*)$') {
            $clean = ConvertFrom-ConfigScalar $Matches[1]
            if (-not [string]::IsNullOrWhiteSpace($clean)) { $items += $clean }
        }
    }
    if ($items.Count -eq 0) {
        throw ("Unreadable " + $Source + ": '" + ($Path -join ".") + "' is present but holds no entries.")
    }
    return $items
}

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

    $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $val = Get-ConfigBlockValue -Content $content -Path @("paths", $Key) -Source $configPath
    if ($null -ne $val) {
        if ([System.IO.Path]::IsPathRooted($val)) {
            return $val
        }
        return (Join-Path $root $val)
    }

    return (Join-Path $root $defaults[$Key])
}

function Get-ConfiguredReview {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("diff_tool", "editor", "auto_push", "require_green_ci", "ci_timeout_minutes", "ci_queued_grace_minutes", "ci_staging_branch_prefix", "ci_required_checks", "ci_post_push_watch")]
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
    if (Test-Path -LiteralPath $configPath) {
        $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $val = Get-ConfigBlockValue -Content $content -Path @("review", $Key) -Source $configPath
        if ($null -ne $val) { return $val }
    }

    if ($Key -eq "auto_push" -or $Key -eq "require_green_ci" -or $Key -eq "ci_post_push_watch") { return "false" }
    if ($Key -eq "ci_timeout_minutes") { return "20" }
    if ($Key -eq "ci_queued_grace_minutes") { return "15" }
    return ""
}

# hooks.project_dir names the adopter's own hooks directory, which Crucible's hooks run
# after their own checks because core.hooksPath otherwise shadows it. Absent means no
# chaining. A present but unusable value throws rather than returning $null: a hook that
# quietly stops chaining is the silent shadowing this setting exists to end. Item 150.
function Get-ConfiguredProjectHooksDir {
    param([string]$ProjectRoot = "")

    $root = $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }
    $root = (Resolve-Path -LiteralPath $root).Path

    $configPath = Join-Path $root ".crucible/config.yaml"
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }

    $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $val = Get-ConfigBlockValue -Content $content -Path @("hooks", "project_dir") -Source $configPath
    if ($null -eq $val) { return $null }
    return (Resolve-ProjectHooksDirValue -Value $val -ProjectRoot $root)
}

function Resolve-ProjectHooksDirValue {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    $val = $Value
    $root = $ProjectRoot
    if ([System.IO.Path]::IsPathRooted($val) -or $val -match '^([A-Za-z]:|[\\/])') {
        throw ("hooks.project_dir must be a relative path inside the project (got '" + $val + "').")
    }
    if ($val -match '^\.\.' -or $val -match '[\\/]\.\.') {
        throw ("hooks.project_dir must not escape the project root (got '" + $val + "').")
    }
    # Crucible's own hooks live under .crucible; naming them would make each hook run itself.
    if ($val -match '^\.crucible([\\/]|$)') {
        throw ("hooks.project_dir must name the project's own hooks, not a directory under .crucible (got '" + $val + "').")
    }

    $full = Join-Path $root $val
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw ("hooks.project_dir names a directory that does not exist: " + $val)
    }
    return (Resolve-Path -LiteralPath $full).Path
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

    $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $list = Get-ConfigBlockList -Content $content -Path @("manifest_files") -Source $configPath
    if ($null -ne $list) {
        return $list
    }

    return @()
}

# Resolve an abstract capability tier (strong/default/light, from Get-SpecialistModel) to a
# concrete model name for the active CLI target. Resolution order:
#   1. the config.yaml `models:` block (operator-editable; models change often)
#   2. the framework default map below (source of truth when config is absent)
#   3. the tier token itself (last resort; never throws)
# 'agent' is the generic default CLI and runs the Claude models. 'grok' has no model
# knob: the default for every tier is 'inherit', which tells the orchestrator to omit
# model. A config.yaml value still wins, so an adopter can pin a slug later. An empty
# tier (the 'done' phase) has no model. Keep the default map in sync with
# templates/project/.crucible/config.yaml.
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
        codex       = @{ strong = "gpt-6.1-sol";             default = "gpt-6.1-sol";              light = "gpt-6-luna" }
        antigravity = @{ strong = "Gemini 3.1 Pro (High)";   default = "Gemini 3.8 Flash (High)";  light = "Gemini 3.8 Flash (Medium)" }
        grok        = @{ strong = "inherit";                 default = "inherit";                  light = "inherit" }
    }

    $configured = Get-ModelFromConfig -Target $target -Tier $tier -ProjectRoot $ProjectRoot
    if (-not [string]::IsNullOrWhiteSpace($configured)) { return $configured }

    if ($defaults.ContainsKey($target) -and $defaults[$target].ContainsKey($tier)) {
        return $defaults[$target][$tier]
    }

    return $tier
}

# Read models.targets.<target>.<tier> from config.yaml. Returns "" when absent. Nesting is
# models: > targets: > <target>: > <tier>:, at whatever indent width the file uses.
function Get-ModelFromConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Tier,
        [string]$ProjectRoot = ""
    )

    return Get-ModelsBlockValue -Path @("models", "targets", $Target, $Tier) -ProjectRoot $ProjectRoot
}

# Read models.effort.<target>.<tier> from config.yaml. Returns "" when absent.
function Get-EffortFromConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Tier,
        [string]$ProjectRoot = ""
    )

    return Get-ModelsBlockValue -Path @("models", "effort", $Target, $Tier) -ProjectRoot $ProjectRoot
}

function Get-ModelsBlockValue {
    param(
        [Parameter(Mandatory = $true)][string[]]$Path,
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

    $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $val = Get-ConfigBlockValue -Content $content -Path $Path -Source $configPath
    if ($null -ne $val) { return $val }

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
