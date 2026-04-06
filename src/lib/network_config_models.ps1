function ConvertTo-NormalizedCollection {
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return ,@()
    }

    if ($Value -is [string]) {
        return ,@([string] $Value)
    }

    return ,@($Value)
}

function ConvertTo-NormalizedMetadata {
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return @{}
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $metadata = @{}
        foreach ($key in $Value.Keys) {
            $metadata[$key] = $Value[$key]
        }
        return $metadata
    }

    $propertyBag = @{}
    foreach ($property in ($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty') })) {
        $propertyBag[$property.Name] = $property.Value
    }

    if ($propertyBag.Count -gt 0) {
        return $propertyBag
    }

    return @{ value = $Value }
}

function New-NetworkConfigurationPlan {
    param(
        [string] $Source = 'server_derived',
        [string] $AssignedIp,
        [Nullable[int]] $PrefixLength,
        [string] $Gateway,
        [string[]] $DnsServers,
        [string] $DnsTargetAdapter,
        [Nullable[int]] $DnsTargetInterfaceIndex,
        [string[]] $DnsCandidateServers,
        [string] $DnsApplyStrategy = 'adapter_scoped',
        [psobject] $DnsPreexistingState,
        [string[]] $DnsOwnedServers,
        [Nullable[int]] $RouteTargetInterfaceIndex,
        [psobject] $RoutePreexistingState,
        [object[]] $RouteCandidateEntries,
        [object[]] $RouteOwnedEntries,
        [string] $RouteApplyStrategy = 'split_routes_only',
        [object[]] $SplitIncludeRoutes,
        [object[]] $SplitExcludeRoutes,
        [string[]] $SplitIncludeDomains,
        [string[]] $InterfaceHints,
        [object] $Metadata
    )

    return [PSCustomObject]@{
        Source = $Source
        AssignedIp = $AssignedIp
        PrefixLength = $PrefixLength
        Gateway = $Gateway
        DnsServers = ConvertTo-NormalizedCollection -Value $DnsServers
        DnsTargetAdapter = $DnsTargetAdapter
        DnsTargetInterfaceIndex = $DnsTargetInterfaceIndex
        DnsCandidateServers = ConvertTo-NormalizedCollection -Value $DnsCandidateServers
        DnsApplyStrategy = $DnsApplyStrategy
        DnsPreexistingState = $DnsPreexistingState
        DnsOwnedServers = ConvertTo-NormalizedCollection -Value $DnsOwnedServers
        RouteTargetInterfaceIndex = $RouteTargetInterfaceIndex
        RoutePreexistingState = $RoutePreexistingState
        RouteCandidateEntries = ConvertTo-NormalizedCollection -Value $RouteCandidateEntries
        RouteOwnedEntries = ConvertTo-NormalizedCollection -Value $RouteOwnedEntries
        RouteApplyStrategy = $RouteApplyStrategy
        SplitIncludeRoutes = ConvertTo-NormalizedCollection -Value $SplitIncludeRoutes
        SplitExcludeRoutes = ConvertTo-NormalizedCollection -Value $SplitExcludeRoutes
        SplitIncludeDomains = ConvertTo-NormalizedCollection -Value $SplitIncludeDomains
        InterfaceHints = ConvertTo-NormalizedCollection -Value $InterfaceHints
        Metadata = ConvertTo-NormalizedMetadata -Value $Metadata
    }
}

function New-NetworkConfigurationRoute {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Destination,

        [Parameter(Mandatory = $true)]
        [int] $PrefixLength,

        [string] $Netmask,

        [string] $RouteType = 'include',

        [string] $RawEvidence,

        [string] $NextHop,

        [Nullable[int]] $InterfaceIndex,

        [Nullable[int]] $RouteMetric,

        [string] $DestinationPrefix,

        [string] $OwnershipSource
    )

    return [PSCustomObject]@{
        Destination = $Destination
        PrefixLength = $PrefixLength
        Netmask = $Netmask
        RouteType = $RouteType
        RawEvidence = $RawEvidence
        NextHop = $NextHop
        InterfaceIndex = $InterfaceIndex
        RouteMetric = $RouteMetric
        DestinationPrefix = if ($DestinationPrefix) { $DestinationPrefix } else { '{0}/{1}' -f $Destination, $PrefixLength }
        OwnershipSource = $OwnershipSource
    }
}

function New-NetworkConfigurationConflict {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Kind,

        [Parameter(Mandatory = $true)]
        [string] $Scope,

        [Parameter(Mandatory = $true)]
        [string] $Summary,

        [string] $Severity = 'warning'
    )

    return [PSCustomObject]@{
        Kind = $Kind
        Scope = $Scope
        Summary = $Summary
        Severity = $Severity
    }
}

function New-NetworkConfigurationResult {
    param(
        [string] $Status = 'not_applied',
        [Alias('Error')]
        [string] $C_Error,
        [string] $Source = 'server_derived',
        [psobject] $Plan,
        [object[]] $Conflicts,
        [AllowNull()] [Nullable[datetime]] $CollectedAt,
        [object[]] $OwnedRoutes,
        [object[]] $OwnedDnsServers
    )

    return [PSCustomObject]@{
        Status = $Status
        Error = $C_Error
        Source = $Source
        Plan = $Plan
        Conflicts = ConvertTo-NormalizedCollection -Value $Conflicts
        CollectedAt = $CollectedAt
        OwnedRoutes = ConvertTo-NormalizedCollection -Value $OwnedRoutes
        OwnedDnsServers = ConvertTo-NormalizedCollection -Value $OwnedDnsServers
    }
}
