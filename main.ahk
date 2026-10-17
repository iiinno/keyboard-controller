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

G := { LogPath: "" }

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
        DetectErrors: 0,
        SettleUntil: G.Cfg.SettleMs ? A_TickCount + G.Cfg.SettleMs : 0,
        LastTick: A_TickCount,
        LastLoggedTarget: ""
    }

    ; The log is appended across restarts and only rotated by the size cap in Log, so a
    ; previous session's failure is still readable after a restart.
    OnExit(OnScriptExit)
    Log("INFO", "App started, pid " ProcessExist())

    ; Nothing is filtered yet. Record the fail-open startup state explicitly.
    Log("INFO", "Internal keyboard PASS (startup default)")

    BuildTray()
    RegisterHotkey()

    ; Start polling, but do not block until SettleUntil has passed. This keeps startup
    ; and resume on one timer path.
    SetTimer(PollTick, G.Cfg.PollMs)
    OnMessage(0x218, OnPowerBroadcast)
}

; ---------------------------------------------------------------------------
; device identification
; ---------------------------------------------------------------------------

PrepareBlock() {
    global G

    try {
        Interception.Open()
        devices := Interception.ListKeyboards()
        for device in devices
            Log("INFO", "Interception keyboard " device.id ": " device.hardwareId)
        internal := SelectInternalKeyboard(G.Cfg, devices)
    } catch as e {
        EnterFault("cannot prepare built-in keyboard block: " e.Message)
        return false
    }

    G.State.InternalDeviceId := internal.id
    Log("INFO", Format("Built-in keyboard is Interception device {1}: {2}", internal.id, internal.hardwareId))
    return true
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
    return (mode = "AUTO" && link = "CONNECTED" && health = "OK") ? "BLOCKED" : "PASS"
}

Reconcile(reason) {
    global G

    desired := G.State.SettleUntil ? "PASS" : DecideInternalState(G.State.Mode, G.State.Link, G.State.Health)
    if (desired = G.State.Applied)
        return
    ApplyState(desired, reason)
}

ApplyState(target, reason) {
    global G

    try {
        if (target = "BLOCKED") {
            if !PrepareBlock()
                return
            Interception.BlockDevice(G.State.InternalDeviceId)
            SetTimer(DrainInternal, G.Cfg.DrainMs)
        } else {
            ; Empty the queue, then destroy the whole Interception context. The public
            ; API does not report DeviceIoControl success for filter changes, so an
            ; unverifiable get_filter(0) is not used as a release proof.
            if (G.State.InternalDeviceId != 0 && Interception.IsOpen())
                Interception.Drain(G.State.InternalDeviceId)
            if !Interception.Close()
                throw Error("the Interception context could not be destroyed")
            SetTimer(DrainInternal, 0)
            G.State.InternalDeviceId := 0
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

; Fail-open exit for every unrecoverable problem. Release destroys the Interception
; context so this controller no longer holds device handles. PASS is controller state,
; not an independent physical-input test.
EnterFault(reason) {
    global G

    firstFault := (G.State.Health != "FAULT")
    G.State.Health := "FAULT"
    G.State.FaultReason := reason
    if firstFault
        Log("ERROR", "FAULT: " reason)

    released := Interception.Close()
    SetTimer(DrainInternal, 0)
    G.State.InternalDeviceId := 0
    G.State.Applied := released ? "PASS" : "UNKNOWN"

    if firstFault {
        if !released
            Log("ERROR", "the Interception context could not be destroyed. Restart this script, or run "
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

    ; -1 means a suspend notification was received and resume has not been observed yet.
    if (G.State.SettleUntil < 0)
        return
    if (G.State.SettleUntil && now < G.State.SettleUntil)
        return
    if (G.State.SettleUntil > 0)
        G.State.SettleUntil := 0

    RefreshExternal()
    Reconcile("poll")
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
    G.State.SettleUntil := G.Cfg.SettleMs ? A_TickCount + G.Cfg.SettleMs : 0
    UpdateTray()
}

OnPowerBroadcast(wParam, lParam, msg, hwnd) {
    global G

    switch wParam {
        case 0x04:  ; PBT_APMSUSPEND
            Log("INFO", "Suspend")
            G.State.SettleUntil := -1
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
        ? "Built-in keyboard blocked" : "Built-in keyboard PASS")
}

; Tray action, and the manual recovery path for a failed identification: retry the
; whole device lookup before evaluating.
RefreshNow(*) {
    global G

    if (G.State.Health != "OK") {
        G.State.Health := "OK"
        G.State.FaultReason := ""
        G.State.InternalDeviceId := 0
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
    released := Interception.Close()
    if released
        Log("ERROR", "exiting after an unhandled error; Interception context destroyed")
    else
        Log("ERROR", "exiting after an unhandled error, and the Interception context could not be destroyed. "
            . "Run recover.ahk or reboot to be sure the built-in keyboard is free.")
    Notify("Laptop Keyboard: error", err.Message)
    ExitApp(1)
}

OnScriptExit(reason, code) {
    global G

    Log("INFO", "App exiting (" reason ")")

    released := Interception.Close()
    if released
        Log("INFO", "Internal keyboard PASS (Interception context destroyed on exit)")
    else
        Log("ERROR", "the Interception context could not be destroyed on exit. "
            . "Run recover.ahk or reboot to be sure the built-in keyboard is free.")

    return 0
}
