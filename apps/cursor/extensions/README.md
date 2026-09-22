# Cursor拡張機能

通常の拡張機能は `extensions.yml` で管理します。

Mac Path Paste (`hnishim.vscode-path-paste`) は例外として、`cursor-setup.sh` が [ソースリポジトリ](https://github.com/hnishim/vscode-path-paste) の `main` を確認します。未導入または前回導入したコミットから変更された場合は、一時ディレクトリでVSIXを生成し、Cursorへ導入・更新します。同じコミットが導入済みなら省略します。

各Macで通常の `setup-macos.sh` を実行すると同期されます。GitHub ReleasesやMarketplaceでの版更新は不要です。セットアップ未実行中の自動更新は行いません。

最後に導入できたコミットは `~/Library/Application Support/my.cursor.mac-path-paste/installed-commit` に記録します。失敗時は前回の記録を維持し、既存のCursor設定や他の拡張機能を変更しません。ただしCursor CLIによる導入処理自体の原子性は保証されません。
