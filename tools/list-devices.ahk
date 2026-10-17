#Requires AutoHotkey v2.0 64-bit
#Include ..\lib\Interception.ahk
#Include ..\lib\Pnp.ahk

; Read-only diagnostic used to configure config.ini.
;
; It prints the keyboard hardware IDs Interception exposes and the currently present
; HID instance IDs. The first list is used for internal_keyboard.match; the second is
; used for external_keyboard.match.

global Lines := []

Section(title) {
    global Lines
    Lines.Push("")
    Lines.Push("=== " title " ===")
}

Emit(text) {
    global Lines
    Lines.Push(text)
}

Section("Interception keyboards")
try {
    keyboards := Interception.ListKeyboards()
    if (keyboards.Length = 0)
        Emit("  none. Either no keyboard is attached, or the driver is not installed.")
    for keyboard in keyboards
        Emit(Format("  device {1}: {2}", keyboard.id, keyboard.hardwareId))
    Interception.Close()
} catch as e {
    Emit("  ERROR: " e.Message)
}

Section("Present HID devices")
try {
    for instanceId in Pnp.ListPresent("HID")
        Emit("  " instanceId)
} catch as e {
    Emit("  ERROR: " e.Message)
}

text := ""
for entry in Lines
    text .= entry "`r`n"

outPath := A_ScriptDir "\device-list.txt"
try {
    if FileExist(outPath)
        FileDelete(outPath)
} catch {
}
FileAppend(text, outPath, "UTF-8")

MsgBox("Wrote " outPath "`n`n" text, "keyboard-controller device list")