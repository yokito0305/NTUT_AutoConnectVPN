function ConvertTo-Ipv4PrefixLength {
    param(
        [string] $Netmask
    )

    if ([string]::IsNullOrWhiteSpace($Netmask)) {
        return $null
    }

    if ($Netmask -match '^\d+$') {
        $prefixLength = 0
        if (-not [int]::TryParse($Netmask, [ref] $prefixLength)) {
            return $null
        }

        if ($prefixLength -lt 0 -or $prefixLength -gt 32) {
            return $null
        }

        return $prefixLength
    }

    $octets = $Netmask -split '\.'
    if ($octets.Count -ne 4) {
        return $null
    }

    $binary = New-Object System.Collections.Generic.List[string]
    $isValidNetmask = $true

    foreach ($octet in $octets) {
        $value = 0
        if (-not [int]::TryParse($octet, [ref] $value)) {
            $isValidNetmask = $false
            break
        }

        if ($value -lt 0 -or $value -gt 255) {
            $isValidNetmask = $false
            break
        }

        $binary.Add([Convert]::ToString($value, 2).PadLeft(8, '0')) | Out-Null
    }

    if (-not $isValidNetmask) {
        return $null
    }

    $bits = (@($binary) -join '')
    if ($bits -notmatch '^1*0*$') {
        return $null
    }

    return (($bits -replace '0', '').Length)
}

function Add-RawEvidenceLine {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Evidence,

        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    if (-not $Evidence.ContainsKey('RawEvidence')) {
        $Evidence['RawEvidence'] = New-Object System.Collections.ArrayList
    }

    if ($Evidence.RawEvidence.Count -ge 20) {
        $Evidence.RawEvidence.RemoveAt(0)
    }

    [void] $Evidence.RawEvidence.Add($Line)
}

function Remove-OpenConnectTimestampPrefix {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    if ($Line -match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]\s*(.+)$') {
        return $Matches[1]
    }

    return $Line
}

function New-NetworkConfigurationEvidence {
    return @{
        AssignedIp = $null
        PrefixLength = $null
        Gateway = $null
        DnsServers = New-Object System.Collections.ArrayList
        SplitIncludeRoutes = New-Object System.Collections.ArrayList
        SplitExcludeRoutes = New-Object System.Collections.ArrayList
        SplitIncludeDomains = New-Object System.Collections.ArrayList
        InterfaceHints = New-Object System.Collections.ArrayList
        RawEvidence = New-Object System.Collections.ArrayList
        PendingSplitIncludeDomain = $false
    }
}

function Update-NetworkConfigurationEvidenceFromLine {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Evidence,

        [Parameter(Mandatory = $true)]
        [string] $Line
    )

    $changed = $false
    $normalizedLine = Remove-OpenConnectTimestampPrefix -Line $Line

    if ($Evidence.PendingSplitIncludeDomain) {
        $Evidence.PendingSplitIncludeDomain = $false
        if (-not ($normalizedLine -match '^\[') -and (Add-UniqueListItem -Collection $Evidence.SplitIncludeDomains -Value $normalizedLine.Trim())) {
            Add-RawEvidenceLine -Evidence $Evidence -Line $Line
            $changed = $true
        }
    }

    if ($normalizedLine -match '^Configured as ([0-9\.]+)(?:,\s*netmask ([0-9\.]+))?') {
        if ($Evidence.AssignedIp -ne $Matches[1]) {
            $Evidence.AssignedIp = $Matches[1]
            $changed = $true
        }

        if ($Matches[2]) {
            $prefix = ConvertTo-Ipv4PrefixLength -Netmask $Matches[2]
            if ($Evidence.PrefixLength -ne $prefix) {
                $Evidence.PrefixLength = $prefix
                $changed = $true
            }
        }

        Add-RawEvidenceLine -Evidence $Evidence -Line $Line
        return $changed
    }

    if ($normalizedLine -match '^Public VPN Gateway Address:\s*(.+)$') {
        $gateway = $Matches[1].Trim()
        if ($Evidence.Gateway -ne $gateway) {
            $Evidence.Gateway = $gateway
            $changed = $true
        }
        Add-RawEvidenceLine -Evidence $Evidence -Line $Line
        return $changed
    }

    if ($normalizedLine -match '^Connected to HTTPS on ([^ ]+) ') {
        $gateway = $Matches[1].Trim()
        if ($Evidence.Gateway -ne $gateway) {
            $Evidence.Gateway = $gateway
            $changed = $true
        }
        Add-RawEvidenceLine -Evidence $Evidence -Line $Line
        return $changed
    }

    if ($normalizedLine -match '^Received DNS server (.+)$') {
        if (Add-UniqueListItem -Collection $Evidence.DnsServers -Value $Matches[1].Trim()) {
            Add-RawEvidenceLine -Evidence $Evidence -Line $Line
            return $true
        }
    }

    if ($normalizedLine -match '^Received split include route ([0-9\.]+)/([0-9\.]+|\d+)$') {
        $route = New-NetworkConfigurationRoute -Destination $Matches[1] -PrefixLength (ConvertTo-Ipv4PrefixLength -Netmask $Matches[2]) -Netmask $Matches[2] -RouteType 'include' -RawEvidence $Line
        if (Add-UniqueRoute -Collection $Evidence.SplitIncludeRoutes -Route $route) {
            Add-RawEvidenceLine -Evidence $Evidence -Line $Line
            return $true
        }
    }

    if ($normalizedLine -match '^Received split exclude route ([0-9\.]+)/([0-9\.]+|\d+)$') {
        $route = New-NetworkConfigurationRoute -Destination $Matches[1] -PrefixLength (ConvertTo-Ipv4PrefixLength -Netmask $Matches[2]) -Netmask $Matches[2] -RouteType 'exclude' -RawEvidence $Line
        if (Add-UniqueRoute -Collection $Evidence.SplitExcludeRoutes -Route $route) {
            Add-RawEvidenceLine -Evidence $Evidence -Line $Line
            return $true
        }
    }

    if ($normalizedLine -match 'include-split-tunneling-domain.*?:\s*(.+)$') {
        if (Add-UniqueListItem -Collection $Evidence.SplitIncludeDomains -Value $Matches[1].Trim()) {
            Add-RawEvidenceLine -Evidence $Evidence -Line $Line
            return $true
        }
    }

    if ($normalizedLine -match 'include-split-tunneling-domain.*?:\s*$') {
        $Evidence.PendingSplitIncludeDomain = $true
        Add-RawEvidenceLine -Evidence $Evidence -Line $Line
        return $true
    }

    if ($normalizedLine -match '^Opened tun device (.+)$') {
        if (Add-UniqueListItem -Collection $Evidence.InterfaceHints -Value $Matches[1].Trim()) {
            Add-RawEvidenceLine -Evidence $Evidence -Line $Line
            return $true
        }
    }

    if ($normalizedLine -match '^Using TAP-Windows device (.+), index (\d+)$') {
        $hint = '{0} (index {1})' -f $Matches[1].Trim(), $Matches[2]
        if (Add-UniqueListItem -Collection $Evidence.InterfaceHints -Value $hint) {
            Add-RawEvidenceLine -Evidence $Evidence -Line $Line
            return $true
        }
    }

    if ($normalizedLine -match '^Set up .*? as (.+)$') {
        if (Add-UniqueListItem -Collection $Evidence.InterfaceHints -Value $Matches[1].Trim()) {
            Add-RawEvidenceLine -Evidence $Evidence -Line $Line
            return $true
        }
    }

    return $changed
}

function Add-UniqueListItem {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList] $Collection,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    if ($Collection -contains $Value) {
        return $false
    }

    [void] $Collection.Add($Value)
    return $true
}

function Add-UniqueRoute {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.ArrayList] $Collection,

        [Parameter(Mandatory = $true)]
        [psobject] $Route
    )

    foreach ($existing in $Collection) {
        if ($existing.Destination -eq $Route.Destination -and $existing.PrefixLength -eq $Route.PrefixLength -and $existing.RouteType -eq $Route.RouteType) {
            return $false
        }
    }

    [void] $Collection.Add($Route)
    return $true
}

function New-NetworkConfigurationContext {
    param(
        [string] $RootDir,
        [string] $LogPath,
        [string] $StatePath
    )

    return [PSCustomObject]@{
        RootDir = $RootDir
        LogPath = $LogPath
        StatePath = $StatePath
    }
}

