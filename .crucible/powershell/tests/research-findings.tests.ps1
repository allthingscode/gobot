# Item 257: every directory lookup uses the same exact-ID findings owner.
$ErrorActionPreference = 'Stop'
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT 'powershell/crucible-lib.ps1')
$results = @()
$root = New-TestFixtureRoot -NameHint 'research-findings'

function New-FindingsFixture {
    param([string]$Case)
    $dir = Join-Path $root $Case
    $research = Join-Path $dir '.crucible/research'
    $session = Join-Path $dir '.crucible/session'
    $specDir = Join-Path $dir '.crucible/backlog/features/active'
    New-Item -ItemType Directory -Path $specDir, (Join-Path $session 'R-1/research') -Force | Out-Null
    "paths:`n  backlog: .crucible/backlog`n  session: .crucible/session`n" |
        Set-Content -LiteralPath (Join-Path $dir '.crucible/config.yaml') -Encoding utf8NoBOM
    "---`nitem_id: R-1`ntype: Research`nstatus: Grooming`n---`n# Research" |
        Set-Content -LiteralPath (Join-Path $specDir 'R-1_research.md') -Encoding utf8NoBOM
    $expected = @()
    if ($Case -ne 'missing-directory') {
        New-Item -ItemType Directory -Path $research -Force | Out-Null
        $names = @('R-10_findings.md', 'R-1other.md')
        switch ($Case) {
            'plain' { $names += 'R-1.md'; $expected = @('R-1.md') }
            'suffixed' { $names += 'R-1_findings.md'; $expected = @('R-1_findings.md') }
            'multiple' { $names += @('R-1_a.md', 'R-1_z.md'); $expected = @('R-1_a.md', 'R-1_z.md') }
            'ordinal' { $names += @('R-1_a.md', 'R-1_B.md'); $expected = @('R-1_B.md', 'R-1_a.md') }
            'tie' { $names += @('R-1_a.md', 'R-1_z.md'); $expected = @('R-1_a.md', 'R-1_z.md') }
        }
        foreach ($name in $names) {
            $path = Join-Path $research $name
            '# findings' | Set-Content -LiteralPath $path -Encoding utf8NoBOM
            # The unrelated prefix files are newest. The exact-ID owner must exclude
            # them before sorting; file creation/enumeration order cannot choose a winner.
            $year = if ($name -in @('R-10_findings.md', 'R-1other.md')) { 2030 }
                elseif ($Case -eq 'multiple' -and $name -eq 'R-1_a.md') { 2020 }
                else { 2021 }
            [IO.File]::SetLastWriteTimeUtc($path, [datetime]::new($year, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
        }
    }
    return @{ Root = $dir; Research = $research; Session = $session; Expected = $expected }
}

try {
    foreach ($case in @('none', 'plain', 'suffixed', 'multiple', 'tie', 'ordinal', 'missing-directory')) {
        $fixture = New-FindingsFixture -Case $case
        $results += Run-Test -Name "Findings owner selects exact ID: $case" -Body {
            Assert-Result -Name 'findings owner exists' -Condition ($null -ne (Get-Command Get-ResearchFindingsArtifact -ErrorAction SilentlyContinue)) -FailureMessage 'the shared findings reader is missing'
            $files = @(Get-ResearchFindingsArtifact -TaskId R-1 -ResearchDirectory $fixture.Research)
            $expectedCount = @($fixture.Expected).Count
            Assert-Result -Name "$case owner cardinality" -Condition ($files.Count -eq $expectedCount) -FailureMessage "expected $expectedCount artifact(s), got $($files.Count)"
            if ($expectedCount) {
                Assert-Result -Name "$case owner chooses deterministic artifact" -Condition (($files.Name -join ',') -ceq ($fixture.Expected -join ',')) -FailureMessage ($files.Name -join ',')
            }
        }

        $results += Run-Test -Name "Research gate uses exact findings: $case" -Body {
            $script = Join-Path $REPO_ROOT 'powershell/record-research-gate.ps1'
            $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $script -TaskId R-1 -Reason approved -Approved C-350 -ProjectRoot $fixture.Root }
            if ($fixture.Expected.Count -gt 1) {
                Assert-Result -Name "$case ambiguous gate exits nonzero" -Condition ($run.ExitCode -ne 0) -FailureMessage $run.Output
                foreach ($name in $fixture.Expected) {
                    Assert-Result -Name "$case ambiguity lists $name" -Condition ($run.Output.Contains((Join-Path $fixture.Research $name))) -FailureMessage $run.Output
                }
                Assert-Result -Name "$case ambiguity names remedy" -Condition ($run.Output.Contains('Keep one exact findings file') -and $run.Output.Contains('then record the research gate again')) -FailureMessage $run.Output
                Assert-Result -Name "$case ambiguity records nothing" -Condition (-not (Test-Path (Join-Path $fixture.Session 'global/research_gate')) -and -not (Test-Path (Join-Path $fixture.Session 'R-1/research/gate-filing.md')) -and -not (Test-Path (Join-Path $fixture.Session 'R-1/research/gate-filing-pointer.md'))) -FailureMessage $run.Output
                return
            }
            Assert-Result -Name "$case research gate runs" -Condition ($run.ExitCode -eq 0) -FailureMessage $run.Output
            $body = [IO.File]::ReadAllText((Join-Path $fixture.Session 'R-1/research/gate-filing.md'))
            $pointer = if ($fixture.Expected.Count) { '.crucible/research/' + $fixture.Expected[0] } else { '.crucible/research/<findings artifact>' }
            Assert-Result -Name "$case research gate cites exact selection" -Condition ($body.Contains($pointer) -and -not $body.Contains('R-10_findings.md') -and -not $body.Contains('R-1other.md')) -FailureMessage $body
        }

        $results += Run-Test -Name "Research lineage uses exact findings: $case" -Body {
            $handoff = [pscustomobject]@{ task_id = 'R-1' }
            $context = @{ HandoffDir = ''; CrucibleRoot = '.crucible' }
            $advisory = Get-ResearchMisrouteAdvisory -Handoff $handoff -Context $context -ProjectRoot $fixture.Root
            $shouldWarn = ($fixture.Expected.Count -eq 0)
            Assert-Result -Name "$case lineage agrees with exact artifact presence" -Condition ((-not [string]::IsNullOrEmpty($advisory)) -eq $shouldWarn) -FailureMessage "expected warning=$shouldWarn; advisory=$advisory"
        }

        $results += Run-Test -Name "No-code review uses exact findings: $case" -Body {
            $runner = @'
param($Root, $Framework)
$ErrorActionPreference = 'Stop'
$Quiet = $true
. (Join-Path $Framework 'powershell/crucible-lib.ps1')
# No task branch or diff is involved in this fixture; exercise the real review surface.
function Get-GateReviewRange { @{ BaseSha = ''; BranchSha = '' } }
$session = Join-Path $Root '.crucible/session'
$ctx = @{
    RepoRoot = $Root; CrucibleRoot = '.crucible'; IsBootstrap = $false; Quiet = $true
    SessionDir = $session; LogFile = (Join-Path $session 'gate/pipeline.log.jsonl')
    CircuitBreakerHistoryFile = (Join-Path $session 'global/circuit_breakers.jsonl')
    GateOutcome = $null; GateReason = $null; GateRedirectTarget = $null
    Handoff = [pscustomobject]@{
        task_id = 'R-1'; source_phase = 'deployment'; target_phase = 'done'
        cumulative_handoff_count = 1; commit_hash = ''
    }
}
Push-Location $Root
try { Invoke-HumanGate -Context $ctx } finally { Pop-Location }
'@
            $path = Join-Path $fixture.Root 'review.ps1'
            Set-Content -LiteralPath $path -Value $runner -Encoding utf8NoBOM
            $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $path $fixture.Root $REPO_ROOT }
            Assert-Result -Name "$case no-code review runs" -Condition ($run.ExitCode -eq 0) -FailureMessage $run.Output
            $pointer = if ($fixture.Expected.Count) { (@($fixture.Expected | ForEach-Object { '.crucible/research/' + $_ }) -join ', ') } else { 'the archived spec' }
            Assert-Result -Name "$case no-code review cites exact selection" -Condition ($run.Output.Contains('review ' + $pointer + ' + filed stubs') -and -not $run.Output.Contains('R-10_findings.md') -and -not $run.Output.Contains('R-1other.md')) -FailureMessage $run.Output
        }
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
if (@($results | Where-Object { -not $_ }).Count -gt 0) { exit 1 }
Write-Host "ALL TESTS PASSED ($($results.Count) tests)"
