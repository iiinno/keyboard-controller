#Requires -Version 7.0
param([long]$WindowHandle, [string]$OutputPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PanelCapture {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr dc, uint flags);
}
'@
[PanelCapture]::SetProcessDPIAware() | Out-Null
$rect = [PanelCapture+RECT]::new()
if (-not [PanelCapture]::GetWindowRect([IntPtr]$WindowHandle, [ref]$rect)) { throw 'Window bounds unavailable' }
$bitmap = [Drawing.Bitmap]::new($rect.Right - $rect.Left, $rect.Bottom - $rect.Top)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
try {
    $dc = $graphics.GetHdc()
    try {
        if (-not [PanelCapture]::PrintWindow([IntPtr]$WindowHandle, $dc, 2)) { throw 'PrintWindow failed' }
    } finally { $graphics.ReleaseHdc($dc) }
    $bitmap.Save($OutputPath, [Drawing.Imaging.ImageFormat]::Png)
} finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}