function Get-OpenConnectHttpBodyDocuments {
    param(
        [string] $BodyDumpFile
    )

    if ([string]::IsNullOrWhiteSpace($BodyDumpFile) -or -not (Test-Path $BodyDumpFile)) {
        return @()
    }

    $documents = New-Object System.Collections.ArrayList
    $currentDocument = $null
    $currentLines = New-Object System.Collections.ArrayList

    foreach ($line in (Get-Content -Path $BodyDumpFile -ErrorAction SilentlyContinue)) {
        if ($line -match '^=== BEGIN HTTP XML BODY ([^ ]+) \[([^\]]+)\] \((.+)\) ===$') {
            $currentDocument = [PSCustomObject]@{
                RequestPath = $Matches[1]
                DocumentType = $Matches[2]
                CapturedAt = $Matches[3]
            }
            $currentLines = New-Object System.Collections.ArrayList
            continue
        }

        if ($line -match '^=== END HTTP XML BODY ([^ ]+) ===$') {
            if ($currentDocument -and $currentDocument.RequestPath -eq $Matches[1]) {
                [void] $documents.Add([PSCustomObject]@{
                    RequestPath = $currentDocument.RequestPath
                    DocumentType = $currentDocument.DocumentType
                    CapturedAt = $currentDocument.CapturedAt
                    XmlText = ((@($currentLines) -join [Environment]::NewLine).Trim())
                })
            }

            $currentDocument = $null
            $currentLines = New-Object System.Collections.ArrayList
            continue
        }

        if ($currentDocument) {
            [void] $currentLines.Add($line)
        }
    }

    return @($documents)
}

function Get-OpenConnectLatestHttpBodyDocumentMap {
    param(
        [string] $BodyDumpFile
    )

    $documentsByType = @{}
    foreach ($document in @(Get-OpenConnectHttpBodyDocuments -BodyDumpFile $BodyDumpFile)) {
        if ([string]::IsNullOrWhiteSpace($document.DocumentType)) {
            continue
        }

        $documentsByType[$document.DocumentType] = $document
    }

    return $documentsByType
}

function Read-JsonFileSafely {
    param(
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $null
    }

    try {
        return (Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Write-JsonFileUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [object] $Payload
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, ($Payload | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-XmlDocumentSafely {
    param(
        [string] $XmlText
    )

    if ([string]::IsNullOrWhiteSpace($XmlText)) {
        return $null
    }

    try {
        $document = New-Object System.Xml.XmlDocument
        $document.LoadXml($XmlText)
        return $document
    } catch {
        return $null
    }
}

function New-XmlConfigDocumentRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string] $DocumentType,

        [Parameter(Mandatory = $true)]
        [string] $RequestPath,

        [Parameter(Mandatory = $true)]
        [string] $XmlText,

        [string] $SourcePath
    )

    return [PSCustomObject]@{
        DocumentType = $DocumentType
        RequestPath = $RequestPath
        XmlText = $XmlText
        SourcePath = $SourcePath
    }
}

function Get-XmlNodeInnerText {
    param(
        [System.Xml.XmlNode] $ParentNode,
        [string] $ChildName
    )

    if ($null -eq $ParentNode -or [string]::IsNullOrWhiteSpace($ChildName)) {
        return $null
    }

    $node = $ParentNode.SelectSingleNode($ChildName)
    if ($null -eq $node) {
        return $null
    }

    return $node.InnerText.Trim()
}

function Get-XmlMemberValues {
    param(
        [System.Xml.XmlNode] $ParentNode,
        [string] $ListNodeName
    )

    $values = New-Object System.Collections.ArrayList
    if ($null -eq $ParentNode -or [string]::IsNullOrWhiteSpace($ListNodeName)) {
        return @($values)
    }

    $listNode = $ParentNode.SelectSingleNode($ListNodeName)
    if ($null -eq $listNode) {
        return @($values)
    }

    foreach ($member in @($listNode.SelectNodes('member'))) {
        $value = $member.InnerText.Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            [void] $values.Add($value)
        }
    }

    return @($values)
}

function Add-XmlEvidenceTag {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Evidence,

        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    if (-not $Evidence.Metadata.Contains('xml_evidence')) {
        $Evidence.Metadata['xml_evidence'] = New-Object System.Collections.ArrayList
    }

    if (-not ($Evidence.Metadata.xml_evidence -contains $Value)) {
        [void] $Evidence.Metadata.xml_evidence.Add($Value)
    }
}

function Add-MissingFieldTag {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Evidence,

        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    if (-not $Evidence.Metadata.Contains('missing_fields')) {
        $Evidence.Metadata['missing_fields'] = New-Object System.Collections.ArrayList
    }

    if (-not ($Evidence.Metadata.missing_fields -contains $Value)) {
        [void] $Evidence.Metadata.missing_fields.Add($Value)
    }
}

