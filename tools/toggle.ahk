#Requires AutoHotkey v2.0
; Asks the running controller to switch between AUTO and FORCED_ON.
;
; Bind this to a key on the external keyboard, for example through the Logi Options+
; app. Only that keyboard's key triggers it, so the built-in keyboard's version of the
; same key does nothing.
;
; The mode and the Interception filter both live inside main.ahk, and a filter belongs
; to the handle that set it, so this process cannot change them directly. It leaves a
; request file that main.ahk consumes. If the controller is not running, this says so
; rather than appearing to do nothing.

#NoTrayIcon
#SingleInstance Force
#Warn All, Off

ControllerIsRunning(pidPath) {
    if !FileExist(pidPath)
        return false
    try {
        pidText := Trim(FileRead(pidPath))
        return IsInteger(pidText) && ProcessExist(Integer(pidText))
    } catch {
        return false
    }
}

; This file lives in tools\, so two path segments up is the project root.
root := RegExReplace(A_LineFile, "\\[^\\]*\\[^\\]*$")
requestPath := root "\logs\toggle.request"
pidPath := root "\logs\controller.pid"

; A leftover request would be consumed as if it were this one.
try {
    FileDelete(requestPath)
} catch {
}

try {
    FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "`n", requestPath, "UTF-8")
} catch as e {
    TrayTip("Could not write the mode request.`n" e.Message, "Laptop Keyboard", 0x1)
    ExitApp(1)
}

; main.ahk deletes the file when it handles the request.
handled := false
loop 24 {
    Sleep(50)
    if !FileExist(requestPath) {
        handled := true
        break
    }
}

if !handled {
    try {
        FileDelete(requestPath)
    } catch {
    }
    running := ControllerIsRunning(pidPath)
    detail := running
        ? "The controller is running but did not answer. Check logs\controller.log."
        : "The controller is not running. Start main.ahk, or set it to start at logon."
    TrayTip("The mode did not change.`n" detail, "Laptop Keyboard", 0x1)
}

ExitApp(0)
