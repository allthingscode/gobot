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