function ConvertTo-NetworkConfigurationRouteFromCidr {
    param(
        [string] $Value,
        [string] $RouteType,
        [string] $RawEvidence
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    if ($Value -notmatch '^([^/]+)/([^/]+)$') {
        return $null
    }

    $destination = $Matches[1].Trim()
    $maskOrPrefix = $Matches[2].Trim()
    $prefixLength = ConvertTo-Ipv4PrefixLength -Netmask $maskOrPrefix
    if ($null -eq $prefixLength) {
        return $null
    }

    return (New-NetworkConfigurationRoute -Destination $destination -PrefixLength $prefixLength -Netmask $maskOrPrefix -RouteType $RouteType -RawEvidence $RawEvidence)
}

function Get-NetworkConfigurationEvidenceFromXmlDocuments {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Documents
    )

    if (-not @($Documents)) {
        return $null
    }

    $documentMap = @{}
    foreach ($document in @($Documents)) {
        if ($document -and -not [string]::IsNullOrWhiteSpace($document.DocumentType)) {
            $documentMap[[string] $document.DocumentType] = $document
        }
    }

    if ($documentMap.Count -eq 0) {
        return $null
    }

    $evidence = [ordered]@{
        AssignedIp = $null
        PrefixLength = $null
        Gateway = $null
        DnsServers = New-Object System.Collections.ArrayList
        SplitIncludeRoutes = New-Object System.Collections.ArrayList
        SplitExcludeRoutes = New-Object System.Collections.ArrayList
        SplitIncludeDomains = New-Object System.Collections.ArrayList
        Metadata = [ordered]@{
            xml_documents = @($documentMap.Keys | Sort-Object)
            xml_evidence = New-Object System.Collections.ArrayList
            missing_fields = New-Object System.Collections.ArrayList
        }
    }

    $gatewayDocument = $null
    if ($documentMap.ContainsKey('ssl_vpn_getconfig')) {
        $gatewayDocument = $documentMap['ssl_vpn_getconfig']
    } elseif ($documentMap.ContainsKey('global_protect_getconfig')) {
        $gatewayDocument = $documentMap['global_protect_getconfig']
    }

    if ($gatewayDocument) {
        $xmlDocument = ConvertTo-XmlDocumentSafely -XmlText $gatewayDocument.XmlText
        if ($xmlDocument -and $xmlDocument.DocumentElement) {
            $rootNode = $xmlDocument.DocumentElement
            $evidence.Metadata['xml_primary_document'] = $gatewayDocument.DocumentType
            $evidence.Metadata['xml_primary_request_path'] = $gatewayDocument.RequestPath
            $evidence.Metadata['xml_primary_root'] = $rootNode.Name
            if ($gatewayDocument.SourcePath) {
                $evidence.Metadata['xml_primary_source_path'] = $gatewayDocument.SourcePath
            }

            $assignedIp = Get-XmlNodeInnerText -ParentNode $rootNode -ChildName 'ip-address'
            if (-not [string]::IsNullOrWhiteSpace($assignedIp)) {
                $evidence.AssignedIp = $assignedIp
                Add-XmlEvidenceTag -Evidence $evidence -Value 'ssl_vpn_getconfig.ip-address'
            } else {
                Add-MissingFieldTag -Evidence $evidence -Value 'assigned_ip'
            }

            $gateway = Get-XmlNodeInnerText -ParentNode $rootNode -ChildName 'gw-address'
            if (-not [string]::IsNullOrWhiteSpace($gateway)) {
                $evidence.Gateway = $gateway
                Add-XmlEvidenceTag -Evidence $evidence -Value 'ssl_vpn_getconfig.gw-address'
            } else {
                Add-MissingFieldTag -Evidence $evidence -Value 'gateway'
            }

            $netmask = Get-XmlNodeInnerText -ParentNode $rootNode -ChildName 'netmask'
            $prefixLength = ConvertTo-Ipv4PrefixLength -Netmask $netmask
            if ($null -ne $prefixLength) {
                $evidence.PrefixLength = $prefixLength
                $evidence.Metadata['netmask'] = $netmask
                Add-XmlEvidenceTag -Evidence $evidence -Value 'ssl_vpn_getconfig.netmask'
            } else {
                Add-MissingFieldTag -Evidence $evidence -Value 'prefix_length'
            }

            foreach ($dnsServer in @(Get-XmlMemberValues -ParentNode $rootNode -ListNodeName 'dns')) {
                if (Add-UniqueListItem -Collection $evidence.DnsServers -Value $dnsServer) {
                    Add-XmlEvidenceTag -Evidence $evidence -Value 'ssl_vpn_getconfig.dns.member'
                }
            }
            if (@($evidence.DnsServers).Count -eq 0) {
                Add-MissingFieldTag -Evidence $evidence -Value 'dns_servers'
            }

            foreach ($routeValue in @(Get-XmlMemberValues -ParentNode $rootNode -ListNodeName 'access-routes')) {
                $route = ConvertTo-NetworkConfigurationRouteFromCidr -Value $routeValue -RouteType 'include' -RawEvidence ('xml:{0}' -f $routeValue)
                if ($route -and (Add-UniqueRoute -Collection $evidence.SplitIncludeRoutes -Route $route)) {
                    Add-XmlEvidenceTag -Evidence $evidence -Value 'ssl_vpn_getconfig.access-routes.member'
                }
            }
            if (@($evidence.SplitIncludeRoutes).Count -eq 0) {
                Add-MissingFieldTag -Evidence $evidence -Value 'split_include_routes'
            }

            foreach ($routeValue in @(Get-XmlMemberValues -ParentNode $rootNode -ListNodeName 'exclude-access-routes')) {
                $route = ConvertTo-NetworkConfigurationRouteFromCidr -Value $routeValue -RouteType 'exclude' -RawEvidence ('xml:{0}' -f $routeValue)
                if ($route -and (Add-UniqueRoute -Collection $evidence.SplitExcludeRoutes -Route $route)) {
                    Add-XmlEvidenceTag -Evidence $evidence -Value 'ssl_vpn_getconfig.exclude-access-routes.member'
                }
            }

            foreach ($domain in @(Get-XmlMemberValues -ParentNode $rootNode -ListNodeName 'include-split-tunneling-domain')) {
                if (Add-UniqueListItem -Collection $evidence.SplitIncludeDomains -Value $domain) {
                    Add-XmlEvidenceTag -Evidence $evidence -Value 'ssl_vpn_getconfig.include-split-tunneling-domain.member'
                }
            }

            $defaultGateway = Get-XmlNodeInnerText -ParentNode $rootNode -ChildName 'default-gateway'
            if (-not [string]::IsNullOrWhiteSpace($defaultGateway)) {
                $evidence.Metadata['default_gateway'] = $defaultGateway
                Add-XmlEvidenceTag -Evidence $evidence -Value 'ssl_vpn_getconfig.default-gateway'
            }

            foreach ($fieldName in @('portal', 'user', 'need-tunnel', 'lifetime', 'timeout', 'disconnect-on-idle', 'mtu', 'dns-suffix', 'no-direct-access-to-local-network')) {
                $fieldValue = Get-XmlNodeInnerText -ParentNode $rootNode -ChildName $fieldName
                if (-not [string]::IsNullOrWhiteSpace($fieldValue)) {
                    $metadataKey = $fieldName.Replace('-', '_')
                    $evidence.Metadata[$metadataKey] = $fieldValue
                    Add-XmlEvidenceTag -Evidence $evidence -Value ('ssl_vpn_getconfig.{0}' -f $fieldName)
                }
            }

            $winsValues = @(Get-XmlMemberValues -ParentNode $rootNode -ListNodeName 'wins')
            if ($winsValues.Count -gt 0) {
                $evidence.Metadata['wins_servers'] = $winsValues
                Add-XmlEvidenceTag -Evidence $evidence -Value 'ssl_vpn_getconfig.wins.member'
            }

            $ipsecNode = $rootNode.SelectSingleNode('ipsec')
            if ($ipsecNode) {
                foreach ($fieldName in @('udp-port', 'ipsec-mode', 'enc-algo', 'hmac-algo')) {
                    $fieldValue = Get-XmlNodeInnerText -ParentNode $ipsecNode -ChildName $fieldName
                    if (-not [string]::IsNullOrWhiteSpace($fieldValue)) {
                        $metadataKey = ('ipsec_{0}' -f $fieldName.Replace('-', '_'))
                        $evidence.Metadata[$metadataKey] = $fieldValue
                        Add-XmlEvidenceTag -Evidence $evidence -Value ('ssl_vpn_getconfig.ipsec.{0}' -f $fieldName)
                    }
                }
            }
        }
    }

    $preloginDocument = if ($documentMap.ContainsKey('global_protect_prelogin')) { $documentMap['global_protect_prelogin'] } else { $null }
    if ($preloginDocument) {
        $preloginXml = ConvertTo-XmlDocumentSafely -XmlText $preloginDocument.XmlText
        if ($preloginXml -and $preloginXml.DocumentElement) {
            $serverIp = Get-XmlNodeInnerText -ParentNode $preloginXml.DocumentElement -ChildName 'server-ip'
            if (-not [string]::IsNullOrWhiteSpace($serverIp)) {
                $evidence.Metadata['prelogin_server_ip'] = $serverIp
                Add-XmlEvidenceTag -Evidence $evidence -Value 'global_protect_prelogin.server-ip'
            }
        }
    }

    $evidence.Metadata.missing_fields = @($evidence.Metadata.missing_fields | Sort-Object -Unique)
    $evidence.Metadata.xml_evidence = @($evidence.Metadata.xml_evidence | Sort-Object -Unique)
    return [PSCustomObject] $evidence
}

function Get-OpenConnectXmlNetworkConfigurationEvidence {
    param(
        [string] $BodyDumpFile
    )

    $documentMap = Get-OpenConnectLatestHttpBodyDocumentMap -BodyDumpFile $BodyDumpFile
    if ($documentMap.Count -eq 0) {
        return $null
    }

    return (Get-NetworkConfigurationEvidenceFromXmlDocuments -Documents @($documentMap.Values))
}

