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
        $drive = @('D'..'Z' | Where-Object { -not [IO.Directory]::Exists($_ + ':\') } | Get-Random -Count 1)[0] + ':'
        & subst $drive $project
        Assert-Result 'subst succeeded' ($LASTEXITCODE -eq 0) 'could not create drive'
        try {
            $driveRoot = $drive + '\'
            if ($site -eq 'handoff') {
            $ctx = @{ RepoRoot = $driveRoot; TaskId = 'F-001'; BudgetCeilings = @{ low = 10 }; LatestHandoff = Get-Item ($driveRoot + 'h.json'); LogFile = $driveRoot + 'missing.jsonl' }
            Read-CrucibleHandoffContext -Context $ctx
            Assert-Result 'handoff at root' ($ctx.RelativeHandoffPath -ceq 'h.json') $ctx.RelativeHandoffPath
            } else {
            $report = Test-LineEndingConformance -ProjectRoot $driveRoot -BundleRoot ($driveRoot + '.crucible')
            Assert-Result 'eol status' ($report.Status -ceq 'ok') $report.Reason
            Assert-Result 'bundle CRLF excluded' ($report.Violations.Count -eq 0 -and $report.Checked -eq 2) ($report | Out-String)
            }
        } finally { & subst $drive /D }
    }
    }
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
Write-TestFileSummary -Results $results
