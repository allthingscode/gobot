# --- config.yaml reader -------------------------------------------------------
# One parser backs every accessor. Distinguish missing keys from unreadable keys
# so malformed config cannot silently disable a gate through a default. Item 34.
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

    $lineIndex = -1
    foreach ($line in ($text -split '\r?\n')) {
        $lineIndex++
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
            LineIndex = $lineIndex
            Indent = $indent
            Key    = $key
            Value  = $value
            Text   = $line.Trim()
        }
    }

    return $entries
}

# One owner for config scalar decoding. Double-quoted YAML escapes written by init
# decode once here; comments and hashes inside quoted values stay intact.
function ConvertFrom-ConfigScalar {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Raw)

    $text = $Raw.Trim()
    if ($text -match '^"((?:[^"\\]|\\[\\"])*)"') {
        return [regex]::Replace($Matches[1], '\\([\\"])', { param($m) $m.Groups[1].Value })
    }
    # Older configs used verbatim Windows paths. Decode only when the entire
    # quoted value uses supported escapes; otherwise preserve every backslash.
    if ($text -match '^"(.*)"(?:[ \t]*#.*)?$') { return $Matches[1] }
    if ($text -match "^'([^']*)'") { return $Matches[1] }
    if ($text -match '^(.*?)[ \t]+#') { $text = $Matches[1] }
    return $text.Trim()
}

