#Requires AutoHotkey v2.0 64-bit

; A modal warning or error dialog would freeze this process while it is holding a
; block, leaving the built-in keyboard unusable until the dialog is dismissed. This
; directive must come before the includes so that it also covers their code. Real
; errors are handled by OnError in Main instead.
#Warn All, Off

#SingleInstance Force
#Include lib\Config.ahk
#Include lib\Devices.ahk

; Laptop internal keyboard auto-block controller.
;
; Blocks input from the built-in keyboard only when all three hold:
;   the external Bluetooth keyboard is attached, the mode is AUTO, and this process
;   is healthy.
; Every other outcome, including every error and every unknown state, leaves the
; built-in keyboard usable. The built-in keyboard is never disabled at the PnP level,
; so it always comes back once this process stops filtering.
;
; Run tools\block-test.ahk first. It blocks for a few seconds and releases by itself,
; which proves the release path before the persistent controller is trusted.

G := { LogPath: "", PidPath: "" }

Main()

; ---------------------------------------------------------------------------
; startup
; ---------------------------------------------------------------------------

Main() {
    global G

    ; Any unhandled error means the process state is unknown. Log it, release the
    ; built-in keyboard, and exit rather than keep running in the dark.
    OnError(OnUnhandledError)

    Persistent()

    G.LogPath := A_ScriptDir "\logs\controller.log"
    G.PidPath := A_ScriptDir "\logs\controller.pid"
    ; tools\toggle.ahk leaves this file to ask for a mode change. The mode and the
    ; Interception filter both live in this process, and a filter is per handle, so
    ; another process cannot flip them by itself.
    G.RequestPath := A_ScriptDir "\logs\toggle.request"
    DirCreate(A_ScriptDir "\logs")

    try {
        G.Cfg := LoadConfig(A_ScriptDir "\config.ini")
    } catch as e {
        Log("ERROR", "config.ini could not be loaded: " e.Message)
        MsgBox("keyboard-controller cannot start.`n`n" e.Message, "Laptop Keyboard Controller", "Icon!")
        ExitApp(1)
    }

    G.State := {
        Mode: G.Cfg.StartMode,
        Link: "UNKNOWN",
        Applied: "PASS",
        Health: "OK",
        FaultReason: "",
        InternalDeviceId: 0,
        InternalHardwareId: "",
        DetectErrors: 0,
        LastTick: A_TickCount,
        LastLoggedTarget: ""
    }

    ; The log is appended across restarts and only rotated by the size cap in Log, so a
    ; previous session's failure is still readable after a restart.
    OnExit(OnScriptExit)
    if FileExist(G.PidPath)
        FileDelete(G.PidPath)
    FileAppend(ProcessExist(), G.PidPath)

    Log("INFO", "App started, pid " ProcessExist())

    ; Nothing is filtered yet. Record the fail-open startup state explicitly.
    Log("INFO", "Internal keyboard PASS (startup default)")

    InitInterception()
    BuildTray()
    RegisterHotkey()

    ; Devices are still enumerating at logon, so the first real evaluation waits.
    ; A period of 0 disables a timer, hence the floor of 1 ms.
    SetTimer(InitialEvaluate, -Max(G.Cfg.SettleMs, 1))
    SetTimer(PollTick, G.Cfg.PollMs)
    ; Short interval so a key bound through Logi Options+ feels immediate.
    SetTimer(ToggleRequestTick, 150)
    OnMessage(0x218, OnPowerBroadcast)
}

; ---------------------------------------------------------------------------
; device identification
; ---------------------------------------------------------------------------

