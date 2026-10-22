# I7: exercise authorization at dispatch, including actions that never return.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_harness.ps1')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'powershell/lib/platform.ps1')
$pwsh = Get-PwshCommand
$lib = (Join-Path $repoRoot 'powershell/crucible-lib.ps1').Replace("'", "''")
$root = New-TestFixtureRoot -NameHint 'gate-decision'
$results = @()

function New-DecisionFixture {
    param([string]$Name, [string]$InputPath, [string]$Outcome = 'accepted')
    $project = Join-Path $root $Name
    $session = Join-Path $project '.crucible/session'
    $gate = Join-Path $session 'global/gate_decisions'
    $active = Join-Path $project '.crucible/backlog/features/active'
    New-Item -ItemType Directory -Path $gate, $active -Force | Out-Null
    @'
project:
  default_branch: main
review:
  auto_push: true
  require_green_ci: false
'@ | Set-Content -LiteralPath (Join-Path $project '.crucible/config.yaml') -Encoding utf8
    @'
---
item_id: "F-242"
type: "feature"
status: "Ready for Deploy"
priority: "P2"
---
# Decision test
'@ | Set-Content -LiteralPath (Join-Path $active 'F-242_Decision.md') -Encoding utf8
    @'
# Backlog
## Active Items
| ID | Status | Title | Target |
|---|---|---|---|
| [F-242](features/active/F-242_Decision.md) | Ready for Deploy | Decision | Operator |
'@ | Set-Content -LiteralPath (Join-Path $project '.crucible/backlog/BACKLOG.md') -Encoding utf8
    'base' | Set-Content -LiteralPath (Join-Path $project 'README.md') -Encoding utf8
    $null = Invoke-ExternalCommand { git -C $project init --initial-branch=main }
    foreach ($setting in @(@('user.name', 'Test'), @('user.email', 'test@example.com'), @('commit.gpgSign', 'false'), @('core.hooksPath', '.no-hooks'))) {
        $null = Invoke-ExternalCommand { git -C $project config $setting[0] $setting[1] }
    }
    $null = Invoke-ExternalCommand { git -C $project add . }
    $null = Invoke-ExternalCommand { git -C $project commit -m base }
    $null = Invoke-ExternalCommand { git -C $project checkout -b task/F-242 }
    'task' | Set-Content -LiteralPath (Join-Path $project 'feature.md') -Encoding utf8
    $null = Invoke-ExternalCommand { git -C $project add feature.md }
    $null = Invoke-ExternalCommand { git -C $project commit -m task }
    $null = Invoke-ExternalCommand { git -C $project checkout main }
    # A local missing remote fails deterministically without network or credentials.
    $null = Invoke-ExternalCommand { git -C $project remote add origin (Join-Path $project 'missing.git') }
    $ctx = @{
        RepoRoot = $project; SessionDir = $session; CrucibleRoot = '.crucible'
        LogFile = Join-Path $session 'F-242/pipeline.log.jsonl'
        CircuitBreakerHistoryFile = Join-Path $session 'global/circuit_breakers.jsonl'
        GateOutcome = if ($InputPath -eq 'CLI') { $Outcome } else { $null }
        GateReason = 'Reviewed every acceptance criterion'; GateRedirectTarget = 'F-243'
        IsBootstrap = $false; Quiet = $true
        Handoff = [pscustomobject]@{
            task_id = 'F-242'; source_phase = 'deployment'; target_phase = 'done'
            session_cycle_id = 'cycle-242'; cumulative_handoff_count = 1
        }
    }
    if ($InputPath -eq 'pending') {
        ('{"outcome":"' + $Outcome + '","reason":"Reviewed every acceptance criterion","redirect_target":"F-243"}') |
            Set-Content -LiteralPath (Join-Path $gate 'gate_decision_F-242_pending.json') -Encoding utf8
    }
    return $ctx
}

function Invoke-DecisionFixture {
    param([hashtable]$Context, [string]$Setup = '')
    $ctxPath = Join-Path $Context.RepoRoot 'context.xml'
    $Context | Export-Clixml -LiteralPath $ctxPath
    $scriptPath = Join-Path $Context.RepoRoot 'run.ps1'
    @"
`$ErrorActionPreference = 'Stop'
`$Quiet = `$true
. '$lib'
`$ctx = Import-Clixml -LiteralPath '$($ctxPath.Replace("'", "''"))'
Set-Location -LiteralPath `$ctx.RepoRoot
$Setup
Invoke-HumanGate -Context `$ctx
Write-Host 'GATE_RETURNED'
"@ | Set-Content -LiteralPath $scriptPath -Encoding utf8
    return Invoke-ExternalCommand { & $pwsh -NoProfile -File $scriptPath }
}

