# 実機検証

2026年10月17日に行った確認結果です。公開コードの一般的な動作保証ではなく、1台のWindows 11実機で確認できた範囲を記録しています。

## 確認環境

- Windows 11
- AutoHotkey v2
- Interception
- 内蔵キーボード `ACPI\LEN0071`。Interception device 1
- 外付けLogitechキーボード `VID_046D` / `PID_B372`。Interception device 2

## 確認できた動作

- 外付けキーボード接続中の `AUTO` で、内蔵device 1だけが `BLOCK` になる
- `FORCED_ON` に切り替えると `PASS` に戻る
- 18秒間 `BLOCK` を維持し、ログにドレイン由来のFAULTは出なかった
- 正常終了時に `OnExit` がフィルタ解除を行い、`PASS` を記録した
- `tools\toggle.ahk` 経由で `FORCED_ON` と `AUTO` を切り替えられた
- マウススロット11から20はフィルタ対象外になっている
- タスクスケジューラから手動起動し、コントローラーが動作することを確認した

ログでは次の遷移を確認しています。

```text
2026-10-17 14:04:58 INFO Internal keyboard BLOCK (mode=AUTO, external=CONNECTED, reason=poll)
2026-10-17 14:05:16 INFO App exiting (Single)
2026-10-17 14:05:16 INFO Internal keyboard PASS (exit)
2026-10-17 16:31:29 INFO Mode=FORCED_ON
2026-10-17 16:31:29 INFO Internal keyboard PASS (mode=FORCED_ON, external=CONNECTED, reason=mode-change)
2026-10-17 16:33:58 INFO Mode=AUTO
2026-10-17 16:33:58 INFO Internal keyboard BLOCK (mode=AUTO, external=CONNECTED, reason=mode-change)
```

## 未確認

- 外付けキーボードの電源断から、おおむね `poll_ms` の時間内に内蔵入力が戻ること
- スリープ復帰直後のPASSと、`settle_ms` 後の再評価
- 制御プロセスを強制終了した場合に、Interceptionドライバだけでフィルタが解放されること
- 次回ログオン時にタスクスケジューラから自動起動すること

強制終了時の解放はドライバ実装をソースから確認できないため、`recover.ahk` とWindows再起動を復旧経路として残しています。