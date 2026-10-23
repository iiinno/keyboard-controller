#Requires AutoHotkey v2.0

; Monotonic uptime includes sleep and avoids A_TickCount's 32-bit rollover.
ControllerNow() {
    return DllCall("GetTickCount64", "uint64")
}

PauseRemainingSeconds(deadline, now) {
    return Max(0, Ceil((deadline - now) / 1000))
}

; Anything not positively known to be safe to block resolves to PASS.
DecideInternalState(mode, link, health, paused := false) {
    return (mode = "AUTO" && link = "CONNECTED" && health = "OK" && !paused) ? "BLOCKED" : "PASS"
}
