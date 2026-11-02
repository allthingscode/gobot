# Item 355: a local helper's presence is a function-table lookup, never command discovery.
# Get-Command on a missing name searches modules and every executable PATH entry; on WSL's
# inherited Windows PATH each miss took about 1.4s. Production code asks the Function:
# drive instead. Get-Command stays for genuine external tools (git, gh, the configured
# editor), so the scan below separates the two shapes rather than banning the cmdlet.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/repo-scan.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/install-manifest.ps1")

$results = @()

# Get-Command calls whose name is computed at run time. Each resolves an external tool, so
# the name cannot be checked as a literal; any new dynamic site must be reviewed and listed.
# A call restricted with -CommandType Application is external by construction and needs no entry.
$EXTERNAL_DISCOVERY_ALLOWLIST = @(
    @{ RelativePath = "powershell/crucible-doctor.ps1"; NameText = '$Command'; Reason = "Invoke-ToolCheck probes an external executable before running it." },
    @{ RelativePath = "powershell/crucible-doctor.ps1"; NameText = '$pwshName'; Reason = "Resolves the PowerShell host executable Get-PwshCommand names." },
    @{ RelativePath = "powershell/crucible-doctor.ps1"; NameText = '$tool'; Reason = "Resolves configured verification tools on PATH." },
    @{ RelativePath = "powershell/lib/config-helpers.ps1"; NameText = '$EditorOrToolName'; Reason = "Resolves the configured editor or tool command." }
)

$GET_COMMAND_NAMES = @('Get-Command', 'gcm', 'Microsoft.PowerShell.Core\Get-Command')

function New-ScanEntry {
    param(
        [Parameter(Mandatory = $true)][string]$FullName,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    return [pscustomobject]@{ FullName = $FullName; RelativePath = $RelativePath }
}

function Get-ProductionPs1Files {
    param([string]$RepoRoot)
    return @(Get-RepoScannableFile -RepoRoot $RepoRoot -Extension ".ps1" -ExcludePrefix @("powershell/tests", "examples", "vendor"))
}

function Get-ParsedScript {
    param([Parameter(Mandatory = $true)][string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw ("parse failed for " + $Path + ": " + $errors[0].Message) }
    return $ast
}

function Get-DefinedFunctionNames {
    param([array]$Files)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $Files) {
        $ast = Get-ParsedScript -Path $f.FullName
        foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            [void]$names.Add($fn.Name)
        }
    }
    return , $names
}

# The name arguments of one Get-Command call, plus whether it was restricted to applications.
# Bound against the cmdlet's real metadata, so switches (-Verbose, -All), abbreviations and
# aliases cannot shift which element is taken as the name.
function Get-GetCommandNameArgument {
    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.CommandAst]$Command)
    $binding = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($Command, $true)
    $nameAsts = @()
    if ($binding.BoundParameters.ContainsKey('Name')) {
        $value = $binding.BoundParameters['Name'].Value
        $nameAsts = if ($value -is [System.Management.Automation.Language.ArrayLiteralAst]) { @($value.Elements) } else { @($value) }
    }
    $applicationOnly = $false
    if ($binding.BoundParameters.ContainsKey('CommandType')) {
        $typeAst = $binding.BoundParameters['CommandType'].Value
        $applicationOnly = $typeAst -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $typeAst.Value -eq 'Application'
    }
    return [pscustomobject]@{ NameAsts = $nameAsts; ApplicationOnly = $applicationOnly }
}

