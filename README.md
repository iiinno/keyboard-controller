# keyboard-controller

WindowsノートPCの上に外付けキーボードを置いて使うための、AutoHotkey v2製キーボードコントローラーです。指定した外付けHIDがWindows上で現在存在すると判定できる間だけ、内蔵キーボードの入力を遮断します。内蔵デバイス自体は無効化せず、切断・エラー・終了時はフィルタ解除を試みます。

Interceptionを使ってキーボード単位で入力を扱うため、外付けキーボード、マウス、タッチパッドは通常どおり使えます。

## 内蔵キーボードを遮断する条件

次の4条件がそろった場合だけ `BLOCKED` になります。

1. モードが `AUTO`
2. 設定した外付けキーボードを現在接続中と判定できる
3. 一時解除の時間外である
4. コントローラーが正常に動作している

それ以外は `PASS` です。接続状態を取得できない、内蔵キーボードを一意に特定できない、Interceptionの初期化に失敗した、といった場合も遮断しません。

| モード | 外付け接続 | 内蔵キーボード |
| --- | --- | --- |
| `AUTO` | 接続中 | `BLOCKED` |
| `AUTO` | 未接続・不明 | `PASS` |
| `AUTO`＋一時解除中 | 任意 | `PASS` |
| `FORCED_ON` | 任意 | `PASS` |
| `FAULT` | 任意 | Interceptionコンテキストを破棄。失敗時は `UNKNOWN` |

`PASS` は、このコントローラーがInterceptionの遮断コンテキストを保持していない状態です。物理キー入力がWindowsまで届いたことを独立に確認した意味ではありません。

## 導入

必要なものは次の3つです。

