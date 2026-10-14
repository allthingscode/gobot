Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Get-BacklogItemPathForTaskProjectRoot below needs Get-ConfiguredPath. crucible-lib.ps1
# loads config-helpers.ps1 first, so this normally does nothing; it exists so a caller
# that dot-sources this file on its own gets a working function rather than a missing one.
if (-not (Get-Command Get-ConfiguredPath -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "config-helpers.ps1")
}

if (-not (Test-Path variable:script:HeldBacklogLocks)) {
    $script:HeldBacklogLocks = @{}
}

function Get-BacklogLockFilePath {
    param([Parameter(Mandatory=$true)][string]$BacklogPath)

    $resolved = $BacklogPath
    if (Test-Path -LiteralPath $BacklogPath) {
        $resolved = (Resolve-Path -LiteralPath $BacklogPath).ProviderPath
    } else {
        $parent = Split-Path -Parent $BacklogPath
        if ($parent -and (Test-Path -LiteralPath $parent)) {
            $resolved = Join-Path (Resolve-Path -LiteralPath $parent).ProviderPath (Split-Path -Leaf $BacklogPath)
        }
    }
    return "$resolved.lock"
}

function Invoke-WithBacklogLock {
    param(
        [Parameter(Mandatory=$true)][string]$BacklogPath,
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 10,
        [int]$StaleLockAgeSeconds = 30
    )

    if ([string]::IsNullOrWhiteSpace($BacklogPath)) {
        throw "BacklogPath parameter cannot be empty."
    }

    $lockPath = Get-BacklogLockFilePath -BacklogPath $BacklogPath
    $normLockPath = $lockPath.ToLowerInvariant()

    # Process-local re-entrancy check
    if ($script:HeldBacklogLocks.ContainsKey($normLockPath) -and $script:HeldBacklogLocks[$normLockPath] -gt 0) {
        $script:HeldBacklogLocks[$normLockPath] = $script:HeldBacklogLocks[$normLockPath] + 1
        try {
            return & $ScriptBlock
        } finally {
            $script:HeldBacklogLocks[$normLockPath] = $script:HeldBacklogLocks[$normLockPath] - 1
            if ($script:HeldBacklogLocks[$normLockPath] -eq 0) {
                $script:HeldBacklogLocks.Remove($normLockPath)
            }
        }
    }

    $startTime = [System.DateTime]::UtcNow
    $acquired = $false

    while (([System.DateTime]::UtcNow - $startTime).TotalSeconds -lt $TimeoutSeconds) {
        try {
            # Try atomic file creation with FileAccess ReadWrite, FileShare None
            $fs = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $info = "$PID;$(Get-Date -Format 'o')"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($info)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Close()
            $fs.Dispose()
            $acquired = $true
            break
        } catch [System.IO.IOException] {
            # Lock file exists or is opened exclusively by another process. Check if stale.
            if (Test-Path -LiteralPath $lockPath) {
                $isStale = $false
                try {
                    $item = Get-Item -LiteralPath $lockPath -ErrorAction SilentlyContinue
                    if ($null -ne $item) {
                        $age = ([System.DateTime]::UtcNow - $item.LastWriteTimeUtc).TotalSeconds
                        if ($age -ge $StaleLockAgeSeconds) {
                            $isStale = $true
                        } else {
                            $content = [System.IO.File]::ReadAllText($lockPath)
                            if (-not [string]::IsNullOrWhiteSpace($content)) {
                                $parts = $content.Split(";")
                                $lockPid = 0
                                if ([int]::TryParse($parts[0], [ref]$lockPid)) {
                                    $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                                    if ($null -eq $proc) {
                                        $isStale = $true
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    # Ignore read failures if locked during active write
                }

                if ($isStale) {
                    try {
                        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
                    } catch {}
                    continue
                }
            }
            Start-Sleep -Milliseconds 100
        }
    }

    if (-not $acquired) {
        throw "Timed out waiting to acquire BACKLOG.md lock at $lockPath (timeout ${TimeoutSeconds}s)"
    }

    $script:HeldBacklogLocks[$normLockPath] = 1

    try {
        return & $ScriptBlock
    } finally {
        $script:HeldBacklogLocks.Remove($normLockPath)
        if (Test-Path -LiteralPath $lockPath) {
            try {
                Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
            } catch {}
        }
    }
}

# TODO item 190: keep both legal spec filename forms in one place; callers choose
# directory order and whether archived subdirectories belong in their search.
function Get-BacklogSpecFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][string]$Directory,
        [switch]$Recurse
    )

    foreach ($pattern in @(($Task + "_*.md"), ($Task + ".md"))) {
        Get-ChildItem -LiteralPath $Directory -File -Filter $pattern -Recurse:$Recurse -ErrorAction SilentlyContinue
    }
}

# Resolve a spec from a task id, preferring active over loose over archived.
# Keep this shared lookup independent of gate orchestration. Item 14.
function Get-BacklogItemPathForTaskProjectRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [string]$ProjectRoot = ""
    )

    $typeDir = if ($Task -match "^F-") {
        "features"
    } elseif ($Task -match "^B-") {
        "bugs"
    } elseif ($Task -match "^C-") {
        "chores"
    } else {
        ""
    }

    $typeDirs = if ([string]::IsNullOrWhiteSpace($typeDir)) {
        @("features", "bugs", "chores")
    } else {
        @($typeDir)
    }

    $backlogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $ProjectRoot
    foreach ($dir in $typeDirs) {
        foreach ($sub in @(($dir + "/active"), $dir, ($dir + "/archived"))) {
            $searchPath = Join-Path $backlogDir $sub
            $recurse = $sub.EndsWith("/archived")
            $match = Get-BacklogSpecFiles -Task $Task -Directory $searchPath -Recurse:$recurse | Select-Object -First 1
            if ($null -ne $match) {
                return $match.FullName
            }
        }
    }

    return ""
}

