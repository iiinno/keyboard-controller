#Requires AutoHotkey v2.0
#Include Wide.ahk

; Thin AHK v2 wrapper over the separately licensed Interception API.
; Only the pieces this project needs: create a context, list keyboards with their
; hardware IDs, filter one device, and release the context again.
;
; The filter is applied per device by interception_set_filter, which calls a predicate
; once per device index and applies the filter only where the predicate returns
; non-zero. That is what keeps the external keyboard out of our input path entirely:
; while the built-in keyboard is blocked, no stroke from any other keyboard passes
; through this process.

; Inputs read by the predicate below. Plain globals so the fast callback does no class
; or property lookup.
PredTargetDevice := 0
PredMatchAllKeyboards := false

; Called by interception.dll once per device index (1 to 20). Returning non-zero marks
; the device as one this context filters.
;
; Keyboard slots are 1 to 10 and mouse slots are 11 to 20. The Interception driver is
; installed as an upper filter for both keyboards and mice, so this predicate must never
; match a mouse slot: a filtered mouse would make the pointer unusable, and the mouse is
; one of the recovery paths for a blocked keyboard.
InterceptionPredicate(device) {
    global PredTargetDevice, PredMatchAllKeyboards
    if PredMatchAllKeyboards
        return (device >= 1 && device <= 10) ? 1 : 0
    return (device = PredTargetDevice) ? 1 : 0
}

class Interception {
    static KEY_NONE := 0x0000
    static KEY_ALL := 0xFFFF
    static MAX_KEYBOARD := 10

    ; Hardware IDs arrive as UTF-16. The sample in the Interception repository reads
    ; them into a 1000-byte buffer, so this matches the size the driver expects.
    static HWID_BYTES := 1000

    static _fn := Map()
    static _module := 0
    static _ctx := 0
    static _pred := 0
    static _open := false

    static IsOpen() {
        return Interception._open
    }

    ; Loads the library and creates a context. Throws if the driver is not installed or
    ; not running, so the caller can fail open instead of half-working.
    static Open() {
        if Interception._open
            return

        ; Load only the DLL placed next to this wrapper. Never fall back to the
        ; process DLL search path.
        libDir := RegExReplace(A_LineFile, "\\[^\\]*$")
        dllPath := libDir "\interception.dll"
        hModule := DllCall("LoadLibraryExW", "wstr", dllPath, "ptr", 0
            , "uint", 0x00000100 | 0x00000800, "ptr")
        if !hModule
            throw Error("interception.dll could not be loaded. Put the "
                . (A_PtrSize = 8 ? "64-bit" : "32-bit")
                . " interception.dll in lib\ and install the Interception driver (see docs\setup.md). "
                . "This AutoHotkey is " (A_PtrSize = 8 ? "64-bit" : "32-bit")
                . ", so the DLL must match its architecture.")

        ; Resolve exports explicitly. DllCall("interception.dll\fn") would re-resolve the
        ; module by name and can pick up a second copy when we loaded by full path.
        for name in ["interception_create_context", "interception_destroy_context"
            , "interception_set_filter", "interception_receive", "interception_get_hardware_id"] {
            addr := DllCall("GetProcAddress", "ptr", hModule, "astr", name, "ptr")
            if !addr {
                DllCall("FreeLibrary", "ptr", hModule)
                Interception._fn.Clear()
                throw Error("interception.dll has no export " name)
            }
            Interception._fn[name] := addr
        }

        Interception._module := hModule
        Interception._ctx := DllCall(Interception._fn["interception_create_context"], "ptr")
        if !Interception._ctx {
            DllCall("FreeLibrary", "ptr", Interception._module)
            Interception._module := 0
            Interception._fn.Clear()
            throw Error("interception_create_context failed, which means the Interception driver is "
                . "not installed or not running yet. Run install-interception.exe /install as "
                . "administrator and reboot (see docs\setup.md).")
        }

        try {
            Interception._pred := CallbackCreate(InterceptionPredicate, "F", 1)
        } catch as e {
            DllCall(Interception._fn["interception_destroy_context"], "ptr", Interception._ctx)
            Interception._ctx := 0
            DllCall("FreeLibrary", "ptr", Interception._module)
            Interception._module := 0
            Interception._fn.Clear()
            throw e
        }
        Interception._open := true
    }

