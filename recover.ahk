#Requires AutoHotkey v2.0 64-bit
#Warn All, Off
#Include lib\Interception.ahk

; Emergency recovery. Ask a running controller to exit cleanly, then issue a
; best-effort filter clear from a fresh Interception context. If input is still stuck,
; reboot Windows.

reported := []

DetectHiddenWindows(true)
controllerTitle := A_ScriptDir "\main.ahk - AutoHotkey v ahk_class AutoHotkey"
if hwnd := WinExist(controllerTitle) {
    pid := WinGetPID("ahk_id " hwnd)
    try {
        WinClose("ahk_id " hwnd)
        if WinWaitClose("ahk_id " hwnd, , 2) {
            reported.Push("Closed the running controller.")
        } else if ProcessExist(pid) {
            ProcessClose(pid)
            reported.Push("Stopped the unresponsive controller.")
        }
    } catch as e {
        reported.Push("Could not stop the running controller: " e.Message)
    }
}

try {
    Interception.Open()
    reported.Push("Opened a fresh Interception context for recovery.")
} catch as e {
    reported.Push("Could not reach Interception: " e.Message)
} finally {
    Interception.Close()
}

reported.Push("")
reported.Push("Try the built-in keyboard now. If it still does not respond, reboot Windows.")

text := ""
for line in reported
    text .= line "`n"

MsgBox(text, "Laptop Keyboard Controller recovery")