function Get-BacklogSpecStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [string]$ProjectRoot = ""
    )

    # The spec's frontmatter is the artifact; BACKLOG.md is an index rendered from it.
    # Returns $null when no spec exists at all, which is what lets a caller tell
    # "no such task" apart from "task exists and its status is blank".
    $specPath = Get-BacklogItemPathForTaskProjectRoot -Task $Task -ProjectRoot $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($specPath) -or -not (Test-Path -LiteralPath $specPath)) {
        return $null
    }

    foreach ($line in (Get-Content -LiteralPath $specPath -Head 30 -Encoding UTF8)) {
        if ($line -match '^\s*status:\s*"?([^"#]+?)"?\s*$') {
            return $matches[1].Trim()
        }
    }

    return ""
}

function Get-BacklogTaskStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Task,
        [string]$ProjectRoot = "",
        [string]$BacklogDir = ""
    )

    # Shared status resolver for dependency checks and concurrent-Groomer exclusions.
    # Spec first, index second: archived specs can exist without a BACKLOG.md row. Item 54.
    $specStatus = Get-BacklogSpecStatus -Task $Task -ProjectRoot $ProjectRoot
    if ($null -ne $specStatus) {
        return @{ Found = $true; Status = $specStatus; Source = "its spec file"; Searched = @("its spec file") }
    }

    if ([string]::IsNullOrWhiteSpace($BacklogDir)) {
        $BacklogDir = Get-ConfiguredPath -Key "backlog" -ProjectRoot $ProjectRoot
    }

    $searched = @("its spec file")
    foreach ($name in @("BACKLOG.md", "ARCHIVED.md")) {
        $indexPath = Join-Path $BacklogDir $name
        if (-not (Test-Path $indexPath)) { continue }
        $searched += $name

        $statusColumnIndex = -1
        $escaped = [regex]::Escape($Task)
        foreach ($line in (Get-Content -Path $indexPath -Encoding UTF8)) {
            if ($line -match '^\|\s*ID\s*\|') {
                $headerCols = ($line -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne "" }
                $statusColumnIndex = [Array]::IndexOf($headerCols, "Status")
                continue
            }
            if ($line -match '^\|\s*[-: ]+\|') { continue }

            if ($line -match "^\|\s*(:?\[$escaped\]\([^)]+\)|$escaped)\s*\|") {
                $rowCols = ($line -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne "" }
                $status = if ($statusColumnIndex -ge 0 -and $statusColumnIndex -lt $rowCols.Count) {
                    $rowCols[$statusColumnIndex]
                } elseif ($rowCols.Count -gt 0) {
                    $rowCols[$rowCols.Count - 1]
                } else {
                    ""
                }
                return @{ Found = $true; Status = $status; Source = $name; Searched = $searched }
            }
        }
    }

    return @{ Found = $false; Status = ""; Source = ""; Searched = $searched }
}

function Test-BacklogTaskTerminal {
    param($Status)

    if ($null -eq $Status) { return $false }
    $normalized = ([string]$Status).Trim().ToLowerInvariant()
    return ($normalized -eq "production" -or $normalized -eq "resolved")
}