InitInterception() {
    global G

    try {
        Interception.Open()
    } catch as e {
        EnterFault("Interception unavailable: " e.Message)
        return
    }

    devices := []
    try {
        devices := Interception.ListKeyboards()
    } catch as e {
        EnterFault("could not list keyboards: " e.Message)
        return
    }

    for device in devices
        Log("INFO", "Interception keyboard " device.id ": " device.hardwareId)

    try {
        internal := SelectInternalKeyboard(G.Cfg, devices)
    } catch as e {
        EnterFault(e.Message)
        return
    }

    G.State.InternalDeviceId := internal.id
    G.State.InternalHardwareId := internal.hardwareId
    Log("INFO", Format("Built-in keyboard is Interception device {1}: {2}", internal.id, internal.hardwareId))
}

; Sets State.Link from the present-device list. Any failure leaves the link unknown,
; which the decision function treats as not connected.
RefreshExternal() {
    global G

    try {
        present := ExternalKeyboardPresent(G.Cfg)
        G.State.ExternalPresent := present
        G.State.Link := present ? "CONNECTED" : "DISCONNECTED"
        G.State.DetectErrors := 0
    } catch as e {
        G.State.Link := "UNKNOWN"
        G.State.DetectErrors += 1
        if (G.State.DetectErrors = 3)
            Log("WARN", "external keyboard detection is failing: " e.Message)
    }
}

; ---------------------------------------------------------------------------
; decision and application
; ---------------------------------------------------------------------------

; The single place that decides whether the built-in keyboard may be blocked. Pure,
; so it can be read as the whole rule. Anything not positively known to be safe to
; block resolves to PASS, which is the fail-open requirement written as code.
DecideInternalState(mode, link, health) {
    if (health != "OK")
        return "PASS"
    if (mode = "FORCED_ON")
        return "PASS"
    if (link = "CONNECTED")
        return "BLOCKED"
    return "PASS"
}

Reconcile(reason) {
    global G

    desired := DecideInternalState(G.State.Mode, G.State.Link, G.State.Health)
    if (desired = G.State.Applied)
        return
    ApplyState(desired, reason)
}

ApplyState(target, reason) {
    global G

    try {
        if (target = "BLOCKED") {
            if (G.State.InternalDeviceId = 0)
                throw Error("built-in keyboard was never identified")
            Interception.BlockDevice(G.State.InternalDeviceId)
            SetTimer(DrainInternal, G.Cfg.DrainMs)
        } else {
            ; Empty the queue before lifting the filter, so nothing stale is left for
            ; the driver to hand back later.
            if (G.State.InternalDeviceId != 0)
                Interception.Drain(G.State.InternalDeviceId)
            ; A clear that cannot be confirmed must not be recorded as PASS.
            if !Interception.ClearAll()
                throw Error("the Interception filter could not be cleared")
            SetTimer(DrainInternal, 0)
        }
    } catch as e {
        G.State.Applied := "UNKNOWN"
        G.State.LastLoggedTarget := ""
        EnterFault("failed to switch the built-in keyboard to " target ": " e.Message)
        return
    }

    G.State.Applied := target
    if (target != G.State.LastLoggedTarget) {
        G.State.LastLoggedTarget := target
        Log("INFO", Format("Internal keyboard {1} (mode={2}, external={3}, reason={4})"
            , (target = "BLOCKED") ? "BLOCK" : "PASS", G.State.Mode, G.State.Link, reason))
    }
    UpdateTray()
}

; Fail-open exit for every unrecoverable problem. Drops every filter this context
; holds, on every keyboard slot, then reports. Applied becomes PASS only when the
; clear is confirmed, and UNKNOWN otherwise, so the log and the tray never claim the
; keyboard is free when that is unproven.
EnterFault(reason) {
    global G

    firstFault := (G.State.Health != "FAULT")
    G.State.Health := "FAULT"
    G.State.FaultReason := reason
    if firstFault
        Log("ERROR", "FAULT: " reason)

    cleared := Interception.ClearAll()
    SetTimer(DrainInternal, 0)
    G.State.Applied := cleared ? "PASS" : "UNKNOWN"

    if firstFault {
        if !cleared
            Log("ERROR", "the Interception filter could not be cleared. Restart this script, or run "
                . "recover.ahk, to be sure the built-in keyboard is free.")
        UpdateTray()
        Notify("Laptop Keyboard: FAULT", reason)
    }
}

