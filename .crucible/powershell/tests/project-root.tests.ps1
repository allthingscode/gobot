# Regression tests for powershell/lib/project-root.ps1.
#
# The question this helper answers - "which project am I operating on?" - used to be
# answered four separate times, and validate-backlog.ps1's answer was the naive one: fall
# back to the working directory and validate whatever was there. Found by TODO item 60,
# where a Groomer standing in another checkout was told "Backlog file not found" about a
# repository it had never been asked about.

$ErrorActionPreference = "Stop"
$REPO_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $REPO_ROOT "powershell/lib/project-root.ps1")
. (Join-Path $REPO_ROOT "powershell/lib/platform.ps1")
$results = @()

$tempRoot = New-TestFixtureRoot -NameHint "project-root-test"

function New-ProjectDir {
    param([string]$Path, [switch]$WithConfig, [switch]$WithBacklog)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    if ($WithBacklog) { New-Item -ItemType Directory -Path (Join-Path $Path ".crucible/backlog") -Force | Out-Null }
    if ($WithConfig) {
        New-Item -ItemType Directory -Path (Join-Path $Path ".crucible") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Path ".crucible/config.yaml") -Value "crucible_root: .crucible" -Encoding UTF8
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

try {
    $results += Run-Test -Name "A directory is a project when either marker is present" -Body {
        $withBacklog = New-ProjectDir -Path (Join-Path $tempRoot "marker-backlog") -WithBacklog
        $withConfig  = New-ProjectDir -Path (Join-Path $tempRoot "marker-config") -WithConfig
        $bare        = New-ProjectDir -Path (Join-Path $tempRoot "marker-none")

        Assert-Result -Name ".crucible/backlog counts" -Condition (Test-CrucibleProjectRoot -Path $withBacklog) -FailureMessage "a directory with .crucible/backlog was not recognized as a project"
        Assert-Result -Name ".crucible/config.yaml counts" -Condition (Test-CrucibleProjectRoot -Path $withConfig) -FailureMessage "a directory with .crucible/config.yaml was not recognized as a project"
        Assert-Result -Name "neither marker does not count" -Condition (-not (Test-CrucibleProjectRoot -Path $bare)) -FailureMessage "a directory with no .crucible markers was recognized as a project"
        Assert-Result -Name "a path that does not exist does not count" -Condition (-not (Test-CrucibleProjectRoot -Path (Join-Path $tempRoot "absent"))) -FailureMessage "a non-existent path was recognized as a project"
        Assert-Result -Name "an empty path does not count" -Condition (-not (Test-CrucibleProjectRoot -Path "")) -FailureMessage "an empty path was recognized as a project"
    }

    $results += Run-Test -Name "An explicit root wins over everything else" -Body {
        $explicit = New-ProjectDir -Path (Join-Path $tempRoot "explicit") -WithConfig
        $derivable = New-ProjectDir -Path (Join-Path $tempRoot "derivable") -WithConfig
        $scriptRoot = Join-Path $derivable ".crucible/powershell"
        New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null

        $resolved = Resolve-CrucibleProjectRoot -ProjectRoot $explicit -ScriptRoot $scriptRoot
        Assert-Result -Name "explicit root returned" -Condition ($resolved -eq $explicit) -FailureMessage ("expected '" + $explicit + "', got '" + $resolved + "'")
    }

    # The bundle ships at <adopter>/.crucible/powershell/, so the script's own location names
    # the adopter. This is the case the working-directory fallback used to get wrong: an
    # orchestrator standing anywhere else still has to reach the right project.
    $results += Run-Test -Name "A bundled script derives its adopter, whatever the working directory" -Body {
        $adopter = New-ProjectDir -Path (Join-Path $tempRoot "adopter") -WithBacklog
        $scriptRoot = Join-Path $adopter ".crucible/powershell"
        New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null
        $elsewhere = New-ProjectDir -Path (Join-Path $tempRoot "elsewhere")

        Push-Location $elsewhere
        try {
            $resolved = Resolve-CrucibleProjectRoot -ProjectRoot "" -ScriptRoot $scriptRoot
        } finally {
            Pop-Location
        }
        Assert-Result -Name "derived the adopter, not the cwd" -Condition ($resolved -eq $adopter) -FailureMessage ("expected '" + $adopter + "', got '" + $resolved + "'")
    }

    # The canonical framework checkout is not itself an adopter, so a script running from
    # <crucible>/powershell/ has nothing to derive and the working directory is all there is.
    $results += Run-Test -Name "An underivable script accepts a working directory that is a project" -Body {
        $framework = New-ProjectDir -Path (Join-Path $tempRoot "framework")
        $scriptRoot = Join-Path $framework "powershell"
        New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null
        $project = New-ProjectDir -Path (Join-Path $tempRoot "cwd-project") -WithConfig

        Push-Location $project
        try {
            $resolved = Resolve-CrucibleProjectRoot -ProjectRoot "" -ScriptRoot $scriptRoot
        } finally {
            Pop-Location
        }
        Assert-Result -Name "cwd accepted when it is a project" -Condition ($resolved -eq $project) -FailureMessage ("expected '" + $project + "', got '" + $resolved + "'")
    }

    # The defect itself. With nothing to derive and a working directory that is not a
    # project, the old code guessed and carried on; the caller then read a report about a
    # repository it had never named. An unanswered question has to be asked, not guessed.
    $results += Run-Test -Name "An unrelated working directory is refused, naming the parameter" -Body {
        $framework = New-ProjectDir -Path (Join-Path $tempRoot "framework-strict")
        $scriptRoot = Join-Path $framework "powershell"
        New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null
        $unrelated = New-ProjectDir -Path (Join-Path $tempRoot "unrelated")

        $threw = $false
        $message = ""
        Push-Location $unrelated
        try {
            $null = Resolve-CrucibleProjectRoot -ProjectRoot "" -ScriptRoot $scriptRoot
        } catch {
            $threw = $true
            $message = $_.Exception.Message
        } finally {
            Pop-Location
        }
        Assert-Result -Name "refused rather than guessed" -Condition $threw -FailureMessage "an unrelated working directory was accepted as the project root"
        Assert-Result -Name "the message names -ProjectRoot" -Condition ($message -match '\-ProjectRoot') -FailureMessage ("the failure has to name the parameter the caller must pass. Message: " + $message)
        Assert-Result -Name "the message names the directory it rejected" -Condition ($message -match [regex]::Escape($unrelated)) -FailureMessage ("the failure has to name the working directory it looked at. Message: " + $message)
    }

    $results += Run-Test -Name "An explicit root that does not exist is refused, not resolved" -Body {
        $absent = Join-Path $tempRoot "no-such-project"
        $threw = $false
        $message = ""
        try {
            $null = Resolve-CrucibleProjectRoot -ProjectRoot $absent -ScriptRoot (Join-Path $REPO_ROOT "powershell")
        } catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        Assert-Result -Name "refused" -Condition $threw -FailureMessage "a -ProjectRoot naming a path that does not exist was accepted"
        Assert-Result -Name "names the bad path" -Condition ($message -match [regex]::Escape($absent)) -FailureMessage ("the failure has to name the path it could not find. Message: " + $message)
        # Resolve-Path would throw here on its own, but its message names only the path.
        # Every refusal from this helper names the parameter the caller has to fix, which
        # is the whole point of item 60: the reader must be told what to pass, not just
        # what went wrong.
        Assert-Result -Name "names -ProjectRoot" -Condition ($message -match '\-ProjectRoot') -FailureMessage ("the failure has to name the parameter that carried the bad path. Message: " + $message)
    }

    # The caller's parameter is not always spelled -ProjectRoot, and a message naming a
    # parameter the caller cannot pass is worse than no message at all.
    $results += Run-Test -Name "The refusal names the caller's own parameter" -Body {
        $framework = New-ProjectDir -Path (Join-Path $tempRoot "framework-named")
        $scriptRoot = Join-Path $framework "powershell"
        New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null
        $unrelated = New-ProjectDir -Path (Join-Path $tempRoot "unrelated-named")

        $message = ""
        Push-Location $unrelated
        try {
            $null = Resolve-CrucibleProjectRoot -ProjectRoot "" -ScriptRoot $scriptRoot -ParameterName "-Root"
        } catch {
            $message = $_.Exception.Message
        } finally {
            Pop-Location
        }
        Assert-Result -Name "names -Root" -Condition ($message -match '\-Root') -FailureMessage ("expected the supplied parameter name in the message. Message: " + $message)
    }

    # crucible.ps1 was the last caller still answering this question for itself. It refused
    # nothing: where the other three threw, it took the working directory unvalidated, and
    # -Init is the most expensive place in the codebase to guess, because it boots a phase
    # for the repository it guessed at. The reason recorded for keeping it was the
    # framework's own fixtures, which invoke it from a directory that is not an adopter -
    # but every one of them passes -ProjectRoot, so the fallback was serving none of them.
    # Item 71.
    $results += Run-Test -Name "The entrypoint refuses an unrelated working directory" -Body {
        $unrelated = New-ProjectDir -Path (Join-Path $tempRoot "entrypoint-unrelated")
        $entrypoint = Join-Path $REPO_ROOT "powershell/crucible.ps1"

        # A child process, because the assertion is about what the entrypoint does on
        # startup - it resolves the root before it reads a single switch - and dot-sourcing
        # it here would run the orchestrator inside the test process. Invoke-ExternalCommand
        # rather than a bare call: this file runs under $ErrorActionPreference = "Stop", and
        # a native command's stderr line becomes a terminating error under it. That turns
        # every assertion below into an exception thrown before any of them is reached - the
        # test still fails, but on the child's choice of stream rather than on its output.
        Push-Location $unrelated
        try {
            $result = Invoke-ExternalCommand -Command { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File $entrypoint -Health -Quiet }
        } finally {
            Pop-Location
        }
        $exit = $result.ExitCode
        $joined = $result.Output

        Assert-Result -Name "refused rather than guessed" -Condition ($exit -ne 0) -FailureMessage ("the entrypoint accepted a working directory that is not a project. Exit code " + $exit + ". Output: " + $joined)
        Assert-Result -Name "the refusal names -ProjectRoot" -Condition ($joined -match '\-ProjectRoot') -FailureMessage ("the operator has to be told which parameter to pass. Output: " + $joined)
        # An unhandled exception exits non-zero and carries the same message, so both
        # assertions above pass against a script that merely crashed. These two are the
        # difference between a refusal and a stack trace: the "Error: " prefix exists only
        # on the reported path, and FullyQualifiedErrorId only on the thrown one. Checking
        # for a stack trace by shape is what does not work - PowerShell renders an unhandled
        # throw from a script as "At <path>:<line> char:<col>", not the "At line:N char:N"
        # of the console, and a regex written for the console form matches neither and
        # passes against both.
        Assert-Result -Name "it is reported rather than thrown" -Condition ($joined -match '(?m)^Error: ') -FailureMessage ("the refusal did not come out through this entrypoint's own error reporting. Output: " + $joined)
        Assert-Result -Name "with no exception machinery in the operator's face" -Condition ($joined -notmatch 'FullyQualifiedErrorId|CategoryInfo') -FailureMessage ("the refusal reached the operator as an unhandled exception. Output: " + $joined)
    }

    # The other half of the same change. Refusing an unrelated working directory is only
    # half the contract; the reason the entrypoint can afford to refuse is that a bundled
    # copy knows its own adopter from $PSScriptRoot and never needed the cwd. Nothing
    # covered that for this script before - every fixture passes -ProjectRoot, so handing
    # the helper the wrong -ScriptRoot would have gone unnoticed by all of them.
    $results += Run-Test -Name "A bundled entrypoint targets its own adopter from an unrelated directory" -Body {
        $adopter = Join-Path $tempRoot "bundled-adopter"
        New-Item -ItemType Directory -Path (Join-Path $adopter ".crucible") -Force | Out-Null
        Copy-Item -Path (Join-Path $REPO_ROOT "powershell") -Destination (Join-Path $adopter ".crucible/powershell") -Recurse -Force
        # A version no other config carries, so the banner below can only have come from
        # this adopter's config. "it did not refuse" alone would also pass if the script
        # resolved some other project and got on with it.
        [System.IO.File]::WriteAllText(
            (Join-Path $adopter ".crucible/config.yaml"),
            "crucible_root: `".crucible`"`ncrucible_version: `"9.9.9`"`n",
            (New-Object System.Text.UTF8Encoding($false)))
        $elsewhere = New-ProjectDir -Path (Join-Path $tempRoot "bundled-elsewhere")

        # No action switch: the root is resolved and the banner printed before the script
        # looks at what it was asked to do, and this test is about the resolution only.
        Push-Location $elsewhere
        try {
            $result = Invoke-ExternalCommand -Command { & (Get-PwshCommand) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $adopter ".crucible/powershell/crucible.ps1") }
        } finally {
            Pop-Location
        }
        $joined = $result.Output

        Assert-Result -Name "it did not refuse" -Condition ($joined -notmatch 'Pass \-ProjectRoot naming the project') -FailureMessage ("a bundled copy has an adopter to derive and must not ask for -ProjectRoot. Output: " + $joined)
        Assert-Result -Name "it read the adopter's own config" -Condition ($joined -match 'Crucible v9\.9\.9') -FailureMessage ("the banner comes from the resolved root's config, so this is where a root resolved from anywhere else shows up. Output: " + $joined)
    }

    # This resolution was hand-rolled in four places before item 60, and it had already
    # drifted: validate-backlog.ps1 guessed silently where the other three refused, and no
    # two of the three refusals said the same thing. Item 60 moved three, item 71 moved the
    # fourth, so nothing should answer this question for itself any more.
    $results += Run-Test -Name "No script derives the project root by hand any more" -Body {
        # The expectation is now empty, and an empty expectation cannot prove the scan read
        # anything. So the same scan runs twice: once over a planted file that does derive
        # the root by hand, where it has to find something, and once over powershell/, where
        # it has to find nothing. Asserting only the second half would pass identically
        # against a scan that returns an empty list unconditionally - which is precisely
        # what this test risked becoming the moment its last real subject was migrated.
        function Get-InlineRootDeriver {
            param([Parameter(Mandatory=$true)][string]$Path)
            $found = @()
            $scripts = @(Get-ChildItem -Path $Path -Filter "*.ps1" -File -Recurse |
                Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' -and $_.Name -ne "project-root.ps1" })
            foreach ($script in $scripts) {
                $text = Get-Content -LiteralPath $script.FullName -Raw -Encoding UTF8
                if ($text -match '\$derivedParent' -and $text -match '\.crucible/config\.yaml') {
                    $found += $script.Name
                }
            }
            return @($found | Sort-Object -Unique)
        }

        $planted = Join-Path $tempRoot "planted"
        New-Item -ItemType Directory -Path $planted -Force | Out-Null
        $handRolled = @(
            '$derivedParent = Split-Path -Path $PSScriptRoot -Parent',
            'if (Test-Path -LiteralPath (Join-Path $derivedParent ".crucible/config.yaml")) { $REPO_ROOT = $derivedParent }'
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $planted "hand-rolled.ps1"), $handRolled + "`n", (New-Object System.Text.UTF8Encoding($false)))

        $detected = Get-InlineRootDeriver -Path $planted
        Assert-Result -Name "the scan finds a hand-rolled copy when one is there" -Condition ($detected -contains "hand-rolled.ps1") -FailureMessage ("the scan reported nothing in a directory holding a file that derives the root by hand, so its verdict on powershell/ below means nothing. Found: " + ($detected -join ", "))

        $scripts = @(Get-ChildItem -Path (Join-Path $REPO_ROOT "powershell") -Filter "*.ps1" -File -Recurse |
            Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' -and $_.Name -ne "project-root.ps1" })
        Assert-Result -Name "scripts were found" -Condition ($scripts.Count -ge 1) -FailureMessage "no powershell scripts matched, so the scan below would report clean without reading anything"

        $inline = Get-InlineRootDeriver -Path (Join-Path $REPO_ROOT "powershell")
        Assert-Result -Name "no hand-rolled copy remains" -Condition ($inline.Count -eq 0) -FailureMessage ("these derive the project root by hand instead of calling Resolve-CrucibleProjectRoot: " + ($inline -join ", "))
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$failures = @($results | Where-Object { -not $_ }).Count
if ($failures -gt 0) {
    Write-Host ("`n{0} test(s) failed." -f $failures) -ForegroundColor Red
    exit 1
}
Write-Host "`nALL TESTS PASSED" -ForegroundColor Green
exit 0
