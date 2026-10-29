# Match generated prompt rules without freezing their wording. TODO item 194.
# Unit tests for record-research-gate.ps1: the post-Research-Gate continuation helper that
# records a human gate decision and generates a self-contained gate-filing.md so a
# re-dispatched Researcher files the approved stubs instead of re-presenting the gate.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$SCRIPT = Join-Path $REPO_ROOT "powershell/record-research-gate.ps1"

$results = @()

function New-GateProject {
    param([Parameter(Mandatory=$true)][string]$Root, [string]$TaskId = "R-021")
    $crucible = Join-Path $Root ".crucible"
    $researchSession = Join-Path $crucible "session/$TaskId/research"
    $researchDir = Join-Path $crucible "research"
    New-Item -ItemType Directory -Path $researchSession, $researchDir, (Join-Path $crucible "backlog") -Force | Out-Null
    "paths:`n  backlog: `".crucible/backlog`"`n  session: `".crucible/session`"" | Set-Content -LiteralPath (Join-Path $crucible "config.yaml") -Encoding UTF8
    "# findings" | Set-Content -LiteralPath (Join-Path $researchDir "$TaskId`_Quality_Audit_20260715.md") -Encoding UTF8
    return @{ Root = $Root; TaskId = $TaskId; GateFiling = (Join-Path $researchSession "gate-filing.md") }
}

$tempRoot = New-TestFixtureRoot -NameHint "research-gate-test"