function ConvertTo-ConfigScalar {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

# A requested key present without a 'key: value' pair is malformed, not absent. Item 34.
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

# --- verification checks block -------------------------------------------------
# The one reader of verification.quick, verification.full and verification.config_check.
# It was the runner's own loop until item 245; validate-config.ps1 and crucible-doctor.ps1
# each read the block with their own regexes and disagreed with it (item 241).

function Read-VerificationInlineScalar {
    param([string]$Value)
    $Value = $Value.Trim()
    if ($Value.Length -ge 2 -and ($Value[0] -eq '"' -or $Value[0] -eq "'") -and $Value[0] -eq $Value[$Value.Length - 1]) {
        $inner = $Value.Substring(1, $Value.Length - 2)
        # `"a.exe" "b"` starts and ends with a quote but is not one quoted scalar.
        if ($Value[0] -eq '"' -and $Value -match '^"(?:[^"\\]|\\.)*"$') { return ConvertFrom-ConfigScalar $Value }
        if (-not $inner.Contains([string]$Value[0])) { return ConvertFrom-ConfigScalar $Value }
    }
    return $Value
}

# Read a YAML block scalar (| literal or > folded) whose header line is at index
# $HeaderIndex. Adopters commonly write a multi-statement verification command as a
# folded scalar (`command: >-`) for readability; the inline regex only captured the
# `>-` indicator, so Invoke-Expression later choked on a bare `>`. Returns the joined
# body plus NextIndex (first line NOT consumed). Folded joins content lines with
# spaces (blank line -> newline); literal joins with newlines. Chomping indicators
# are accepted; the trailing newline is irrelevant to Invoke-Expression.
function Read-VerificationBlockScalar {
    param(
        [string[]]$Lines,
        [int]$HeaderIndex,
        [string]$Indicator,
        [int]$KeyIndent
    )
    $folded = $Indicator.StartsWith(">")
    $bodyLines = New-Object System.Collections.Generic.List[string]
    $blockIndent = -1
    $i = $HeaderIndex + 1
    while ($i -lt $Lines.Count) {
        $line = $Lines[$i]
        if ($line -match "^\s*$") {
            $bodyLines.Add("")
            $i++
            continue
        }
        $indent = ($line -replace "^(\s*).*$", '$1').Length
        if ($indent -le $KeyIndent) { break }
        if ($blockIndent -lt 0) { $blockIndent = $indent }
        if ($line.Length -ge $blockIndent) {
            $bodyLines.Add($line.Substring($blockIndent))
        } else {
            $bodyLines.Add($line.TrimStart())
        }
        $i++
    }
    while ($bodyLines.Count -gt 0 -and $bodyLines[$bodyLines.Count - 1] -eq "") {
        $bodyLines.RemoveAt($bodyLines.Count - 1)
    }
    if ($folded) {
        $value = ""
        foreach ($b in $bodyLines) {
            if ($b -eq "") { $value += "`n" }
            elseif ($value -eq "" -or $value.EndsWith("`n")) { $value += $b }
            else { $value += " " + $b }
        }
    } else {
        $value = ($bodyLines -join "`n")
    }
    return @{ Value = $value; NextIndex = $i }
}

function Read-VerificationEntryValue {
    param([object]$Entry, [string[]]$Lines)
    $raw = $Entry.Value.Trim()
    if ($raw -match "^[|>][+-]?\d*$") {
        return (Read-VerificationBlockScalar -Lines $Lines -HeaderIndex $Entry.LineIndex -Indicator $raw -KeyIndent $Entry.Indent).Value
    }
    return Read-VerificationInlineScalar $raw
}

# Returns one record per check in the mode: Name, Command, HostGate, AlternativeRunner.
# Full mode appends config_check last. HostGate and AlternativeRunner are $null when the
# key is absent and "" when it is written empty, so the validator can refuse the second.
function Get-VerificationChecks {
    param(
        [AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][ValidateSet("quick", "full")][string]$Mode
    )

    $lines = @(([string]$Content) -split '\r?\n')
    $entries = @(Get-ConfigEntries -Content ([string]$Content))
    $commands = @()
    $node = Find-ConfigNode -Entries $entries -Path @("verification", $Mode) -Source "config.yaml"
    if ($null -ne $node -and $node.SpanStart -lt $node.SpanEnd) {
        $listIndent = $entries[$node.SpanStart].Indent
        for ($i = $node.SpanStart; $i -lt $node.SpanEnd; $i++) {
            $entry = $entries[$i]
            if ($entry.Indent -ne $listIndent -or $entry.Text -notmatch '^-\s*name:\s*(.+)$') { continue }
            $check = @{ Name = Read-VerificationInlineScalar $Matches[1]; Command = $null; HostGate = $null; AlternativeRunner = $null }
            $end = $i + 1
            while ($end -lt $node.SpanEnd -and $entries[$end].Indent -gt $listIndent) { $end++ }
            if ($i + 1 -lt $end) {
                $fieldIndent = $entries[$i + 1].Indent
                for ($j = $i + 1; $j -lt $end; $j++) {
                    $field = $entries[$j]
                    if ($field.Indent -ne $fieldIndent) { continue }
                    switch ($field.Key) {
                        "command" { $check.Command = Read-VerificationEntryValue -Entry $field -Lines $lines }
                        "host_gate" { $check.HostGate = Read-VerificationInlineScalar $field.Value }
                        "alternative_runner" { $check.AlternativeRunner = Read-VerificationInlineScalar $field.Value }
                    }
                }
            }
            if ($null -ne $check.Command) { $commands += $check }
            $i = $end - 1
        }
    }
    if ($Mode -eq "full") {
        $nameNode = Find-ConfigNode -Entries $entries -Path @("verification", "config_check", "name") -Source "config.yaml"
        $commandNode = Find-ConfigNode -Entries $entries -Path @("verification", "config_check", "command") -Source "config.yaml"
        if ($null -ne $nameNode -and $null -ne $commandNode) {
            $name = Read-VerificationInlineScalar $entries[$nameNode.Index].Value
            $command = Read-VerificationEntryValue -Entry $entries[$commandNode.Index] -Lines $lines
            if ($name -and $command) { $commands += @{ Name = $name; Command = $command; HostGate = $null; AlternativeRunner = $null } }
        }
    }

    return $commands
}

function Get-VerificationCheckIdentityErrors {
    param([AllowEmptyString()][string]$Content)

    # Names own persistent not-run records across modes. Reserve built-ins even when
    # they do not run on this host or in this mode, and validate the whole config.
    $owners = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $owners.Add("Encoding guard (BOM/mojibake)", "built-in check-mojibake.ps1")
    $owners.Add("Encoding guard (whitespace)", "built-in git diff --check")
    $owners.Add("Project pre-push hook", "built-in project pre-push hook")
    $owners.Add("verification.quick checks", "built-in verification.quick availability check")
    $owners.Add("verification.full checks", "built-in verification.full availability check")
    foreach ($mode in @("quick", "full")) {
        foreach ($check in @(Get-VerificationChecks -Content $Content -Mode $mode)) {
            $name = ([string]$check.Name -replace '[\r\n]+', ' ').Trim()
            $command = "verification.${mode}: " + $check.Command
            if ($owners.ContainsKey($name)) {
                "Duplicate verification check name '$name': '$($owners[$name])' conflicts with '$command'. Check names must be unique across modes and built-in checks."
            } else {
                $owners.Add($name, $command)
            }
        }
    }
}

# --- config source for the checks --------------------------------------------
# The checks runner reads the main checkout's config.yaml, which a gated specialist can
# edit without committing, and the integrity breaker skips it as adopter-owned. The runner
# refuses anything but the committed file rather than reading HEAD: reading HEAD would run
# checks that validate-config.ps1, the doctor and the human never see in the file. Item 254.
#
# - Every git call runs from ProjectRoot and compares with the project's HEAD, so a nested
#   repository or submodule inside .crucible cannot vouch for a config it committed itself;
#   one that owns the file is refused by name.
# - The file is read once. Those bytes are hashed through git's filters (hash-object
#   --stdin --path) and returned as Content, so the runner derives every setting from the
#   bytes that were verified, not from a later read a running check could change.
#   Comparing the hash rather than porcelain status also catches an edit that
#   skip-worktree or assume-unchanged hides.
# - A symlinked config, on disk or in HEAD, is refused: the checks would come from
#   wherever the link points, and HEAD records the link text, not the checks.
function Get-ConfigCommitState {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$ConfigPath = ""
    )

    $root = Resolve-FilesystemPath -Path $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $root ".crucible/config.yaml" }
    $newState = {
        param([string]$Status, [string]$Detail, [string]$Remedy, $Content = $null)
        [pscustomobject]@{ Status = $Status; ConfigPath = $ConfigPath; Detail = $Detail; Remedy = $Remedy; Message = ($Detail + " Remedy: " + $Remedy); Content = $Content }
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return & $newState "missing" ("Configuration file not found: " + $ConfigPath + ".") "Create it with init-project.ps1 and commit it."
    }
    $fullConfig = Resolve-FilesystemPath -Path $ConfigPath
    $rel = Get-PathRelativeToDirectory -Path $fullConfig -Directory $root -Separator "/"
    if ([string]::IsNullOrEmpty($rel)) {
        return & $newState "unverifiable" ($ConfigPath + " is not inside the project root " + $root + ", so the project's HEAD cannot vouch for it.") "Keep the config at .crucible/config.yaml inside the project."
    }
    if (-not [string]::IsNullOrEmpty([string](Get-Item -LiteralPath $fullConfig -Force).LinkType)) {
        return & $newState "symlink" ($ConfigPath + " is a symbolic link, so the checks would come from wherever it points.") ("Replace it with a regular file holding the config and commit it: git add " + $rel + "; git commit.")
    }
    if ($null -eq (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        return & $newState "not-git" ($ConfigPath + " cannot be compared with a commit because git is not on PATH, so nothing shows the checks it names are the committed ones.") "Install git and commit the file."
    }
    $git = {
        param([string]$Directory, [string[]]$GitArgs)
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $out = @(& git -C (Resolve-FilesystemPath -Path $Directory) @GitArgs 2>$null)
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (($out | ForEach-Object { [string]$_ }) -join "`n").Trim() }
        } finally { $ErrorActionPreference = $prevEAP }
    }

    $inside = & $git $root @("rev-parse", "--is-inside-work-tree")
    if ($inside.ExitCode -ne 0 -or $inside.Text -ne "true") {
        return & $newState "not-git" ($ConfigPath + " is not inside a git work tree (git rev-parse --is-inside-work-tree exited " + $inside.ExitCode + "), so no commit records the checks it names.") "Put the project under git and commit the file."
    }
    $projectTop = & $git $root @("rev-parse", "--show-toplevel")
    $configTop = & $git (Split-Path -Parent $fullConfig) @("rev-parse", "--show-toplevel")
    $topComparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if ($projectTop.ExitCode -ne 0 -or $configTop.ExitCode -ne 0 -or -not $projectTop.Text.Equals($configTop.Text, $topComparison)) {
        return & $newState "nested-repo" ($ConfigPath + " belongs to the git repository at " + $configTop.Text + ", not the project's at " + $projectTop.Text + ", so a commit there does not show the project committed the checks.") "Remove the nested repository or submodule from the config's directory and commit the file in the project."
    }

    $entry = & $git $root @("ls-tree", "HEAD", "--", $rel)
    if ($entry.ExitCode -eq 0 -and $entry.Text -match '^(\d{6}) (\w+) ([0-9a-f]+)\t') {
        $headMode = $Matches[1]; $headType = $Matches[2]; $headBlob = $Matches[3]
    } else {
        $headMode = ""; $headType = ""; $headBlob = ""
    }
    if ($headMode -eq "120000") {
        return & $newState "symlink" ($ConfigPath + " is committed as a symbolic link, so HEAD records the link text, not the checks.") ("Commit a regular file in its place: git add " + $rel + "; git commit.")
    }
    if ($headType -eq "commit") {
        return & $newState "nested-repo" ($ConfigPath + " sits in a submodule of the project, so the project's HEAD records a commit id, not the checks.") "Commit the config as a regular file in the project."
    }
    if ([string]::IsNullOrEmpty($headBlob) -or $headType -ne "blob") {
        $ignored = & $git $root @("check-ignore", "-q", "--", $rel)
        if ($ignored.ExitCode -eq 0) {
            return & $newState "ignored" ($ConfigPath + " is ignored by git and not committed at HEAD, so nothing records the checks it names.") ("Remove the ignore rule ('git check-ignore -v " + $rel + "' names it), then commit the file. docs/git-policy.md lists it under Commit By Default.")
        }
        return & $newState "uncommitted" ($ConfigPath + " is not committed at HEAD, so nothing records the checks it names.") ("Commit it: git add " + $rel + "; git commit.")
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($fullConfig)
    } catch {
        return & $newState "unreadable" ($ConfigPath + " could not be read (" + $_.Exception.Message + "), so the checks it names cannot be verified.") "Restore read access to the file, or restore it from HEAD, then rerun."
    }
    $diskBlob = ""
    $hashExit = -1
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new("git")
        foreach ($arg in @("-C", $root, "hash-object", "--stdin", ("--path=" + $rel))) { $psi.ArgumentList.Add($arg) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        try {
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $proc.StandardInput.Close()
            $diskBlob = $proc.StandardOutput.ReadToEnd().Trim()
            $proc.WaitForExit()
            $null = $stderrTask.Result
            $hashExit = $proc.ExitCode
        } finally { $proc.Dispose() }
    } catch {
        $diskBlob = ""
    }
    if ($hashExit -ne 0 -or [string]::IsNullOrWhiteSpace($diskBlob)) {
        return & $newState "unverifiable" ($ConfigPath + " could not be compared with HEAD (git hash-object exited " + $hashExit + ").") "Check that the file is readable and git works in this repository."
    }
    if ($diskBlob -ne $headBlob) {
        return & $newState "modified" ($ConfigPath + " has uncommitted changes, so the checks it names are not the committed ones.") ("Commit the change (git add " + $rel + "; git commit) or revert it to HEAD.")
    }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return & $newState "committed" ($ConfigPath + " matches HEAD.") "" $text
}

