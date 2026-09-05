. (Join-Path $PSScriptRoot "platform.ps1")

# Crucible tells adopters which installed files to commit, but nothing verified
# that the adopter's own ignore rules leave those files committable. An unanchored
# root pattern such as `AGENTS.md` matches at EVERY depth, so it also swallows
# `.crucible/agent-instructions/AGENTS.md` with no warning anywhere.

# Canonical commit-by-default list, bundle-relative. Single source of truth for
# the prose in init-project.ps1, lib/instruction-blocks.ps1 and docs/git-policy.md.
function Get-CommitByDefaultPath {
    return @(
        ".gitignore",
        ".gitattributes",
        "README.md",
        "config.yaml",
        "agent-instructions",
        "docs",
        "personas",
        "sops",
        "prompts",
        "schemas",
        "powershell"
    )
}

# Expand that list into the real files present in an installed bundle. Directory
# granularity is not enough: a pattern like `AGENTS.md` matches a file and leaves
# the containing directory unremarkable, which is exactly how the failure hides.
function Get-BundleCommittablePath {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$BundleRoot
    )

    $rootFull = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $collected = New-Object System.Collections.Generic.List[string]

    foreach ($entry in Get-CommitByDefaultPath) {
        $candidate = Join-Path $BundleRoot $entry
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $candidate -Recurse -File -Force -ErrorAction SilentlyContinue) {
                $collected.Add($file.FullName) | Out-Null
            }
        } elseif (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $collected.Add((Resolve-Path -LiteralPath $candidate).Path) | Out-Null
        }
    }

    $relative = New-Object System.Collections.Generic.List[string]
    foreach ($full in $collected) {
        $rel = $full
        if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $full.Substring($rootFull.Length)
        }
        $rel = $rel.Replace("\", "/").TrimStart("/")
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        if ($rel.StartsWith(".git/")) { continue }
        $relative.Add($rel) | Out-Null
    }
    # Comma operator: PowerShell unrolls a returned List, and a bundle with exactly one
    # commit-by-default file would come back as a bare [string], whose .Count throws
    # under the Set-StrictMode -Version Latest that factory-lib.ps1 turns on. That
    # crashed the doctor before it reached any later check.
    return ,$relative.ToArray()
}

