# Injection detector library.
# Exposes Get-InjectionMatches and Test-InjectionContent for prompt injection checking.

function Get-InjectionMatches {
    param(
        [Parameter(Mandatory=$true)][AllowNull()][AllowEmptyString()][string]$Text,
        [string]$RulesPath
    )

    if ([string]::IsNullOrEmpty($RulesPath)) {
        # Default to the ruleset next to this lib (resolved relatively to schemas/)
        $RulesPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../schemas/injection-rules.json"))
    }

    if (-not (Test-Path -LiteralPath $RulesPath -PathType Leaf)) {
        throw "Ruleset file not found at path: $RulesPath"
    }

    $rules = $null
    try {
        $content = Get-Content -LiteralPath $RulesPath -Raw -Encoding UTF8
        $rules = $content | ConvertFrom-Json
    } catch {
        throw "Failed to load or parse ruleset: $_"
    }

    if ($null -eq $rules) {
        throw "Ruleset is empty or invalid JSON: $RulesPath"
    }

    $matches = @()

    # Empty string and whitespace return clean (no throw)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ,$matches
    }

    # Normalize:
    # 1. Zero-width / bidi / control character rule runs against the RAW text.
    # 2. Literal rules run against normalized text: lowercase and zero-width/control characters stripped.
    $normalizedText = [System.Text.RegularExpressions.Regex]::Replace($Text, '[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]', '')
    $normalizedText = $normalizedText.ToLower()

    # Enforce rules as array
    $ruleArray = @()
    if ($rules -is [array]) {
        $ruleArray = $rules
    } else {
        $ruleArray = @($rules)
    }

    foreach ($rule in $ruleArray) {
        if (-not $rule.id -or -not $rule.pattern -or -not $rule.category -or -not $rule.severity) {
            throw "Invalid rule definition in ruleset. Required keys: id, pattern, category, severity."
        }

        # Select target text based on rule ID
        $targetText = $normalizedText
        if ($rule.id -eq "zero-width-control") {
            $targetText = $Text
        }

        try {
            $regex = [System.Text.RegularExpressions.Regex]::new($rule.pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $regexMatches = $regex.Matches($targetText)
            foreach ($m in $regexMatches) {
                $matches += [PSCustomObject]@{
                    RuleId   = $rule.id
                    Category = $rule.category
                    Severity = $rule.severity
                    Excerpt  = $m.Value
                }
            }
        } catch {
            throw "Invalid regex pattern in rule '$($rule.id)': $($rule.pattern). Error: $_"
        }
    }

    return ,$matches
}

function Test-InjectionContent {
    param(
        [Parameter(Mandatory=$true)][AllowNull()][AllowEmptyString()][string]$Text,
        [string]$RulesPath
    )

    $matches = Get-InjectionMatches -Text $Text -RulesPath $RulesPath
    if ($null -eq $matches) {
        return $false
    }

    if ($matches -is [array]) {
        return ($matches.Count -gt 0)
    }

    return $true
}
