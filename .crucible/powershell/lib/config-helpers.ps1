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
        [ValidateSet("diff_tool", "editor")]
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
