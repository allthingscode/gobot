$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/factory-lib.ps1")

# ConvertTo-AsciiSafeText (factory-lib.ps1) guards reason strings against mojibake: agents
# emit smart punctuation that corrupts on a UTF-8 JSON round-trip. Inputs are built from
# codepoints so this test file itself stays ASCII-safe.

$results = @()

$results += Run-Test -Name "Transliterates em/en dashes to hyphen" -Body {
    $text = "Review approved " + [char]0x2014 + " no blockers" + [char]0x2013 + "ship"
    $out = ConvertTo-AsciiSafeText -Text $text
    Assert-Result -Name "ascii only" -Condition ($out -eq "Review approved - no blockers-ship") -FailureMessage "got '$out'"
}

$results += Run-Test -Name "Transliterates curly quotes, ellipsis, arrow, bullet, nbsp" -Body {
    $text = [char]0x201C + "done" + [char]0x201D + [char]0x2026 + [char]0x00A0 + [char]0x2192 + [char]0x2022 + [char]0x2019
    $out = ConvertTo-AsciiSafeText -Text $text
    Assert-Result -Name "expected" -Condition ($out -eq ('"done"... ->*' + "'")) -FailureMessage "got '$out'"
}

$results += Run-Test -Name "Drops remaining non-ASCII (accents, emoji)" -Body {
    $text = "caf" + [char]0x00E9 + " " + [char]0x2764
    $out = ConvertTo-AsciiSafeText -Text $text
    Assert-Result -Name "dropped" -Condition ($out -eq "caf ") -FailureMessage "got '$out'"
}

$results += Run-Test -Name "Leaves plain ASCII unchanged" -Body {
    $text = "plain ascii reason 123 (ok)!"
    $out = ConvertTo-AsciiSafeText -Text $text
    Assert-Result -Name "unchanged" -Condition ($out -eq $text) -FailureMessage "got '$out'"
}

$results += Run-Test -Name "Passes through empty and null" -Body {
    Assert-Result -Name "empty" -Condition ((ConvertTo-AsciiSafeText -Text "") -eq "") -FailureMessage "empty changed"
    $n = ConvertTo-AsciiSafeText -Text $null
    Assert-Result -Name "null" -Condition ([string]::IsNullOrEmpty($n)) -FailureMessage "null not passthrough"
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
