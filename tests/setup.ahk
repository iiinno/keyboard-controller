#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include assert.ahk
#Include ..\lib\Setup.ahk

try {
    RunSetupTests()
    ReportPass()
    ExitApp(0)
} catch as testFailure {
    FileAppend("FAIL: " testFailure.Message " (line " testFailure.Line ")`n", "**", "UTF-8")
    ExitApp(1)
}

RunSetupTests() {
    testDir := A_Temp "\keyboard-controller-setup-test-" ProcessExist()
    DirCreate(testDir)
    try {
    added := AddedDeviceIDs(["HID\existing"], ["hid\EXISTING", "HID\new"])
    AssertEqual(added.Length, 1, "presence comparison ignores case")
    AssertEqual(added[1], "HID\new", "new external ID")
    AssertEqual(AddedDeviceIDs(["HID\new"], ["HID\new"]).Length, 0, "still-present external cannot be confirmed absent")
    path := testDir "\config.ini"
    keyboards := [{id: 1, hardwareId: "ACPI\internal"}, {id: 2, hardwareId: "HID\external"}]
    WriteSetupConfig(path, A_ScriptDir "\..\config.example.ini", "ACPI\internal", "HID\external", keyboards)
    cfg := LoadConfig(path)
    AssertEqual(cfg.InternalMatch[1], "ACPI\internal", "internal setting")
    AssertEqual(cfg.ExternalMatch[1], "HID\external", "external setting")
    IniWrite("1500", path, "timing", "poll_ms")
    WriteSetupConfig(path, A_ScriptDir "\..\config.example.ini", "ACPI\internal", "HID\changed", keyboards)
    AssertEqual(LoadConfig(path).PollMs, 1500, "preserve timing")
    AssertEqual(FileExist(path ".bak") != "", true, "backup existing config")
    AssertThrows(() => WriteSetupConfig(path, "", "ACPI", "HID\new", [keyboards[1], keyboards[1]]), "2 matched")
    AssertEqual(LoadConfig(path).ExternalMatch[1], "HID\changed", "failed validation preserves config")
    AssertThrows(() => WriteSetupConfig(path, "", "ACPI,too-broad", "HID\new", keyboards), "single patterns")
    AssertThrows(() => WriteSetupConfig(path, "", "ACPI", "HID`ninvalid", keyboards), "single patterns")
    AssertEqual(Interception.IsOpen(), false, "setup tests never open the driver")
    } finally {
        DirDelete(testDir, true)
    }
}
