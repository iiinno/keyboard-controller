#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
#NoTrayIcon
#Include ..\lib\Setup.ahk

S := {Root: A_ScriptDir "\..", Before: [], Keyboards: [], Added: []}
S.Window := Gui("-MaximizeBox -MinimizeBox", "keyboard-controller 初回セットアップ")
S.Window.SetFont("s10", "Yu Gothic UI")
S.Window.AddText("w640", "外付けキーボードを抜き差しして設定します。入力の遮断は行いません。`n初回はInterceptionドライバを導入し、Windowsを再起動してください。")
S.Window.AddButton("xm y+12 w300 h32", "ドライバを導入（管理者・再起動が必要）").OnEvent("Click", InstallDriver)
S.Window.AddButton("xm y+16 w640 h32", "① 外付けを外した状態を取得").OnEvent("Click", CaptureBaseline)
S.Internal := S.Window.AddDropDownList("xm y+8 w640", [])
S.Internal.OnEvent("Change", MarkSetupDirty)
S.Window.AddButton("xm y+16 w640 h32", "② 外付けを接続して検出").OnEvent("Click", DetectExternal)
S.External := S.Window.AddDropDownList("xm y+8 w640", [])
S.External.OnEvent("Change", MarkSetupDirty)
S.Window.AddButton("xm y+16 w640 h32", "③ もう一度外付けを外して確認・保存").OnEvent("Click", SaveSelection)
S.Status := S.Window.AddText("xm y+12 w640 h64", "ドライバ導入済みなら、①から進めてください。既存のタイミング・ホットキー設定は保持します。")
S.Test := S.Window.AddButton("xm y+12 w310 h36 Disabled", "④ 接続し直して8秒テスト")
S.Test.OnEvent("Click", RunSafetyTest)
S.Start := S.Window.AddButton("x+20 yp w310 h36 Disabled", "常駐コントローラーを開始")
S.Start.OnEvent("Click", StartController)
S.Window.OnEvent("Close", (*) => ExitApp())
S.Window.Show()

InstallDriver(*) {
    global S
    path := S.Root "\.runtime\interception\command line installer\install-interception.exe"
    if !FileExist(path) {
        S.Status.Text := "install.ps1で導入するか、公式Interceptionのインストーラーを実行してください。"
        return
    }
    try {
        Run('*RunAs "' path '" /install')
        S.Status.Text := "ドライバの導入を許可し、完了後にWindowsを再起動してください。再起動後はセットアップを開き直します。"
    } catch as setupError {
        S.Status.Text := setupError.Message
    }
}

CaptureBaseline(*) {
    global S
    try {
        S.Before := Pnp.ListPresent("HID")
        S.Keyboards := Interception.ListKeyboards()
        S.Internal.Delete()
        labels := []
        for keyboard in S.Keyboards
            labels.Push(keyboard.hardwareId)
        S.Internal.Add(labels)
        if (labels.Length = 1)
            S.Internal.Choose(1)
        S.Added := []
        S.External.Delete()
        S.Test.Enabled := false
        S.Start.Enabled := false
        S.Status.Text := "一覧から内蔵キーボードを選び、外付けを接続して②を押してください。"
    } catch as setupError {
        S.Status.Text := "検出できません: " setupError.Message
    } finally {
        Interception.Close()
    }
}

DetectExternal(*) {
    global S
    MarkSetupDirty()
    try {
        if !S.Keyboards.Length
            throw Error("先に外付けを外して①を押してください。")
        S.Added := AddedDeviceIDs(S.Before, Pnp.ListPresent("HID"))
        S.External.Delete()
        S.External.Add(S.Added)
        if S.Added.Length
            S.External.Choose(1)
        S.Status.Text := S.Added.Length
            ? "新しく現れた外付けのIDを選び、もう一度外して③を押してください。"
            : "新しいHIDが見つかりません。接続を確認してください。電源断に追従しないレシーバーはAUTO判定に使えません。"
    } catch as setupError {
        S.Status.Text := setupError.Message
    }
}

MarkSetupDirty(*) {
    global S
    S.Test.Enabled := false
    S.Start.Enabled := false
}

SaveSelection(*) {
    global S
    try {
        if (!S.Internal.Value || !S.External.Value)
            throw Error("①と②で内蔵・外付けを選んでください。")
        external := S.Added[S.External.Value]
        if !AddedDeviceIDs(Pnp.ListPresent("HID"), [external]).Length
            throw Error("外付けのIDがまだ存在します。切断または電源断してから③を押してください。")
        internal := StrSplit(S.Keyboards[S.Internal.Value].hardwareId, "|")[1]
        WriteSetupConfig(S.Root "\config.ini", S.Root "\config.example.ini", internal, external, Interception.ListKeyboards())
        S.Test.Enabled := true
        S.Start.Enabled := true
        S.Status.Text := "保存しました。外付けを接続し直して④を実行し、内蔵だけが止まり8秒後に戻ることを確認してください。既存設定があればconfig.ini.bakに退避しています。"
    } catch as setupError {
        S.Status.Text := setupError.Message
    } finally {
        Interception.Close()
    }
}

RunSafetyTest(*) {
    global S
    try {
        if !ExternalKeyboardPresent(LoadConfig(S.Root "\config.ini"))
            throw Error("先に外付けを接続し直してください。")
        Run('"' A_AhkPath '" "' S.Root '\tools\block-test.ahk"')
    } catch as setupError {
        S.Status.Text := setupError.Message
    }
}

StartController(*) {
    global S
    Run('"' A_AhkPath '" "' S.Root '\main.ahk"')
}
