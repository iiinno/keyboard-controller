# Windowsのセットアップ

## 簡単導入

公開ReleaseのWindows ZIPを展開して `install.cmd` を開きます。ソースからの場合もリポジトリ直下の同じファイルを使えます。AutoHotkeyとInterceptionを公式配布物からSHA-256照合付きで配置し、初回設定を開きます。既存の設定とログは上書きしません。

1. 初回は「ドライバを導入」で管理者承認を行い、Windowsを再起動する
2. スタートメニューの Keyboard Controller → Setup を開く
3. 外付けを外して①、接続して②、もう一度外して③を押す。内蔵候補が複数なら一覧から選ぶ
4. 接続し直して8秒テストを実行し、内蔵だけが止まり、外付けとポインターは使え、8秒後に内蔵が戻ることを確認する
5. 常駐を開始する。以後はスタートメニューから起動できる

ドライバ導入はユーザーがボタンで明示した場合だけ実行します。更新時にアプリが動いていれば、ファイルを変更する前に中止します。設定のIDを変更する場合は `config.ini.bak` に以前の内容を保存します。ログオン時の自動起動は後述のタスクスケジューラで設定できます。

Linux・macOSは [cross-platform.md](cross-platform.md) を参照してください。以下は従来の手動導入手順です。

公開リポジトリから初めて導入する場合の手順です。内蔵キーボードを遮断する処理を試す前に、必ず短時間の `block-test.ahk` で解除まで確認します。

## 1. AutoHotkey v2 64-bitを入れる

