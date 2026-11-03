# A parameter's declaration owns the values it accepts, for every command surface. Item 365.
#
# Get-CrucibleScriptParameters reads a literal [ValidateSet(...)] (with its IgnoreCase) and an
# enum type from the target's param block. New-CrucibleCommand refuses a value outside them,
# and the documented-command binder reports one, through the shared
# Get-CrucibleCommandValueProblems. A placeholder passes; a <a|b> choice list must offer only
# accepted values; a quoted "a|b" is one value, as PowerShell reads it.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$BUNDLE_ROOT = (Resolve-Path -Path "$PSScriptRoot/../..").Path
. (Join-Path $PSScriptRoot '_harness.ps1')
. (Join-Path $BUNDLE_ROOT "powershell/lib/platform.ps1")
. (Join-Path $BUNDLE_ROOT "powershell/lib/crucible-command.ps1")
. (Join-Path $PSScriptRoot "_command-binding.ps1")

$results = @()
$FIXTURE_PARAMS = @(
    'param(',
    '    [ValidateSet("quick", "full")][string]$Mode,',
    '    [ValidateSet("Exact", IgnoreCase = $false)][string]$Case,',
    '    [System.DayOfWeek]$Day,',
    '    [ValidateSet("a", "b")][string[]]$List,',
    '    [ValidateSet("False")][switch]$Flag,',
    '    [ValidateSet([string])][string]$Computed,',
    '    [string]$Free',
    ')'
) -join "`n"

