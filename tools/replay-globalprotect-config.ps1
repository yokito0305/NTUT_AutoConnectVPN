param(
    [string] $Server,
    [string] $CredentialFile,
    [string] $OutputRoot,
    [switch] $SkipCertificateValidation
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RootDir = (Resolve-Path (Join-Path $ScriptRoot '..')).ProviderPath

try {
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
} catch {
}
. (Join-Path $RootDir 'config\config.ps1')
. (Join-Path $RootDir 'src\lib\vpn_common.ps1')

if (-not $Server) {
    $Server = Get-VpnConfig -ConfigKey 'VpnServer' -RootDir $RootDir
}

if (-not $CredentialFile) {
    $CredentialFile = Get-VpnConfig -ConfigKey 'CredentialFile' -RootDir $RootDir
}

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $RootDir 'out\http-replay'
}

function New-ReplayDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BasePath
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $BasePath $timestamp
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Get-ReplayCredential {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path $Path)) {
        throw "Credential file not found: $Path"
    }

    $cred = Import-Clixml -Path $Path
    if (-not ($cred -is [System.Management.Automation.PSCredential])) {
        throw "Credential file does not contain a PSCredential: $Path"
    }

    return @{
        UserName = $cred.UserName
        Password = SecureStringToPlainText $cred.Password
    }
}

function New-ReplayHttpClient {
    param(
        [switch] $DisableCertificateValidation
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.CookieContainer = [System.Net.CookieContainer]::new()
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

    if ($DisableCertificateValidation) {
        $handler.ServerCertificateCustomValidationCallback = { $true }
    }

    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    $client.DefaultRequestHeaders.ExpectContinue = $false
    $client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'OpenConnect-HTTP-Replay/1.0')

    return @{
        Client = $client
        Handler = $handler
    }
}

function Save-ResponseArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string] $OutputDirectory,

        [Parameter(Mandatory = $true)]
        [string] $Stem,

        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpResponseMessage] $Response,

        [Parameter(Mandatory = $true)]
        [byte[]] $BodyBytes
    )

    $headersPath = Join-Path $OutputDirectory ($Stem + '.headers.txt')
    $bodyPath = Join-Path $OutputDirectory ($Stem + '.body.xml')
    $metaPath = Join-Path $OutputDirectory ($Stem + '.meta.json')

    $headerLines = [System.Collections.Generic.List[string]]::new()
    $headerLines.Add(("HTTP/{0} {1} {2}" -f $Response.Version, [int] $Response.StatusCode, $Response.ReasonPhrase))
    foreach ($header in $Response.Headers) {
        $headerLines.Add(("{0}: {1}" -f $header.Key, ($header.Value -join ', ')))
    }
    foreach ($header in $Response.Content.Headers) {
        $headerLines.Add(("{0}: {1}" -f $header.Key, ($header.Value -join ', ')))
    }

    [System.IO.File]::WriteAllLines($headersPath, $headerLines, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllBytes($bodyPath, $BodyBytes)

    $bodyText = [System.Text.Encoding]::UTF8.GetString($BodyBytes)
    $xmlRoot = $null
    $xmlStatus = 'not_xml'

    try {
        $xmlDoc = [System.Xml.XmlDocument]::new()
        $xmlDoc.LoadXml($bodyText)
        $xmlRoot = $xmlDoc.DocumentElement.Name
        $xmlStatus = 'valid_xml'
    } catch {
        $xmlStatus = 'invalid_xml'
    }

    $payload = [ordered]@{
        status_code = [int] $Response.StatusCode
        reason_phrase = $Response.ReasonPhrase
        content_type = if ($Response.Content.Headers.ContentType) { $Response.Content.Headers.ContentType.ToString() } else { $null }
        content_length_header = if ($Response.Content.Headers.ContentLength) { [int64] $Response.Content.Headers.ContentLength } else { $null }
        body_byte_length = $BodyBytes.Length
        xml_status = $xmlStatus
        xml_root = $xmlRoot
        captured_at = (Get-Date -Format 'o')
    }

    [System.IO.File]::WriteAllText(
        $metaPath,
        ($payload | ConvertTo-Json -Depth 4),
        [System.Text.UTF8Encoding]::new($false)
    )

    return $payload
}

