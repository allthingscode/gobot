# Inspection only: never execute the selected Gobot binary.
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot), [string]$ToolDirectory)
. (Join-Path $PSScriptRoot 'check_security.ps1') -ToolDirectory $ToolDirectory

function Resolve-SelectedBinary {
    param([string]$ProjectRoot)
    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectRoot)
    foreach ($relative in @('bin/gobot.exe', 'gobot.exe')) {
        $candidate = Join-Path $root $relative
        if (Test-Path -LiteralPath $candidate) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Selected candidate is not a file: $candidate" }
            return $candidate
        }
    }
    throw "Missing gobot.exe in bin or project root: $root"
}

function Invoke-BinaryNative {
    param([string]$Command, [string[]]$Arguments)
    try {
        $output = & $Command @Arguments 2>&1
        [pscustomobject]@{ Output = @($output); Code = $LASTEXITCODE }
    } catch { [pscustomobject]@{ Output = @($_.Exception.Message); Code = 1 } }
}

function Read-BinaryMetadata {
    param([string[]]$Lines)
    $metadata = @{ Settings = @{}; Dependencies = @(); GoVersion = ''; MainPath = ''; Module = '' }
    $lastModule = $null
    foreach ($line in $Lines) {
        Write-Host $line
        if ($line -match '^.+:\s+(go\d+\.\d+(?:\.\d+)?(?:\S*)?)\s*$') { $metadata.GoVersion = $Matches[1]; continue }
        $parts = @($line.Trim() -split '\s+')
        if (-not $parts[0]) { continue }
        switch ($parts[0]) {
            'path' { if ($parts.Count -ne 2 -or $metadata.MainPath) { throw 'Malformed path metadata' }; $metadata.MainPath = $parts[1] }
            'mod' {
                if ($parts.Count -lt 3 -or $metadata.Module) { throw 'Malformed module metadata' }
                $metadata.Module = $parts[1]
                $lastModule = @{ Path = $parts[1]; Version = $parts[2]; Replace = $null }
                $metadata.MainModule = $lastModule
            }
            'dep' {
                if ($parts.Count -lt 3) { throw 'Malformed dependency metadata' }
                $lastModule = @{ Path = $parts[1]; Version = $parts[2]; Replace = $null }
                $metadata.Dependencies += $lastModule
            }
            '=>' {
                if ($null -eq $lastModule -or $parts.Count -lt 2 -or $lastModule.Replace) { throw 'Malformed replacement metadata' }
                $lastModule.Replace = @{ Path = $parts[1]; Version = $(if ($parts.Count -gt 2) { $parts[2] } else { '' }) }
            }
            'build' {
                if ($line.Trim() -notmatch '^build\s+([^=\s]+)=(.*)$') { throw 'Malformed build metadata' }
                $key = $Matches[1]; $value = $Matches[2].Trim('"')
                if ($metadata.Settings.ContainsKey($key)) { throw "Duplicate build setting: $key" }
                $metadata.Settings[$key] = $value
            }
            default { throw "Malformed metadata line: $line" }
        }
    }
    if (-not $metadata.GoVersion -or -not $metadata.MainPath -or -not $metadata.Module) { throw 'Missing Go, path or module metadata' }
    return $metadata
}

