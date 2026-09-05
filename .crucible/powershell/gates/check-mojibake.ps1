param(
    [Parameter(Mandatory = $false, ValueFromRemainingArguments = $true)]
    [string[]]$Paths = @()
)

if ($Paths.Count -eq 0) {
    # ../.. because this script lives in <root>/powershell/gates. A single ".." landed on
    # powershell/ itself, where none of the content paths below exist, so every default
    # path was skipped as missing and a bare invocation scanned zero files and exited 0.
    $contentRoot = (Resolve-Path -Path "$PSScriptRoot/../..").Path
    $isFramework = (Test-Path -LiteralPath (Join-Path $contentRoot "proposals")) -and (Test-Path -LiteralPath (Join-Path $contentRoot "powershell/run-all-tests.ps1"))

    if ($isFramework) {
        # Keep in sync with the explicit list in scripts/hooks/pre-commit.
        # check-mojibake.tests.ps1 pins both against the tracked root *.md files.
        $Paths = @(
            (Join-Path $contentRoot "prompts"),
            (Join-Path $contentRoot "personas"),
            (Join-Path $contentRoot "sops"),
            (Join-Path $contentRoot "docs"),
            (Join-Path $contentRoot "powershell"),
            (Join-Path $contentRoot "templates"),
            (Join-Path $contentRoot "README.md"),
            (Join-Path $contentRoot "ROADMAP.md"),
            (Join-Path $contentRoot "CHANGELOG.md"),
            (Join-Path $contentRoot "CONTRIBUTING.md"),
            (Join-Path $contentRoot "TODO.md")
        )
    } else {
        $Paths = @(
            (Join-Path $contentRoot "prompts"),
            (Join-Path $contentRoot "personas"),
            (Join-Path $contentRoot "sops"),
            (Join-Path $contentRoot "docs"),
            (Join-Path $contentRoot "powershell"),
            (Join-Path $contentRoot "templates"),
            (Join-Path $contentRoot "README.md")
        )
    }
}
$ErrorActionPreference = "Stop"

$markers = @(
    ([string]([char]0x00C3)),                                              # mojibake capital A-tilde
    ([string]([char]0x00C2)),                                              # mojibake capital A-circumflex
    ([string]::Concat([char]0x00E2, [char]0x2020, [char]0x2019)),          # mojibake capital A-circumflex?'
    ([string]::Concat([char]0x00E2, [char]0x20AC, [char]0x201D)),          # mojibake capital A-circumflex?"
    ([string]::Concat([char]0x00E2, [char]0x20AC, [char]0x201C)),          # mojibake capital A-circumflex?"
    ([string]::Concat([char]0x00E2, [char]0x20AC, [char]0x0153)),          # mojibake capital A-circumflex??
    ([string]::Concat([char]0x00E2, [char]0x20AC, [char]0x2122))           # mojibake capital A-circumflex??
)

$targetFiles = @()
foreach ($path in $Paths) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        if ($path -match '\.(md|ps1)$') {
            $targetFiles += Get-Item -LiteralPath $path
        }
    } else {
        $targetFiles += Get-ChildItem -Path $path -Recurse -File |
            Where-Object { $_.Extension -in @(".md", ".ps1") }
    }
}

$hits = @()
foreach ($file in $targetFiles) {
    # BOM detection: a UTF-8 byte-order mark (EF BB BF) is invisible to the mojibake
    # marker scan below (Select-String -Encoding UTF8 consumes it), yet it corrupts
    # docs and diffs. Read the leading bytes directly and flag it as its own hit.
    $prefix = New-Object byte[] 3
    $fs = [System.IO.File]::OpenRead($file.FullName)
    try {
        $read = $fs.Read($prefix, 0, 3)
    } finally {
        $fs.Dispose()
    }
    if ($read -eq 3 -and $prefix[0] -eq 0xEF -and $prefix[1] -eq 0xBB -and $prefix[2] -eq 0xBF) {
        $hits += [pscustomobject]@{
            Path    = $file.FullName
            Line    = 1
            Marker  = "UTF-8 BOM"
            Snippet = "file begins with a UTF-8 byte-order mark (EF BB BF)"
        }
    }

    foreach ($marker in $markers) {
        $matches = Select-String -Path $file.FullName -SimpleMatch -Pattern $marker -Encoding UTF8
        foreach ($m in $matches) {
            $hits += [pscustomobject]@{
                Path    = $m.Path
                Line    = $m.LineNumber
                Marker  = $marker
                Snippet = $m.Line.Trim()
            }
        }
    }
}

if ($hits.Count -gt 0) {
    Write-Host "[FAIL] Encoding issues detected (mojibake markers / UTF-8 BOM):" -ForegroundColor Red
    $hits | Sort-Object Path, Line, Marker | ForEach-Object {
        Write-Host ("{0}:{1} [{2}] {3}" -f $_.Path, $_.Line, $_.Marker, $_.Snippet)
    }
    exit 1
}

Write-Host "[PASS] No mojibake markers or BOMs detected in scoped files." -ForegroundColor Green
exit 0
