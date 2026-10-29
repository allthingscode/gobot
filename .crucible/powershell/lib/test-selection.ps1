if (-not (Get-Command Resolve-FilesystemPath -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "config-helpers.ps1") }

. (Join-Path $PSScriptRoot 'platform.ps1')

# Paths stay relative to the runner's parent, including when that is an adopter's
# .crucible directory rather than the git root. TODO item 201.
function Get-TestSelectionChangedPaths {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [string]$Base = 'HEAD'
    )

    $diff = Invoke-Git -Directory $Root -GitArgs @('diff', '--name-only', '--relative', $Base, '--', '.')
    if ($diff.ExitCode -ne 0) { throw "Cannot select tests: git diff against '$Base' failed in $Root." }
    $untracked = Invoke-Git -Directory $Root -GitArgs @('ls-files', '--others', '--exclude-standard')
    if ($untracked.ExitCode -ne 0) { throw "Cannot select tests: git ls-files failed in $Root." }
    @($diff.Lines) + @($untracked.Lines) | Where-Object { $_ } | Sort-Object -Unique
}

# Only direct path arguments and inline joins identify directory readers.
# Variables are not followed: assigning a directory then enumerating the variable
# is deliberately not detected. Wildcard path literals count anywhere. TODO item 201.
function Get-TestSelectionDirectoryPatterns {
    param([string]$Root, [string]$Text)

    $Root = Resolve-FilesystemPath -Path $Root
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
    $strings = $ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        ($node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $node.NestedExpressions.Count -eq 0)
    }, $true)
    foreach ($literal in $strings) {
        $value = $literal.Value.Replace('\', '/')
        if ($value -notmatch '^[a-zA-Z0-9_./*?\[\] -]+$' -or [System.IO.Path]::IsPathRooted($value)) { continue }
        if ($literal.Parent -is [System.Management.Automation.Language.CommandAst] -and
            $literal.Parent.CommandElements[0] -eq $literal) { continue }
        $base = $Root
        $argument = $literal
        $parent = $literal.Parent
        if ($parent -is [System.Management.Automation.Language.CommandAst] -and $parent.GetCommandName() -eq 'Join-Path') {
            $joinElements = $parent.CommandElements
            $joinIndex = $joinElements.IndexOf($literal)
            # A literal base plus a literal child describes one joined path, not
            # an independent directory reader for the base.
            if ($joinElements.Count -eq 3 -and
                $joinElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                if ($joinIndex -eq 1 -and $value -notmatch '[*?\[]') { continue }
                if ($joinIndex -eq 2) { $value = $joinElements[1].Value.Replace('\', '/') + '/' + $value }
            }
            if ($parent.Extent.Text -match '\$PSScriptRoot\b') {
                $base = Join-Path $Root 'powershell/tests'
            }
            $argument = $parent
            $parent = $parent.Parent
            # Only expression wrappers may connect an inline join to its reader.
            # Do not walk through assignments, script blocks, or other commands.
            while ($parent -is [System.Management.Automation.Language.PipelineAst] -or
                   $parent -is [System.Management.Automation.Language.CommandExpressionAst] -or
                   $parent -is [System.Management.Automation.Language.ParenExpressionAst]) {
                $argument = $parent
                $parent = $parent.Parent
            }
        }
        $reader = $null
        if ($parent -is [System.Management.Automation.Language.CommandParameterAst] -and
            $parent.ParameterName -in @('Path', 'LiteralPath')) {
            $argument = $parent
            $parent = $parent.Parent
        }
        if ($parent -is [System.Management.Automation.Language.CommandAst] -and
            $parent.GetCommandName() -in @('Get-ChildItem', 'gci', 'ls', 'dir')) {
            $elements = $parent.CommandElements
            $index = $elements.IndexOf($argument)
            if ($index -eq 1 -or ($index -gt 1 -and
                $elements[$index - 1] -is [System.Management.Automation.Language.CommandParameterAst] -and
                $elements[$index - 1].ParameterName -in @('Path', 'LiteralPath')) -or
                ($argument -is [System.Management.Automation.Language.CommandParameterAst] -and
                $argument.ParameterName -in @('Path', 'LiteralPath'))) {
                $reader = $parent
            }
        } elseif ($parent -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                  $parent.Static -and $parent.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
                  $parent.Expression.TypeName.FullName -in @('IO.Directory', 'System.IO.Directory') -and
                  $parent.Member.Value -in @('GetFiles', 'EnumerateFiles', 'GetDirectories') -and
                  $parent.Arguments[0] -eq $argument) {
            $reader = $parent
        }
        # Wildcard literals already encode the directory and pattern, including
        # paths passed to Get-Item, Resolve-Path, Test-Path, and Get-Content.
        if ($value -notmatch '[*?\[]' -and -not $reader) { continue }
        $pattern = '*'
        $directory = $value
        if ($value -match '[*?\[]') {
            $slash = $value.LastIndexOf('/')
            if ($slash -lt 0) {
                if ($argument -eq $literal) { continue }
                $directory = '.'
                $pattern = $value
            } else {
                $directory = $value.Substring(0, $slash)
                $pattern = $value.Substring($slash + 1)
            }
        }
        $fullDirectory = [System.IO.Path]::GetFullPath((Join-Path $base $directory))
        $relative = [System.IO.Path]::GetRelativePath($Root, $fullDirectory).Replace('\', '/')
        if ($relative -eq '.' -or $relative -eq '..' -or $relative.StartsWith('../')) { continue }
        if ($pattern -eq '*' -and $reader) {
            if ($reader -is [System.Management.Automation.Language.CommandAst] -and
                $reader.Extent.Text -match '-(?:Filter|Include)\s+([''"])([^''"$\r\n]+)\1(?!\s*,)') {
                $pattern = $Matches[2]
            } elseif ($reader -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                      $reader.Arguments.Count -gt 1 -and
                      $reader.Arguments[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $pattern = $reader.Arguments[1].Value
            }
        }
        [pscustomobject]@{ Directory = $relative; Pattern = $pattern }
    }
}

function Get-AffectedTestFiles {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [string]$Base = 'HEAD'
    )

    $Root = Resolve-FilesystemPath -Path $Root
    $changedPaths = @(Get-TestSelectionChangedPaths -Root $Root -Base $Base)
    $tests = @(Get-ChildItem -LiteralPath (Join-Path $Root 'powershell/tests') -Filter '*.tests.ps1' -File | Sort-Object Name)
    $texts = @{}
    $reasons = @{}
    $directoryPatterns = @{}
    foreach ($test in $tests) {
        $texts[$test.FullName] = [System.IO.File]::ReadAllText((Resolve-FilesystemPath -Path $test.FullName))
        $directoryPatterns[$test.FullName] = @(Get-TestSelectionDirectoryPatterns -Root $Root -Text $texts[$test.FullName])
        $reasons[$test.FullName] = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($path in $changedPaths) {
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $Root $path))
        $leaf = Split-Path -Leaf $path
        $functions = @()
        if ($path -like '*.ps1') {
            $diff = Invoke-Git -Directory $Root -GitArgs @('diff', '--no-ext-diff', '--no-textconv', '--relative', '-U0', $Base, '--', $path)
            if ($diff.ExitCode -ne 0) { throw "Cannot select tests: git diff failed for $path." }
            $hunks = @()
            foreach ($line in $diff.Lines) {
                if ($line -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@') {
                    $hunks += [pscustomobject]@{
                        OldStart = [int]$Matches[1]
                        OldCount = if ($Matches.ContainsKey(2)) { [int]$Matches[2] } else { 1 }
                        NewStart = [int]$Matches[3]
                        NewCount = if ($Matches.ContainsKey(4)) { [int]$Matches[4] } else { 1 }
                    }
                }
            }

            # git show's ./ form resolves from -C, so deleted functions in a bundle
            # use the same relative path as the new-side AST. TODO item 201.
            $basePath = "$($Base):./$path"
            $exists = Invoke-Git -Directory $Root -GitArgs @('cat-file', '-e', $basePath)
            $oldText = ''
            if ($exists.ExitCode -eq 0) {
                $old = Invoke-Git -Directory $Root -GitArgs @('show', $basePath)
                if ($old.ExitCode -ne 0) { throw "Cannot select tests: git show failed for $path." }
                $oldText = $old.Raw
            }
            $newText = if (Test-Path -LiteralPath $fullPath -PathType Leaf) { [System.IO.File]::ReadAllText((Resolve-FilesystemPath -Path $fullPath)) } else { '' }
            if ($exists.ExitCode -ne 0 -and $newText -and $hunks.Count -eq 0) {
                $hunks += [pscustomobject]@{ OldStart = 0; OldCount = 0; NewStart = 1; NewCount = ($newText -split "`n").Count }
            }
            foreach ($side in @(
                @{ Text = $oldText; Start = 'OldStart'; Count = 'OldCount' },
                @{ Text = $newText; Start = 'NewStart'; Count = 'NewCount' }
            )) {
                $ast = [System.Management.Automation.Language.Parser]::ParseInput($side.Text, [ref]$null, [ref]$null)
                $definitions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
                foreach ($definition in $definitions) {
                    foreach ($hunk in $hunks) {
                        $start = $hunk.($side.Start)
                        $count = $hunk.($side.Count)
                        # A zero-length side is an insertion/deletion boundary, not
                        # a changed line in the adjacent function. TODO item 201.
                        if ($count -gt 0 -and $start -le $definition.Extent.EndLineNumber -and ($start + $count - 1) -ge $definition.Extent.StartLineNumber) {
                            $functions += $definition.Name
                            break
                        }
                    }
                }
            }
            $functions = @($functions | Sort-Object -Unique)
        }

        foreach ($test in $tests) {
            $testReasons = $reasons[$test.FullName]
            if ($test.FullName -eq $fullPath) { $testReasons.Add("changed test: $path") }
            if ($texts[$test.FullName].IndexOf($leaf, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $testReasons.Add("mentions file $leaf (changed: $path)")
            }
            foreach ($reader in $directoryPatterns[$test.FullName]) {
                $normalized = $path.Replace('\', '/')
                if ($normalized.StartsWith($reader.Directory + '/', [System.StringComparison]::OrdinalIgnoreCase) -and $leaf -like $reader.Pattern) {
                    $testReasons.Add("reads directory $($reader.Directory) pattern $($reader.Pattern) (changed: $path)")
                }
            }
            foreach ($function in $functions) {
                if ($texts[$test.FullName] -match ('\b' + [regex]::Escape($function) + '\b')) {
                    $testReasons.Add("mentions function $function (changed: $path)")
                }
            }
        }
    }

    foreach ($test in $tests) {
        if ($reasons[$test.FullName].Count -gt 0) {
            [pscustomobject]@{ File = $test; Reasons = @($reasons[$test.FullName] | Sort-Object -Unique) }
        }
    }
}
