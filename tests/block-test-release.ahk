#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include assert.ahk

; run.ps1 pre-includes the actual Release() function, without executing block-test.
; This fake replaces Interception entirely; no DLL or driver is loaded.
class Interception {
    static Calls := 0
    static Close() {
        this.Calls += 1
        return this.Calls > 1
    }
}

Released := false
Messages := []

try {
    AssertEqual(Release(), false, "failed close must report failure")
    AssertEqual(Released, false, "failed close must allow a retry")
    AssertEqual(Interception.Calls, 1, "first close attempted")
    AssertEqual(InStr(Messages[1], "ERROR:") > 0, true, "failure log is truthful")

    AssertEqual(Release(), true, "retry can succeed")
    AssertEqual(Released, true, "successful close marks completion")
    AssertEqual(Interception.Calls, 2, "close was retried")
    AssertEqual(InStr(Messages[2], "context destroyed") > 0, true, "success log")

    AssertEqual(Release(), true, "successful release is idempotent")
    AssertEqual(Interception.Calls, 2, "no extra close after success")
    AssertEqual(Messages.Length, 2, "no duplicate success log")
    ReportPass()
    ExitApp(0)
} catch as e {
    FileAppend("FAIL: " e.Message " (line " e.Line ")`n", "**", "UTF-8")
    ExitApp(1)
}

Drain() {
}

Log(message) {
    global Messages
    Messages.Push(message)
}
