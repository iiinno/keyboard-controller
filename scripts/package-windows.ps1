#Requires -Version 5.1
param([string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'))
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('keyboard-controller-package-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
try {
    foreach ($name in @('main.ahk','recover.ahk','config.example.ini','README.md','LICENSE','THIRD_PARTY_NOTICES.md','install.ps1','install.cmd')) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination $work
    }
    foreach ($directory in @('lib','tools','docs')) {
        $destination = Join-Path $work $directory
        New-Item -ItemType Directory -Path $destination | Out-Null
        $filter = if ($directory -eq 'docs') { '*' } else { '*.ahk' }
        Get-ChildItem -LiteralPath (Join-Path $root $directory) -File -Filter $filter | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $destination
        }
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $archive = Join-Path $OutputDirectory 'keyboard-controller-windows-x64.zip'
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($work, $archive)
    $line = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() + '  keyboard-controller-windows-x64.zip'
    [IO.File]::WriteAllText($archive + '.sha256', $line + "`n", [Text.UTF8Encoding]::new($false))
    Write-Host "PACKAGE=$archive"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
