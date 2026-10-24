# The one builder for a command line Crucible prints for one of its own scripts. Item 247.
#
# Items 207, 208, 218 and 219 (and 125, 126 before them) were printed commands that did not
# work as printed: a wrong path, a value re-split by Start-Process, a dropped -Effort, a
# missing -ProjectRoot. Each was a string literal that nothing compared with the script it
# named. Every printed command now comes from New-CrucibleCommand, which reads the target's
# param block from its AST and binds each parameter to a declared name and kind, applies the
# companion rules, and quotes each value for the transport it names.
# powershell/tests/printed-commands.tests.ps1 fails on a "<script>.ps1 -<Param>" string
# anywhere else in runtime PowerShell. Policy section 8, I15.
#
# A command that cannot be built never costs the surface printing it: by default the builder
# returns "# (command unavailable: <reason>)" in place of the command, so a stop report, a gate
# menu or a refusal still prints and still exits as it would have. -Strict throws instead.

if (-not (Test-Path -Path variable:script:CrucibleCommandParameterCache)) {
    $script:CrucibleCommandParameterCache = @{}
}
if (-not (Get-Command Get-ConfiguredCrucibleRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "config-helpers.ps1")
}

# Parameters that do not work alone. When names the parameter that needs the other one,
# Unless a parameter whose presence lifts the rule.
function Get-CrucibleCommandCompanionRules {
    return @(
        @{ Script = "powershell/crucible.ps1"; When = "Init"; Requires = "ProjectRoot"; Unless = ""
           Reason = "an -Init without -ProjectRoot resolves whichever tree the shell is in (items 119, 125, 126)" },
        @{ Script = "powershell/launch-codex-specialist.ps1"; When = "Model"; Requires = "Effort"; Unless = "Preflight"
           Reason = "a Codex level is a model and an effort together (item 219)" }
    )
}

# The bundle this file ships in: <bundle>/powershell/lib/crucible-command.ps1. Parameters are
# bound against its scripts; a printed path names the project's configured bundle instead.
function Get-CrucibleCommandBundleRoot {
    $libDir = Split-Path -Parent $MyInvocation.MyCommand.ScriptBlock.File
    return (Split-Path -Parent (Split-Path -Parent $libDir))
}

# The bundle a printed command for this project runs: the configured crucible_root under the
# project root. A placeholder or blank root, or a config that cannot be read, prints the
# {crucible_root} placeholder rather than a guessed path.
function Get-CrucibleCommandRoot {
    param([AllowEmptyString()][string]$ProjectRoot = "")
    if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or $ProjectRoot -match '^[{<].*[}>]$') { return "{crucible_root}" }
    try {
        $configured = Get-ConfiguredCrucibleRoot -ProjectRoot $ProjectRoot
    } catch {
        $configured = $null
    }
    if ([string]::IsNullOrWhiteSpace($configured)) { return "{crucible_root}" }
    return $configured
}

# The declared parameters of a bundle script, by name, each with whether it is a switch.
function Get-CrucibleScriptParameters {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [string]$BundleRoot = ""
    )
    if ([string]::IsNullOrEmpty($BundleRoot)) { $BundleRoot = Get-CrucibleCommandBundleRoot }
    $normalized = $Script.Replace("\", "/")
    if ($normalized -notmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*\.ps1$' -or $normalized -match '(^|/)\.\.(/|$)') {
        throw ("New-CrucibleCommand: '" + $Script + "' is not a bundle-relative script path such as powershell/crucible.ps1.")
    }
    $path = Join-Path $BundleRoot $normalized
    $cacheKey = [System.IO.Path]::GetFullPath($path)
    if (-not (Test-Path -Path variable:script:CrucibleCommandParameterCache)) {
        $script:CrucibleCommandParameterCache = @{}
    }
    if ($script:CrucibleCommandParameterCache.ContainsKey($cacheKey)) {
        return $script:CrucibleCommandParameterCache[$cacheKey]
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw ("New-CrucibleCommand: no script " + $normalized + " in the bundle at " + $BundleRoot + ".")
    }
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors -and @($parseErrors).Count -gt 0) {
        throw ("New-CrucibleCommand: " + $normalized + " does not parse: " + $parseErrors[0].Message)
    }
    if ($null -eq $ast.ParamBlock) {
        throw ("New-CrucibleCommand: " + $normalized + " declares no param block, so no parameter can be bound to it.")
    }
    $declared = @{}
    foreach ($p in $ast.ParamBlock.Parameters) {
        $isSwitch = $false
        foreach ($attr in $p.Attributes) {
            if ($attr -is [System.Management.Automation.Language.TypeConstraintAst] -and $attr.TypeName.FullName -in @("switch", "System.Management.Automation.SwitchParameter")) {
                $isSwitch = $true
            }
        }
        $declared[$p.Name.VariablePath.UserPath] = $isSwitch
    }
    $script:CrucibleCommandParameterCache[$cacheKey] = $declared
    return $declared
}

