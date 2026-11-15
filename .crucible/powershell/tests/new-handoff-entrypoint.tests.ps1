# new-handoff.ps1 binds its parameters inside a protected call, so a binding failure is an
# exit an in-process caller cannot catch (I11, item 375). Each case runs a real in-process
# caller under Stop and StrictMode with an outer try/catch, in its own pwsh process.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_harness.ps1')
$source = Split-Path $PSScriptRoot
$pwshCmd = (Get-Process -Id $PID).Path
$fixture = New-TestFixtureRoot -NameHint 'new-handoff-entrypoint'
function Write-CaseText([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}
function New-EntrypointProject([string]$Name) {
    $project = Join-Path $fixture $Name
    Write-CaseText (Join-Path $project '.crucible/backlog/BACKLOG.md') "| ID | Status | Title |`n|---|---|---|`n| F-375 | Ready | Entrypoint fixture |`n"
    Write-CaseText (Join-Path $project 'src/a.txt') 'fixture'
    return $project
}
function Get-HandoffFiles([string]$Project) {
    $dir = Join-Path $Project '.crucible/session/handoffs'
    return @(if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -Filter '*.json' -File })
}

$results = @()
try {
    $refusalCaller = Join-Path $fixture 'refusal-caller.ps1'
    Write-CaseText $refusalCaller @'
param([string]$Generator, [string]$ProjectRoot, [string]$Case)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSStyle.OutputRendering = 'PlainText'
$common = @{ TaskId = 'F-375'; ProjectRoot = $ProjectRoot; OutputPath = (Join-Path $ProjectRoot 'out.json') }
try {
    $global:LASTEXITCODE = 0
    switch ($Case) {
        'invalid-source' { & $Generator @common -Source bogus -Target implementation -Reason 'binding fixture' }
        'missing-mandatory' { & $Generator @common -Source grooming -Target implementation }
        'type-conversion' { & $Generator @common -Source grooming -Target implementation -Reason 'binding fixture' -RebaseCount notanumber }
        'validate-set' { & $Generator @common -Source grooming -Target implementation -Reason 'binding fixture' -BudgetTier bogus }
        'parameter-set' { & $Generator @common -Source grooming -Target implementation -Reason 'binding fixture' -Rebaseline }
        'duplicate-colon' { & $Generator @common -Source grooming -Target implementation -Reason 'binding fixture' -RebaseCount:1 -RebaseCount:2 }
        'mixed-colon-first' { & $Generator @common -Source grooming -Target implementation -Reason 'binding fixture' -RebaseCount:1 -RebaseCount 2 }
        'mixed-colon-last' { & $Generator @common -Source grooming -Target implementation -Reason 'binding fixture' -RebaseCount 1 -RebaseCount:2 }
        'abbreviated' { & $Generator @common -Source grooming -Target implementation -Reason 'binding fixture' -RebaseC:1 -RebaseCount 2 }
        'common-alias' { & $Generator @common -Source grooming -Target implementation -Reason 'binding fixture' -ErrorAction:SilentlyContinue -ea Stop }
        'declared-prefix' { & $Generator @common -Source grooming -Target implementation -Reason 'binding fixture' -D:$false -DesignRequired }
        'splat-override' { $withSwitch = $common + @{ DesignRequired = $true }; & $Generator @withSwitch -Source grooming -Target implementation -Reason 'binding fixture' -DesignRequired:$false }
    }
    Write-Host ('CALLER_LASTEXITCODE=' + $LASTEXITCODE)
} catch {
    Write-Host ('CALLER_CAUGHT: ' + $_.Exception.Message)
    exit 0
}
exit $LASTEXITCODE
'@
    foreach ($case in @(
        @{ Name = 'invalid-source'; Expected = "Source.*does not belong to the set" },
        @{ Name = 'missing-mandatory'; Expected = 'missing mandatory parameters.*Reason' },
        @{ Name = 'type-conversion'; Expected = 'RebaseCount.*notanumber' },
        @{ Name = 'validate-set'; Expected = 'BudgetTier.*does not belong to the set' },
        @{ Name = 'parameter-set'; Expected = 'Parameter set cannot be resolved' },
        @{ Name = 'duplicate-colon'; Expected = "RebaseCount.*specified more than once" },
        @{ Name = 'mixed-colon-first'; Expected = "RebaseCount.*specified more than once" },
        @{ Name = 'mixed-colon-last'; Expected = "RebaseCount.*specified more than once" },
        @{ Name = 'abbreviated'; Expected = "RebaseCount.*specified more than once" },
        @{ Name = 'common-alias'; Expected = "ErrorAction.*specified more than once" },
        @{ Name = 'declared-prefix'; Expected = "DesignRequired.*specified more than once" },
        @{ Name = 'splat-override'; Expected = "DesignRequired.*specified more than once" }
    )) {
        $results += Run-Test ("Binding failure refuses an in-process caller: " + $case.Name) {
            $project = New-EntrypointProject ('refusal-' + $case.Name)
            $stderr = Join-Path $project 'stderr.txt'
            $res = Invoke-ExternalCommand { & $pwshCmd -NoProfile -NonInteractive -File $refusalCaller -Generator (Join-Path $source 'new-handoff.ps1') -ProjectRoot $project -Case $case.Name 2>$stderr }
            $output = @($res.Output) -join "`n"
            $diagnostic = [IO.File]::ReadAllText($stderr)
            # PowerShell may wrap a long error with a '|' gutter; read it as one line.
            $normalized = ($diagnostic -replace '(?m)^\s*\|\s?', '') -replace '\s+', ' '
            $evidence = "exit=$($res.ExitCode)`n$output`n$diagnostic"
            Assert-Result 'caller cannot catch the binding refusal' ($output -notmatch 'CALLER_CAUGHT') $evidence
            Assert-Result 'caller observes nonzero LASTEXITCODE' ($output -match 'CALLER_LASTEXITCODE=(-?\d+)' -and [int]$Matches[1] -ne 0) $evidence
            Assert-Result 'caller process exits nonzero' ($res.ExitCode -ne 0) $evidence
            Assert-Result 'stderr names the binding failure' ($normalized -match ('new-handoff\.ps1: .*' + $case.Expected)) $evidence
            Assert-Result 'no handoff is written' (-not (Test-Path -LiteralPath (Join-Path $project 'out.json')) -and (Get-HandoffFiles $project).Count -eq 0) $evidence
        }
    }

    $results += Run-Test 'A normal in-process call writes the same JSON and handoff as the core' {
        $project = New-EntrypointProject 'parity'
        $caller = Join-Path $project 'parity-caller.ps1'
        Write-CaseText $caller @'
param([string]$Source, [string]$ProjectRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSStyle.OutputRendering = 'PlainText'
try {
    foreach ($entry in @(@{ Name = 'entrypoint'; Script = (Join-Path $Source 'new-handoff.ps1') }, @{ Name = 'core'; Script = (Join-Path $Source 'lib/new-handoff-core.ps1') })) {
        # A hashtable-splatted switch, colon-bound values and a value shaped like a
        # parameter name must all bind exactly as they do against the core.
        $splat = @{
            TaskId = 'F-375'; Source = 'grooming'; Target = 'implementation'
            Reason = '-Source is a reason, not a parameter'; PromptVersion = 'implementation_prompt-v21'
            FileAffinity = @('src/', 'docs/'); DesignRequired = $true
            ProjectRoot = $ProjectRoot; OutputPath = (Join-Path $ProjectRoot ($entry.Name + '.json'))
        }
        $global:LASTEXITCODE = 0
        $stdout = & $entry.Script @splat -HandoffRetryCount:2 -Artifacts:@('src/a.txt')
        $code = $LASTEXITCODE
        [IO.File]::WriteAllText((Join-Path $ProjectRoot ($entry.Name + '.stdout')), (@($stdout) -join "`n"), [Text.UTF8Encoding]::new($false))
        Write-Host ('EXIT_' + $entry.Name + '=' + $code)
    }
} catch {
    Write-Host ('CALLER_CAUGHT: ' + $_.Exception.Message)
    exit 0
}
exit 0
'@
        $res = Invoke-ExternalCommand { & $pwshCmd -NoProfile -NonInteractive -File $caller -Source $source -ProjectRoot $project 2>&1 }
        $output = @($res.Output) -join "`n"
        Assert-Result 'parity caller completes without a caught error' ($output -notmatch 'CALLER_CAUGHT') $output
        Assert-Result 'entrypoint and core both exit 0' ($output -match 'EXIT_entrypoint=0' -and $output -match 'EXIT_core=0') $output
        $entryResult = [IO.File]::ReadAllText((Join-Path $project 'entrypoint.stdout')) | ConvertFrom-Json
        $coreResult = [IO.File]::ReadAllText((Join-Path $project 'core.stdout')) | ConvertFrom-Json
        Assert-Result 'entrypoint stdout is the JSON result' ($entryResult.ok -eq $true -and $entryResult.task_id -eq 'F-375' -and $entryResult.source -eq 'grooming' -and $entryResult.target -eq 'implementation' -and $entryResult.handoff_file -eq (Join-Path $project 'entrypoint.json')) $output
        $entryShape = [ordered]@{}; $coreShape = [ordered]@{}
        foreach ($p in $entryResult.PSObject.Properties) { if ($p.Name -ne 'handoff_file') { $entryShape[$p.Name] = $p.Value } }
        foreach ($p in $coreResult.PSObject.Properties) { if ($p.Name -ne 'handoff_file') { $coreShape[$p.Name] = $p.Value } }
        Assert-Result 'entrypoint JSON matches the core apart from its path' (($entryShape | ConvertTo-Json -Compress) -ceq ($coreShape | ConvertTo-Json -Compress)) $output
        $entryText = [IO.File]::ReadAllText((Join-Path $project 'entrypoint.json'))
        $coreText = [IO.File]::ReadAllText((Join-Path $project 'core.json'))
        Assert-Result 'entrypoint handoff is byte-identical to the core handoff' ($entryText -ceq $coreText) ("entrypoint:`n$entryText`ncore:`n$coreText")
        $handoff = $entryText | ConvertFrom-Json
        Assert-Result 'splatted switch, colon values and dash-led reason bound' ($handoff.design_required -eq $true -and $handoff.handoff_retry_count -eq 2 -and (@($handoff.artifacts) -join ',') -eq 'src/a.txt' -and $handoff.reason -ceq '-Source is a reason, not a parameter') $entryText

        $native = Invoke-ExternalCommand { & $pwshCmd -NoProfile -NonInteractive -File (Join-Path $source 'new-handoff.ps1') -TaskId F-375 -Source grooming -Target implementation -Reason 'native colon switch' -PromptVersion implementation_prompt-v21 -FileAffinity src/ '-DesignRequired:$false' -ProjectRoot $project -OutputPath (Join-Path $project 'native.json') 2>&1 }
        Assert-Result 'pwsh -File colon switch binds by name' ($native.ExitCode -eq 0 -and ([IO.File]::ReadAllText((Join-Path $project 'native.json')) | ConvertFrom-Json).design_required -eq $false) (@($native.Output) -join "`n")
    }
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
Write-TestFileSummary -Results $results
