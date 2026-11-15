# Shared object-preserving forwarding for parameterless entrypoints. The caller protects
# helper binding and loading too, so neither can throw past the entrypoint's refusal.
param([string]$TargetScript, [object[]]$Arguments, [string]$Entrypoint)

$ErrorActionPreference = 'Stop'
try {
    # Re-splatting $Arguments drops the value of a switch passed as -Name:$value, from a hashtable
    # splat or a pwsh -File colon argument, and binds that value positionally. Those pairs are
    # passed by name; every other argument is forwarded unchanged, so arrays stay objects.
    # $Arguments cannot tell an explicit -Name:value from a splatted one, so a repeated name is
    # refused rather than resolved; the binder would refuse it too unless one came from a splat.
    # Names are compared after resolving an alias or a unique prefix against the target's
    # param() block and the common parameters its CmdletBinding adds. Like the binder, a
    # prefix resolves among the declared parameters before the common ones.
    $coreAst = [System.Management.Automation.Language.Parser]::ParseFile($TargetScript, [ref]$null, [ref]$null)
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
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $argument = $Arguments[$i]
        $parameterName = if ($null -ne $argument) { $argument.PSObject.Properties['<CommandParameterName>'] } else { $null }
        if ($null -ne $parameterName) {
            $name = Resolve-CoreParameterName ([string]$parameterName.Value)
            if (-not $seenNames.Add($name)) {
                [Console]::Error.WriteLine("${Entrypoint}: Parameter '$name' is specified more than once. Pass each parameter once, including when one value comes from a splatted hashtable.")
                exit 1
            }
        }
        if ($null -ne $parameterName -and $i + 1 -lt $Arguments.Count -and (([string]$argument).EndsWith(':') -or $Arguments[$i + 1] -is [bool])) {
            $namedArguments[[string]$parameterName.Value] = $Arguments[$i + 1]
            $i++
            continue
        }
        $forwardedArguments.Add([psobject]$argument)
    }
    $positionalArguments = $forwardedArguments.ToArray()
    $global:LASTEXITCODE = 0
    & $TargetScript @namedArguments @positionalArguments
    if (-not $? -and $LASTEXITCODE -eq 0) { exit 1 }
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine("${Entrypoint}: " + $_.Exception.Message)
    exit 1
}
