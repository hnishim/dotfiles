# Custom InstructionsとNotionの同期

同期設定は、アカウントを識別する項目とNotionの対象IDだけを保存します。認証情報は設定ファイルへ書かず、実行ごとに選択した認証経路から取得します。

## アカウント設定

設定ファイルには次の項目を1行ずつ記録します。各IDは利用するNotionアカウントの実値に置き換えてください。

```ini
account_id=personal
credential_source=keychain
expected_user_id=<Notion user ID>
workspace_id=<Notion workspace ID>
custom_instructions_page_id=<Custom Instructions page ID>
user_profile_page_id=<User Profile page ID>
skills_data_source_id=<Skills data source ID>
```

`account_id` は `molcure` または `personal` です。`credential_source=keychain` はKeychainサービス `my.notion.<account_id>` から認証情報を読みます。`credential_source=ntn-default` はMOLCUREに限り、現在の `ntn` 既定認証からトークンを取得します。個人用アカウントではKeychainを使ってください。

同期前に、選択した認証で `whoami --json` を照合し、利用者IDとワークスペースIDが設定と一致すること、および3つの対象IDを読み取れることを確認します。対象確認やSkillsデータソースの照会が失敗した場合、Notionへの更新を始めません。同期済み判定の保存先はアカウント、ワークスペース、対象IDごとに分かれます。

設定ファイルを手で作る場合は、アクセス権を所有者だけにしてください。Keychainにはトークンを登録しますが、トークン自体は設定ファイルやログへ記録しません。

## セットアップと手動実行

`custom-instructions-setup.sh` を実行すると、対話形式でアカウントとNotion対象を設定でき、生成するLaunchAgentには設定ファイルの場所が保存されます。自動実行は、そのLaunchAgentに渡した設定を使います。

アカウントを切り替える場合は `NOTION_ACCOUNT_ID_OVERRIDE=molcure` または `NOTION_ACCOUNT_ID_OVERRIDE=personal` を指定してセットアップを再実行します。保存済み設定と異なるアカウントを選ぶと、以前のワークスペース・対象IDは引き継がず、選択したアカウントの値を入力または環境変数で渡します。認証状態と利用者IDの確認が済むまで設定ファイルを更新しません。

手動実行では、同期プログラムへ設定ファイルを引数として渡します。別アカウントの設定を用意すれば、同じ同期プログラムを別アカウントで個別に実行できます。

```bash
SUPPORT="$HOME/Library/Application Support/my.notion.sync"
HELPER="$HOME/Applications/Custom Instructions Sync.app/Contents/MacOS/CustomInstructionsSync"
NTN="$(command -v ntn)"
CONFIG="$SUPPORT/notion-pages-personal.conf"

"$SUPPORT/sync-custom-instructions" "$HELPER" "$NTN" "${CODEX_HOME:-$HOME/.codex}" "$CONFIG"
```

別のアカウントには別の設定ファイルを指定します。1つのLaunchAgentは1つの設定ファイルを使うため、自動実行するアカウントを変更するときはセットアップをその設定で再実行してください。

以前の形式で、`notion-pages.conf` にアカウント項目がない場合は、互換性のためMOLCUREの `ntn-default` として扱います。セットアップを再実行すると利用者IDを確認し、明示的なアカウント設定へ更新します。
