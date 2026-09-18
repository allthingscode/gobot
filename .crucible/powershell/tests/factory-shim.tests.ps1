# Tests for the deprecated powershell/factory.ps1 entrypoint shim.
#
# The shim forwards to crucible.ps1, so every assertion here is about transparency:
# what the caller sent, what came back, and what the caller saw. A shim that quietly
# reshapes any of those is worse than no shim, because the old path keeps working
# while behaving differently from the new one.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")

$results = @()
$shell = Get-PwshCommand

# The stub stands in for crucible.ps1 so the assertions are about the shim alone.
# It declares no param() block for the same reason the shim does not: every token
# must be observable exactly as the shim passed it.
$STUB_BODY = @'
$ErrorActionPreference = "Stop"
[Console]::Out.WriteLine("STUB-STDOUT-MARKER")
[Console]::Error.WriteLine("STUB-STDERR-MARKER")
foreach ($a in $args) { [Console]::Out.WriteLine("ARG:[" + $a + "]") }
if ($args -contains "-FailMe") { exit 7 }
exit 0
'@

# Builds a fixture bundle: the real shim, the real library tree it needs to emit its
# event, and the stub in place of the entrypoint.
function New-ShimFixture {
    param([string]$ShimSource = "")

    $root = New-TestFixtureRoot -NameHint "shim-test"
    $ps = Join-Path $root "powershell"
    New-Item -ItemType Directory -Path $ps -Force | Out-Null
    Copy-Item -Path (Join-Path $REPO_ROOT "powershell/lib") -Destination $ps -Recurse -Force
    Copy-Item -Path (Join-Path $REPO_ROOT "powershell/crucible-lib.ps1") -Destination $ps -Force

    if ([string]::IsNullOrEmpty($ShimSource)) {
        Copy-Item -Path (Join-Path $REPO_ROOT "powershell/factory.ps1") -Destination $ps -Force
    } else {
        [System.IO.File]::WriteAllText((Join-Path $ps "factory.ps1"), $ShimSource, [System.Text.UTF8Encoding]::new($false))
    }
    [System.IO.File]::WriteAllText((Join-Path $ps "crucible.ps1"), $STUB_BODY, [System.Text.UTF8Encoding]::new($false))
    return $root
}