    ; Every keyboard slot the driver exposes, with the hardware IDs it reports.
    ; Empty slots return no hardware ID and are skipped. Only slots 1 to 10 are
    ; examined, so a mouse slot can never be returned.
    static ListKeyboards() {
        Interception.Open()
        found := []
        buf := Buffer(Interception.HWID_BYTES, 0)
        loop Interception.MAX_KEYBOARD {
            device := A_Index
            nBytes := DllCall(Interception._fn["interception_get_hardware_id"]
                , "ptr", Interception._ctx, "int", device, "ptr", buf.Ptr
                , "uint", Interception.HWID_BYTES, "uint")
            if (nBytes = 0)
                continue
            ; Parse only the bytes the API says it wrote.
            hardwareId := Wide.ReadJoined(buf, Min(nBytes, Interception.HWID_BYTES), "|")
            if (hardwareId != "")
                found.Push({ id: device, hardwareId: hardwareId })
        }
        return found
    }

    ; Filters every stroke from one keyboard device. The upstream setter is void, so
    ; release destroys the whole context rather than trusting an unverifiable readback.
    static BlockDevice(device) {
        ; Guarded here as well as in the predicate, because filtering a mouse slot would
        ; take away one of the recovery paths.
        if (device < 1 || device > Interception.MAX_KEYBOARD)
            throw Error("refusing to filter device " device ", which is not a keyboard slot (1 to "
                . Interception.MAX_KEYBOARD ")")
        Interception._applyFilter(device, Interception.KEY_ALL)
    }

    ; Best-effort explicit clear used by Close().
    static ClearAll() {
        Interception._applyFilterAll(Interception.KEY_NONE)
    }

    ; Consumes and discards whatever the device has queued. Discarding is the block.
    ; Reading keeps the driver queue empty, which is why this runs on a timer while the
    ; built-in keyboard is blocked.
    static Drain(device, maxPerCall := 64) {
        if !Interception._open
            return 0
        buf := Buffer(8 * maxPerCall, 0)
        total := 0
        loop {
            n := DllCall(Interception._fn["interception_receive"]
                , "ptr", Interception._ctx, "int", device, "ptr", buf.Ptr
                , "uint", maxPerCall, "int")
            if (n <= 0)
                break
            total += n
            if (A_Index > 64)
                break
        }
        return total
    }

    ; Release follows the upstream context lifecycle. Destroying the context closes every
    ; Interception device handle. Returns true when that call completed; this is not a
    ; physical-input test.
    static Close() {
        if !Interception._open
            return true

        ; set_filter is void, so this is best-effort. Context destruction below is the
        ; actual lifecycle boundary and closes every device handle.
        try Interception.ClearAll()
        try {
            DllCall(Interception._fn["interception_destroy_context"], "ptr", Interception._ctx)
        } catch {
            return false
        }

        Interception._ctx := 0
        if Interception._pred {
            try {
                CallbackFree(Interception._pred)
            }
            Interception._pred := 0
        }
        Interception._open := false
        if Interception._module {
            DllCall("FreeLibrary", "ptr", Interception._module)
            Interception._module := 0
        }
        Interception._fn.Clear()
        return true
    }

    ; Applies a filter to one device. The predicate matches that exact index, so no
    ; mouse slot is affected.
    static _applyFilter(device, filter) {
        global PredTargetDevice, PredMatchAllKeyboards
        Interception.Open()
        PredMatchAllKeyboards := false
        PredTargetDevice := device
        DllCall(Interception._fn["interception_set_filter"]
            , "ptr", Interception._ctx, "ptr", Interception._pred, "ushort", filter)
    }

    ; Applies a filter to every keyboard slot. The predicate returns non-zero only for
    ; indices 1 to 10, so clearing here never touches a mouse.
    static _applyFilterAll(filter) {
        global PredMatchAllKeyboards
        Interception.Open()
        PredMatchAllKeyboards := true
        DllCall(Interception._fn["interception_set_filter"]
            , "ptr", Interception._ctx, "ptr", Interception._pred, "ushort", filter)
    }
}