try {
    $results += Run-Test -Name 'Accept then push failure preserves authorization and same-cycle re-run on both inputs (I7)' -Body {
        foreach ($inputPath in @('CLI', 'pending')) {
            $ctx = New-DecisionFixture -Name "push-$inputPath" -InputPath $inputPath
            $run = Invoke-DecisionFixture -Context $ctx
            $output = $run.Output -join "`n"
            Assert-Result "$inputPath push refuses" ($run.ExitCode -eq 1 -and $output -match 'git push failed') $output
            $merged = Invoke-ExternalCommand { git -C $ctx.RepoRoot merge-base --is-ancestor task/F-242 main }
            Assert-Result "$inputPath task merged before push failure" ($merged.ExitCode -eq 0) $output
            Assert-Result "$inputPath spec finalized before push failure" (Test-Path -LiteralPath (Join-Path $ctx.RepoRoot '.crucible/backlog/features/archived/F-242_Decision.md')) $output
            $records = @(Get-ChildItem -LiteralPath (Join-Path $ctx.SessionDir 'global/gate_decisions') -Filter 'F-242-*.json')
            Assert-Result "$inputPath authorization survives push failure" ($records.Count -eq 1) $output
            $decision = Get-Content -LiteralPath $records[0].FullName -Raw | ConvertFrom-Json
            Assert-Result "$inputPath recorded authorization is bound to task and cycle" ($decision.task_id -eq 'F-242' -and $decision.session_cycle_id -eq 'cycle-242' -and $decision.outcome -eq 'accepted') 'wrong authorization'
            $template = Join-Path $ctx.SessionDir 'global/gate_decisions/gate_decision_F-242_pending.json'
            Assert-Result "$inputPath pending template is consumed once the decision is recorded" (-not (Test-Path -LiteralPath $template)) $output
            $before = [IO.File]::ReadAllBytes($records[0].FullName)
            $ctx.GateOutcome = $null
            $again = Invoke-DecisionFixture -Context $ctx
            $text = $again.Output -join "`n"
            Assert-Result "$inputPath same-cycle re-run does not repeat the action" ($again.ExitCode -eq 0 -and $text -match 'GATE_RETURNED' -and $text -notmatch 'git push failed|Pushing merged') $text
            Assert-Result "$inputPath re-run retains decision bytes" ([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($records[0].FullName))) 're-run rewrote decision'
        }
    }

    $results += Run-Test -Name 'An accept whose push failed is not replayed without a human in a new cycle on both inputs (I7)' -Body {
        foreach ($inputPath in @('CLI', 'pending')) {
            $ctx = New-DecisionFixture -Name "cycle-$inputPath" -InputPath $inputPath
            $run = Invoke-DecisionFixture -Context $ctx
            $output = $run.Output -join "`n"
            Assert-Result "$inputPath first accept stops at the push" ($run.ExitCode -eq 1 -and $output -match 'git push failed') $output
            $ctx.GateOutcome = $null
            $ctx.Handoff.session_cycle_id = 'cycle-243'
            $again = Invoke-DecisionFixture -Context $ctx
            $text = $again.Output -join "`n"
            Assert-Result "$inputPath new-cycle gate asks the human instead of replaying the accept" ($again.ExitCode -eq 0 -and $text -match 'Present this menu to the human' -and $text -notmatch 'git push failed|Pushing merged|GATE_RETURNED') $text
        }
    }

    $results += Run-Test -Name 'Every outcome is recorded before a nonreturning action on both inputs (I7)' -Body {
        foreach ($inputPath in @('CLI', 'pending')) {
            foreach ($outcome in @('accepted', 'redirected', 'rejected', 'abandoned')) {
                $ctx = New-DecisionFixture -Name "dispatch-$inputPath-$outcome" -InputPath $inputPath -Outcome $outcome
                $run = Invoke-DecisionFixture -Context $ctx -Setup @'
function Invoke-HumanGateAction {
    param($TaskId, $Outcome, $ProjectRoot, $SourcePhase, $GateReason, $Handoff, $LogFile, $CircuitBreakerHistoryFile)
    $files = @(Get-ChildItem -LiteralPath (Join-Path $ctx.SessionDir 'global/gate_decisions') -Filter 'F-242-*.json')
    if ($files.Count -eq 1) {
        $saved = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
        if ($saved.outcome -eq $Outcome -and $saved.task_id -eq $TaskId -and $saved.session_cycle_id -eq 'cycle-242' -and
            $saved.reason -eq $GateReason -and $saved.rework_requested -eq ($Outcome -eq 'rejected')) { Write-Host 'AUTHORIZED_ACTION' }
    }
    exit 7
}
'@
                $text = $run.Output -join "`n"
                Assert-Result "$inputPath $outcome authorization exists at dispatch" ($run.ExitCode -eq 7 -and $text -match 'AUTHORIZED_ACTION') $text
            }
        }
    }

    $results += Run-Test -Name 'A conflicting redirect undoes authorization and requires a fresh gate on both inputs (I3, I7)' -Body {
        foreach ($inputPath in @('CLI', 'pending')) {
            $ctx = New-DecisionFixture -Name "conflict-$inputPath" -InputPath $inputPath -Outcome redirected
            'primary' | Set-Content -LiteralPath (Join-Path $ctx.RepoRoot 'feature.md') -Encoding utf8
            $null = Invoke-ExternalCommand { git -C $ctx.RepoRoot add feature.md }
            $null = Invoke-ExternalCommand { git -C $ctx.RepoRoot commit -m conflict }
            $run = Invoke-DecisionFixture -Context $ctx
            $text = $run.Output -join "`n"
            Assert-Result "$inputPath conflicting redirect routes to rework" ($run.ExitCode -eq 3) $text
            Assert-Result "$inputPath conflicting redirect leaves spec active" (Test-Path -LiteralPath (Join-Path $ctx.RepoRoot '.crucible/backlog/features/active/F-242_Decision.md')) $text
            $records = @(Get-ChildItem -LiteralPath (Join-Path $ctx.SessionDir 'global/gate_decisions') -Filter 'F-242-*.json')
            Assert-Result "$inputPath conflicting redirect removes advancing authorization" ($records.Count -eq 0) $text
            $template = Join-Path $ctx.SessionDir 'global/gate_decisions/gate_decision_F-242_pending.json'
            Assert-Result "$inputPath conflicting redirect leaves no filled template to replay" (-not (Test-Path -LiteralPath $template)) $text
            $ctx.GateOutcome = $null
            $again = Invoke-DecisionFixture -Context $ctx
            $output = $again.Output -join "`n"
            Assert-Result "$inputPath conflicting redirect asks for a fresh decision" ($again.ExitCode -eq 0 -and $output -match 'Present this menu to the human' -and $output -notmatch 'GATE_RETURNED') $output
        }
    }

    # The CLI input never reads the template; gate-reason-rule.tests.ps1 pins that it
    # leaves an unfilled one untouched through dispatch.
    $results += Run-Test -Name 'A pending template that cannot be consumed refuses before dispatch (I7, I11)' -Body {
        foreach ($inputPath in @('pending')) {
            $ctx = New-DecisionFixture -Name "consume-$inputPath" -InputPath $inputPath
            $template = Join-Path $ctx.SessionDir 'global/gate_decisions/gate_decision_F-242_pending.json'
            $run = Invoke-DecisionFixture -Context $ctx -Setup @'
function Remove-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [string]$Path, [switch]$Force, [switch]$Recurse)
    $target = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($target -like '*_pending.json') { throw 'template removal denied' }
    Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}
function Invoke-HumanGateAction { Write-Host 'UNAUTHORIZED_ACTION' }
'@
            $text = $run.Output -join "`n"
            Assert-Result "$inputPath unconsumed template refuses without dispatch" ($run.ExitCode -ne 0 -and $text -match 'template removal denied' -and $text -notmatch 'UNAUTHORIZED_ACTION|GATE_RETURNED') $text
            $records = @(Get-ChildItem -LiteralPath (Join-Path $ctx.SessionDir 'global/gate_decisions') -Filter 'F-242-*.json')
            Assert-Result "$inputPath unconsumed template withdraws the recorded decision" ($records.Count -eq 0 -and (Test-Path -LiteralPath $template)) $text
        }
    }

    $results += Run-Test -Name 'A decision storage failure refuses an embedding caller before dispatch (I7, I11)' -Body {
        foreach ($inputPath in @('CLI', 'pending')) {
            foreach ($preference in @('Stop', 'Continue')) {
                $ctx = New-DecisionFixture -Name "write-$inputPath-$preference" -InputPath $inputPath
                $run = Invoke-DecisionFixture -Context $ctx -Setup @"
function Set-Content { throw 'decision storage unavailable' }
function Invoke-HumanGateAction { Write-Host 'UNAUTHORIZED_ACTION' }
`$ErrorActionPreference = '$preference'
try { Invoke-HumanGate -Context `$ctx } catch { Write-Host 'CALLER_CAUGHT_REFUSAL' }
Write-Host 'CALLER_CONTINUED'
exit 0
"@
                $text = $run.Output -join "`n"
                Assert-Result "$inputPath $preference storage refusal cannot be swallowed" ($run.ExitCode -ne 0 -and $text -match 'decision storage unavailable' -and $text -notmatch 'UNAUTHORIZED_ACTION|CALLER_CONTINUED|CALLER_CAUGHT_REFUSAL') $text
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-TestFileSummary -Results $results
