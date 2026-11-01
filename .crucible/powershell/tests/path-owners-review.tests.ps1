# Cross-review regressions for items 304 and 305. No agent runtime is invoked.
$ErrorActionPreference = 'Stop'
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT 'powershell/crucible-lib.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/crucible-gates.ps1')
. (Join-Path $REPO_ROOT 'powershell/lib/line-ending-conformance.ps1')
$results = @()
$root = New-TestFixtureRoot -NameHint 'path-owners-review'
$utf8 = [Text.UTF8Encoding]::new($false)
try {
    $results += Run-Test 'Bare drive roots normalize in the containment helper' {
        if (-not (Test-PlatformIsWindows)) { Skip-Test 'Bare drive roots are Windows paths.' }
        Assert-Result 'drive child is contained' (Test-PathWithinDirectory -Directory 'C:' -Path 'C:\a\b.md') 'trimmed drive root refused'
        Assert-Result 'bare drive equals full root' (Test-PathWithinDirectory -Directory 'C:\' -Path 'C:') 'bare Path refused'
    }
    $results += Run-Test 'Bare drive roots normalize in the relativization helper' {
        if (-not (Test-PlatformIsWindows)) { Skip-Test 'Bare drive roots are Windows paths.' }
        Assert-Result 'drive suffix' ((Get-PathRelativeToDirectory -Directory 'C:' -Path 'C:\a\b.md' -Separator '/') -ceq 'a/b.md') 'wrong drive suffix'
        Assert-Result 'bare path equals directory' ((Get-PathRelativeToDirectory -Directory 'C:\' -Path 'C:' -Separator '/') -ceq '') 'wrong root suffix'
    }
    $results += Run-Test 'Drive-root display adapter accepts the trimmed root' {
        if (-not (Test-PlatformIsWindows)) { Skip-Test 'Bare drive roots are Windows paths.' }
        Assert-Result 'display suffix' ((Get-RootRelativePath -Root 'C:' -Path 'C:\a\b.md') -ceq 'a/b.md') 'wrong display suffix'
    }
    $results += Run-Test 'Root-relative configured backlog keeps its historical filing prefix' {
        if (-not (Test-PlatformIsWindows)) { Skip-Test 'Root-relative Windows paths have a different POSIX meaning.' }
        $project = Join-Path $root 'filing'
        $records = Join-Path $project '.crucible/session/global/research_gate'
        New-Item -ItemType Directory -Path $records -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $project '.crucible/config.yaml'), "paths:`n  backlog: '\shared\backlog'`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $records 'F-001-20261023.json'), '{"approved":["F-002"]}', $utf8)
        $scope = Get-ResearchGateFilingScope -TaskId 'F-001' -RepoRoot $project
        Assert-Result 'historical slash prefix' ($scope.BacklogPrefix -ceq '/shared/backlog/') $scope.BacklogPrefix
        Assert-Result 'approved IDs retained' ($scope.Ids -contains 'F-002') 'gate record was not read'
    }
    $results += Run-Test 'Nonexistent absolute bundle escaping through dot-dot gets item 303 refusal' {
        $project = Join-Path $root 'launcher'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $escape = Join-Path $project 'missing/../../evil'
        Assert-Result 'escape does not exist' (-not (Test-Path -LiteralPath $escape)) 'fixture exists'
        $output = Invoke-ExternalCommand -AsLines { & (Get-PwshCommand) -NoProfile -File (Join-Path $REPO_ROOT 'powershell/launch-codex-specialist.ps1') -ProjectRoot $project -CrucibleRoot $escape -Model unused -TaskId F-001 -Phase verification -PromptText REVIEW 2>&1 } | Out-String
        Assert-Result 'refusal exit 2' ($LASTEXITCODE -eq 2) $output
        Assert-Result 'item 303 diagnostic' ($output -match '-CrucibleRoot must be relative to the repo root') $output
        Assert-Result 'no empty-root exception' ($output -notmatch 'crucible_root value is empty') $output
        Assert-Result 'refusal wrote no session' (-not (Test-Path (Join-Path $project '.crucible'))) 'refusal created runtime files'
    }
    $results += Run-Test 'Rooted but non-qualified Windows bundle keeps item 303 refusal' {
        if (-not (Test-PlatformIsWindows)) { Skip-Test 'Root-relative Windows paths require Windows.' }
        $output = Invoke-ExternalCommand -AsLines { & (Get-PwshCommand) -NoProfile -File (Join-Path $REPO_ROOT 'powershell/launch-codex-specialist.ps1') -ProjectRoot $root -CrucibleRoot '\missing-bundle' -Model unused 2>&1 } | Out-String
        Assert-Result 'refusal exit 2' ($LASTEXITCODE -eq 2) $output
        Assert-Result 'item 303 diagnostic' ($output -match '-CrucibleRoot must be relative to the repo root') $output
    }
    foreach ($site in @('handoff', 'line-ending')) {
    $results += Run-Test ($site + ' works at a subst drive root') {
        if (-not (Test-PlatformIsWindows)) { Skip-Test 'subst drive roots require Windows.' }
        $project = Join-Path $root 'drive'
        $bundle = Join-Path $project '.crucible'
        New-Item -ItemType Directory -Path $bundle -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $bundle 'inside.txt'), "inside`r`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $project 'outside.txt'), "outside`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $project 'h.json'), '{"task_id":"F-001","budget_tier":"low"}', $utf8)
        $null = Invoke-Git @('init', '--quiet', $project)
        $null = Invoke-Git @('config', 'core.autocrlf', 'false') -Directory $project
        $null = Invoke-Git @('add', '-A') -Directory $project
        Use-TestSubstDrive -Path $project -Body {
            param($driveRoot)
            if ($site -eq 'handoff') {
            $ctx = @{ RepoRoot = $driveRoot; TaskId = 'F-001'; BudgetCeilings = @{ low = 10 }; LatestHandoff = Get-Item ($driveRoot + 'h.json'); LogFile = $driveRoot + 'missing.jsonl' }
            Read-CrucibleHandoffContext -Context $ctx
            Assert-Result 'handoff at root' ($ctx.RelativeHandoffPath -ceq 'h.json') $ctx.RelativeHandoffPath
            } else {
            $report = Test-LineEndingConformance -ProjectRoot $driveRoot -BundleRoot ($driveRoot + '.crucible')
            Assert-Result 'eol status' ($report.Status -ceq 'ok') $report.Reason
            Assert-Result 'bundle CRLF excluded' ($report.Violations.Count -eq 0 -and $report.Checked -eq 2) ($report | Out-String)
            }
        }
    }
    }
    # Item 353: a simulated drive table and subst. No real drive is created, so
    # these run on every platform and cannot collide with parallel tests.
    function Invoke-WithSubstStub {
        param([hashtable]$Stub, [scriptblock]$Body)
        $script:substStub = @{ Defined = [Collections.Generic.HashSet[string]]::new(); Competitor = [Collections.Generic.HashSet[string]]::new(); Mapped = [Collections.Generic.HashSet[string]]::new(); Calls = [Collections.Generic.List[string]]::new(); NativeFailure = ''; RemoveFails = $false }
        foreach ($key in @('Defined', 'Competitor')) { foreach ($letter in @($Stub[$key])) { if ($letter) { [void]$script:substStub[$key].Add($letter) } } }
        foreach ($key in @('NativeFailure', 'RemoveFails')) { if ($Stub.ContainsKey($key)) { $script:substStub[$key] = $Stub[$key] } }
        function Test-TestDriveLetterDefined { param([string]$Letter) $script:substStub.Defined.Contains($Letter) }
        function subst {
            $s = $script:substStub
            $s.Calls.Add(($args -join ' '))
            $letter = ([string]$args[0]) -replace ':$', ''
            $global:LASTEXITCODE = 1
            if ($args[1] -eq '/D') {
                if ($s.RemoveFails -or -not $s.Mapped.Remove($letter)) { return ('Invalid parameter - ' + $args[0]) }
                [void]$s.Defined.Remove($letter)
            } elseif ($letter -notmatch '^[D-Z]$') {
                return ('Invalid parameter - ' + $args[0])
            } elseif ($s.NativeFailure) {
                return $s.NativeFailure
            } else {
                # The competitor maps this letter after the owner's check, before its claim.
                if ($s.Competitor.Contains($letter)) { [void]$s.Defined.Add($letter) }
                if ($s.Defined.Contains($letter)) { return 'Drive already SUBSTed' }
                [void]$s.Defined.Add($letter)
                [void]$s.Mapped.Add($letter)
            }
            $global:LASTEXITCODE = 0
        }
        & $Body
    }
    $results += Run-Test 'Subst owner moves past a letter taken after its availability check' {
        Invoke-WithSubstStub @{ Competitor = 'D' } {
            $drive = New-TestSubstDrive -Path $root
            Assert-Result 'next letter claimed' ($drive -ceq 'E:') "got '$drive'"
            Assert-Result 'competitor keeps its letter' ($script:substStub.Defined.Contains('D') -and -not $script:substStub.Mapped.Contains('D')) ($script:substStub.Calls -join ', ')
            Remove-TestSubstDrive -Drive $drive
            Assert-Result 'claimed mapping removed' ($script:substStub.Mapped.Count -eq 0) ($script:substStub.Calls -join ', ')
        }
    }
    $results += Run-Test 'Subst owner reports exhaustion as an I12 skip' {
        Invoke-WithSubstStub @{ Defined = @('D'..'Z') } {
            $drive = New-TestSubstDrive -Path $root
            Assert-Result 'checked exhaustion returns null without a claim' ($null -eq $drive -and $script:substStub.Calls.Count -eq 0) ("got '$drive'; " + ($script:substStub.Calls -join ', '))
        }
        Invoke-WithSubstStub @{ Competitor = @('D'..'Z') } {
            $drive = New-TestSubstDrive -Path $root
            Assert-Result 'collision exhaustion is bounded and returns null' ($null -eq $drive -and $script:substStub.Calls.Count -eq 23 -and $script:substStub.Mapped.Count -eq 0) ("got '$drive'; " + ($script:substStub.Calls -join ', '))
            $reason = ''
            $probe = @{ Ran = $false }
            try { Use-TestSubstDrive -Path $root -Body { $probe.Ran = $true } } catch { $reason = $_.Exception.Message }
            Assert-Result 'site skips with a reason' ($reason -ceq ($CRUCIBLE_SKIP_SENTINEL + 'No free D..Z drive letter is available for subst.') -and -not $probe.Ran) $reason
        }
    }
    $results += Run-Test 'Subst owner propagates a failure other than a collision' {
        Invoke-WithSubstStub @{ NativeFailure = 'Path not found - X' } {
            $diagnostic = ''
            try { New-TestSubstDrive -Path $root | Out-Null } catch { $diagnostic = $_.Exception.Message }
            Assert-Result 'failure is not a skip or a retry' ($diagnostic -match 'Path not found - X' -and $diagnostic -notmatch [regex]::Escape($CRUCIBLE_SKIP_SENTINEL) -and $script:substStub.Calls.Count -eq 1) ("$diagnostic; " + ($script:substStub.Calls -join ', '))
        }
    }
    $results += Run-Test 'Subst site removes its mapping when the body fails and reports a failed removal' {
        Invoke-WithSubstStub @{} {
            $diagnostic = ''
            try { Use-TestSubstDrive -Path $root -Body { param($driveRoot) throw ('body failed at ' + $driveRoot) } } catch { $diagnostic = $_.Exception.Message }
            Assert-Result 'body failure propagates' ($diagnostic -ceq 'body failed at D:\') $diagnostic
            Assert-Result 'mapping removed after failure' ($script:substStub.Mapped.Count -eq 0 -and $script:substStub.Calls -contains 'D: /D') ($script:substStub.Calls -join ', ')
        }
        Invoke-WithSubstStub @{ RemoveFails = $true } {
            $diagnostic = ''
            try { Use-TestSubstDrive -Path $root -Body { param($driveRoot) } } catch { $diagnostic = $_.Exception.Message }
            Assert-Result 'failed removal is reported' ($diagnostic -match 'subst D: /D failed') $diagnostic
        }
    }
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
Write-TestFileSummary -Results $results
