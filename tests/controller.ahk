#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include assert.ahk
#Include ..\lib\ControlPanel.ahk

; run.ps1 pre-includes the production state/tray functions, without Main().
; Only actuation and device enumeration are faked; no driver code is included.
G := {Cfg: {PollMs: 1000, SettleMs: 3000, ResumeGapFactor: 3}}
ExternalLink := "CONNECTED"
RefreshStates := []
LogsOpened := 0
HeartbeatCount := 0
ResetState()
BuildTray()

try {
    TestPolicy()
    TestTemporaryPass()
    TestModesAndFault()
    TestResume()
    TestPanel()
    ReportPass()
    G.Panel.Window.Destroy()
    ExitApp(0)
} catch as testFailure {
    FileAppend("FAIL: " testFailure.Message " (line " testFailure.Line ")`n", "**", "UTF-8")
    ExitApp(1)
}

ResetState() {
    global G, ExternalLink, RefreshStates
    ExternalLink := "CONNECTED"
    RefreshStates := []
    G.State := {Mode: "AUTO", Link: "CONNECTED", Applied: "PASS", Health: "OK"
        , FaultReason: "", InternalDeviceId: 0, SettleUntil: 0, PauseUntil: 0
        , LastTick: ControllerNow()}
}

TestPolicy() {
    AssertEqual(DecideInternalState("AUTO", "CONNECTED", "OK"), "BLOCKED", "healthy AUTO blocks")
    AssertEqual(DecideInternalState("FORCED_ON", "CONNECTED", "OK"), "PASS", "forced ON passes")
    AssertEqual(DecideInternalState("AUTO", "UNKNOWN", "OK"), "PASS", "unknown link passes")
    AssertEqual(DecideInternalState("AUTO", "DISCONNECTED", "OK"), "PASS", "disconnected passes")
    AssertEqual(DecideInternalState("AUTO", "CONNECTED", "FAULT"), "PASS", "fault passes")
    AssertEqual(DecideInternalState("AUTO", "CONNECTED", "OK", true), "PASS", "temporary ON passes")
    AssertEqual(PauseRemainingSeconds(0, 100), 0, "no pause")
    AssertEqual(PauseRemainingSeconds(99, 100), 0, "expired pause")
    AssertEqual(PauseRemainingSeconds(101, 100), 1, "partial seconds round up")
    AssertEqual(PauseRemainingSeconds(60100, 100), 60, "exact minute")
    AssertEqual(PauseRemainingSeconds(4294968296, 4294967296), 1, "64-bit uptime")
}

TestTemporaryPass() {
    global G, ExternalLink
    ResetState()
    Reconcile("test")
    AssertEqual(G.State.Applied, "BLOCKED", "initial block")
    before := ControllerNow()
    TemporarilyEnable(5)
    AssertEqual(G.State.Applied, "PASS", "temporary ON releases immediately")
    AssertEqual(G.State.PauseUntil >= before + 300000, true, "five-minute deadline")
    AssertEqual(G.State.PauseUntil <= ControllerNow() + 300000, true, "deadline bounded")
    Reconcile("test")
    AssertEqual(G.State.Applied, "PASS", "poll cannot reblock during pause")
    G.State.PauseUntil := ControllerNow() - 1
    PollTick()
    AssertEqual(G.State.PauseUntil, 0, "expired deadline cleared")
    AssertEqual(G.State.Applied, "BLOCKED", "connected AUTO resumes after expiry")

    TemporarilyEnable(15)
    AssertEqual(PauseRemainingSeconds(G.State.PauseUntil, ControllerNow()), 900, "fifteen-minute deadline")
    ExternalLink := "DISCONNECTED"
    G.State.PauseUntil := ControllerNow() - 1
    PollTick()
    AssertEqual(G.State.Applied, "PASS", "expiry refreshes the current disconnected link")

    AssertThrows(() => TemporarilyEnable(0), "1 to 60")
    AssertThrows(() => TemporarilyEnable(61), "1 to 60")
    AssertThrows(() => TemporarilyEnable(1.5), "1 to 60")
}

TestModesAndFault() {
    global G, RefreshStates
    ResetState()
    TemporarilyEnable(5)
    SetMode("AUTO")
    AssertEqual(G.State.PauseUntil, 0, "AUTO cancels pause even when mode is already AUTO")
    AssertEqual(G.State.Applied, "BLOCKED", "explicit AUTO reevaluates")
    SetMode("FORCED_ON")
    AssertEqual(G.State.Applied, "PASS", "forced ON releases")
    AssertEqual(RefreshStates[RefreshStates.Length], "PASS", "release precedes enumeration")
    TemporarilyEnable(5)
    AssertEqual(G.State.Mode, "AUTO", "timed ON returns to AUTO policy")
    ToggleMode()
    AssertEqual(G.State.Mode, "FORCED_ON", "existing toggle still works")
    AssertEqual(G.State.PauseUntil, 0, "toggle cancels countdown")

    G.State.Health := "FAULT"
    G.State.FaultReason := "injected failure"
    TemporarilyEnable(5)
    G.State.PauseUntil := ControllerNow() - 1
    PollTick()
    AssertEqual(G.State.Health, "FAULT", "temporary ON never clears a fault")
    AssertEqual(G.State.Applied, "PASS", "fault prevents reblock on expiry")

    previous := A_IsCritical
    Critical(7)
    try {
        Reconcile("test")
        AssertEqual(A_IsCritical, 7, "reconcile restores its caller's critical setting")
    } finally {
        Critical(previous)
    }
}