function Invoke-FormPost {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [Parameter(Mandatory = $true)]
        [hashtable] $FormFields,

        [Parameter(Mandatory = $true)]
        [string] $OutputDirectory,

        [Parameter(Mandatory = $true)]
        [string] $Stem
    )

    $pairs = [System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]]::new()
    foreach ($entry in $FormFields.GetEnumerator()) {
        if ($null -eq $entry.Value) { continue }
        $pairs.Add([System.Collections.Generic.KeyValuePair[string,string]]::new([string] $entry.Key, [string] $entry.Value))
    }

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Uri)
    $request.Content = [System.Net.Http.FormUrlEncodedContent]::new($pairs)
    $response = $Client.SendAsync($request).GetAwaiter().GetResult()
    $bodyBytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $metadata = Save-ResponseArtifacts -OutputDirectory $OutputDirectory -Stem $Stem -Response $response -BodyBytes $bodyBytes

    return @{
        Response = $response
        BodyBytes = $bodyBytes
        BodyText = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
        Metadata = $metadata
    }
}

function Get-XmlValue {
    param(
        [Parameter(Mandatory = $true)]
        [string] $XmlText,

        [Parameter(Mandatory = $true)]
        [string] $XPath
    )

    try {
        $doc = [System.Xml.XmlDocument]::new()
        $doc.LoadXml($XmlText)
        $node = $doc.SelectSingleNode($XPath)
        if ($node) {
            return $node.InnerText
        }
    } catch {
    }

    return $null
}

function Get-JnlpArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string] $XmlText
    )

    $result = [ordered]@{}
    $doc = [System.Xml.XmlDocument]::new()
    $doc.LoadXml($XmlText)
    $arguments = @($doc.SelectNodes('/jnlp/application-desc/argument'))

    if ($arguments.Count -lt 19) {
        throw "Gateway login response did not include the expected number of JNLP arguments."
    }

    $result.authcookie = $arguments[1].InnerText
    $result.portal = $arguments[3].InnerText
    $result.user = $arguments[4].InnerText
    $result.domain = $arguments[7].InnerText
    $result.clientVer = $arguments[14].InnerText
    $result.preferred_ip = $arguments[15].InnerText
    $result.portal_userauthcookie = $arguments[16].InnerText
    $result.portal_prelogonuserauthcookie = $arguments[17].InnerText
    $result.preferred_ipv6 = $arguments[18].InnerText

    return $result
}

$credential = Get-ReplayCredential -Path $CredentialFile
$outputDirectory = New-ReplayDirectory -BasePath $OutputRoot

$http = New-ReplayHttpClient -DisableCertificateValidation:$SkipCertificateValidation
$client = $http.Client

$osVersion = [System.Environment]::OSVersion.VersionString
$computerName = [System.Environment]::MachineName
$ipv6Support = 'yes'

$portalPreloginUri = "https://$Server/global-protect/prelogin.esp?tmp=tmp&clientVer=4100&clientos=Windows"
$portalGetConfigUri = "https://$Server/global-protect/getconfig.esp"
$gatewayLoginUri = "https://$Server/ssl-vpn/login.esp"
$gatewayGetConfigUri = "https://$Server/ssl-vpn/getconfig.esp"

Write-Host "Replay output: $outputDirectory"
Write-Host "Requesting portal prelogin..."
$portalPrelogin = Invoke-FormPost -Client $client -Uri $portalPreloginUri -FormFields @{ 'cas-support' = 'yes' } -OutputDirectory $outputDirectory -Stem '01-portal-prelogin'

