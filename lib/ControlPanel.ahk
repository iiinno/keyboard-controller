#Requires AutoHotkey v2.0
#Include Policy.ahk

; A modeless window: unlike a native tray menu, it does not stop SetTimer.
class ControlPanel {
    __New(onMode, onPause, onRefresh, onLog, onExit) {
        this.Window := Gui("-MaximizeBox -MinimizeBox", "keyboard-controller")
        this.Window.SetFont("s10", "Yu Gothic UI")
        this.Window.MarginX := 16
        this.Window.MarginY := 16
        this.Window.AddText("w432", "AUTOは外付けキーボードの接続に合わせて切り替えます。")
        this.Internal := this.Window.AddText("xm y+16 w432 h24", "")
        this.Link := this.Window.AddText("xm y+4 w432 h24", "")
        this.Mode := this.Window.AddText("xm y+4 w432 h24", "")
        this.Pause := this.Window.AddText("xm y+4 w432 h24", "")
        this.Fault := this.Window.AddText("xm y+4 w432 h56", "")

        this.Auto := this.Window.AddButton("xm y+8 w210 h36", "AUTOに戻す")
        this.Auto.OnEvent("Click", (*) => onMode.Call("AUTO"))
        this.Forced := this.Window.AddButton("x+12 yp w210 h36", "内蔵キーボードを常にON")
        this.Forced.OnEvent("Click", (*) => onMode.Call("FORCED_ON"))
        this.Five := this.Window.AddButton("xm y+10 w210 h36", "5分だけON")
        this.Five.OnEvent("Click", (*) => onPause.Call(5))
        this.Fifteen := this.Window.AddButton("x+12 yp w210 h36", "15分だけON")
        this.Fifteen.OnEvent("Click", (*) => onPause.Call(15))
        this.Window.AddText("xm y+8 w432", "一時解除の終了後は、接続状態を確認してAUTOに戻ります。")

        this.Refresh := this.Window.AddButton("xm y+16 w136 h32", "デバイス再検出")
        this.Refresh.OnEvent("Click", (*) => onRefresh.Call())
        this.Log := this.Window.AddButton("x+12 yp w136 h32", "ログを開く")
        this.Log.OnEvent("Click", (*) => onLog.Call())
        this.Exit := this.Window.AddButton("x+12 yp w136 h32", "常駐を終了")
        this.Exit.OnEvent("Click", (*) => onExit.Call())
        this.Window.AddText("xm y+12 w432", "×またはEscで閉じても、接続の監視は続きます。")
        this.Window.OnEvent("Close", (*) => this.Hide())
        this.Window.OnEvent("Escape", (*) => this.Hide())
    }

    Show() {
        this.Window.Show("AutoSize")
    }

    Hide() {
        this.Window.Hide()
    }

    Update(state, now) {
        remaining := PauseRemainingSeconds(state.PauseUntil, now)
        internal := Map("PASS", "使用可能（PASS）", "BLOCKED", "入力を遮断中（BLOCKED）", "UNKNOWN", "状態不明（UNKNOWN）")
        link := Map("CONNECTED", "接続中", "DISCONNECTED", "未接続", "UNKNOWN", "未確認")
        this.Internal.Text := "内蔵キーボード: " internal.Get(state.Applied, "状態不明")
        this.Link.Text := "外付けキーボード: " link.Get(state.Link, "未確認")
        this.Mode.Text := "モード: " (state.Mode = "AUTO" ? "AUTO（自動切替）" : "常にON")
        this.Pause.Text := remaining
            ? Format("一時解除: 残り {1}:{2:02}", remaining // 60, Mod(remaining, 60))
            : "一時解除: なし"
        this.Fault.Text := state.Health = "FAULT"
            ? "エラー: " state.FaultReason "`n詳細はログを確認してください。"
            : "状態: 正常"
        this.Auto.Enabled := state.Mode != "AUTO" || remaining > 0
        this.Forced.Enabled := state.Mode != "FORCED_ON"
    }
}
