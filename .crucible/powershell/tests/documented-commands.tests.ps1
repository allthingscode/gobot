# Every command a shipped document gives for one of Crucible's own scripts binds to that script.
#
# Item 275. Item 247 binds the commands runtime PowerShell prints (I15), but the documents an
# orchestrator or specialist copies commands from were free text: items 125, 126 and 272 were
# instances there of the class item 219 was at runtime. This reads the fenced code, inline code
# and plain prose of every Markdown file the bundle ships and checks each "<script>.ps1 -<Param>": the
# script is in the bundle, it declares every parameter, a parameter that takes a value has one,
# and the builder's companion rules (Get-CrucibleCommandCompanionProblems) hold. Placeholders
# such as <task-id> and {project_root} are values like any other. A line that breaks a rule on
# purpose needs an allowance with its reason, and an allowance that excuses nothing fails.
#
# It ships, and reads the bundle it runs in. The framework's dev-only scripts are absent from
# an adopter bundle and are not counted as bundle scripts here either, so a document naming one
# needs the same allowance in both layouts.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$BUNDLE_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $BUNDLE_ROOT "powershell/lib/platform.ps1")
. (Join-Path $BUNDLE_ROOT "powershell/lib/install-manifest.ps1")
. (Join-Path $BUNDLE_ROOT "powershell/lib/crucible-command.ps1")

$results = @()

# Invocations that break a rule and are not a command anyone runs as written. Each names its
# document, a pattern for the invocation's text, and why. A bare `crucible.ps1 -Init` span is
# not exempt by shape: items 125 and 126 were bare copies an agent ran, so each document that
# names the entry point in a sentence is reviewed here.
$BARE_INIT = '^crucible\.ps1 -Init$'
$DOCUMENTED_COMMAND_ALLOWANCES = @(
    @{ RelativePath = "docs/config-reference.md"; Pattern = $BARE_INIT
       Reason = "says what -Init prints about the approval mode; the runnable line is in sops/orchestrator.md" },
    @{ RelativePath = "docs/orchestrators/claude.md"; Pattern = $BARE_INIT
       Reason = "explains STATUS=ADVANCE_INCOMPLETE, the specialist's own -Init that was cut off; the launcher prints the recovery command" },
    @{ RelativePath = "docs/orchestrators/codex.md"; Pattern = $BARE_INIT
       Reason = "names the specialist's cut-off -Init and the run that prints [APPROVAL MODE]; the runnable lines are in this guide's fences" },
    @{ RelativePath = "docs/orchestrators/grok.md"; Pattern = $BARE_INIT
       Reason = "names the orchestrator's first -Init and where -Target grok goes; the runnable lines are in this guide's fences" },
    @{ RelativePath = "sops/deployment.md"; Pattern = $BARE_INIT
       Reason = "says the orchestrator's -Init already ran the dependency gate, and tells the Operator not to run it again" },
    @{ RelativePath = "sops/implementation.md"; Pattern = $BARE_INIT
       Reason = "tells an escalating Architect not to run -Init; the runnable line is in Phase 4" },
    @{ RelativePath = "sops/orchestrator.md"; Pattern = $BARE_INIT
       Reason = "names the -Init that prints [APPROVAL MODE] and the specialist's own -Init; the runnable line is in Step 1" },
    @{ RelativePath = "docs/policy.md"; Pattern = '^powershell/gates/check-generated-docs\.ps1 -Write$'
       Reason = "the sentence says this regenerator runs in the framework repo only and is not part of a bundle" }
)

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
    $invocations = @()
    $text = [System.IO.File]::ReadAllText($FullName)
    foreach ($segment in @(Get-MarkdownCodeSegments -Text $text)) {
        foreach ($m in [regex]::Matches($segment.Text, $SCRIPT_TOKEN)) {
            $rest = $segment.Text.Substring($m.Index + $m.Length) -replace '^["'']', ''
            $shown = @()
            foreach ($word in @(Get-CommandWords -Text $rest)) {
                if (($word.Trim('"', "'")) -match $SCRIPT_TOKEN -and ($word.Trim('"', "'")) -match '\.ps1$') { break }
                $shown += $word
            }
            if (@($shown | Where-Object { $_ -match $PARAMETER_WORD -or $_ -match $SPLAT_WORD }).Count -eq 0) { continue }
            $invocations += [pscustomobject]@{
                RelativePath = $RelativePath
                Line         = $segment.Line
                Kind         = $segment.Kind
                Path         = $m.Groups["path"].Value
                Text         = ($m.Groups["path"].Value + " " + ($shown -join " ")).Trim()
                Words        = $shown
            }
        }
    }
    return $invocations
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
        if ($inline) { $i++; continue }
        if ($Declared[$canonical]) {
            $previousSwitch = $canonical
            $i++
            continue
        }
        if ($nextIsValue) { $i += 2; continue }
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
        } else {
            $declared = Get-CrucibleScriptParameters -Script $resolved.Script -BundleRoot $BundleRoot
            $problems += @(Get-InvocationBindingProblems -Invocation $invocation -Script $resolved.Script -Declared $declared)
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
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Allowances
    )
    $invocations = @()
    foreach ($rel in $Documents) {
        $invocations += @(Get-DocumentedInvocations -FullName (Join-Path $Root $rel) -RelativePath $rel)
    }
    $bound = @(Get-DocumentedCommandProblems -Invocations $invocations -Shipped $Shipped -BundleRoot $BUNDLE_ROOT)
    Set-DocumentedCommandAllowances -Bound $bound -Allowances $Allowances
    return $bound
}

