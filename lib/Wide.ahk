#Requires AutoHotkey v2.0

; Reading NUL-separated UTF-16 strings out of a raw buffer.
;
; StrGet with an explicit length still stops at the first NUL, and a NUL does not
; survive as a usable split delimiter in an AutoHotkey string. So the buffer is walked
; one UTF-16 code unit at a time instead. Verified on the target machine: both the
; cfgmgr32 device list and the Interception hardware IDs come back as multi-strings.

class Wide {
    ; Entries of a NUL-separated multi-string. Empty entries are dropped, which also
    ; discards the zero padding past the end of the data.
    static ReadMultiString(buf, byteLength) {
        entries := []
        limit := byteLength // 2
        start := 0
        i := 0
        while (i < limit) {
            if (NumGet(buf.Ptr, i * 2, "ushort") = 0) {
                if (i = start) {
                    start := limit
                    break
                }
                entries.Push(StrGet(buf.Ptr + start * 2, i - start, "UTF-16"))
                start := i + 1
            }
            i += 1
        }
        if (limit > start) {
            tail := StrGet(buf.Ptr + start * 2, limit - start, "UTF-16")
            if (tail != "")
                entries.Push(tail)
        }
        return entries
    }

    ; The same entries joined by a separator, for substring matching against patterns.
    static ReadJoined(buf, byteLength, separator) {
        joined := ""
        for entry in Wide.ReadMultiString(buf, byteLength)
            joined .= entry separator
        return joined
    }
}