function Read-BinaryModuleGraph {
    param([string]$Json)
    # go list emits consecutive JSON objects, not a JSON array. Track strings and
    # nesting rather than splitting on braces (replacement objects are nested).
    $depth = 0; $quoted = $false; $escaped = $false; $start = -1; $modules = @{}
    for ($i = 0; $i -lt $Json.Length; $i++) {
        $character = $Json[$i]
        if ($quoted) {
            if ($escaped) { $escaped = $false }
            elseif ($character -eq '\') { $escaped = $true }
            elseif ($character -eq '"') { $quoted = $false }
            continue
        }
        if ($character -eq '"') {
            if ($depth -eq 0) { throw 'Malformed module graph' }
            $quoted = $true; continue
        }
        if ($character -eq '{') { if ($depth -eq 0) { $start = $i }; $depth++ }
        elseif ($character -eq '}') {
            $depth--
            if ($depth -lt 0) { throw 'Malformed module graph' }
            if ($depth -eq 0) {
                $module = $Json.Substring($start, $i - $start + 1) | ConvertFrom-Json -ErrorAction Stop
                if (-not $module.Path -or $modules.ContainsKey($module.Path)) { throw 'Invalid module graph identity' }
                $modules[$module.Path] = $module
            }
        } elseif ($depth -eq 0 -and -not [char]::IsWhiteSpace($character)) { throw 'Malformed module graph' }
    }
    if ($depth -ne 0 -or $quoted -or $modules.Count -eq 0) { throw 'Incomplete module graph' }
    return $modules
}

function Compare-BinaryMetadata {
    param($Metadata, [string]$ProjectRoot)
    $issues = @()
    if ($Metadata.MainPath -ne 'github.com/allthingscode/gobot/cmd/gobot') { $issues += 'Main path mismatch' }
    if ($Metadata.Module -ne 'github.com/allthingscode/gobot') { $issues += 'Main module mismatch' }
    foreach ($setting in @('GOOS', 'GOARCH', 'CGO_ENABLED', 'vcs', 'vcs.revision', 'vcs.time', 'vcs.modified')) {
        if (-not $Metadata.Settings.ContainsKey($setting) -or -not $Metadata.Settings[$setting]) { $issues += "Unverifiable: missing $setting" }
    }
    if ($Metadata.Settings['GOOS'] -ne 'windows') { $issues += 'GOOS mismatch: expected windows' }
    if ($Metadata.Settings['CGO_ENABLED'] -ne '0') { $issues += 'CGO mismatch: expected 0' }
    if ($Metadata.Settings['vcs'] -ne 'git') { $issues += 'Unverifiable: VCS is not git' }
    if ($Metadata.Settings['vcs.modified'] -eq 'true') { $issues += 'Dirty build: vcs.modified=true' }
    elseif ($Metadata.Settings['vcs.modified'] -ne 'false') { $issues += 'Unverifiable: malformed vcs.modified' }
    $timestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Metadata.Settings['vcs.time'], [ref]$timestamp)) { $issues += 'Unverifiable: malformed vcs.time' }
    $head = Invoke-BinaryNative 'git' @('-C', $ProjectRoot, 'rev-parse', 'HEAD')
    $revision = ($head.Output -join '').Trim()
    if ($head.Code -ne 0 -or $revision -notmatch '^[0-9a-f]{40,64}$') { $issues += 'Unverifiable: git HEAD unavailable' }
    elseif ($Metadata.Settings['vcs.revision'] -ne $revision) { $issues += 'Revision mismatch with git HEAD' }
    $go = Invoke-BinaryNative 'go' @('env', 'GOVERSION')
    $version = ($go.Output -join '').Trim()
    if ($go.Code -ne 0 -or $version -notmatch '^go\d+\.\d+(?:\.\d+)?$') { $issues += 'Unverifiable: effective Go toolchain unavailable' }
    elseif ($Metadata.GoVersion -ne $version) { $issues += "Go toolchain mismatch: binary $($Metadata.GoVersion), checkout $version" }
    $mod = ''
    try { $mod = Get-Content -LiteralPath (Join-Path $ProjectRoot 'go.mod') -Raw -ErrorAction Stop }
    catch { $issues += 'Unverifiable: go.mod unreadable' }
    if ($mod -notmatch '(?m)^go\s+(\d+\.\d+(?:\.\d+)?)\s*$') { $issues += 'Unverifiable: go.mod minimum unavailable' }
    else {
        $minimum = $Matches[1]
        if ($Metadata.GoVersion -notmatch '^go(\d+\.\d+(?:\.\d+)?)$') { $issues += 'Unverifiable: binary Go version' }
        elseif ([version]$Matches[1] -lt [version]$minimum) { $issues += "Go version below go.mod minimum $minimum" }
    }
    $graphResult = Invoke-BinaryNative 'go' @('list', '-mod=readonly', '-m', '-json', 'all')
    try {
        if ($graphResult.Code -ne 0) { throw 'go list failed' }
        $graph = Read-BinaryModuleGraph ($graphResult.Output -join "`n")
        foreach ($embedded in @($Metadata.MainModule) + @($Metadata.Dependencies)) {
            if (-not $graph.ContainsKey($embedded.Path)) { $issues += "Dependency mismatch: $($embedded.Path) absent from graph"; continue }
            $expected = $graph[$embedded.Path]
            $replacement = $expected.PSObject.Properties['Replace']
            if ($embedded.Replace -or ($replacement -and $replacement.Value)) {
                if (-not $embedded.Replace -or -not $replacement -or -not $replacement.Value) { $issues += "Replacement mismatch: $($embedded.Path)"; continue }
                $expectedReplacement = $replacement.Value
                $expectedVersion = $expectedReplacement.PSObject.Properties['Version']
                if ($embedded.Replace.Path -ne $expectedReplacement.Path -or ($embedded.Path -ne $Metadata.Module -and $embedded.Version -ne $expected.Version)) { $issues += "Replacement mismatch: $($embedded.Path)" }
                elseif (-not $expectedVersion -or -not $expectedVersion.Value -or -not $embedded.Replace.Version -or $embedded.Replace.Version -eq '(devel)') { $issues += "Unverifiable: local replacement $($embedded.Path)" }
                elseif ($embedded.Replace.Version -ne $expectedVersion.Value) { $issues += "Replacement mismatch: $($embedded.Path)" }
            } elseif ($embedded.Path -ne $Metadata.Module -and $embedded.Version -ne $expected.Version) { $issues += "Dependency mismatch: $($embedded.Path)" }
        }
    } catch { $issues += ('Unverifiable: module graph: ' + $_.Exception.Message) }
    return $issues
}

