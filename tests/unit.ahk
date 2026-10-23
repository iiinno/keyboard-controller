#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include assert.ahk
#Include ..\lib\Devices.ahk

try {
    TestMatching()
    TestDeviceSelection()
    TestWideStrings()
    TestConfig()
    ReportPass()
    ExitApp(0)
} catch as e {
    FileAppend("FAIL: " e.Message " (line " e.Line ")`n", "**", "UTF-8")
    ExitApp(1)
}

TestMatching() {
    parts := SplitList(" , LEN0071, , VID_046D , ")
    AssertEqual(parts.Length, 2, "empty patterns are dropped")
    AssertEqual(parts[2], "VID_046D", "patterns are trimmed")
    AssertEqual(MatchesAny("acpi\len0071", parts), true, "case-insensitive matching")
    AssertEqual(MatchesAny("unrelated", parts), false, "unmatched ID")
    AssertEqual(MatchesAny("anything", []), false, "empty pattern list")
    AssertEqual(IntOr(" 1000 ", 9), 1000, "integer setting")
    AssertEqual(IntOr("bad", 9), 9, "invalid setting fallback")
}

TestDeviceSelection() {
    cfg := {InternalMatch: ["LEN0071"], InternalExclude: ["046D"]}
    builtIn := {id: 1, hardwareId: "ACPI\LEN0071"}
    external := {id: 2, hardwareId: "HID\VID_046D&LEN0071"}
    AssertEqual(SelectInternalKeyboard(cfg, [builtIn, external]).id, 1, "exclude takes precedence")
    AssertThrows(() => SelectInternalKeyboard(cfg, []), "0 matched")
    AssertThrows(() => SelectInternalKeyboard(cfg, [external]), "0 matched")
    AssertThrows(() => SelectInternalKeyboard(cfg, [builtIn, builtIn]), "2 matched")

    global PredTargetDevice, PredMatchAllKeyboards
    PredMatchAllKeyboards := false
    PredTargetDevice := 3
    loop 20
        AssertEqual(InterceptionPredicate(A_Index), A_Index = 3, "single-device predicate " A_Index)
    PredMatchAllKeyboards := true
    loop 20
        AssertEqual(InterceptionPredicate(A_Index), A_Index <= 10, "keyboard-only predicate " A_Index)
    PredMatchAllKeyboards := false
    PredTargetDevice := 0
    AssertThrows(() => Interception.BlockDevice(0), "not a keyboard slot")
    AssertThrows(() => Interception.BlockDevice(11), "not a keyboard slot")
    AssertEqual(Interception.IsOpen(), false, "tests never open the driver")
}

TestWideStrings() {
    ; Two NUL-separated entries followed by the double-NUL terminator and junk.
    buf := Buffer(32, 0)
    StrPut("one", buf.Ptr, 4, "UTF-16")
    StrPut("two", buf.Ptr + 8, 4, "UTF-16")
    StrPut("junk", buf.Ptr + 18, 5, "UTF-16")
    entries := Wide.ReadMultiString(buf, buf.Size)
    AssertEqual(entries.Length, 2, "stop at double NUL")
    AssertEqual(entries[1], "one", "first UTF-16 entry")
    AssertEqual(entries[2], "two", "second UTF-16 entry")
    AssertEqual(Wide.ReadJoined(buf, buf.Size, "|"), "one|two|", "joined hardware IDs")
    AssertEqual(Wide.ReadMultiString(Buffer(4, 0), 4).Length, 0, "empty multi-string")
    AssertEqual(Wide.ReadMultiString(buf, 6)[1], "one", "bounded unterminated entry")
    AssertEqual(Wide.ReadMultiString(buf, 7)[1], "one", "odd byte count ignores partial code unit")
}

TestConfig() {
    ini := A_Temp "\keyboard-controller-test-" DllCall("GetCurrentProcessId", "uint") ".ini"
    AssertEqual(FileExist(ini), "", "isolated config path")
    try {
        AssertThrows(() => LoadConfig(ini), "was not found")
        FileCopy(A_ScriptDir "\..\config.example.ini", ini)
        cfg := LoadConfig(ini)
        AssertEqual(cfg.StartMode, "AUTO", "default mode")
        AssertEqual(cfg.PollMs, 1000, "default poll")
        IniWrite("forced_on", ini, "general", "start_mode")
        IniWrite("-1", ini, "timing", "poll_ms")
        IniWrite("-1", ini, "timing", "settle_ms")
        IniWrite("0", ini, "timing", "drain_ms")
        IniWrite("1", ini, "timing", "resume_gap_factor")
        IniWrite("0", ini, "logging", "max_kb")
        cfg := LoadConfig(ini)
        AssertEqual(cfg.StartMode, "FORCED_ON", "normalize mode")
        AssertEqual(cfg.PollMs, 200, "minimum poll")
        AssertEqual(cfg.SettleMs, 0, "minimum settle")
        AssertEqual(cfg.DrainMs, 1, "minimum drain")
        AssertEqual(cfg.ResumeGapFactor, 2, "minimum resume factor")
        AssertEqual(cfg.MaxLogKb, 16, "minimum log size")
        IniWrite("invalid", ini, "general", "start_mode")
        AssertThrows(() => LoadConfig(ini), "start_mode must be")
        IniWrite("AUTO", ini, "general", "start_mode")
        IniWrite("", ini, "internal_keyboard", "match")
        AssertThrows(() => LoadConfig(ini), "internal_keyboard.match is empty")
        IniWrite("internal", ini, "internal_keyboard", "match")
        IniWrite("", ini, "external_keyboard", "match")
        AssertThrows(() => LoadConfig(ini), "external_keyboard.match is empty")
    } finally {
        if FileExist(ini)
            FileDelete(ini)
    }
}
