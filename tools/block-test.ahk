#Requires AutoHotkey v2.0 64-bit
; A second copy would hold a second block. Force replaces the first instead.
#SingleInstance Force
; A native tray menu pauses SetTimer and could extend the eight-second block.
#NoTrayIcon

; A modal warning dialog would freeze this test while it holds a block, which is the
; one moment it must not stall. This directive must come before the includes so that
; it also covers their code.
#Warn All, Off

#Include ..\lib\Config.ahk
#Include ..\lib\Devices.ahk

; Blocks the built-in keyboard for a fixed number of seconds, then
; releases it unconditionally. Run this before main.ahk, so the release path is proven
; before anything persistent is trusted.
;
; What to check while the countdown runs:
;   - typing on the built-in keyboard produces nothing
;   - typing on the external keyboard still works normally
;   - the touchpad and mouse still work
;   - the built-in keyboard works again immediately after the countdown
;
; Release runs at the end of the countdown and again from OnExit, so closing this
; script early still frees the keyboard.

Seconds := 8

Cfg := LoadConfig(A_ScriptDir "\..\config.ini")
LogPath := A_ScriptDir "\..\logs\block-test.log"
InternalId := 0
Remaining := Seconds
Released := false

DirCreate(A_ScriptDir "\..\logs")

Log(message) {
    global LogPath
    try
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " " message "`r`n", LogPath, "UTF-8")
}

Release() {
    global Released
    if Released
        return true
    SetTimer(Drain, 0)
    closeSucceeded := Interception.Close()
    ; AutoHotkey variable names are case-insensitive: `released` would overwrite
    ; the global Released flag. Mark completion only after a successful close so
    ; OnExit can retry when context destruction failed.
    Released := closeSucceeded
    if closeSucceeded
        Log("Release requested: Interception context destroyed")
    else
        Log("ERROR: Interception context could not be destroyed. Reboot if the built-in keyboard is not responsive.")
    return closeSucceeded
}

Drain() {
    global InternalId
    try
        Interception.Drain(InternalId)
}

Tick() {
    global Remaining
    Remaining -= 1
    if (Remaining > 0) {
        ToolTip("block-test: built-in keyboard BLOCKED, " Remaining " s left")
        return
    }
    SetTimer(Tick, 0)
    ToolTip()
    released := Release()
    Log("Countdown finished")
    message := released
        ? "Done. The Interception context was destroyed. Test the built-in keyboard now.`n`nLog: " LogPath
        : "The Interception context could not be destroyed. Use recover.ahk or reboot if the keyboard does not respond.`n`nLog: " LogPath
    MsgBox(message, "block-test")
    ExitApp(released ? 0 : 1)
}

OnBlockTestError(err, mode) {
    ToolTip()
    Log(Format("ERROR: unhandled error (mode={1}): {2} at {3} line {4}"
        , mode, err.Message, err.File, err.Line))
    Release()
    MsgBox("block-test stopped after an error. If the built-in keyboard does not respond, run recover.ahk or reboot.`n`n" err.Message
        , "block-test", "Icon!")
    ExitApp(1)
}

OnBlockTestExit(reason, code) {
    Release()
    return 0
}

OnError(OnBlockTestError)
OnExit(OnBlockTestExit)

try {
    Interception.Open()
    devices := Interception.ListKeyboards()
    for device in devices
        Log("Interception keyboard " device.id ": " device.hardwareId)
    internal := SelectInternalKeyboard(Cfg, devices)
    InternalId := internal.id
} catch as e {
    Log("ABORT: " e.Message)
    MsgBox("block-test cannot run.`n`n" e.Message, "block-test", "Icon!")
    ExitApp(1)
}

Log("Blocking Interception device " InternalId " (" internal.hardwareId ") for " Seconds " seconds")
Interception.BlockDevice(InternalId)
SetTimer(Drain, 10)
SetTimer(Tick, 1000)
ToolTip("block-test: built-in keyboard BLOCKED, " Remaining " s left")