function Find-LocalHelperDiscoveryViolation {
    param(
        [array]$Files,
        $LocalFunctions,
        [array]$Allowlist,
        [System.Collections.Generic.HashSet[string]]$MatchedAllowlist = $null
    )
    $verbs = [Collections.Generic.HashSet[string]]::new([string[]]@((Get-Verb).Verb), [StringComparer]::OrdinalIgnoreCase)
    $violations = @()
    foreach ($f in $Files) {
        $ast = Get-ParsedScript -Path $f.FullName
        $calls = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $GET_COMMAND_NAMES -contains $n.GetCommandName()
        }, $true)
        foreach ($call in $calls) {
            $where = $f.RelativePath + ":" + $call.Extent.StartLineNumber + ": " + $call.Extent.Text
            $argument = Get-GetCommandNameArgument -Command $call
            foreach ($nameAst in $argument.NameAsts) {
                if ($nameAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $name = $nameAst.Value
                    $verbNoun = $name -match '^([A-Za-z]+)-[A-Za-z0-9]+$' -and $verbs.Contains($Matches[1])
                    if ($LocalFunctions.Contains($name) -or $verbNoun) {
                        $violations += ($where + "  (local helper '" + $name + "': use Test-Path -LiteralPath Function:" + $name + ")")
                    }
                    continue
                }
                if ($argument.ApplicationOnly) { continue }
                $text = $nameAst.Extent.Text
                $entry = @($Allowlist | Where-Object { $_.RelativePath -eq $f.RelativePath -and $_.NameText -eq $text }) | Select-Object -First 1
                if ($null -eq $entry) {
                    $violations += ($where + "  (dynamic name is not an allowlisted external-tool lookup)")
                } elseif ($null -ne $MatchedAllowlist) {
                    [void]$MatchedAllowlist.Add($entry.RelativePath + "|" + $entry.NameText)
                }
            }
        }
    }
    return $violations
}

$results += Run-Test -Name "Production code never uses command discovery for local helper presence" -Body {
    $prodFiles = @(Get-ProductionPs1Files -RepoRoot $REPO_ROOT)
    Assert-Result -Name "the production scan is non-empty" -Condition ($prodFiles.Count -ge 50) -FailureMessage (
        "the scan found " + $prodFiles.Count + " production .ps1 files; the assertions below would pass vacuously")
    $localFunctions = Get-DefinedFunctionNames -Files $prodFiles
    Assert-Result -Name "local function inventory is populated" -Condition ($localFunctions.Contains('Resolve-FilesystemPath') -and $localFunctions.Count -ge 200) -FailureMessage ("found only " + $localFunctions.Count + " production function definitions")
    $matched = [Collections.Generic.HashSet[string]]::new()
    $violations = @(Find-LocalHelperDiscoveryViolation -Files $prodFiles -LocalFunctions $localFunctions -Allowlist $EXTERNAL_DISCOVERY_ALLOWLIST -MatchedAllowlist $matched)
    Assert-Result -Name "no Get-Command local helper presence checks" -Condition ($violations.Count -eq 0) -FailureMessage ("found " + $violations.Count + " violation(s):`n" + ($violations -join "`n"))
    $stale = @($EXTERNAL_DISCOVERY_ALLOWLIST | Where-Object { -not $matched.Contains($_.RelativePath + "|" + $_.NameText) } | ForEach-Object { $_.RelativePath + " " + $_.NameText })
    Assert-Result -Name "every external-discovery allowlist entry still matches" -Condition ($stale.Count -eq 0) -FailureMessage ("stale allowlist entries:`n" + ($stale -join "`n"))
}

