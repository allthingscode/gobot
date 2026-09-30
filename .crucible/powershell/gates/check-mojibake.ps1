# PositionalBinding = $false, with an explicit Position only on $Paths. Without it
# $MessageFile is implicitly positional too, and a lone positional argument binds to it
# instead of to $Paths - so `check-mojibake.ps1 README.md` would quietly take the
# single-file message route while two or more arguments took the other. Caught by the
# declined-extension case in check-mojibake.tests.ps1, which is the only case whose result
# differs between the two routes.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $false, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Paths = @(),

    # One file to scan whatever its extension. The extension filter below exists so a
    # directory walk does not read .go or .json, but it also silently skipped an explicit
    # leaf path it did not recognise. A commit message file is the case that matters: it is
    # neither .md nor .ps1, it lives outside every content root, and a BOM in it becomes the
    # first character of a subject line that no later commit can correct once pushed. A
    # single string rather than an array because powershell.exe -File binds only the first
    # token of a named array parameter. Item 89.
    [string]$MessageFile = "",

    # Scan only the staged files that fall inside the default scope below, which is what the
    # framework pre-commit runs; pre-push runs the whole default scope, so a push still
    # checks everything. Item 151.
    [switch]$Staged
)

if ($Staged -and ($Paths.Count -gt 0 -or $MessageFile)) {
    Write-Host "[FAIL] -Staged takes no paths and no -MessageFile; it scans the staged files in the default scope." -ForegroundColor Red
    exit 1
}

if ($Paths.Count -eq 0 -and -not $MessageFile) {
    # ../.. because this script lives in <root>/powershell/gates. A single ".." landed on
    # powershell/ itself, where none of the content paths below exist, so every default
    # path was skipped as missing and a bare invocation scanned zero files and exited 0.
    $contentRoot = (Resolve-Path -Path "$PSScriptRoot/../..").Path
    $isFramework = (Test-Path -LiteralPath (Join-Path $contentRoot "proposals")) -and (Test-Path -LiteralPath (Join-Path $contentRoot "powershell/run-all-tests.ps1"))

    if ($isFramework) {
        # Keep in sync with the explicit list in scripts/hooks/pre-push.
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

    if ($Staged) {
        Push-Location $contentRoot
        try {
            $stagedNames = @(git diff --cached --name-only --diff-filter=ACMR)
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[FAIL] git diff --cached failed, so no staged file list could be built." -ForegroundColor Red
                exit 1
            }
        } finally {
            Pop-Location
        }
        $scope = @($Paths | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/') })
        $stagedInScope = @()
        foreach ($rel in $stagedNames) {
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            if ($rel -notmatch '\.(md|ps1)$') { continue }
            $full = [System.IO.Path]::GetFullPath((Join-Path $contentRoot $rel))
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            foreach ($root in $scope) {
                if ($full.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $full.StartsWith($root + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $stagedInScope += $full
                    break
                }
            }
        }
        $Paths = $stagedInScope
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
$declined = @()
foreach ($path in $Paths) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        if ($path -match '\.(md|ps1)$') {
            $targetFiles += Get-Item -LiteralPath $path
        } else {
            # Not skipped silently. A caller that names a file and is answered [PASS] has been
            # told the file is clean when it was never opened. Item 89.
            $declined += $path
        }
    } else {
        $targetFiles += Get-ChildItem -Path $path -Recurse -File |
            Where-Object { $_.Extension -in @(".md", ".ps1") }
    }
}

if ($MessageFile) {
    # A message file the hook cannot find is a gate that could not run, not a clean message.
    if (-not (Test-Path -LiteralPath $MessageFile -PathType Leaf)) {
        Write-Host ("[FAIL] -MessageFile names no readable file: " + $MessageFile) -ForegroundColor Red
        exit 1
    }
    $targetFiles += Get-Item -LiteralPath $MessageFile
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

if ($hits.Count -gt 0 -or $declined.Count -gt 0) {
    if ($hits.Count -gt 0) {
        Write-Host "[FAIL] Encoding issues detected (mojibake markers / UTF-8 BOM):" -ForegroundColor Red
        $hits | Sort-Object Path, Line, Marker | ForEach-Object {
            Write-Host ("{0}:{1} [{2}] {3}" -f $_.Path, $_.Line, $_.Marker, $_.Snippet)
        }
        if ($hits | Where-Object { $_.Marker -eq "UTF-8 BOM" }) {
            Write-Host "Rewrite the file as UTF-8 without a BOM. In PowerShell:" -ForegroundColor Yellow
            Write-Host '  [System.IO.File]::WriteAllText($p, [System.IO.File]::ReadAllText($p).TrimStart([char]0xFEFF), (New-Object System.Text.UTF8Encoding($false)))' -ForegroundColor Yellow
        }
    }
    if ($declined.Count -gt 0) {
        Write-Host "[FAIL] Named files this gate does not scan, so nothing was checked for them:" -ForegroundColor Red
        $declined | Sort-Object | ForEach-Object { Write-Host $_ }
        Write-Host "Only .md and .ps1 are walked. Pass one file of any type with -MessageFile." -ForegroundColor Yellow
    }
    exit 1
}

# The count is reported because a pass over zero files and a pass over the whole tree are
# otherwise the same line, which is how a mis-resolved content root once read as green.
Write-Host ("[PASS] No mojibake markers or BOMs detected in " + $targetFiles.Count + " scoped file(s).") -ForegroundColor Green
exit 0
