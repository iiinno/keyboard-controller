# 実機検証

2026年10月17日に行った確認結果です。公開コードの一般的な動作保証ではなく、1台のWindows 11実機で確認できた範囲を記録しています。ログ上の `PASS` はコントローラー/APIの状態であり、物理キー入力がWindowsへ到達したことを独立に測定した結果ではありません。

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
- 正常終了時に `OnExit` が `PASS` を記録した
- `FORCED_ON` と `AUTO` のモード切替を確認した
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

## 自動テスト

WindowsとPowerShell 7で次を実行できます。AutoHotkeyのパスは環境に合わせて変更してください。

```powershell
pwsh -File .\tests\run.ps1 -AutoHotkey 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
```

実行スクリプトの構文検証、設定の検証、デバイス候補の一意性と除外優先、マウススロットの除外、UTF-16文字列の読み取り、遮断テストでの解除失敗と再試行を確認します。InterceptionのDLL・ドライバ・接続キーボードは不要です。`block-test.ahk` 全体は実行せず、解除関数だけを取り出して偽のAPIで検証します。

同じテストをGitHub Actionsでも実行します。これらは物理入力の遮断・復旧やスリープ復帰の実機確認を代替しません。

操作パネルについては、実際のWindowsウィンドウとボタンで、トレイ通知からの表示、5分／15分の一時解除、AUTOへの復帰、強制ON、ログ、デバイス再検出、閉じた後の常駐継続を検証します。パネル表示中のタイマー進行も確認します。コントローラーの関数を実コードから取り出し、デバイス列挙と状態適用だけを偽物に置き換えるため、キーボードの入力を遮断しません。期限切れ、未接続、FAULT、スリープ復帰の待機条件はこの状態遷移テストで確認します。

## OS別の追加自動検証

Linux x64/arm64、macOS Apple Silicon/Intelで、ネイティブビルド、`go vet`、`go test -race`、設定・一時解除・切断・復帰の状態遷移、実APIの読み取り専用列挙、パッケージからの導入、SHA-256不一致の拒否を実行します。Linuxはuinputで作った隔離された2台の仮想キーボードに対し、実際のEVIOCGRAB、内蔵側だけの入力抑止、外付け入力の継続、解除後の復帰を確認します。

Windowsの追加導入検証では、標準PowerShell 5.1によるパッケージからの導入、公式ZIPのSHA-256照合、設定保持、実行ファイルのロック時の更新拒否、初回セットアップのネイティブ画面を確認します。ドライバのインストール・再起動・物理入力の遮断はこのCIでは行いません。

macOSではIOKitのコンパイル・列挙までを実APIで確認し、入力の独占・解除は物理機器で未確認です。偽バックエンドの状態遷移テストを、物理入力やTCC許可の実証として扱いません。詳細と各環境の導入は [cross-platform.md](cross-platform.md) にあります。
