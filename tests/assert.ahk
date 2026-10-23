Assertions := 0

AssertEqual(actual, expected, label) {
    global Assertions
    Assertions += 1
    if (actual != expected)
        throw Error(label ": expected '" expected "', got '" actual "'")
}

AssertThrows(callback, messagePart) {
    try {
        callback.Call()
    } catch as e {
        AssertEqual(InStr(e.Message, messagePart) > 0, true, "error: " e.Message)
        return
    }
    throw Error("Expected an error containing '" messagePart "'")
}

ReportPass() {
    global Assertions
    FileAppend("PASS: " Assertions " assertions`n", "*", "UTF-8")
}
