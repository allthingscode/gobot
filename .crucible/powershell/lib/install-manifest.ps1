. (Join-Path $PSScriptRoot "normalized-hash.ps1")
if (-not (Get-Command "Test-PathWithinDirectory" -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "config-helpers.ps1")
}

function Get-InstallManifest {
    param([string]$FrameworkRoot = "")

    if ([string]::IsNullOrWhiteSpace($FrameworkRoot)) {
        $FrameworkRoot = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "../..")))
    } elseif (Test-Path -LiteralPath $FrameworkRoot) {
        $FrameworkRoot = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $FrameworkRoot))
    }

    $manifestPath = Join-Path $FrameworkRoot "install-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Install manifest not found at $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($property in "scaffold_source", "root_files", "copied_dirs", "adopter_owned_excludes") {
        if (-not $manifest.PSObject.Properties[$property]) {
            throw "Install manifest missing required property: $property"
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.scaffold_source)) {
        throw "Install manifest scaffold_source must not be empty."
    }
    if (@($manifest.copied_dirs).Count -eq 0) {
        throw "Install manifest copied_dirs must not be empty."
    }
    foreach ($rootFile in @($manifest.root_files)) {
        if ([string]::IsNullOrWhiteSpace([string]$rootFile)) {
            throw "Install manifest root_files must not contain empty entries."
        }
    }
    return $manifest
}

function ConvertTo-ManifestRelativePath {
    param([Parameter(Mandatory=$true)][string]$Path)
    return $Path.Replace("\", "/").TrimStart("/")
}

# The framework's record of its own renames, as adopter-relative from -> to pairs.
#
# Optional, and absent means "no renames": a synthetic manifest in a test, or one read
# from a bundle installed before this key existed, must still load. An empty map only
# costs the old behaviour, which is a review-removal the adopter has to prune by hand.
function Get-SupersededRenameMap {
    param([Parameter(Mandatory=$true)]$Manifest)

    $map = @{}
    if (-not $Manifest.PSObject.Properties["renamed_paths"]) {
        return $map
    }
    foreach ($entry in @($Manifest.renamed_paths)) {
        if ($null -eq $entry) { continue }
        $from = ConvertTo-ManifestRelativePath -Path ([string]$entry.from)
        $to = ConvertTo-ManifestRelativePath -Path ([string]$entry.to)
        if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) {
            throw "Install manifest renamed_paths entries require a non-empty 'from' and 'to'."
        }
        if ($from -eq $to) {
            throw "Install manifest renamed_paths entry renames a path to itself: $from"
        }
        $map[$from] = $to
    }
    return $map
}