# The companion rules a parameter set breaks, one message each. Shared with the guard test,
# which applies them to every call site without running it.
function Get-CrucibleCommandCompanionProblems {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Names
    )
    $normalized = $Script.Replace("\", "/")
    $problems = @()
    foreach ($rule in (Get-CrucibleCommandCompanionRules)) {
        if ($rule.Script -ne $normalized) { continue }
        if ($Names -notcontains $rule.When) { continue }
        if (-not [string]::IsNullOrEmpty($rule.Unless) -and $Names -contains $rule.Unless) { continue }
        if ($Names -contains $rule.Requires) { continue }
        $problems += ("-" + $rule.When + " needs -" + $rule.Requires + ": " + $rule.Reason)
    }
    return $problems
}

# A literal for a PowerShell 7+ prompt. Doubling every quote its tokenizer accepts carries
# quotes, $, backticks, trailing backslashes and empty strings without native passing.
function ConvertTo-CrucibleCommandPowerShellLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value -eq '--%') {
        throw "New-CrucibleCommand: --% is PowerShell's stop-parsing token even inside quotes; no direct command is available."
    }
    $escaped = $Value
    foreach ($q in @([char]0x27, [char]0x2018, [char]0x2019, [char]0x201A, [char]0x201B)) { $escaped = $escaped.Replace([string]$q, ([string]$q + [string]$q)) }
    return ("'" + $escaped + "'")
}

# A literal shared by Bash and PowerShell, for an agent whose shell is not prescribed.
# Keep the pre-284 native-passing refusals. Single quotes protect dollars and backticks
# in both shells; double quotes carry apostrophes when neither shell expands the value.
# A value with both is written as adjacent segments after a bare first character: both
# shells join them into one argument, but PowerShell splits a word that starts with a
# quote, so a value that cannot start bare has no shared literal. Item 290.
function ConvertTo-CrucibleCommandShellNeutralLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { throw "New-CrucibleCommand: shell-neutral -File has an empty value." }
    if ($Value.Contains('"')) { throw "New-CrucibleCommand: shell-neutral -File cannot carry a double quote on older launching PowerShell hosts." }
    if ($Value.EndsWith('\') -and $Value -match '\s') { throw "New-CrucibleCommand: shell-neutral -File cannot carry whitespace and a trailing backslash on older launching PowerShell hosts." }
    if ($Value -notmatch "['\u2018\u2019\u201A\u201B]") { return ("'" + $Value + "'") }
    if ($Value.EndsWith('\')) {
        throw "New-CrucibleCommand: quotes and a trailing backslash escape the closing double quote in Bash; no shared Bash/PowerShell literal is available."
    }
    if ($Value -notmatch '[$`\u201C\u201D\u201E]' -and -not $Value.Contains('\\')) { return ('"' + $Value + '"') }
    if ($Value -cnotmatch '^[A-Za-z0-9_/]') {
        throw "New-CrucibleCommand: the value combines quotes with shell expansions or doubled backslashes and does not start with a letter, digit, underscore or slash; no shared Bash/PowerShell literal is available."
    }
    $segments = @([regex]::Matches($Value.Substring(1), "['\u2018\u2019\u201A\u201B]+|[^'\u2018\u2019\u201A\u201B]+") | ForEach-Object {
        if ($_.Value -match "^['\u2018\u2019\u201A\u201B]") { '"' + $_.Value + '"' } else { "'" + $_.Value + "'" }
    })
    return ($Value.Substring(0, 1) + ($segments -join ""))
}

# A shell-neutral line that starts a generated script taking no parameters. A caller that
# writes its values into such a script keeps them off the native command line, where lists,
# double quotes and empty values do not survive every launching shell. Item 291.
function New-CrucibleScriptFileCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Strict
    )
    try {
        if ($Path.Contains("`r") -or $Path.Contains("`n") -or $Path.Contains([string][char]0)) {
            throw ("New-CrucibleCommand: the script path contains a line break or NUL, which no quoting puts on one command line: " + $Path)
        }
        return ("pwsh -NoProfile -ExecutionPolicy Bypass -File " + (ConvertTo-CrucibleCommandShellNeutralLiteral -Value $Path))
    } catch {
        if ($Strict) { throw }
        $reason = ($_.Exception.Message -replace '^New-CrucibleCommand: ', '') -replace '[\r\n]+', ' '
        return ("# (command unavailable: " + $reason + ")")
    }
}

