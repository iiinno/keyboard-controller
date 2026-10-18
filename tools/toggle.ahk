#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#SingleInstance Off

; Launch from a device app's "Open application/file" action, not a key mapping.
; Notify the running controller directly; no keyboard events or file IPC.
DetectHiddenWindows(true)
root := RegExReplace(A_ScriptDir, "i)\\tools$")
controller := root "\main.ahk - AutoHotkey v ahk_class AutoHotkey"
hwnd := WinExist(controller)
if !hwnd {
    TrayTip("Controller is not running. Start main.ahk first.", "Laptop Keyboard", 0x1)
    ExitApp(1)
}
if !DllCall("PostMessageW", "ptr", hwnd, "uint", 0x8005, "uptr", 0, "uptr", 0, "int") {
    TrayTip("Could not send the mode-change request.", "Laptop Keyboard", 0x1)
    ExitApp(1)
}