function Test-FrameworkDevOnlyFile {
    param([string]$Path)
    $normalized = $Path.Replace("\", "/").TrimStart("/")
    $devOnlyPaths = @(
        "powershell/sync-example-mirror.ps1",
        "powershell/lib/linux-leg-stamp.ps1",
        "powershell/gates/check-assertion-deletion.ps1",
        "powershell/gates/check-linux-leg.ps1",
        "powershell/gates/check-culture-sensitive-time.ps1",
        # Enforces Crucible's authoring convention - ASCII only - over Crucible's own
        # tracked files. That is a house style, not a property of correct source: an
        # adopter's code may need non-ASCII for reasons that are none of Crucible's
        # business, and a shipped copy would impose it on them. check-mojibake.ps1 does
        # ship, and should, because mis-decoded bytes are a defect in anybody's file.
        "powershell/gates/check-ascii.ps1",
        "powershell/tests/check-ascii.tests.ps1",
        # Drives the -Staged split of check-ascii.ps1 and check-culture-sensitive-time.ps1,
        # both dev-only, alongside check-mojibake.ps1. Item 151.
        "powershell/tests/staged-gate-scans.tests.ps1",
        # Check Crucible's own docs for deprecated shim invocations so self-generated
        # events cannot pollute the deletion criterion. Adopter references remain valid
        # usage signals and must not fail their commits. Item 94.
        "powershell/tests/deprecated-entrypoint-references.tests.ps1",
        # Reads the index of the repo it runs in against a prompts/ pathspec. An
        # adopter's prompts live under .crucible/prompts/, so shipping this would put a
        # gate in every bundle that matches nothing, invoked by nothing, and reports a
        # clean pass on a rule it never checked.
        "powershell/gates/check-prompt-version.ps1",
        # Checks Crucible's own docs against its constants; omit it from adopter bundles
        # where a self-comparison would not enforce the framework contract. Item 15.
        "powershell/gates/check-generated-docs.ps1",
        # Rates Crucible and routes its recommendations to Crucible's own Human, Groomer
        # and Architect; its last category is competitive research against six named
        # frameworks. An adopter running it produces a document only the maintainer can
        # act on. The adopter-facing version of this need already ships as
        # sops/system-analysis.md, which covers the adopter project and Crucible both.
        "sops/research-audit-framework.md",
        "powershell/tests/check-generated-docs.tests.ps1",
        # Asserts against the ignore rules of the Crucible repo itself. In an adopter
        # bundle $REPO_ROOT is the bundle root, whose .gitignore is the scaffold's and
        # deliberately carries none of those rules, so a shipped copy would fail for the
        # adopter. The adopter-facing half of item 84 is docs/git-policy.md, not a rule.
        "powershell/tests/framework-gitignore.tests.ps1",
        # Asserts against the worktree registrations of the Crucible repo itself, and its shared
        # fixture registers worktrees of it. In an adopter bundle $REPO_ROOT is the bundle root,
        # whose worktree list is not the framework's; both are dead weight there.
        "powershell/tests/framework-worktree-hygiene.tests.ps1",
        "powershell/tests/run-all-tests-worktree-cleanup.tests.ps1",
        "powershell/tests/_worktree-fixture.ps1",
        "powershell/tests/crucible-lint-authoring.tests.ps1",
        # Its owners table and allowances name the framework's own powershell/ paths and
        # line patterns. A bundle lays them out under .crucible/powershell/, so every owner
        # would report itself missing. Item 245.
        "powershell/tests/format-owners.tests.ps1",
        # These whole-class caller audits invoke framework-only ASCII and mirror-sync
        # tooling; an installed bundle deliberately omits those entrypoints.
        "powershell/tests/native-alias-sweep.tests.ps1",
        "powershell/tests/manifest-path-boundaries.tests.ps1",
        # Scans Crucible's runtime command call sites, not an adopter's source tree.
        "powershell/tests/printed-commands.tests.ps1",
        # Exercises the same framework-only detector and catalog. Item 257 review.
        "powershell/tests/format-owners-review.tests.ps1",
        # Scans this framework repo's runtime for I2 discard sites and stale allowances.
        "powershell/tests/git-discard-guard.tests.ps1",
        # Proves the two shipped test files that still name scripts/crucible_lint.go
        # do not invoke it from a bundle that has been through this list. Item 108.
        # The named files themselves ship; this wrapper does not, because it uses
        # the framework checkout as the install source.
        "powershell/tests/shipped-tests-crucible-lint.tests.ps1",
        # Compares shipping docs to the framework install set and dev-only files;
        # an adopter bundle omits the evidence this scan needs. Item 114.
        "powershell/tests/documented-paths-ship.tests.ps1",
        # Proves those four still exit 0 from a bundle, and that documented-paths-ship
        # is omitted. Item 114. Uses the framework checkout as the install source.
        "powershell/tests/shipped-tests-framework-layout.tests.ps1",
        "powershell/tests/examples-mirror-sync.tests.ps1",
        "powershell/tests/pre-push-hook.tests.ps1",
        "powershell/tests/check-assertion-deletion.tests.ps1",
        "powershell/tests/init-project-core.tests.ps1",
        "powershell/tests/init-project-instructions.tests.ps1",
        "powershell/tests/init-project-config-version.tests.ps1",
        "powershell/tests/update-bundle-core.tests.ps1",
        "powershell/tests/update-bundle-custom-regions.tests.ps1",
        "powershell/tests/update-bundle-rename-prune.tests.ps1",
        "powershell/tests/update-bundle-scope-snapshot.tests.ps1",
        "powershell/tests/watch-adopter-ci.tests.ps1",
        "powershell/tests/backlog-lock.tests.ps1",
        "powershell/tests/adopter-install-materialization.tests.ps1",
        "powershell/tests/adopter-update-materialization.tests.ps1",
        "powershell/tests/check-linux-leg.tests.ps1",
        "powershell/tests/check-culture-sensitive-time.tests.ps1",
        "powershell/tests/check-prompt-version.tests.ps1",
        # Pins Crucible's own prompt text. An adopter may customize a prompt, and a shipped
        # copy would fail their run over wording that is theirs to choose. Item 142.
        "powershell/tests/phase-prompt-handoff-example.tests.ps1",
        # Compares Crucible's Architect instructions with its gates and handoff API;
        # adopter-customized workflow prose is not this repo's contract. TODO item 193.
        "powershell/tests/implementation-instruction-contract.tests.ps1",
        # Pins Crucible's own Operator wording against the approval and publishing rules, for the
        # same reason. Item 232.
        "powershell/tests/deployment-approval-contract.tests.ps1",
        # Pins Crucible's own grooming SOP text, for the same reason. Item 143.
        "powershell/tests/grooming-stub-deviation.tests.ps1",
        # Pins Crucible's own grooming and verification SOP text, for the same reason. Item 145.
        "powershell/tests/changed-path-consumers.tests.ps1",
        # Pins Crucible's own verification SOP and prompt text, for the same reason. Item 146.
        "powershell/tests/review-criteria-evidence.tests.ps1",
        # Pins the deployment SOP and prompt wording against the gate-reason rule, for the
        # same reason. Item 144.
        "powershell/tests/gate-reason-rule.tests.ps1",
        # Its ledger names the Crucible repo's own test files, one per entry, and an entry nothing
        # reaches is a failure by design. An adopter bundle ships a subset of powershell/tests, so
        # every entry naming an excluded file would report itself stale and fail the adopter's run
        # for a rule that is about this repository's migration rather than about their tests.
        "powershell/tests/fixture-root-conformance.tests.ps1",
        # Exclude framework tooling per file; scripts/hooks/ must ship because
        # core.hooksPath uses all four hooks in adopter bundles. Item 83.
        #
        # Produces the framework's .private/linux-leg-stamp.json for the dev-only
        # check-linux-leg.ps1 gate, so adopters need neither producer nor consumer.
        "scripts/test-linux.ps1",
        # Windows process profiling is maintainer tooling, not adopter runtime. Item 201.
        "scripts/profile-tests.ps1",
        "powershell/tests/profile-tests.tests.ps1",
        # Provisions WSL tools for the dev-only Linux leg and Go linter.
        "scripts/wsl-bootstrap.sh",
        # Lints framework backlog, docs and schema. The hook invokes it only when
        # REPO_ROOT equals FRAMEWORK_ROOT, which adopter bundle layouts cannot satisfy.
        # Shipped tests skip the go-run when this file is absent. Item 108.
        "scripts/crucible_lint.go",
        "scripts/crucible_lint_test.go"
    )
    if ($devOnlyPaths -contains $normalized) {
        return $true
    }

    # Artifacts of building Crucible, not of using it. They name Crucible's own
    # internals and are meaningless inside an adopter project, so they neither
    # ship on install nor mirror into examples/gobot.
    $devOnlyPrefixes = @(
        "docs/investigations/",
        "docs/proposals/",
        # The framework audit's scorecard and the reports it produces. Both describe
        # Crucible, and both are read from this checkout rather than from a bundle -
        # self-hosting is not a supported mode, so there is no .crucible/ here to put
        # them in.
        "docs/audits/"
    )
    foreach ($prefix in $devOnlyPrefixes) {
        if ($normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

# Name all install source paths once so enumeration and the mirror sync's staged
# canonical check cover the same scaffold, copied directories and root files.
function Get-InstallSourceRoot {
    param([Parameter(Mandatory=$true)]$Manifest)

    $roots = @()
    $roots += ConvertTo-ManifestRelativePath -Path ([string]$Manifest.scaffold_source)
    $roots += @($Manifest.root_files | ForEach-Object { ConvertTo-ManifestRelativePath -Path ([string]$_) })
    $roots += @($Manifest.copied_dirs | ForEach-Object { (ConvertTo-ManifestRelativePath -Path ([string]$_)).TrimEnd("/") })
    return @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
}

function Get-FrameworkOwnedFiles {
    param(
        [string]$FrameworkRoot = "",
        [string]$AtCommit = ""
    )

    if ([string]::IsNullOrWhiteSpace($FrameworkRoot)) {
        $FrameworkRoot = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "../..")))
    } else {
        $FrameworkRoot = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $FrameworkRoot))
    }
    $manifest = Get-InstallManifest -FrameworkRoot $FrameworkRoot
    $roots = @(Get-InstallSourceRoot -Manifest $manifest)

    if (-not [string]::IsNullOrWhiteSpace($AtCommit)) {
        $files = @()
        foreach ($root in $roots) {
            $treeOutput = @(git -C (Resolve-FilesystemPath -Path $FrameworkRoot) ls-tree -r --name-only $AtCommit -- $root 2>$null)
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to enumerate install files at commit $AtCommit under $root"
            }
            $files += $treeOutput
        }
        return @($files | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ConvertTo-ManifestRelativePath -Path ([string]$_) } | Where-Object { -not (Test-FrameworkDevOnlyFile -Path $_) } | Sort-Object -Unique)
    }

    $files = @()
    foreach ($root in $roots) {
        $absoluteRoot = Join-Path $FrameworkRoot $root
        if (-not (Test-Path -LiteralPath $absoluteRoot)) {
            continue
        }
        if (Test-Path -LiteralPath $absoluteRoot -PathType Leaf) {
            $resolvedFile = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $absoluteRoot))
            $relative = $resolvedFile.Substring($FrameworkRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            $files += ConvertTo-ManifestRelativePath -Path $relative
            continue
        }
        $resolvedRoot = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $absoluteRoot))
        $files += Get-ChildItem -LiteralPath $resolvedRoot -Force -Recurse -File | Where-Object {
            $rel = $_.FullName.Substring($FrameworkRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            # Exclude gitignored runtime state that can accumulate under a
            # framework source dir's own nested .crucible/ (e.g. powershell/.crucible/).
            -not (Test-NestedCrucibleRuntimePath -RelativePath $rel -Manifest $manifest)
        } | ForEach-Object {
            $relative = $_.FullName.Substring($FrameworkRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            ConvertTo-ManifestRelativePath -Path $relative
        }
    }
    return @($files | Where-Object { -not (Test-FrameworkDevOnlyFile -Path $_) } | Sort-Object -Unique)
}