DrainInternal() {
    global G

    if (G.State.Applied != "BLOCKED" || G.State.InternalDeviceId = 0)
        return
    try {
        Interception.Drain(G.State.InternalDeviceId)
    } catch as e {
        EnterFault("could not drain the built-in keyboard queue: " e.Message)
    }
}

; ---------------------------------------------------------------------------
; timers and power events
; ---------------------------------------------------------------------------

PollTick() {
    global G

    now := A_TickCount
    gap := now - G.State.LastTick
    G.State.LastTick := now

    ; A missed power message still shows up as a long timer gap. Treat it as a resume
    ; rather than trusting the state the machine was in before it slept.
    if (gap > G.Cfg.PollMs * G.Cfg.ResumeGapFactor + 5000) {
        Log("INFO", Format("timer gap of {1} ms, treating as resume", gap))
        HandleResume()
        return
    }

    RefreshExternal()
    Reconcile("poll")
}

InitialEvaluate() {
    global G

    RefreshExternal()
    Reconcile("startup")
    UpdateTray()
}

; Do not trust a pre-sleep block after resume. Release first, wait for the device
; tree to settle, then evaluate again from current device state.
HandleResume() {
    global G

    Log("INFO", "Resume detected, releasing the built-in keyboard first")
    if (G.State.Applied = "BLOCKED")
        ApplyState("PASS", "resume")
    G.State.Link := "UNKNOWN"
    Reconcile("resume-pass")
    SetTimer(ResumeSettle, -Max(G.Cfg.SettleMs, 1))
}

ResumeSettle() {
    global G

    RefreshExternal()
    Reconcile("resume-settled")
    UpdateTray()
}

OnPowerBroadcast(wParam, lParam, msg, hwnd) {
    global G

    switch wParam {
        case 0x04:  ; PBT_APMSUSPEND
            Log("INFO", "Suspend")
            if (G.State.Applied = "BLOCKED")
                ApplyState("PASS", "suspend")
        case 0x07, 0x12:  ; PBT_APMRESUMESUSPEND, PBT_APMRESUMEAUTOMATIC
            HandleResume()
    }
    return 0
}

; ---------------------------------------------------------------------------
; mode control
; ---------------------------------------------------------------------------

ToggleMode(*) {
    global G

    SetMode(G.State.Mode = "AUTO" ? "FORCED_ON" : "AUTO")
}

; Consumes a mode-change request left by tools\toggle.ahk, which is what a key bound
; through Logi Options+ launches. Deleting the file is also the acknowledgement the
; launcher waits for, so a missing controller gets reported instead of passing silently.
ToggleRequestTick() {
    global G

    if !FileExist(G.RequestPath)
        return
    try {
        FileDelete(G.RequestPath)
    } catch {
    }
    ToggleMode()
}

SetMode(mode) {
    global G

    if (G.State.Mode = mode)
        return
    G.State.Mode := mode
    Log("INFO", "Mode=" mode)
    RefreshExternal()
    Reconcile("mode-change")
    UpdateTray()
    Notify("Laptop Keyboard: " mode, G.State.Applied = "BLOCKED"
        ? "Built-in keyboard blocked" : "Built-in keyboard usable")
}

; Tray action, and the manual recovery path for a failed identification: retry the
; whole device lookup before evaluating.
RefreshNow(*) {
    global G

    if (G.State.Health != "OK") {
        G.State.Health := "OK"
        G.State.FaultReason := ""
        G.State.InternalDeviceId := 0
        G.State.InternalHardwareId := ""
        InitInterception()
    }
    G.State.LastTick := A_TickCount
    RefreshExternal()
    Reconcile("manual-refresh")
    UpdateTray()
}

