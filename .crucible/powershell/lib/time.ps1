function Get-UtcTimestamp {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-UtcFileTimestamp {
    return (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-UtcFileTimestampMs {
    return (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ", [System.Globalization.CultureInfo]::InvariantCulture)
}

# PowerShell 7's ConvertFrom-Json parses ISO-8601 strings into [DateTime]; 5.1 leaves them
# as strings. Normalize both back to ISO-8601 UTC so a rendered timestamp does not depend
# on which engine read the log, and so ordinal comparison of two of them stays chronological.
function Get-IsoTimestamp {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime] -or $Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function ConvertFrom-IsoTimestamp {
    param($Value)
    $timestamp = Get-IsoTimestamp $Value
    if ($null -eq $timestamp) { return $null }
    return [DateTimeOffset]::Parse(
        [string]$timestamp,
        [System.Globalization.CultureInfo]::InvariantCulture,
        ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    )
}