$results += Run-Test -Name "MUT: scanner separates local helper checks from external tool discovery" -Body {
    $tempDir = New-TestFixtureRoot -NameHint "local-helper-presence-mut"
    try {
        $cases = [ordered]@{
            'if (-not (Get-Command Resolve-FilesystemPath -ErrorAction SilentlyContinue)) { }' = $true
            'if (Get-Command "Write-LocalThing" -ErrorAction SilentlyContinue) { }' = $true
            '$x = Get-Command -ErrorAction SilentlyContinue -Name ''Get-Undefined''' = $true
            'gcm Invoke-Somewhere -ErrorAction SilentlyContinue' = $true
            '$c = Get-Command $someName -ErrorAction SilentlyContinue' = $true
            'Get-Command -Verbose Resolve-FilesystemPath' = $true
            'Get-Command -Debug Resolve-FilesystemPath -ErrorAction SilentlyContinue' = $true
            'Get-Command -All Resolve-FilesystemPath' = $true
            'Get-Command -Syntax Resolve-FilesystemPath' = $true
            'Microsoft.PowerShell.Core\Get-Command -Verbose $someName' = $true
            'Get-Command git, Resolve-FilesystemPath -ErrorAction SilentlyContinue' = $true
            'Get-Command -Verbose git' = $false
            'if (-not (Get-Command git -ErrorAction SilentlyContinue)) { }' = $false
            '$c = Get-Command "wsl.exe" -ErrorAction SilentlyContinue' = $false
            '$c = Get-Command golangci-lint -ErrorAction SilentlyContinue' = $false
            '$c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue' = $false
            'if (-not (Test-Path -LiteralPath Function:Resolve-FilesystemPath)) { }' = $false
        }
        $local = [Collections.Generic.HashSet[string]]::new([string[]]@('Write-LocalThing'), [StringComparer]::OrdinalIgnoreCase)
        $index = 0
        foreach ($source in $cases.Keys) {
            $index++
            $path = Join-Path $tempDir ("case" + $index + ".ps1")
            [IO.File]::WriteAllText($path, $source + "`n", [Text.UTF8Encoding]::new($false))
            $found = @(Find-LocalHelperDiscoveryViolation -Files @(New-ScanEntry -FullName $path -RelativePath ("case" + $index + ".ps1")) -LocalFunctions $local -Allowlist @())
            $expected = $cases[$source]
            Assert-Result -Name ("case " + $index + " flagged=" + $expected) -Condition (($found.Count -gt 0) -eq $expected) -FailureMessage ("scanner returned " + $found.Count + " violation(s) for: " + $source)
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Load-time import guards in powershell/lib, and the helper each one guarantees. Registered
# explicitly so deleting a guard fails here rather than shrinking the set being checked.
$LOAD_TIME_GUARDS = [ordered]@{
    'archive-task' = @('Invoke-WithBacklogLock', 'Test-PathWithinDirectory')
    'backlog-io' = @('Get-ConfiguredPath', 'Get-PwshCommand')
    'blocked' = @('Resolve-FilesystemPath')
    'checks-not-run' = @('Resolve-FilesystemPath')
    'claude-agents' = @('Get-ClaudeLevel', 'New-CrucibleCommand')
    'codex-launch-outcome' = @('Resolve-FilesystemPath', 'New-CrucibleCommand')
    'crucible-command' = @('Get-ConfiguredCrucibleRoot')
    'crucible-gates' = @('Resolve-FilesystemPath')
    'crucible-gates-handoff' = @('Resolve-FilesystemPath')
    'crucible-gates-human' = @('Resolve-FilesystemPath')
    'event-log' = @('Resolve-FilesystemPath')
    'file-lock' = @('Resolve-FilesystemPath')
    'gitignore-conformance' = @('Test-PathWithinDirectory')
    'handoff' = @('Test-PathWithinDirectory')
    'install-manifest' = @('Test-PathWithinDirectory')
    'instruction-blocks' = @('Resolve-FilesystemPath')
    'line-ending-conformance' = @('Test-PathWithinDirectory')
    'linux-leg-stamp' = @('Resolve-FilesystemPath')
    'no-code-closure' = @('Invoke-Git', 'Get-BacklogItemPathForTaskProjectRoot')
    'normalized-hash' = @('Resolve-FilesystemPath')
    'project-root' = @('Resolve-FilesystemPath')
    'run-lock' = @('Resolve-FilesystemPath', 'Get-NormalizedSha256')
    'session-output' = @('Get-PwshCommand', 'Assert-CrucibleContextKeys', 'Invoke-GitChecked', 'Get-ClaudeAgentDrift', 'Test-NoCodeClosure')
    'test-selection' = @('Resolve-FilesystemPath')
    'worktree' = @('Invoke-GitChecked', 'Resolve-PathFromRoot')
}

# Compares the registry with the guards actually present under $Root/powershell/lib. An
# adopter bundle omits dev-only libraries (Test-FrameworkDevOnlyFile), so there an absent
# dev-only library is not stale. The framework repo ships every library, recognised by its
# dev-only mirror sync script, and keeps the strict check.
function Get-LoadTimeGuardRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$Registry
    )
    $isFrameworkTree = Test-Path -LiteralPath (Join-Path $Root "powershell/sync-example-mirror.ps1")
    $found = @()
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Root "powershell/lib") -Filter *.ps1 | Sort-Object Name)) {
        $ast = Get-ParsedScript -Path $file.FullName
        foreach ($statement in @($ast.EndBlock.Statements)) {
            if ($statement -isnot [System.Management.Automation.Language.IfStatementAst]) { continue }
            $condition = $statement.Clauses[0].Item1.Extent.Text
            if ($condition -match '^-not\s*\(\s*(?:Test-Path\s+-LiteralPath\s+Function:|Get-Command\s+)"?([A-Za-z]+-[A-Za-z0-9]+)"?') {
                $found += ($file.BaseName + ":" + $Matches[1])
            }
        }
    }
    $applicable = [ordered]@{}
    $omitted = @()
    foreach ($lib in $Registry.Keys) {
        $relative = "powershell/lib/$lib.ps1"
        if (-not $isFrameworkTree -and -not (Test-Path -LiteralPath (Join-Path $Root $relative)) -and (Test-FrameworkDevOnlyFile -Path $relative)) {
            $omitted += $lib
            continue
        }
        $applicable[$lib] = @($Registry[$lib])
    }
    $registered = @($applicable.Keys | ForEach-Object { $lib = $_; $applicable[$lib] | ForEach-Object { $lib + ":" + $_ } })
    return [pscustomobject]@{
        Found      = $found
        Applicable = $applicable
        Omitted    = $omitted
        Missing    = @($found | Where-Object { $registered -notcontains $_ })
        Extra      = @($registered | Where-Object { $found -notcontains $_ })
    }
}

