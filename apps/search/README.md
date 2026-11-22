# Search Browserの設定管理

Search固有の利用者設定と「Send links to a space」の振り分けルールを管理します。`defaults/defaults-setup.sh` とは独立しており、既存の `setup-macos.sh` から `search-setup.sh` が実行されます。

## 準備と適用

1. Search Browserで `Personal`/`MOLCURE`/`H2O` の**3プロファイル（各1スペース）**を用意します。各プロファイルのスペース名をそれぞれ同名にします。スペース名が重複する場合だけ、`routes.json` の対象グループに `"profile": "プロファイル名"` を追加します。プロファイル名に含まれる絵文字は、スペース名が一意なら影響しません
2. Searchの **Settings → Spaces & Pins** でスペース機能を有効にします
3. Searchを完全終了してから、dotfilesリポジトリのルートで以下を実行します

```bash
bash apps/search/search-setup.sh --check
bash apps/search/search-setup.sh
```

`--check` は一般設定と振り分けルールの両方を検証し、何も変更しません。適用時は両方を事前検証し、一般設定→ルーティングの順に実行します。Searchが起動中の場合は書き込みを拒否します。一致している設定は書き込みません。振り分けルールの変更前には2キーの内容だけを `~/Library/Application Support/Search Routing Backups/` に保存します。

## ファイルと管理範囲

- `search-setup.sh`：入口。両設定を事前検証してから順番に適用
- `search-preferences-setup.sh`：外観・サイドバー・タブ・リンク・検索・フォーム等の38項目を `defaults write` で管理。`--check` は読み取り専用
- `search-routes-setup.py`：スペースUUIDを解決して振り分けルールを適用。旧 `search-setup.py` から改名
- `routes.json`：37ドメインの振り分け定義

一般設定だけを確認／適用する場合：

```bash
bash apps/search/search-preferences-setup.sh --check
bash apps/search/search-preferences-setup.sh
```

一般設定スクリプトは `icloud.sync`（iCloudの有効化）、ダウンロード先、カスタム `shortcuts`、CloudKit内部情報、端末ID、ウィンドウ位置、パスワード・履歴・拡張機能の実行時状態は管理しません。`contacts.fill` と `passkeys` を設定しても、macOS側のアクセス権限・署名条件までは付与されません。

## 同期上の注意

新しい「Sync with iCloud」はPersonalプロファイルのスペース・ピン・ブックマーク等のみ対象で、MOLCURE・H2Oの追加プロファイルは自動作成しません。新しいMacでは追加プロファイルと同名スペースを作成してから、このセットアップを実行してください。従来のフォルダ同期でも、異なるUUIDの追加プロファイル同士を自動対応付けするわけではありません。「Send links to a space」は同期対象外です。

## 設定ファイル

`routes.json` では、スペース名と対象ドメインの一覧を定義します。Searchは `www.` を除外したホスト名で照合します。サブドメインも対象です。対象範囲を狭める場合は `molcure.slack.com` のような具体例を記述します。同じドメインは複数のスペースへ割り当てられません。

ルールの保存場所はmacOSの `UserDefaults` です。

- `com.officecommun.search` の `spaces.links`（有効化）
- `com.officecommun.search` の `spaces.links.rules`（`site`/`space` UUIDの辞書配列）

内部UUIDは各Macの `~/Library/Application Support/Search/spaces.json` から都度解決し、dotfilesには固定しません。スペースが見つからない、名前が重複して一意に決まらない、保存形式が想定外、といった場合は既存設定を変更せず停止します。Searchのplist全体は書き換えません。

## Finickyからの移行上の制約

`routes.json` は現行の `apps/finicky/finicky.js` にあるドメイン単位の規則を初期値として作っています。次の規則はSearchのルーティングが対応しないため入れていません。

- `notion.so`/`notion.com` のURLパス別のPersonal/MOLCURE振り分け
- Shiftキーを押したときだけGoogle Meetを既定動作に戻す例外

`meet.google.com` は通常時のルールとしてH2Oに振り分けます。`www.linkedin.com` はSearchの仕様に合わせ `linkedin.com` として扱うため、Zenの部分一致より対象範囲が広くなります。未一致URLの挙動にはFinickyと異なる点があります。

## テスト

```bash
python3 -m unittest discover -s apps/search/tests -v
```

実機のmacOS環境で行う `defaults write` とSearch Browserの動作確認は、別途実施してください。
