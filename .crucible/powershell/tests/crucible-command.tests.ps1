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
    $output = @(Invoke-ExternalCommand -AsLines { & $Bash $scriptPath 2>&1 } | ForEach-Object { [string]$_ })
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
        Assert-Result "preflight needs no effort" ($preflight.Contains("-Preflight -Model 'model'")) $preflight
    }

    # Line breaks and NUL remain unsafe in the direct form. Native transports keep their
    # empty-value and leading-dash refusals.
    $results += Run-Test -Name "Unsafe values refuse before any command is returned" -Body {
        foreach ($case in @(@{ Value = "a`nb"; Invoker = "" }, @{ Value = "a`rb"; Invoker = "" }, @{ Value = ("a" + [char]0 + "b"); Invoker = "" })) {
            $value = $case.Value
            $message = ""
            try { $null = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters ([ordered]@{ TaskId = $value }) -CrucibleRoot $tempRoot -Invoker $case.Invoker -Strict } catch { $message = $_.Exception.Message }
            Assert-Result "unsafe value refused" ($message -match 'New-CrucibleCommand:') ("value: " + $value + "; " + $message)
        }
        $argMessage = ""
        try { $null = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters ([ordered]@{ TaskId = "-bad" }) -CrucibleRoot $tempRoot -Transport ArgumentList -Strict } catch { $argMessage = $_.Exception.Message }
        Assert-Result "leading dash refused for ArgumentList" ($argMessage.Contains("pwsh -File binds")) $argMessage
        foreach ($transport in @("Bash", "ArgumentList")) {
            foreach ($value in @("", "-bad")) {
                $message = ""
                try { $null = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters ([ordered]@{ TaskId = $value }) -CrucibleRoot $tempRoot -Transport $transport -Strict } catch { $message = $_.Exception.Message }
                Assert-Result ($transport + " refuses native-only unsafe value '" + $value + "'") ($message -match 'has an empty value|pwsh -File binds') $message
            }
        }
    }

    # Review of 6dcfdcf: next_step.txt is executed, not read, so the note must do nothing.
    $results += Run-Test -Name "The unavailable note is a comment in bash and in PowerShell" -Body {
        $note = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters ([ordered]@{ Init = $true; TaskId = "F-1" }) -CrucibleRoot $tempRoot -Transport Bash
        Assert-Result "note is a comment" ($note.StartsWith("# (command unavailable: ")) $note
        $bashRun = Invoke-TestBashLine -Bash (Get-TestBash) -Line $note -Name "note"
        Assert-Result "bash runs nothing" ($bashRun.ExitCode -eq 0 -and @($bashRun.Lines).Count -eq 0) (@($bashRun.Lines) -join " | ")
        $psOut = @(Invoke-ExternalCommand -AsLines { & ([scriptblock]::Create($note)) })
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
        $actual = @(Invoke-ExternalCommand -AsLines { & ([scriptblock]::Create($direct)) }) -join "`n"
        Assert-Result "direct values preserved" ($actual -ceq $expected) $actual

        $native = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters $parameters -CrucibleRoot $captureRoot -Invoker "pwsh -NoProfile -File"
        $driver = Join-Path $tempRoot "legacy-invoker.ps1"
        [IO.File]::WriteAllText($driver, ($native + "`n"), $utf8)
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $driver }
        Assert-Result "native invocation succeeds" ($run.ExitCode -eq 0) $run.Output
        Assert-Result "native values preserved" (($run.Output.Trim() -replace "`r`n", "`n") -ceq $expected) $run.Output
        Assert-Result "legacy invoker renders a direct call" ($native -ceq $direct) $native

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
            $actual = @(Invoke-ExternalCommand -AsLines { & ([scriptblock]::Create($direct)) })[2]
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

            # Legacy invokers must also render the direct form; no native passing remains.
            $native = New-CrucibleCommand -Script "powershell/crucible.ps1" -Parameters $parameters -CrucibleRoot $captureRoot -Invoker "pwsh -NoProfile -File"
            $nativeLine = @(Invoke-ExternalCommand -AsLines { & ([scriptblock]::Create($native)) })[2]
            Assert-Result ("native literal " + $i) ($native.StartsWith("& '") -and $nativeLine -ceq $expected) ($native + " => " + $nativeLine)

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
        $actual = @(Invoke-ExternalCommand -AsLines { & ([scriptblock]::Create($cmd)) }) -join "`n"
        Assert-Result "array retains two IDs" ($actual -ceq "C-1|C-10") $actual
        $message = ""
        try { $null = New-CrucibleCommand -Script "powershell/new-handoff.ps1" -Parameters ([ordered]@{ HumanApproved = @("C-1", "C-10") }) -CrucibleRoot $captureRoot -Transport ArgumentList -Strict } catch { $message = $_.Exception.Message }
        Assert-Result "native list refuses rather than collapsing IDs" ($message.Contains("pwsh -File accepts only scalar arguments")) $message
        $legacy = New-CrucibleCommand -Script "powershell/new-handoff.ps1" -Parameters ([ordered]@{ TaskId = "R-1"; Source = "research"; Target = "grooming"; Reason = "approve"; HumanApproved = @("C-1", "C-10") }) -CrucibleRoot $captureRoot -Invoker "pwsh -File" -Strict
        Assert-Result "legacy invoker retains two IDs directly" ((@(Invoke-ExternalCommand -AsLines { & ([scriptblock]::Create($legacy)) }) -join "`n") -ceq "C-1|C-10") $legacy
    }

    # Run the printed line inside a fresh pwsh, rather than passing its values through a
    # native -File boundary. The fixture writes bytes so even an empty value has evidence.
    $literalRoot = Join-Path $tempRoot "bundle O'Brien `$literal"
    $literalDir = Join-Path $literalRoot "powershell"
    $null = New-Item -ItemType Directory -Path $literalDir -Force
    [IO.File]::WriteAllText((Join-Path $literalDir "capture.ps1"), @'
param([AllowEmptyString()][string]$ProjectRoot, [string]$OutputPath)
if (-not $PSBoundParameters.ContainsKey('ProjectRoot')) { throw 'ProjectRoot was not bound' }
[IO.File]::WriteAllBytes($OutputPath, [Text.Encoding]::UTF8.GetBytes($ProjectRoot))
'@, $utf8)
    $results += Run-Test -Name "A child script can call its parent's loaded command builder" -Body {
        $child = Join-Path $tempRoot "build-from-child.ps1"
        [IO.File]::WriteAllText($child, @'
param($Root, $Destination)
New-CrucibleCommand -Script 'powershell/capture.ps1' -BundleRoot $Root -CrucibleRoot $Root -Parameters ([ordered]@{ ProjectRoot = 'child''s $HOME'; OutputPath = $Destination })
'@, $utf8)
        $destination = Join-Path $tempRoot "child-bytes.out"
        $line = Invoke-ExternalCommand -AsLines { & $child -Root $literalRoot -Destination $destination }
        Assert-Result "child script builds a direct command" ($line.StartsWith("& '")) $line
        $driver = Join-Path $tempRoot "run-child-command.ps1"
        [IO.File]::WriteAllText($driver, ($line + "`n"), $utf8)
        $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $driver }
        Assert-Result "child-built command executes" ($run.ExitCode -eq 0 -and (Test-Path -LiteralPath $destination)) ($line + " => " + $run.Output)
        Assert-Result "child-built literal arrives byte-for-byte" ([Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) -ceq [Convert]::ToBase64String($utf8.GetBytes("child's `$HOME"))) $line
    }
    $carried = @("O'Brien `$HOME", "O'Brien \\share", "it's ``tick", ("O" + [char]0x2019 + "Brien `$x"), "1'x `$y", "C:\O'Brien\`$x\\y", "_a'b `$c", ("O'Brien " + [char]0x201C + "q" + [char]0x201D))
    $launcherCases = @{ WindowsPowerShell = 0 }
    $legacy = if (Test-PlatformIsWindows) { Get-Command powershell.exe -ErrorAction SilentlyContinue } else { $null }
    # Item 290: a quote mixed with $, a backtick, typographic double quotes or a doubled
    # backslash was refused on ShellNeutral. Adjacent segments after a bare first character
    # are one argument in both shells; a value that cannot start bare stays refused.
    $results += Run-Test -Name "Shell-neutral literals carry quotes mixed with expansions under Bash, pwsh and a Windows PowerShell launcher" -Body {
        if (-not (Test-PlatformIsWindows)) { $carried += "/srv/o'brien/`$x" }
        $bash = Get-TestBash
        $index = 0
        foreach ($value in $carried) {
            $index++
            $outputPath = Join-Path $tempRoot ("mixed-" + $index + ".out")
            $line = New-CrucibleCommand -Script "powershell/capture.ps1" -BundleRoot $literalRoot -CrucibleRoot $literalRoot -Parameters ([ordered]@{ ProjectRoot = $value; OutputPath = $outputPath }) -Transport ShellNeutral -Strict
            Assert-Result ("mixed value " + $index + " starts pwsh") ($line.StartsWith("pwsh -NoProfile -ExecutionPolicy Bypass -File ")) $line
            $shells = @(@{ Name = "Bash"; Ext = "sh"; Bom = $false }, @{ Name = "pwsh"; Ext = "ps1"; Bom = $false })
            if ($null -ne $legacy) { $shells += @{ Name = "Windows PowerShell"; Ext = "ps1"; Bom = $true } }
            foreach ($shell in $shells) {
                if (Test-Path -LiteralPath $outputPath) { Remove-Item -LiteralPath $outputPath -Force }
                $driver = Join-Path $tempRoot ("mixed-" + $index + "." + $shell.Ext)
                [IO.File]::WriteAllText($driver, ($line + "`n"), (New-Object System.Text.UTF8Encoding($shell.Bom)))
                $run = switch ($shell.Name) {
                    "Bash" { Invoke-ExternalCommand { & $bash $driver } }
                    "pwsh" { Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $driver } }
                    default { Invoke-ExternalCommand { & $legacy.Source -NoProfile -ExecutionPolicy Bypass -File $driver } }
                }
                $actual = if (Test-Path -LiteralPath $outputPath) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($outputPath)) } else { "" }
                Assert-Result ($shell.Name + " delivers mixed value " + $index + " byte for byte") ($run.ExitCode -eq 0 -and $actual -ceq [Convert]::ToBase64String($utf8.GetBytes($value))) ($line + " => exit " + $run.ExitCode + ": " + $run.Output)
                if ($shell.Name -eq "Windows PowerShell") { $launcherCases.WindowsPowerShell++ }
            }
        }
        foreach ($value in @("'quoted' `$x", " O'Brien `$x", ".O'Brien `$x", "~O'Brien `$x", "@O'Brien `$x")) {
            $line = New-CrucibleCommand -Script "powershell/capture.ps1" -BundleRoot $literalRoot -CrucibleRoot $literalRoot -Parameters ([ordered]@{ ProjectRoot = $value }) -Transport ShellNeutral
            $message = ""
            try { $null = New-CrucibleCommand -Script "powershell/capture.ps1" -BundleRoot $literalRoot -CrucibleRoot $literalRoot -Parameters ([ordered]@{ ProjectRoot = $value }) -Transport ShellNeutral -Strict } catch { $message = $_.Exception.Message }
            $bashRun = Invoke-TestBashLine -Bash $bash -Line $line -Name "mixed-refused"
            Assert-Result ("a value that cannot start bare stays refused: " + $value) ($line.StartsWith("# (command unavailable: ") -and $message.Contains("does not start with a letter") -and $bashRun.ExitCode -eq 0 -and @($bashRun.Lines).Count -eq 0) ($line + "; strict=" + $message)
        }
    }

    $results += Run-Test -Name 'Windows PowerShell launcher coverage matches the platform' -Body {
        $expectedCases = if (Test-PlatformIsWindows) { $carried.Count } else { 0 }
        $probeResult = if ($null -eq $legacy) { 'not found ($null)' } else { $legacy.Source }
        Assert-Result 'every Windows launcher case executes on Windows only' ($launcherCases.WindowsPowerShell -eq $expectedCases) ("Expected $expectedCases Windows PowerShell launcher cases, executed $($launcherCases.WindowsPowerShell); powershell.exe probe: $probeResult")
        if (-not (Test-PlatformIsWindows)) {
            Skip-Test -Reason 'Windows PowerShell launcher checks require Windows; the powershell.exe probe is disabled on this platform.'
        }
    }

    $results += Run-Test -Name "A generated script's shell-neutral line runs it from Bash and pwsh" -Body {
        $outputPath = Join-Path $tempRoot "runner.out"
        $runnerPath = Join-Path $literalRoot "gate-handoff.ps1"
        [IO.File]::WriteAllText($runnerPath, ("& '" + (Join-Path $literalDir "capture.ps1").Replace("'", "''") + "' -ProjectRoot 'a b' -OutputPath '" + $outputPath.Replace("'", "''") + "'`n"), $utf8)
        $line = New-CrucibleScriptFileCommand -Path $runnerPath -Strict
        foreach ($ext in @("sh", "ps1")) {
            if (Test-Path -LiteralPath $outputPath) { Remove-Item -LiteralPath $outputPath -Force }
            $driver = Join-Path $tempRoot ("runner." + $ext)
            [IO.File]::WriteAllText($driver, ($line + "`n"), $utf8)
            $run = if ($ext -eq "sh") { Invoke-ExternalCommand { & (Get-TestBash) $driver } } else { Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $driver } }
            Assert-Result ("runner line runs from " + $ext) ($run.ExitCode -eq 0 -and (Test-Path -LiteralPath $outputPath) -and [IO.File]::ReadAllText($outputPath) -ceq "a b") ($line + " => " + $run.Output)
        }
        $note = New-CrucibleScriptFileCommand -Path ("x`ny.ps1")
        Assert-Result "a runner path with a line break prints the unavailable note" ($note.StartsWith("# (command unavailable: ")) $note
    }

    $cases = [ordered]@{
        "root with whitespace and trailing backslash" = 'C:\work dir\'
        "embedded double quote" = 'say "approved"'
        "single quote" = "O'Brien"
        "dollar sign" = 'cash$HOME'
        "empty value" = ""
    }
    $caseIndex = 0
    foreach ($caseName in $cases.Keys) {
        foreach ($invoker in @("pwsh -NoProfile -File", "powershell.exe -File")) {
            $caseIndex++
            $results += Run-Test -Name ("PowerShell printed literal: " + $caseName + "; invoker '" + $invoker + "'") -Body {
                $value = $cases[$caseName]
                $outputPath = Join-Path $tempRoot ("bytes-" + $caseIndex + ".out")
                $line = New-CrucibleCommand -Script "powershell/capture.ps1" -BundleRoot $literalRoot -CrucibleRoot $literalRoot -Parameters ([ordered]@{ ProjectRoot = $value; OutputPath = $outputPath }) -Invoker $invoker
                $driver = Join-Path $tempRoot ("printed-" + $caseIndex + ".ps1")
                [IO.File]::WriteAllText($driver, ($line + "`n"), $utf8)
                $run = Invoke-ExternalCommand { & (Get-PwshCommand) -NoProfile -File $driver }
                Assert-Result "printed literal executes in pwsh" ($run.ExitCode -eq 0) ($line + " => " + $run.Output)
                Assert-Result "fixture received the printed literal" (Test-Path -LiteralPath $outputPath) $line
                $actualBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($outputPath))
                $expectedBytes = [Convert]::ToBase64String($utf8.GetBytes($value))
                Assert-Result "printed literal arrives byte-for-byte" ($actualBytes -ceq $expectedBytes) ($line + " => " + $actualBytes)
                $expectedPath = (Join-Path $literalDir "capture.ps1").Replace("'", "''")
                Assert-Result "printed literal uses direct quoted script" ($line.StartsWith("& '" + $expectedPath + "' -ProjectRoot ")) $line
                Assert-Result "printed literal uses single-quoted value" ($line.Contains("-ProjectRoot '" + $value.Replace("'", "''") + "' -OutputPath ")) $line
            }
        }
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    $runRoot = [IO.Path]::GetFullPath((Get-TestRunRoot)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($runRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture escaped the test run root: $resolved" }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

Write-TestFileSummary -Results $results