$shipped = Get-ShippedFileSet -BundleRoot $BUNDLE_ROOT
$treeBound = @(Get-DocumentedCommandScan -Root $BUNDLE_ROOT -Documents $shipped.Markdown -Shipped $shipped -Allowances $DOCUMENTED_COMMAND_ALLOWANCES)

$results += Run-Test -Name "Every documented command for a Crucible script binds to the script" -Body {
    Assert-Result -Name "the shipped documents are read" -Condition ($shipped.Markdown.Count -ge 50 -and $shipped.Scripts.Count -ge 40) -FailureMessage (
        "read " + $shipped.Markdown.Count + " shipped Markdown files and " + $shipped.Scripts.Count + " bundle scripts; fewer means the scan is not reading this bundle and the binding below proves nothing")
    Assert-Result -Name "documented commands found" -Condition ($treeBound.Count -ge 120) -FailureMessage (
        "found " + $treeBound.Count + " documented invocations; the shipped documents held about 150 when this guard was written, so fewer means the parser stopped seeing them")
    $unbound = @(Get-UnboundDocumentedCommands -Bound $treeBound)
    $message = if ($unbound.Count -gt 0) { "Documented commands that do not bind (fix the document, or add an allowance with its reason):`n" + ($unbound -join "`n") } else { "none" }
    Assert-Result -Name "every documented command binds" -Condition ($unbound.Count -eq 0) -FailureMessage $message
}

$results += Run-Test -Name "Every documented-command allowance has a reason and still excuses a line" -Body {
    $invalid = @()
    foreach ($entry in $DOCUMENTED_COMMAND_ALLOWANCES) {
        if (-not (Test-Path -LiteralPath (Join-Path $BUNDLE_ROOT $entry.RelativePath) -PathType Leaf)) { $invalid += ($entry.RelativePath + ": document does not exist") }
        if ([string]::IsNullOrWhiteSpace($entry.Reason) -or $entry.Reason.Length -lt 20) { $invalid += ($entry.RelativePath + ": missing or too short a reason") }
    }
    $invalid += @(Get-StaleDocumentedCommandAllowances -Bound $treeBound -Allowances $DOCUMENTED_COMMAND_ALLOWANCES)
    $message = if ($invalid.Count -gt 0) { $invalid -join "`n" } else { "none" }
    Assert-Result -Name "documented-command allowances are valid and live" -Condition ($invalid.Count -eq 0) -FailureMessage $message
}

