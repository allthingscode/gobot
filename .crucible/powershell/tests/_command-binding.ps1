# The reader and binder for commands written as text: shipped documents (item 275) and the
# framework tests' printed advice (item 364). It ships with documented-commands.tests.ps1.
# Values are checked against Get-CrucibleScriptParameters' accepted values (item 365).

# The roots a documented script path may start from: the bundle as the documents name it, a
# placeholder, or the example checkout path docs/updating.md runs the updater from. What is
# left must be a bundle-relative script.
$DOCUMENTED_ROOT_PREFIX = '^(?:\./)?(?:(?:\{\{crucible_root\}\}|\{crucible_root\}|\.crucible|<[^<>/]+>|\{[^{}/]+\}|(?:[A-Za-z]:)?/path/to/[^/]+)/)?'

$SCRIPT_TOKEN = '(?<![\w.-])(?<path>(?:[^\s"''`|;()]*[/\\])?[\w-]+\.ps1)(?![\w.-])'
# Any word that starts with a dash and a letter is a parameter to PowerShell, whatever follows.
$PARAMETER_WORD = '^\[?-[A-Za-z]'
$PARAMETER_TOKEN = '^\[?-(?<name>[A-Za-z][\w-]*?)(?<inline>:\S*)?\]?[),.]*$'
$SPLAT_WORD = '^\[?@[A-Za-z_]'

