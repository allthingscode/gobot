# Tests for shared config/path helpers (Get-ConfiguredPath, Parse-SemVer, Compare-SemVer).

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/config-helpers.ps1")

$results = @()







function ToStr($arr) { if ($null -eq $arr) { return "<null>" } return ($arr -join '.') }

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-config-helpers-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results += Run-Test -Name "Parse-SemVer extracts major.minor.patch" -Body {
        Assert-Result -Name "full triple" -Condition ((ToStr (Parse-SemVer "1.2.3")) -eq "1.2.3") -FailureMessage "1.2.3 should parse to 1.2.3"
        Assert-Result -Name "embedded in text" -Condition ((ToStr (Parse-SemVer "crucible v2.10.0 (build 7)")) -eq "2.10.0") -FailureMessage "should extract embedded version"
        Assert-Result -Name "two-part defaults patch 0" -Condition ((ToStr (Parse-SemVer "1.4")) -eq "1.4.0") -FailureMessage "1.4 should parse to 1.4.0"
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
