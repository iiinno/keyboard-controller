#Requires -Version 7.0
param(
    [Parameter(Mandatory)]
    [string]$AutoHotkey
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$AutoHotkey = (Resolve-Path -LiteralPath $AutoHotkey).Path
$repoRoot = Split-Path -Parent $PSScriptRoot
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('keyboard-controller-tests-' + [guid]::NewGuid())

function Invoke-Ahk([string[]]$AhkArguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($AutoHotkey)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.ArgumentList.Add('/ErrorStdOut=UTF-8')
    foreach ($arg in $AhkArguments) { $info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) {
            $process.Kill($true)
            throw 'AutoHotkey test exceeded 15 seconds'
        }
        Write-Host $stdout.GetAwaiter().GetResult()
        Write-Host $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "AutoHotkey exited with code $($process.ExitCode)" }
    } finally {
        $process.Dispose()
    }
}

New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    # /Validate parses the real entry points without running startup or blocking input.
    $entries = @('main.ahk', 'recover.ahk') + @(Get-ChildItem (Join-Path $repoRoot 'tools') -Filter '*.ahk' | ForEach-Object { 'tools\' + $_.Name })
    foreach ($entry in $entries) {
        Write-Host "Validate: $entry"
        Invoke-Ahk @('/Validate', (Join-Path $repoRoot $entry))
    }
    Invoke-Ahk @((Join-Path $PSScriptRoot 'unit.ahk'))

    # Extract just the production Release() body. Including the whole tool would
    # run its top-level keyboard-blocking code, which must never happen in CI.
    $source = Get-Content -LiteralPath (Join-Path $repoRoot 'tools\block-test.ahk') -Raw
    $release = [regex]::Matches($source, '(?ms)^Release\(\) \{\r?\n.*?^\}')
    if ($release.Count -ne 1) { throw 'Expected exactly one top-level Release() function' }
    $releasePath = Join-Path $tempDir 'Release.ahk'
    [IO.File]::WriteAllText($releasePath, $release[0].Value, [Text.UTF8Encoding]::new($false))
    Invoke-Ahk @('/include', $releasePath, (Join-Path $PSScriptRoot 'block-test-release.ahk'))

    # Include controller functions without startup, logging, or driver actuation.
    $controller = Get-Content -LiteralPath (Join-Path $repoRoot 'main.ahk') -Raw
    $names = @('Reconcile', 'PollTick', 'HandleResume', 'OnPowerBroadcast',
        'ToggleMode', 'OnToggleRequest', 'SetMode', 'TemporarilyEnable',
        'RefreshNow', 'BuildTray', 'OnTrayIcon', 'UpdateTray')
    $functions = foreach ($name in $names) {
        $matches = [regex]::Matches($controller, "(?ms)^$name\([^\r\n]*\) \{\r?\n.*?^\}")
        if ($matches.Count -ne 1) { throw "Expected exactly one top-level $name() function" }
        $matches[0].Value
    }
    $controllerPath = Join-Path $tempDir 'Controller.ahk'
    [IO.File]::WriteAllText($controllerPath, ($functions -join "`n`n"), [Text.UTF8Encoding]::new($false))
    $previewPath = Join-Path $tempDir 'panel.png'
    Invoke-Ahk @('/include', $controllerPath, (Join-Path $PSScriptRoot 'controller.ahk'), $previewPath)
    if (-not (Test-Path -LiteralPath $previewPath)) { throw 'Native panel preview was not captured' }
    Write-Host ('PANEL_PREVIEW_BASE64:' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($previewPath)))
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}