function Remove-DocumentedCommandFixture {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    $runRoot = [IO.Path]::GetFullPath((Get-TestRunRoot)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($runRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture escaped the test run root: $resolved" }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

# Inline code spans of one paragraph, which may cross its line breaks, then each line of the
# prose around them: a command written without backticks is still a command to copy.
function Get-InlineCodeSegments {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Paragraph
    )
    if ($Paragraph.Count -eq 0) { return @() }
    $text = ($Paragraph | ForEach-Object { $_.Text }) -join "`n"
    $segments = @()
    $spanPattern = '(?s)(?<!`)(?<ticks>`+)(?!`)(?<body>.+?)(?<!`)\k<ticks>(?!`)'
    foreach ($m in [regex]::Matches($text, $spanPattern)) {
        $offset = ($text.Substring(0, $m.Index).Split("`n")).Count - 1
        $segments += [pscustomobject]@{ Line = $Paragraph[$offset].Line; Kind = "code"; Text = ($m.Groups["body"].Value -replace '\s*\n\s*', ' ').Trim() }
    }
    $prose = [regex]::Replace($text, $spanPattern, { param($m) " | " + ("`n" * ($m.Value.Split("`n").Count - 1)) })
    $proseLines = $prose.Split("`n")
    for ($k = 0; $k -lt $proseLines.Count; $k++) {
        $segments += [pscustomobject]@{ Line = $Paragraph[$k].Line; Kind = "prose"; Text = $proseLines[$k].Trim() }
    }
    return $segments
}

# The code a Markdown document shows: each logical line of a fenced block (a trailing backtick
# or backslash continues it), each inline code span, and each line of prose, each marked as
# code or prose.
function Get-MarkdownCodeSegments {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $lines = $Text -split "\r?\n"
    $segments = @()
    $fence = $null
    $fenceKind = "prose"
    $pending = $null
    $paragraph = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $number = $i + 1
        if ($null -ne $fence) {
            if ($line -match ('^\s*(?:>\s*)*' + [regex]::Escape([string]$fence[0]) + '{' + $fence.Length + ',}\s*$')) {
                if ($null -ne $pending) { $segments += $pending; $pending = $null }
                $fence = $null
                continue
            }
            $body = $line.TrimEnd()
            $continues = $body -match '(?:\s|^)[`\\]$'
            if ($continues) { $body = $body.Substring(0, $body.Length - 1) }
            if ($null -eq $pending) {
                $pending = [pscustomobject]@{ Line = $number; Kind = $fenceKind; Text = $body.Trim() }
            } else {
                $pending.Text = ($pending.Text + " " + $body.Trim()).Trim()
            }
            if (-not $continues) { $segments += $pending; $pending = $null }
            continue
        }
        if ($line -match '^\s*(?:>\s*)*(?<f>`{3,}|~{3,})\s*(?<info>[^\s`]*)') {
            $segments += @(Get-InlineCodeSegments -Paragraph $paragraph)
            $paragraph = @()
            $fence = $Matches["f"]
            # A shell block is code. Any other block (text, markdown, an untagged decision tree)
            # is read like prose, so a sentence after a command in it ends the command.
            $fenceKind = if ($Matches["info"] -match '^(?i:bash|sh|shell|console|powershell|pwsh|ps1)$') { "code" } else { "prose" }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($line)) {
            $segments += @(Get-InlineCodeSegments -Paragraph $paragraph)
            $paragraph = @()
            continue
        }
        $paragraph += [pscustomobject]@{ Line = $number; Text = $line }
    }
    if ($null -ne $pending) { $segments += $pending }
    $segments += @(Get-InlineCodeSegments -Paragraph $paragraph)
    return $segments
}

# The words of a command line after its script path. A quoted string, a <placeholder> and a
# {placeholder} are one word whatever they contain; a pipe, a semicolon, an ampersand, a
# comment or a closing parenthesis ends the command.
function Get-CommandWords {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $words = @()
    $i = 0
    $n = $Text.Length
    while ($i -lt $n) {
        if ([char]::IsWhiteSpace($Text[$i])) { $i++; continue }
        if ('|;&#)'.Contains([string]$Text[$i])) { break }
        $word = New-Object System.Text.StringBuilder
        while ($i -lt $n -and -not [char]::IsWhiteSpace($Text[$i])) {
            $c = $Text[$i]
            $close = switch ($c) { '"' { '"' } "'" { "'" } '<' { '>' } '{' { '}' } default { $null } }
            if ($null -ne $close) {
                $end = $Text.IndexOf($close, $i + 1)
                if ($c -eq '{') {
                    $depth = 0
                    for ($j = $i; $j -lt $n; $j++) {
                        if ($Text[$j] -eq '{') { $depth++ } elseif ($Text[$j] -eq '}') { $depth--; if ($depth -eq 0) { $end = $j; break } }
                    }
                }
                if ($end -lt 0) { $end = $n - 1 }
                [void]$word.Append($Text.Substring($i, $end - $i + 1))
                $i = $end + 1
                continue
            }
            if ($c -eq '|' -or $c -eq ';') { break }
            [void]$word.Append($c)
            $i++
        }
        $words += $word.ToString()
        if ($i -lt $n -and ($Text[$i] -eq '|' -or $Text[$i] -eq ';')) { break }
    }
    return $words
}

# One record per "<script>.ps1 -<Param>" (or splat) in a document: the script as written, the
# words after it up to the next script, and whether it is code or prose.
function Get-DocumentedInvocations {
    param(
        [Parameter(Mandatory = $true)][string]$FullName,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    $text = [System.IO.File]::ReadAllText($FullName)
    $invocations = @()
    foreach ($segment in @(Get-MarkdownCodeSegments -Text $text)) {
        $invocations += @(Get-CommandTextInvocations -Segment $segment -RelativePath $RelativePath)
    }
    return $invocations
}

# The invocations in one segment of text (a document's code or prose, or a test's printed
# message): each script with the words that follow it, when one of them is a parameter. With
# -BareCue, a script with no parameter is one too when the text before it ends in that cue
# ("Re-sync with: <script>"), so its path is still resolved.
function Get-CommandTextInvocations {
    param(
        [Parameter(Mandatory = $true)]$Segment,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [string]$BareCue = ""
    )
    $invocations = @()
    foreach ($m in [regex]::Matches($Segment.Text, $SCRIPT_TOKEN)) {
        $rest = $Segment.Text.Substring($m.Index + $m.Length) -replace '^["'']', ''
        $shown = @()
        foreach ($word in @(Get-CommandWords -Text $rest)) {
            if (($word.Trim('"', "'")) -match $SCRIPT_TOKEN -and ($word.Trim('"', "'")) -match '\.ps1$') { break }
            $shown += $word
        }
        # Prose that goes on with a word that is no parameter names the script, not a command:
        # the command would end at that word.
        if ($Segment.Kind -eq "prose" -and $shown.Count -gt 0 -and $shown[0] -notmatch $PARAMETER_WORD -and $shown[0] -notmatch $SPLAT_WORD) { $shown = @() }
        if (@($shown | Where-Object { $_ -match $PARAMETER_WORD -or $_ -match $SPLAT_WORD }).Count -eq 0) {
            if ([string]::IsNullOrEmpty($BareCue) -or $Segment.Text.Substring(0, $m.Index) -notmatch ('(?:' + $BareCue + ')\s*$')) { continue }
        }
        $invocations += [pscustomobject]@{
            RelativePath = $RelativePath
            Line         = $Segment.Line
            Kind         = $Segment.Kind
            Path         = $m.Groups["path"].Value
            Text         = ($m.Groups["path"].Value + " " + ($shown -join " ")).Trim()
            Words        = $shown
        }
    }
    return $invocations
}

# The literal one documented value carries, or $null when it is computed. A single-quoted value
# is literal whatever it holds; a double-quoted one is computed when it expands ($, backtick);
# a bare one when it is a variable, an expression or a splat.
function Get-DocumentedValueLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -ge 2 -and $Value[0] -eq "'" -and $Value[-1] -eq "'") {
        return $Value.Substring(1, $Value.Length - 2).Replace("''", "'")
    }
    if ($Value.Length -ge 2 -and $Value[0] -eq '"' -and $Value[-1] -eq '"') {
        $inner = $Value.Substring(1, $Value.Length - 2)
        if ($inner -match '[$`]') { return $null }
        return $inner
    }
    if ($Value -match '[$`@(]') { return $null }
    return $Value
}

