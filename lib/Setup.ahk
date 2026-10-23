#Requires AutoHotkey v2.0
#Include Config.ahk
#Include Devices.ahk

AddedDeviceIDs(before, after) {
    known := Map()
    known.CaseSense := "Off"
    for id in before
        known[id] := true
    added := []
    for id in after {
        if !known.Has(id)
            added.Push(id)
    }
    return added
}

WriteSetupConfig(path, examplePath, internalPattern, externalID, keyboards) {
    if (internalPattern = "" || externalID = "" || InStr(internalPattern, ",") || InStr(externalID, ",")
        || InStr(internalPattern externalID, "`n") || InStr(internalPattern externalID, "`r"))
        throw Error("Device IDs must be nonempty single patterns")
    draft := path ".setup-" ProcessExist() ".tmp"
    try {
        FileCopy(FileExist(path) ? path : examplePath, draft, true)
        IniWrite(internalPattern, draft, "internal_keyboard", "match")
        IniWrite("", draft, "internal_keyboard", "exclude")
        IniWrite(externalID, draft, "external_keyboard", "match")
        cfg := LoadConfig(draft)
        SelectInternalKeyboard(cfg, keyboards)
        if FileExist(path)
            FileCopy(path, path ".bak", true)
        FileMove(draft, path, true)
    } finally {
        if FileExist(draft)
            FileDelete(draft)
    }
}
