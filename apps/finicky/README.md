# Finickyのルーティング設定

`finicky.js` をこのリポジトリで管理し、`~/.config/finicky/finicky.js` からシンボリックリンクします。セットアップは不足している `~/.config` と `~/.config/finicky` を作成します。同じリンクで再実行できます。別のファイル、ディレクトリ、リンクが配置先にある場合は上書きしません。

## 初回適用

Finickyは設定を複数の場所から探索します。公式文書では `~/.finicky.js`、`~/.finicky.ts`、`~/.config/finicky.js`、`~/.config/finicky.ts` をこのリポジトリの配置先より先に確認します。古い設定があると、管理対象の設定が読み込まれないことがあります。[Finicky公式の設定場所と初回設定](https://github.com/johnste/finicky/wiki/Getting-started)を参照してください。

1. 上記の古い設定場所にファイルがないか確認します。ある場合は内容を確認し、このリポジトリの `finicky.js` に必要な設定を手動で反映します。
2. 古い設定ファイルを検索対象外へ手動で退避します。セットアップは既存設定の移動・削除・上書きを行いません。
3. dotfilesのルートから `bash apps/finicky/finicky-setup.sh` を実行します。`setup-macos.sh` にも登録済みです。
4. `ls -l "$HOME/.config/finicky/finicky.js"` と `readlink "$HOME/.config/finicky/finicky.js"` で、このリポジトリの `apps/finicky/finicky.js` へのリンクを確認します。
5. Finickyを起動して設定の読込みを確認します。Personal、MOLCURE、H2OのURL、Personal用とMOLCURE用のNotion URL、Shiftを押して開くGoogle Meet、未一致URLを確認してください。Zenの `Personal`、`MOLCURE`、`H2O` のSpaceがあることも確認します。

配置先に既存ファイルや別のリンクがある場合は、内容とリンク先を確認してから手動で退避し、セットアップを再実行してください。親ディレクトリの位置にファイルがある場合も、自動削除や置換はせずに失敗します。

## 既定ブラウザー

FinickyがmacOSから通常のURLを受け取るには、Finickyを既定のWebブラウザーに設定します。macOSの「システム設定」から既定のWebブラウザーを選び、`open "https://x.com/"` などで実際の振り分け先を確認してください。

現在の `duti/duti_settings.duti` は `http` をZenに割り当てています。`setup-macos.sh` を実行するとこの設定が適用されるため、Finickyを既定にした後に全体セットアップを再実行すると、既定ブラウザーがZenへ戻ることがあります。このIssueではdutiの割り当ては変更しません。

## 別のMacで使う場合

1. FinickyとZenをインストールし、Zenに `Personal`、`MOLCURE`、`H2O` のSpaceを用意します。
2. 既存のFinicky設定を確認・退避してから、dotfilesを配置します。
3. dotfilesのルートで `bash apps/finicky/finicky-setup.sh` または `bash setup-macos.sh` を実行します。
4. Finickyを既定ブラウザーに設定し、各ルールと未一致URLの動作を実機で確認します。

Finickyの実アプリによる設定読込み、各URLの振り分け、ZenのSpace指定とShift判定は、各Macで確認してください。
