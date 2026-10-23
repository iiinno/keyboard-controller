#Requires -Version 5.1
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'keyboard-controller'),
    [string]$SourceRoot = $PSScriptRoot,
    [string]$DownloadCache = '',
    [switch]$NoLaunch,
    [switch]$NoShortcuts
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64') {
    throw 'This Windows build requires an x64 PC; the Interception driver does not support Windows ARM64.'
}
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory)
if ($InstallDirectory -eq [IO.Path]::GetPathRoot($InstallDirectory)) { throw 'Choose an application directory, not a drive root.' }
$work = Join-Path ([IO.Path]::GetTempPath()) ('keyboard-controller-install-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null

function Get-VerifiedArchive([string]$Name, [string]$Url, [string]$Sha256) {
    $path = Join-Path $work $Name
    if ($DownloadCache -and (Test-Path -LiteralPath (Join-Path $DownloadCache $Name))) {
        Copy-Item -LiteralPath (Join-Path $DownloadCache $Name) -Destination $path
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $path
    }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Sha256) { throw "SHA-256 mismatch: $Name" }
    return $path
}

try {
    if (-not $SourceRoot -or -not (Test-Path -LiteralPath (Join-Path $SourceRoot 'main.ahk'))) {
        $base = 'https://github.com/iiinno/keyboard-controller/releases/latest/download'
        $zip = Join-Path $work 'keyboard-controller-windows-x64.zip'
        $manifest = Join-Path $work 'windows.sha256'
        Invoke-WebRequest -UseBasicParsing "$base/keyboard-controller-windows-x64.zip" -OutFile $zip
        Invoke-WebRequest -UseBasicParsing "$base/keyboard-controller-windows-x64.zip.sha256" -OutFile $manifest
        $line = (Get-Content -LiteralPath $manifest -Raw).Trim()
        if ($line -notmatch '^([a-fA-F0-9]{64})\s+keyboard-controller-windows-x64\.zip$') { throw 'Invalid release checksum manifest' }
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $Matches[1]) { throw 'Release SHA-256 mismatch' }
        $SourceRoot = Join-Path $work 'source'
        Expand-Archive -LiteralPath $zip -DestinationPath $SourceRoot
    }
    $SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
    if ($SourceRoot.TrimEnd('\') -eq $InstallDirectory.TrimEnd('\')) { throw 'Install into a separate application directory.' }
    # Check locks before changing any installed code or dependency.
    foreach ($relative in @('.runtime\AutoHotkey64.exe', 'lib\interception.dll')) {
        $existing = Join-Path $InstallDirectory $relative
        if (Test-Path -LiteralPath $existing) {
            try { $file = [IO.File]::Open($existing, 'Open', 'ReadWrite', 'None'); $file.Dispose() }
            catch { throw 'Close the running controller and setup window before updating; installed files are still in use.' }
        }
    }
    $ahk = Get-VerifiedArchive 'AutoHotkey_2.0.30.zip' 'https://github.com/AutoHotkey/AutoHotkey/releases/download/v2.0.30/AutoHotkey_2.0.30.zip' '1E0ECE7ECB2D5646E55758150472677996A57F9DB5C83D2996D8B47B9E2F31A4'
    $interception = Get-VerifiedArchive 'Interception_1.0.1.zip' 'https://github.com/oblitum/Interception/releases/download/v1.0.1/Interception.zip' 'AD038963D6413055765128B0B931F6E765147C9916DBA79E65D872B261F9AF10'
    $ahkDir = Join-Path $work 'ahk'
    $driverDir = Join-Path $work 'interception'
    Expand-Archive -LiteralPath $ahk -DestinationPath $ahkDir
    Expand-Archive -LiteralPath $interception -DestinationPath $driverDir
    New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
    foreach ($name in @('main.ahk','recover.ahk','config.example.ini','README.md','LICENSE','THIRD_PARTY_NOTICES.md','install.ps1','install.cmd')) {
        Copy-Item -LiteralPath (Join-Path $SourceRoot $name) -Destination (Join-Path $InstallDirectory $name) -Force
    }
    foreach ($directory in @('lib','tools','docs')) {
        $target = Join-Path $InstallDirectory $directory
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $filter = if ($directory -eq 'docs') { '*' } else { '*.ahk' }
        Get-ChildItem -LiteralPath (Join-Path $SourceRoot $directory) -File -Filter $filter | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
    }
    $runtime = Join-Path $InstallDirectory '.runtime'
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $ahkDir 'AutoHotkey64.exe') -Destination $runtime -Force
    Copy-Item -LiteralPath (Join-Path $driverDir 'Interception\library\x64\interception.dll') -Destination (Join-Path $InstallDirectory 'lib\interception.dll') -Force
    $driverTarget = Join-Path $runtime 'interception'
    New-Item -ItemType Directory -Path $driverTarget -Force | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $driverDir 'Interception') | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $driverTarget -Recurse -Force
    }
    Get-ChildItem -LiteralPath $ahkDir -File | Where-Object { $_.Name -match 'license' } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $runtime -Force
    }
    if (-not $NoShortcuts) {
        $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Keyboard Controller'
        New-Item -ItemType Directory -Path $menu -Force | Out-Null
        $shell = New-Object -ComObject WScript.Shell
        foreach ($item in @(@('Keyboard Controller','main.ahk'), @('Setup','tools\setup.ahk'), @('Recover','recover.ahk'))) {
            $link = $shell.CreateShortcut((Join-Path $menu ($item[0] + '.lnk')))
            $link.TargetPath = Join-Path $runtime 'AutoHotkey64.exe'
            $link.Arguments = '"' + (Join-Path $InstallDirectory $item[1]) + '"'
            $link.WorkingDirectory = $InstallDirectory
            $link.Save()
        }
    }
    Write-Host "Installed: $InstallDirectory"
    Write-Host 'Existing config.ini and logs are preserved. No driver has been installed or input blocked.'
    if (-not $NoLaunch) {
        Start-Process -FilePath (Join-Path $runtime 'AutoHotkey64.exe') -ArgumentList ('"' + (Join-Path $InstallDirectory 'tools\setup.ahk') + '"')
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
