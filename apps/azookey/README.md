# azooKeyのカスタムローマ字変換表

`CustomInputTable/custom_input_table.tsv` をdotfilesで管理します。azooKey本体の保存先は
`~/Library/Application Support/azooKeyMac/CustomInputTable/custom_input_table.tsv` です。
TSVの保存ではファイル自体が原子的に置き換えられるため、ファイルではなく親ディレクトリをシンボリックリンクします。

## 初回移行（Macで一度だけ）

1. azooKeyの設定画面と入力メソッドを終了します。元の `CustomInputTable/` の内容と実際のTSVを確認します。TSVが存在しない場合は、azooKeyでカスタムルールを作成・保存してから作業します。用途が不明な別ファイルがある場合は、移行せず確認します。
2. 元の `CustomInputTable/` ディレクトリ全体を別名・別の場所に退避し、削除しないでください。退避前に実TSVを `apps/azookey/CustomInputTable/custom_input_table.tsv` にコピーし、元ファイルと内容が一致することを確認します。架空のTSVや空のファイルは作りません。
3. 元のアプリ側ディレクトリを退避先に移した後、dotfilesのルートから `bash apps/azookey/azookey-setup.sh` を実行します。既存のディレクトリや別のリンクが残る場合は、共通の `create_symlink()` が上書きせずエラーにします。自動移行や自動削除は行いません。
4. ディレクトリリンクが正しいこと、再実行しても変わらないことを確認します。azooKeyを起動し、必要に応じてGUIでカスタム入力方式を選び、変換とルール保存を確認します。GUI保存後もリンクが残り、dotfiles側のTSVが更新されることを確認してください。

TSVがまだdotfilesにないMacでは、セットアップは警告を表示してazooKeyの処理だけをスキップします。

## 変更の反映

azooKeyのGUIでルールを編集・保存したら、`git diff -- apps/azookey/CustomInputTable/custom_input_table.tsv` で差分を確認して通常どおりGitに反映します。取り込むのは実際のカスタムルールだけです。学習辞書、個人入力履歴、ほかの設定は管理しません。
