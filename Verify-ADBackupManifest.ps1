[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $BackupPath 'manifest-sha256.txt'
if (-not (Test-Path $manifestPath)) {
    throw "Manifest file not found: $manifestPath"
}

$failures = @()
$lines = Get-Content -Path $manifestPath
foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $parts = $line -split '\s{2,}', 2
    if ($parts.Count -ne 2) {
        $failures += "Malformed line: $line"
        continue
    }

    $expectedHash = $parts[0].Trim()
    $relativePath = $parts[1].TrimStart('.','\')
    $fullPath = Join-Path $BackupPath $relativePath

    if (-not (Test-Path $fullPath)) {
        $failures += "Missing file: $relativePath"
        continue
    }

    $actualHash = (Get-FileHash -Path $fullPath -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) {
        $failures += "Hash mismatch: $relativePath"
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "Manifest verification failed with $($failures.Count) issue(s)."
}

Write-Host "Manifest verification successful for $BackupPath"