[AutoHotkey v2](https://www.autohotkey.com/) をインストールします。このプロジェクトは64-bit版で確認しています。

## 2. Interceptionを入れる

[oblitum/Interception](https://github.com/oblitum/Interception) の公式リリースを取得します。

1. 64-bit版 `interception.dll` を、このリポジトリの `lib\interception.dll` にコピーします
2. 管理者権限のコマンドプロンプトでInterceptionのインストーラーを実行します
3. Windowsを再起動します

インストール例です。

```bat
install-interception.exe /install
```

削除する場合は `/uninstall` を使い、再起動します。

```bat
install-interception.exe /uninstall
```

Interceptionはキーボードとマウスの上位フィルタドライバを導入します。このプロジェクトはコード上でキーボードスロット1から10だけを対象にし、マウススロット11から20は拒否します。

## 3. 設定ファイルを作る

`config.example.ini` を `config.ini` にコピーします。

```powershell
Copy-Item .\config.example.ini .\config.ini
```

`config.ini` は端末固有のデバイスIDを含むため `.gitignore` の対象です。

## 4. デバイスIDを確認する

`tools\list-devices.ahk` を実行します。Interceptionが見つけたキーボードと、現在存在するHIDデバイスを表示し、同じ内容を `tools\device-list.txt` に保存します。

内蔵キーボードは `Interception keyboards` から探します。外付けキーボードは `Present HID devices` から探します。

例です。

```text
=== Interception keyboards ===
  device 1: ACPI\LEN0071|...
  device 2: HID\VID_046D&UP:0001_U:0006|...

=== Present HID devices ===
  HID\{...}_DEV_VID&02046D_PID&B372_...\...
```

## 5. config.iniを実機に合わせる

`internal_keyboard.match` には、内蔵キーボードのInterceptionハードウェアIDにだけ含まれる文字列を入れます。候補がちょうど1台にならなければコントローラーは遮断しません。

`external_keyboard.match` には、外付けキーボードの現在のHIDインスタンスIDに含まれる文字列を入れます。BluetoothとUSBレシーバーでIDが変わる場合があります。PnPの `PRESENT` はHIDインスタンスの存在だけを表し、実際にキー入力できることは保証しません。特にUSBレシーバーがキーボード本体の電源断後も残る構成では、そのレシーバーIDをAUTO判定に使わないでください。手順8で本体の電源断・切断に追従して内蔵キーボードが戻ることを実機確認できたIDだけを設定します。

`internal_keyboard.exclude` は任意です。外付けキーボードのVIDやPIDの数字を入れておくと、内蔵キーボードの候補から明示的に除外できます。

## 6. 8秒の遮断テストを行う

`tools\block-test.ahk` を実行します。8秒間だけ設定した内蔵キーボードを遮断し、その後自動で解除します。タイマーを止めるトレイメニューは表示せず、残り時間をツールチップに表示します。

確認する内容は次の4点です。

- 内蔵キーボードの入力だけ止まる
- 外付けキーボードは入力できる
- マウスとタッチパッドは動く
- 8秒後に内蔵キーボードが戻る

戻らない場合はマウスから `recover.ahk` を実行します。それでも戻らなければWindowsを再起動します。

## 7. 常駐コントローラーを起動する

`main.ahk` を実行します。トレイアイコンを左クリックまたは右クリックして操作パネルを開き、現在のモード、内蔵キーボードの適用状態、外付けキーボードの接続状態、エラーを確認できます。パネルを開いていても監視は続きます。×またはEscで閉じると、パネルだけが非表示になります。

通常は `AUTO` を使います。内蔵キーボードを一時的に使いたい場合は `FORCED_ON` に切り替えます。

自動でAUTOに戻したい場合は `5分だけON` または `15分だけON` を使います。残り時間が0になった後、次の接続確認でAUTOの判定に戻ります。`AUTOに戻す` または `内蔵キーボードを常にON` を押すとカウントダウンを取り消します。

## 8. 切断と終了を確認する

公開環境で使い始める前に、次を実機で確認してください。

1. 外付けキーボードを切断すると内蔵キーボードが戻る
2. 操作パネルの `内蔵キーボードを常にON` で戻る
3. 操作パネルの `常駐を終了` で終了すると戻る
4. スリープ復帰直後は一度PASSになり、設定した待機時間の後に再評価される
5. 内蔵キーボードのCtrl・Alt・Shiftなどを押したままAUTO遮断へ移らない。押下中に切り替えた場合は修飾状態が残る可能性があるため、必要なら同じキーを一度押して離して状態を戻す
6. 操作パネルを開いたまま外付けキーボードを切断しても、内蔵入力が戻る
7. 一時解除の終了時に、外付けが接続中ならAUTO遮断、未接続ならPASSになる

強制終了時の挙動はInterceptionドライバ側に依存します。確認する場合は、マウスと再起動手段を確保した状態で行ってください。

## 9. モード切替キーを設定する

`general.toggle_hotkey` にはAutoHotkeyのホットキー記法を使います。

Logi Options+などで「キーストロークの割り当て」が使えない場合は、**「アプリケーション／ファイルを開く」で `tools/toggle.ahk` か、それをAutoHotkeyで起動するショートカットを指定**してください。ランチャーは実キー操作を送信せず、常駐コントローラーへ直接切替を要求します。

`tools\key-tester.ahk` はF13からF24やメディアキーなど、通常入力に使いにくいキーのAutoHotkey名を確認するための補助ツールです。

## 10. ログオン時に起動する

動作確認が終わってから自動起動を設定します。Windowsのタスクスケジューラでログオン時に64-bit版AutoHotkeyから `main.ahk` を起動するタスクを作成します。

常駐プロセス自体に管理者権限は不要です。管理者権限が必要なのはInterceptionドライバの導入と削除だけです。

## ログの見方

実行ログは `logs\controller.log` に保存されます。

| ログまたは表示 | 確認する点 |
| --- | --- |
| `interception.dll could not be loaded` | `lib\interception.dll` があるか、AutoHotkeyとDLLが64-bitでそろっているか |
| `interception_create_context failed` | Interceptionドライバを導入して再起動したか |
| `expected exactly 1 built-in keyboard but 0 matched` | `internal_keyboard.match` が実機のIDと合っているか |
| `expected exactly 1 built-in keyboard but 2 matched` | `internal_keyboard.match` をより一意な文字列にできるか |
| `External Keyboard: DISCONNECTED` | `external_keyboard.match` が現在存在するHID IDと合っているか |
| `Internal Keyboard: UNKNOWN` | `recover.ahk` を実行し、必要なら再起動する |