# The literals a documented value word carries, after optional-bracket and sentence punctuation:
# for an array parameter each comma-separated element (commas inside quotes are kept), else the
# word as one value. A computed element is left to the run.
function Get-DocumentedValueLiterals {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Word,
        [switch]$IsArray
    )
    $value = $Word.TrimEnd(']', ')', ',', '.', ';', ':')
    $elements = @($value)
    if ($IsArray) {
        $elements = @()
        $current = New-Object System.Text.StringBuilder
        $quote = $null
        foreach ($c in $value.ToCharArray()) {
            if ($null -ne $quote) { if ($c -eq $quote) { $quote = $null } }
            elseif ($c -eq "'" -or $c -eq '"') { $quote = $c }
            elseif ($c -eq ',') { $elements += $current.ToString(); [void]$current.Clear(); continue }
            [void]$current.Append($c)
        }
        $elements += $current.ToString()
    }
    return @($elements | ForEach-Object { Get-DocumentedValueLiteral -Value $_.Trim() } | Where-Object { $null -ne $_ })
}

# Binds an invocation's words to the declared parameters the way PowerShell would, and says
# what does not bind. Full names only: a unique prefix runs, but a document that abbreviates
# breaks when the script gains a parameter with the same prefix. A value that is not the
# argument of a named value parameter binds positionally, which no documented command relies
# on, so it is reported; in prose the command ends at the first such word instead, because
# the sentence continues there. A splat cannot be bound from a document line.
function Get-InvocationBindingProblems {
    param(
        [Parameter(Mandatory = $true)]$Invocation,
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][hashtable]$Declared
    )
    $problems = @()
    $names = @()
    $words = @($Invocation.Words)
    $previousSwitch = $null
    $i = 0
    while ($i -lt $words.Count) {
        $word = $words[$i]
        if ($word -match $SPLAT_WORD) {
            $problems += ("splats " + $word + ", which a document line cannot bind; write the parameters out")
            $previousSwitch = $null
            $i++
            continue
        }
        if ($word -notmatch $PARAMETER_WORD) {
            if ($Invocation.Kind -eq "prose") { break }
            $after = if ($null -ne $previousSwitch) { " after the switch -" + $previousSwitch } else { "" }
            $problems += ("the value " + $word + $after + " is not the argument of a named parameter, so PowerShell binds it positionally; name its parameter")
            $previousSwitch = $null
            $i++
            continue
        }
        $previousSwitch = $null
        $parameter = [regex]::Match($word, $PARAMETER_TOKEN)
        if (-not $parameter.Success) {
            $problems += ("cannot read " + $word + " as a parameter name")
            $i++
            continue
        }
        $name = $parameter.Groups["name"].Value
        $inline = $parameter.Groups["inline"].Length -gt 1
        $nextIsValue = $i + 1 -lt $words.Count -and $words[$i + 1] -notmatch $PARAMETER_WORD -and $words[$i + 1] -notmatch $SPLAT_WORD
        $canonical = @($Declared.Keys | Where-Object { $_ -eq $name }) | Select-Object -First 1
        if ($null -eq $canonical) {
            $prefixed = @($Declared.Keys | Where-Object { $_.StartsWith($name, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object)
            if ($prefixed.Count -eq 1) {
                $problems += ("abbreviated parameter -" + $name + "; write -" + $prefixed[0])
            } elseif ($prefixed.Count -gt 1) {
                $problems += ("abbreviated parameter -" + $name + " is ambiguous (" + (($prefixed | ForEach-Object { "-" + $_ }) -join ", ") + "); write the full name")
            } else {
                $problems += ($Script + " declares no parameter -" + $name)
            }
            $i += $(if (-not $inline -and $nextIsValue) { 2 } else { 1 })
            continue
        }
        $names += $canonical
        $valueWord = $null
        if ($Declared[$canonical].IsSwitch) {
            # A present switch binds True (or the $true/$false given inline), which its own
            # ValidateSet may refuse.
            $state = "True"
            if ($inline) {
                $given = $parameter.Groups["inline"].Value.Substring(1)
                $state = if ($given -eq '$true') { "True" } elseif ($given -eq '$false') { "False" } else { $null }
            } else {
                $previousSwitch = $canonical
            }
            if ($null -ne $state) { $problems += @(Get-CrucibleCommandValueProblems -Name $canonical -Value $state -Parameter $Declared[$canonical]) }
            $i++
            continue
        }
        if ($inline) {
            $valueWord = $parameter.Groups["inline"].Value.Substring(1)
        } elseif ($nextIsValue) {
            $valueWord = $words[$i + 1]
        }
        if ($null -ne $valueWord) {
            $literals = @(Get-DocumentedValueLiterals -Word $valueWord -IsArray:([bool]$Declared[$canonical].IsArray))
            if ($literals.Count -gt 0) { $problems += @(Get-CrucibleCommandValueProblems -Name $canonical -Value $literals -Parameter $Declared[$canonical]) }
            $i += $(if ($inline) { 1 } else { 2 })
            continue
        }
        $problems += ("-" + $canonical + " takes a value and none follows it")
        $i++
    }
    $problems += @(Get-CrucibleCommandCompanionProblems -Script $Script -Names $names)
    return $problems
}

# What ships, from the install manifest of the bundle this file is in: the Markdown to read and
# the scripts a command may name.
function Get-ShippedFileSet {
    param([Parameter(Mandatory = $true)][string]$BundleRoot)
    $owned = @(Get-FrameworkOwnedFiles -FrameworkRoot $BundleRoot)
    $scripts = @{}
    $leaves = @{}
    foreach ($rel in $owned) {
        if ($rel -notmatch '\.ps1$' -or $rel -notmatch '^(powershell|scripts)/' -or $rel -match '^powershell/tests/') { continue }
        $scripts[$rel] = $true
        $leaf = ($rel -split '/')[-1]
        if (-not $leaves.ContainsKey($leaf)) { $leaves[$leaf] = @() }
        $leaves[$leaf] += $rel
    }
    return [pscustomobject]@{
        Markdown = @($owned | Where-Object { $_ -match '\.md$' })
        Scripts  = $scripts
        Leaves   = $leaves
    }
}

# The bundle-relative script an invocation names, or why it names none.
function Resolve-DocumentedScript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Shipped
    )
    $normalized = $Path.Replace('\', '/')
    if (-not $normalized.Contains('/')) {
        $found = @(if ($Shipped.Leaves.ContainsKey($normalized)) { $Shipped.Leaves[$normalized] })
        if ($found.Count -eq 1) { return @{ Script = $found[0]; Problem = $null } }
        if ($found.Count -gt 1) { return @{ Script = $null; Problem = ("names " + $normalized + ", which is ambiguous in the bundle: " + ($found -join ", ")) } }
        return @{ Script = $null; Problem = ("names no script " + $normalized + " in the bundle") }
    }
    $relative = $normalized -replace $DOCUMENTED_ROOT_PREFIX, ''
    if ($Shipped.Scripts.ContainsKey($relative)) { return @{ Script = $relative; Problem = $null } }
    if (Test-FrameworkDevOnlyFile -Path $relative) {
        return @{ Script = $null; Problem = ("names " + $relative + ", a framework dev-only script that no bundle receives") }
    }
    return @{ Script = $null; Problem = ("names no script " + $normalized + " in the bundle") }
}