# Report every committable bundle file that an ignore rule OUTSIDE the bundle
# would exclude. Rules inside the bundle are Crucible's own policy, not violations.
#
# Returns [PSCustomObject] Status = ok | skipped | error, Violations, Checked, Reason.
function Test-GitignoreConformance {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$BundleRoot,
        [int]$BatchLimit = 12000
    )

    $result = [PSCustomObject]@{
        Status     = "ok"
        Violations = @()
        Checked    = 0
        Reason     = ""
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $result.Status = "skipped"
        $result.Reason = "git is not installed or not on PATH."
        return $result
    }
    if (-not (Test-Path -LiteralPath $BundleRoot -PathType Container)) {
        $result.Status = "skipped"
        $result.Reason = "Bundle directory not found at " + $BundleRoot + "."
        return $result
    }

    $topResult = Invoke-Git @("rev-parse", "--show-toplevel") -Directory $ProjectRoot
    $topLevel = ($topResult.Raw | Out-String).Trim()
    if ($topResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($topLevel)) {
        $result.Status = "skipped"
        $result.Reason = "Not inside a git work tree; ignore rules cannot be evaluated."
        return $result
    }

    $candidates = Get-BundleCommittablePath -ProjectRoot $ProjectRoot -BundleRoot $BundleRoot
    $result.Checked = $candidates.Count
    if ($candidates.Count -eq 0) {
        $result.Status = "skipped"
        $result.Reason = "Bundle contains no commit-by-default files to check."
        return $result
    }

    $bundleFull = (Resolve-Path -LiteralPath $BundleRoot).Path.Replace("\", "/").TrimEnd("/")
    # A plain hashtable, not HashSet[string]: PowerShell 5.1 cannot resolve the
    # HashSet comparer constructor overload, and hashtable lookup is already
    # case-insensitive, which is what a Windows path comparison needs.
    $submitted = @{}
    foreach ($candidate in $candidates) { $submitted[$candidate] = $true }

    $violations = New-Object System.Collections.Generic.List[object]
    $batches = New-Object System.Collections.Generic.List[object]
    $batch = New-Object System.Collections.Generic.List[string]
    $batchChars = 0
    foreach ($candidate in $candidates) {
        $batch.Add($candidate) | Out-Null
        $batchChars += ($candidate.Length + 3)
        if ($batchChars -ge $BatchLimit) {
            $batches.Add($batch.ToArray()) | Out-Null
            $batch.Clear()
            $batchChars = 0
        }
    }
    if ($batch.Count -gt 0) { $batches.Add($batch.ToArray()) | Out-Null }

    foreach ($chunk in $batches) {
        # argv rather than --stdin: `-z` is rejected without --stdin, and Windows
        # PowerShell prepends a BOM to a piped stdin payload, corrupting the first
        # path. Batching keeps the command line clear of the OS length limit.
        #
        # --no-index is load-bearing. Without it check-ignore exempts already-tracked
        # files and returns a silent, falsely clean exit 1.
        $gitArgs = @("check-ignore", "-v", "--no-index", "--") + $chunk
        $ignoreResult = Invoke-Git $gitArgs -Directory $ProjectRoot

        # 0 = at least one match, 1 = no matches. Anything else is a real failure.
        if ($ignoreResult.ExitCode -gt 1) {
            $result.Status = "error"
            $result.Reason = "git check-ignore failed with exit code " + $ignoreResult.ExitCode + "."
            return $result
        }

        foreach ($line in @($ignoreResult.Lines)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            # source:line:pattern<TAB>path. The source may be an absolute path
            # carrying a drive-letter colon, so bind on the last ':<digits>:'.
            $match = [regex]::Match($line, '^(?<source>.*):(?<line>\d+):(?<pattern>.*)\t(?<path>.*)$')
            if (-not $match.Success) {
                $result.Status = "error"
                $result.Reason = "Could not parse git check-ignore output: " + $line
                return $result
            }

            $path = $match.Groups["path"].Value
            if (-not $submitted.ContainsKey($path)) {
                $result.Status = "error"
                $result.Reason = "git check-ignore reported a path that was never submitted: " + $path
                return $result
            }

            # A printed negation is the winning rule and means the path is NOT
            # ignored. Counting these as hits would fire on the very workaround
            # adopters add to undo an over-broad pattern.
            $pattern = $match.Groups["pattern"].Value
            if ($pattern.StartsWith("!")) { continue }

            # The source is relative to the git top-level while the path is relative
            # to ProjectRoot: two different bases on the same output line.
            $source = $match.Groups["source"].Value
            $sourceFull = $source
            if (-not [System.IO.Path]::IsPathRooted($sourceFull)) {
                $sourceFull = Join-Path $topLevel $source
            }
            $sourceFull = $sourceFull.Replace("\", "/")
            if ($sourceFull.StartsWith(($bundleFull + "/"), [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $violations.Add([PSCustomObject]@{
                Path    = $path
                Source  = $source
                Line    = [int]$match.Groups["line"].Value
                Pattern = $pattern
            }) | Out-Null
        }
    }

    # .ToArray(), not @($violations): in Windows PowerShell 5.1 the array subexpression
    # throws "Argument types do not match" on any List[object], even an empty one.
    # List[string] is unaffected, so the quirk is easy to miss.
    $result.Violations = $violations.ToArray()
    return $result
}

# One-line-per-violation summary, capped so a repo that ignores the whole bundle
# does not print hundreds of lines into a doctor report.
function Format-GitignoreConformanceDetail {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Violations,
        [int]$MaxShown = 5
    )

    $shown = @($Violations | Select-Object -First $MaxShown)
    $parts = @()
    foreach ($violation in $shown) {
        $parts += ($violation.Source + ":" + $violation.Line + ":" + $violation.Pattern + " -> " + $violation.Path)
    }
    if ($Violations.Count -gt $shown.Count) {
        $parts += ("... and " + ($Violations.Count - $shown.Count) + " more")
    }
    return ($parts -join "; ")
}