function Convert-FrameworkPathToAdopter {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)]$Manifest
    )

    $source = ConvertTo-ManifestRelativePath -Path $SourcePath
    $scaffold = (ConvertTo-ManifestRelativePath -Path ([string]$Manifest.scaffold_source)).TrimEnd("/")
    if ($source -eq $scaffold) {
        return ""
    }
    if ($source.StartsWith($scaffold + "/", [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $source.Substring($scaffold.Length + 1)
        if ($rel -eq "gitignore") {
            return ".gitignore"
        }
        return $rel
    }

    foreach ($rootFile in @($Manifest.root_files)) {
        $normalizedFile = ConvertTo-ManifestRelativePath -Path ([string]$rootFile)
        if ($source -eq $normalizedFile) {
            return $source
        }
    }

    foreach ($dir in @($Manifest.copied_dirs)) {
        $normalizedDir = (ConvertTo-ManifestRelativePath -Path ([string]$dir)).TrimEnd("/")
        if ($source -eq $normalizedDir -or $source.StartsWith($normalizedDir + "/", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $source
        }
    }

    throw "Path is not framework-owned according to install manifest: $SourcePath"
}

function Get-AdopterPathsForSource {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)]$Manifest
    )

    $paths = @()
    $adopterPath = Convert-FrameworkPathToAdopter -SourcePath $SourcePath -Manifest $Manifest
    if (-not [string]::IsNullOrWhiteSpace($adopterPath)) {
        $paths += $adopterPath
    }

    $source = ConvertTo-ManifestRelativePath -Path $SourcePath
    $scaffold = (ConvertTo-ManifestRelativePath -Path ([string]$Manifest.scaffold_source)).TrimEnd("/")
    if ($source.StartsWith($scaffold + "/", [System.StringComparison]::OrdinalIgnoreCase)) {
        $paths += $source
    }

    return @($paths | Sort-Object -Unique)
}

