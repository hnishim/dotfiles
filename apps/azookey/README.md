# AzooKey用TSVの保存先と初回移行手順

`CustomInputTable/custom_input_table.tsv` をdotfilesで管理します。AzooKey本体の保存先は
`~/Library/Containers/dev.ensan.inputmethod.azooKeyMac/Data/Library/Application Support/azooKeyMac/CustomInputTable/custom_input_table.tsv` です。
TSVの保存ではファイル自体が原子的に置き換えられるため、ファイルではなく親ディレクトリをシンボリックリンクします。

## 初回移行（Macで一度だけ）

1. AzooKeyの設定画面を閉じ、入力メソッドも終了します。元の `CustomInputTable/` にあるファイルを確認します。TSVがなければ、azooKeyでカスタムルールを作成して保存してから移行します。用途不明のファイルを見つけたら、移行せず内容を確認します
2. 元の `CustomInputTable/` ディレクトリ全体を別名・別の場所に退避し、削除しないでください。退避前に実TSVを `apps/azookey/CustomInputTable/custom_input_table.tsv` にコピーし、元ファイルと内容が一致することを確認します。架空のTSVや空のファイルは作りません
3. 元のアプリ側ディレクトリを退避先に移した後、dotfilesのルートから `bash apps/azookey/azookey-setup.sh` を実行します。既存のディレクトリや別のリンクが残る場合は、共通の `create_symlink()` が上書きせずエラーにします。自動移行や自動削除は行いません
4. リンク先が `apps/azookey/CustomInputTable/` と一致し、再実行後も同じリンクが保たれることを確認します。AzooKeyを起動し、カスタム入力方式が未選択ならGUIで選択します。登録済みルールで変換できることと、ルール保存後もリンクが残ってdotfiles側のTSVが更新されることを確認してください

TSVがまだdotfilesにないMacでは、セットアップは警告を表示してazooKeyの処理だけをスキップします。

## 変更の反映

AzooKeyのGUIでルールを編集・保存したら、`git diff -- apps/azookey/CustomInputTable/custom_input_table.tsv` で差分を確認して通常どおりGitに反映します。取り込むのは実際のカスタムルールだけです。学習辞書、個人入力履歴、ほかの設定は管理しません。