# Each invocation bound against the script it names, with its problems.
function Get-DocumentedCommandProblems {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Invocations,
        [Parameter(Mandatory = $true)]$Shipped,
        [Parameter(Mandatory = $true)][string]$BundleRoot
    )
    $bound = @()
    foreach ($invocation in $Invocations) {
        $problems = @()
        $resolved = Resolve-DocumentedScript -Path $invocation.Path -Shipped $Shipped
        if ($null -ne $resolved.Problem) {
            $problems += $resolved.Problem
        } elseif (@($invocation.Words).Count -gt 0) {
            try {
                $declared = Get-CrucibleScriptParameters -Script $resolved.Script -BundleRoot $BundleRoot
                $problems += @(Get-InvocationBindingProblems -Invocation $invocation -Script $resolved.Script -Declared $declared)
            } catch {
                $problems += ($_.Exception.Message -replace '^New-CrucibleCommand: ', '')
            }
        }
        $bound += [pscustomobject]@{ Invocation = $invocation; Problems = @($problems); Allowance = $null }
    }
    return $bound
}

function Set-DocumentedCommandAllowances {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Bound,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Allowances
    )
    foreach ($entry in $Bound) {
        if ($entry.Problems.Count -eq 0) { continue }
        $entry.Allowance = @($Allowances | Where-Object {
            $_.RelativePath -eq $entry.Invocation.RelativePath -and $entry.Invocation.Text -cmatch $_.Pattern
        }) | Select-Object -First 1
    }
}