# One value as a process command line carries it (Start-Process -ArgumentList, and
# ProcessStartInfo.Arguments on every platform): quoted when it has whitespace or a quote,
# with the backslashes before a quote, and a trailing run of them, doubled.
function ConvertTo-CrucibleCommandNativeArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') {
            [void]$builder.Append([char]92, (2 * $backslashes + 1))
            [void]$builder.Append('"')
        } else {
            if ($backslashes -gt 0) { [void]$builder.Append([char]92, $backslashes) }
            [void]$builder.Append($ch)
        }
        $backslashes = 0
    }
    if ($backslashes -gt 0) { [void]$builder.Append([char]92, (2 * $backslashes)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

# One value as a POSIX shell reads it (an agent's Bash tool; Git Bash on Windows): a bare
# token as is, anything else single-quoted with each ' written as '\''.
function ConvertTo-CrucibleCommandBashLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value -match '^[A-Za-z0-9_./:@%+=,][A-Za-z0-9_./:@%+=,-]*$') { return $Value }
    return ("'" + $Value.Replace("'", "'\''") + "'")
}

# One parameter value for the transport. A placeholder such as <model> prints as given for a
# PowerShell prompt, for a human to replace, and single-quoted for a shell, where < is a
# redirect. A carriage return, newline or NUL cannot appear on one command line. The native
# -File transports also refuse empty values and values beginning with '-', which older
# PowerShell drops or pwsh -File binds as a parameter name.
function Format-CrucibleCommandValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [ValidateSet("PowerShell", "ShellNeutral", "ArgumentList", "Bash")][string]$Transport = "PowerShell",
        [switch]$File
    )
    if ($Value -match '^<[^<>"''`$\r\n]+>$') {
        if ($Transport -eq "ShellNeutral") { return (ConvertTo-CrucibleCommandShellNeutralLiteral -Value $Value) }
        if ($Transport -eq "Bash") { return ("'" + $Value + "'") }
        if ($Value -match '\s') { return ('"' + $Value + '"') }
        return $Value
    }
    if ($Transport -ne "PowerShell" -and [string]::IsNullOrEmpty($Value)) {
        throw ("New-CrucibleCommand: -" + $Name + " has an empty value; omit the parameter or pass a placeholder such as <" + $Name.ToLowerInvariant() + ">.")
    }
    foreach ($bad in @("`r", "`n", [string][char]0)) {
        if ($Value.Contains($bad)) {
            $shown = switch ($bad) { "`r" { "a carriage return" } "`n" { "a newline" } default { "a NUL character" } }
            throw ("New-CrucibleCommand: the value of -" + $Name + " contains " + $shown + ", which no quoting puts on one command line")
        }
    }
    if ($File -and $Value.StartsWith("-")) {
        throw ("New-CrucibleCommand: the value of -" + $Name + " starts with '-', which pwsh -File binds as a parameter name: " + $Value)
    }
    # Git Bash rewrites an argument that looks like a POSIX path before a Windows program sees
    # it, and quoting does not stop it: /tmp, //x, @/x, x=/tmp and x=@/y all arrive changed.
    # Turning the rewrite off (MSYS_NO_PATHCONV) would reach git and the hooks the command
    # starts, which rely on it, so such a value has no Bash line on Windows.
    $onWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    if ($Transport -eq "Bash" -and $onWindows -and ($Value -match '^@?/' -or $Value -match '^\S*=@?/')) {
        throw ("New-CrucibleCommand: the value of -" + $Name + " looks like a POSIX path, which Git Bash rewrites before pwsh sees it: " + $Value)
    }
    if ($Transport -eq "ShellNeutral" -and $onWindows -and ($Value -match '^@?/' -or $Value -match '^\S*=@?/')) {
        throw ("New-CrucibleCommand: the value of -" + $Name + " looks like a POSIX path, which Git Bash rewrites before pwsh sees it: " + $Value)
    }
    if ($Transport -eq "ShellNeutral") { return (ConvertTo-CrucibleCommandShellNeutralLiteral -Value $Value) }
    if ($Transport -eq "ArgumentList") { return (ConvertTo-CrucibleCommandNativeArgument -Value $Value) }
    if ($Transport -eq "Bash") { return (ConvertTo-CrucibleCommandBashLiteral -Value $Value) }
    return (ConvertTo-CrucibleCommandPowerShellLiteral -Value $Value)
}