function Resolve-ConfigProjectRoot {
    param(
        [string]$ProjectRoot = "",
        [ValidateSet("Existing", "Always", "None")]
        [string]$PathResolution = "Existing"
    )

    $root = $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        # Dynamic scope lookup also works when REPO_ROOT is unset under strict mode.
        $repoRootVar = Get-Variable -Name "REPO_ROOT" -ErrorAction SilentlyContinue
        $root = if ($null -ne $repoRootVar) { $repoRootVar.Value } else { (Get-Location).Path }
    }

    if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }
    if ($PathResolution -eq "Existing" -and $root -and (Test-Path -LiteralPath $root)) {
        $root = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $root))
    }
    if ($PathResolution -eq "Always") { $root = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $root)) }
    return $root
}

function Get-ConfiguredPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("backlog", "session", "workspaces", "prompts", "personas", "sops")]
        [string]$Key,
        [string]$ProjectRoot = "",
        # Config text already read and verified (Get-ConfigCommitState). Supplied, the file
        # is not reopened. Item 254.
        [AllowEmptyString()][string]$Content
    )

    $root = Resolve-ConfigProjectRoot -ProjectRoot $ProjectRoot
    $configPath = Join-Path $root ".crucible/config.yaml"
    $haveContent = $PSBoundParameters.ContainsKey("Content")

    # Defaults
    $defaults = @{
        backlog    = ".crucible/backlog"
        session    = ".crucible/session"
        workspaces = ".crucible/.agent-workspaces"
        prompts    = ".crucible/prompts"
        personas   = ".crucible/personas"
        sops       = ".crucible/sops"
    }

    if (-not $haveContent -and -not (Test-Path -LiteralPath $configPath)) {
        return (Resolve-PathFromRoot -Root $root -Path $defaults[$Key])
    }

    $content = if ($haveContent) { $Content } else { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 }
    $val = Get-ConfigBlockValue -Content $content -Path @("paths", $Key) -Source $configPath
    if ($null -ne $val) {
        return (Resolve-PathFromRoot -Root $root -Path $val)
    }

    return (Resolve-PathFromRoot -Root $root -Path $defaults[$Key])
}

