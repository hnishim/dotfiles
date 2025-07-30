# `defaults.md`

`defaults` コマンドでは対応できないシステム設定内容をここにまとめておく。

## Karabiner-Elements

設定ファイル（`karabiner.json`）をシンボリックリンクにして端末間同期するため、 Full Disk Access を有効化する。

- Privacy & Security → Full Disk Access
  - `/Library/Application Support/org.pqrs/Karabiner-Elements/bin/` にある `karabiner_grabber` を追加

## IME（かわせみ）

IME切替候補にMac標準IMEを消す。
参考：[https://leica-q2.com/2021/03/04/good-things/kawasemi3-kankyou/](キジトラ猫とカメラが好き「かわせみ3」だけ環境設定に残したい | キジトラ猫とカメラが好き)

- Keyboard → Text Input → Input Sources → Edit
  - `+` ボタンからかわせみを追加
  - 他の入力メソッドを削除
    - まず `Japanese - Romaji` の中の `Romaji` にチェック
    - その上で `Japanese - Romaji` を削除
    - その後に `ABC` を削除（うまくいかなければ逆の順番を試す）
