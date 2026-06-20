# Smoke tests for powershell/init-project.ps1 (Append Instructions).

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
$env:CRUCIBLE_SKIP_PROVENANCE = "true"
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$SCRIPT = Join-Path $REPO_ROOT "powershell/init-project.ps1"
$results = @()

function Invoke-InitScript {
    $cleanArray = @()
    $i = 0
    while ($i -lt $args.Count) {
        $arg = $args[$i]
        if ($arg -eq "-AsSubprocess") {
            $i++
            continue
        }
        $cleanArray += $arg
        $i++
    }

    $output = @(& (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $SCRIPT @cleanArray 2>&1)
    return $output
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("crucible-init-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    # --- AppendInstructions tests ---
    $appendRoot = Join-Path $tempRoot "append-app"

    $results += Run-Test -Name "AppendInstructions creates instruction files with sentinel markers" -Body {
        $outputLines = @(Invoke-InitScript `
            -ProjectRoot $appendRoot `
            -ProjectName "Append Test" `
            -AppendInstructions `
            -Quiet 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "append exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)

        foreach ($fileName in @("AGENTS.md", "CLAUDE.md", "GEMINI.md")) {
            $filePath = Join-Path $appendRoot $fileName
            Assert-Result -Name "$fileName exists" -Condition (Test-Path -LiteralPath $filePath) -FailureMessage "$fileName was not created"

            $content = Get-Content -LiteralPath $filePath -Raw -Encoding UTF8
            $startCount = ([regex]::Matches($content, "crucible-instructions-start")).Count
            $endCount   = ([regex]::Matches($content, "crucible-instructions-end")).Count
            Assert-Result -Name "$fileName has start marker" -Condition ($startCount -eq 1) -FailureMessage ("expected 1 start marker, got " + $startCount)
            Assert-Result -Name "$fileName has end marker"   -Condition ($endCount -eq 1) -FailureMessage ("expected 1 end marker, got " + $endCount)
        }

        # Verify AGENTS.md contains canonical content
        $agentsContent = Get-Content -LiteralPath (Join-Path $appendRoot "AGENTS.md") -Raw -Encoding UTF8
        Assert-Result -Name "AGENTS has crucible heading" -Condition ($agentsContent -match "## Crucible") -FailureMessage "AGENTS.md missing Crucible heading"
        Assert-Result -Name "AGENTS has factory snippet" -Condition ($agentsContent -match "factory\.ps1") -FailureMessage "AGENTS.md missing factory.ps1 snippet"
        Assert-Result -Name "AGENTS has commit list" -Condition ($agentsContent -match "Commit durable Crucible files") -FailureMessage "AGENTS.md missing commit list"
    }

    $results += Run-Test -Name "AppendInstructions skips when block already exists (idempotent)" -Body {
        # appendRoot already has instruction files from the previous test

        # Capture file contents before re-run
        $beforeAgents = Get-Content -LiteralPath (Join-Path $appendRoot "AGENTS.md") -Raw -Encoding UTF8
        $beforeClaude = Get-Content -LiteralPath (Join-Path $appendRoot "CLAUDE.md") -Raw -Encoding UTF8
        $beforeGemini = Get-Content -LiteralPath (Join-Path $appendRoot "GEMINI.md") -Raw -Encoding UTF8

        $outputLines = @(Invoke-InitScript `
            -ProjectRoot $appendRoot `
            -AppendInstructions `
            -Force `
            -Quiet 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "rerun exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)

        # Marker count unchanged
        $agentsContent = Get-Content -LiteralPath (Join-Path $appendRoot "AGENTS.md") -Raw -Encoding UTF8
        $startCount = ([regex]::Matches($agentsContent, "crucible-instructions-start")).Count
        Assert-Result -Name "still one marker" -Condition ($startCount -eq 1) -FailureMessage ("expected 1 start marker after rerun, got " + $startCount)

        # Content byte-identical
        $afterAgents = Get-Content -LiteralPath (Join-Path $appendRoot "AGENTS.md") -Raw -Encoding UTF8
        $afterClaude = Get-Content -LiteralPath (Join-Path $appendRoot "CLAUDE.md") -Raw -Encoding UTF8
        $afterGemini = Get-Content -LiteralPath (Join-Path $appendRoot "GEMINI.md") -Raw -Encoding UTF8
        Assert-Result -Name "AGENTS unchanged" -Condition ($beforeAgents -eq $afterAgents) -FailureMessage "AGENTS.md content changed on rerun"
        Assert-Result -Name "CLAUDE unchanged" -Condition ($beforeClaude -eq $afterClaude) -FailureMessage "CLAUDE.md content changed on rerun"
        Assert-Result -Name "GEMINI unchanged" -Condition ($beforeGemini -eq $afterGemini) -FailureMessage "GEMINI.md content changed on rerun"
    }

    $results += Run-Test -Name "AppendInstructions aborts on corrupt sentinel markers" -Body {
        $corruptRoot = Join-Path $tempRoot "corrupt-app"

        # First create a valid scaffold
        $null = @(Invoke-InitScript `
            -ProjectRoot $corruptRoot `
            -ProjectName "Corrupt Test" `
            -Quiet 2>&1)

        # Create an AGENTS.md with only the start marker (no end marker)
        $corruptAgents = Join-Path $corruptRoot "AGENTS.md"
        Set-Content -LiteralPath $corruptAgents -Value "# My Project`n`n<!-- crucible-instructions-start -->`nSome content without end marker" -Encoding UTF8

        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $outputLines = @(Invoke-InitScript `
                -ProjectRoot $corruptRoot `
                -AppendInstructions `
                -Force `
                -Quiet 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $output = $outputLines -join "`n"
        Assert-Result -Name "corrupt exit" -Condition ($exitCode -ne 0) -FailureMessage ("expected non-zero exit on corrupt markers. Output: " + $output)
        Assert-Result -Name "corrupt message" -Condition ($output -match "corrupted|mismatched") -FailureMessage ("expected corruption error message. Output: " + $output)
    }

    $results += Run-Test -Name "AppendInstructions preserves personal content byte-for-byte" -Body {
        $preserveRoot = Join-Path $tempRoot "preserve-app"

        # Create scaffold first (without AppendInstructions)
        $null = @(Invoke-InitScript `
            -ProjectRoot $preserveRoot `
            -ProjectName "Preserve Test" `
            -Quiet 2>&1)

        # Create an AGENTS.md with personal content above and below where block will land
        $personalAgents = Join-Path $preserveRoot "AGENTS.md"
        $personalContent = "# My Personal Rules`n`nThese are my private workflow notes.`nDo not touch this content.`n`n## My Other Section`n`nMore personal content here.`n"
        [System.IO.File]::WriteAllText($personalAgents, $personalContent, [System.Text.UTF8Encoding]::new($false))

        # Run AppendInstructions
        $outputLines = @(Invoke-InitScript `
            -ProjectRoot $preserveRoot `
            -AppendInstructions `
            -Force `
            -Quiet 2>&1)
        $output = $outputLines -join "`n"
        Assert-Result -Name "preserve exit" -Condition ($LASTEXITCODE -eq 0) -FailureMessage ("expected exit 0, got " + $LASTEXITCODE + ". Output: " + $output)

        # Read back and verify personal content is preserved at the start
        $result = Get-Content -LiteralPath $personalAgents -Raw -Encoding UTF8
        Assert-Result -Name "starts with personal" -Condition ($result.StartsWith("# My Personal Rules")) -FailureMessage "personal content header was modified"
        Assert-Result -Name "has personal notes" -Condition ($result -match "These are my private workflow notes\.") -FailureMessage "personal workflow notes were modified"
        Assert-Result -Name "has other section" -Condition ($result -match "## My Other Section") -FailureMessage "personal section was modified"
        Assert-Result -Name "has more personal" -Condition ($result -match "More personal content here\.") -FailureMessage "trailing personal content was modified"

        # Also verify the block was appended
        Assert-Result -Name "has crucible block" -Condition ($result -match "crucible-instructions-start") -FailureMessage "Crucible block was not appended"
        Assert-Result -Name "has crucible end" -Condition ($result -match "crucible-instructions-end") -FailureMessage "Crucible end marker was not appended"
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($results -contains $false) {
    Write-Host "`nSOME TESTS FAILED" -ForegroundColor Red
    exit 1
}

Write-Host ("`nALL TESTS PASSED (" + $results.Count + " tests)") -ForegroundColor Green
exit 0