# The owner of crucible_root (I13): its value as configured, ".crucible" when the config
# does not set it, and $null when the project has no config, so a caller can tell an
# installed project from a guess. NoDefault exposes an absent key to diagnostics. Item 247.
function Get-ConfiguredCrucibleRootValue {
    param([string]$ProjectRoot = "", [switch]$NoDefault)

    $root = Resolve-ConfigProjectRoot -ProjectRoot $ProjectRoot
    $configPath = Join-Path $root ".crucible/config.yaml"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $null }
    $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $value = Get-ConfigBlockValue -Content $content -Path @("crucible_root") -Source $configPath
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($NoDefault) { return $null }
        return ".crucible"
    }
    return $value.Trim()
}

# The project's installed bundle as a path: crucible_root under the project root, or $null
# when the project has no config. Printed commands name this bundle, not the one whose
# library happens to be loaded, so a framework checkout run against an adopter still prints
# the adopter's paths. Item 247.
function Get-ConfiguredCrucibleRoot {
    param([string]$ProjectRoot = "")

    $value = Get-ConfiguredCrucibleRootValue -ProjectRoot $ProjectRoot
    if ($null -eq $value) { return $null }
    return (Resolve-CrucibleBundleRoot -ProjectRoot (Resolve-ConfigProjectRoot -ProjectRoot $ProjectRoot) -CrucibleRoot $value)
}

