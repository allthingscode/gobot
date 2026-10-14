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

function Get-AffectedTestFiles {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [string]$Base = 'HEAD'
    )

    $changedPaths = @(Get-TestSelectionChangedPaths -Root $Root -Base $Base)
    $tests = @(Get-ChildItem -LiteralPath (Join-Path $Root 'powershell/tests') -Filter '*.tests.ps1' -File | Sort-Object Name)
    $texts = @{}
    $reasons = @{}
    foreach ($test in $tests) {
        $texts[$test.FullName] = [System.IO.File]::ReadAllText($test.FullName)
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
            $newText = if (Test-Path -LiteralPath $fullPath -PathType Leaf) { [System.IO.File]::ReadAllText($fullPath) } else { '' }
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
