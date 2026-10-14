# Selection is deliberately textual: exercise real git hunks and child runs so a
# green result proves which files ran, including deleted functions. TODO item 201.
$ErrorActionPreference = 'Stop'
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/platform.ps1')
$selector = Join-Path $REPO_ROOT 'powershell/lib/test-selection.ps1'
if (Test-Path -LiteralPath $selector) { . $selector }
$results = @()

function Write-SelectionFile {
    param([string]$Root, [string]$Path, [string]$Text)
    $fullPath = Join-Path $Root $Path
    New-Item -ItemType Directory -Path (Split-Path -Parent $fullPath) -Force | Out-Null
    [System.IO.File]::WriteAllText($fullPath, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-SelectionGit {
    param([string]$Root, [string[]]$GitArgs)
    $r = Invoke-Git -Directory $Root -GitArgs $GitArgs
    if ($r.ExitCode -ne 0) { throw "Fixture git failed: $($GitArgs -join ' ')" }
    return $r.Raw
}

$sourceText = @'
function Get-Alpha {
    'alpha'
}
function Get-Beta {
    'beta'
}
'@
$sourceText += "`n"

function New-SelectionFixture {
    param([switch]$Adopter)
    $repo = New-TestFixtureRoot -NameHint 'selection'
    $root = if ($Adopter) { Join-Path $repo '.crucible' } else { $repo }
    Write-SelectionFile $root 'powershell/source.ps1' $sourceText
    Write-SelectionFile $root 'powershell/helper.ps1' "'helper'`n"
    Write-SelectionFile $root 'prompts/deployment_prompt.md' "first`n"
    Write-SelectionFile $root 'powershell/tests/alpha.tests.ps1' '# Get-Alpha'
    Write-SelectionFile $root 'powershell/tests/beta.tests.ps1' '# Get-Beta'
    Write-SelectionFile $root 'powershell/tests/helper.tests.ps1' '# helper.ps1'
    Write-SelectionFile $root 'powershell/tests/substring.tests.ps1' '# Get-AlphaExtra'
    Write-SelectionFile $root 'powershell/tests/prompt.tests.ps1' '# deployment_prompt.md'
    $null = Invoke-SelectionGit $repo @('init', '--quiet')
    $null = Invoke-SelectionGit $repo @('add', '-A')
    $null = Invoke-SelectionGit $repo @('commit', '--quiet', '-m', 'fixture')
    return $root
}

function Assert-Selection {
    param([object[]]$Selected, [string[]]$Names)
    $actual = @($Selected | ForEach-Object { $_.File.Name }) -join ','
    Assert-Result -Name 'exact selected files in name order' -Condition ($actual -eq ($Names -join ',')) -FailureMessage "expected '$($Names -join ',')', got '$actual'"
}

function Stage-SelectionRunner {
    $root = New-TestFixtureRoot -NameHint 'selection-runner'
    $psDir = Join-Path $root 'powershell'
    $testsDir = Join-Path $psDir 'tests'
    $libDir = Join-Path $psDir 'lib'
    New-Item -ItemType Directory -Path $testsDir, $libDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $REPO_ROOT 'powershell/run-all-tests.ps1') -Destination $psDir
    Copy-Item -Path (Join-Path $PSScriptRoot '_*.ps1') -Destination $testsDir
    foreach ($lib in @('run-lock.ps1', 'normalized-hash.ps1', 'platform.ps1', 'test-selection.ps1')) {
        $path = Join-Path $REPO_ROOT "powershell/lib/$lib"
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $libDir }
    }
    Write-SelectionFile $root 'powershell/tests/_fixtures.ps1' 'function Get-SharedAdopterFixture { return $null }'
    Write-SelectionFile $root 'powershell/source.ps1' $sourceText
    foreach ($name in @('alpha', 'beta')) {
        $text = @"
# Get-$name
[System.IO.File]::WriteAllText((Join-Path `$PSScriptRoot '$name.ran'), 'ran')
Write-Host 'PASSED'
"@
        Write-SelectionFile $root "powershell/tests/$name.tests.ps1" $text
    }
    Write-SelectionFile $root '.gitignore' "*.ran`n"
    $null = Invoke-SelectionGit $root @('init', '--quiet')
    $null = Invoke-SelectionGit $root @('add', '-A')
    $null = Invoke-SelectionGit $root @('commit', '--quiet', '-m', 'fixture')
    return $root
}

function Invoke-SelectionRunner {
    param([string]$Root, [string[]]$RunnerArgs)
    $out = @(& (Get-PwshCommand) -NoProfile -File (Join-Path $Root 'powershell/run-all-tests.ps1') @RunnerArgs 2>&1)
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out -join "`n" }
}

$results += Run-Test -Name 'An edit inside one function selects only its whole-word test' -Body {
    $root = New-SelectionFixture
    Write-SelectionFile $root 'powershell/source.ps1' ($sourceText.Replace("'alpha'", "'changed'"))
    $selected = @(Get-AffectedTestFiles -Root $root)
    Assert-Selection $selected @('alpha.tests.ps1')
    Assert-Result -Name 'reason names function and source' -Condition (($selected[0].Reasons -join '; ') -match 'Get-Alpha.*source.ps1') -FailureMessage ($selected[0].Reasons -join '; ')
}

$results += Run-Test -Name 'A deleted function selects its test using the old AST' -Body {
    $root = New-SelectionFixture
    Write-SelectionFile $root 'powershell/source.ps1' "function Get-Beta {`n    'beta'`n}`n"
    Assert-Selection @(Get-AffectedTestFiles -Root $root) @('alpha.tests.ps1')
}

$results += Run-Test -Name 'Deleting a source file selects both old functions' -Body {
    $root = New-SelectionFixture
    Remove-Item -LiteralPath (Join-Path $root 'powershell/source.ps1')
    Assert-Selection @(Get-AffectedTestFiles -Root $root) @('alpha.tests.ps1', 'beta.tests.ps1')
}

$results += Run-Test -Name 'Renaming a function selects tests for both its old and new names' -Body {
    $root = New-SelectionFixture
    Write-SelectionFile $root 'powershell/source.ps1' ($sourceText.Replace('Get-Alpha', 'Get-AlphaExtra'))
    Assert-Selection @(Get-AffectedTestFiles -Root $root) @('alpha.tests.ps1', 'substring.tests.ps1')
}

$results += Run-Test -Name 'Inserting between functions does not touch either function' -Body {
    $root = New-SelectionFixture
    Write-SelectionFile $root 'powershell/source.ps1' ($sourceText.Replace('function Get-Beta', "# outside functions`nfunction Get-Beta"))
    Assert-Selection @(Get-AffectedTestFiles -Root $root) @()
}

foreach ($case in @(
    @{ Path = 'powershell/helper.ps1'; Name = 'helper.tests.ps1' },
    @{ Path = 'prompts/deployment_prompt.md'; Name = 'prompt.tests.ps1' }
)) {
    $results += Run-Test -Name ("Changing $($case.Path) selects its leaf-name test") -Body {
        $root = New-SelectionFixture
        Write-SelectionFile $root $case.Path "changed`n"
        $selected = @(Get-AffectedTestFiles -Root $root)
        Assert-Selection $selected @($case.Name)
        Assert-Result -Name 'reason names changed path' -Condition (($selected[0].Reasons -join '; ').Contains($case.Path)) -FailureMessage ($selected[0].Reasons -join '; ')
    }
}

$results += Run-Test -Name 'A new test selects itself and deleted tests are skipped' -Body {
    $root = New-SelectionFixture
    Write-SelectionFile $root 'powershell/tests/new.tests.ps1' '# new test'
    Remove-Item -LiteralPath (Join-Path $root 'powershell/tests/beta.tests.ps1')
    Assert-Selection @(Get-AffectedTestFiles -Root $root) @('new.tests.ps1')
}

$results += Run-Test -Name 'A new source selects tests mentioning its functions' -Body {
    $root = New-SelectionFixture
    Write-SelectionFile $root 'powershell/new.ps1' 'function Get-Alpha { return 1 }'
    Assert-Selection @(Get-AffectedTestFiles -Root $root) @('alpha.tests.ps1')
}

$results += Run-Test -Name 'No changes select nothing' -Body {
    $root = New-SelectionFixture
    Assert-Selection @(Get-AffectedTestFiles -Root $root) @()
}

$results += Run-Test -Name 'Selection preserves all reasons without duplicate files' -Body {
    $root = New-SelectionFixture
    Write-SelectionFile $root 'powershell/tests/alpha.tests.ps1' '# Get-Alpha and source.ps1'
    Write-SelectionFile $root 'powershell/source.ps1' ($sourceText.Replace("'alpha'", "'changed'"))
    $selected = @(Get-AffectedTestFiles -Root $root)
    Assert-Selection $selected @('alpha.tests.ps1')
    Assert-Result -Name 'self, leaf, and function reasons retained' -Condition ($selected[0].Reasons.Count -eq 3) -FailureMessage ($selected[0].Reasons -join '; ')
}

$results += Run-Test -Name 'An explicit base includes committed changes as well as staged edits' -Body {
    $root = New-SelectionFixture
    $base = Invoke-SelectionGit $root @('rev-parse', 'HEAD')
    Write-SelectionFile $root 'powershell/source.ps1' ($sourceText.Replace("'alpha'", "'changed'"))
    $null = Invoke-SelectionGit $root @('add', '-A')
    $null = Invoke-SelectionGit $root @('commit', '--quiet', '-m', 'change')
    Write-SelectionFile $root 'powershell/helper.ps1' "changed`n"
    $null = Invoke-SelectionGit $root @('add', '-A')
    Assert-Selection @(Get-AffectedTestFiles -Root $root -Base $base) @('alpha.tests.ps1', 'helper.tests.ps1')
}

$results += Run-Test -Name 'Adopter paths are bundle-relative on both sides of the diff' -Body {
    $root = New-SelectionFixture -Adopter
    Write-SelectionFile $root 'powershell/source.ps1' "function Get-Beta {`n    'beta'`n}`n"
    Write-SelectionFile $root 'powershell/tests/new.tests.ps1' '# new'
    Write-SelectionFile (Split-Path -Parent $root) 'outside.ps1' 'function Get-Beta { }'
    Assert-Selection @(Get-AffectedTestFiles -Root $root) @('alpha.tests.ps1', 'new.tests.ps1')
    Assert-Result -Name 'changed paths exclude project files' -Condition (@(Get-TestSelectionChangedPaths -Root $root) -notcontains 'outside.ps1') -FailureMessage 'project file leaked into bundle selection'
}

$results += Run-Test -Name 'An invalid base fails selection instead of reporting no changes' -Body {
    $root = New-SelectionFixture
    $message = ''
    try { $null = Get-AffectedTestFiles -Root $root -Base 'missing-ref' } catch { $message = $_.Exception.Message }
    Assert-Result -Name 'git error is surfaced' -Condition ($message -match 'git diff') -FailureMessage "expected git diff failure, got: $message"
}

foreach ($mode in @('parallel', 'serial', 'base', 'failure', 'marker', 'bad-marker')) {
    $results += Run-Test -Name ("Changed runner executes only the selected synthetic test ($mode)") -Body {
        $root = Stage-SelectionRunner
        $argsForRunner = @('-Changed', '-ThrottleLimit', '2')
        if ($mode -eq 'serial') { $argsForRunner += '-Serial' }
        if ($mode -eq 'base') { $argsForRunner = @('-Base', 'HEAD', '-ThrottleLimit', '2') }
        if ($mode -eq 'failure') {
            Write-SelectionFile $root 'powershell/tests/alpha.tests.ps1' "# Get-Alpha`nWrite-Host 'FAILED: synthetic'`n"
        }
        if ($mode -eq 'marker') {
            $path = Join-Path $root 'powershell/tests/alpha.tests.ps1'
            Write-SelectionFile $root 'powershell/tests/alpha.tests.ps1' ("# crucible-test: serial - synthetic worker`n" + [System.IO.File]::ReadAllText($path))
        }
        if ($mode -eq 'bad-marker') {
            Write-SelectionFile $root 'powershell/tests/alpha.tests.ps1' "# crucible-test: serial`n# Get-Alpha`nthrow 'must not run'`n"
        }
        Write-SelectionFile $root 'powershell/source.ps1' ($sourceText.Replace("'alpha'", "'changed'"))
        $r = Invoke-SelectionRunner $root $argsForRunner
        $expectedExit = if ($mode -in @('failure', 'bad-marker')) { 1 } else { 0 }
        Assert-Result -Name 'expected exit code' -Condition ($r.ExitCode -eq $expectedExit) -FailureMessage $r.Output
        Assert-Result -Name 'unselected file never runs' -Condition (-not (Test-Path -LiteralPath (Join-Path $root 'powershell/tests/beta.ran'))) -FailureMessage $r.Output
        if ($mode -notin @('failure', 'bad-marker')) {
            Assert-Result -Name 'selected file actually runs' -Condition (Test-Path -LiteralPath (Join-Path $root 'powershell/tests/alpha.ran')) -FailureMessage $r.Output
            Assert-Result -Name 'summary counts one file' -Condition ($r.Output -match 'Passed: 1') -FailureMessage $r.Output
        }
        if ($mode -eq 'marker') { Assert-Result -Name 'selected marker runs serially' -Condition ($r.Output -match 'SERIAL alpha.tests.ps1 - synthetic worker') -FailureMessage $r.Output }
        if ($mode -eq 'bad-marker') { Assert-Result -Name 'bad marker fails preflight' -Condition ($r.Output -match 'serial marker gives no reason') -FailureMessage $r.Output }
        Assert-Result -Name 'selection reason printed' -Condition ($r.Output -match 'SELECT alpha.tests.ps1.*Get-Alpha') -FailureMessage $r.Output
        Assert-Result -Name 'last line requires full suite before commit' -Condition (($r.Output.Trim() -split "`r?`n")[-1] -match 'Partial run.*full suite.*before committing') -FailureMessage $r.Output
    }
}

foreach ($change in @($false, $true)) {
    $results += Run-Test -Name ("Changed runner exits zero without starting tests when none are selected (changed=$change)") -Body {
        $root = Stage-SelectionRunner
        if ($change) { Write-SelectionFile $root 'unrelated.txt' 'new file' }
        $r = Invoke-SelectionRunner $root @('-Changed')
        Assert-Result -Name 'empty selection succeeds' -Condition ($r.ExitCode -eq 0) -FailureMessage $r.Output
        Assert-Result -Name 'explains empty selection' -Condition ($r.Output -match 'No affected test files selected') -FailureMessage $r.Output
        if ($change) { Assert-Result -Name 'names changed file' -Condition ($r.Output -match 'unrelated.txt') -FailureMessage $r.Output }
        Assert-Result -Name 'no synthetic test runs' -Condition (@(Get-ChildItem (Join-Path $root 'powershell/tests') -Filter '*.ran').Count -eq 0) -FailureMessage $r.Output
        Assert-Result -Name 'last line requires full suite before commit' -Condition (($r.Output.Trim() -split "`r?`n")[-1] -match 'Partial run.*full suite.*before committing') -FailureMessage $r.Output
    }
}

$results += Run-Test -Name 'Changed runner reports an invalid base and ends with the partial-run reminder' -Body {
    $root = Stage-SelectionRunner
    $r = Invoke-SelectionRunner $root @('-Base', 'missing-ref')
    Assert-Result -Name 'invalid base fails' -Condition ($r.ExitCode -eq 1 -and $r.Output -match 'git diff') -FailureMessage $r.Output
    Assert-Result -Name 'no synthetic test runs' -Condition (@(Get-ChildItem (Join-Path $root 'powershell/tests') -Filter '*.ran').Count -eq 0) -FailureMessage $r.Output
    Assert-Result -Name 'last line requires full suite before commit' -Condition (($r.Output.Trim() -split "`r?`n")[-1] -match 'Partial run.*full suite.*before committing') -FailureMessage $r.Output
}

Write-TestFileSummary -Results $results
