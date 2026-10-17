#Requires AutoHotkey v2.0

; config.ini loading and validation.
;
; Everything here fails loudly rather than guessing, because a wrong guess about
; which keyboard is which ends with the built-in keyboard blocked when it should
; not be.

; Reads and validates the configuration. Throws with a message meant for the user.
; The path is explicit because scripts under tools\ have a different A_ScriptDir.
;
; The object is filled in one assignment per line so that every value is a plain
; function call on its own line.
LoadConfig(iniPath) {
    if !FileExist(iniPath)
        throw Error("config.ini was not found at " iniPath ". Copy config.example.ini to config.ini and configure the device IDs first.")

    cfg := {}
    cfg.StartMode := StrUpper(Trim(IniRead(iniPath, "general", "start_mode", "AUTO")))
    cfg.ToggleHotkey := Trim(IniRead(iniPath, "general", "toggle_hotkey", "^!+F12"))
    cfg.InternalMatch := SplitList(IniRead(iniPath, "internal_keyboard", "match", ""))
    cfg.InternalExclude := SplitList(IniRead(iniPath, "internal_keyboard", "exclude", ""))
    cfg.ExternalMatch := SplitList(IniRead(iniPath, "external_keyboard", "match", ""))
    cfg.PollMs := IntOr(IniRead(iniPath, "timing", "poll_ms", "1000"), 1000)
    cfg.SettleMs := IntOr(IniRead(iniPath, "timing", "settle_ms", "3000"), 3000)
    cfg.DrainMs := IntOr(IniRead(iniPath, "timing", "drain_ms", "10"), 10)
    cfg.ResumeGapFactor := IntOr(IniRead(iniPath, "timing", "resume_gap_factor", "3"), 3)
    cfg.MaxLogKb := IntOr(IniRead(iniPath, "logging", "max_kb", "256"), 256)

    if (cfg.StartMode != "AUTO" && cfg.StartMode != "FORCED_ON")
        throw Error("start_mode must be AUTO or FORCED_ON, got '" cfg.StartMode "'.")
    if (cfg.ToggleHotkey = "")
        throw Error("toggle_hotkey is empty.")
    if (cfg.InternalMatch.Length = 0)
        throw Error("internal_keyboard.match is empty, so the built-in keyboard cannot be identified.")
    if (cfg.ExternalMatch.Length = 0)
        throw Error("external_keyboard.match is empty, so the external keyboard cannot be identified.")

    ; Below 200 ms the poll costs more than it returns.
    cfg.PollMs := Max(cfg.PollMs, 200)
    cfg.DrainMs := Max(cfg.DrainMs, 1)
    cfg.SettleMs := Max(cfg.SettleMs, 0)
    cfg.ResumeGapFactor := Max(cfg.ResumeGapFactor, 2)
    cfg.MaxLogKb := Max(cfg.MaxLogKb, 16)
    return cfg
}

SplitList(value) {
    items := []
    for part in StrSplit(value, ",") {
        part := Trim(part)
        if (part != "")
            items.Push(part)
    }
    return items
}

IntOr(value, fallback) {
    text := Trim(value)
    return IsInteger(text) ? Integer(text) : fallback
}

; Case-insensitive substring test against a list of patterns.
MatchesAny(haystack, patterns) {
    needle := StrLower(haystack)
    for pattern in patterns {
        if (InStr(needle, StrLower(pattern)))
            return true
    }
    return false
}
