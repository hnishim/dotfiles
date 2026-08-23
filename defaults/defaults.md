# `defaults.md`

`defaults` コマンドでは対応できないシステム設定内容をここにまとめておく。

## General

Apple Watch でMacをアンロックする。

- Touch ID & Password
  - Allow Apple Watch to unlock your Mac: `On`
    - *注: この設定はキーチェーンに保存されており、`defaults` コマンドでは管理できません。*

ZoomやMeetでカメラをオンにするたび表示される「リアクションをオンにする」というメッセージを抑止する。
参考：[https://x.com/yusukeoi/status/1886739712435728741],[https://www.reddit.com/r/mac/comments/171rs4k/comment/m5x0odz/]

- Notifications → FaceTime
  - 以下 `Off`
    - Show notifications on lock screen
    - Show in Notification Center
    - Badge application icon
    - Play sound for notification
  - 次にAllow notifications `Off`
  - Mac再起動

## Karabiner-Elements

設定ファイル（`karabiner.json`）をシンボリックリンクにして端末間同期するため、 Full Disk Access を有効化する。

- Privacy & Security → Full Disk Access
  - `/Library/Application Support/org.pqrs/Karabiner-Elements/bin/` にある `karabiner_grabber` を追加

Karabinerの `Shell commands` からMimiでウインドウを操作する場合は、Mimi本体ではなく、Karabinerのshell command実行主体にもAccessibility許可が必要。

- Privacy & Security → Accessibility
  - `karabiner_console_user_server`：`On`
  - `Mimi.app`：今回のKarabiner経由の失敗原因ではなかった。Mimi単体での必要性は未検証のため、現状はオンのまま保持する

この許可はmacOSのTCCで管理されるため、`defaults` やdotfilesの設定ファイルから自動付与できない。Karabiner-Elementsの初回インストール、更新、または権限リセット後に手動で確認する。

Karabiner経由のMimi実行時は、ラッパースクリプトが `mimi status` を同じ実行コンテキストで確認する。Accessibilityが許可されていなければ、ウインドウ操作せずエラーとしてKarabinerのログに記録する。

## IME（かわせみ）

IME切替候補にMac標準IMEを消す。
参考：[https://leica-q2.com/2021/03/04thood-things/kawasemi3-kankyou/](キジトラ猫とカメラが好き「かわせみ3」だけ環境設定に残したい | キジトラ猫とカメラが好き)

- Keyboard → Text Input → Input Sources → Edit
  - `+` ボタンからかわせみを追加
  - 他の入力メソッドを削除
    - まず `Japanese - Romaji` の中の `Romaji` にチェック
    - その上で `Japanese - Romaji` を削除
    - その後に `ABC` を削除（うまくいかなければ逆の順番を試す）