function Test-AdopterOwnedPath {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)]$Manifest
    )

    $path = ConvertTo-ManifestRelativePath -Path $RelativePath
    foreach ($exclude in @($Manifest.adopter_owned_excludes)) {
        $pattern = ConvertTo-ManifestRelativePath -Path ([string]$exclude)
        if ($pattern.EndsWith("/**")) {
            $prefix = $pattern.Substring(0, $pattern.Length - 3).TrimEnd("/")
            if ($path -eq $prefix -or $path.StartsWith($prefix + "/", [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
            continue
        }

        if ([System.Management.Automation.WildcardPattern]::Get($pattern, [System.Management.Automation.WildcardOptions]::IgnoreCase).IsMatch($path)) {
            return $true
        }
    }
    return $false
}

function Test-CrucibleGitIgnored {
    param(
        [Parameter(Mandatory=$true)][string]$BundleRoot,
        [Parameter(Mandatory=$true)][string]$RelativePath
    )
    $gitRoot = $null
    $dir = [System.IO.Path]::GetFullPath((Resolve-FilesystemPath -Path $BundleRoot))
    while ($null -ne $dir) {
        if (Test-Path -LiteralPath (Join-Path $dir ".git")) {
            $gitRoot = $dir
            break
        }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir -or [string]::IsNullOrEmpty($parent)) {
            break
        }
        $dir = $parent
    }
    if ($null -eq $gitRoot) {
        return $false
    }

    $absoluteFilePath = [System.IO.Path]::GetFullPath((Resolve-FilesystemPath -Path (Join-Path $BundleRoot $RelativePath)))

    if (Test-PathWithinDirectory -Path $absoluteFilePath -Directory $gitRoot) {
        $relativeToGit = Get-PathRelativeToDirectory -Path $absoluteFilePath -Directory $gitRoot
        $relativeToGit = $relativeToGit -replace '\\', '/'

        $null = git -C (Resolve-FilesystemPath -Path $gitRoot) check-ignore --quiet -- $relativeToGit 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}

function Test-ScaffoldSnapshotPath {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)]$Manifest
    )
    $path = ConvertTo-ManifestRelativePath -Path $RelativePath
    $scaffold = (ConvertTo-ManifestRelativePath -Path ([string]$Manifest.scaffold_source)).TrimEnd("/")
    return $path -eq $scaffold -or $path.StartsWith($scaffold + "/", [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-NestedCrucibleRuntimePath {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        $Manifest
    )
    $path = ConvertTo-ManifestRelativePath -Path $RelativePath
    $segments = $path -split '[\\/]'
    if (-not ($segments -contains ".crucible")) {
        return $false
    }
    if ($null -ne $Manifest -and (Test-ScaffoldSnapshotPath -RelativePath $path -Manifest $Manifest)) {
        return $false
    }
    return $true
}

$script:ProvenanceManifestVersion = 1

function Get-ProvenanceManifestPath {
    param([Parameter(Mandatory=$true)][string]$BundleRoot)
    return Join-Path $BundleRoot "install-provenance.json"
}

# Every path an install materializes into a bundle, as the adopter-relative path paired with
# the framework file it is copied from.
#
# Use the same install scope at a commit for provenance and in the working tree for
# examples/gobot. A separate subset can hide missing bundle files from parity checks. Item 80.
function Get-AdopterBundlePath {
    param(
        [Parameter(Mandatory=$true)][string]$FrameworkRoot,
        [Parameter(Mandatory=$true)]$Manifest,
        # Empty reads the working tree. Naming a commit reads that commit, which is what a
        # provenance manifest records.
        [string]$Commit = ""
    )

    $frameworkFiles = if ([string]::IsNullOrWhiteSpace($Commit)) {
        @(Get-FrameworkOwnedFiles -FrameworkRoot $FrameworkRoot)
    } else {
        @(Get-FrameworkOwnedFiles -FrameworkRoot $FrameworkRoot -AtCommit $Commit)
    }

    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $ordered = New-Object System.Collections.Generic.List[object]
    foreach ($source in $frameworkFiles) {
        foreach ($adopterPath in @(Get-AdopterPathsForSource -SourcePath $source -Manifest $Manifest)) {
            if ([string]::IsNullOrWhiteSpace($adopterPath)) { continue }
            $normalized = ConvertTo-ManifestRelativePath -Path $adopterPath
            if (Test-AdopterOwnedPath -RelativePath $normalized -Manifest $Manifest) { continue }
            if ($seen.Add($normalized)) {
                $ordered.Add([pscustomobject]@{ AdopterPath = $normalized; SourcePath = $source }) | Out-Null
            }
        }
    }
    return $ordered.ToArray()
}

function Get-ProvenanceBundlePaths {
    param(
        [Parameter(Mandatory=$true)][string]$FrameworkRoot,
        [Parameter(Mandatory=$true)]$Manifest,
        [Parameter(Mandatory=$true)][string]$Commit
    )

    return Get-AdopterBundlePath -FrameworkRoot $FrameworkRoot -Manifest $Manifest -Commit $Commit
}

function New-ProvenanceManifest {
    param(
        [Parameter(Mandatory=$true)][string]$FrameworkRoot,
        [Parameter(Mandatory=$true)][string]$Commit,
        [Parameter(Mandatory=$false)]$Manifest = $null
    )

    $FrameworkRoot = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $FrameworkRoot))
    if ($null -eq $Manifest) {
        $Manifest = Get-InstallManifest -FrameworkRoot $FrameworkRoot
    }

    # Cache optimization: git commit contents are immutable. We can cache the generated
    # manifest in the temp directory using a key derived from $FrameworkRoot and $Commit.
    $normRoot = $FrameworkRoot -replace '\\', '/'
    $cacheKey = Get-NormalizedSha256 -Content ($normRoot + "|" + $Commit)
    $cachePath = Join-Path ([System.IO.Path]::GetTempPath()) "crucible-prov-cache-$cacheKey.json"

    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        try {
            $cachedJson = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8
            $cachedManifest = $cachedJson | ConvertFrom-Json
            if ($null -ne $cachedManifest -and $cachedManifest.source_commit -eq $Commit) {
                return $cachedManifest
            }
        } catch {
            # Ignore cache read errors and regenerate
        }
    }

    $files = [ordered]@{}
    foreach ($entry in @(Get-ProvenanceBundlePaths -FrameworkRoot $FrameworkRoot -Manifest $Manifest -Commit $Commit)) {
        $content = Get-GitFileContent -Repo $FrameworkRoot -Commit $Commit -Path $entry.SourcePath
        if ($null -eq $content) { continue }
        $hash = Get-NormalizedSha256 -Content $content
        $baseContent = Get-ContentWithoutCustomRegions -Content $content
        $baseHash = Get-NormalizedSha256 -Content $baseContent
        $files[$entry.AdopterPath] = [pscustomobject]@{
            hash = $hash
            base_hash = $baseHash
        }
    }

    $prov = [pscustomobject]@{
        manifest_version = $script:ProvenanceManifestVersion
        source_commit = $Commit
        files = [pscustomobject]$files
    }

    try {
        $json = $prov | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText((Resolve-FilesystemPath -Path $cachePath), $json, [System.Text.UTF8Encoding]::new($false))
    } catch {
        # Ignore cache write errors
    }

    return $prov
}