# Each instance in the record, written the way the documents had it, planted in a scratch
# document with no allowance. Each must be reported with its own problem.
$FENCE = '```'
$PLANTED_DOCUMENTS = [ordered]@{
    "item 125 SOP advance without the root" = @(
        ($FENCE + "bash`npwsh -ExecutionPolicy Bypass \`n  -File `"{{crucible_root}}/powershell/crucible.ps1`" -Init -TaskId {task_id} -Quiet`n" + $FENCE),
        "-Init needs -ProjectRoot")
    "item 126 bare Init copy" = @(
        "At session end, run ``crucible.ps1 -Init`` to advance.",
        "-Init needs -ProjectRoot")
    "item 126 Init with a task and no root" = @(
        "Each agent runs ``crucible.ps1 -Init -TaskId {id}`` and chains forward.",
        "-Init needs -ProjectRoot")
    "item 219 dispatch without the effort" = @(
        "Re-dispatch with ``launch-codex-specialist.ps1 -TaskId <id> -Phase research -Model <model> -PromptFile <path>``.",
        "-Model needs -Effort")
    "item 272 specialist example without the effort" = @(
        ($FENCE + "powershell`npwsh -ExecutionPolicy Bypass ```n  -File `"{{crucible_root}}/powershell/launch-codex-specialist.ps1`" ```n  -TaskId {task_id} -Phase implementation -Model {model} -PromptFile `"{prompt}`"`n" + $FENCE),
        "-Model needs -Effort")
    "undeclared parameter" = @(
        "Run ``{{crucible_root}}/powershell/crucible.ps1 -Init -TaskId {task_id} -ProjectRoot `"{project_root}`" -Recovr``.",
        "declares no parameter -Recovr")
    "item 218 path outside the bundle layout" = @(
        "Usage: ``.\.crucible\\crucible.ps1 -Init -TaskId {task_id} -ProjectRoot `"{project_root}`"``",
        "names no script")
    "bool parameter with no value" = @(
        "For state updates use ``update-session-state.ps1 -Specialist grooming -TaskId {task_id} -UpdateJsonFile temp.json -Merge``.",
        "-Merge takes a value")
    "command in prose without backticks" = @(
        "Then run crucible.ps1 -Init -TaskId F-1 to advance.",
        "-Init needs -ProjectRoot")
    # Codex review of 3045d19: each of these passed.
    "parameter name with a dash" = @(
        "Run ``crucible.ps1 -Init -ProjectRoot . -Not-A-Parameter``.",
        "declares no parameter -Not-A-Parameter")
    "splatted parameters" = @(
        ($FENCE + "powershell`n`$options = @{ Init = `$true; Recovr = `$true }`n& ./powershell/crucible.ps1 @options`n" + $FENCE),
        "splats @options")
    "value after a switch" = @(
        "Run ``crucible.ps1 -Init `$true -ProjectRoot .``.",
        "after the switch -Init")
    "abbreviated parameter" = @(
        "Run ``crucible.ps1 -Ini -ProjectRoot .``.",
        "abbreviated parameter -Ini; write -Init")
    "positional value" = @(
        "Run ``clear-session-state.ps1 implementation -ProjectRoot .``.",
        "binds it positionally")
    "framework dev-only script" = @(
        "Run ``powershell/gates/check-ascii.ps1 -Staged`` before committing.",
        "framework dev-only script")
}

$CORRECT_DOCUMENT = @(
    "Run ``crucible.ps1 -Init -TaskId <task-id> -ProjectRoot `"{project_root}`"`` to advance.",
    "",
    ($FENCE + "bash"),
    "pwsh -ExecutionPolicy Bypass \",
    "  -File `"{{crucible_root}}/powershell/new-handoff.ps1`" -TaskId {task_id} -Source grooming -Target <implementation|research> -Reason `"Ready - see notes.`" [-FileAffinity `"<paths>`"] [-DesignRequired] -ProjectRoot `"{project_root}`"",
    $FENCE,
    "",
    "Preflight with ``launch-codex-specialist.ps1 -Preflight -Model <slug>``, then",
    "dispatch with ``launch-codex-specialist.ps1 -TaskId {task_id} -Phase research",
    "-Model {model} -Effort {effort} -PromptFile <path>``.",
    "",
    ('````markdown'),
    $FENCE,
    "& '{{crucible_root}}/powershell/crucible.ps1' -Init -TaskId <task-id> -ProjectRoot '{project_root}'",
    $FENCE,
    '````',
    "",
    "Run ``C:\path\to\crucible-source\powershell\update-bundle.ps1 -FrameworkSource `"C:\path\to\crucible-source`" -AdopterRoot . -Mode report-only``.",
    "",
    ($FENCE + "text"),
    "-> Run crucible.ps1 -Health to check worktree state.",
    $FENCE
) -join "`n"

function Get-PlantedScan {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Body,
        [AllowEmptyCollection()][array]$Allowances = @()
    )
    $rel = "docs/" + $Name + ".md"
    $path = Join-Path $Directory $rel
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [System.IO.File]::WriteAllText($path, $Body + "`n", (New-Object System.Text.UTF8Encoding($false)))
    return @(Get-DocumentedCommandScan -Root $Directory -Documents @($rel) -Shipped $shipped -Allowances $Allowances)
}

$results += Run-Test -Name "MUT: each recorded documented instance, planted, is reported" -Body {
    $tempDir = New-TestFixtureRoot -NameHint "documented-commands-planted"
    try {
        $index = 0
        foreach ($name in $PLANTED_DOCUMENTS.Keys) {
            $index++
            $bound = @(Get-PlantedScan -Directory $tempDir -Name ("planted-" + $index) -Body $PLANTED_DOCUMENTS[$name][0])
            $expected = $PLANTED_DOCUMENTS[$name][1]
            $unbound = @(Get-UnboundDocumentedCommands -Bound $bound)
            $matching = @($unbound | Where-Object { $_.Contains($expected) })
            Assert-Result -Name ("planted " + $name + " reported") -Condition ($unbound.Count -eq 1 -and $matching.Count -eq 1) -FailureMessage (
                "expected one unbound command reporting '" + $expected + "'; got " + $unbound.Count + ": " + ($unbound -join " | "))
        }
    } finally {
        Remove-DocumentedCommandFixture -Path $tempDir
    }
}

$results += Run-Test -Name "MUT: correctly documented commands, placeholders included, bind" -Body {
    $tempDir = New-TestFixtureRoot -NameHint "documented-commands-correct"
    try {
        $bound = @(Get-PlantedScan -Directory $tempDir -Name "correct" -Body $CORRECT_DOCUMENT)
        Assert-Result -Name "every planted command is seen" -Condition ($bound.Count -eq 7) -FailureMessage (
            "expected 7 invocations; got " + $bound.Count + ": " + (($bound | ForEach-Object { $_.Invocation.Text }) -join " | "))
        $unbound = @(Get-UnboundDocumentedCommands -Bound $bound)
        Assert-Result -Name "correct commands bind" -Condition ($unbound.Count -eq 0) -FailureMessage ($unbound -join "`n")
    } finally {
        Remove-DocumentedCommandFixture -Path $tempDir
    }
}

$results += Run-Test -Name "MUT: an allowance excuses its line, and one that excuses nothing is reported" -Body {
    $tempDir = New-TestFixtureRoot -NameHint "documented-commands-allowance"
    try {
        $allowance = @{ RelativePath = "docs/allowed.md"; Pattern = $BARE_INIT; Reason = "a planted sentence that names the entry point" }
        $bound = @(Get-PlantedScan -Directory $tempDir -Name "allowed" -Body "The orchestrator's ``crucible.ps1 -Init`` already ran." -Allowances @($allowance))
        Assert-Result -Name "allowed line excused" -Condition (@(Get-UnboundDocumentedCommands -Bound $bound).Count -eq 0 -and @(Get-StaleDocumentedCommandAllowances -Bound $bound -Allowances @($allowance)).Count -eq 0) -FailureMessage (
            "the allowance did not excuse its line: " + (@(Get-UnboundDocumentedCommands -Bound $bound) -join " | "))
        $fixed = @(Get-PlantedScan -Directory $tempDir -Name "allowed" -Body "The orchestrator's ``crucible.ps1 -Init -ProjectRoot `"{project_root}`"`` already ran." -Allowances @($allowance))
        Assert-Result -Name "stale documented-command allowance reported" -Condition (@(Get-StaleDocumentedCommandAllowances -Bound $fixed -Allowances @($allowance)).Count -eq 1) -FailureMessage (
            "an allowance whose line was fixed still counted as used")
    } finally {
        Remove-DocumentedCommandFixture -Path $tempDir
    }
}

$results += Run-Test -Name "MUT: a tree allowance that matches nothing is reported" -Body {
    $dead = @{ RelativePath = "sops/orchestrator.md"; Pattern = '^crucible\.ps1 -Frobnicate$'; Reason = "a sentence that was rewritten and left its allowance behind" }
    $bound = @(Get-DocumentedCommandScan -Root $BUNDLE_ROOT -Documents $shipped.Markdown -Shipped $shipped -Allowances @($dead))
    Assert-Result -Name "dead tree allowance reported" -Condition (@(Get-StaleDocumentedCommandAllowances -Bound $bound -Allowances @($dead)).Count -eq 1) -FailureMessage "an allowance matching no documented command was not reported"
}

$failedCount = @($results | Where-Object { -not $_ }).Count
if ($failedCount -gt 0) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "`nALL TESTS PASSED ($($results.Count) tests)" -ForegroundColor Green
exit 0
