param(
    [string] $OutputDir = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath 'out\openconnect-win64'),
    [ValidateSet('docker', 'podman')]
    [string] $ContainerEngine,
    [string] $ImageTag = 'ntut-autovpn/openconnect-build:fedora42-mingw64',
    [switch] $RebuildImage
)

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
$scriptPath = '/workspace/third_party/openconnect-build/build-openconnect-win64.sh'
$containerOutputDir = '/workspace/out/openconnect-win64'
$dockerfilePath = Join-Path $PSScriptRoot 'Dockerfile.mingw64'

if (-not $ContainerEngine) {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $ContainerEngine = 'docker'
    } elseif (Get-Command podman -ErrorAction SilentlyContinue) {
        $ContainerEngine = 'podman'
    } else {
        throw 'Docker or Podman is required for local Windows debug builds.'
    }
}

if (-not (Test-Path $dockerfilePath)) {
    throw "Missing Dockerfile: $dockerfilePath"
}

function Test-ContainerImageExists {
    param(
        [string] $Engine,
        [string] $Tag
    )

    & $Engine image inspect $Tag *> $null
    return $LASTEXITCODE -eq 0
}

function Invoke-ContainerBuildImage {
    param(
        [string] $Engine,
        [string] $Tag,
        [string] $Context,
        [string] $Dockerfile
    )

    $buildCommand = @(
        'build',
        '-t', $Tag,
        '-f', $Dockerfile,
        $Context
    )

    & $Engine @buildCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to build local OpenConnect build image '$Tag'."
    }
}

$shouldBuildImage = $RebuildImage -or -not (Test-ContainerImageExists -Engine $ContainerEngine -Tag $ImageTag)
if ($shouldBuildImage) {
    Write-Host "Building local OpenConnect build image $ImageTag" -ForegroundColor Cyan
    Invoke-ContainerBuildImage -Engine $ContainerEngine -Tag $ImageTag -Context $repoRoot -Dockerfile $dockerfilePath
}

$volumeSpec = '{0}:/workspace' -f $repoRoot
$buildCommand = @(
    'run', '--rm',
    '-v', $volumeSpec,
    '-w', '/workspace',
    $ImageTag,
    'bash', '-lc', "$scriptPath $containerOutputDir"
)

& $ContainerEngine @buildCommand
if ($LASTEXITCODE -ne 0) {
    throw "Local OpenConnect build failed with exit code $LASTEXITCODE."
}

Write-Host "OpenConnect runtime staged under $OutputDir" -ForegroundColor Green