function Get-UnboundDocumentedCommands {
    param([AllowEmptyCollection()][array]$Bound)
    return @($Bound | Where-Object { $_.Problems.Count -gt 0 -and $null -eq $_.Allowance } | ForEach-Object {
        $_.Invocation.RelativePath + ":" + $_.Invocation.Line + ": " + $_.Invocation.Text + "`n    " + ($_.Problems -join "`n    ")
    })
}

function Get-StaleDocumentedCommandAllowances {
    param([AllowEmptyCollection()][array]$Bound, [AllowEmptyCollection()][array]$Allowances)
    $stale = @()
    foreach ($allowance in $Allowances) {
        $used = @($Bound | Where-Object { $null -ne $_.Allowance -and [object]::ReferenceEquals($_.Allowance, $allowance) })
        if ($used.Count -eq 0) { $stale += ($allowance.RelativePath + ": pattern " + $allowance.Pattern + " excuses no documented command") }
    }
    return $stale
}

function Get-DocumentedCommandScan {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Documents,
        [Parameter(Mandatory = $true)]$Shipped,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Allowances,
        [Parameter(Mandatory = $true)][string]$BundleRoot
    )
    $invocations = @()
    foreach ($rel in $Documents) {
        $invocations += @(Get-DocumentedInvocations -FullName (Join-Path $Root $rel) -RelativePath $rel)
    }
    $bound = @(Get-DocumentedCommandProblems -Invocations $invocations -Shipped $Shipped -BundleRoot $BundleRoot)
    Set-DocumentedCommandAllowances -Bound $bound -Allowances $Allowances
    return $bound
}