function Write-ProvenanceManifest {
    param(
        [Parameter(Mandatory=$true)][string]$BundleRoot,
        [Parameter(Mandatory=$true)]$ProvenanceManifest
    )
    $path = Get-ProvenanceManifestPath -BundleRoot $BundleRoot
    # ConvertTo-Json on PS 5.1 emits CRLF; normalize to LF for git policy under .crucible/
    $json = ($ProvenanceManifest | ConvertTo-Json -Depth 10) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText((Resolve-FilesystemPath -Path $path), $json, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Read-ProvenanceManifest {
    param([Parameter(Mandatory=$true)][string]$BundleRoot)
    $path = Get-ProvenanceManifestPath -BundleRoot $BundleRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-ExpectedScaffoldFiles {
    [CmdletBinding()]
    param(
        [string]$FrameworkRoot = "",
        $Manifest = $null
    )

    if ([string]::IsNullOrWhiteSpace($FrameworkRoot)) {
        $FrameworkRoot = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "../..")))
    } else {
        $FrameworkRoot = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $FrameworkRoot))
    }

    if ($null -eq $Manifest) {
        $Manifest = Get-InstallManifest -FrameworkRoot $FrameworkRoot
    }

    $scaffoldPrefix = (ConvertTo-ManifestRelativePath -Path ([string]$Manifest.scaffold_source)).TrimEnd("/") + "/"
    $expectedScaffoldRelPaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $source = ""

    # 1. Check provenance manifest if present
    $prov = Read-ProvenanceManifest -BundleRoot $FrameworkRoot
    if ($null -ne $prov -and $null -ne $prov.files) {
        foreach ($prop in $prov.files.PSObject.Properties) {
            $path = ConvertTo-ManifestRelativePath -Path $prop.Name
            if ($path.StartsWith($scaffoldPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $relInScaffold = $path.Substring($scaffoldPrefix.Length)
                [void]$expectedScaffoldRelPaths.Add($relInScaffold)
            }
        }
    }
    if ($expectedScaffoldRelPaths.Count -gt 0) {
        $source = "provenance"
    } else {
        # 2. Check git ls-tree if in a git repo
        $gitRoot = $null
        $dir = [System.IO.Path]::GetFullPath($FrameworkRoot)
        while ($null -ne $dir) {
            if (Test-Path -LiteralPath (Join-Path $dir ".git")) {
                $gitRoot = $dir
                break
            }
            $parent = Split-Path -Parent $dir
            if ($parent -eq $dir -or [string]::IsNullOrEmpty($parent)) {
                break
            }
            $dir = $parent
        }

        if ($null -ne $gitRoot) {
            $treeOutput = @(git -C (Resolve-FilesystemPath -Path $FrameworkRoot) ls-files -- $scaffoldPrefix 2>$null)
            if ($LASTEXITCODE -eq 0 -and $treeOutput.Count -gt 0) {
                foreach ($line in $treeOutput) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    $path = ConvertTo-ManifestRelativePath -Path $line
                    if ($path.StartsWith($scaffoldPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $relInScaffold = $path.Substring($scaffoldPrefix.Length)
                        [void]$expectedScaffoldRelPaths.Add($relInScaffold)
                    }
                }
            }
        }
        if ($expectedScaffoldRelPaths.Count -gt 0) {
            $source = "git"
        }
    }

    # 3. Fallback to disk walk if neither provenance nor git gave expected files
    if ($expectedScaffoldRelPaths.Count -eq 0) {
        $source = "disk-walk"
        $scaffoldAbs = Join-Path $FrameworkRoot $scaffoldPrefix
        if (Test-Path -LiteralPath $scaffoldAbs) {
            $items = Get-ChildItem -LiteralPath $scaffoldAbs -Force -Recurse -File
            foreach ($item in $items) {
                $rel = $item.FullName.Substring($scaffoldAbs.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
                [void]$expectedScaffoldRelPaths.Add((ConvertTo-ManifestRelativePath -Path $rel))
            }
        }
    }

    return @{
        Files = @($expectedScaffoldRelPaths | Sort-Object -Unique)
        Source = $source
    }
}

function Test-ScaffoldTemplateComplete {
    [CmdletBinding()]
    param(
        [string]$FrameworkRoot = "",
        $Manifest = $null
    )

    if ([string]::IsNullOrWhiteSpace($FrameworkRoot)) {
        $FrameworkRoot = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "../..")))
    } else {
        $FrameworkRoot = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $FrameworkRoot))
    }

    if ($null -eq $Manifest) {
        $Manifest = Get-InstallManifest -FrameworkRoot $FrameworkRoot
    }

    $templateRoot = Join-Path $FrameworkRoot ([string]$Manifest.scaffold_source)
    if (-not (Test-Path -LiteralPath $templateRoot)) {
        return @{
            IsComplete = $false
            MissingFiles = @("Directory missing: $templateRoot")
            ExpectedCount = 0
            OnDiskCount = 0
            Source = "none"
            IsAuthoritative = $false
        }
    }

    $expectedResult = Get-ExpectedScaffoldFiles -FrameworkRoot $FrameworkRoot -Manifest $Manifest
    $expectedRelFiles = @($expectedResult.Files)
    $source = [string]$expectedResult.Source
    $isAuthoritative = ($source -ne "disk-walk")

    $missing = @()
    $missingFileCount = 0

    foreach ($relFile in $expectedRelFiles) {
        $fullPath = Join-Path $templateRoot $relFile
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            $missing += $relFile
            $missingFileCount++
        }
    }

    $backlogDir = Join-Path $templateRoot "backlog"
    if (-not (Test-Path -LiteralPath $backlogDir)) {
        if ($missing -notcontains "backlog/") {
            $missing += "backlog/"
        }
    }

    return @{
        IsComplete = ($missing.Count -eq 0)
        MissingFiles = $missing
        ExpectedCount = $expectedRelFiles.Count
        OnDiskCount = ($expectedRelFiles.Count - $missingFileCount)
        Source = $source
        IsAuthoritative = $isAuthoritative
    }
}