function Invoke-SelectedBinaryCheck {
    param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot), [string]$ToolDirectory)
    $ErrorActionPreference = 'Stop'
    $oldLocation = Get-Location
    $status = 1
    $scanAttempted = $false
    try {
        $ProjectRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectRoot)
        $binary = Resolve-SelectedBinary $ProjectRoot
        Write-Host "Selected binary: $binary"
        Set-Location -LiteralPath $ProjectRoot
        Write-Host 'Metadata inspection (go version -m):'
        $result = Invoke-BinaryNative 'go' @('version', '-m', $binary)
        if ($result.Code -ne 0) { throw 'Go metadata unreadable; binary scan not performed.' }
        try { $metadata = Read-BinaryMetadata $result.Output }
        catch { throw ('Go metadata malformed; binary scan not performed: ' + $_.Exception.Message) }
        $issues = @()
        try { $issues = @(Compare-BinaryMetadata $metadata $ProjectRoot) }
        catch { $issues += ('Unverifiable checkout evidence: ' + $_.Exception.Message) }
        foreach ($issue in $issues) { Write-Host $issue }
        Write-Host 'Binary scan: retained-symbol advisories; source evidence is distinct and cannot clear binary findings.'
        $scanAttempted = $true
        $scanStatus = Invoke-SecurityCheck -ToolDirectory $ToolDirectory -BinaryPath $binary
        if ($scanStatus -ne 0) { $status = $scanStatus }
        elseif ($issues.Count -eq 0) { Write-Host 'Matching clean Windows metadata and completed clean binary scan.'; $status = 0 }
    } catch {
        Write-Host ('Preflight failed: ' + $_.Exception.Message)
        if (-not $scanAttempted) { Write-Host 'Binary scan not performed: selection or metadata inspection failed.' }
    }
    finally {
        Set-Location $oldLocation
        if ($status -ne 0) {
            Write-Host ('Rebuild: pwsh -NoProfile -File "' + (Join-Path $ProjectRoot 'scripts/build.ps1') + '"')
            Write-Host ('Recheck: pwsh -NoProfile -File "' + (Join-Path $ProjectRoot 'scripts/check_selected_binary.ps1') + '"')
            Write-Host 'Resolve checkout/toolchain mismatches before rebuilding. No Gobot process was launched.'
        }
    }
    return $status
}

if ($MyInvocation.InvocationName -ne '.') { exit (Invoke-SelectedBinaryCheck -ProjectRoot $ProjectRoot -ToolDirectory $ToolDirectory) }