$results += Run-Test -Name "Every load-time helper guard in powershell/lib is registered" -Body {
    $registration = Get-LoadTimeGuardRegistration -Root $REPO_ROOT -Registry $LOAD_TIME_GUARDS
    $found = $registration.Found
    $missing = $registration.Missing
    $extra = $registration.Extra
    Assert-Result -Name "guards found" -Condition ($found.Count -ge 30) -FailureMessage ("found only " + $found.Count + " load-time guards")
    Assert-Result -Name "no unregistered guard" -Condition ($missing.Count -eq 0) -FailureMessage ("register in LOAD_TIME_GUARDS: " + ($missing -join ', '))
    Assert-Result -Name "no stale registration" -Condition ($extra.Count -eq 0) -FailureMessage ("registered guard not found: " + ($extra -join ', '))
}

$results += Run-Test -Name "Guard registration tolerates dev-only libraries an adopter bundle omits, only outside the framework repo" -Body {
    Assert-Result -Name "linux-leg-stamp is dev-only" -Condition (Test-FrameworkDevOnlyFile -Path "powershell/lib/linux-leg-stamp.ps1") -FailureMessage "the fixture premise no longer holds; pick another dev-only library"
    $fixtureRoot = New-TestFixtureRoot -NameHint "local-helper-registration"
    try {
        $libDir = Join-Path $fixtureRoot "powershell/lib"
        New-Item -ItemType Directory -Path $libDir -Force | Out-Null
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $REPO_ROOT "powershell/lib") -Filter *.ps1)) {
            if ($file.Name -ne 'linux-leg-stamp.ps1') { Copy-Item -LiteralPath $file.FullName -Destination $libDir }
        }
        $adopter = Get-LoadTimeGuardRegistration -Root $fixtureRoot -Registry $LOAD_TIME_GUARDS
        Assert-Result -Name "adopter shape: no stale registration" -Condition ($adopter.Extra.Count -eq 0) -FailureMessage ("registered guard not found: " + ($adopter.Extra -join ', '))
        Assert-Result -Name "adopter shape: no unregistered guard" -Condition ($adopter.Missing.Count -eq 0) -FailureMessage ("unregistered: " + ($adopter.Missing -join ', '))
        Assert-Result -Name "adopter shape: omitted library is not probed" -Condition ((@($adopter.Omitted) -join ',') -eq 'linux-leg-stamp' -and -not $adopter.Applicable.Contains('linux-leg-stamp')) -FailureMessage ("omitted: " + (@($adopter.Omitted) -join ','))

        [IO.File]::WriteAllText((Join-Path $fixtureRoot "powershell/sync-example-mirror.ps1"), "`n", [Text.UTF8Encoding]::new($false))
        $framework = Get-LoadTimeGuardRegistration -Root $fixtureRoot -Registry $LOAD_TIME_GUARDS
        Assert-Result -Name "framework shape: an absent dev-only library is stale" -Condition ((@($framework.Extra) -join ',') -eq 'linux-leg-stamp:Resolve-FilesystemPath') -FailureMessage ("extra: " + (@($framework.Extra) -join ','))
    } finally {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "Each library loads its guarded helpers alone, and again when already loaded, with zero discovery calls" -Body {
    $tempRoot = New-TestFixtureRoot -NameHint "local-helper-presence"
    try {
        $probe = Join-Path $tempRoot 'helper-presence-probe.ps1'
        $probeScript = @'
param([string]$LibraryPath, [string]$DependencyNames, [string]$IsolatedHelper)
$ErrorActionPreference = 'Stop'
$helpers = $DependencyNames -split ','
foreach ($helper in $helpers) {
    if (Test-Path -LiteralPath "Function:$helper") { throw "fresh child unexpectedly already defines $helper" }
}
# A sibling import can transitively supply a missing helper; stub the other guarded
# helpers so this child depends on the isolated guard alone.
if ($IsolatedHelper) {
    foreach ($helper in $helpers) {
        if ($helper -ne $IsolatedHelper) { Set-Item -LiteralPath "Function:$helper" -Value { } }
    }
}
$lookups = [Collections.Generic.List[string]]::new()
function Get-Command {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    $lookups.Add($Name)
    Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
}
. $LibraryPath
foreach ($helper in $helpers) {
    if (-not (Test-Path -LiteralPath "Function:$helper")) { throw "guarded helper $helper was not loaded by $LibraryPath" }
}
if ($lookups.Count -ne 0) { throw ("standalone load: expected 0 command-discovery calls, got " + $lookups.Count + ": " + ($lookups -join ', ')) }
if (-not $IsolatedHelper) {
    . $LibraryPath
    foreach ($helper in $helpers) {
        if (-not (Test-Path -LiteralPath "Function:$helper")) { throw "guarded helper $helper missing after reload" }
    }
    if ($lookups.Count -ne 0) { throw ("already-loaded reload: expected 0 command-discovery calls, got " + $lookups.Count + ": " + ($lookups -join ', ')) }
}
Write-Output 'guarded helpers loaded; zero command-discovery calls'
'@
        [IO.File]::WriteAllText($probe, $probeScript, [Text.UTF8Encoding]::new($false))
        $applicable = (Get-LoadTimeGuardRegistration -Root $REPO_ROOT -Registry $LOAD_TIME_GUARDS).Applicable
        foreach ($library in $applicable.Keys) {
            $helpers = @($applicable[$library])
            $modes = if ($helpers.Count -gt 1) { @('') + $helpers } else { @('') }
            foreach ($isolatedHelper in $modes) {
                $libraryPath = Join-Path $REPO_ROOT "powershell/lib/$library.ps1"
                $names = $helpers -join ','
                $output = @(Invoke-ExternalCommand -AsLines {
                    & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $probe -LibraryPath $libraryPath -DependencyNames $names -IsolatedHelper $isolatedHelper 2>&1
                })
                $exitCode = $LASTEXITCODE
                $mode = if ($isolatedHelper) { "isolated $isolatedHelper" } else { 'cold then reloaded' }
                Assert-Result -Name "$library ($mode)" -Condition ($exitCode -eq 0) -FailureMessage ("expected exit 0, got ${exitCode}: " + ($output -join "`n"))
            }
        }
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failedCount = @($results | Where-Object { -not $_ }).Count
if ($failedCount -gt 0) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nALL TESTS PASSED ($($results.Count) tests)" -ForegroundColor Green
    exit 0
}