function New-CrucibleCommand {
    <#
    .SYNOPSIS
        Returns the command line for a Crucible script, bound to that script's param block.
    .DESCRIPTION
        -Script is bundle-relative (powershell/crucible.ps1). -Parameters is ordered: a switch
        takes $true, a list prints comma-joined with each element quoted, anything else is a
        string. -CrucibleRoot roots the path at the bundle the reader runs ("" prints the
        bundle-relative path, for the framework repository).
        -Transport PowerShell (the default) is a direct & '<script>' line for a PowerShell
        7+ prompt. It ignores -Invoker, so callers cannot reintroduce native passing.
        -Transport Bash
        is a line for a POSIX shell (an agent's Bash tool), which starts the script through
        -Invoker, default "pwsh -NoProfile -ExecutionPolicy Bypass -File"; -Transport
        ArgumentList is the argument string for Start-Process -FilePath pwsh -ArgumentList,
        which starts the script with -NoProfile -ExecutionPolicy Bypass -File.
        -Transport ShellNeutral is for agent-executed instructions without a prescribed
        shell: it starts pwsh -File from Bash or PowerShell (including a 5.1 launching
        shell) and retains the older hosts' native-passing refusals. It takes no -Invoker
        and no lists; a caller with lists writes the direct form into a generated script
        and prints New-CrucibleScriptFileCommand for it.
        -Reference prints only the script's file name for prose that names a parameter rather
        than a line to run; the parameters are still bound, the companion rules are not applied.
        A command that cannot be built returns "# (command unavailable: <reason>)", a comment
        in both shells, so a line that is executed rather than read does nothing; -Strict throws.
    #>
    [CmdletBinding(DefaultParameterSetName = "Command")]
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [System.Collections.Specialized.OrderedDictionary]$Parameters = $null,
        [Parameter(Mandatory = $true, ParameterSetName = "Command")][AllowEmptyString()][string]$CrucibleRoot,
        [Parameter(ParameterSetName = "Command")][string]$Invoker = "",
        [Parameter(ParameterSetName = "Command")][ValidateSet("PowerShell", "ShellNeutral", "ArgumentList", "Bash")][string]$Transport = "PowerShell",
        [Parameter(Mandatory = $true, ParameterSetName = "Reference")][switch]$Reference,
        [string]$BundleRoot = "",
        [switch]$Strict
    )

    try {
        if ($null -eq $Parameters) { $Parameters = [ordered]@{} }
        $normalized = $Script.Replace("\", "/")
        $declared = Get-CrucibleScriptParameters -Script $normalized -BundleRoot $BundleRoot
        $isReference = ($PSCmdlet.ParameterSetName -eq "Reference")
        if (-not $isReference -and $Transport -in @("ArgumentList", "ShellNeutral") -and -not [string]::IsNullOrEmpty($Invoker)) {
            throw ("New-CrucibleCommand: -Transport " + $Transport + " supplies its own pwsh arguments; it takes no -Invoker.")
        }
        if (-not $isReference -and $Transport -eq "Bash" -and [string]::IsNullOrEmpty($Invoker)) { $Invoker = "pwsh -NoProfile -ExecutionPolicy Bypass -File" }
        $viaFile = (-not $isReference) -and ($Transport -in @("ArgumentList", "Bash", "ShellNeutral"))
        $valueTransport = if ($isReference) { "PowerShell" } else { $Transport }

        $names = @()
        $parts = @()
        foreach ($key in $Parameters.Keys) {
            $name = [string]$key
            if (-not $declared.ContainsKey($name)) {
                throw ("New-CrucibleCommand: " + $normalized + " declares no parameter -" + $name + ". Its parameters: " + ((@($declared.Keys) | Sort-Object | ForEach-Object { "-" + $_ }) -join ", "))
            }
            $value = $Parameters[$key]
            if ($declared[$name]) {
                if ($value -isnot [bool] -or -not $value) {
                    throw ("New-CrucibleCommand: -" + $name + " is a switch of " + $normalized + "; pass `$true, or omit it.")
                }
                $parts += ("-" + $name)
            } else {
                if ($null -eq $value -or $value -is [bool] -or $value -is [switch]) {
                    throw ("New-CrucibleCommand: -" + $name + " of " + $normalized + " takes a value, not a switch.")
                }
                if ($value -is [array]) {
                    if ($viaFile) {
                        throw ("New-CrucibleCommand: -" + $name + " is a list; pwsh -File accepts only scalar arguments. Use a direct PowerShell invocation for lists.")
                    }
                    $items = @($value)
                    if ($items.Count -eq 0) {
                        throw ("New-CrucibleCommand: -" + $name + " has an empty list; omit the parameter.")
                    }
                    $formatted = @(foreach ($item in $items) {
                        $f = Format-CrucibleCommandValue -Name $name -Value ([string]$item) -Transport $valueTransport
                        if ($f.StartsWith('"') -or $f.StartsWith("'")) { $f } else { '"' + $f + '"' }
                    })
                    $parts += ("-" + $name + " " + ($formatted -join ","))
                } else {
                    $parts += ("-" + $name + " " + (Format-CrucibleCommandValue -Name $name -Value ([string]$value) -Transport $valueTransport -File:$viaFile))
                }
            }
            $names += $name
        }

        $leaf = Split-Path -Leaf $normalized
        if ($isReference) {
            return ((@($leaf) + $parts) -join " ")
        }

        $problems = @(Get-CrucibleCommandCompanionProblems -Script $normalized -Names $names)
        if ($problems.Count -gt 0) {
            throw ("New-CrucibleCommand: " + $normalized + " " + ($problems -join "; "))
        }

        $path = $normalized
        if (-not [string]::IsNullOrEmpty($CrucibleRoot)) {
            $root = $CrucibleRoot.TrimEnd("/", "\")
            if ($root.Contains("\")) {
                $path = $root + "\" + $normalized.Replace("/", "\")
            } else {
                $path = $root + "/" + $normalized
            }
        }
        if ($path.Contains("`r") -or $path.Contains("`n") -or $path.Contains([string][char]0)) {
            throw ("New-CrucibleCommand: the script path contains a line break or NUL, which no quoting puts on one command line: " + $path)
        }
        if ($Transport -eq "ShellNeutral") {
            $head = New-CrucibleScriptFileCommand -Path $path -Strict
        } elseif ($Transport -eq "ArgumentList") {
            $head = "-NoProfile -ExecutionPolicy Bypass -File " + (ConvertTo-CrucibleCommandNativeArgument -Value $path)
        } elseif ($Transport -eq "Bash") {
            $head = $Invoker.Trim() + " " + (ConvertTo-CrucibleCommandBashLiteral -Value $path)
        } else {
            $head = "& " + (ConvertTo-CrucibleCommandPowerShellLiteral -Value $path)
        }
        return ((@($head) + $parts) -join " ")
    } catch {
        if ($Strict) { throw }
        $reason = ($_.Exception.Message -replace '^New-CrucibleCommand: ', '') -replace '[\r\n]+', ' '
        return ("# (command unavailable: " + $reason + ")")
    }
}
