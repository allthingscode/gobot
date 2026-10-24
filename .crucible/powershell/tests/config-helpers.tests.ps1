# Tests for shared config/path helpers (Get-ConfiguredPath, Parse-SemVer, Compare-SemVer).

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/config-helpers.ps1")

$results = @()







function ToStr($arr) { if ($null -eq $arr) { return "<null>" } return ($arr -join '.') }

$tempRoot = New-TestFixtureRoot -NameHint "config-helpers-test"

try {
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
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