try {
    $results += Run-Test -Name "records approval and generates a gate-filing prompt listing approved items" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "approve")
        & $SCRIPT -TaskId $p.TaskId -Reason "Gate approved" -Approved "C-350","C-351" -ProjectRoot $p.Root | Out-Null
        Assert-Result "gate-filing written" (Test-Path -LiteralPath $p.GateFiling) "gate-filing.md was not generated"
        $body = Get-Content -LiteralPath $p.GateFiling -Raw
        Assert-Result "names approved C-350" ($body -match "C-350") "approved item C-350 not listed"
        Assert-Result "names approved C-351" ($body -match "C-351") "approved item C-351 not listed"
        Assert-Result "forbids re-audit" ($body -match '(?im)^(?=[^\r\n]*(?:do not|must not|never))(?=[^\r\n]*(?:re-run|repeat))(?=[^\r\n]*audit)[^\r\n]+\r?$') "missing the do-not-re-audit directive"
        Assert-Result "instructs handoff" ($body -match "new-handoff\.ps1") "missing the handoff instruction"
        Assert-Result "passes HumanApproved" ($body -match "-HumanApproved") "handoff command should record HumanApproved"
    }

    # Item 235: an approved upstream referral has no backlog ID; it is recorded, never filed.
    $results += Run-Test -Name "records an approved upstream referral without asking to file it" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "upstream")
        $ref = "U-044-01: preserve the first session-state write"
        & $SCRIPT -TaskId $p.TaskId -Reason "I approve both" -Approved "B-043" -ApprovedUpstream $ref -ProjectRoot $p.Root | Out-Null
        $record = Get-ChildItem -LiteralPath (Join-Path $p.Root ".crucible/session/global/research_gate") -Filter "$($p.TaskId)-*.json" | Select-Object -First 1
        $decision = Get-Content -LiteralPath $record.FullName -Raw | ConvertFrom-Json
        Assert-Result "referral recorded" (@($decision.approved_upstream) -contains $ref) (Get-Content -LiteralPath $record.FullName -Raw)
        Assert-Result "referral is not a filing ID" (-not (@($decision.approved) -contains $ref) -and (@($decision.approved) -contains "B-043")) (Get-Content -LiteralPath $record.FullName -Raw)
        $body = Get-Content -LiteralPath $p.GateFiling -Raw
        Assert-Result "referral listed as not filed" ($body -match '(?s)UPSTREAM REFERRALS \(do NOT file[^\n]*\n  - U-044-01') "the continuation must list the referral under a do-not-file heading"
        Assert-Result "referral not in handoff IDs" (-not ($body -match '-HumanApproved[^\n]*U-044-01')) "the referral must not be passed as a backlog ID"

        $p2 = New-GateProject -Root (Join-Path $tempRoot "upstream-only")
        & $SCRIPT -TaskId $p2.TaskId -Reason "route upstream" -ApprovedUpstream $ref -ProjectRoot $p2.Root | Out-Null
        $body2 = Get-Content -LiteralPath $p2.GateFiling -Raw
        Assert-Result "upstream-only decision files no stubs" ($body2 -match 'No stubs to file') "an upstream-only decision must not ask for stubs"
    }

    $results += Run-Test -Name "a non-ID in -Approved is still refused" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "non-id")
        $refused = $false
        try { & $SCRIPT -TaskId $p.TaskId -Reason "x" -Approved "U-044-01" -ProjectRoot $p.Root | Out-Null } catch { $refused = $_.Exception.Message -match 'is not a backlog item ID' }
        Assert-Result "non-ID refused" $refused "U-044-01 must not be accepted as a backlog ID"
    }

    # Item 229: filing instructions must follow the adopter's backlog path.
    $results += Run-Test -Name "approved stub instructions use the configured backlog directory" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "custom-backlog")
        "paths:`n  backlog: tickets`n  session: .crucible/session`n" | Set-Content -LiteralPath (Join-Path $p.Root ".crucible/config.yaml") -Encoding UTF8
        & $SCRIPT -TaskId $p.TaskId -Reason "ok" -Approved "C-350" -ProjectRoot $p.Root | Out-Null
        $body = Get-Content -LiteralPath $p.GateFiling -Raw
        $backlog = Join-Path $p.Root "tickets"
        Assert-Result "configured stub directory" ($body.Contains($backlog + '/{bugs,chores,features}/active/')) "filing instructions must name the resolved tickets directory"
        Assert-Result "no hard-coded backlog directory" (-not $body.Contains('.crucible/backlog/')) "filing instructions must not send stubs to the default backlog"
        Assert-Result "approved stub listed" ($body.Contains('  - C-350')) "expected the single approved stub"
    }
    # TODO item 208: background pwsh launches re-split multi-word -PromptText values.
    $results += Run-Test -Name "printed Codex dispatch uses a file-sourced one-line pointer" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "dispatch with spaces")
        $output = (Invoke-ExternalCommand -AsLines { & $SCRIPT -TaskId $p.TaskId -Reason "ok" -Approved "C-350" -ProjectRoot $p.Root 6>&1 } | Out-String)
        $codex = @($output -split "`r?`n" | Where-Object { $_ -match '^    Codex:' })
        Assert-Result "one Codex command" ($codex.Count -eq 1) "expected one printed Codex command"
        Assert-Result "no PromptText" ($codex[0] -notmatch '-PromptText') "printed Codex command must not use -PromptText"
        $pointerPath = Join-Path (Split-Path $p.GateFiling) "gate-filing-pointer.md"
        Assert-Result "quoted PromptFile path" ($codex[0].Contains("-PromptFile '" + $pointerPath + "'")) "expected quoted pointer file path"
        # Item 219: a Codex level includes both model and effort.
        Assert-Result "model and effort in dispatch" ($codex[0] -match '-Model <model> -Effort <effort>') "expected both halves of the Codex level"
        Assert-Result "task-scoped dispatch" ($codex[0] -match "-TaskId 'R-021' -Phase 'research'") "expected TaskId and Phase"
        Assert-Result "pointer written" (Test-Path -LiteralPath $pointerPath) "missing pointer file"
        $pointer = [IO.File]::ReadAllText($pointerPath)
        $expected = "Researcher: $($p.TaskId) - read and follow all instructions in $($p.GateFiling)"
        Assert-Result "one-line pointer content" ($pointer.TrimEnd("`r", "`n") -eq $expected) "pointer must direct the Researcher to gate-filing.md"
        $bytes = [IO.File]::ReadAllBytes($pointerPath)
        Assert-Result "pointer ASCII without BOM" (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) "pointer must be ASCII and BOM-free"
        Assert-Result "Claude pointer unchanged" ($output.Contains('Claude: Agent tool, prompt = "' + $expected + '"')) "expected Claude inline pointer"
    }

    $results += Run-Test -Name "writes a structural decision record with the approved list" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "record")
        & $SCRIPT -TaskId $p.TaskId -Reason "ok" -Approved "C-350" -Deferred "C-352" -Rejected "C-999" -ProjectRoot $p.Root | Out-Null
        $gateDir = Join-Path $p.Root ".crucible/session/global/research_gate"
        $rec = @(Get-ChildItem -LiteralPath $gateDir -Filter "$($p.TaskId)-*.json")
        Assert-Result "one decision record" ($rec.Count -eq 1) "expected exactly one decision record"
        $obj = Get-Content -LiteralPath $rec[0].FullName -Raw | ConvertFrom-Json
        Assert-Result "outcome approved" ($obj.outcome -eq "approved") "outcome should be approved when items approved"
        Assert-Result "approved recorded" ($obj.approved -contains "C-350") "approved list missing C-350"
        Assert-Result "deferred recorded" ($obj.deferred -contains "C-352") "deferred list missing C-352"
        Assert-Result "rejected recorded" ($obj.rejected -contains "C-999") "rejected list missing C-999"
    }

    # Review of 5d1b869 (item 247): the printed commands were built first and refused a reason
    # they could not double-quote, so an ordinary human reason was never recorded.
    $results += Run-Test -Name "a reason with a dollar sign and quotes is recorded and printed as a literal" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "dollar-reason")
        $reason = 'Approve C-350; costs $5 and it''s "cheap"'
        $output = (Invoke-ExternalCommand -AsLines { & $SCRIPT -TaskId $p.TaskId -Reason $reason -Approved "C-350" -ProjectRoot $p.Root 6>&1 } | Out-String)
        $gateDir = Join-Path $p.Root ".crucible/session/global/research_gate"
        $rec = @(Get-ChildItem -LiteralPath $gateDir -Filter "$($p.TaskId)-*.json" -ErrorAction SilentlyContinue)
        Assert-Result "decision recorded" ($rec.Count -eq 1) $output
        $obj = if ($rec.Count -eq 1) { Get-Content -LiteralPath $rec[0].FullName -Raw | ConvertFrom-Json } else { $null }
        Assert-Result "reason recorded verbatim" ($null -ne $obj -and $obj.reason -ceq $reason) $output
        $body = if (Test-Path -LiteralPath $p.GateFiling) { Get-Content -LiteralPath $p.GateFiling -Raw } else { "" }
        Assert-Result "handoff command carries the reason as a literal" ($body.Contains("-Reason 'Approve C-350; costs `$5 and it''s `"cheap`"'")) $body
    }

    $results += Run-Test -Name "all-deferred decision files no stubs but still records and hands off" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "defer")
        & $SCRIPT -TaskId $p.TaskId -Reason "not now" -Deferred "C-350","C-351" -ProjectRoot $p.Root | Out-Null
        $body = Get-Content -LiteralPath $p.GateFiling -Raw
        Assert-Result "no-stub path" ($body -match "No stubs to file") "should take the no-stubs branch"
        Assert-Result "still hands off" ($body -match "new-handoff\.ps1") "should still write a handoff"
        $gateDir = Join-Path $p.Root ".crucible/session/global/research_gate"
        $obj = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $gateDir -Filter "$($p.TaskId)-*.json")[0].FullName -Raw | ConvertFrom-Json
        Assert-Result "outcome closed" ($obj.outcome -eq "closed") "outcome should be closed when nothing approved"
    }

    $results += Run-Test -Name "gate-filing never tells the Researcher to set a status the deployment gate refuses" -Body {
        # R-031's Researcher followed "set R-031's own status to Production", and the Operator
        # had to revert it: the deployment gate's premature-status guard (F12) refuses a
        # terminal status before a human accepts. Read the terminal set from that guard so a
        # status added there is checked here too.
        $gatesText = Get-Content -LiteralPath (Join-Path $REPO_ROOT "powershell/lib/crucible-gates.ps1") -Raw
        $terminal = @()
        if ($gatesText -match "(?s)Premature Production/Resolved status guard.*?\\b\(\?:([A-Za-z|]+)\)\\b") {
            $terminal = @($Matches[1] -split '\|')
        }
        Assert-Result "terminal set read from the F12 guard" ($terminal.Count -ge 2) "could not read the terminal statuses from the F12 guard in crucible-gates.ps1"
        foreach ($case in @(@{ Name = "approved"; Args = @{ Approved = @("C-350") } }, @{ Name = "deferred"; Args = @{ Deferred = @("C-350") } })) {
            $p = New-GateProject -Root (Join-Path $tempRoot ("status-" + $case.Name))
            $gateArgs = $case.Args
            & $SCRIPT -TaskId $p.TaskId -Reason "ok" -ProjectRoot $p.Root @gateArgs | Out-Null
            $body = Get-Content -LiteralPath $p.GateFiling -Raw
            $sentences = @(($body -replace "\s+", " ") -split "(?<=[.:;])\s+")
            foreach ($status in $terminal) {
                $offending = @($sentences | Where-Object { $_ -match "\b$status\b" -and $_ -notmatch '(?i)\b(?:do not|must not|never)\b' })
                Assert-Result "$($case.Name): no instruction to set $status" ($offending.Count -eq 0) ("gate-filing tells the Researcher to set " + $status + ": " + ($offending -join " | "))
            }
            Assert-Result "$($case.Name): says to leave the parent status" ($body -match ('(?im)^(?=[^\r\n]*' + [regex]::Escape($p.TaskId) + ')(?=[^\r\n]*status)(?=[^\r\n]*(?:leave|keep))(?=[^\r\n]*(?:as it is|unchanged|alone))[^\r\n]+\r?$')) "gate-filing should tell the Researcher to leave the parent status alone"
        }
    }

    $results += Run-Test -Name "generated gate-filing.md is ASCII and BOM-free" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "encoding")
        & $SCRIPT -TaskId $p.TaskId -Reason "clean" -Approved "C-350" -ProjectRoot $p.Root | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($p.GateFiling)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Assert-Result "no BOM" (-not $hasBom) "gate-filing.md must be BOM-free"
        $nonAscii = @($bytes | Where-Object { $_ -gt 0x7F })
        Assert-Result "ascii only" ($nonAscii.Count -eq 0) "gate-filing.md must be ASCII-only"
    }

    $results += Run-Test -Name "a gate recorded through pwsh -File stores bare IDs and a prompt with real paths (item 174)" -Body {
        # gobot R-040: the quotes reached the script, and the prompt named `$findingsRel and
        # `$CrucibleRoot literally because a Markdown backtick escaped the dollar sign.
        $p = New-GateProject -Root (Join-Path $tempRoot "pwsh-file")
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $SCRIPT -TaskId $p.TaskId -Reason "ok" -Approved '"C-350","C-351"' -ProjectRoot $p.Root }
        Assert-Result "exit 0" ($run.ExitCode -eq 0) ("record-research-gate failed: " + $run.Output)
        $gateDir = Join-Path $p.Root ".crucible/session/global/research_gate"
        $obj = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $gateDir -Filter "$($p.TaskId)-*.json")[0].FullName -Raw | ConvertFrom-Json
        Assert-Result "bare IDs recorded" ((@($obj.approved) -join ",") -eq "C-350,C-351") ("approved recorded as: " + (@($obj.approved) -join ","))
        $body = Get-Content -LiteralPath $p.GateFiling -Raw
        Assert-Result "no dollar sign" ($body -notmatch '\$') ("gate-filing.md holds an unexpanded variable: " + $body)
        Assert-Result "names the findings artifact" ($body -match '`\.crucible/research/R-021_Quality_Audit_20260715\.md`') "gate-filing.md should name the findings artifact in backticks"
        Assert-Result "names the backlog path" ($body.Contains('`' + (Join-Path $p.Root '.crucible/backlog') + '/{bugs,chores,features}/active/`')) "gate-filing.md should name the backlog directory in backticks"
        Assert-Result "handoff IDs singly quoted" ($body -match "-HumanApproved 'C-350','C-351'") "handoff command should quote each ID once"
        Assert-Result "no suspicious-content sentinel" ($body -notmatch 'SuspiciousContent') "the handoff command must not pass -SuspiciousContent"
        Assert-Result "stubs filed as Stub" ($body -match 'status: "Stub"' -and $body -notmatch 'status: "Ready"') "stubs must be filed with status Stub for the Stub-Only Close-Out"
    }

    $launcherCases = @{ WindowsPowerShell = 0 }
    $stepLineCount = 3
    $legacy = if (Test-PlatformIsWindows) { Get-Command powershell.exe -ErrorAction SilentlyContinue } else { $null }
    # Item 291: Steps 3 and 4 are run by the Researcher in whichever shell it has; Codex's is
    # often Bash, where the direct & '<script>' form is a syntax error. Inert copies of the
    # real param blocks write what they bound, so no handoff, backlog or agent CLI runs.
    $results += Run-Test -Name "gate-filing Steps 3 and 4 run unchanged under Bash, pwsh and a Windows PowerShell launcher" -Body {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $p = New-GateProject -Root (Join-Path $tempRoot "gate O'Brien `$HOME")
        $bundle = Join-Path $p.Root ".crucible/powershell"
        $null = New-Item -ItemType Directory -Path $bundle -Force
        $capture = @'

$captured = @(foreach ($name in @($PSBoundParameters.Keys | Sort-Object)) {
    $value = $PSBoundParameters[$name]
    if ($value -is [array]) { $name + "=[" + (@($value) -join "|") + "]#" + @($value).Count } else { $name + "=" + $value }
})
$captured += ("host7plus=" + ($PSVersionTable.PSVersion.Major -ge 7))
[IO.File]::WriteAllText((Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) ("capture-" + (Split-Path -Leaf $PSCommandPath) + ".txt")), ($captured -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
'@
        foreach ($name in @("new-handoff.ps1", "validate-backlog.ps1", "crucible.ps1")) {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $REPO_ROOT ("powershell/" + $name)), [ref]$tokens, [ref]$errors)
            [IO.File]::WriteAllText((Join-Path $bundle $name), ($ast.ParamBlock.Extent.Text + $capture), $utf8)
        }
        $reason = 'Approve C-350; costs $5 and it''s "cheap" `tick \\share' + [char]0x2019 + 's'
        & $SCRIPT -TaskId $p.TaskId -Reason $reason -Approved "C-350","C-351" -Deferred "C-352,C-353" -Rejected "C-999" -ProjectRoot $p.Root | Out-Null
        $body = [IO.File]::ReadAllText($p.GateFiling)
        $steps = $body.Substring($body.IndexOf("## Step 3"))
        $lines = @($steps -split "`n" | Where-Object { $_ -match '^    \S' -and $_ -notmatch '^    #' } | ForEach-Object { $_.Substring(4) })
        Assert-Result "$stepLineCount executable lines in Steps 3 and 4" ($lines.Count -eq $stepLineCount) ($lines -join "`n")

        $expected = @(
            ("capture-new-handoff.ps1.txt", (@("HumanApproved=[C-350|C-351]#2", "HumanDeferred=[C-352|C-353]#2", "HumanRejected=[C-999]#1", ("Reason=" + $reason), "Source=research", "StubSpecsCreated=[C-350|C-351]#2", "Target=grooming", ("TaskId=" + $p.TaskId), "host7plus=True") -join "`n")),
            ("capture-validate-backlog.ps1.txt", (@(("ProjectRoot=" + $p.Root), "host7plus=True") -join "`n")),
            ("capture-crucible.ps1.txt", (@("Init=True", ("ProjectRoot=" + $p.Root), "Quiet=True", ("TaskId=" + $p.TaskId), "host7plus=True") -join "`n"))
        )
        $bash = Get-TestBash
        $cdBash = "cd -- '" + $p.Root.Replace("'", "'\''") + "' || exit 9"
        $cdPs = "Set-Location -LiteralPath '" + $p.Root.Replace("'", "''") + "'"
        for ($i = 0; $i -lt $stepLineCount; $i++) {
            $shells = @(
                @{ Name = "Bash"; Ext = "sh"; Text = ($cdBash + "`n" + $lines[$i] + "`n"); Bom = $false },
                @{ Name = "pwsh"; Ext = "ps1"; Text = ($cdPs + "`n" + $lines[$i] + "`n"); Bom = $false }
            )
            if ($null -ne $legacy) { $shells += @{ Name = "Windows PowerShell"; Ext = "ps1"; Text = ($cdPs + "`n" + $lines[$i] + "`n"); Bom = $true } }
            foreach ($shell in $shells) {
                $capturePath = Join-Path $p.Root $expected[$i][0]
                if (Test-Path -LiteralPath $capturePath) { Remove-Item -LiteralPath $capturePath -Force }
                $driver = Join-Path $tempRoot ("step-line-" + $i + "." + $shell.Ext)
                [IO.File]::WriteAllText($driver, $shell.Text, (New-Object System.Text.UTF8Encoding($shell.Bom)))
                $run = switch ($shell.Name) {
                    "Bash" { Invoke-ExternalCommand { & $bash $driver } }
                    "pwsh" { Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $driver } }
                    default { Invoke-ExternalCommand { & $legacy.Source -NoProfile -ExecutionPolicy Bypass -File $driver } }
                }
                $actual = if (Test-Path -LiteralPath $capturePath) { [IO.File]::ReadAllText($capturePath) } else { "(nothing captured)" }
                $want = $utf8.GetBytes($expected[$i][1])
                Assert-Result ($shell.Name + " runs line " + ($i + 1) + " and delivers every value byte for byte") ($run.ExitCode -eq 0 -and (Test-Path -LiteralPath $capturePath) -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($capturePath)) -ceq [Convert]::ToBase64String($want)) ($lines[$i] + "`n=> exit " + $run.ExitCode + ": " + $run.Output + "`ncaptured: " + $actual)
                if ($shell.Name -eq "Windows PowerShell") { $launcherCases.WindowsPowerShell++ }
            }
        }

        foreach ($line in $lines) {
            Assert-Result "each line starts pwsh rather than the agent shell's own host" ($line.StartsWith("pwsh -NoProfile -ExecutionPolicy Bypass -File ")) $line
        }
        $runnerPath = Join-Path (Split-Path -Parent $p.GateFiling) "gate-handoff.ps1"
        $runner = @([IO.File]::ReadAllText($runnerPath) -split "`n")
        Assert-Result "the reading copy is the command the runner holds" ($steps.Contains("    # " + $runner[1] + "`n")) ($runner -join "`n")

        # A refused handoff stops the Researcher before Step 4.
        [IO.File]::WriteAllText((Join-Path $bundle "new-handoff.ps1"), ((Get-Content -LiteralPath (Join-Path $bundle "new-handoff.ps1") -Raw) + "`nexit 2`n"), $utf8)
        $driver = Join-Path $tempRoot "step-refused.sh"
        [IO.File]::WriteAllText($driver, ($cdBash + "`n" + $lines[0] + "`n"), $utf8)
        $run = Invoke-ExternalCommand { & $bash $driver }
        Assert-Result "the runner exits with new-handoff's refusal code" ($run.ExitCode -eq 2) ("exit " + $run.ExitCode + ": " + $run.Output)
    }

    $results += Run-Test -Name 'Windows PowerShell launcher coverage matches the platform' -Body {
        $expectedCases = if (Test-PlatformIsWindows) { $stepLineCount } else { 0 }
        $probeResult = if ($null -eq $legacy) { 'not found ($null)' } else { $legacy.Source }
        Assert-Result 'every Windows launcher case executes on Windows only' ($launcherCases.WindowsPowerShell -eq $expectedCases) ("Expected $expectedCases Windows PowerShell launcher cases, executed $($launcherCases.WindowsPowerShell); powershell.exe probe: $probeResult")
        if (-not (Test-PlatformIsWindows)) {
            Skip-Test -Reason 'Windows PowerShell launcher checks require Windows; the powershell.exe probe is disabled on this platform.'
        }
    }

    $results += Run-Test -Name "a handoff command the builder cannot write leaves a runner that exits nonzero" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "unavailable-handoff")
        & $SCRIPT -TaskId $p.TaskId -Reason "line one`nline two" -Approved "C-350" -ProjectRoot $p.Root | Out-Null
        $runnerPath = Join-Path (Split-Path -Parent $p.GateFiling) "gate-handoff.ps1"
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $runnerPath }
        Assert-Result "unavailable handoff runner exits 2 and says why" ($run.ExitCode -eq 2 -and $run.Output -match 'command unavailable' -and $run.Output -match 'newline') ("exit " + $run.ExitCode + ": " + $run.Output)
    }

    $results += Run-Test -Name "a value that is not a backlog ID is refused (item 174)" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "bad-id")
        $threw = $false
        try { & $SCRIPT -TaskId $p.TaskId -Reason "x" -Approved "C-350","B034" -ProjectRoot $p.Root 2>$null } catch { $threw = ($_.Exception.Message -match "'B034' is not a backlog item ID") }
        Assert-Result "refuses B034" $threw "expected a refusal naming B034"
        Assert-Result "writes no gate-filing" (-not (Test-Path -LiteralPath $p.GateFiling)) "a refused gate must not write gate-filing.md"
    }

    $results += Run-Test -Name "empty decision is refused" -Body {
        $p = New-GateProject -Root (Join-Path $tempRoot "empty")
        $threw = $false
        try { & $SCRIPT -TaskId $p.TaskId -Reason "x" -ProjectRoot $p.Root 2>$null } catch { $threw = $true }
        Assert-Result "throws on empty decision" $threw "expected an error when no items are approved/deferred/rejected"
    }

    $results += Run-Test -Name "missing research session directory is refused" -Body {
        $root = Join-Path $tempRoot "nosession"
        $crucible = Join-Path $root ".crucible"
        New-Item -ItemType Directory -Path (Join-Path $crucible "backlog") -Force | Out-Null
        "paths:`n  backlog: `".crucible/backlog`"`n  session: `".crucible/session`"" | Set-Content -LiteralPath (Join-Path $crucible "config.yaml") -Encoding UTF8
        $threw = $false
        try { & $SCRIPT -TaskId "R-099" -Reason "x" -Approved "C-1" -ProjectRoot $root 2>$null } catch { $threw = $true }
        Assert-Result "throws without research session" $threw "expected an error when the research session dir is absent"
    }

} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-TestFileSummary -Results $results