RegisterHotkey() {
    global G

    try {
        Hotkey(G.Cfg.ToggleHotkey, ToggleMode)
        Log("INFO", "Toggle hotkey registered: " G.Cfg.ToggleHotkey)
    } catch as e {
        Log("ERROR", "hotkey '" G.Cfg.ToggleHotkey "' could not be registered: " e.Message)
        Notify("Laptop Keyboard: hotkey failed", G.Cfg.ToggleHotkey " could not be registered. Use the tray menu.")
    }
}

; ---------------------------------------------------------------------------
; tray and notification
; ---------------------------------------------------------------------------

BuildTray() {
    UpdateTray()
}

UpdateTray() {
    global G

    ; Reported as recorded, so UNKNOWN is never shown as PASS.
    internal := G.State.Applied
    external := G.State.Link
    health := G.State.Health

    A_IconTip := Format("Laptop Keyboard Controller`nMode: {1}`nInternal: {2}`nExternal: {3}`nHealth: {4}"
        , G.State.Mode, internal, external, health)

    status := ["Mode: " G.State.Mode, "Internal Keyboard: " internal
        , "External Keyboard: " external, "Health: " health]

    A_TrayMenu.Delete()
    for line in status {
        A_TrayMenu.Add(line, Noop)
        A_TrayMenu.Disable(line)
    }
    A_TrayMenu.Add()
    A_TrayMenu.Add("Switch to AUTO", (*) => SetMode("AUTO"))
    A_TrayMenu.Add("Force Internal Keyboard ON", (*) => SetMode("FORCED_ON"))
    A_TrayMenu.Add("Refresh Devices", RefreshNow)
    A_TrayMenu.Add("Open Log", OpenLog)
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => ExitApp())
}

Noop(*) {
}

OpenLog(*) {
    global G

    if FileExist(G.LogPath)
        Run(G.LogPath)
}

Notify(title, text) {
    try {
        TrayTip(text, title, 0x1)
    }
}

; ---------------------------------------------------------------------------
; logging
; ---------------------------------------------------------------------------

Log(level, message) {
    global G

    if (G.LogPath = "")
        return
    try {
        ; The config may have failed to load, so do not depend on it here.
        limitKb := G.HasProp("Cfg") ? G.Cfg.MaxLogKb : 256
        if (FileExist(G.LogPath) && FileGetSize(G.LogPath) > limitKb * 1024)
            RotateLog()
        FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") " " level " " message "`r`n", G.LogPath, "UTF-8")
    }
}

RotateLog() {
    global G

    try {
        if !FileExist(G.LogPath)
            return
        backup := G.LogPath ".1"
        if FileExist(backup)
            FileDelete(backup)
        FileMove(G.LogPath, backup)
    }
}

; ---------------------------------------------------------------------------
; shutdown
; ---------------------------------------------------------------------------

OnUnhandledError(err, mode) {
    global G

    Log("ERROR", Format("unhandled error (mode={1}): {2} at {3} line {4}"
        , mode, err.Message, err.File, err.Line))
    cleared := Interception.ClearAll()
    try {
        Interception.Close()
    }
    if cleared
        Log("ERROR", "exiting after an unhandled error; internal keyboard confirmed usable")
    else
        Log("ERROR", "exiting after an unhandled error, and the Interception filter could not be cleared. "
            . "Run recover.ahk or reboot to be sure the built-in keyboard is free.")
    Notify("Laptop Keyboard: error", err.Message)
    ExitApp(1)
}

OnScriptExit(reason, code) {
    global G

    Log("INFO", "App exiting (" reason ")")

    cleared := Interception.ClearAll()
    try {
        Interception.Close()
    }
    if cleared
        Log("INFO", "Internal keyboard PASS (exit)")
    else
        Log("ERROR", "the Interception filter could not be cleared on exit. "
            . "Run recover.ahk or reboot to be sure the built-in keyboard is free.")

    try {
        if FileExist(G.PidPath)
            FileDelete(G.PidPath)
    }
    return 0
}