$temp = New-TestFixtureRoot -NameHint "command-values"
try {
    New-Item -ItemType Directory -Path (Join-Path $temp "powershell") | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $temp "powershell/values.ps1"), $FIXTURE_PARAMS + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $declared = Get-CrucibleScriptParameters -Script "powershell/values.ps1" -BundleRoot $temp

    function Get-BuiltLine {
        param([Parameter(Mandatory = $true)][System.Collections.Specialized.OrderedDictionary]$Parameters)
        return (New-CrucibleCommand -Script "powershell/values.ps1" -BundleRoot $temp -CrucibleRoot ".crucible" -Parameters $Parameters)
    }

    function Get-DocumentedProblems {
        param([Parameter(Mandatory = $true)][string[]]$Words)
        $invocation = [pscustomobject]@{ Kind = "code"; Words = $Words }
        return @(Get-InvocationBindingProblems -Invocation $invocation -Script "powershell/values.ps1" -Declared $declared)
    }

    $results += Run-Test -Name "The declaration's accepted values are read" -Body {
        Assert-Result -Name "ValidateSet values read" -Condition ($null -ne $declared.Mode.Accepted -and (@($declared.Mode.Accepted.Values) -join ",") -ceq "quick,full" -and -not $declared.Mode.Accepted.CaseSensitive) -FailureMessage ($declared.Mode | Out-String)
        Assert-Result -Name "IgnoreCase false read as case-sensitive" -Condition ($null -ne $declared.Case.Accepted -and $declared.Case.Accepted.CaseSensitive) -FailureMessage ($declared.Case | Out-String)
        Assert-Result -Name "enum names read" -Condition ($null -ne $declared.Day.Accepted -and @($declared.Day.Accepted.Values) -contains "Monday" -and @($declared.Day.Accepted.Values).Count -eq 7) -FailureMessage ($declared.Day | Out-String)
        Assert-Result -Name "a set that is not a literal list lists no values" -Condition ($null -eq $declared.Computed.Accepted) -FailureMessage ($declared.Computed | Out-String)
        Assert-Result -Name "a free parameter lists no values" -Condition ($null -eq $declared.Free.Accepted -and -not $declared.Free.IsSwitch) -FailureMessage ($declared.Free | Out-String)
    }

    $CASES = @(
        @{ Name = "a ValidateSet"; Key = "Mode"; Bad = "fast"; Good = "QUICK" },
        @{ Name = "a case-sensitive ValidateSet"; Key = "Case"; Bad = "exact"; Good = "Exact" },
        @{ Name = "an enum"; Key = "Day"; Bad = "Someday"; Good = "monday" },
        @{ Name = "an enum number"; Key = "Day"; Bad = "9"; Good = "1" }
    )
    foreach ($case in $CASES) {
        $results += Run-Test -Name ("MUT: " + $case.Name + " value outside the set is refused by the builder and the binder") -Body {
            $parameters = [ordered]@{}
            $parameters[$case.Key] = $case.Bad
            $line = Get-BuiltLine -Parameters $parameters
            $expected = "-" + $case.Key + " value '" + $case.Bad + "' is outside its accepted values"
            Assert-Result -Name ($case.Name + " builder refuses the value") -Condition ($line.StartsWith("# (command unavailable:") -and $line.Contains($expected)) -FailureMessage $line
            $problems = @(Get-DocumentedProblems -Words @(("-" + $case.Key), $case.Bad))
            Assert-Result -Name ($case.Name + " binder reports the value") -Condition ($problems.Count -eq 1 -and $problems[0].Contains($expected)) -FailureMessage ($problems -join "; ")
            foreach ($good in @($case.Good, "<value>", "{value}", "{{value}}")) {
                $parameters[$case.Key] = $good
                $line = Get-BuiltLine -Parameters $parameters
                Assert-Result -Name ($case.Name + " builder takes " + $good) -Condition ($line.StartsWith("& ")) -FailureMessage $line
                $problems = @(Get-DocumentedProblems -Words @(("-" + $case.Key), $good))
                Assert-Result -Name ($case.Name + " binder takes " + $good) -Condition ($problems.Count -eq 0) -FailureMessage ($problems -join "; ")
            }
        }
    }

    $results += Run-Test -Name "MUT: a choice list offers only accepted values, and a quoted one is a single value" -Body {
        $line = Get-BuiltLine -Parameters ([ordered]@{ Mode = "<quick|full>" })
        Assert-Result -Name "builder takes an accepted choice list" -Condition ($line.StartsWith("& ")) -FailureMessage $line
        $line = Get-BuiltLine -Parameters ([ordered]@{ Mode = "<quick|fast>" })
        Assert-Result -Name "builder refuses a choice outside the set" -Condition ($line.Contains("-Mode value 'fast' is outside")) -FailureMessage $line
        $line = Get-BuiltLine -Parameters ([ordered]@{ Mode = "quick|full" })
        Assert-Result -Name "builder refuses a bare choice list as one value" -Condition ($line.Contains("-Mode value 'quick|full' is outside")) -FailureMessage $line
        $problems = @(Get-DocumentedProblems -Words @("[-Mode", "<quick|fast>]"))
        Assert-Result -Name "binder reports a bracketed choice outside the set" -Condition ($problems.Count -eq 1 -and $problems[0].Contains("'fast'")) -FailureMessage ($problems -join "; ")
        $problems = @(Get-DocumentedProblems -Words @("-Mode", '"quick|full"'))
        Assert-Result -Name "binder reports a quoted choice list as one value" -Condition ($problems.Count -eq 1 -and $problems[0].Contains("'quick|full'")) -FailureMessage ($problems -join "; ")
        $problems = @(Get-DocumentedProblems -Words @("-Mode:fast"))
        Assert-Result -Name "binder reports an inline value" -Condition ($problems.Count -eq 1 -and $problems[0].Contains("'fast'")) -FailureMessage ($problems -join "; ")
        $problems = @(Get-DocumentedProblems -Words @("-Mode", '$mode', "-Free", "anything"))
        Assert-Result -Name "binder leaves a computed value to the run" -Condition ($problems.Count -eq 0) -FailureMessage ($problems -join "; ")
    }

    $results += Run-Test -Name "MUT: a quoted value is checked as PowerShell reads it" -Body {
        $problems = @(Get-DocumentedProblems -Words @("-Mode", "'fast@'"))
        Assert-Result -Name "binder reports a single-quoted value with a special character" -Condition ($problems.Count -eq 1 -and $problems[0].Contains("'fast@'")) -FailureMessage ($problems -join "; ")
        $problems = @(Get-DocumentedProblems -Words @("-Mode", "'full'", "-Case", "'Exact'"))
        Assert-Result -Name "binder takes single-quoted accepted values" -Condition ($problems.Count -eq 0) -FailureMessage ($problems -join "; ")
        $problems = @(Get-DocumentedProblems -Words @("-Mode", '"$mode"', "-Day:1"))
        Assert-Result -Name "binder leaves an expanding string to the run and takes an enum number inline" -Condition ($problems.Count -eq 0) -FailureMessage ($problems -join "; ")
    }

    $results += Run-Test -Name "MUT: a switch is checked against its own ValidateSet" -Body {
        $line = Get-BuiltLine -Parameters ([ordered]@{ Flag = $true })
        Assert-Result -Name "builder refuses a switch its set refuses" -Condition ($line.Contains("-Flag value 'True' is outside")) -FailureMessage $line
        $problems = @(Get-DocumentedProblems -Words @("-Flag"))
        Assert-Result -Name "binder reports a switch its set refuses" -Condition ($problems.Count -eq 1 -and $problems[0].Contains("-Flag value 'True'")) -FailureMessage ($problems -join "; ")
        $problems = @(Get-DocumentedProblems -Words @('-Flag:$false'))
        Assert-Result -Name "binder takes a switch set false inline" -Condition ($problems.Count -eq 0) -FailureMessage ($problems -join "; ")
    }

    $results += Run-Test -Name "MUT: every element of a list value is checked" -Body {
        $problems = @(Get-DocumentedProblems -Words @("-List", "a,c"))
        Assert-Result -Name "binder reports a list element outside the set" -Condition ($problems.Count -eq 1 -and $problems[0].Contains("-List value 'c'")) -FailureMessage ($problems -join "; ")
        $problems = @(Get-DocumentedProblems -Words @("-List", "'a','b'"))
        Assert-Result -Name "binder takes a quoted list of accepted values" -Condition ($problems.Count -eq 0) -FailureMessage ($problems -join "; ")
        $problems = @(Get-DocumentedProblems -Words @("-Mode", "quick,full"))
        Assert-Result -Name "binder keeps a scalar value whole" -Condition ($problems.Count -eq 1 -and $problems[0].Contains("'quick,full'")) -FailureMessage ($problems -join "; ")
        $line = New-CrucibleCommand -Script "powershell/values.ps1" -BundleRoot $temp -CrucibleRoot ".crucible" -Parameters ([ordered]@{ List = @("a", "c") })
        Assert-Result -Name "builder refuses a list element outside the set" -Condition ($line.Contains("-List value 'c' is outside")) -FailureMessage $line
        $line = New-CrucibleCommand -Script "powershell/values.ps1" -BundleRoot $temp -CrucibleRoot ".crucible" -Parameters ([ordered]@{ List = @("a", "B") })
        Assert-Result -Name "builder takes a list of accepted values" -Condition ($line.StartsWith("& ")) -FailureMessage $line
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($temp)
    $runRoot = [IO.Path]::GetFullPath((Get-TestRunRoot)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($runRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture escaped the test run root: $resolved" }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

Write-TestFileSummary -Results $results
