#Requires AutoHotkey v2.0 64-bit
#Warn All, Off
#Include lib\Interception.ahk

; Emergency recovery for a built-in keyboard that stayed blocked.
;
; Run this when main.ahk stopped responding or died while the built-in keyboard was
; blocked. It does two things, in order:
;   1. terminates a controller that is still running, which closes the handles that
;      carry its input filter;
;   2. clears the filter on every keyboard slot from a fresh context, which covers the
;      case where the driver keeps the filter per device rather than per handle.
;
; Neither step is guaranteed to be what releases the keyboard, because the driver is
; closed source. If the built-in keyboard still does not respond afterwards, reboot.
; Nothing here is persistent, so rebooting always restores normal input.

; A stale pid file plus pid reuse would otherwise make this kill an unrelated program,
; so the recorded process is only terminated when it really is AutoHotkey. Every
; AutoHotkey script owns a main window, hidden or not, so the process name is readable
; through it. Checked on the target machine: this returns "AutoHotkey64.exe".
IsAutoHotkeyProcess(pid) {
    DetectHiddenWindows(true)
    try {
        name := WinGetProcessName("ahk_pid " pid)
    } catch {
        return false
    }
    return InStr(StrLower(name), "autohotkey") = 1
}

reported := []

pidPath := A_ScriptDir "\logs\controller.pid"
if FileExist(pidPath) {
    pidText := Trim(FileRead(pidPath))
    if (pidText != "" && IsInteger(pidText) && ProcessExist(Integer(pidText))) {
        if IsAutoHotkeyProcess(Integer(pidText)) {
            ProcessClose(Integer(pidText))
            Sleep(400)
            reported.Push("Terminated the running controller (pid " pidText ").")
        } else {
            reported.Push("Pid " pidText " is running but is not AutoHotkey, so it was left alone. "
                . "If the controller is still running, end AutoHotkey64.exe in Task Manager.")
        }
    } else {
        reported.Push("No running controller was recorded.")
    }
} else {
    reported.Push("No controller pid file was found, so no controller was terminated.")
}

cleared := false
try {
    Interception.Open()
    cleared := Interception.ClearAll()
    Interception.Close()
} catch as e {
    reported.Push("Could not reach Interception: " e.Message)
}
if cleared
    reported.Push("Cleared the Interception filter on every keyboard slot.")

reported.Push("")
reported.Push("Try the built-in keyboard now. If it still does not respond, reboot.")

text := ""
for line in reported
    text .= line "`n"

MsgBox(text, "Laptop Keyboard Controller recovery")
