# Item 247: bind commands to the real param blocks, then execute the rendered forms.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$REPO_ROOT = (Resolve-Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot "_harness.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$results = @()
$builder = Join-Path $REPO_ROOT "powershell/lib/crucible-command.ps1"
$results += Run-Test -Name "Printed command builder is available" -Body {
    Assert-Result "builder exists" (Test-Path -LiteralPath $builder) "the runtime has no bound command builder"
}
if (-not $results[-1]) { exit 1 }
. $builder
$tempRoot = New-TestFixtureRoot -NameHint "command builder"

# Runs one rendered line as a bash script file, as an agent's Bash tool would run it.
function Invoke-TestBashLine {
    param([Parameter(Mandatory = $true)][string]$Bash, [Parameter(Mandatory = $true)][string]$Line, [Parameter(Mandatory = $true)][string]$Name)
    $scriptPath = Join-Path $tempRoot ($Name + ".sh")
    [System.IO.File]::WriteAllText($scriptPath, ($Line + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $output = @(& $Bash $scriptPath 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $output }
}
$utf8 = [System.Text.UTF8Encoding]::new($false)

try {
    $results += Run-Test -Name "Builder rejects unknown parameters and missing companions" -Body {
        $cases = @(
            @{ Script = "powershell/crucible.ps1"; Params = [ordered]@{ TaskID2 = "F-1" }; Error = "declares no parameter -TaskID2" },
            @{ Script = "powershell/crucible.ps1"; Params = [ordered]@{ Init = $true; TaskId = "F-1" }; Error = "-Init needs -ProjectRoot" },
            @{ Script = "powershell/launch-codex-specialist.ps1"; Params = [ordered]@{ Model = "model" }; Error = "-Model needs -Effort" },
            @{ Script = "powershell/crucible.ps1"; Params = [ordered]@{ Health = "yes" }; Error = "is a switch" },
            @{ Script = "powershell/crucible.ps1"; Params = [ordered]@{ TaskId = $true }; Error = "takes a value" },
            @{ Script = "powershell/not-a-script.ps1"; Params = [ordered]@{}; Error = "no script" }
        )
        foreach ($case in $cases) {
            $message = ""
            try { $null = New-CrucibleCommand -Script $case.Script -Parameters $case.Params -CrucibleRoot $tempRoot -Strict } catch { $message = $_.Exception.Message }
            Assert-Result -Name ("refuses " + $case.Error) -Condition ($message.Contains($case.Error)) -FailureMessage $message
            # Without -Strict the same refusal is the printed text, so the surface still prints.
            $degraded = New-CrucibleCommand -Script $case.Script -Parameters $case.Params -CrucibleRoot $tempRoot
            Assert-Result -Name ("degrades " + $case.Error) -Condition ($degraded.StartsWith("# (command unavailable: ") -and $degraded.Contains($case.Error)) -FailureMessage $degraded
        }
        $preflight = New-CrucibleCommand -Script "powershell/launch-codex-specialist.ps1" -Parameters ([ordered]@{ Preflight = $true; Model = "model" }) -CrucibleRoot $tempRoot
        Assert-Result "preflight needs no effort" ($preflight.Contains("-Preflight -Model model")) $preflight
    }

    # Only what no quoting puts on one command line is refused: an empty value (older PowerShell
    # drops it), a line break or NUL anywhere, and a leading dash where pwsh -File would bind
    # the value as a parameter name.
    $results += Run-Test -Name "Unsafe values refuse before any command is returned" -Body {
        foreach ($case in @(@{ Value = ""; Invoker = "" }, @{ Value = "a`nb"; Invoker = "" }, @{ Value = "a`rb"; Invoker = "" }, @{ Value = ("a" + [char]0 + "b"); Invoker = "" }, @{ Value = "-bad"; Invoker = "pwsh -File" })) {
            $value = $case.Value
            $message = ""
            try { $null = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters ([ordered]@{ TaskId = $value }) -CrucibleRoot $tempRoot -Invoker $case.Invoker -Strict } catch { $message = $_.Exception.Message }
            Assert-Result "unsafe value refused" ($message -match 'New-CrucibleCommand:') ("value: " + $value + "; " + $message)
        }
        $argMessage = ""
        try { $null = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters ([ordered]@{ TaskId = "-bad" }) -CrucibleRoot $tempRoot -Transport ArgumentList -Strict } catch { $argMessage = $_.Exception.Message }
        Assert-Result "leading dash refused for ArgumentList" ($argMessage.Contains("pwsh -File binds")) $argMessage
    }

    # Review of 6dcfdcf: next_step.txt is executed, not read, so the note must do nothing.
    $results += Run-Test -Name "The unavailable note is a comment in bash and in PowerShell" -Body {
        $note = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters ([ordered]@{ Init = $true; TaskId = "F-1" }) -CrucibleRoot $tempRoot -Transport Bash
        Assert-Result "note is a comment" ($note.StartsWith("# (command unavailable: ")) $note
        $bashRun = Invoke-TestBashLine -Bash (Get-TestBash) -Line $note -Name "note"
        Assert-Result "bash runs nothing" ($bashRun.ExitCode -eq 0 -and @($bashRun.Lines).Count -eq 0) (@($bashRun.Lines) -join " | ")
        $psOut = @(& ([scriptblock]::Create($note)))
        Assert-Result "PowerShell runs nothing" ($psOut.Count -eq 0) ($psOut -join " | ")
    }

    # Copy only the real declaration into an inert script: no agent CLI can run here.
    $captureRoot = Join-Path $tempRoot "bundle with spaces"
    $captureDir = Join-Path $captureRoot "powershell"
    $null = New-Item -ItemType Directory -Path $captureDir -Force
    $tokens = $null; $errors = $null
    $target = Join-Path $REPO_ROOT "powershell/crucible.ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors)
    $captureBody = $ast.ParamBlock.Extent.Text + @'

# Non-ASCII prints as \uXXXX so the console code page cannot change what a test compares.
$rootShown = -join @($ProjectRoot.ToCharArray() | ForEach-Object { if ([int]$_ -gt 126) { "\u" + ([int]$_).ToString("X4") } else { [string]$_ } })
@("init=$Init", "task=$TaskId", "root=$rootShown", "reason=$GateReason")
'@
    [System.IO.File]::WriteAllText((Join-Path $captureDir "crucible.ps1"), $captureBody, $utf8)

    $results += Run-Test -Name "Rendered commands carry spaces and punctuation through direct and background invocation" -Body {
        $project = Join-Path $tempRoot "project O'Brien (one); & two"
        $parameters = [ordered]@{ Init = $true; TaskId = "F-247"; ProjectRoot = $project; GateReason = "approve O'Brien; & (checks)" }
        $expected = @("init=True", "task=F-247", ("root=" + $project), "reason=approve O'Brien; & (checks)") -join "`n"
        $direct = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters $parameters -CrucibleRoot $captureRoot
        $actual = @(& ([scriptblock]::Create($direct))) -join "`n"
        Assert-Result "direct values preserved" ($actual -ceq $expected) $actual

        $native = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters $parameters -CrucibleRoot $captureRoot -Invoker "pwsh -NoProfile -File"
        $run = Invoke-ExternalCommand { & ([scriptblock]::Create($native)) }
        Assert-Result "native invocation succeeds" ($run.ExitCode -eq 0) $run.Output
        Assert-Result "native values preserved" (($run.Output.Trim() -replace "`r`n", "`n") -ceq $expected) $run.Output

        $stdout = Join-Path $tempRoot "background.out"
        $stderr = Join-Path $tempRoot "background.err"
        $window = @{}
        if (Test-PlatformIsWindows) { $window.WindowStyle = "Hidden" }
        $argumentList = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters $parameters -CrucibleRoot $captureRoot -Transport ArgumentList -Strict
        $proc = Start-Process -FilePath (Get-PwshCommand) -ArgumentList $argumentList @window -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        Assert-Result "background invocation succeeds" ($proc.ExitCode -eq 0) ([System.IO.File]::ReadAllText($stderr))
        $actual = [System.IO.File]::ReadAllText($stdout).Trim() -replace "`r`n", "`n"
        Assert-Result "background values preserved" ($actual -ceq $expected) $actual
    }

    # Review of 5d1b869: these values were refused, so the surface that printed the command
    # threw instead. Each is a literal on a PowerShell prompt and its own encoding for
    # Start-Process, and each arrives at the script byte for byte.
    $results += Run-Test -Name "Dollar signs, quotes, backticks and trailing backslashes reach the script verbatim" -Body {
        $values = @('C:\cash$root', 'D:\', 'C:\a b\', ('it' + [char]0x2019 + 's "quoted" $HOME'), "back``tick O'Brien", "-dash", "it's `$x", '\\srv\share', '/c/Users', '/tmp', 'x=/tmp')
        $bash = Get-TestBash
        $window = @{}
        if (Test-PlatformIsWindows) { $window.WindowStyle = "Hidden" }
        $i = 0
        foreach ($value in $values) {
            $i++
            $parameters = [ordered]@{ Init = $true; TaskId = "F-247"; ProjectRoot = $value }
            $expected = "root=" + (-join @($value.ToCharArray() | ForEach-Object { if ([int]$_ -gt 126) { "\u" + ([int]$_).ToString("X4") } else { [string]$_ } }))
            $direct = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters $parameters -CrucibleRoot $captureRoot -Strict
            $actual = @(& ([scriptblock]::Create($direct)))[2]
            Assert-Result ("direct literal " + $i) ($actual -ceq $expected) ($direct + " => " + $actual)
            if ($value.StartsWith("-")) { continue }

            # Review of ae04d9c: Git Bash rewrites a POSIX-looking value (/tmp, x=/tmp) before a
            # Windows pwsh sees it, so on Windows that value has no Bash line.
            $gitBashRewrites = (Test-PlatformIsWindows) -and ($value -match '^@?/' -or $value -match '^\S*=@?/')
            if ($gitBashRewrites) {
                $bashLine = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters $parameters -CrucibleRoot $captureRoot -Transport Bash -Invoker "pwsh -NoProfile -File"
                Assert-Result ("bash literal " + $i + " unavailable") ($bashLine.StartsWith("# (command unavailable: ") -and $bashLine.Contains("Git Bash rewrites")) $bashLine
                Assert-Result ("bash literal " + $i + " sets no MSYS switch") (-not $bashLine.Contains("MSYS_NO_PATHCONV")) $bashLine
            } else {
                $bashLine = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters $parameters -CrucibleRoot $captureRoot -Transport Bash -Invoker "pwsh -NoProfile -File" -Strict
                $bashOutput = Invoke-TestBashLine -Bash $bash -Line $bashLine -Name ("literal-" + $i)
                Assert-Result ("bash literal " + $i) ($bashOutput.ExitCode -eq 0 -and @($bashOutput.Lines)[2] -ceq $expected) ($bashLine + " => " + ($bashOutput.Lines -join " | "))
            }

            # Windows PowerShell 5.1 and PowerShell 7.0 to 7.2 pass these to pwsh -File broken,
            # so a PowerShell -File line prints the unavailable note instead.
            $olderBreaks = $value.Contains('"') -or ($value.EndsWith("\") -and $value -match '\s')
            $native = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters $parameters -CrucibleRoot $captureRoot -Invoker "pwsh -NoProfile -File"
            if ($olderBreaks) {
                Assert-Result ("native literal " + $i + " unavailable") ($native.StartsWith("# (command unavailable: ")) $native
            } else {
                $run = Invoke-ExternalCommand { & ([scriptblock]::Create($native)) }
                $nativeLine = @($run.Output -split "`r?`n")[2]
                Assert-Result ("native literal " + $i) ($run.ExitCode -eq 0 -and $nativeLine -ceq $expected) ($native + " => " + $run.Output)
            }

            $argumentList = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters $parameters -CrucibleRoot $captureRoot -Transport ArgumentList -Strict
            $stdout = Join-Path $tempRoot ("literal-" + $i + ".out")
            $stderr = Join-Path $tempRoot ("literal-" + $i + ".err")
            $proc = Start-Process -FilePath (Get-PwshCommand) -ArgumentList $argumentList @window -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            $backgroundLine = @([System.IO.File]::ReadAllText($stdout) -split "`r?`n")[2]
            Assert-Result ("ArgumentList literal " + $i) ($proc.ExitCode -eq 0 -and $backgroundLine -ceq $expected) ($argumentList + " => " + [System.IO.File]::ReadAllText($stdout) + [System.IO.File]::ReadAllText($stderr))
        }
    }

    $results += Run-Test -Name "Array values preserve separate handoff IDs" -Body {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $REPO_ROOT "powershell/new-handoff.ps1"), [ref]$tokens, [ref]$errors)
        [System.IO.File]::WriteAllText((Join-Path $captureDir "new-handoff.ps1"), ($ast.ParamBlock.Extent.Text + "`n`$HumanApproved -join '|'`n"), $utf8)
        $cmd = New-CrucibleCommand -Script "powershell/new-handoff.ps1" -Parameters ([ordered]@{ TaskId = "R-1"; Source = "research"; Target = "grooming"; Reason = "approve"; HumanApproved = @("C-1", "C-10") }) -CrucibleRoot $captureRoot
        $actual = @(& ([scriptblock]::Create($cmd))) -join "`n"
        Assert-Result "array retains two IDs" ($actual -ceq "C-1|C-10") $actual
        $message = ""
        try { $null = New-CrucibleCommand -Script "powershell/new-handoff.ps1" -Parameters ([ordered]@{ HumanApproved = @("C-1", "C-10") }) -CrucibleRoot $captureRoot -Invoker "pwsh -File" -Strict } catch { $message = $_.Exception.Message }
        Assert-Result "native list refuses rather than collapsing IDs" ($message.Contains("pwsh -File accepts only scalar arguments")) $message
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    $runRoot = [IO.Path]::GetFullPath((Get-TestRunRoot)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($runRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture escaped the test run root: $resolved" }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

if (@($results | Where-Object { -not $_ }).Count -gt 0) { exit 1 }
Write-Host "ALL TESTS PASSED ($($results.Count) tests)"
