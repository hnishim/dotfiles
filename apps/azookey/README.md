# AzooKeyカスタム入力表の同期

dotfilesの CustomInputTable/custom_input_table.tsv を正本として、AzooKeyのコンテナ内にある実ファイルへ一方向に自動反映します。辞書、入力履歴、その他の設定は対象外です。

## 初回設定

初回移行ではAzooKeyの設定画面を閉じ、入力メソッドを終了してください。dotfilesのルートで次を一度実行します。

    bash apps/azookey/azookey-setup.sh

セットアップは既存のリンク先がdotfilesの正本と一致する場合だけ、リンクをコンテナ内の実ディレクトリへ移します。表以外のファイル、想定外のリンク、異なる保存先データがあれば、上書きせず停止します。正本のTSVは削除・変更しません。

## 編集と自動反映

編集するファイルは apps/azookey/CustomInputTable/custom_input_table.tsv です。AzooKey側はApp Sandbox内の実ファイルに書き込むため、GUIで編集した変更をdotfilesへ戻しません。GUIから別の内容を保存すると、そのデータを保持したまま同期を停止します。停止理由は ~/Library/Application Support/my.azookey.sync/sync.log で確認してください。

LaunchAgentは正本を含むディレクトリの WatchPaths と RunAtLoad で動きます。固定間隔の定期実行やAzooKeyの自動再起動はありません。ローカル編集はファイル変更イベントで反映しますが、iCloud Driveの更新やスリープ復帰後にイベントが届くか、最大反映時間は保証できません。イベントを受け取れなかった場合は、次の変更通知またはLaunchAgentの再読込まで反映が遅れることがあります。

同じ入力セッション中に表が再読込されるかは、AzooKeyの実動作を確認するまで未確定です。自動同期は表をアプリの保存先へ置き換えるところまで行い、アプリを終了・再起動しません。反映を確認するときは、変換セッションを作り直した場合とAzooKeyを次回起動した場合を分けてください。

同期先で前回の同期内容と異なる編集を見つけると、その内容を保持して以降の同期を停止します。正本TSVに不正な行がある場合、同期状態が欠落・破損した場合、コピーや原子的置換に失敗した場合も、既存の同期先を上書きしません。競合を確認するときは、同期先と正本の内容を別々に確認してください。内容の確認には次を使えます。

    git diff -- apps/azookey/CustomInputTable/custom_input_table.tsv

ログには処理結果だけを記録し、表の内容は記録しません。設定を再実行するとLaunchAgentを登録し直し、保存先との整合を確認します。設定再実行は通常の手動同期手段ではありません。

## 停止と復元

AzooKeyをアプリ内保存へ戻す場合は、LaunchAgentを停止します。コンテナ内の実ディレクトリと表は残すため、AzooKeyはそのまま保存できます。

    launchctl bootout "gui/$(id -u)/my.azookey.sync"
    rm "$HOME/Library/LaunchAgents/my.azookey.sync.plist"

停止後もdotfiles側の正本と同期状態・ログはそのまま残ります。自動反映を再開するときは、初回設定と同じセットアップコマンドを実行してください。