# Item 304: one owner for rooted-as-is versus relative-under-root composition.
# Do not canonicalize, trim, change separators or require existence. Keep Join-Path's
# binding for relative values (including empty/null); callers own their validation.
function Resolve-PathFromRoot {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()]$Root,
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    if ($Path -match '^([^\\/:]+):') {
        try {
            $pathDrive = $ExecutionContext.SessionState.Drive.Get($Matches[1])
            if ($pathDrive.Provider.Name -eq 'FileSystem') { return $Path }
        } catch [System.Management.Automation.DriveNotFoundException] { }
    }
    return (Join-Path $Root $Path)
}

# Rooted Windows paths can still depend on the current PowerShell filesystem drive.
# GetFullPath would instead choose the process drive; missing paths need no existence probe.
function Resolve-FilesystemPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathFullyQualified($Path)) {
        $mappedDrive = $null
        if ($Path -match '^([A-Za-z]):') {
            try { $mappedDrive = $ExecutionContext.SessionState.Drive.Get($Matches[1]) }
            catch [System.Management.Automation.DriveNotFoundException] { }
        }
        # A PowerShell-only drive can look native to .NET without naming that disk.
        if ($null -eq $mappedDrive -or ($mappedDrive.Provider.Name -eq 'FileSystem' -and
                $mappedDrive.Root -eq ($mappedDrive.Name + ':\'))) { return $Path }
    }
    $provider = $null
    $drive = $null
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw "Cannot qualify a filesystem path from provider '$($provider.Name)'." }
    return $fullPath
}

# The one resolver of a bundle root (I13, item 301): an absolute crucible_root is used as is,
# a relative one is joined to the project root. config.yaml must hold a relative value
# (validate-config.ps1), but -CrucibleRoot and Context.CrucibleRoot may carry an absolute one,
# and a project root joined in front of it names a directory that does not exist, which
# made the research scan skip every artifact (items 280, 300). An empty input refuses.
function Resolve-CrucibleBundleRoot {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$CrucibleRoot
    )

    if ([string]::IsNullOrWhiteSpace($CrucibleRoot)) {
        throw "Cannot resolve the Crucible bundle: the crucible_root value is empty."
    }
    # Preserve this specialization's empty-root diagnostic, including whitespace roots.
    $resolutionRoot = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { "" } else { $ProjectRoot }
    try {
        return (Resolve-PathFromRoot -Root $resolutionRoot -Path $CrucibleRoot)
    } catch {
        if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
            throw ("Cannot resolve the Crucible bundle '" + $CrucibleRoot + "': it is relative and the project root is empty.")
        }
        throw
    }
}

