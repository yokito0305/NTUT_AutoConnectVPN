param(
    [string] $SourceDir = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath 'out\openconnect-win64\bin'),
    [string] $DestinationDir = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath 'bin')
)

if (-not (Test-Path $SourceDir)) {
    throw "Source runtime directory not found: $SourceDir"
}

New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
Get-ChildItem -Path $SourceDir -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $DestinationDir $_.Name) -Force
}

Write-Host "Staged OpenConnect runtime into $DestinationDir" -ForegroundColor Green
