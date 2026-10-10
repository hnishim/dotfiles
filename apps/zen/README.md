# Zen Browserのショートカット設定

使用プロファイル内の `zen-keyboard-shortcuts.json` を、本リポジトリの `apps/zen/zen-keyboard-shortcuts.json` へのシンボリックリンクに置き換えます。ZenのGUIからショートカットを変更すると、リンク先のJSONが直接更新されます。別の同期・取込機構はありません。

## 最初のMacから設定を取り込む

1. Zenの `about:profiles` で**使用中**のプロファイルの「ルートディレクトリ」を確認し、Zenを正常終了します。
2. プロファイル内の `zen-keyboard-shortcuts.json` が存在することを確認し、内容に個人情報や管理不要の値が混入していないことを確認します。このファイルだけを `apps/zen/zen-keyboard-shortcuts.json` へコピーしてGitで管理します。実ファイルが無い場合はZenのGUIでショートカット設定を一度保存してから確認してください。ダミー設定を作成しないでください。
3. Zen側の元ファイルのみ、プロファイル外へ退避します。例: `mv "$PROFILE/zen-keyboard-shortcuts.json" "$HOME/zen-keyboard-shortcuts.backup.json"`（`PROFILE` は手順1で確認した絶対パスを設定してください）。他のプロファイル設定ファイルは動かしません。
4. リポジトリのルートから `bash apps/zen/zen-setup.sh` を実行します。プロファイルが複数あり自動判定できない場合は `ZEN_PROFILE_PATH="/絶対パス/使用中プロファイル" bash apps/zen/zen-setup.sh` として明示します。元ファイルが残っている場合はスキップします。
5. `ls -l "$PROFILE/zen-keyboard-shortcuts.json"` で本リポジトリを指すリンクになったことを確認し、Zenを起動して設定・キー操作を確認します。

## 別のMac／新しいプロファイルへ適用

1. Zenを**一度起動して正常終了**し、プロファイルと内部の移行状態を初期化してください。ZenはショートカットのJSONとは別に `zen.keyboard.shortcuts.version` preferenceで設定移行を管理しています。初期化前のプロファイルへJSONだけを配置するとカスタム設定が初期化される可能性があります。
2. dotfiles側に取り込み済みの管理JSONがあることを確認します。新しいプロファイルにZenが生成した同名ファイルがあれば、Zen終了後にプロファイル外へ退避してからセットアップを実行します。
3. `bash apps/zen/zen-setup.sh` を実行します。必要に応じて `ZEN_PROFILE_PATH` を明示します。再実行しても同一リンクは変更しません。
4. Zenを再起動してショートカット操作を確認してください。

## 運用上の注意

- `setup-macos.sh` にも登録されています。ただし、初回に管理JSONがない・プロファイルがない・既存ファイルと競合する・対象を特定できない場合は何も変更せずスキップします。初回移行は手動です。
- GUI編集後は `git diff -- apps/zen/zen-keyboard-shortcuts.json` で差分を確認し、必要な変更だけコミットします。Zen自体や複数Mac間のバージョン差によりJSONが変更される可能性があります。必要ならGit履歴から戻してください。
- Zen Syncとこのファイルの干渉、Zenアップデート時の書込み、実アプリがシンボリックリンクを維持するかは未検証です。別のMacで使い始める前に実機で確認してください。
- `prefs.js`、履歴、Cookie、認証情報、プロファイル全体を本リポジトリへコピーしないでください。
