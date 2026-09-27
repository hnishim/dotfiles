# Custom InstructionsとNotionの同期

このセットアップが登録するLaunchAgentは、MOLCUREのNotionだけを同期します。認証情報は設定ファイルへ保存せず、実行ごとに選択した認証経路から取得します。

## MOLCUREの設定

設定ファイルにはMOLCUREの利用者・ワークスペース・同期先を記録します。各IDは実際に使うMOLCUREの値に置き換えてください。

```ini
account_id=molcure
credential_source=ntn-default
expected_user_id=<Notion user ID>
workspace_id=<Notion workspace ID>
custom_instructions_page_id=<Custom Instructions page ID>
user_profile_page_id=<User Profile page ID>
skills_data_source_id=<Skills data source ID>
```

`credential_source=ntn-default` は `ntn` の既定認証を使います。セットアップと同期の前に、認証先の利用者ID・ワークスペースID、および3つの対象IDを照合します。照合できない場合はNotionへの更新を始めません。同期済み判定の保存先はアカウント、ワークスペース、対象IDごとに分かれます。

設定ファイルを手で作る場合は、アクセス権を所有者だけにしてください。認証情報は設定ファイルやログへ記録しません。

## セットアップと実行

`custom-instructions-setup.sh` はMOLCURE専用です。既定でMOLCUREを選び、生成する設定ファイルとLaunchAgentの両方にMOLCUREを明示します。Personalの設定が保存済みの場合や `NOTION_ACCOUNT_ID_OVERRIDE=personal` が渡された場合は、NotionへアクセスせずLaunchAgentも登録しません。`ntn` が実行できない場合もLaunchAgentを登録しません。

このLaunchAgentでPersonal Notionは同期しません。Personalアカウントの読み取り確認は `ntn` を直接使って行い、Personal用の同期先や同期設定は作りません。

手動で同期する場合もMOLCUREの設定ファイルを指定します。

```bash
SUPPORT="$HOME/Library/Application Support/my.notion.sync"
HELPER="$HOME/Applications/Custom Instructions Sync.app/Contents/MacOS/CustomInstructionsSync"
NTN="$(command -v ntn)"
CONFIG="$SUPPORT/notion-pages.conf"

"$SUPPORT/sync-custom-instructions" "$HELPER" "$NTN" "${CODEX_HOME:-$HOME/.codex}" "$CONFIG"
```

以前の形式で `notion-pages.conf` にアカウント項目がない場合は、互換性のためMOLCUREの `ntn-default` として扱います。セットアップを再実行すると利用者IDを確認し、明示的なMOLCURE設定へ更新します。
