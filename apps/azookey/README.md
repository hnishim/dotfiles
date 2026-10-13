# AzooKeyカスタム入力表の同期

apps/azookey/CustomInputTable/custom_input_table.tsvを正本として、AzooKeyのコンテナ内にある表へ一方向に同期します。辞書、入力履歴、その他の設定は対象外です。

## 初回設定と手動同期

初回設定ではAzooKeyの設定画面を閉じ、入力メソッドを終了してください。dotfilesのルートで、次の同じコマンドを実行します。

    bash apps/azookey/azookey-setup.sh

dotfiles側の表を編集した後や、別端末からのiCloud同期が終わった後も、同じコマンドを実行してください。

    bash apps/azookey/azookey-setup.sh

新しい許可や別の利用者向け同期コマンドは必要ありません。

## 同期と競合

セットアップは既存のリンク先がdotfilesの正本と一致する場合だけ、リンクをコンテナ内の実ディレクトリへ移します。保存先がない場合や空の場合は初期化します。表以外の資産、想定外のリンク、異なる保存先データがあれば上書きせず停止します。正本の表は削除・変更しません。

同期先が前回の同期内容から独立して変更されていた場合は、その内容を保全して以降の同期を止めます。正本TSVが不正・欠落・読取不能の場合、同期状態が欠落・破損している場合、コピーや原子的置換に失敗した場合も既存表を上書きしません。状態書込み後に失敗した場合は、同じコマンドを再実行すると整合を確認できます。

内容の差分は次で確認できます。

    git diff -- apps/azookey/CustomInputTable/custom_input_table.tsv

ログには処理結果だけを記録し、表の内容は記録しません。GUIで保存した変更はdotfilesへ戻しません。編集元はdotfiles側の正本に統一してください。

## 旧LaunchAgentの退役

セットアップ時に、旧LaunchAgentが稼働中なら停止し、~/Library/LaunchAgents/my.azookey.sync.plistがあれば内容を保全して退避します。通常の退避先は~/Library/Application Support/my.azookey.sync/my.azookey.sync.plist.disabledです。既存の退避先がある場合は別名を使い、上書きしません。実際の退避先はコマンド結果に表示します。

停止や退避に失敗した場合は、表の移行・同期を進めずに理由を表示します。退避失敗時は次回ログイン時にも旧Agentが起動する可能性が残るため、結果に表示された状態を確認してください。退避後に同期が失敗しても、旧Agentやplistを自動で再有効化しません。

## AzooKeyでの反映

同期先の表を置き換えた後、起動中のAzooKeyがいつ表を読み直すかは未確認です。変換セッションを作り直した場合と、AzooKeyを次回起動した場合を分けて実入力で確認してください。このコマンドはAzooKeyを終了・再起動しません。