function Get-DriftClassification {
    param(
        [Parameter(Mandatory=$true)][string]$BundleRoot,
        [Parameter(Mandatory=$true)]$ProvenanceManifest,
        [Parameter(Mandatory=$true)]$Manifest
    )

    $BundleRoot = (Resolve-FilesystemPath -Path (Resolve-Path -LiteralPath $BundleRoot))
    $results = [ordered]@{
        pristine = New-Object System.Collections.Generic.List[string]
        customized = New-Object System.Collections.Generic.List[string]
        "adopter-added" = New-Object System.Collections.Generic.List[string]
        "framework-removed" = New-Object System.Collections.Generic.List[string]
    }

    $manifestPaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($property in $ProvenanceManifest.files.PSObject.Properties) {
        $relPath = ConvertTo-ManifestRelativePath -Path $property.Name
        [void]$manifestPaths.Add($relPath)
        $absolute = Join-Path $BundleRoot $relPath
        $workingHash = Get-FileNormalizedHash -Path $absolute
        if ($null -eq $workingHash) {
            $results["framework-removed"].Add($relPath) | Out-Null
            continue
        }
        
        $manifestHash = [string]$property.Value.hash
        $manifestBaseHash = if ($property.Value.base_hash) { [string]$property.Value.base_hash } else { $manifestHash }
        
        $workingHashBase = Get-FileNormalizedHash -Path $absolute -WithoutCustomRegions
        
        if ($workingHash -eq $manifestHash) {
            $results["pristine"].Add($relPath) | Out-Null
        } elseif ($workingHashBase -eq $manifestBaseHash) {
            $results["pristine"].Add($relPath) | Out-Null
        } else {
            $results["customized"].Add($relPath) | Out-Null
        }
    }

    $scanRoots = @($Manifest.copied_dirs | ForEach-Object { (ConvertTo-ManifestRelativePath -Path ([string]$_)).TrimEnd("/") })
    $scanRoots += @($Manifest.root_files | ForEach-Object { ConvertTo-ManifestRelativePath -Path ([string]$_) })
    foreach ($root in $scanRoots) {
        $absoluteRoot = Join-Path $BundleRoot $root
        if (-not (Test-Path -LiteralPath $absoluteRoot)) { continue }
        if (Test-Path -LiteralPath $absoluteRoot -PathType Leaf) {
            if ($root -eq "install-provenance.json") { continue }
            if (-not $manifestPaths.Contains($root)) {
                if (-not (Test-AdopterOwnedPath -RelativePath $root -Manifest $Manifest)) {
                    if (-not (Test-ScaffoldSnapshotPath -RelativePath $root -Manifest $Manifest)) {
                        if (Test-CrucibleGitIgnored -BundleRoot $BundleRoot -RelativePath $root) { continue }
                    }
                    $results["adopter-added"].Add($root) | Out-Null
                }
            }
            continue
        }
        foreach ($file in Get-ChildItem -LiteralPath $absoluteRoot -Recurse -File -Force) {
            $rel = ConvertTo-ManifestRelativePath -Path ($file.FullName.Substring($BundleRoot.Length))
            if ($rel -eq "install-provenance.json") { continue }
            if ($manifestPaths.Contains($rel)) { continue }
            if (Test-AdopterOwnedPath -RelativePath $rel -Manifest $Manifest) { continue }
            if (-not (Test-ScaffoldSnapshotPath -RelativePath $rel -Manifest $Manifest)) {
                if (Test-CrucibleGitIgnored -BundleRoot $BundleRoot -RelativePath $rel) { continue }
            }
            $results["adopter-added"].Add($rel) | Out-Null
        }
    }

    foreach ($key in @($results.Keys)) {
        $sorted = @($results[$key] | Sort-Object -Unique)
        $results[$key] = $sorted
    }
    return $results
}
