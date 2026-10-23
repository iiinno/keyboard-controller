#Requires -Version 7.0
param([string]$DownloadCache = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('keyboard-controller-install-test-' + [guid]::NewGuid())
$target = Join-Path $work 'program with spaces'
$process = $null
New-Item -ItemType Directory -Path $target -Force | Out-Null
try {
    $config = Join-Path $target 'config.ini'
    [IO.File]::WriteAllText($config, 'machine-specific configuration')
    & (Join-Path $root 'scripts\package-windows.ps1')
    $expanded = Join-Path $work 'expanded'
    Expand-Archive -LiteralPath (Join-Path $root 'dist\keyboard-controller-windows-x64.zip') -DestinationPath $expanded
    $menu = Join-Path $work 'menu with spaces'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $expanded 'install.ps1'), '-SourceRoot', $expanded, '-InstallDirectory', $target, '-ShortcutDirectory', $menu, '-NoLaunch')
    if ($DownloadCache) { $arguments += @('-DownloadCache', $DownloadCache) }
    & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell 5.1 installation failed' }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $menu 'Setup.lnk'))
    if ($shortcut.TargetPath -ne (Join-Path $target '.runtime\AutoHotkey64.exe') -or -not $shortcut.Arguments.Contains('tools\setup.ahk')) { throw 'Incorrect setup shortcut' }
    if ([IO.File]::ReadAllText($config) -ne 'machine-specific configuration') { throw 'Existing config changed' }
    $ahk = Join-Path $target '.runtime\AutoHotkey64.exe'
    if (-not (Test-Path -LiteralPath $ahk) -or -not (Test-Path -LiteralPath (Join-Path $target 'lib\interception.dll'))) { throw 'Missing runtime dependency' }
    if (-not (Test-Path -LiteralPath (Join-Path $target '.runtime\interception\command line installer\install-interception.exe'))) { throw 'Missing driver installer' }
    $main = Join-Path $target 'main.ahk'
    $before = (Get-FileHash -LiteralPath $main).Hash
    $lock = [IO.File]::Open($ahk, 'Open', 'Read', 'None')
    try {
        $rejected = $false
        try { & (Join-Path $expanded 'install.ps1') -SourceRoot $expanded -InstallDirectory $target -NoLaunch -NoShortcuts }
        catch { $rejected = $_.Exception.Message -match 'still in use' }
        if (-not $rejected) { throw 'Locked runtime was not rejected' }
        if ((Get-FileHash -LiteralPath $main).Hash -ne $before) { throw 'Code changed during rejected update' }
    } finally { $lock.Dispose() }
    # Launch only the setup UI. Its startup path never opens/grabs a keyboard.
    $process = Start-Process -FilePath $ahk -ArgumentList ('"' + (Join-Path $target 'tools\setup.ahk') + '"') -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do { Start-Sleep -Milliseconds 50; $process.Refresh() } while (-not $process.MainWindowHandle -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline)
    if (-not $process.MainWindowHandle) { throw 'Setup window did not open' }
    $preview = Join-Path $work 'wizard.png'
    & (Join-Path $PSScriptRoot 'capture-panel.ps1') -WindowHandle $process.MainWindowHandle -OutputPath $preview
    Write-Host ('WIZARD_PREVIEW_BASE64:' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($preview)))
    Write-Host 'PASS: Windows package, verified dependency download, config preservation, locked-update rejection, and native setup UI'
} finally {
    if ($process -and -not $process.HasExited) {
        $process.CloseMainWindow() | Out-Null
        if (-not $process.WaitForExit(3000)) { $process.Kill($true); $process.WaitForExit() }
    }
    Remove-Item -LiteralPath $work -Recurse -Force
}