function Merge-NetworkConfigurationPlanWithXmlEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $BasePlan,

        [psobject] $XmlEvidence
    )

    if ($null -eq $XmlEvidence) {
        return $BasePlan
    }

    $metadata = @{}
    if ($BasePlan.Metadata) {
        foreach ($key in $BasePlan.Metadata.Keys) {
            $metadata[$key] = $BasePlan.Metadata[$key]
        }
    }

    foreach ($key in $XmlEvidence.Metadata.Keys) {
        $metadata[$key] = $XmlEvidence.Metadata[$key]
    }

    return (New-NetworkConfigurationPlan `
        -Source $BasePlan.Source `
        -AssignedIp $(if (-not [string]::IsNullOrWhiteSpace($XmlEvidence.AssignedIp)) { $XmlEvidence.AssignedIp } else { $BasePlan.AssignedIp }) `
        -PrefixLength $(if ($null -ne $XmlEvidence.PrefixLength) { $XmlEvidence.PrefixLength } else { $BasePlan.PrefixLength }) `
        -Gateway $(if (-not [string]::IsNullOrWhiteSpace($XmlEvidence.Gateway)) { $XmlEvidence.Gateway } else { $BasePlan.Gateway }) `
        -DnsServers $(if (@($XmlEvidence.DnsServers).Count -gt 0) { @($XmlEvidence.DnsServers) } else { @($BasePlan.DnsServers) }) `
        -DnsTargetAdapter $BasePlan.DnsTargetAdapter `
        -DnsTargetInterfaceIndex $BasePlan.DnsTargetInterfaceIndex `
        -DnsCandidateServers $(if (@($XmlEvidence.DnsServers).Count -gt 0) { @($XmlEvidence.DnsServers) } else { @($BasePlan.DnsCandidateServers) }) `
        -DnsApplyStrategy $BasePlan.DnsApplyStrategy `
        -DnsPreexistingState $BasePlan.DnsPreexistingState `
        -DnsOwnedServers @($BasePlan.DnsOwnedServers) `
        -RouteTargetInterfaceIndex $BasePlan.RouteTargetInterfaceIndex `
        -RoutePreexistingState $BasePlan.RoutePreexistingState `
        -RouteCandidateEntries @($BasePlan.RouteCandidateEntries) `
        -RouteOwnedEntries @($BasePlan.RouteOwnedEntries) `
        -RouteApplyStrategy $BasePlan.RouteApplyStrategy `
        -SplitIncludeRoutes $(if (@($XmlEvidence.SplitIncludeRoutes).Count -gt 0) { @($XmlEvidence.SplitIncludeRoutes) } else { @($BasePlan.SplitIncludeRoutes) }) `
        -SplitExcludeRoutes $(if (@($XmlEvidence.SplitExcludeRoutes).Count -gt 0) { @($XmlEvidence.SplitExcludeRoutes) } else { @($BasePlan.SplitExcludeRoutes) }) `
        -SplitIncludeDomains $(if (@($XmlEvidence.SplitIncludeDomains).Count -gt 0) { @($XmlEvidence.SplitIncludeDomains) } else { @($BasePlan.SplitIncludeDomains) }) `
        -InterfaceHints @($BasePlan.InterfaceHints) `
        -Metadata $metadata)
}

function Get-NetworkConfigurationPlanFromReplayDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ReplayDirectory,

        [Parameter(Mandatory = $true)]
        [string] $Server,

        [Parameter(Mandatory = $true)]
        [string] $UserName
    )

    if (-not (Test-Path $ReplayDirectory)) {
        return $null
    }

    $documents = New-Object System.Collections.ArrayList
    $gatewayGetConfigPath = Join-Path $ReplayDirectory '04-gateway-getconfig.body.xml'
    $portalPreloginPath = Join-Path $ReplayDirectory '01-portal-prelogin.body.xml'

    if (Test-Path $gatewayGetConfigPath) {
        [void] $documents.Add((New-XmlConfigDocumentRecord -DocumentType 'ssl_vpn_getconfig' -RequestPath '/ssl-vpn/getconfig.esp' -XmlText (Get-Content -Path $gatewayGetConfigPath -Raw -ErrorAction Stop) -SourcePath $gatewayGetConfigPath))
    }

    if (Test-Path $portalPreloginPath) {
        [void] $documents.Add((New-XmlConfigDocumentRecord -DocumentType 'global_protect_prelogin' -RequestPath '/global-protect/prelogin.esp' -XmlText (Get-Content -Path $portalPreloginPath -Raw -ErrorAction Stop) -SourcePath $portalPreloginPath))
    }

    if ($documents.Count -eq 0) {
        return $null
    }

    $xmlEvidence = Get-NetworkConfigurationEvidenceFromXmlDocuments -Documents @($documents)
    if ($null -eq $xmlEvidence) {
        return $null
    }

    $metadata = @{
        replay_source = 'replay'
        replay_directory = $ReplayDirectory
        replay_server = $Server
        replay_username = $UserName
    }

    $basePlan = New-NetworkConfigurationPlan -Metadata $metadata
    return (Merge-NetworkConfigurationPlanWithXmlEvidence -BasePlan $basePlan -XmlEvidence $xmlEvidence)
}

function Get-ReplayConfigurationCacheEntries {
    param(
        [string] $CachePath
    )

    $cache = Read-JsonFileSafely -Path $CachePath
    if ($null -eq $cache -or $null -eq $cache.entries) {
        return @()
    }

    return @($cache.entries)
}

function Save-ReplayConfigurationCacheEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CachePath,

        [Parameter(Mandatory = $true)]
        [object[]] $Entries
    )

    $payload = [ordered]@{
        entries = @($Entries)
        last_updated = (Get-Date -Format 'o')
    }

    Write-JsonFileUtf8NoBom -Path $CachePath -Payload $payload
}

function Get-ReplayConfigurationCacheEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CachePath,

        [Parameter(Mandatory = $true)]
        [string] $UserName,

        [Parameter(Mandatory = $true)]
        [string] $Server,

        [string] $Gateway
    )

    $entries = @(Get-ReplayConfigurationCacheEntries -CachePath $CachePath)
    $matches = @($entries | Where-Object {
        $_.username -eq $UserName -and
        $_.server -eq $Server -and
        (
            [string]::IsNullOrWhiteSpace($Gateway) -or
            [string]::IsNullOrWhiteSpace([string] $_.gateway) -or
            [string] $_.gateway -eq $Gateway
        )
    })
    if ($matches.Count -eq 0) {
        return $null
    }

    return @($matches | Sort-Object captured_at -Descending | Select-Object -First 1)[0]
}

function Test-ReplayConfigurationCacheEntryFresh {
    param(
        [psobject] $Entry,

        [int] $TtlHours = 24
    )

    if ($null -eq $Entry -or -not $Entry.captured_at) {
        return $false
    }

    try {
        $capturedAt = [datetime]::Parse([string] $Entry.captured_at)
        return ($capturedAt -ge (Get-Date).AddHours(-1 * $TtlHours))
    } catch {
        return $false
    }
}

function Convert-NetworkConfigurationPlanToReplayCacheEntry {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Plan,

        [Parameter(Mandatory = $true)]
        [string] $UserName,

        [Parameter(Mandatory = $true)]
        [string] $Server,

        [Parameter(Mandatory = $true)]
        [string] $ReplayDirectory
    )

    return [PSCustomObject]@{
        username = $UserName
        server = $Server
        gateway = $Plan.Gateway
        captured_at = (Get-Date -Format 'o')
        replay_directory = $ReplayDirectory
        plan = $Plan
    }
}

function Update-ReplayConfigurationCacheEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CachePath,

        [Parameter(Mandatory = $true)]
        [psobject] $Entry
    )

    $entries = New-Object System.Collections.ArrayList
    foreach ($existing in @(Get-ReplayConfigurationCacheEntries -CachePath $CachePath)) {
        if (
            $existing.username -eq $Entry.username -and
            $existing.server -eq $Entry.server -and
            [string] $existing.gateway -eq [string] $Entry.gateway
        ) {
            continue
        }

        [void] $entries.Add($existing)
    }

    [void] $entries.Add($Entry)
    Save-ReplayConfigurationCacheEntries -CachePath $CachePath -Entries @($entries)
}

function Resolve-ReplayConfigurationPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RootDir,

        [Parameter(Mandatory = $true)]
        [string] $Server,

        [Parameter(Mandatory = $true)]
        [string] $UserName,

        [Parameter(Mandatory = $true)]
        [string] $CredentialFile,

        [Parameter(Mandatory = $true)]
        [string] $CachePath,

        [Parameter(Mandatory = $true)]
        [string] $OutputRoot,

        [int] $TtlHours = 24,

        [string] $LogPath
    )

    $cacheEntry = Get-ReplayConfigurationCacheEntry -CachePath $CachePath -UserName $UserName -Server $Server
    if ($cacheEntry -and (Test-ReplayConfigurationCacheEntryFresh -Entry $cacheEntry -TtlHours $TtlHours) -and $cacheEntry.plan) {
        Write-LogEvent -Segments @('replay-config', 'cache-hit') -Message ('Using cached replay-derived configuration for {0}@{1}.' -f $UserName, $Server) -LogPath $LogPath
        return [PSCustomObject]@{
            Status = 'ready'
            Source = 'replay_cache'
            Plan = $cacheEntry.plan
            Error = $null
            ReplayDirectory = $cacheEntry.replay_directory
        }
    }

    $replayScript = Join-Path $RootDir 'tools\replay-globalprotect-config.ps1'
    $replayExitCode = 0
    try {
        & $replayScript -Server $Server -CredentialFile $CredentialFile -OutputRoot $OutputRoot | Out-Null
        $replayExitCode = if ($null -ne $LASTEXITCODE) { [int] $LASTEXITCODE } else { 0 }
    } catch {
        $replayExitCode = 1
    }

    if ($replayExitCode -ne 0) {
        Write-LogEvent -Segments @('replay-config', 'replay-failed') -Message ('Replay failed for {0}@{1} with exit code {2}.' -f $UserName, $Server, $replayExitCode) -LogPath $LogPath
        return [PSCustomObject]@{
            Status = 'unavailable'
            Source = 'replay'
            Plan = $null
            Error = 'Replay failed and no fresh cache is available.'
            ReplayDirectory = $null
        }
    }

    $latestReplayDirectory = @(
        Get-ChildItem -Path $OutputRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    ) | Select-Object -First 1

    if ($null -eq $latestReplayDirectory) {
        return [PSCustomObject]@{
            Status = 'unavailable'
            Source = 'replay'
            Plan = $null
            Error = 'Replay completed but no output directory was produced.'
            ReplayDirectory = $null
        }
    }

    $plan = Get-NetworkConfigurationPlanFromReplayDirectory -ReplayDirectory $latestReplayDirectory.FullName -Server $Server -UserName $UserName
    if ($null -eq $plan) {
        return [PSCustomObject]@{
            Status = 'unavailable'
            Source = 'replay'
            Plan = $null
            Error = 'Replay output did not contain a usable getconfig XML document.'
            ReplayDirectory = $latestReplayDirectory.FullName
        }
    }

    Update-ReplayConfigurationCacheEntry -CachePath $CachePath -Entry (Convert-NetworkConfigurationPlanToReplayCacheEntry -Plan $plan -UserName $UserName -Server $Server -ReplayDirectory $latestReplayDirectory.FullName)
    Write-LogEvent -Segments @('replay-config', 'refreshed') -Message ('Refreshed replay-derived configuration for {0}@{1}.' -f $UserName, $Server) -LogPath $LogPath

    return [PSCustomObject]@{
        Status = 'ready'
        Source = 'replay'
        Plan = $plan
        Error = $null
        ReplayDirectory = $latestReplayDirectory.FullName
    }
}

function Convert-OpenConnectEvidenceToNetworkConfigurationPlan {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Evidence,

        [hashtable] $AdditionalMetadata
    )

    $metadata = @{
        raw_evidence = @($Evidence.RawEvidence)
    }

    if ($AdditionalMetadata) {
        foreach ($key in $AdditionalMetadata.Keys) {
            $metadata[$key] = $AdditionalMetadata[$key]
        }
    }

    $basePlan = New-NetworkConfigurationPlan -AssignedIp $Evidence.AssignedIp -PrefixLength $Evidence.PrefixLength -Gateway $Evidence.Gateway -DnsServers @($Evidence.DnsServers) -DnsCandidateServers @($Evidence.DnsServers) -SplitIncludeRoutes @($Evidence.SplitIncludeRoutes) -SplitExcludeRoutes @($Evidence.SplitExcludeRoutes) -SplitIncludeDomains @($Evidence.SplitIncludeDomains) -InterfaceHints @($Evidence.InterfaceHints) -Metadata $metadata
    $bodyDumpPath = $null
    if ($AdditionalMetadata -and $AdditionalMetadata.ContainsKey('http_config_body_path')) {
        $bodyDumpPath = [string] $AdditionalMetadata['http_config_body_path']
    }

    $xmlEvidence = Get-OpenConnectXmlNetworkConfigurationEvidence -BodyDumpFile $bodyDumpPath
    return (Merge-NetworkConfigurationPlanWithXmlEvidence -BasePlan $basePlan -XmlEvidence $xmlEvidence)
}

function Test-NetworkConfigurationPlanReady {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Plan
    )

    $hasConnectivityShape = -not [string]::IsNullOrWhiteSpace($Plan.AssignedIp) -and -not [string]::IsNullOrWhiteSpace($Plan.Gateway)
    $hasServerConfig = @($Plan.DnsServers).Count -gt 0 -or @($Plan.SplitIncludeRoutes).Count -gt 0 -or @($Plan.SplitExcludeRoutes).Count -gt 0
    return ($hasConnectivityShape -and $hasServerConfig)
}

function Get-LocalNetworkSnapshot {
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    $dnsSettings = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue)

    return [PSCustomObject]@{
        Adapters = $adapters
        DnsSettings = $dnsSettings
        Routes = $routes
    }
}

function ConvertTo-RouteSnapshotEntries {
    param(
        [object[]] $Routes
    )

    $entries = New-Object System.Collections.ArrayList
    foreach ($route in @($Routes)) {
        [void] $entries.Add([PSCustomObject]@{
            DestinationPrefix = [string] $route.DestinationPrefix
            InterfaceIndex = if ($null -ne $route.InterfaceIndex) { [int] $route.InterfaceIndex } else { $null }
            NextHop = [string] $route.NextHop
            RouteMetric = if ($null -ne $route.RouteMetric) { [int] $route.RouteMetric } else { $null }
        })
    }

    return @($entries)
}

function ConvertTo-DnsSnapshotMap {
    param(
        [object[]] $DnsSettings
    )

    $snapshot = @{}
    foreach ($dns in @($DnsSettings)) {
        $snapshot[[string] $dns.InterfaceIndex] = @($dns.ServerAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return $snapshot
}

function Get-NetworkConfigurationTargetAdapter {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Plan,

        [Parameter(Mandatory = $true)]
        [psobject] $Snapshot
    )

    $hintedIndex = $null
    foreach ($hint in @($Plan.InterfaceHints)) {
        if ([string] $hint -match 'index (\d+)') {
            $hintedIndex = [int] $Matches[1]
            break
        }
    }

    if ($null -ne $hintedIndex) {
        $adapter = @($Snapshot.Adapters | Where-Object { $_.InterfaceIndex -eq $hintedIndex } | Select-Object -First 1)
        if ($adapter.Count -gt 0) {
            return [PSCustomObject]@{
                Name = [string] $adapter[0].Name
                InterfaceIndex = [int] $adapter[0].InterfaceIndex
            }
        }
    }

    $vpnPattern = 'vpn|tun|tap|wintun|wireguard|openvpn|anyconnect|globalprotect'
    $dnsCandidates = @($Plan.DnsServers | ForEach-Object { [string] $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $routePrefixes = @($Plan.SplitIncludeRoutes | ForEach-Object { [string] $_.DestinationPrefix } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $rankedAdapters = New-Object System.Collections.ArrayList

    foreach ($adapter in @($Snapshot.Adapters)) {
        $adapterText = '{0} {1} {2}' -f $adapter.Name, $adapter.InterfaceDescription, $adapter.Status
        if ($adapter.Status -ne 'Up' -or $adapterText -notmatch $vpnPattern) {
            continue
        }

        $score = 1
        if ($adapterText -match 'openconnect|wintun|globalprotect') {
            $score += 2
        }

        $currentDns = @(Get-DnsAddressesForInterfaceIndex -Snapshot $Snapshot -InterfaceIndex $adapter.InterfaceIndex)
        if ($dnsCandidates.Count -gt 0 -and (Test-StringCollectionEqual -Left $currentDns -Right $dnsCandidates)) {
            $score += 10
        }

        $matchingRoutes = @(
            @($Snapshot.Routes) |
                Where-Object {
                    $_.InterfaceIndex -eq $adapter.InterfaceIndex -and
                    $routePrefixes -contains $_.DestinationPrefix
                }
        )
        if ($matchingRoutes.Count -gt 0) {
            $score += (20 + $matchingRoutes.Count)
        }

        [void] $rankedAdapters.Add([PSCustomObject]@{
            Name = [string] $adapter.Name
            InterfaceIndex = [int] $adapter.InterfaceIndex
            Score = [int] $score
        })
    }

    $selectedAdapter = @(
        $rankedAdapters |
            Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'InterfaceIndex'; Descending = $false } |
            Select-Object -First 1
    )
    if ($selectedAdapter.Count -gt 0 -and $selectedAdapter[0].Score -gt 1) {
        return [PSCustomObject]@{
            Name = [string] $selectedAdapter[0].Name
            InterfaceIndex = [int] $selectedAdapter[0].InterfaceIndex
        }
    }

    return $null
}

function Get-NetworkConfigurationTargetInterfaceIndex {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Plan,

        [Parameter(Mandatory = $true)]
        [psobject] $Snapshot
    )

    $targetAdapter = Get-NetworkConfigurationTargetAdapter -Plan $Plan -Snapshot $Snapshot
    if ($null -eq $targetAdapter) {
        return $null
    }

    return [int] $targetAdapter.InterfaceIndex
}

function Get-DnsAddressesForInterfaceIndex {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Snapshot,

        [Nullable[int]] $InterfaceIndex
    )

    if ($null -eq $InterfaceIndex) {
        return @()
    }

    $dnsMatch = @($Snapshot.DnsSettings | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex } | Select-Object -First 1)
    if ($dnsMatch.Count -eq 0) {
        return @()
    }

    return @($dnsMatch[0].ServerAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-StringCollectionEqual {
    param(
        [AllowNull()] [object[]] $Left,
        [AllowNull()] [object[]] $Right
    )

    $leftNormalized = @($Left | ForEach-Object { [string] $_ } | Sort-Object -Unique)
    $rightNormalized = @($Right | ForEach-Object { [string] $_ } | Sort-Object -Unique)

    if ($leftNormalized.Count -ne $rightNormalized.Count) {
        return $false
    }

    for ($i = 0; $i -lt $leftNormalized.Count; $i++) {
        if ($leftNormalized[$i] -ne $rightNormalized[$i]) {
            return $false
        }
    }

    return $true
}

function Test-StringCollectionContainsAll {
    param(
        [AllowNull()] [object[]] $Container,
        [AllowNull()] [object[]] $Subset
    )

    $containerNormalized = @($Container | ForEach-Object { [string] $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $subsetNormalized = @($Subset | ForEach-Object { [string] $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    foreach ($value in $subsetNormalized) {
        if ($containerNormalized -notcontains $value) {
            return $false
        }
    }

    return $true
}

function Get-BestPreConnectDefaultRoute {
    param(
        [AllowNull()]
        [object[]] $PreConnectRouteSnapshot
    )

    return @(
        @($PreConnectRouteSnapshot) |
            Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and -not [string]::IsNullOrWhiteSpace($_.NextHop) -and $_.NextHop -ne '0.0.0.0' } |
            Sort-Object RouteMetric, InterfaceIndex |
            Select-Object -First 1
    ) | Select-Object -First 1
}

function Find-RouteSnapshotMatch {
    param(
        [AllowNull()]
        [object[]] $Routes,

        [Parameter(Mandatory = $true)]
        [string] $DestinationPrefix,

        [Nullable[int]] $InterfaceIndex,

        [string] $NextHop
    )

    return @(
        @($Routes) |
            Where-Object {
                $_.DestinationPrefix -eq $DestinationPrefix -and
                ($null -eq $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex) -and
                ([string]::IsNullOrWhiteSpace($NextHop) -or $_.NextHop -eq $NextHop)
            } |
            Select-Object -First 1
    ) | Select-Object -First 1
}

function Test-NetworkConfigurationRouteUsesFlexibleNextHopMatching {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Route
    )

    return [string] $Route.RouteType -eq 'include'
}

function Build-NetworkConfigurationRouteCandidateEntries {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Plan,

        [Nullable[int]] $TargetInterfaceIndex,

        [AllowNull()]
        [object[]] $PreConnectRouteSnapshot
    )

    $candidates = New-Object System.Collections.ArrayList
    $conflicts = New-Object System.Collections.ArrayList
    $defaultRoute = Get-BestPreConnectDefaultRoute -PreConnectRouteSnapshot $PreConnectRouteSnapshot

    foreach ($route in @($Plan.SplitIncludeRoutes)) {
        if ($null -eq $TargetInterfaceIndex) {
            continue
        }

        [void] $candidates.Add((New-NetworkConfigurationRoute -Destination $route.Destination -PrefixLength $route.PrefixLength -Netmask $route.Netmask -RouteType 'include' -RawEvidence $route.RawEvidence -NextHop '0.0.0.0' -InterfaceIndex $TargetInterfaceIndex -RouteMetric 1 -OwnershipSource 'session_candidate'))
    }

    foreach ($route in @($Plan.SplitExcludeRoutes)) {
        if ($null -eq $defaultRoute) {
            [void] $conflicts.Add((New-NetworkConfigurationConflict -Kind 'route_bypass_unresolved' -Scope ('{0}/{1}' -f $route.Destination, $route.PrefixLength) -Summary 'Unable to derive a pre-connect default route for split exclude handling.' -Severity 'blocking'))
            continue
        }

        [void] $candidates.Add((New-NetworkConfigurationRoute -Destination $route.Destination -PrefixLength $route.PrefixLength -Netmask $route.Netmask -RouteType 'exclude' -RawEvidence $route.RawEvidence -NextHop ([string] $defaultRoute.NextHop) -InterfaceIndex ([int] $defaultRoute.InterfaceIndex) -RouteMetric ([int] $defaultRoute.RouteMetric) -OwnershipSource 'session_candidate'))
    }

    return [PSCustomObject]@{
        CandidateEntries = @($candidates)
        Conflicts = @($conflicts)
        DefaultRoute = $defaultRoute
    }
}

function Get-NetworkConfigurationDnsOwnership {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Plan,

        [Parameter(Mandatory = $true)]
        [psobject] $Snapshot,

        [AllowNull()]
        [hashtable] $PreConnectDnsSnapshot
    )

    $targetAdapter = Get-NetworkConfigurationTargetAdapter -Plan $Plan -Snapshot $Snapshot
    if ($null -eq $targetAdapter) {
        return [PSCustomObject]@{
            TargetAdapter = $null
            TargetInterfaceIndex = $null
            CandidateServers = @($Plan.DnsServers)
            PreexistingState = $null
            OwnedServers = @()
            Conflicts = @()
        }
    }

    $baselineAddresses = @()
    if ($PreConnectDnsSnapshot -and $PreConnectDnsSnapshot.ContainsKey([string] $targetAdapter.InterfaceIndex)) {
        $baselineAddresses = @($PreConnectDnsSnapshot[[string] $targetAdapter.InterfaceIndex])
    }

    $currentAddresses = @(Get-DnsAddressesForInterfaceIndex -Snapshot $Snapshot -InterfaceIndex $targetAdapter.InterfaceIndex)
    $preexistingState = [PSCustomObject]@{
        Mode = if ($baselineAddresses.Count -gt 0) { 'manual' } else { 'automatic_or_empty' }
        ServerAddresses = @($baselineAddresses)
    }

    $conflicts = New-Object System.Collections.ArrayList
    $ownedServers = @()

    if ($baselineAddresses.Count -gt 0) {
        [void] $conflicts.Add((New-NetworkConfigurationConflict -Kind 'dns_preexisting_manual' -Scope $targetAdapter.Name -Summary ('Target adapter {0} already had manual DNS before OpenConnect started: {1}' -f $targetAdapter.Name, ($baselineAddresses -join ', ')) -Severity 'blocking'))
    } elseif ($currentAddresses.Count -gt 0) {
        $ownedServers = @($currentAddresses)
        [void] $conflicts.Add((New-NetworkConfigurationConflict -Kind 'dns_self_managed' -Scope $targetAdapter.Name -Summary ('Current session manages DNS on adapter {0}: {1}' -f $targetAdapter.Name, ($currentAddresses -join ', ')) -Severity 'warning'))
    }

    return [PSCustomObject]@{
        TargetAdapter = $targetAdapter.Name
        TargetInterfaceIndex = $targetAdapter.InterfaceIndex
        CandidateServers = @($Plan.DnsServers)
        PreexistingState = $preexistingState
        OwnedServers = @($ownedServers)
        Conflicts = @($conflicts)
    }
}

function Get-NetworkConfigurationRouteOwnership {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Plan,

        [Parameter(Mandatory = $true)]
        [psobject] $Snapshot,

        [AllowNull()]
        [object[]] $PreConnectRouteSnapshot
    )

    $targetInterfaceIndex = Get-NetworkConfigurationTargetInterfaceIndex -Plan $Plan -Snapshot $Snapshot
    $candidateResult = Build-NetworkConfigurationRouteCandidateEntries -Plan $Plan -TargetInterfaceIndex $targetInterfaceIndex -PreConnectRouteSnapshot $PreConnectRouteSnapshot
    $conflicts = New-Object System.Collections.ArrayList
    foreach ($conflict in @($candidateResult.Conflicts)) {
        [void] $conflicts.Add($conflict)
    }

    $candidateEntries = New-Object System.Collections.ArrayList
    $ownedEntries = New-Object System.Collections.ArrayList
    $preexistingEntries = New-Object System.Collections.ArrayList

    foreach ($candidate in @($candidateResult.CandidateEntries)) {
        $routeMatchNextHop = if (Test-NetworkConfigurationRouteUsesFlexibleNextHopMatching -Route $candidate) { $null } else { $candidate.NextHop }
        $currentMatch = Find-RouteSnapshotMatch -Routes (ConvertTo-RouteSnapshotEntries -Routes $Snapshot.Routes) -DestinationPrefix $candidate.DestinationPrefix -InterfaceIndex $candidate.InterfaceIndex -NextHop $routeMatchNextHop
        if ($currentMatch) {
            $baselineTargetMatch = Find-RouteSnapshotMatch -Routes $PreConnectRouteSnapshot -DestinationPrefix $candidate.DestinationPrefix -InterfaceIndex $candidate.InterfaceIndex -NextHop $routeMatchNextHop
            if ($baselineTargetMatch) {
                [void] $preexistingEntries.Add($baselineTargetMatch)
                [void] $conflicts.Add((New-NetworkConfigurationConflict -Kind 'route_preexisting_manual' -Scope $candidate.DestinationPrefix -Summary ('Route {0} already existed on the target interface before OpenConnect started.' -f $candidate.DestinationPrefix) -Severity 'blocking'))
                continue
            }

            [void] $ownedEntries.Add((New-NetworkConfigurationRoute -Destination $candidate.Destination -PrefixLength $candidate.PrefixLength -Netmask $candidate.Netmask -RouteType $candidate.RouteType -RawEvidence $candidate.RawEvidence -NextHop $candidate.NextHop -InterfaceIndex $candidate.InterfaceIndex -RouteMetric $currentMatch.RouteMetric -DestinationPrefix $candidate.DestinationPrefix -OwnershipSource 'session_detected'))
            continue
        }

        $baselineMatch = Find-RouteSnapshotMatch -Routes $PreConnectRouteSnapshot -DestinationPrefix $candidate.DestinationPrefix
        if ($baselineMatch) {
            [void] $preexistingEntries.Add($baselineMatch)
            [void] $conflicts.Add((New-NetworkConfigurationConflict -Kind 'route_preexisting_manual' -Scope $candidate.DestinationPrefix -Summary ('Route {0} already existed before OpenConnect started.' -f $candidate.DestinationPrefix) -Severity 'blocking'))
            continue
        }

        [void] $candidateEntries.Add($candidate)
    }

    return [PSCustomObject]@{
        TargetInterfaceIndex = $targetInterfaceIndex
        PreexistingState = [PSCustomObject]@{
            ExistingEntries = @($preexistingEntries)
            DefaultRoute = $candidateResult.DefaultRoute
        }
        CandidateEntries = @($candidateEntries)
        OwnedEntries = @($ownedEntries)
        Conflicts = @($conflicts)
    }
}

function Get-NetworkConfigurationConflicts {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Plan,

        [Parameter(Mandatory = $true)]
        [psobject] $Snapshot,

        [AllowNull()]
        [psobject] $DnsOwnership
    )

    $conflicts = New-Object System.Collections.ArrayList
    $vpnPattern = 'vpn|tun|tap|wintun|wireguard|openvpn|anyconnect|globalprotect'

    foreach ($adapter in @($Snapshot.Adapters)) {
        $adapterText = '{0} {1} {2}' -f $adapter.Name, $adapter.InterfaceDescription, $adapter.Status
        if ($adapter.Status -eq 'Up' -and $adapterText -match $vpnPattern) {
            [void] $conflicts.Add((New-NetworkConfigurationConflict -Kind 'vpn_adapter_present' -Scope ($adapter.Name) -Summary ('Detected active VPN-like adapter: {0}' -f $adapterText.Trim()) -Severity 'warning'))
        }
    }

    foreach ($dns in @($Snapshot.DnsSettings)) {
        $adapterMatch = @($Snapshot.Adapters | Where-Object { $_.InterfaceIndex -eq $dns.InterfaceIndex } | Select-Object -First 1)
        $adapterName = if ($adapterMatch.Count -gt 0) { $adapterMatch[0].Name } else { 'InterfaceIndex=' + $dns.InterfaceIndex }
        $addresses = @($dns.ServerAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $isCurrentSessionDns = $false
        if ($DnsOwnership) {
            $targetIndexMatches = $null -ne $DnsOwnership.TargetInterfaceIndex -and $dns.InterfaceIndex -eq $DnsOwnership.TargetInterfaceIndex
            $targetNameMatches = -not [string]::IsNullOrWhiteSpace($DnsOwnership.TargetAdapter) -and $adapterName -eq $DnsOwnership.TargetAdapter
            $ownedDnsMatches = @($DnsOwnership.OwnedServers).Count -gt 0 -and (Test-StringCollectionEqual -Left $addresses -Right @($DnsOwnership.OwnedServers))
            $candidateDnsMatches = @($DnsOwnership.CandidateServers).Count -gt 0 -and (Test-StringCollectionEqual -Left $addresses -Right @($DnsOwnership.CandidateServers))
            $isCurrentSessionDns = ($targetIndexMatches -or $targetNameMatches) -and ($ownedDnsMatches -or $candidateDnsMatches)
        }

        if ($addresses.Count -gt 0 -and $adapterName -match $vpnPattern) {
            if ($isCurrentSessionDns) {
                continue
            }
            $summary = 'DNS is already configured on VPN-like adapter {0}: {1}' -f $adapterName, ($addresses -join ', ')
            [void] $conflicts.Add((New-NetworkConfigurationConflict -Kind 'dns_already_managed' -Scope $adapterName -Summary $summary -Severity 'blocking'))
        }
    }

    foreach ($route in @($Plan.RouteCandidateEntries)) {
        foreach ($existing in @($Snapshot.Routes)) {
            if ($existing.DestinationPrefix -eq $route.DestinationPrefix) {
                [void] $conflicts.Add((New-NetworkConfigurationConflict -Kind 'route_overlap' -Scope $existing.DestinationPrefix -Summary ('Existing route already present for {0} via interface index {1}' -f $existing.DestinationPrefix, $existing.InterfaceIndex) -Severity 'blocking'))
                break
            }
        }

        if ($route.Destination -eq '0.0.0.0' -and $route.PrefixLength -eq 0) {
            [void] $conflicts.Add((New-NetworkConfigurationConflict -Kind 'default_route_risk' -Scope '0.0.0.0/0' -Summary 'Preview plan contains a default route and may conflict with other local networking.' -Severity 'blocking'))
        }
    }

    return @($conflicts)
}

function Invoke-NetworkConfigurationPreview {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Plan,

        [Parameter(Mandatory = $true)]
        [psobject] $Context,

        [AllowNull()]
        [hashtable] $PreConnectDnsSnapshot,

        [AllowNull()]
        [object[]] $PreConnectRouteSnapshot
    )

    $status = 'not_ready'
    $C_error = $null
    $conflicts = @()
    $snapshot = $null

    if (Test-NetworkConfigurationPlanReady -Plan $Plan) {
        $snapshot = Get-LocalNetworkSnapshot
        $dnsOwnership = Get-NetworkConfigurationDnsOwnership -Plan $Plan -Snapshot $snapshot -PreConnectDnsSnapshot $PreConnectDnsSnapshot
        $routeOwnership = Get-NetworkConfigurationRouteOwnership -Plan $Plan -Snapshot $snapshot -PreConnectRouteSnapshot $PreConnectRouteSnapshot
        $plan = New-NetworkConfigurationPlan -Source $Plan.Source -AssignedIp $Plan.AssignedIp -PrefixLength $Plan.PrefixLength -Gateway $Plan.Gateway -DnsServers @($Plan.DnsServers) -DnsTargetAdapter $dnsOwnership.TargetAdapter -DnsTargetInterfaceIndex $dnsOwnership.TargetInterfaceIndex -DnsCandidateServers @($dnsOwnership.CandidateServers) -DnsApplyStrategy 'adapter_scoped' -DnsPreexistingState $dnsOwnership.PreexistingState -DnsOwnedServers @($dnsOwnership.OwnedServers) -RouteTargetInterfaceIndex $routeOwnership.TargetInterfaceIndex -RoutePreexistingState $routeOwnership.PreexistingState -RouteCandidateEntries @($routeOwnership.CandidateEntries) -RouteOwnedEntries @($routeOwnership.OwnedEntries) -RouteApplyStrategy 'split_routes_only' -SplitIncludeRoutes @($Plan.SplitIncludeRoutes) -SplitExcludeRoutes @($Plan.SplitExcludeRoutes) -SplitIncludeDomains @($Plan.SplitIncludeDomains) -InterfaceHints @($Plan.InterfaceHints) -Metadata $Plan.Metadata
        $conflicts = @(Get-NetworkConfigurationConflicts -Plan $plan -Snapshot $snapshot -DnsOwnership $dnsOwnership) + @($dnsOwnership.Conflicts) + @($routeOwnership.Conflicts)
        $externalBlockingConflicts = @($conflicts | Where-Object { $_.Severity -eq 'blocking' -and $_.Kind -ne 'dns_already_managed' })
        $externalDnsConflicts = @($conflicts | Where-Object { $_.Severity -eq 'blocking' -and $_.Kind -eq 'dns_already_managed' -and $_.Scope -ne $dnsOwnership.TargetAdapter })
        $blockingConflicts = @($externalBlockingConflicts + $externalDnsConflicts)
        $status = if ($blockingConflicts.Count -gt 0) { 'conflict_detected' } else { 'ready' }
    } elseif (-not [string]::IsNullOrWhiteSpace($Plan.AssignedIp) -or -not [string]::IsNullOrWhiteSpace($Plan.Gateway) -or @($Plan.DnsServers).Count -gt 0 -or @($Plan.SplitIncludeRoutes).Count -gt 0 -or @($Plan.SplitExcludeRoutes).Count -gt 0 -or @($Plan.SplitIncludeDomains).Count -gt 0) {
        $status = 'incomplete'
        $C_error = 'Server-derived network configuration is partial; required route or DNS metadata is still missing.'
    }

    return (New-NetworkConfigurationResult -Status $status -Error $C_error -Source $plan.Source -Plan $plan -Conflicts $conflicts -CollectedAt (Get-Date))
}

function Test-NetworkConfigurationRouteAlreadyPresent {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Route
    )

    $existingRoutes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $Route.DestinationPrefix -InterfaceIndex $Route.InterfaceIndex -ErrorAction SilentlyContinue)
    if ($existingRoutes.Count -eq 0) {
        return $false
    }

    if (Test-NetworkConfigurationRouteUsesFlexibleNextHopMatching -Route $Route) {
        return $true
    }

    return @($existingRoutes | Where-Object { $_.NextHop -eq $Route.NextHop }).Count -gt 0
}

function Update-NetworkConfigurationPreviewState {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $State,

        [Parameter(Mandatory = $true)]
        [string] $ServiceState,

        [Parameter(Mandatory = $true)]
        [string] $Reason,

        [string] $LogPath
    )

    if (-not $State.ContainsKey('NetworkConfigEvidence') -or $null -eq $State.NetworkConfigEvidence) {
        $State.NetworkConfigEvidence = New-NetworkConfigurationEvidence
    }

    $metadata = Get-OpenConnectHttpCapturePlanMetadata -CaptureState $State.HttpCapture -DumpFile $OpenConnectHttpDumpFile -BodyDumpFile $OpenConnectHttpBodyDumpFile
    $metadata['http_config_body_path'] = $OpenConnectHttpBodyDumpFile
    $evidencePlan = Convert-OpenConnectEvidenceToNetworkConfigurationPlan -Evidence $State.NetworkConfigEvidence -AdditionalMetadata $metadata
    $plan = if ($State.ReplayConfigResolution -and $State.ReplayConfigResolution.Plan) { $State.ReplayConfigResolution.Plan } else { $evidencePlan }
    $previousStatus = $State.NetworkConfigStatus

    if ($State.ReplayConfigResolution -and $State.ReplayConfigResolution.Status -eq 'unavailable') {
        $preview = New-NetworkConfigurationResult -Status 'incomplete' -Error $State.ReplayConfigResolution.Error -Source $State.ReplayConfigResolution.Source -Plan $plan -Conflicts @() -CollectedAt (Get-Date)
    } elseif ($State.SessionState -eq 'connected') {
        $preview = Invoke-NetworkConfigurationPreview -Plan $plan -Context (New-NetworkConfigurationContext -RootDir $RootDir -LogPath $LogPath -StatePath $StateFile) -PreConnectDnsSnapshot $State.PreConnectDnsSnapshot -PreConnectRouteSnapshot $State.PreConnectRouteSnapshot
        if ($preview.Status -eq 'ready' -and -not $State.NetworkConfigRouteApplied) {
            $State.NetworkConfigRouteApplied = $true
            $appliedRoutes = @(Invoke-NetworkConfigurationRouteApply -Plan $preview.Plan -LogPath $LogPath)
            if ($appliedRoutes.Count -gt 0) {
                $preview = Invoke-NetworkConfigurationPreview -Plan $plan -Context (New-NetworkConfigurationContext -RootDir $RootDir -LogPath $LogPath -StatePath $StateFile) -PreConnectDnsSnapshot $State.PreConnectDnsSnapshot -PreConnectRouteSnapshot $State.PreConnectRouteSnapshot
            }
        }
    } elseif (@($State.NetworkConfigEvidence.RawEvidence).Count -gt 0) {
        $preview = New-NetworkConfigurationResult -Status 'collecting' -Source $plan.Source -Plan $plan -Conflicts @() -CollectedAt (Get-Date)
    } else {
        $preview = New-NetworkConfigurationResult -Status 'not_ready' -Source $plan.Source -Plan $plan -Conflicts @() -CollectedAt (Get-Date)
    }

    $State.NetworkConfigStatus = $preview.Status
    $State.NetworkConfigSource = $preview.Source
    $State.NetworkConfigError = $preview.Error
    $State.NetworkConfigPlan = $preview.Plan
    $State.NetworkConflicts = @($preview.Conflicts)
    $State.NetworkConfigLastUpdated = $preview.CollectedAt

    if ($previousStatus -ne $preview.Status) {
        $message = 'Network configuration preview status changed to {0}' -f $preview.Status
        if ($preview.Error) {
            $message = '{0}; Reason={1}' -f $message, $preview.Error
        }
        Write-LogEvent -Segments @('network-config', $preview.Status) -Message $message -LogPath $LogPath
    }

    Update-ServiceRuntimeState -ServiceState $ServiceState -SessionState $State.SessionState -Reason $Reason -OpenConnectPid $State.ProcessId -ConnectedAt $State.ConnectedAt -AssignedIp $State.AssignedIp -SessionExpiresAt $State.SessionExpiresAt -Gateway $State.Gateway -TransportMode $State.TransportMode -TransportChangedAt $State.TransportChangedAt -LastTransportEvent $State.LastTransportEvent -LastTransportEventAt $State.LastTransportEventAt -LastRekeyAt $State.LastRekeyAt -LastHipCheckAt $State.LastHipCheckAt -LastDpdOkAt $State.LastDpdOkAt -NetworkConfigStatus $preview.Status -NetworkConfigSource $preview.Source -NetworkConfigError $preview.Error -NetworkConfigLastUpdated $preview.CollectedAt -NetworkConfigPlan $preview.Plan -NetworkConflicts @($preview.Conflicts)
}

function Invoke-NetworkConfigurationRouteApply {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Plan,

        [string] $LogPath
    )

    $appliedEntries = New-Object System.Collections.ArrayList
    foreach ($route in @($Plan.RouteCandidateEntries)) {
        try {
            New-NetRoute -DestinationPrefix $route.DestinationPrefix -InterfaceIndex $route.InterfaceIndex -NextHop $route.NextHop -RouteMetric $(if ($null -ne $route.RouteMetric) { [int] $route.RouteMetric } else { 1 }) -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
            Write-LogEvent -Segments @('network-config', 'route-apply') -Message ('Applied route {0} via interface {1} next hop {2}' -f $route.DestinationPrefix, $route.InterfaceIndex, $route.NextHop) -LogPath $LogPath
            [void] $appliedEntries.Add((New-NetworkConfigurationRoute -Destination $route.Destination -PrefixLength $route.PrefixLength -Netmask $route.Netmask -RouteType $route.RouteType -RawEvidence $route.RawEvidence -NextHop $route.NextHop -InterfaceIndex $route.InterfaceIndex -RouteMetric $route.RouteMetric -DestinationPrefix $route.DestinationPrefix -OwnershipSource 'session_applied'))
        } catch {
            if (Test-NetworkConfigurationRouteAlreadyPresent -Route $route) {
                Write-LogEvent -Segments @('network-config', 'route-apply') -Message ('Skipped route {0}; an equivalent route is already present on interface {1}' -f $route.DestinationPrefix, $route.InterfaceIndex) -LogPath $LogPath
                [void] $appliedEntries.Add((New-NetworkConfigurationRoute -Destination $route.Destination -PrefixLength $route.PrefixLength -Netmask $route.Netmask -RouteType $route.RouteType -RawEvidence $route.RawEvidence -NextHop $route.NextHop -InterfaceIndex $route.InterfaceIndex -RouteMetric $route.RouteMetric -DestinationPrefix $route.DestinationPrefix -OwnershipSource 'session_detected'))
                continue
            }

            throw
        }
    }

    return @($appliedEntries)
}

function Invoke-NetworkConfigurationDnsRevert {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Plan,

        [string] $LogPath
    )

    if ($null -eq $Plan) {
        return $false
    }

    $interfaceIndex = $Plan.DnsTargetInterfaceIndex
    $ownedServers = @($Plan.DnsOwnedServers)
    $preexistingState = $Plan.DnsPreexistingState

    if ($null -eq $interfaceIndex -or $ownedServers.Count -eq 0) {
        return $false
    }

    $dnsState = @(Get-DnsClientServerAddress -InterfaceIndex $interfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1)
    $currentAddresses = if ($dnsState.Count -gt 0) { @($dnsState[0].ServerAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } else { @() }

    if (-not (Test-StringCollectionContainsAll -Container $currentAddresses -Subset $ownedServers)) {
        Write-LogEvent -Segments @('network-config', 'dns-revert') -Message ('Skipping DNS revert on interface {0}; current DNS no longer matches owned session DNS.' -f $interfaceIndex) -LogPath $LogPath
        return $false
    }

    if ($preexistingState -and $preexistingState.Mode -eq 'manual' -and @($preexistingState.ServerAddresses).Count -gt 0) {
        Write-LogEvent -Segments @('network-config', 'dns-revert') -Message ('Skipping DNS revert on interface {0}; baseline was manual and should not be overwritten automatically.' -f $interfaceIndex) -LogPath $LogPath
        return $false
    }

    Set-DnsClientServerAddress -InterfaceIndex $interfaceIndex -ResetServerAddresses -ErrorAction Stop
    Write-LogEvent -Segments @('network-config', 'dns-revert') -Message ('Reset adapter-scoped DNS on interface {0} after reverting owned session DNS: {1}' -f $interfaceIndex, ($ownedServers -join ', ')) -LogPath $LogPath
    return $true
}

function Invoke-NetworkConfigurationRouteRevert {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Plan,

        [string] $LogPath
    )

    $reverted = $false
    foreach ($route in @($Plan.RouteOwnedEntries)) {
        $currentRoute = if (Test-NetworkConfigurationRouteUsesFlexibleNextHopMatching -Route $route) {
            @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $route.DestinationPrefix -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue | Select-Object -First 1)
        } else {
            @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $route.DestinationPrefix -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $route.NextHop } | Select-Object -First 1)
        }
        if ($currentRoute.Count -eq 0) {
            continue
        }

        if (Test-NetworkConfigurationRouteUsesFlexibleNextHopMatching -Route $route) {
            Remove-NetRoute -AddressFamily IPv4 -DestinationPrefix $route.DestinationPrefix -InterfaceIndex $route.InterfaceIndex -Confirm:$false -ErrorAction Stop
        } else {
            Remove-NetRoute -AddressFamily IPv4 -DestinationPrefix $route.DestinationPrefix -InterfaceIndex $route.InterfaceIndex -NextHop $route.NextHop -Confirm:$false -ErrorAction Stop
        }
        Write-LogEvent -Segments @('network-config', 'route-revert') -Message ('Removed owned route {0} via interface {1} next hop {2}' -f $route.DestinationPrefix, $route.InterfaceIndex, $route.NextHop) -LogPath $LogPath
        $reverted = $true
    }

    return $reverted
}
