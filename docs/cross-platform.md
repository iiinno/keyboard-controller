# Linux・macOSの導入と操作

Linuxはevdev、macOSはIOHIDを使い、選択したキーボードの入力だけを読み捨てます。追加ドライバ・Go・Pythonのインストールは不要です。マウスやタッチパッドを含む複合デバイス、候補が複数ある状態、接続を確認できない状態では遮断しません。

## 対象環境

| OS | CPU | 操作 | 必要な許可 |
| --- | --- | --- | --- |
| Linuxデスクトップ | x64 / arm64 | アプリ一覧のランチャー、端末 | 選択したevdevノードへのアクセス。自動設定はudev・logind環境向け |
| macOS 13以降 | Apple Silicon / Intel | ユーザーのApplications内のランチャー、端末 | 入力監視の許可と、遮断時の管理者認証 |

X11・Waylandの違いには依存しません。WSLや、実際の入力デバイスが公開されていないコンテナからWindows側のキーボードを制御する用途には対応しません。

macOSの管理者権限はIOHIDのキーボード独占取得に必要です。[Appleの実装](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDLibUserClient.cpp)の `open` 処理でも制約が確認できます。入力監視の許可は別に必要です。アクセシビリティの許可や独自ドライバは要求しません。

## 1. インストール

公開Releaseを使う場合は次のコマンドで、OS・CPUに合うバイナリを取得します。

```sh
curl -fsSL https://raw.githubusercontent.com/iiinno/keyboard-controller/main/install.sh | sh
```

配布物のSHA-256を照合し、既定では `~/.local/bin/keyboard-controller` に配置します。初回は内蔵・外付けを一覧から番号で選びます。既存設定は保持します。`--prefix DIR` で配置先を変更できます。

**初回Releaseの公開前やPRの確認時**は、GitHub Actionsの `package-*` Artifactをダウンロード・展開し、同梱のインストーラーを使えます。展開したディレクトリで次を実行します。

```sh
sh install.sh --from .
```

標準入力が端末ではない環境では、インストール後に次を実行してください。

```sh
~/.local/bin/keyboard-controller setup
```

設定ファイルはLinuxで `$XDG_CONFIG_HOME/keyboard-controller/config.json`（未設定なら `~/.config/...`）、macOSで `~/Library/Application Support/keyboard-controller/config.json` です。再設定は `setup --replace` を使います。

## 2. OSの許可

### Linux

```sh
~/.local/bin/keyboard-controller permissions --apply
```

選択した内蔵キーボードの `ID_PATH` とキーボード種別に限定したudevルールを導入します。ここだけsudoによる認証が必要です。入力デバイス全体への権限や、inputグループへの所属は追加しません。ルールは `/etc/udev/rules.d/70-keyboard-controller.rules` です。

反映されなければデバイスの再接続または再ログインを行ってください。`ID_PATH` が取得できない機器や、logindのアクティブシートがない環境では自動権限設定を行いません。一般ユーザーで読めない場合に、成功したような表示はしません。

### macOS

```sh
~/.local/bin/keyboard-controller permissions --apply
```

システム設定の「プライバシーとセキュリティ → 入力監視」で、このプログラムまたは起動元のTerminalを許可し、プログラムを起動し直します。OSが表示する対象に従ってください。更新後に再許可が必要になることがあります。

実際の遮断では管理者権限も使います。ランチャーはsudoの認証を表示します。権限を回避したり、設定を自動で書き換えたりはしません。

## 3. 8秒テスト

外付けを接続し、マウスで端末を閉じられる状態で実行します。

Linux:

```sh
~/.local/bin/keyboard-controller test
```

macOS:

```sh
sudo ~/.local/bin/keyboard-controller test \
  --config "$HOME/Library/Application Support/keyboard-controller/config.json"
```

内蔵だけが入力できなくなり、外付け・マウスは使え、8秒後に内蔵の入力が戻ることを確認します。対象が不明、外付けが不在、権限が不足している場合はテストを開始せずエラーを返します。表示上のPASSは物理入力を測定した結果ではありません。

## 4. 常駐を開始

初回設定でランチャーも作ります。

- Linux: アプリ一覧の **Keyboard Controller**
- macOS: `~/Applications/Keyboard Controller.command`

ランチャーは端末に状態と操作コマンドを表示します。ウィンドウを閉じるかCtrl+Cで終了します。通常の切断・検出エラー・終了時は解放し、復帰時の長い時間差を検出した場合は一度PASSに戻して待機します。

| 端末に入力するコマンド | 動作 |
| --- | --- |
| `on` | 内蔵を常にON |
| `auto` | 外付けの現在の接続状態で判定。一時解除を取り消す |
| `pause 5` / `pause 15` | 5分／15分だけON。その後AUTOへ戻る |
| `status` | 現在の状態を再表示 |
| `quit` / Ctrl+C | 解放して終了 |

ターミナル出力は監視処理と分けています。出力先が詰まっても接続確認と解放を止めません。キー入力の内容をファイルへ記録しません。

## 困った場合

`doctor` は設定・識別結果・権限情報を表示します。入力を遮断しません。

```sh
~/.local/bin/keyboard-controller doctor
~/.local/bin/keyboard-controller devices --json
```

内蔵の入力が戻らない場合はマウスから常駐端末を閉じてください。別の端末が使える場合は、起動時に表示されたPIDに `kill -TERM PID`（macOSでは必要に応じてsudo）を送れます。それでも解消しなければOSを再起動してください。

主な制約:

- デバイスの存在を検出しています。キーボード本体の電源を切ってもUSBレシーバーだけが残る構成では、AUTOの根拠にしないでください。
- 遮断開始時に押していた修飾キーのキーアップを捨てる可能性があります。切替時に内蔵のCtrl・Alt・Shiftなどを押しっぱなしにしないでください。
- 内蔵キーボードとタッチパッドが一つのHIDとして報告される機器は、ポインター操作を残すため遮断しません。
- 他のキーボード制御ソフトがすでに独占している場合は、取得に失敗して終了します。
- 構成が変わってIDが一致しなくなった場合は `setup --replace` で選び直します。

## 開発・検証

開発時だけGoと、macOSではXcode Command Line Toolsを使います。配布バイナリの利用者には不要です。

```sh
cd portable
go test -race -cover ./...
go vet ./...
```

CIはGo 1.27.3を使い、Linux x64/arm64とmacOS Apple Silicon/Intelでネイティブビルド・実APIの読み取り専用列挙・設定と状態遷移・パッケージからのインストールを確認します。Linuxは隔離したCI VM内のuinput仮想キーボードで、実際のEVIOCGRAB、外付けへの非干渉、解除後の復帰も確認します。

macOSの物理キーボードを実際に独占・解放する試験は行っていません。C/IOKit部分はビルド・列挙で確認し、制御状態は偽のバックエンドで検証しています。個々のMacでの適合は8秒テストと切断・復帰の実機確認が必要です。
