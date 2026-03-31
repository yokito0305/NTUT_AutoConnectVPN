[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = (Resolve-Path (Join-Path $scriptRoot '..')).ProviderPath
}

$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$violations = New-Object System.Collections.Generic.List[string]

Push-Location $RepositoryRoot
try {
    $trackedFiles = git ls-files

    foreach ($file in $trackedFiles) {
        if ($file -match '^(bin/|.*\.(dll|exe|png|jpg|jpeg|gif|zip)$)') {
            continue
        }

        $bytes = [System.IO.File]::ReadAllBytes($file)
        $hasUtf8Bom = $bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and
            $bytes[1] -eq 0xBB -and
            $bytes[2] -eq 0xBF

        if ($hasUtf8Bom) {
            $violations.Add("${file}: UTF-8 BOM detected")
            continue
        }

        try {
            $text = $utf8.GetString($bytes)
        } catch {
            $violations.Add("${file}: not valid UTF-8")
            continue
        }

        if ($text.Contains("`n") -and $text.Contains("`r`n")) {
            $normalized = $text.Replace("`r`n", [string]::Empty)
            if ($normalized.Contains("`n")) {
                $violations.Add("${file}: mixed line endings")
                continue
            }
        }

        if ([regex]::IsMatch($text, "(?<!`r)`n")) {
            $violations.Add("${file}: LF line endings detected")
        }
    }
}
finally {
    Pop-Location
}

if ($violations.Count -gt 0) {
    $violations | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host 'Encoding check passed: UTF-8 without BOM + CRLF'
