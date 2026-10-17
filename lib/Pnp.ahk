#Requires AutoHotkey v2.0
#Include Wide.ahk

; Presence check for PnP devices, via cfgmgr32.
;
; The question this answers is "is this device attached right now", not "is the radio
; on". CM_GETIDLIST_FILTER_PRESENT returns exactly the set Device Manager calls
; present, which is the same set Get-PnpDevice -PresentOnly reports.
;
; Checked on the target machine: enumerator=HID with PRESENT returned 9 devices and
; enumerator=ACPI returned 59, while the same query without PRESENT returned more, so
; absent devices really are excluded.

class Pnp {
    static FILTER_ENUMERATOR := 0x00000001
    static FILTER_PRESENT := 0x00000100

    ; Instance IDs of the present devices under an enumerator, such as "HID" or "ACPI".
    static ListPresent(enumerator) {
        flags := Pnp.FILTER_ENUMERATOR | Pnp.FILTER_PRESENT

        pLen := Buffer(4, 0)
        cr := DllCall("cfgmgr32\CM_Get_Device_ID_List_SizeW"
            , "ptr", pLen.Ptr, "wstr", enumerator, "uint", flags, "int")
        if (cr != 0)
            throw Error("CM_Get_Device_ID_List_SizeW failed for " enumerator ", cr=" cr)

        lenChars := NumGet(pLen.Ptr, 0, "uint")
        if (lenChars = 0)
            return []

        ; BufferLen is in characters, so the byte size is twice the capacity.
        capacity := lenChars + 2
        buf := Buffer(capacity * 2, 0)
        cr := DllCall("cfgmgr32\CM_Get_Device_ID_ListW"
            , "wstr", enumerator, "ptr", buf.Ptr, "uint", capacity, "uint", flags, "int")
        if (cr != 0)
            throw Error("CM_Get_Device_ID_ListW failed for " enumerator ", cr=" cr)

        return Wide.ReadMultiString(buf, capacity * 2)
    }
}