Write-Host "Requesting portal getconfig..."
$portalGetConfigFields = @{
    'jnlpReady' = 'jnlpReady'
    'ok' = 'Login'
    'direct' = 'yes'
    'clientVer' = '4100'
    'prot' = 'https:'
    'internal' = 'no'
    'ipv6-support' = $ipv6Support
    'clientos' = 'Windows'
    'os-version' = $osVersion
    'server' = $Server
    'computer' = $computerName
    'user' = $credential.UserName
    'passwd' = $credential.Password
}
$portalConfig = Invoke-FormPost -Client $client -Uri $portalGetConfigUri -FormFields $portalGetConfigFields -OutputDirectory $outputDirectory -Stem '02-portal-getconfig'

$portalUserAuthCookie = Get-XmlValue -XmlText $portalConfig.BodyText -XPath '/policy/portal-userauthcookie'
$portalPrelogonUserAuthCookie = Get-XmlValue -XmlText $portalConfig.BodyText -XPath '/policy/portal-prelogonuserauthcookie'

Write-Host "Requesting gateway login..."
$gatewayLoginFields = @{
    'jnlpReady' = 'jnlpReady'
    'ok' = 'Login'
    'direct' = 'yes'
    'clientVer' = '4100'
    'prot' = 'https:'
    'internal' = 'no'
    'ipv6-support' = $ipv6Support
    'clientos' = 'Windows'
    'os-version' = $osVersion
    'server' = $Server
    'computer' = $computerName
    'user' = $credential.UserName
    'passwd' = $credential.Password
}
if ($portalUserAuthCookie) {
    $gatewayLoginFields['portal-userauthcookie'] = $portalUserAuthCookie
}
if ($portalPrelogonUserAuthCookie) {
    $gatewayLoginFields['portal-prelogonuserauthcookie'] = $portalPrelogonUserAuthCookie
}

$gatewayLogin = Invoke-FormPost -Client $client -Uri $gatewayLoginUri -FormFields $gatewayLoginFields -OutputDirectory $outputDirectory -Stem '03-gateway-login'
$gatewayArgs = Get-JnlpArguments -XmlText $gatewayLogin.BodyText

Write-Host "Requesting gateway getconfig..."
$gatewayGetConfigFields = @{
    'client-type' = '1'
    'protocol-version' = 'p1'
    'internal' = 'no'
    'app-version' = '6.3.0-33'
    'ipv6-support' = $ipv6Support
    'clientos' = 'Windows'
    'os-version' = $osVersion
    'hmac-algo' = 'sha1,md5,sha256'
    'enc-algo' = 'aes-128-cbc,aes-256-cbc'
    'authcookie' = $gatewayArgs.authcookie
    'portal' = $gatewayArgs.portal
    'user' = $gatewayArgs.user
    'domain' = $gatewayArgs.domain
}
if ($gatewayArgs.preferred_ip) {
    $gatewayGetConfigFields['preferred-ip'] = $gatewayArgs.preferred_ip
}
if ($gatewayArgs.preferred_ipv6) {
    $gatewayGetConfigFields['preferred-ipv6'] = $gatewayArgs.preferred_ipv6
}

$gatewayConfig = Invoke-FormPost -Client $client -Uri $gatewayGetConfigUri -FormFields $gatewayGetConfigFields -OutputDirectory $outputDirectory -Stem '04-gateway-getconfig'

$summary = [ordered]@{
    server = $Server
    output_directory = $outputDirectory
    portal_prelogin = $portalPrelogin.Metadata
    portal_getconfig = $portalConfig.Metadata
    gateway_login = $gatewayLogin.Metadata
    gateway_getconfig = $gatewayConfig.Metadata
    derived = [ordered]@{
        portal_userauthcookie_present = [bool] $portalUserAuthCookie
        portal_prelogonuserauthcookie_present = [bool] $portalPrelogonUserAuthCookie
        authcookie_present = [bool] $gatewayArgs.authcookie
        portal = $gatewayArgs.portal
        user = $gatewayArgs.user
        domain = $gatewayArgs.domain
        preferred_ip = $gatewayArgs.preferred_ip
        preferred_ipv6 = $gatewayArgs.preferred_ipv6
    }
    captured_at = (Get-Date -Format 'o')
}

$summaryPath = Join-Path $outputDirectory 'summary.json'
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host 'Replay completed.'
Write-Host "Summary: $summaryPath"
