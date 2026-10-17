#Requires AutoHotkey v2.0
; A second copy would install a second keyboard hook. Force replaces the first instead.
#SingleInstance Force

; Registers a modal warning dialog would be one more window on screen, so warnings go
; nowhere here. The script is short and interactive, so a typo shows up immediately.
#Warn All, Off

; Press a key and read back the AutoHotkey key name, virtual key and
; scan code, so you can pick a spare key on the external keyboard for toggle_hotkey.
;
; IMPORTANT: close this window when you are done. While it runs it owns a global
; keyboard hook for every key in the list below. Those keys are registered with the "~"
; prefix so they still reach the focused application, but a running hook is exactly the
; thing that interferes with ordinary typing, and leaving it open has no benefit.
;
; The list is deliberately restricted to keys a Bluetooth keyboard might have spare and
; which are not part of ordinary typing. Keys such as CapsLock, NumLock, Insert,
; PrintScreen, ScrollLock, Pause, AppsKey and the volume keys are excluded on purpose,
; because hooking them disturbs normal use for no gain. To read any key at all,
; including those, use AutoHotkey's own key history instead: open the tray icon's
; window, then View, then Key History.

Candidates := ["F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20", "F21", "F22", "F23", "F24"
    , "Launch_App1", "Launch_App2", "Launch_Mail", "Launch_Media"
    , "Browser_Back", "Browser_Forward", "Browser_Refresh", "Browser_Stop"
    , "Browser_Search", "Browser_Favorites", "Browser_Home"
    , "Media_Play_Pause", "Media_Stop", "Media_Next", "Media_Prev"]

TesterGui := Gui("+AlwaysOnTop +Resize", "keyboard-controller key tester")
TesterGui.Add("Text", "", "Press a key. It still reaches the focused app.")
TesterGui.Add("Text", "", "Close this window when you are done; it holds a keyboard hook while it runs.")
Output := TesterGui.Add("Edit", "ReadOnly W560 H340 Multi VScroll")
TesterGui.Show()

Report(name, *) {
    global Output
    vk := GetKeyVK(name)
    sc := GetKeySC(name)
    Output.Value := Format("{1}  vk={2:02X} sc={3:02X}`r`n{4}", name, vk, sc, Output.Value)
}

for name in Candidates {
    try {
        Hotkey("~*" name, Report.Bind(name))
    } catch {
        ; Not a recognised key name on this build. Skip it.
    }
}

; Closing the window releases every hotkey, so a forgotten window cannot keep hooking
; keys after the user thinks the tester is finished.
TesterGui.OnEvent("Close", (*) => ExitApp(0))
