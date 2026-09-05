. (Join-Path $PSScriptRoot "platform.ps1")

# init-project.ps1 installs .crucible/.gitattributes, but nearest-.gitattributes-wins
# means it governs only the bundle subtree. The adopter's own tree is left to whatever
# core.autocrlf happened to be on the machine that first staged each file, and a CRLF
# Makefile or shell script fails outright on a Linux runner. Crucible is the only party
# already inspecting the adopter's git state on a schedule, so it is the only party
# positioned to notice.

# Report every tracked blob outside the bundle whose INDEX line endings are CRLF or
# mixed. The verdict is a property of the repository, not of the machine running the
# check: core.autocrlf=true yields `i/lf w/crlf` for a CRLF working file, so two
# differently-configured developers get the same answer.
#
# Returns [PSCustomObject] Status = ok | skipped | error, Violations, Checked, Reason.
function Test-LineEndingConformance {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$BundleRoot
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

    $topResult = Invoke-Git @("rev-parse", "--show-toplevel") -Directory $ProjectRoot
    $topLevel = ($topResult.Raw | Out-String).Trim()
    if ($topResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($topLevel)) {
        $result.Status = "skipped"
        $result.Reason = "Not inside a git work tree; index line endings cannot be read."
        return $result
    }

    $eolResult = Invoke-Git @("ls-files", "--eol") -Directory $ProjectRoot
    if ($eolResult.ExitCode -ne 0) {
        $result.Status = "error"
        $result.Reason = "git ls-files --eol failed with exit code " + $eolResult.ExitCode + "."
        return $result
    }

    # Bundle-relative prefix to exclude. A CRLF blob inside the bundle still reports
    # i/crlf, so the eol field does not exclude it for us - only this path filter does.
    # A finding there is a broken bundle, a different defect, and would only add noise.
    $bundlePrefix = ""
    if (Test-Path -LiteralPath $BundleRoot -PathType Container) {
        $rootFull = (Resolve-Path -LiteralPath $ProjectRoot).Path.Replace("\", "/").TrimEnd("/")
        $bundleFull = (Resolve-Path -LiteralPath $BundleRoot).Path.Replace("\", "/").TrimEnd("/")
        if ($bundleFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            $bundlePrefix = $bundleFull.Substring($rootFull.Length).TrimStart("/") + "/"
        }
    }

    $violations = New-Object System.Collections.Generic.List[object]
    $checked = 0

    foreach ($line in @($eolResult.Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # i/<eol>  w/<eol>  attr/<attrs><TAB><path>. The attr column CONTAINS SPACES
        # ("attr/text eol=crlf"), so the path binds on the tab and not on whitespace.
        # The eol token can be `-text` for binaries, so \S+ and not \w+.
        $match = [regex]::Match($line, '^i/(?<index>\S+)\s+w/(?<worktree>\S+)\s+attr/(?<attr>.*)\t(?<path>.*)$')
        if (-not $match.Success) {
            $result.Status = "error"
            $result.Reason = "Could not parse git ls-files --eol output: " + $line
            return $result
        }

        $path = $match.Groups["path"].Value
        if ($bundlePrefix -ne "" -and $path.StartsWith($bundlePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $checked++

        # The whole rule is this one field. A file with a declared eol=crlf attribute
        # is `i/lf w/crlf` - deliberate CRLF is LF in the index by definition - so it
        # can never match, which is why no attr parsing and no .bat/.cmd allowlist are
        # needed. Binaries are i/-text and fall out free. i/mixed is included on
        # purpose: inconsistent endings are strictly worse than consistent CRLF.
        $indexEol = $match.Groups["index"].Value
        if ($indexEol -eq "crlf" -or $indexEol -eq "mixed") {
            $violations.Add([PSCustomObject]@{
                Path     = $path
                IndexEol = $indexEol
            }) | Out-Null
        }
    }

    $result.Checked = $checked
    if ($checked -eq 0) {
        $result.Status = "skipped"
        $result.Reason = "No tracked files outside the bundle to check."
        return $result
    }

    # .ToArray(), not @($violations): in Windows PowerShell 5.1 the array subexpression
    # throws "Argument types do not match" on any List[object], even an empty one.
    $result.Violations = $violations.ToArray()
    return $result
}

# One-line summary, capped so a repo that stored its whole history as CRLF does not
# print hundreds of lines into a doctor report.
function Format-LineEndingConformanceDetail {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Violations,
        [int]$MaxShown = 5
    )

    $shown = @($Violations | Select-Object -First $MaxShown)
    $parts = @()
    foreach ($violation in $shown) {
        $parts += ($violation.Path + " (" + $violation.IndexEol + ")")
    }
    if ($Violations.Count -gt $shown.Count) {
        $parts += ("... and " + ($Violations.Count - $shown.Count) + " more")
    }
    return ($parts -join "; ")
}
