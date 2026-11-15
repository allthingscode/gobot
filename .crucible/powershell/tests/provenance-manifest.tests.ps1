# Tests for the provenance manifest generator in powershell/lib/install-manifest.ps1.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $PSScriptRoot '_fixtures.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/install-manifest.ps1")
$results = @()

function Write-Utf8File {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function New-FrameworkFixture {
    param([Parameter(Mandatory=$true)][string]$Root)
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    git -C $Root init --quiet | Out-Null
    git -C $Root config core.autocrlf false | Out-Null
    git -C $Root config core.safecrlf false | Out-Null
    Write-Utf8File -Path (Join-Path $Root "install-manifest.json") -Content @'
{
  "scaffold_source": "templates/project/.crucible",
  "root_files": ["install-manifest.json"],
  "copied_dirs": ["docs", "powershell", "templates"],
  "adopter_owned_excludes": ["config.yaml", "backlog/**", "session/**", "research/**", ".gemini/**", ".private/**", ".agent-workspaces/**"]
}
'@
    Write-Utf8File -Path (Join-Path $Root "templates/project/.crucible/config.yaml") -Content 'project: fixture'
    Write-Utf8File -Path (Join-Path $Root "templates/project/.crucible/README.md") -Content 'readme baseline'
    Write-Utf8File -Path (Join-Path $Root "templates/project/.crucible/backlog/F-000.md") -Content 'template backlog'
    Write-Utf8File -Path (Join-Path $Root "docs/guide.md") -Content 'guide baseline'
    Write-Utf8File -Path (Join-Path $Root "powershell/tool.ps1") -Content 'Write-Host "baseline"'
    return Invoke-GitCommit -Repo $Root -Message "baseline"
}

$tempRoot = New-TestFixtureRoot -NameHint "provenance-test"

try {
    $results += Run-Test -Name "Manifest maps bundle paths to LF-normalized hashes with version and source_commit" -Body {
        $framework = Join-Path $tempRoot "gen-framework"
        $commit = New-FrameworkFixture -Root $framework
        $provenance = New-ProvenanceManifest -FrameworkRoot $framework -Commit $commit

        Assert-Result -Name "manifest_version is 1" -Condition ($provenance.manifest_version -eq 1) -FailureMessage "manifest_version not 1"
        Assert-Result -Name "source_commit recorded" -Condition ($provenance.source_commit -eq $commit) -FailureMessage "source_commit mismatch"

        $names = @($provenance.files.PSObject.Properties.Name)
        Assert-Result -Name "docs/guide.md present" -Condition ($names -contains "docs/guide.md") -FailureMessage ("paths: " + ($names -join ","))
        Assert-Result -Name "powershell/tool.ps1 present" -Condition ($names -contains "powershell/tool.ps1") -FailureMessage ("paths: " + ($names -join ","))

        $expected = Get-GitFileNormalizedHash -Repo $framework -Commit $commit -Path "docs/guide.md"
        Assert-Result -Name "hash matches normalized source" -Condition ($provenance.files."docs/guide.md".hash -eq $expected) -FailureMessage "hash mismatch for docs/guide.md"
        Assert-Result -Name "hash is hex sha256" -Condition ($provenance.files."docs/guide.md".hash -match '^[0-9a-f]{64}$') -FailureMessage "hash is not a sha256 hex string"
    }

    $results += Run-Test -Name "Adopter-owned paths are excluded from the manifest" -Body {
        $framework = Join-Path $tempRoot "exclude-framework"
        $commit = New-FrameworkFixture -Root $framework
        $provenance = New-ProvenanceManifest -FrameworkRoot $framework -Commit $commit
        $names = @($provenance.files.PSObject.Properties.Name)

        # config.yaml (scaffold-derived adopter-owned) and template backlog must be absent
        Assert-Result -Name "config.yaml excluded" -Condition ($names -notcontains "config.yaml") -FailureMessage ("config.yaml leaked: " + ($names -join ","))
        Assert-Result -Name "backlog excluded" -Condition (-not ($names | Where-Object { $_ -like "backlog/*" })) -FailureMessage ("backlog leaked: " + ($names -join ","))
    }

    # Every other test here builds a fixture, commits it, and reads the provenance while the
    # working tree still matches the commit, so nothing pinned the enumeration to $Commit.
    #
    # The content layer is pinned regardless: New-ProvenanceManifest hashes Get-GitFileContent at
    # $Commit and skips anything absent there, so a working-tree edit or an untracked addition
    # cannot reach the manifest. What is NOT pinned is the path set - drop -AtCommit from the
    # enumeration and a file the commit shipped but the working tree no longer has disappears from
    # the manifest, so an adopter updating from that commit is never told the file changed.
    # Deleting from the working tree is the only divergence that shows this.
    #
    # Generate exactly once per (root, commit): New-ProvenanceManifest caches on that key in the
    # temp dir, so a second call for the same pair returns the first result and tests the cache
    # rather than the code.
    $results += Run-Test -Name "Provenance enumerates the named commit, not the working tree" -Body {
        $framework = Join-Path $tempRoot "pinned-framework"
        $commit = New-FrameworkFixture -Root $framework

        Remove-Item -LiteralPath (Join-Path $framework "docs/guide.md") -Force
        Remove-Item -LiteralPath (Join-Path $framework "powershell/tool.ps1") -Force

        $pinned = New-ProvenanceManifest -FrameworkRoot $framework -Commit $commit
        $names = @($pinned.files.PSObject.Properties.Name)

        Assert-Result -Name "deleted tracked file still recorded" -Condition ($names -contains "docs/guide.md") -FailureMessage (
            "docs/guide.md was committed at " + $commit + " but the manifest dropped it after a working-tree delete: " + ($names -join ","))
        Assert-Result -Name "deleted copied-dir file still recorded" -Condition ($names -contains "powershell/tool.ps1") -FailureMessage (
            "powershell/tool.ps1 was committed at " + $commit + " but the manifest dropped it after a working-tree delete: " + ($names -join ","))
        $expected = Get-GitFileNormalizedHash -Repo $framework -Commit $commit -Path "docs/guide.md"
        Assert-Result -Name "hash still that of the commit" -Condition ($pinned.files."docs/guide.md".hash -eq $expected) -FailureMessage (
            "hash for docs/guide.md did not match the committed content at " + $commit)
    }

    $results += Run-Test -Name "EOL differences hash identically (CRLF vs LF)" -Body {
        $framework = Join-Path $tempRoot "eol-framework"
        $commit = New-FrameworkFixture -Root $framework
        $provenance = New-ProvenanceManifest -FrameworkRoot $framework -Commit $commit
        $manifestHash = $provenance.files."docs/guide.md".hash

        # Write the same logical content with CRLF line endings to a working file
        $crlf = Join-Path $tempRoot "eol-working/guide.md"
        Write-Utf8File -Path $crlf -Content "guide baseline`r`n"
        $workingHash = Get-FileNormalizedHash -Path $crlf

        Assert-Result -Name "CRLF hashes equal to manifest" -Condition ($workingHash -eq $manifestHash) -FailureMessage "EOL difference produced a different hash"
    }

    $results += Run-Test -Name "Write/Read round-trips the manifest as UTF-8 without BOM" -Body {
        $framework = Join-Path $tempRoot "io-framework"
        $commit = New-FrameworkFixture -Root $framework
        $provenance = New-ProvenanceManifest -FrameworkRoot $framework -Commit $commit

        $bundleRoot = Join-Path $tempRoot "io-bundle"
        New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null
        $path = Write-ProvenanceManifest -BundleRoot $bundleRoot -ProvenanceManifest $provenance
        Assert-Result -Name "manifest written" -Condition (Test-Path -LiteralPath $path) -FailureMessage "manifest not written"

        $bytes = [System.IO.File]::ReadAllBytes($path)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Assert-Result -Name "no BOM" -Condition (-not $hasBom) -FailureMessage "manifest has a UTF-8 BOM"

        $roundTrip = Read-ProvenanceManifest -BundleRoot $bundleRoot
        Assert-Result -Name "source_commit round-trips" -Condition ($roundTrip.source_commit -eq $commit) -FailureMessage "source_commit lost on round-trip"
        Assert-Result -Name "hash round-trips" -Condition ($roundTrip.files."docs/guide.md".hash -eq $provenance.files."docs/guide.md".hash) -FailureMessage "hash lost on round-trip"
    }
    $results += Run-Test 'Provenance reads a bundle in one git object batch' {
        $framework = Join-Path $tempRoot 'batch-framework'
        $null = New-FrameworkFixture -Root $framework
        foreach ($i in 1..40) { Write-Utf8File (Join-Path $framework "docs/file $i.md") "file $i`n" }
        [IO.File]::WriteAllText((Join-Path $framework 'docs/empty.md'), '')
        Write-Utf8File (Join-Path $framework 'docs/large.md') (('payload ' * 20000) + "`n")
        $commit = Invoke-GitCommit -Repo $framework -Message 'batch paths'
        $trace = Join-Path $tempRoot 'provenance-trace.jsonl'
        $savedTrace = $env:GIT_TRACE2_EVENT
        try {
            $env:GIT_TRACE2_EVENT = $trace.Replace('\', '/')
            $provenance = New-ProvenanceManifest -FrameworkRoot $framework -Commit $commit
        } finally { $env:GIT_TRACE2_EVENT = $savedTrace }
        $commands = @(Get-Content -LiteralPath $trace | ForEach-Object { ConvertFrom-Json $_ } | Where-Object { $_.event -eq 'cmd_name' } | ForEach-Object { $_.name })
        Assert-Result 'provenance has no per-file git show processes' (@($commands | Where-Object { $_ -eq 'show' }).Count -eq 0) ($commands -join ',')
        Assert-Result 'provenance uses exactly one object reader' (@($commands | Where-Object { $_ -eq 'cat-file' }).Count -eq 1) ($commands -join ',')
        Assert-Result 'batch retains every file with spaces in its name' (@($provenance.files.PSObject.Properties.Name | Where-Object { $_ -like 'docs/file *' }).Count -eq 40) 'Batch dropped a path.'
        Assert-Result 'empty blob remains present' ($provenance.files.'docs/empty.md'.hash -eq (Get-NormalizedSha256 -Content '')) 'Empty blob was treated as absent.'
        Assert-Result 'large blob remains complete' ($provenance.files.'docs/large.md'.hash -eq (Get-NormalizedSha256 -Content (('payload ' * 20000) + "`n"))) 'Batch framing truncated a large blob.'
    }
    $results += Run-Test 'Batch decoding preserves normalized content and custom regions' {
        $framework = Join-Path $tempRoot 'batch-decoding'
        $null = New-FrameworkFixture -Root $framework
        Write-Utf8File (Join-Path $framework '.gitattributes') '* -text'
        $content = "first`r`n# >>> CRUCIBLE-CUSTOM`r`nlocal $([char]0x00e9)`r`n# <<< CRUCIBLE-CUSTOM`r`nlast`r`n`r`n"
        Write-Utf8File (Join-Path $framework 'docs/bom.md') ([string][char]0xfeff + $content)
        $commit = Invoke-GitCommit -Repo $framework -Message 'decode'
        $hashes = Get-GitFileNormalizedHashes -Repo $framework -Commit $commit -Paths @('docs/bom.md', 'absent', 'docs/guide.md')
        Assert-Result 'batch hash matches previous UTF8 and BOM decoding' ($hashes['docs/bom.md'].Hash -eq (Get-GitFileNormalizedHash -Repo $framework -Commit $commit -Path 'docs/bom.md')) 'Hash changed on batch decoding.'
        Assert-Result 'batch base hash removes custom region content' ($hashes['docs/bom.md'].BaseHash -eq (Get-NormalizedSha256 -Content (Get-ContentWithoutCustomRegions -Content $content))) 'Custom content entered the base hash.'
        Assert-Result 'missing object keeps null hashes and does not desynchronize next reply' ($null -eq $hashes['absent'].Hash -and $null -eq $hashes['absent'].BaseHash -and $hashes['docs/guide.md'].Hash -eq (Get-NormalizedSha256 -Content 'guide baseline')) 'Missing object changed the batch framing.'
        $empty = Get-GitFileContents -Repo $framework -Commit $commit -Paths @()
        Assert-Result 'empty batch remains empty' ($empty.Count -eq 0) 'Unexpected batch entries.'
    }
    $results += Run-Test 'Batch non-blobs remain absent without losing the next blob' {
        $framework = Join-Path $tempRoot 'batch-nonblobs'
        $commit = New-FrameworkFixture -Root $framework
        git -C $framework update-index --add --cacheinfo "160000,$commit,linked"
        $commit = Invoke-GitCommit -Repo $framework -Message 'gitlink'
        $contents = Get-GitFileContents -Repo $framework -Commit $commit -Paths @('docs', 'linked', 'docs/guide.md')
        Assert-Result 'trees and gitlinks have null contents' ($null -eq $contents['docs'] -and $null -eq $contents['linked']) 'Non-blob object became file content.'
        Assert-Result 'blob after non-blobs retains its framing' ($contents['docs/guide.md'].Trim() -ceq 'guide baseline') 'Reply framing lost after non-blob.'
    }
    $results += Run-Test 'Batch requests use LF independently of writer defaults' {
        $startDefinition = (Get-Command Start-GitFileContentProcess).ScriptBlock
        $writer = [IO.StringWriter]::new()
        $writer.NewLine = "`r`n"
        function Start-GitFileContentProcess {
            param($StartInfo)
            $bytes = [Text.Encoding]::UTF8.GetBytes("deadbeef blob 3`nabc`n")
            $fake = [pscustomobject]@{
                StandardInput = $writer
                StandardOutput = [pscustomobject]@{ BaseStream = [IO.MemoryStream]::new($bytes) }
                StandardError = [IO.StringReader]::new('')
                HasExited = $true
                ExitCode = 0
            }
            $fake | Add-Member ScriptMethod WaitForExit {}
            $fake | Add-Member ScriptMethod Dispose {}
            return $fake
        }
        try {
            $contents = Get-GitFileContents -Repo $tempRoot -Commit 'HEAD' -Paths @('file')
            Assert-Result 'batch request contains LF and no CR' ($writer.ToString() -ceq "HEAD:file`n") ([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($writer.ToString())))
            Assert-Result 'fake reply was read by the real batch owner' ($contents['file'] -ceq 'abc') 'Reply not consumed.'
        } finally { Set-Item Function:Start-GitFileContentProcess $startDefinition }
    }
    $results += Run-Test 'Batch pipe failures include git stderr' {
        $caught = ''
        try { $null = Get-GitFileContents -Repo (Join-Path $tempRoot 'no-such-repo') -Commit 'HEAD' -Paths @('file') }
        catch { $caught = $_.Exception.Message }
        Assert-Result 'failed git batch includes the native diagnostic' ($caught -match 'git cat-file batch failed:' -and $caught -match 'fatal:.*no-such-repo') $caught
    }
    $results += Run-Test 'Nonzero batch exits report git stderr once' {
        $startDefinition = (Get-Command Start-GitFileContentProcess).ScriptBlock
        function Start-GitFileContentProcess {
            param($StartInfo)
            $bytes = [Text.Encoding]::UTF8.GetBytes("deadbeef blob 3`nabc`n")
            $fake = [pscustomobject]@{
                StandardInput = [IO.StringWriter]::new()
                StandardOutput = [pscustomobject]@{ BaseStream = [IO.MemoryStream]::new($bytes) }
                StandardError = [IO.StringReader]::new('fatal: batch exit diagnostic')
                HasExited = $true
                ExitCode = 128
            }
            $fake | Add-Member ScriptMethod WaitForExit {}
            $fake | Add-Member ScriptMethod Dispose {}
            return $fake
        }
        try {
            $caught = ''
            try { $null = Get-GitFileContents -Repo $tempRoot -Commit 'HEAD' -Paths @('file') }
            catch { $caught = $_.Exception.Message }
            Assert-Result 'nonzero batch exit still refuses with one native diagnostic' ($caught -match 'git cat-file batch failed:' -and [regex]::Matches($caught, 'fatal: batch exit diagnostic').Count -eq 1) $caught
        } finally { Set-Item Function:Start-GitFileContentProcess $startDefinition }
    }
    $results += Run-Test 'Broken batch input pipes retain git stderr' {
        $startDefinition = (Get-Command Start-GitFileContentProcess).ScriptBlock
        function Start-GitFileContentProcess {
            param($StartInfo)
            $inputPipe = [pscustomobject]@{}
            $inputPipe | Add-Member ScriptMethod Write { throw [IO.IOException]::new('Broken pipe') }
            $fake = [pscustomobject]@{
                StandardInput = $inputPipe
                StandardOutput = [pscustomobject]@{ BaseStream = [IO.MemoryStream]::new() }
                StandardError = [IO.StringReader]::new('fatal: batch input diagnostic')
                HasExited = $true
                ExitCode = 128
            }
            $fake | Add-Member ScriptMethod WaitForExit {}
            $fake | Add-Member ScriptMethod Dispose {}
            return $fake
        }
        try {
            $caught = ''
            try { $null = Get-GitFileContents -Repo $tempRoot -Commit 'HEAD' -Paths @('file') }
            catch { $caught = $_.Exception.Message }
            Assert-Result 'broken pipe failure includes git stderr' ($caught -match 'Broken pipe' -and $caught -match 'fatal: batch input diagnostic') $caught
        } finally { Set-Item Function:Start-GitFileContentProcess $startDefinition }
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_ }).Count
if ($failed -gt 0) {
    Write-Host ("`n$failed provenance-manifest test(s) failed.") -ForegroundColor Red
    exit 1
}
Write-Host "`nAll provenance-manifest tests passed." -ForegroundColor Green
exit 0
