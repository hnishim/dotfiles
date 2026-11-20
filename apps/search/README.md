# Search Browserのスペース振り分け設定

`Send links to a space` はSearchのiCloud同期の対象外なので、`routes.json` と `search-setup.sh` で再現します。`defaults/defaults-setup.sh` とは独立しています。現時点ではマスターの `setup-macos.sh` には追加していません（実機で設定を確認してから組み込む想定）。

## 準備と適用

1. Search Browserで `Personal` / `MOLCURE` / `H2O` という名前のスペースを作成し、必要ならSearchのスペース同期を済ませます。これらが既存の**プロファイル**であってスペースではない場合は、そのプロファイル内の実際のスペース名を `routes.json` に指定します。同名のスペースが複数ある場合は対象グループへ `"profile": "プロファイル名"` を追加します。
2. Searchの **Settings → Spaces & Pins** でスペース機能を有効にします。
3. Searchを完全終了してから、dotfilesリポジトリのルートで以下を実行します。

```bash
bash apps/search/search-setup.sh --check
bash apps/search/search-setup.sh
```

`--check` は設定を変更しません。適用時はSearchが起動中なら停止し、現在の2キーの設定だけを `~/Library/Application Support/Search Routing Backups/` にバックアップします。すでに一致している場合は何も書き込みません。

## 設定ファイル

`routes.json` に、スペース名と対象ドメインの一覧を定義します。Searchは `www.` を除外したホスト名で照合します。サブドメインにも適用されるため、狭い範囲に限定したい場合は `molcure.slack.com` のように具体的に記述します。同じドメインを複数スペースには指定できません。

ルールの保存場所はmacOSの `UserDefaults` です。

- `com.officecommun.search` の `spaces.links` （有効化）
- `com.officecommun.search` の `spaces.links.rules` （`site` / `space` UUIDの辞書配列）

内部UUIDは各Macの `~/Library/Application Support/Search/spaces.json` から都度解決し、dotfilesには固定しません。スペースが見つからない、名前が重複して一意に決まらない、保存形式が想定外、といった場合は既存設定を変更せず停止します。Searchのplist全体は書き換えません。

## Finickyからの移行上の制約

`routes.json` は現行の `apps/finicky/finicky.js` にあるドメイン単位の規則を初期値として作っています。次の規則はSearchのルーティングが対応しないため入れていません。

- `notion.so` / `notion.com` のURLパス別のPersonal/MOLCURE振り分け
- Shiftキーを押したときだけGoogle Meetを既定動作に戻す例外

`meet.google.com` は通常時のルールとしてH2Oに振り分けます。`www.linkedin.com` はSearchの仕様に合わせ `linkedin.com` として扱うため、Zenの部分一致より対象範囲が広くなります。未一致URLの挙動もFinickyと完全には同じになりません。

## テスト

```bash
python3 -m unittest discover -s apps/search/tests -v
```

macOS実機での `defaults write` とSearch Browserによる動作確認は、別途実施してください。
