# Reason text shared by every surface that records a human's reason: the Human Gate, new-handoff
# and retire-check-not-run.ps1. Dependency-free so lib/checks-not-run.ps1 can enforce the reason
# rule itself (item 259).

function ConvertTo-AsciiSafeText {
    # Transliterate the smart punctuation agents routinely emit (em/en dashes, curly
    # quotes, ellipsis, arrows, bullet, nbsp) to ASCII, then drop any remaining non-ASCII
    # so a reason string survives a UTF-8 JSON round-trip without mojibake. Reasons are
    # short human-readable strings, not content, so lossy transliteration is acceptable.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $map = @{
        [char]0x2013 = '-'; [char]0x2014 = '-'; [char]0x2012 = '-'; [char]0x2015 = '-'
        [char]0x2018 = "'"; [char]0x2019 = "'"; [char]0x201A = "'"; [char]0x2032 = "'"
        [char]0x201C = '"'; [char]0x201D = '"'; [char]0x201E = '"'; [char]0x2033 = '"'
        [char]0x2026 = '...'; [char]0x2192 = '->'; [char]0x2190 = '<-'; [char]0x2022 = '*'
        [char]0x00A0 = ' '
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        if ($map.ContainsKey($ch)) {
            [void]$sb.Append($map[$ch])
        } elseif ([int]$ch -lt 128) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString()
}

function Get-LowSignalGateReasons {
    # Exact phrases only, compared after trim and lowercase. A stock phrase with
    # more words ("Looks good. I see nothing concerning.") is the human's reason
    # and is recorded. sops/deployment.md and prompts/deployment_prompt.md list
    # these; gate-reason-rule.tests.ps1 keeps them in step. Item 144.
    return @(
        "n/a", "na", "none", "ok", "looks good", "looks good.",
        "approved", "accept", "accepted", "done", "ship it", "auto"
    )
}

function Test-GateReasonRefused {
    param([string]$Reason)
    if ([string]::IsNullOrWhiteSpace($Reason)) { return $true }
    $normalized = (ConvertTo-AsciiSafeText -Text $Reason).Trim().ToLowerInvariant()
    if ($normalized -eq "") { return $true }
    return ((Get-LowSignalGateReasons) -contains $normalized)
}