function Invoke-Shim {
    param([string]$FixtureRoot, [string]$ArgumentTail)

    $shim = Join-Path $FixtureRoot "powershell/factory.ps1"
    $outFile = Join-Path $FixtureRoot "stdout.txt"
    $errFile = Join-Path $FixtureRoot "stderr.txt"
    # One argument string rather than an array: PowerShell 5.1's Start-Process array
    # quoting is the behaviour this test holds the shim to, so it must not also be the
    # thing under test.
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $shim + '" -ProjectRoot "' + $FixtureRoot + '" ' + $ArgumentTail
    $proc = Start-Process -FilePath $shell -ArgumentList $argLine `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -Wait -PassThru -NoNewWindow
    return @{
        ExitCode = $proc.ExitCode
        StdOut   = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        StdErr   = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
    }
}

function Get-DeprecationEvents {
    param([string]$FixtureRoot, [string]$TaskId)

    $log = if ([string]::IsNullOrEmpty($TaskId)) {
        Join-Path $FixtureRoot ".crucible/session/global/pipeline.log.jsonl"
    } else {
        Join-Path $FixtureRoot (".crucible/session/" + $TaskId + "/pipeline.log.jsonl")
    }
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    return @(Get-Content -LiteralPath $log | Where-Object { $_ -match '"event":"deprecated_entrypoint"' })
}

$results += Run-Test -Name "the shim forwards every argument unchanged, including one containing spaces" -Body {
    $fixture = New-ShimFixture
    try {
        $r = Invoke-Shim -FixtureRoot $fixture -ArgumentTail '-Init -TaskId F-001 -GateReason "two words here"'
        Assert-Result -Name "-Init survived" -Condition ($r.StdOut -match '(?m)^ARG:\[-Init\]') -FailureMessage ("stdout: " + $r.StdOut + " stderr: " + $r.StdErr)
        Assert-Result -Name "-TaskId survived" -Condition ($r.StdOut -match '(?m)^ARG:\[-TaskId\]') -FailureMessage ("stdout: " + $r.StdOut)
        Assert-Result -Name "task id value survived" -Condition ($r.StdOut -match '(?m)^ARG:\[F-001\]') -FailureMessage ("stdout: " + $r.StdOut)
        Assert-Result -Name "spaced argument arrived as one token" -Condition ($r.StdOut -match '(?m)^ARG:\[two words here\]') -FailureMessage ("stdout: " + $r.StdOut)
    } finally {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "the shim preserves a zero exit code" -Body {
    $fixture = New-ShimFixture
    try {
        $r = Invoke-Shim -FixtureRoot $fixture -ArgumentTail '-Init -TaskId F-001'
        Assert-Result -Name "exit 0 preserved" -Condition ($r.ExitCode -eq 0) -FailureMessage (Format-ProcessExitMessage -ExitCode $r.ExitCode -ExpectedExitCode 0 -Output ($r.StdOut + $r.StdErr))
    } finally {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "the shim preserves a non-zero exit code" -Body {
    $fixture = New-ShimFixture
    try {
        $r = Invoke-Shim -FixtureRoot $fixture -ArgumentTail '-Init -TaskId F-001 -FailMe'
        Assert-Result -Name "exit 7 preserved" -Condition ($r.ExitCode -eq 7) -FailureMessage (Format-ProcessExitMessage -ExitCode $r.ExitCode -ExpectedExitCode 7 -Output ($r.StdOut + $r.StdErr))
    } finally {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "the shim swallows neither stream, and warns on stderr rather than stdout" -Body {
    $fixture = New-ShimFixture
    try {
        $r = Invoke-Shim -FixtureRoot $fixture -ArgumentTail '-Init -TaskId F-001'
        Assert-Result -Name "child stdout reached the caller" -Condition ($r.StdOut -match 'STUB-STDOUT-MARKER') -FailureMessage ("stdout: " + $r.StdOut)
        Assert-Result -Name "child stderr reached the caller" -Condition ($r.StdErr -match 'STUB-STDERR-MARKER') -FailureMessage ("stderr: " + $r.StdErr)
        Assert-Result -Name "deprecation notice went to stderr" -Condition ($r.StdErr -match '\[DEPRECATED\]') -FailureMessage ("stderr: " + $r.StdErr)
        # Anything the shim prints on stdout lands in whatever the caller is parsing,
        # and orchestrators parse this stream for the [NEXT SESSION COMMAND] markers.
        Assert-Result -Name "stdout carries nothing from the shim" -Condition ($r.StdOut -notmatch '\[DEPRECATED\]') -FailureMessage ("stdout: " + $r.StdOut)
    } finally {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "the shim emits exactly one deprecated_entrypoint event per invocation" -Body {
    $fixture = New-ShimFixture
    try {
        $r = Invoke-Shim -FixtureRoot $fixture -ArgumentTail '-Init -TaskId F-001'
        $events = @(Get-DeprecationEvents -FixtureRoot $fixture -TaskId "F-001")
        Assert-Result -Name "one event written" -Condition ($events.Count -eq 1) -FailureMessage ("expected 1 deprecated_entrypoint event, got " + $events.Count + ". stderr: " + $r.StdErr)
        Assert-Result -Name "event carries the kind D2 queries on" -Condition ($events[0] -match '"kind":"deprecated_entrypoint_factory_ps1"') -FailureMessage ("event: " + $events[0])
        Assert-Result -Name "event carries the invoking task id" -Condition ($events[0] -match '"task_id":"F-001"') -FailureMessage ("event: " + $events[0])

        $second = Invoke-Shim -FixtureRoot $fixture -ArgumentTail '-Init -TaskId F-001'
        $after = @(Get-DeprecationEvents -FixtureRoot $fixture -TaskId "F-001")
        Assert-Result -Name "a second invocation adds exactly one more" -Condition ($after.Count -eq 2) -FailureMessage ("expected 2, got " + $after.Count + ". stderr: " + $second.StdErr)
    } finally {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "an invocation with no -TaskId still records the event, against the global log" -Body {
    $fixture = New-ShimFixture
    try {
        $r = Invoke-Shim -FixtureRoot $fixture -ArgumentTail '-Health'
        Assert-Result -Name "exit preserved" -Condition ($r.ExitCode -eq 0) -FailureMessage (Format-ProcessExitMessage -ExitCode $r.ExitCode -ExpectedExitCode 0 -Output ($r.StdOut + $r.StdErr))
        $events = @(Get-DeprecationEvents -FixtureRoot $fixture -TaskId "")
        Assert-Result -Name "one global event written" -Condition ($events.Count -eq 1) -FailureMessage ("expected 1 global deprecated_entrypoint event, got " + $events.Count + ". stderr: " + $r.StdErr)
    } finally {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "MUTATION: a shim that drops its arguments fails the forwarding assertions" -Body {
    $mutant = @'
$crucibleScript = Join-Path $PSScriptRoot "crucible.ps1"
& $crucibleScript
exit $LASTEXITCODE
'@
    $fixture = New-ShimFixture -ShimSource $mutant
    try {
        $r = Invoke-Shim -FixtureRoot $fixture -ArgumentTail '-Init -TaskId F-001 -GateReason "two words here"'
        Assert-Result -Name "arguments are visibly gone" -Condition ($r.StdOut -notmatch '(?m)^ARG:\[-Init\]') -FailureMessage ("an arg-dropping shim still forwarded -Init, so the forwarding assertions prove nothing. stdout: " + $r.StdOut)
    } finally {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results += Run-Test -Name "MUTATION: a shim that hardcodes exit 0 fails the exit-code assertion" -Body {
    $mutant = @'
$crucibleScript = Join-Path $PSScriptRoot "crucible.ps1"
& $crucibleScript @args
exit 0
'@
    $fixture = New-ShimFixture -ShimSource $mutant
    try {
        $r = Invoke-Shim -FixtureRoot $fixture -ArgumentTail '-Init -TaskId F-001 -FailMe'
        Assert-Result -Name "the non-zero code is visibly lost" -Condition ($r.ExitCode -ne 7) -FailureMessage "an exit-0 shim still reported 7, so the exit-code assertion proves nothing"
    } finally {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($results -contains $false) {
    exit 1
} else {
    exit 0
}