- Windows 11。現時点で実機確認しているOSです
- AutoHotkey v2 64-bit
- [Interception](https://github.com/oblitum/Interception)

Interceptionのバイナリはこのリポジトリに含めていません。公式リリースから64-bit版 `interception.dll` を `lib\interception.dll` に配置し、ドライバをインストールして再起動してください。

その後は次の順で進めます。

```text
1. config.example.ini を config.ini にコピー
2. tools\list-devices.ahk で内蔵・外付けキーボードのIDを確認
3. config.ini の internal_keyboard.match / external_keyboard.match を設定
4. tools\block-test.ahk で8秒間の遮断と自動解除を確認
5. main.ahk を起動
```

詳しい手順は [`docs/setup.md`](docs/setup.md) にあります。

## 設定

`config.ini` は端末ごとの設定なのでGit管理しません。最初に `config.example.ini` をコピーして作成します。

```ini
[internal_keyboard]
match=LEN0071
exclude=046D,B372

[external_keyboard]
match=_DEV_VID&02046D_PID&B372_,VID_046D&PID_B372
```

上は実機検証に使った例です。別の機種では `tools\list-devices.ahk` の出力から値を選んでください。

`internal_keyboard.match` に一致するInterceptionキーボードが1台でなければ遮断しません。`exclude` は外付けキーボードを内蔵と誤認しないための追加条件です。`external_keyboard.match` はPnP上の存在を見ており、実際にキー入力できることまでは保証しません。USBレシーバーがキーボード本体の電源断後も残る機種では、AUTO判定にそのレシーバーIDを使わないでください。

主なタイミング設定は次のとおりです。

| キー | 既定値 | 用途 |
| --- | ---: | --- |
| `poll_ms` | 1000 | 外付けHIDの存在確認間隔 |
| `settle_ms` | 3000 | 起動・復帰後にデバイス列挙が落ち着くまで待つ時間 |
| `drain_ms` | 10 | 遮断中の内蔵キーボード入力を読み捨てる間隔 |
| `resume_gap_factor` | 3 | 電源イベントを取り逃した場合に復帰とみなす補助判定 |

## モードを切り替える

トレイアイコンを左クリックまたは右クリックすると操作パネルを開きます。`AUTOに戻す` と `内蔵キーボードを常にON`（`FORCED_ON`）を切り替えられます。パネルは開いたままでも接続監視を続け、×またはEscで閉じても常駐は続きます。

`5分だけON`／`15分だけON` は内蔵キーボードを一時的に使いたいときの操作です。残り時間を表示し、終了後は現在の外付け接続状態を確認してAUTOの判定に戻ります。エラー状態や起動・復帰後の待機中には再遮断しません。AUTOまたは常にONを選ぶと一時解除を取り消します。一時解除は再起動後には引き継ぎません。終了の判定は `poll_ms` ごとに行います。

`toggle_hotkey` は通常のAutoHotkeyホットキー用です。Logi Options+などのデバイスアプリでは、**「アプリケーション／ファイルを開く」から `tools/toggle.ahk`（またはこのスクリプトを起動するショートカット）を実行**できます。キーの送信は不要です。ランチャーは常駐中の `main.ahk` にWindowsメッセージを送るだけで、要求ファイルは作りません。

## 内蔵キーボードが戻らない場合

次の順で復旧します。

1. 外付けキーボードの電源を切るか、Bluetoothを切断する
2. マウスまたはタッチパッドから `recover.ahk` を実行する
3. 改善しなければWindowsを再起動する

コントローラーから解除できない場合はWindows再起動を復旧手段にします。再起動後も、実際に内蔵キーボードから入力できることを確認してください。

## ファイル構成

```text
keyboard-controller/
├─ main.ahk                 常駐コントローラー
├─ recover.ahk              緊急復旧
├─ config.example.ini       公開用の設定例
├─ lib/
│  ├─ Config.ahk            設定読み込みと検証
│  ├─ Devices.ahk           内蔵・外付けキーボードの判定
│  ├─ Interception.ahk      Interception APIの薄いラッパー
│  ├─ Pnp.ahk               現在接続中のPnPデバイス列挙
│  ├─ ControlPanel.ahk      常駐監視を止めない操作パネル
│  ├─ Policy.ahk            状態判定と一時解除の残り時間
│  └─ Wide.ahk              UTF-16マルチ文字列の読み取り
├─ tools/
│  ├─ block-test.ahk        8秒だけ遮断する安全確認
│  ├─ key-tester.ahk        ホットキー候補の確認
│  ├─ list-devices.ahk      デバイスIDの確認
│  └─ toggle.ahk            外付けキーボード用の切替ランチャー
└─ docs/
   ├─ setup.md              導入と確認手順
   └─ validation.md         実機で確認した範囲
```

実行時には `config.ini`、`logs\`、`lib\interception.dll` が必要または生成されますが、いずれもGit管理の対象外です。

## 実機で確認した範囲

2026年10月17日にWindows 11、AutoHotkey v2、Lenovo ThinkPadの内蔵キーボードとLogitech Bluetoothキーボードで確認しています。内蔵キーボードだけの遮断、解除、18秒間のBLOCK維持、正常終了時のPASS復帰、モード切替まで実機ログで確認済みです。

詳細と未確認項目は [`docs/validation.md`](docs/validation.md) に分けています。

## 制約

- Interceptionドライバの導入には管理者権限と再起動が必要です
- 内蔵キーボードの特定はハードウェアIDの部分一致なので、端末ごとに設定が必要です
- 遮断中は内蔵キーボードの入力を読み捨てます。遮断開始時にすでに押していたキーのキーアップも捨てられる可能性があり、特にCtrl・Alt・Shiftなどの修飾キーはOS側で押下状態が残ることがあります。AUTOへ移るときは内蔵キーボードのキーを押したままにしないでください
- 制御プロセスを強制終了した場合のドライバ挙動はInterception側に依存します。`recover.ahk` と再起動を復旧手段として残しています
- AutoHotkeyの通常ホットキーだけでは、同じキーがどの物理キーボードから来たかを区別できません

## ライセンス

このリポジトリのコードはMIT Licenseです。

Interceptionは別ライセンスの外部依存です。バイナリやドライバはこのリポジトリに含めていません。利用条件は公式リポジトリと [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) を確認してください。

