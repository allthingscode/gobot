# Writes a validated handoff. The parameters and body are in lib/new-handoff-core.ps1;
# this entrypoint only binds them inside a protected call.
#
# Deliberately declares no param() block. PowerShell binds a script's parameters before
# its body or trap runs, so a missing mandatory argument, an invalid -Source or a failed
# type conversion would throw to an in-process caller, whose catch could turn the refusal
# into a pass (I11, item 375). Here binding happens inside the call below, and any failure
# becomes a stderr diagnostic and exit 1. The core's own refusals keep their exit codes.
# Follows the factory.ps1 forwarder.

$ErrorActionPreference = 'Stop'
$coreScript = Join-Path $PSScriptRoot "lib/new-handoff-core.ps1"
if (-not (Test-Path -LiteralPath $coreScript)) {
    [Console]::Error.WriteLine("new-handoff.ps1 needs lib/new-handoff-core.ps1, which is missing at $coreScript. Your Crucible bundle is incomplete; see docs/updating.md.")
    exit 1
}

# Re-splatting $args drops the value of a switch passed as -Name:$value, from a hashtable
# splat or a pwsh -File colon argument, and binds that value positionally. Those pairs are
# passed by name; every other argument is forwarded unchanged, so arrays stay objects.
# $args cannot tell an explicit -Name:value from a splatted one, so a repeated name is
# refused rather than resolved; the binder would refuse it too unless one came from a splat.
# Names are compared after resolving an alias or a unique prefix against the core's
# param() block and the common parameters its CmdletBinding adds. Like the binder, a
# prefix resolves among the declared parameters before the common ones.
$coreAst = [System.Management.Automation.Language.Parser]::ParseFile($coreScript, [ref]$null, [ref]$null)
$parameterAliases = @{}
$declaredNames = [System.Collections.Generic.List[string]]::new()
$commonNames = [System.Collections.Generic.List[string]]::new()
if ($null -ne $coreAst.ParamBlock) {
    foreach ($parameter in $coreAst.ParamBlock.Parameters) {
        $declaredNames.Add($parameter.Name.VariablePath.UserPath)
        foreach ($attribute in $parameter.Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' }) {
            foreach ($alias in $attribute.PositionalArguments) { $parameterAliases[[string]$alias.SafeGetValue()] = $parameter.Name.VariablePath.UserPath }
        }
    }
}
foreach ($common in [System.Management.Automation.Internal.CommonParameters].GetProperties()) {
    $commonNames.Add($common.Name)
    foreach ($alias in $common.GetCustomAttributes([Alias], $false).AliasNames) { $parameterAliases[$alias] = $common.Name }
}
function Resolve-CoreParameterName([string]$Name) {
    if ($parameterAliases.ContainsKey($Name)) { return $parameterAliases[$Name] }
    foreach ($names in @(, $declaredNames) + @(, $commonNames)) {
        $exact = @($names | Where-Object { $_ -eq $Name })
        if ($exact.Count -eq 1) { return $exact[0] }
    }
    foreach ($names in @(, $declaredNames) + @(, $commonNames)) {
        $prefixed = @($names | Where-Object { $_ -like ([WildcardPattern]::Escape($Name) + '*') })
        if ($prefixed.Count -eq 1) { return $prefixed[0] }
        if ($prefixed.Count -gt 1) { return $Name }
    }
    return $Name
}
$seenNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$namedArguments = @{}
$forwardedArguments = [System.Collections.Generic.List[psobject]]::new()
for ($i = 0; $i -lt $args.Count; $i++) {
    $argument = $args[$i]
    $parameterName = if ($null -ne $argument) { $argument.PSObject.Properties['<CommandParameterName>'] } else { $null }
    if ($null -ne $parameterName) {
        $name = Resolve-CoreParameterName ([string]$parameterName.Value)
        if (-not $seenNames.Add($name)) {
            [Console]::Error.WriteLine("new-handoff.ps1: Parameter '$name' is specified more than once. Pass each parameter once, including when one value comes from a splatted hashtable.")
            exit 1
        }
    }
    if ($null -ne $parameterName -and $i + 1 -lt $args.Count -and (([string]$argument).EndsWith(':') -or $args[$i + 1] -is [bool])) {
        $namedArguments[[string]$parameterName.Value] = $args[$i + 1]
        $i++
        continue
    }
    $forwardedArguments.Add([psobject]$argument)
}
$positionalArguments = $forwardedArguments.ToArray()

try {
    $global:LASTEXITCODE = 0
    & $coreScript @namedArguments @positionalArguments
    if (-not $? -and $LASTEXITCODE -eq 0) { exit 1 }
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine("new-handoff.ps1: " + $_.Exception.Message)
    exit 1
}
