# Tests for shared config/path helpers (Get-ConfiguredPath, Parse-SemVer, Compare-SemVer).

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/config-helpers.ps1")

$results = @()

function Import-SubjectFunction {
    param([string]$File, [string[]]$Names)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
    foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        if ($node.Name -in $Names) { . ([scriptblock]::Create($node.Extent.Text)) }
    }
    foreach ($name in $Names) { Set-Item "Function:script:$name" (Get-Item "Function:$name").ScriptBlock }
}

function ToStr($arr) { if ($null -eq $arr) { return "<null>" } return ($arr -join '.') }

$tempRoot = New-TestFixtureRoot -NameHint "config-helpers-test"

try {
    . (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
    foreach ($minutesKey in @('ci_timeout_minutes', 'ci_queued_grace_minutes')) {
        $results += Run-Test -Name "Accept refuses invalid $minutesKey before side effects" -Body {
            Import-SubjectFunction "$REPO_ROOT/powershell/lib/crucible-gates-human.ps1" @('Invoke-HumanGateAcceptRedirect', 'Get-HumanGateAcceptConfig')
            $root = Join-Path $tempRoot 'accept'
            $null = New-Item -ItemType Directory "$root/.crucible" -Force
            [IO.File]::WriteAllText("$root/.crucible/config.yaml", "review:`n  ${minutesKey}: invalid`n")
            $script:merged = $false
            $script:finalized = $false
            function git { $global:LASTEXITCODE = 0; return 'fixture-sha' }
            function Get-ConfiguredPath { return $root }
            function Invoke-HumanGateAcceptMerge { $script:merged = $true }
            function Invoke-HumanGateBacklogFinalization { $script:finalized = $true; return $true }
            $message = ''
            try {
                Invoke-HumanGateAcceptRedirect -TaskId F-001 -Outcome accepted -ProjectRoot $root -PrimaryBranch main -LogFile fixture -CircuitBreakerHistoryFile fixture
            } catch { $message = $_.Exception.Message }
            Assert-Result -Name "invalid $minutesKey refuses with no merge or finalization" -Condition ($message -match "review\.$minutesKey" -and -not $script:merged -and -not $script:finalized) -FailureMessage "message=$message merged=$script:merged finalized=$script:finalized"
        }
    }

    foreach ($mode in @('quick', 'full')) {
        foreach ($entries in @('[]', "`n    - name: no-command")) {
            $results += Run-Test -Name "Validator names empty $mode mode ($entries)" -Body {
                $text = [IO.File]::ReadAllText("$REPO_ROOT/templates/project/.crucible/config.yaml") -replace 'replace-with-project-quick-test-command', 'Write-Output quick' -replace 'replace-with-project-full-test-command', 'Write-Output full'
                $bundle = Join-Path $tempRoot 'validate/.crucible'
                foreach ($dir in @('docs','prompts','personas','schemas','sops','powershell')) {
                    $null = New-Item -ItemType Directory (Join-Path $bundle $dir) -Force
                }
                $path = Join-Path $bundle 'config.yaml'
                [IO.File]::WriteAllText($path, $text)
                $control = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File "$REPO_ROOT/powershell/validate-config.ps1" -ConfigPath $path }
                Assert-Result -Name 'populated modes pass validation' -Condition ($control.ExitCode -eq 0) -FailureMessage $control.Output
                $text = $text -replace "(?m)^  ${mode}:\r?\n    - name: [^\r\n]+\r?\n      command: [^\r\n]+", "  ${mode}: $entries"
                [IO.File]::WriteAllText($path, $text)
                $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File "$REPO_ROOT/powershell/validate-config.ps1" -ConfigPath $path }
                Assert-Result -Name "validator refuses and names verification.$mode zero checks" -Condition ($run.ExitCode -eq 2 -and $run.Output -match "verification\.$mode has zero checks") -FailureMessage $run.Output
            }
        }
    }

    $results += Run-Test -Name 'Verification fields trim trailing whitespace' -Body {
        $checks = @(Get-VerificationChecks -Content "verification:`n  quick:`n    - name: Cfg`n      command: echo ok`n      host_gate: os=windows   `n  config_check:`n    name: `"Cfg check`"  `n    command: echo config`n" -Mode quick)
        Assert-Result -Name 'host gate ignores trailing spaces' -Condition ($checks[0].HostGate -ceq 'os=windows') -FailureMessage "Got <$($checks[0].HostGate)>"
    }
    $results += Run-Test -Name 'Config check name trims before decoding' -Body {
        $checks = @(Get-VerificationChecks -Content "verification:`n  config_check:`n    name: `"Cfg`"  `n    command: echo config`n" -Mode full)
        Assert-Result -Name 'quoted config check name ignores trailing spaces' -Condition ($checks[0].Name -ceq 'Cfg') -FailureMessage "Got <$($checks[0].Name)>"
    }

    $results += Run-Test -Name 'Shared encoder round trips quotes and backslashes' -Body {
        $value = 'A "quote" at C:\work\'
        $got = ConvertFrom-ConfigScalar (ConvertTo-ConfigScalar $value)
        Assert-Result -Name 'shared encoder preserves scalar' -Condition ($got -ceq $value) -FailureMessage $got
    }
    $results += Run-Test -Name 'Bundle scalar IO uses shared decoding' -Body {
        Import-SubjectFunction "$REPO_ROOT/powershell/update-bundle.ps1" @('Read-ConfigScalar', 'Write-ConfigScalar')
        $path = Join-Path $tempRoot 'bundle.yaml'
        [IO.File]::WriteAllText($path, "crucible_version: `"1.2.3`"`ncrucible_install_commit: 'abc123'`n")
        foreach ($pair in @(@('crucible_version','1.2.3'), @('crucible_install_commit','abc123'))) {
            Assert-Result -Name "bundle preserves $($pair[0]) reading" -Condition ((Read-ConfigScalar $path $pair[0]) -ceq $pair[1]) -FailureMessage $pair[0]
            Write-ConfigScalar $path $pair[0] $pair[1]
            Assert-Result -Name "bundle preserves $($pair[0]) writing" -Condition ((Read-ConfigScalar $path $pair[0]) -ceq $pair[1]) -FailureMessage $pair[0]
        }
        $value = 'A "quote" at C:\work\'
        Write-ConfigScalar $path description $value
        Assert-Result -Name 'bundle escaped scalar round trip' -Condition ((Read-ConfigScalar $path description) -ceq $value) -FailureMessage ([IO.File]::ReadAllText($path))
    }
    foreach ($value in @('C:\work\', '\\server\share\b')) {
        $results += Run-Test -Name "Legacy quoted path preserves $value" -Body {
            $got = Get-ConfigBlockValue -Content ('paths:' + "`n  backlog: " + '"' + $value + '"') -Path @('paths','backlog') -Source fixture
            Assert-Result -Name "legacy path remains verbatim $value" -Condition ($got -ceq $value) -FailureMessage "Got <$got>"
        }
    }
    foreach ($key in @('ci_timeout_minutes', 'ci_queued_grace_minutes')) {
        $results += Run-Test -Name "Review $key schema bounds match runtime" -Body {
            $schema = Get-Content "$REPO_ROOT/schemas/config.schema.json" -Raw | ConvertFrom-Json
            $property = $schema.properties.review.properties.$key
            Assert-Result -Name "$key has non-negative schema minimum" -Condition ($property.PSObject.Properties.Name -contains 'minimum' -and $property.minimum -eq 0) -FailureMessage "$key missing minimum 0"
        }
    }

    $results += Run-Test -Name "Init description escapes read back unchanged" -Body {
        . (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
        $root = Join-Path $tempRoot "quoted-description"
        $description = 'A path \ and a "quote"'
        $cmd = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File (Join-Path $REPO_ROOT "powershell/init-project.ps1") -ProjectRoot $root -Description $description -Quiet }
        Assert-Result -Name "quoted description init succeeds" -Condition ($cmd.ExitCode -eq 0) -FailureMessage $cmd.Output
        $text = Get-Content -LiteralPath (Join-Path $root ".crucible/config.yaml") -Raw
        $got = Get-ConfigBlockValue -Content $text -Path @("project", "description") -Source "fixture"
        Assert-Result -Name "description backslash and quote round trip" -Condition ($got -ceq $description) -FailureMessage "Got: $got"
    }

    $results += Run-Test -Name "Init absolute Windows backlog reads back unchanged" -Body {
        if (-not $IsWindows) { return }
        . (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
        $root = Join-Path $tempRoot "windows-backlog"
        $backlog = Join-Path $tempRoot "absolute-backlog"
        $cmd = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File (Join-Path $REPO_ROOT "powershell/init-project.ps1") -ProjectRoot $root -BacklogDir $backlog -Quiet }
        Assert-Result -Name "absolute backlog init succeeds" -Condition ($cmd.ExitCode -eq 0) -FailureMessage $cmd.Output
        $text = Get-Content -LiteralPath (Join-Path $root ".crucible/config.yaml") -Raw
        $got = Get-ConfigBlockValue -Content $text -Path @("paths", "backlog") -Source "fixture"
        Assert-Result -Name "absolute Windows backlog round trip" -Condition ($got -ceq $backlog) -FailureMessage "Got: $got"
    }

    $results += Run-Test -Name "Parse-SemVer extracts major.minor.patch" -Body {
        Assert-Result -Name "full triple" -Condition ((ToStr (Parse-SemVer "1.2.3")) -eq "1.2.3") -FailureMessage "1.2.3 should parse to 1.2.3"
        Assert-Result -Name "embedded in text" -Condition ((ToStr (Parse-SemVer "crucible v2.10.0 (build 7)")) -eq "2.10.0") -FailureMessage "should extract embedded version"
        Assert-Result -Name "two-part defaults patch 0" -Condition ((ToStr (Parse-SemVer "1.4")) -eq "1.4.0") -FailureMessage "1.4 should parse to 1.4.0"
    }

    # Item 301: one resolver for a bundle root; items 280 and 300 joined the project root in
    # front of an absolute one.
    $results += Run-Test -Name "Resolve-CrucibleBundleRoot keeps an absolute root and joins a relative one" -Body {
        $project = Join-Path $tempRoot "bundle root project"
        $absolute = Join-Path $tempRoot "outside bundle/.crucible"
        Assert-Result -Name "absolute with spaces as is" -Condition ((Resolve-CrucibleBundleRoot -ProjectRoot $project -CrucibleRoot $absolute) -eq $absolute) -FailureMessage "an absolute crucible_root must be used as is"
        Assert-Result -Name "relative under the project" -Condition ((Resolve-CrucibleBundleRoot -ProjectRoot $project -CrucibleRoot "tools/crucible") -eq (Join-Path $project "tools/crucible")) -FailureMessage "a relative crucible_root must be joined to the project root"
        foreach ($case in @(@{ Project = $project; Root = "" }, @{ Project = $project; Root = "  " }, @{ Project = ""; Root = ".crucible" })) {
            $message = ""
            try { $null = Resolve-CrucibleBundleRoot -ProjectRoot $case.Project -CrucibleRoot $case.Root } catch { $message = $_.Exception.Message }
            Assert-Result -Name ("empty input refused: '" + $case.Project + "' / '" + $case.Root + "'") -Condition ($message -match "Cannot resolve the Crucible bundle") -FailureMessage ("expected a refusal, got: '" + $message + "'")
        }
    }

    $results += Run-Test -Name "General path resolution preserves rooted spelling and relative Join-Path output" -Body {
        $root = Join-Path $tempRoot "ResolutionRoot"
        $absolute = $tempRoot.Replace("\", "/") + "/Outside//unused/../Leaf/"
        $cases = @(
            @{ Root = $root; Path = $absolute; Expected = $absolute },
            @{ Root = $null; Path = $absolute; Expected = $absolute },
            @{ Root = ""; Path = $absolute; Expected = $absolute },
            @{ Root = $root; Path = "Child/MixedLeaf/"; Expected = (Join-Path $root "Child/MixedLeaf/") },
            @{ Root = ($root + "/"); Path = "Child/../MixedLeaf"; Expected = (Join-Path ($root + "/") "Child/../MixedLeaf") },
            @{ Root = $root; Path = ""; Expected = (Join-Path $root "") },
            @{ Root = $root; Path = "  "; Expected = (Join-Path $root "  ") }
        )
        if ($IsWindows) {
            $cases += @{ Root = $root; Path = "C:MixedLeaf"; Expected = "C:MixedLeaf" }
            $cases += @{ Root = $root; Path = "\MixedLeaf/"; Expected = "\MixedLeaf/" }
            $cases += @{ Root = $root; Path = "\\server\share\MixedLeaf\"; Expected = "\\server\share\MixedLeaf\" }
        }
        foreach ($case in $cases) {
            $actual = Resolve-PathFromRoot -Root $case.Root -Path $case.Path
            Assert-Result -Name ("exact output for '" + $case.Path + "' under '" + $case.Root + "'") -Condition ($actual -ceq $case.Expected) -FailureMessage ("expected '" + $case.Expected + "', got '" + $actual + "'")
        }
        Assert-Result -Name "bundle specialization keeps rooted spelling with no root" -Condition ((Resolve-CrucibleBundleRoot -ProjectRoot "  " -CrucibleRoot $absolute) -ceq $absolute) -FailureMessage "bundle specialization changed the rooted value"
    }

    $results += Run-Test -Name "General resolution retains null binding and bundle refusal diagnostics" -Body {
        foreach ($case in @(
            @{ Root = $tempRoot; Path = $null; Parameter = "ChildPath"; Kind = "null" },
            @{ Root = $null; Path = "leaf"; Parameter = "Path"; Kind = "null" },
            @{ Root = ""; Path = "leaf"; Parameter = "Path"; Kind = "empty string" }
        )) {
            $message = ""
            $actual = $null
            try { $actual = Resolve-PathFromRoot -Root $case.Root -Path $case.Path } catch { $message = $_.Exception.Message }
            $preserved = if ($case.Parameter -eq "ChildPath") {
                $message -ceq "" -and $actual -ceq (Join-Path $case.Root $null)
            } else { $message -match $case.Parameter -and $message -match $case.Kind }
            Assert-Result -Name ("Join-Path binding preserved for " + $case.Parameter + " " + $case.Kind) -Condition $preserved -FailureMessage ("output '" + $actual + "'; error '" + $message + "'")
        }
        $message = ""
        try { $null = Resolve-CrucibleBundleRoot -ProjectRoot "  " -CrucibleRoot "bundle" } catch { $message = $_.Exception.Message }
        Assert-Result -Name "bundle keeps its exact empty-root diagnostic" -Condition ($message -ceq "Cannot resolve the Crucible bundle 'bundle': it is relative and the project root is empty.") -FailureMessage $message
    }

    $results += Run-Test -Name "Test-PathWithinDirectory compares on a separator boundary" -Body {
        $bundle = if ($IsWindows) { "C:\bundle" } else { "/bundle" }
        Assert-Result -Name "the directory itself" -Condition (Test-PathWithinDirectory -Path $bundle -Directory $bundle) -FailureMessage "a directory contains itself"
        Assert-Result -Name "a child" -Condition (Test-PathWithinDirectory -Path (Join-Path $bundle "research/F-1_findings.md") -Directory (Join-Path $bundle "research")) -FailureMessage "a file under the directory is inside it"
        Assert-Result -Name "trailing separator on the directory" -Condition (Test-PathWithinDirectory -Path (Join-Path $bundle "x.md") -Directory ($bundle + [System.IO.Path]::DirectorySeparatorChar)) -FailureMessage "a trailing separator must not change the answer"
        Assert-Result -Name "sibling bundle2 refused" -Condition (-not (Test-PathWithinDirectory -Path ($bundle + "2") -Directory $bundle)) -FailureMessage ($bundle + "2 shares the prefix but is not inside " + $bundle)
        Assert-Result -Name "file in sibling bundle2 refused" -Condition (-not (Test-PathWithinDirectory -Path (Join-Path ($bundle + "2") "research/x.md") -Directory $bundle)) -FailureMessage "a file under a sibling sharing the prefix is outside"
        Assert-Result -Name "research-old refused" -Condition (-not (Test-PathWithinDirectory -Path (Join-Path $bundle "research-old/x.md") -Directory (Join-Path $bundle "research"))) -FailureMessage "research-old is a sibling of research, not inside it"
        Assert-Result -Name "dot-dot escape refused" -Condition (-not (Test-PathWithinDirectory -Path (Join-Path $bundle "research/../x.md") -Directory (Join-Path $bundle "research"))) -FailureMessage "a path that climbs out of the directory is outside"
    }

    $results += Run-Test -Name "Path relativization owns normalization, outside and output spelling" -Body {
        $directory = Join-Path $tempRoot "OwnerRoot"
        $cases = @(
            @{ Path = (Join-Path $directory "Child/File.md"); Directory = $directory; Expected = "Child/File.md" },
            @{ Path = (Join-Path $directory "Child/../File.md"); Directory = $directory; Expected = "File.md" },
            @{ Path = (Join-Path $directory "File.md"); Directory = (Join-Path $directory "unused/.."); Expected = "File.md" },
            @{ Path = ($directory + "/Child/"); Directory = ($directory + "/"); Expected = "Child/" },
            @{ Path = $directory; Directory = $directory; Expected = "" },
            @{ Path = (Join-Path ($directory + "2") "File.md"); Directory = $directory; Expected = $null }
        )
        if ($IsWindows) {
            $cases += @{ Path = (Join-Path $directory "Child/File.md"); Directory = $directory.ToUpperInvariant(); Expected = "Child/File.md" }
        }
        foreach ($case in $cases) {
            $actual = Get-PathRelativeToDirectory -Path $case.Path -Directory $case.Directory -Separator "/"
            Assert-Result -Name ("suffix for " + $case.Path + " under " + $case.Directory) -Condition ($actual -ceq $case.Expected) -FailureMessage ("expected '" + $case.Expected + "', got '" + $actual + "'")
        }
        $native = Get-PathRelativeToDirectory -Path ($directory + "/Child/") -Directory $directory
        Assert-Result -Name "native separator and trailing separator" -Condition ($native -ceq ("Child" + [IO.Path]::DirectorySeparatorChar)) -FailureMessage $native
        $caseMismatch = Get-PathRelativeToDirectory -Path (Join-Path $directory "File.md") -Directory ($directory + "x/../ownerroot") -Comparison Ordinal
        Assert-Result -Name "ordinal display adapter can keep case sensitivity" -Condition ($null -eq $caseMismatch) -FailureMessage "ordinal matching must not fold case"
        foreach ($pair in @(@{ Path = "child"; Directory = $directory }, @{ Path = $directory; Directory = "root" })) {
            $message = ""
            try { $null = Get-PathRelativeToDirectory @pair } catch { $message = $_.Exception.Message }
            Assert-Result -Name "relative input refuses before GetFullPath" -Condition ($message -match "must both be absolute") -FailureMessage $message
            $message = ""
            try { $null = Test-PathWithinDirectory @pair } catch { $message = $_.Exception.Message }
            Assert-Result -Name "containment also refuses relative input" -Condition ($message -match "must both be absolute") -FailureMessage $message
        }
    }

    $results += Run-Test -Name "Parse-SemVer returns null for non-versions" -Body {
        Assert-Result -Name "empty" -Condition ($null -eq (Parse-SemVer "")) -FailureMessage "empty should be null"
        Assert-Result -Name "whitespace" -Condition ($null -eq (Parse-SemVer "   ")) -FailureMessage "whitespace should be null"
        Assert-Result -Name "no digits" -Condition ($null -eq (Parse-SemVer "abc")) -FailureMessage "non-numeric should be null"
    }

    $results += Run-Test -Name "Compare-SemVer orders versions correctly" -Body {
        Assert-Result -Name "equal" -Condition ((Compare-SemVer @(1,2,3) @(1,2,3)) -eq 0) -FailureMessage "equal versions should compare 0"
        Assert-Result -Name "major greater" -Condition ((Compare-SemVer @(2,0,0) @(1,9,9)) -eq 1) -FailureMessage "higher major should win"
        Assert-Result -Name "minor greater" -Condition ((Compare-SemVer @(1,3,0) @(1,2,9)) -eq 1) -FailureMessage "higher minor should win"
        Assert-Result -Name "patch lesser" -Condition ((Compare-SemVer @(1,2,3) @(1,2,4)) -eq -1) -FailureMessage "lower patch should compare -1"
    }

    $results += Run-Test -Name "Get-ConfiguredPath falls back to defaults with no config" -Body {
        $noCfg = Join-Path $tempRoot "no-config"
        New-Item -ItemType Directory -Path $noCfg -Force | Out-Null
        $got = Get-ConfiguredPath -Key "backlog" -ProjectRoot $noCfg
        $expected = Join-Path (Resolve-Path -LiteralPath $noCfg).Path ".crucible/backlog"
        Assert-Result -Name "default backlog" -Condition ($got -eq $expected) -FailureMessage "expected default '$expected', got '$got'"
    }

    $results += Run-Test -Name "Get-ConfiguredPath honors a custom relative path from config" -Body {
        $proj = Join-Path $tempRoot "custom-rel"
        New-Item -ItemType Directory -Path (Join-Path $proj ".crucible") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj ".crucible/config.yaml") -Value "paths:`n  backlog: `"work/items`"`n" -Encoding UTF8
        $got = Get-ConfiguredPath -Key "backlog" -ProjectRoot $proj
        $expected = Join-Path (Resolve-Path -LiteralPath $proj).Path "work/items"
        Assert-Result -Name "custom relative" -Condition ($got -eq $expected) -FailureMessage "expected '$expected', got '$got'"
    }

    $results += Run-Test -Name "Get-ConfiguredPath returns an absolute config path unchanged" -Body {
        $proj = Join-Path $tempRoot "custom-abs"
        New-Item -ItemType Directory -Path (Join-Path $proj ".crucible") -Force | Out-Null
        $abs = Join-Path $tempRoot "elsewhere/backlog"
        Set-Content -LiteralPath (Join-Path $proj ".crucible/config.yaml") -Value "paths:`n  backlog: `"$($abs -replace '\\','/')`"`n" -Encoding UTF8
        $got = Get-ConfiguredPath -Key "backlog" -ProjectRoot $proj
        Assert-Result -Name "absolute unchanged" -Condition ($got -eq ($abs -replace '\\','/')) -FailureMessage "absolute path should be returned as-is, got '$got'"
    }

    $results += Run-Test -Name "Get-ConfiguredPath ProjectRoot override works from a foreign CWD" -Body {
        $proj = Join-Path $tempRoot "foreign-cwd"
        New-Item -ItemType Directory -Path (Join-Path $proj ".crucible") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj ".crucible/config.yaml") -Value "paths:`n  session: `"state/sess`"`n" -Encoding UTF8
        Push-Location $tempRoot
        try {
            $got = Get-ConfiguredPath -Key "session" -ProjectRoot $proj
        } finally {
            Pop-Location
        }
        $expected = Join-Path (Resolve-Path -LiteralPath $proj).Path "state/sess"
        Assert-Result -Name "foreign cwd" -Condition ($got -eq $expected) -FailureMessage "expected '$expected', got '$got'"
    }

    $results += Run-Test -Name "Get-ConfiguredManifestFiles parses list and block syntax" -Body {
        $proj = Join-Path $tempRoot "manifest-test"
        New-Item -ItemType Directory -Path (Join-Path $proj ".crucible") -Force | Out-Null
        
        # Test block list syntax
        Set-Content -LiteralPath (Join-Path $proj ".crucible/config.yaml") -Value "manifest_files:`n  - go.mod`n  - go.sum`n" -Encoding UTF8
        $got = Get-ConfiguredManifestFiles -ProjectRoot $proj
        Assert-Result -Name "block list size" -Condition (@($got).Count -eq 2) -FailureMessage "expected 2 manifest files"
        Assert-Result -Name "block list go.mod" -Condition ($got[0] -eq "go.mod") -FailureMessage "expected go.mod, got $($got[0])"
        Assert-Result -Name "block list go.sum" -Condition ($got[1] -eq "go.sum") -FailureMessage "expected go.sum, got $($got[1])"

        # Test inline array syntax
        Set-Content -LiteralPath (Join-Path $proj ".crucible/config.yaml") -Value "manifest_files: [`"package.json`", `"package-lock.json`"]`n" -Encoding UTF8
        $gotInline = Get-ConfiguredManifestFiles -ProjectRoot $proj
        Assert-Result -Name "inline list size" -Condition (@($gotInline).Count -eq 2) -FailureMessage "expected 2 inline manifest files"
        Assert-Result -Name "inline list package.json" -Condition ($gotInline[0] -eq "package.json") -FailureMessage "expected package.json, got $($gotInline[0])"

        # Test missing manifest_files returning empty array
        Set-Content -LiteralPath (Join-Path $proj ".crucible/config.yaml") -Value "paths:`n  backlog: `"work`"`n" -Encoding UTF8
        $gotEmpty = Get-ConfiguredManifestFiles -ProjectRoot $proj
        Assert-Result -Name "missing manifests empty" -Condition (@($gotEmpty).Count -eq 0) -FailureMessage "expected empty array when key is missing"
    }

    # --- indent-agnostic parsing (TODO item 34) ------------------------------
    # Every accessor used to pin the indent to exactly two spaces, so a 3-space,
    # 4-space, tab-indented or BOM-prefixed config - all valid YAML - read as absent
    # and silently took the default. For require_green_ci that default is "false",
    # which switches the publish gate off while the file says it is on.

    $enc = New-Object System.Text.UTF8Encoding($false)
    $bomEnc = New-Object System.Text.UTF8Encoding($true)
    function New-ConfigProject($Name, $Text, [switch]$WithBom) {
        $proj = Join-Path $tempRoot $Name
        New-Item -ItemType Directory -Path (Join-Path $proj ".crucible") -Force | Out-Null
        $writer = if ($WithBom) { $bomEnc } else { $enc }
        [System.IO.File]::WriteAllText((Join-Path $proj ".crucible/config.yaml"), $Text, $writer)
        return $proj
    }

    $indentCases = @(
        @{ Name = "2space"; Indent = "  " },
        @{ Name = "3space"; Indent = "   " },
        @{ Name = "4space"; Indent = "    " },
        @{ Name = "tab";    Indent = "`t" }
    )

    $results += Run-Test -Name "Get-ConfiguredPath reads any indent width" -Body {
        foreach ($case in $indentCases) {
            $proj = New-ConfigProject ("indent-path-" + $case.Name) ("paths:`n" + $case.Indent + "backlog: work/items`n")
            $got = Get-ConfiguredPath -Key "backlog" -ProjectRoot $proj
            $expected = Join-Path (Resolve-Path -LiteralPath $proj).Path "work/items"
            Assert-Result -Name ($case.Name + " backlog") -Condition ($got -eq $expected) -FailureMessage ("expected '$expected', got '$got'")
        }
    }

    $results += Run-Test -Name "Get-ConfiguredReview reads any indent width" -Body {
        foreach ($case in $indentCases) {
            $proj = New-ConfigProject ("indent-review-" + $case.Name) ("review:`n" + $case.Indent + "require_green_ci: true`n")
            $got = Get-ConfiguredReview -Key "require_green_ci" -ProjectRoot $proj
            Assert-Result -Name ($case.Name + " require_green_ci") -Condition ($got -eq "true") -FailureMessage ("expected 'true', got '$got' - the CI publish gate would be off")
        }
    }

    $results += Run-Test -Name "Get-ModelFromConfig reads any indent width" -Body {
        foreach ($case in $indentCases) {
            $i = $case.Indent
            $yaml = "models:`n" + $i + "targets:`n" + $i + $i + "claude:`n" + $i + $i + $i + "strong: opus-probe`n"
            $proj = New-ConfigProject ("indent-model-" + $case.Name) $yaml
            $got = Get-ConfiguredModel -Target "claude" -Tier "strong" -ProjectRoot $proj
            Assert-Result -Name ($case.Name + " model") -Condition ($got -eq "opus-probe") -FailureMessage ("expected 'opus-probe', got '$got'")
        }
    }

    $results += Run-Test -Name "Get-ConfiguredManifestFiles reads any indent width" -Body {
        foreach ($case in $indentCases) {
            $proj = New-ConfigProject ("indent-manifest-" + $case.Name) ("manifest_files:`n" + $case.Indent + "- go.mod`n" + $case.Indent + "- go.sum`n")
            $got = @(Get-ConfiguredManifestFiles -ProjectRoot $proj)
            Assert-Result -Name ($case.Name + " manifest") -Condition (($got -join ",") -eq "go.mod,go.sum") -FailureMessage ("expected 'go.mod,go.sum', got '" + ($got -join ",") + "'")
        }
    }

    $results += Run-Test -Name "A UTF-8 BOM does not hide the first key" -Body {
        $proj = New-ConfigProject "bom-config" "paths:`n  backlog: work/items`n" -WithBom
        $got = Get-ConfiguredPath -Key "backlog" -ProjectRoot $proj
        $expected = Join-Path (Resolve-Path -LiteralPath $proj).Path "work/items"
        Assert-Result -Name "bom backlog" -Condition ($got -eq $expected) -FailureMessage ("expected '$expected', got '$got'")
    }

    $results += Run-Test -Name "A trailing comment is not part of the value" -Body {
        $proj = New-ConfigProject "inline-comment" "review:`n  diff_tool: zed  # the reviewer's editor`n"
        $got = Get-ConfiguredReview -Key "diff_tool" -ProjectRoot $proj
        Assert-Result -Name "comment stripped" -Condition ($got -eq "zed") -FailureMessage ("expected 'zed', got '$got'")
    }

    $results += Run-Test -Name "An absent key still takes the documented default" -Body {
        $proj = New-ConfigProject "absent-keys" "project:`n  name: `"x`"`n"
        Assert-Result -Name "review default" -Condition ((Get-ConfiguredReview -Key "require_green_ci" -ProjectRoot $proj) -eq "false") -FailureMessage "absent require_green_ci should default to false"
        $expected = Join-Path (Resolve-Path -LiteralPath $proj).Path ".crucible/backlog"
        Assert-Result -Name "path default" -Condition ((Get-ConfiguredPath -Key "backlog" -ProjectRoot $proj) -eq $expected) -FailureMessage "absent backlog should default"
        Assert-Result -Name "manifest default" -Condition (@(Get-ConfiguredManifestFiles -ProjectRoot $proj).Count -eq 0) -FailureMessage "absent manifest_files should be empty"
    }

    $results += Run-Test -Name "A key present but unreadable throws instead of defaulting" -Body {
        $valueless = New-ConfigProject "unreadable-valueless" "review:`n  require_green_ci:`n"
        $threw = $false
        try { $null = Get-ConfiguredReview -Key "require_green_ci" -ProjectRoot $valueless } catch { $threw = $true }
        Assert-Result -Name "valueless key throws" -Condition $threw -FailureMessage "a key with no value must not fall back to the default"

        $malformed = New-ConfigProject "unreadable-malformed" "paths:`n  backlog `"work/items`"`n"
        $threw = $false
        try { $null = Get-ConfiguredPath -Key "backlog" -ProjectRoot $malformed } catch { $threw = $true }
        Assert-Result -Name "malformed line throws" -Condition $threw -FailureMessage "a key line missing its colon must not read as absent"

        $notAList = New-ConfigProject "unreadable-list" "manifest_files: go.mod`n"
        $threw = $false
        try { $null = Get-ConfiguredManifestFiles -ProjectRoot $notAList } catch { $threw = $true }
        Assert-Result -Name "non-list throws" -Condition $threw -FailureMessage "a scalar manifest_files must not read as an empty list"
    }

    $results += Run-Test -Name "The shipped template config parses through the primitive" -Body {
        $template = Join-Path $REPO_ROOT "templates/project/.crucible/config.yaml"
        $content = Get-Content -LiteralPath $template -Raw -Encoding UTF8
        $got = Get-ConfigBlockValue -Content $content -Path @("models", "targets", "antigravity", "strong") -Source $template
        Assert-Result -Name "quoted nested value" -Condition ($got -eq "Gemini 3.1 Pro (High)") -FailureMessage ("expected the quoted antigravity strong model, got '$got'")
        $grokDefault = Get-ConfigBlockValue -Content $content -Path @("models", "targets", "grok", "default") -Source $template
        Assert-Result -Name "grok default is inherit" -Condition ($grokDefault -eq "inherit") -FailureMessage ("expected inherit, got '$grokDefault'")
        $absent = Get-ConfigBlockValue -Content $content -Path @("review", "require_green_ci") -Source $template
        Assert-Result -Name "commented-out block is absent" -Condition ($null -eq $absent) -FailureMessage "a commented-out review block must read as absent, not as a value"
    }

    # Item 178: the approval mode is a personal setting, read from the gitignored local file first.
    $results += Run-Test -Name "Get-ConfiguredApprovalMode prefers config.local.yaml and refuses unknown values" -Body {
        $proj = Join-Path $tempRoot "approval"
        $crucibleDir = Join-Path $proj ".crucible"
        New-Item -ItemType Directory -Path $crucibleDir -Force | Out-Null
        $shared = Join-Path $crucibleDir "config.yaml"
        $local = Join-Path $crucibleDir "config.local.yaml"

        Assert-Result -Name "no config is per-phase" -Condition ((Get-ConfiguredApprovalMode -ProjectRoot $proj) -eq "per-phase") -FailureMessage "default must be per-phase"

        Set-Content -LiteralPath $shared -Value "review:`n  require_green_ci: true`n" -Encoding UTF8
        Assert-Result -Name "absent key is per-phase" -Condition ((Get-ConfiguredApprovalMode -ProjectRoot $proj) -eq "per-phase") -FailureMessage "absent key must be per-phase"

        Set-Content -LiteralPath $local -Value "orchestration:`n  approval: to-gate`nreview:`n  require_green_ci: false`n" -Encoding UTF8
        Assert-Result -Name "local to-gate wins" -Condition ((Get-ConfiguredApprovalMode -ProjectRoot $proj) -eq "to-gate") -FailureMessage "local to-gate must be read"
        Assert-Result -Name "local file changes no other key" -Condition ((Get-ConfiguredReview -Key "require_green_ci" -ProjectRoot $proj) -eq "true") -FailureMessage "config.local.yaml must not override review keys"

        Set-Content -LiteralPath $shared -Value "orchestration:`n  approval: per-phase`n" -Encoding UTF8
        Assert-Result -Name "local beats shared" -Condition ((Get-ConfiguredApprovalMode -ProjectRoot $proj) -eq "to-gate") -FailureMessage "local must win over config.yaml"

        Remove-Item -LiteralPath $local -Force
        Set-Content -LiteralPath $shared -Value "orchestration:`n  approval: `"To-Gate`"`n" -Encoding UTF8
        Assert-Result -Name "shared value used without local" -Condition ((Get-ConfiguredApprovalMode -ProjectRoot $proj) -eq "to-gate") -FailureMessage "config.yaml value must apply when there is no local file"

        Set-Content -LiteralPath $local -Value "orchestration:`n  approval: auto`n" -Encoding UTF8
        $message = ""
        try { $null = Get-ConfiguredApprovalMode -ProjectRoot $proj } catch { $message = $_.Exception.Message }
        Assert-Result -Name "unknown value throws naming the allowed values" -Condition ($message -match "per-phase, to-gate" -and $message -match "'auto'") -FailureMessage ("got: " + $message)
    }

    # Item 189: project.default_branch is honored, and a branch it names must exist.
    $results += Run-Test -Name "Get-ConfiguredPrimaryBranch honors project.default_branch and refuses a missing one" -Body {
        $proj = Join-Path $tempRoot "primary-branch"
        New-Item -ItemType Directory -Path (Join-Path $proj ".crucible") -Force | Out-Null
        git -C $proj init --quiet -b trunk
        git -C $proj -c user.name=T -c user.email=t@example.com commit --allow-empty -m init --quiet
        git -C $proj branch main
        $config = Join-Path $proj ".crucible/config.yaml"

        Assert-Result -Name "unset prefers main" -Condition ((Get-ConfiguredPrimaryBranch -ProjectRoot $proj) -eq "main") -FailureMessage "with no setting, an existing main is the primary branch"

        Set-Content -LiteralPath $config -Value "project:`n  default_branch: `"trunk`"`n" -Encoding UTF8
        Assert-Result -Name "configured branch wins" -Condition ((Get-ConfiguredPrimaryBranch -ProjectRoot $proj) -eq "trunk") -FailureMessage "project.default_branch must be honored over the main/master guess"

        Set-Content -LiteralPath $config -Value "project:`n  default_branch: develop`n" -Encoding UTF8
        $message = ""
        try { $null = Get-ConfiguredPrimaryBranch -ProjectRoot $proj } catch { $message = $_.Exception.Message }
        Assert-Result -Name "missing configured branch throws" -Condition ($message -match "project.default_branch" -and $message -match "'develop'" -and $message -match "'trunk'") -FailureMessage ("expected the setting, its value and the current branch named. Got: " + $message)
    }

    # Item 254: the checks run only from a committed config.yaml. Each state is named, and
    # only one of them is "committed".
    function New-CommitStateRepo {
        param([string]$Name, [switch]$CommitConfig, [string]$GitIgnore = "")
        $proj = Join-Path $tempRoot $Name
        $null = New-Item -ItemType Directory -Path (Join-Path $proj ".crucible") -Force
        $null = Invoke-ExternalCommand { git -C $proj init --quiet }
        $null = Invoke-ExternalCommand { git -C $proj config core.autocrlf false }
        [IO.File]::WriteAllText((Join-Path $proj "README.md"), "fixture`n")
        [IO.File]::WriteAllText((Join-Path $proj ".crucible/config.yaml"), "verification:`n  quick:`n    - name: unit`n      command: exit 5`n")
        $paths = @("README.md")
        if ($GitIgnore) { [IO.File]::WriteAllText((Join-Path $proj ".gitignore"), $GitIgnore + "`n"); $paths += ".gitignore" }
        if ($CommitConfig) { $paths += ".crucible/config.yaml" }
        $null = Invoke-ExternalCommand { git -C $proj add -- @paths }
        $null = Invoke-ExternalCommand { git -C $proj -c user.name=t -c user.email=t@example.com -c commit.gpgSign=false commit --quiet -m init }
        return $proj
    }
    function Get-StateFor {
        param([string]$Config)
        return (Get-ConfigCommitState -ProjectRoot (Split-Path -Parent (Split-Path -Parent $Config)) -ConfigPath $Config)
    }

    $results += Run-Test -Name "Config commit state names each way the checks file can differ from HEAD (item 254)" -Body {
        $proj = New-CommitStateRepo -Name "commit-state" -CommitConfig
        $config = Join-Path $proj ".crucible/config.yaml"
        $committed = $config
        Assert-Result -Name "committed config reads as committed" -Condition ((Get-StateFor $committed).Status -eq "committed") -FailureMessage (Get-StateFor $committed).Message

        [IO.File]::WriteAllText($config, "verification:`n  quick:`n    - name: unit`n      command: exit 0`n")
        $state = Get-StateFor $config
        Assert-Result -Name "an edit that weakens a check is modified" -Condition ($state.Status -eq "modified" -and $state.Message.Contains($config) -and $state.Remedy.Contains("git add .crucible/config.yaml")) -FailureMessage $state.Message

        $null = Invoke-ExternalCommand { git -C $proj add .crucible/config.yaml }
        Assert-Result -Name "a staged but uncommitted edit is modified" -Condition ((Get-StateFor $config).Status -eq "modified") -FailureMessage (Get-StateFor $config).Message
        $null = Invoke-ExternalCommand { git -C $proj reset --quiet -- .crucible/config.yaml }

        # skip-worktree hides the edit from git status; the content hash still sees it.
        $null = Invoke-ExternalCommand { git -C $proj update-index --skip-worktree .crucible/config.yaml }
        $porcelain = (Invoke-ExternalCommand { git -C $proj status --porcelain -- .crucible/config.yaml }).Output -join ""
        Assert-Result -Name "the skip-worktree fixture is hidden from status" -Condition ([string]::IsNullOrWhiteSpace($porcelain)) -FailureMessage ("status still shows the edit: " + $porcelain)
        Assert-Result -Name "an edit hidden by skip-worktree is modified" -Condition ((Get-StateFor $config).Status -eq "modified") -FailureMessage (Get-StateFor $config).Message
        $null = Invoke-ExternalCommand { git -C $proj update-index --no-skip-worktree .crucible/config.yaml }
    }

    $results += Run-Test -Name "A CRLF checkout of a committed LF config is committed under autocrlf (item 254)" -Body {
        $proj = New-CommitStateRepo -Name "commit-state-crlf" -CommitConfig
        $config = Join-Path $proj ".crucible/config.yaml"
        $null = Invoke-ExternalCommand { git -C $proj config core.autocrlf true }
        [IO.File]::WriteAllText($config, "verification:`r`n  quick:`r`n    - name: unit`r`n      command: exit 5`r`n")
        $state = Get-StateFor $config
        Assert-Result -Name "line-ending conversion alone is not an edit" -Condition ($state.Status -eq "committed") -FailureMessage $state.Message
    }

    $results += Run-Test -Name "Config commit state refuses untracked, ignored, non-git and missing configs by name (item 254)" -Body {
        $untracked = Join-Path (New-CommitStateRepo -Name "commit-state-untracked") ".crucible/config.yaml"
        $state = Get-StateFor $untracked
        Assert-Result -Name "an untracked config is uncommitted" -Condition ($state.Status -eq "uncommitted" -and $state.Message.Contains($untracked) -and $state.Remedy.Contains("git add .crucible/config.yaml")) -FailureMessage $state.Message

        $ignored = Join-Path (New-CommitStateRepo -Name "commit-state-ignored" -GitIgnore ".crucible/config.yaml") ".crucible/config.yaml"
        $state = Get-StateFor $ignored
        Assert-Result -Name "an ignored config is ignored" -Condition ($state.Status -eq "ignored" -and $state.Message.Contains($ignored) -and $state.Remedy.Contains("git check-ignore -v .crucible/config.yaml")) -FailureMessage $state.Message

        $plain = Join-Path $tempRoot "commit-state-plain"
        $null = New-Item -ItemType Directory -Path (Join-Path $plain ".crucible") -Force
        $plainConfig = Join-Path $plain ".crucible/config.yaml"
        [IO.File]::WriteAllText($plainConfig, "verification:`n")
        $savedCeiling = $env:GIT_CEILING_DIRECTORIES
        $env:GIT_CEILING_DIRECTORIES = $tempRoot
        try { $state = Get-StateFor $plainConfig } finally { $env:GIT_CEILING_DIRECTORIES = $savedCeiling }
        Assert-Result -Name "a config outside git is not-git" -Condition ($state.Status -eq "not-git" -and $state.Message.Contains($plainConfig)) -FailureMessage $state.Message

        $missing = Join-Path $plain "nothing/config.yaml"
        $state = Get-StateFor $missing
        Assert-Result -Name "a missing config is missing" -Condition ($state.Status -eq "missing" -and $state.Message.Contains($missing)) -FailureMessage $state.Message

        $message = (Get-StateFor $untracked).Message
        Assert-Result -Name "the checks source refuses with the file and the remedy" -Condition ($message.Contains($untracked) -and $message.Contains("Remedy:") -and $null -eq (Get-StateFor $untracked).Content) -FailureMessage $message
    }

    # Codex review of de0f0f4, finding 1: git ran from the config's directory, so a nested
    # repository there could commit a weakened config and vouch for it.
    $results += Run-Test -Name "A nested repository inside .crucible cannot vouch for a weakened config (item 254)" -Body {
        $proj = New-CommitStateRepo -Name "commit-state-nested" -CommitConfig
        $config = Join-Path $proj ".crucible/config.yaml"
        $nested = Join-Path $proj ".crucible"
        [IO.File]::WriteAllText($config, "verification:`n  quick:`n    - name: unit`n      command: exit 0`n")
        $null = Invoke-ExternalCommand { git -C $nested init --quiet }
        $null = Invoke-ExternalCommand { git -C $nested add -- config.yaml }
        $null = Invoke-ExternalCommand { git -C $nested -c user.name=t -c user.email=t@example.com -c commit.gpgSign=false commit --quiet -m weakened }
        $nestedHead = (Invoke-ExternalCommand { git -C $nested rev-parse --verify --quiet "HEAD:config.yaml" }).ExitCode
        Assert-Result -Name "the nested repository committed the weakened config" -Condition ($nestedHead -eq 0) -FailureMessage "fixture: the nested commit did not record config.yaml"
        $state = Get-StateFor $config
        Assert-Result -Name "a config owned by a nested repository is refused by name" -Condition ($state.Status -eq "nested-repo" -and $state.Message.Contains($config) -and $state.Remedy.Contains("nested repository")) -FailureMessage ($state.Status + ": " + $state.Message)
    }

    # Finding 2: the runner derives its settings from the bytes that were verified.
    $results += Run-Test -Name "A committed config returns the verified bytes as its content (item 254)" -Body {
        $proj = New-CommitStateRepo -Name "commit-state-content" -CommitConfig
        $config = Join-Path $proj ".crucible/config.yaml"
        $state = Get-StateFor $config
        Assert-Result -Name "the verified content is the committed text" -Condition ($state.Status -eq "committed" -and $state.Content -ceq [IO.File]::ReadAllText($config)) -FailureMessage ($state.Status + ": " + [string]$state.Content)
        $paths = Get-ConfiguredPath -Key "session" -ProjectRoot $proj -Content "paths:`n  session: .crucible/from-content`n"
        Assert-Result -Name "a supplied content is read instead of the file" -Condition ($paths -eq (Join-Path $proj ".crucible/from-content")) -FailureMessage $paths
    }

    # Codex re-review of 8e0a26e: an unreadable config is a named state, not a throw, and
    # every accessor given -Content reads it instead of the file.
    $results += Run-Test -Name "An unreadable committed config is a named state, not an exception (item 254)" -Body {
        $proj = New-CommitStateRepo -Name "commit-state-unreadable" -CommitConfig
        $config = Join-Path $proj ".crucible/config.yaml"
        $lock = [IO.File]::Open($config, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            $state = $null
            $thrown = ""
            try { $state = Get-StateFor $config } catch { $thrown = $_.Exception.Message }
        } finally { $lock.Dispose() }
        Assert-Result -Name "an unreadable config returns the unreadable state" -Condition ($thrown -eq "" -and $null -ne $state -and $state.Status -eq "unreadable" -and $state.Message.Contains($config) -and $state.Message.Contains("Remedy:")) -FailureMessage ("thrown: " + $thrown + "; state: " + $(if ($state) { $state.Status + ": " + $state.Message } else { "<none>" }))
    }

    $results += Run-Test -Name "The review accessor reads supplied content instead of the file (item 254)" -Body {
        $empty = Join-Path $tempRoot "review-content-no-config"
        $null = New-Item -ItemType Directory -Path $empty -Force
        $value = Get-ConfiguredReview -Key auto_push -ProjectRoot $empty -Content "review:`n  auto_push: true`n"
        Assert-Result -Name "supplied review content is honored with no config file" -Condition ($value -eq "true") -FailureMessage ("got '" + $value + "'")
        $proj = New-CommitStateRepo -Name "review-content-over-file"
        [IO.File]::WriteAllText((Join-Path $proj ".crucible/config.yaml"), "review:`n  auto_push: false`n")
        $value = Get-ConfiguredReview -Key auto_push -ProjectRoot $proj -Content "review:`n  auto_push: true`n"
        Assert-Result -Name "supplied review content wins over the file" -Condition ($value -eq "true") -FailureMessage ("got '" + $value + "'")
    }

    # Finding 3: a symlinked config is refused by name, in HEAD or on disk. The HEAD case
    # stages a 120000 entry directly, so it runs on hosts that cannot create a link.
    $results += Run-Test -Name "A config committed as a symbolic link is refused by name, not reported modified (item 254)" -Body {
        $proj = New-CommitStateRepo -Name "commit-state-symlink-head"
        $config = Join-Path $proj ".crucible/config.yaml"
        $linkBlob = ((Invoke-ExternalCommand { "../real-config.yaml" | git -C $proj hash-object -w --stdin }).Output -join "").Trim()
        $null = Invoke-ExternalCommand { git -C $proj update-index --add --cacheinfo ("120000," + $linkBlob + ",.crucible/config.yaml") }
        $null = Invoke-ExternalCommand { git -C $proj -c user.name=t -c user.email=t@example.com -c commit.gpgSign=false commit --quiet -m link }
        $mode = ((Invoke-ExternalCommand { git -C $proj ls-tree HEAD -- .crucible/config.yaml }).Output -join "")
        Assert-Result -Name "the fixture committed a symbolic link" -Condition ($mode.StartsWith("120000")) -FailureMessage ("ls-tree: " + $mode)
        $state = Get-StateFor $config
        Assert-Result -Name "a committed symlink config is refused as a symlink" -Condition ($state.Status -eq "symlink" -and $state.Message.Contains($config) -and $state.Remedy.Contains("regular file")) -FailureMessage ($state.Status + ": " + $state.Message)
    }

    $results += Run-Test -Name "A config that is a symbolic link on disk is refused by name (item 254)" -Body {
        $proj = New-CommitStateRepo -Name "commit-state-symlink-disk" -CommitConfig
        $config = Join-Path $proj ".crucible/config.yaml"
        $target = Join-Path $proj "same-config.yaml"
        [IO.File]::WriteAllText($target, [IO.File]::ReadAllText($config))
        Remove-Item -LiteralPath $config -Force
        try { $null = New-Item -ItemType SymbolicLink -Path $config -Target $target -ErrorAction Stop } catch { Skip-Test ("this host cannot create a symbolic link: " + $_.Exception.Message); return }
        $state = Get-StateFor $config
        Assert-Result -Name "a symlink to identical content is still refused" -Condition ($state.Status -eq "symlink" -and $state.Message.Contains($config)) -FailureMessage ($state.Status + ": " + $state.Message)
    }}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
