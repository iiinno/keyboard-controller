#Requires AutoHotkey v2.0
#Include Interception.ahk
#Include Pnp.ahk
#Include Config.ahk

; Device identification. Shared by the controller and by tools\block-test.ahk, so the
; safety test exercises the same rule the controller uses.

; Picks the built-in keyboard out of the keyboards Interception exposes.
; Throws unless exactly one device matches, so the caller fails open instead of
; blocking a keyboard it only half recognises.
SelectInternalKeyboard(cfg, devices) {
    candidates := []
    for device in devices {
        ; A device matching an exclude pattern is never the built-in keyboard, even
        ; when it also matches an include pattern.
        if MatchesAny(device.hardwareId, cfg.InternalExclude)
            continue
        if MatchesAny(device.hardwareId, cfg.InternalMatch)
            candidates.Push(device)
    }

    if (candidates.Length != 1) {
        detail := ""
        for device in devices
            detail .= "`n  device " device.id ": " device.hardwareId
        if (detail = "")
            detail := "`n  Interception reported no keyboards at all."
        throw Error(Format("expected exactly 1 built-in keyboard but {1} matched.{2}"
            . "`nFix internal_keyboard.match in config.ini. Run tools\list-devices.ahk to see the hardware IDs."
            , candidates.Length, detail))
    }
    return candidates[1]
}

; True when a currently present HID device matches external_keyboard.match.
; A powered-off or out-of-range keyboard is absent, not connected.
ExternalKeyboardPresent(cfg) {
    for instanceId in Pnp.ListPresent("HID") {
        if MatchesAny(instanceId, cfg.ExternalMatch)
            return true
    }
    return false
}