# Whether Path is Directory or inside it, compared on full paths at a separator boundary so
# a sibling sharing the prefix (C:\bundle2 beside C:\bundle, research-old beside research)
# is outside. Ordinal and case-insensitive: a scan that misses an artifact by case fails open.
function Test-PathWithinDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Directory,
        [System.StringComparison]$Comparison = [System.StringComparison]::OrdinalIgnoreCase
    )

    # Resolve-Path callers trim trailing separators, including a drive root's slash.
    # Treat a bare drive as that drive's root, never its process-relative directory.
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        if ($Path -match '^[A-Za-z]:$') { $Path += "\" }
        if ($Directory -match '^[A-Za-z]:$') { $Directory += "\" }
    }
    if (-not [System.IO.Path]::IsPathFullyQualified($Path) -or
        -not [System.IO.Path]::IsPathFullyQualified($Directory)) {
        throw "Cannot test path containment: Path and Directory must both be absolute."
    }
    $normalizedPath = [System.IO.Path]::GetFullPath($Path).Replace("\", "/").TrimEnd("/")
    $normalizedDirectory = [System.IO.Path]::GetFullPath($Directory).Replace("\", "/").TrimEnd("/")
    if ($normalizedPath.Equals($normalizedDirectory, $Comparison)) { return $true }
    $directoryPrefix = $normalizedDirectory + "/"
    return $normalizedPath.StartsWith($directoryPrefix, $Comparison)
}

# Item 305: return a suffix only after the containment owner accepts the same full
# paths that are sliced. Empty string means the directory itself; $null means outside.
# Require absolute inputs: GetFullPath must never choose the process working directory.
# Keep the suffix's case and trailing separator; callers select their existing separator.
function Get-PathRelativeToDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Directory,
        [System.StringComparison]$Comparison = [System.StringComparison]::OrdinalIgnoreCase,
        [ValidateSet("/", "\")][string]$Separator = [string][System.IO.Path]::DirectorySeparatorChar
    )

    # Resolve-Path callers trim trailing separators, including a drive root's slash.
    # Treat a bare drive as that drive's root, never its process-relative directory.
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        if ($Path -match '^[A-Za-z]:$') { $Path += "\" }
        if ($Directory -match '^[A-Za-z]:$') { $Directory += "\" }
    }
    if (-not [System.IO.Path]::IsPathFullyQualified($Path) -or
        -not [System.IO.Path]::IsPathFullyQualified($Directory)) {
        throw "Cannot relativize a path: Path and Directory must both be absolute."
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path).Replace("\", "/")
    $fullDirectory = [System.IO.Path]::GetFullPath($Directory).Replace("\", "/").TrimEnd("/")
    if (-not (Test-PathWithinDirectory -Path $Path -Directory $Directory -Comparison $Comparison)) { return $null }
    return $fullPath.Substring($fullDirectory.Length).TrimStart("/").Replace("/", $Separator)
}

function Test-ConfiguredRuntimePath {
    # Item 188: custom session/workspaces roots have the same runtime-data exemption.
    param([string]$Path, [string]$ProjectRoot)
    $fullPath = Resolve-FilesystemPath -Path (Resolve-PathFromRoot -Root $ProjectRoot -Path $Path)
    foreach ($key in @("session", "workspaces")) {
        $directory = Resolve-FilesystemPath -Path (Get-ConfiguredPath -Key $key -ProjectRoot $ProjectRoot)
        if (Test-PathWithinDirectory -Path $fullPath -Directory $directory) {
            return $true
        }
    }
    return $false
}

function Get-ConfiguredReview {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("diff_tool", "editor", "auto_push", "require_green_ci", "ci_timeout_minutes", "ci_queued_grace_minutes", "ci_staging_branch_prefix", "ci_required_checks", "ci_post_push_watch")]
        [string]$Key,
        [string]$ProjectRoot = "",
        # Config text already read and verified (Get-ConfigCommitState). Supplied, the file
        # is not reopened. Item 254.
        [AllowEmptyString()][string]$Content
    )

    $root = Resolve-ConfigProjectRoot -ProjectRoot $ProjectRoot
    $configPath = Join-Path $root ".crucible/config.yaml"
    $haveContent = $PSBoundParameters.ContainsKey("Content")
    if ($haveContent -or (Test-Path -LiteralPath $configPath)) {
        $content = if ($haveContent) { $Content } else { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 }
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
    param(
        [string]$ProjectRoot = "",
        # Verified config text; supplied, the file is not reopened. Item 254.
        [AllowEmptyString()][string]$Content
    )

    $root = Resolve-ConfigProjectRoot -ProjectRoot $ProjectRoot -PathResolution Always

    $configPath = Join-Path $root ".crucible/config.yaml"
    $haveContent = $PSBoundParameters.ContainsKey("Content")
    if (-not $haveContent -and -not (Test-Path -LiteralPath $configPath)) { return $null }

    $content = if ($haveContent) { $Content } else { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 }
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
    if ((Resolve-PathFromRoot -Root $root -Path $val) -ceq $val -or $val -match '^([A-Za-z]:|[\\/])') {
        throw ("hooks.project_dir must be a relative path inside the project (got '" + $val + "').")
    }
    if ($val -match '^\.\.' -or $val -match '[\\/]\.\.') {
        throw ("hooks.project_dir must not escape the project root (got '" + $val + "').")
    }
    # Crucible's own hooks live under .crucible; naming them would make each hook run itself.
    if ($val -match '^\.crucible([\\/]|$)') {
        throw ("hooks.project_dir must name the project's own hooks, not a directory under .crucible (got '" + $val + "').")
    }

    $full = Resolve-PathFromRoot -Root $root -Path $val
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw ("hooks.project_dir names a directory that does not exist: " + $val)
    }
    return (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $full))
}

# project.default_branch names the branch tasks are cut from, rebased onto and merged into.
# Unset, it is main when that branch exists, else master. A configured branch that does
# not exist throws instead of falling back: merging into a guessed branch is worse than
# stopping. Item 189.
function Get-ConfiguredPrimaryBranch {
    param(
        [string]$ProjectRoot = "",
        # Verified config text; supplied, the file is not reopened. Item 254.
        [AllowEmptyString()][string]$Content
    )

    $root = Resolve-FilesystemPath -Path (Resolve-ConfigProjectRoot -ProjectRoot $ProjectRoot -PathResolution None)

    $configPath = Join-Path $root ".crucible/config.yaml"
    $haveContent = $PSBoundParameters.ContainsKey("Content")
    if ($haveContent -or (Test-Path -LiteralPath $configPath)) {
        $content = if ($haveContent) { $Content } else { Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 }
        $val = Get-ConfigBlockValue -Content $content -Path @("project", "default_branch") -Source $configPath
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            $branch = $val.Trim()
            git -C (Resolve-FilesystemPath -Path $root) show-ref --verify --quiet "refs/heads/$branch" 2>$null
            if ($LASTEXITCODE -ne 0) {
                $current = (git -C (Resolve-FilesystemPath -Path $root) symbolic-ref --short -q HEAD 2>$null)
                throw ("project.default_branch in " + $configPath + " is '" + $branch + "', but " + $root + " has no such branch. Set it to the branch tasks merge into" + $(if ($current) { " (the checkout is on '" + ([string]$current).Trim() + "')" } else { "" }) + ".")
            }
            return $branch
        }
    }

    git -C (Resolve-FilesystemPath -Path $root) show-ref --verify --quiet refs/heads/main 2>$null
    if ($LASTEXITCODE -eq 0) { return "main" }
    return "master"
}

# orchestration.approval says whether the orchestrator asks for a "go" before every
# dispatch (per-phase) or once per item and then runs each phase to the Human Gate
# (to-gate). It is a personal preference, so the gitignored .crucible/config.local.yaml
# is read first and wins; the committed config.yaml is the fallback. An unrecognized value
# throws rather than falling back, so a typo never silently changes who approves. Item 178.
function Get-ConfigFileApprovalMode {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $content = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    $val = Get-ConfigBlockValue -Content $content -Path @("orchestration", "approval") -Source $ConfigPath
    if ($null -eq $val) { return $null }
    $allowed = @("per-phase", "to-gate")
    $mode = $val.Trim().ToLowerInvariant()
    if ($allowed -notcontains $mode) {
        throw ("orchestration.approval in " + $ConfigPath + " must be one of: " + ($allowed -join ", ") + " (got '" + $val + "').")
    }
    return $mode
}

function Get-ConfiguredApprovalMode {
    param([string]$ProjectRoot = "")

    $root = Resolve-ConfigProjectRoot -ProjectRoot $ProjectRoot -PathResolution None

    foreach ($name in @("config.local.yaml", "config.yaml")) {
        $configPath = Join-Path $root (".crucible/" + $name)
        if (-not (Test-Path -LiteralPath $configPath)) { continue }
        $mode = Get-ConfigFileApprovalMode -ConfigPath $configPath
        if ($null -ne $mode) { return $mode }
    }
    return "per-phase"
}

function Get-ConfiguredManifestFiles {
    param(
        [string]$ProjectRoot = ""
    )

    $root = Resolve-ConfigProjectRoot -ProjectRoot $ProjectRoot
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
# tier (the 'done' phase) has no model. A codex tier is a level, a model and an effort
# together, and so is a claude tier (Item 212), so their models come from Get-ModelLevel.
# Keep the default maps in sync with templates/project/.crucible/config.yaml.
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

    if ($target -eq "codex" -or $target -eq "claude") {
        $level = Get-ModelLevel -Target $target -Tier $tier -ProjectRoot $ProjectRoot -WarningAction SilentlyContinue
        if ($null -ne $level) { return $level.Model }
        return $tier
    }

    $defaults = @{
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

# A level is a model and an effort taken together, and one is never set without the
# other. Codex: strong is gpt-6.1-sol at high, default is gpt-6.1-sol at low, light is
# gpt-6-luna at high. Luna is most effective at high, so the cheapest level is Luna at high
# rather than a stronger model at a lower effort. Claude (Item 212): strong is
# claude-opus-5-5 at high, default is claude-sonnet-5-5 at medium, light is claude-haiku-5-5
# at high; the Agent tool takes the effort as its `effort` parameter. config.yaml sets a
# level as one pair:
#   models: > targets: > <target>: > <tier>: > model: / effort:
# A bare model at models.targets.<target>.<tier> still reads, at the built-in effort, and
# warns when it changes the model without the effort. Only Codex also has the older split
# form, models.effort.codex.<tier>, which still reads and warns wherever it splits a level.
# Returns $null for an empty or unknown tier (the 'done' phase).
function Get-ModelLevel {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("codex", "claude")][string]$Target,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Tier,
        [string]$ProjectRoot = ""
    )

    if ($Target -eq "codex") {
        $label = "Codex"
        $levels = @{
            strong  = @{ Model = "gpt-6.1-sol"; Effort = "high" }
            default = @{ Model = "gpt-6.1-sol"; Effort = "low" }
            light   = @{ Model = "gpt-6-luna";  Effort = "high" }
        }
        $efforts = @("none", "minimal", "low", "medium", "high", "xhigh", "max")
    } else {
        $label = "Claude"
        $levels = @{
            strong  = @{ Model = "claude-opus-5-5";   Effort = "high" }
            default = @{ Model = "claude-sonnet-5-5"; Effort = "medium" }
            light   = @{ Model = "claude-haiku-5-5";  Effort = "high" }
        }
        $efforts = @("low", "medium", "high", "xhigh", "max")
    }

    $t = if ($null -ne $Tier) { $Tier.Trim().ToLowerInvariant() } else { "" }
    if (-not $levels.ContainsKey($t)) { return $null }
    $builtIn = $levels[$t]
    $level = [pscustomobject]@{ Tier = $t; Model = $builtIn.Model; Effort = $builtIn.Effort }

    $configPath = Get-ProjectConfigFile -ProjectRoot $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($configPath)) { return $level }
    $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $entries = @(Get-ConfigEntries -Content $content)

    $levelPath = @("models", "targets", $Target, $t)
    $levelKey = $levelPath -join "."
    $splitKey = "models.effort.codex." + $t
    $splitEffort = if ($Target -eq "codex") { Get-ConfigBlockValue -Content $content -Path @("models", "effort", "codex", $t) -Source $configPath } else { $null }
    $node = Find-ConfigNode -Entries $entries -Path $levelPath -Source $configPath

    if ($null -ne $node -and [string]::IsNullOrWhiteSpace($entries[$node.Index].Value)) {
        $model = Get-ConfigBlockValue -Content $content -Path ($levelPath + "model") -Source $configPath
        $effort = Get-ConfigBlockValue -Content $content -Path ($levelPath + "effort") -Source $configPath
        if ($null -eq $model -or $null -eq $effort) {
            throw ("Unreadable " + $configPath + ": '" + $levelKey + "' is a " + $label + " level, so it needs both a model and an effort.")
        }
        $effort = $effort.Trim().ToLowerInvariant()
        if ($efforts -notcontains $effort) {
            throw ("Unreadable " + $configPath + ": '" + $levelKey + ".effort' is '" + $effort + "', which is not one of " + ($efforts -join ", ") + ".")
        }
        if ($null -ne $splitEffort) {
            Write-Warning ("config.yaml " + $splitKey + " is ignored: " + $levelKey + " already sets the level's effort. Delete " + $splitKey + ".")
        }
        $level.Model = $model
        $level.Effort = $effort
        return $level
    }

    if ($null -ne $node) { $level.Model = ConvertFrom-ConfigScalar $entries[$node.Index].Value }
    if ($null -ne $splitEffort) {
        $value = $splitEffort.Trim().ToLowerInvariant()
        if ($efforts -contains $value) {
            $level.Effort = $value
            Write-Warning ("config.yaml " + $splitKey + " sets the effort of the " + $t + " level apart from its model. Write the level as one pair, a model and an effort under " + $levelKey + ", and delete " + $splitKey + ".")
        } else {
            Write-Warning ("config.yaml " + $splitKey + " is '" + $splitEffort + "', which is not one of " + ($efforts -join ", ") + "; using the " + $t + " level's built-in effort '" + $builtIn.Effort + "'.")
        }
    } elseif ($level.Model -ne $builtIn.Model) {
        Write-Warning ("config.yaml " + $levelKey + " changes the " + $t + " level's model to '" + $level.Model + "' but not its effort, so it runs at the built-in '" + $builtIn.Effort + "'. Write the level as one pair, a model and an effort under " + $levelKey + ".")
    }
    return $level
}

