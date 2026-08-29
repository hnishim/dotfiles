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

## IME（かわせみ）

IME切替候補にMac標準IMEを消す。
参考：[https://leica-q2.com/2021/03/04thood-things/kawasemi3-kankyou/](キジトラ猫とカメラが好き「かわせみ3」だけ環境設定に残したい | キジトラ猫とカメラが好き)

- Keyboard → Text Input → Input Sources → Edit
  - `+` ボタンからかわせみを追加
  - 他の入力メソッドを削除
    - まず `Japanese - Romaji` の中の `Romaji` にチェック
    - その上で `Japanese - Romaji` を削除
    - その後に `ABC` を削除（うまくいかなければ逆の順番を試す）