TestResume() {
    global G
    ResetState()
    TemporarilyEnable(5)
    deadline := G.State.PauseUntil
    OnPowerBroadcast(0x04, 0, 0x218, A_ScriptHwnd)
    AssertEqual(G.State.SettleUntil, -1, "suspend inhibits blocking")
    HandleResume()
    AssertEqual(G.State.PauseUntil, deadline, "resume keeps monotonic pause deadline")
    AssertEqual(G.State.SettleUntil > ControllerNow(), true, "resume settles first")
    Reconcile("test")
    AssertEqual(G.State.Applied, "PASS", "resume remains PASS")
    G.State.PauseUntil := ControllerNow() - 1
    PollTick()
    AssertEqual(G.State.Applied, "PASS", "expiry cannot bypass settling")
    G.State.SettleUntil := ControllerNow() - 1
    PollTick()
    AssertEqual(G.State.Applied, "BLOCKED", "settled resume reevaluates current link")
}

TestPanel() {
    global G, HeartbeatCount, LogsOpened
    ResetState()
    UpdateTray()
    AssertEqual(DllCall("GetMenuItemCount", "ptr", A_TrayMenu.Handle, "int"), 0, "no native tray menu")
    G.Panel.Hide()
    ; A real tray notification must show a modeless panel and return, rather than
    ; entering AutoHotkey's modal tray menu. No mouse or keyboard input is sent.
    OnMessage(0x404, OnTrayIcon)
    PostMessage(0x404, 0, 0x205, , "ahk_id " A_ScriptHwnd)
    Sleep(50)
    hwnd := G.Panel.Window.Hwnd
    AssertEqual(DllCall("IsWindowVisible", "ptr", hwnd, "int"), 1, "right tray click opens panel")
    SetTimer(Heartbeat, 10)
    try {
        Sleep(100)
        AssertEqual(HeartbeatCount > 0, true, "timers keep running with panel open")
        OnTrayIcon(0, 0x202, 0x404, A_ScriptHwnd)
        AssertEqual(G.Panel.Window.Hwnd, hwnd, "repeated clicks reuse one panel")
        ClickControl(G.Panel.Five)
        AssertEqual(G.State.Applied, "PASS", "native five-minute button releases")
        AssertEqual(InStr(G.Panel.Pause.Text, "5:00") > 0, true, "countdown is visible")
        ClickControl(G.Panel.Auto)
        AssertEqual(G.State.PauseUntil, 0, "native AUTO button cancels countdown")
        ClickControl(G.Panel.Forced)
        AssertEqual(G.State.Mode, "FORCED_ON", "native forced-ON button")
        ClickControl(G.Panel.Fifteen)
        AssertEqual(InStr(G.Panel.Pause.Text, "15:00") > 0, true, "native fifteen-minute button")
        ClickControl(G.Panel.Log)
        AssertEqual(LogsOpened, 1, "native log button")
        G.State.Health := "FAULT"
        G.State.FaultReason := "injected fault detail"
        UpdateTray()
        AssertEqual(InStr(G.Panel.Fault.Text, "injected fault detail") > 0, true, "fault is visible")
        ClickControl(G.Panel.Refresh)
        AssertEqual(G.State.Health, "OK", "native refresh explicitly retries fault")
        if A_Args.Length {
            G.State.PauseUntil := ControllerNow() + 300000
            UpdateTray()
            quote := Chr(34)
            command := "pwsh -NoProfile -File " quote A_ScriptDir "\capture-panel.ps1" quote
                . " -WindowHandle " hwnd " -OutputPath " quote A_Args[1] quote
            AssertEqual(RunWait(command, , "Hide"), 0, "capture actual native panel")
        }
        ticks := HeartbeatCount
        PostMessage(0x10, 0, 0, , "ahk_id " hwnd)
        Sleep(50)
        AssertEqual(DllCall("IsWindowVisible", "ptr", hwnd, "int"), 0, "close hides panel")
        AssertEqual(HeartbeatCount > ticks, true, "closing panel keeps timers running")
    } finally {
        SetTimer(Heartbeat, 0)
    }
}

ClickControl(control) {
    DllCall("SendMessageW", "ptr", control.Hwnd, "uint", 0xF5, "uptr", 0, "ptr", 0, "ptr")
    Sleep(30)
}

Heartbeat() {
    global HeartbeatCount
    HeartbeatCount += 1
}

ApplyState(target, reason) {
    global G
    G.State.Applied := target
}

RefreshExternal() {
    global G, ExternalLink, RefreshStates
    RefreshStates.Push(G.State.Applied)
    G.State.Link := ExternalLink
}

Log(*) {
}

Notify(*) {
}

OpenLog(*) {
    global LogsOpened
    LogsOpened += 1
}