function Get-CodexLevel {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Tier,
        [string]$ProjectRoot = ""
    )
    return Get-ModelLevel -Target codex -Tier $Tier -ProjectRoot $ProjectRoot
}

function Get-ClaudeLevel {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Tier,
        [string]$ProjectRoot = ""
    )
    return Get-ModelLevel -Target claude -Tier $Tier -ProjectRoot $ProjectRoot
}

# The project's .crucible/config.yaml, or "" when there is none.
function Get-ProjectConfigFile {
    param([string]$ProjectRoot = "")

    $root = Resolve-ConfigProjectRoot -ProjectRoot $ProjectRoot

    $configPath = Join-Path $root ".crucible/config.yaml"
    if (-not (Test-Path -LiteralPath $configPath)) { return "" }
    return $configPath
}

function Get-ModelsBlockValue {
    param(
        [Parameter(Mandatory = $true)][string[]]$Path,
        [string]$ProjectRoot = ""
    )

    $configPath = Get-ProjectConfigFile -ProjectRoot $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($configPath)) { return "" }

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

# Optional review keys default in Get-ConfiguredReview; every present value must parse.
function ConvertFrom-ReviewMinutes {
    param([string]$Value, [string]$Key)
    $minutes = 0
    if ($Value -notmatch '^[0-9]+$' -or -not [int]::TryParse($Value, [ref]$minutes)) {
        throw "review.$Key must be a non-negative integer of minutes (got '$Value')."
    }
    return $minutes
}
