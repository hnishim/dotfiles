#!/bin/bash

# textlintと関連ルールのセットアップ、設定ファイルの同期を行うスクリプト

# 共通ライブラリを読み込み
source "$(dirname "$0")/../lib/common.sh"

# --- 変数定義 ---
# このスクリプトが存在するディレクトリ
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
# 設定ファイル
ICLOUD_TEXTLINT_CONFIG="$SCRIPT_DIR/.textlintrc.json"
ICLOUD_PRH_CONFIG="$SCRIPT_DIR/my-prh.yml"
# ホームディレクトリのリンク先
HOME_TEXTLINT_CONFIG="$HOME/.textlintrc.json"
HOME_PRH_CONFIG="$HOME/my-prh.yml"
# バックアップ用ディレクトリ
BACKUP_DIR="$HOME/.config_backup/textlint"
BACKUP_DATE=$(date +%Y%m%d)

# --- 前提条件チェック ---
log_info "前提条件をチェックしています..."

# Node.jsのチェック (ご指定の `brew list | grep node` よりも確実な `command -v` を使用)
check_command "node" "'brew install node' またはリポジトリの 'brew-setup.sh' を実行してインストールしてください。" || exit 1

# npmのチェック
check_command "npm" "Node.jsのインストール状況を確認してください。" || exit 1

# jqのチェック (ルールのパースに必要)
check_command "jq" "'brew install jq' を実行してインストールしてください。" || exit 1

# 設定ファイルの存在チェック
check_file "$ICLOUD_TEXTLINT_CONFIG" "textlint設定ファイル" || exit 1
# .textlintrc.json で prh が有効になっているため、辞書ファイルもチェック
check_file "$ICLOUD_PRH_CONFIG" "prh辞書ファイル" || exit 1

echo ""
log_info "--- textlint本体のインストールを開始します ---"

# textlint本体のインストールチェック (ご指定の grep よりも正確な `npm list` を使用)
if npm list -g --depth=0 textlint &>/dev/null; then
    log_success "textlint は既にインストール済みです。"
else
    log_info "textlint をグローバルにインストールします..."
    if npm install -g textlint; then
        log_success "textlint のインストールに成功しました。"
    else
        log_error "textlint のインストールに失敗しました。"
        exit 1
    fi
fi

echo ""
log_info "--- textlintルールのインストールを開始します ---"
log_info "設定ファイル (.textlintrc.json) を解析しています..."

# .textlintrc.jsonからルールキーを抽出 (値がfalseのものは除外)
rule_keys=$(get_json_value "$ICLOUD_TEXTLINT_CONFIG" '.rules | to_entries[] | select(.value != false) | .key')

if [ -z "$rule_keys" ]; then
    log_info "インストール対象のルールが見つかりませんでした。"
else
    # インストール済みnpmパッケージリストを一度だけ取得して高速化
    installed_packages=$(npm list -g --depth=0 --json)

    echo "$rule_keys" | while IFS= read -r key; do
        # prhはtextlint本体に同梱されているためスキップ
        if [ "$key" = "prh" ]; then
            continue
        fi

        # ルールキーからnpmパッケージ名を決定
        package_name=""
        if [[ "$key" == textlint-rule-* ]]; then
            package_name="$key"
        elif [[ "$key" == preset-* ]]; then
            package_name="textlint-rule-$key"
        elif [[ "$key" == @* ]]; then
            # Scoped package: @scope/name -> @scope/textlint-rule-name
            scope=$(echo "$key" | cut -d'/' -f1)
            name=$(echo "$key" | cut -d'/' -f2)
            if [[ "$name" == textlint-rule-* ]]; then
                package_name="$key"
            else
                package_name="$scope/textlint-rule-$name"
            fi
        else
            package_name="textlint-rule-$key"
        fi

        # 既にインストールされているかチェック
        if echo "$installed_packages" | jq -e ".dependencies[\"$package_name\"]" &>/dev/null; then
            log_success "ルール '$package_name' は既にインストール済みです。"
        else
            log_info "ルール '$package_name' をインストールします..."
            if npm install -g "$package_name"; then
                log_success "ルール '$package_name' のインストールに成功しました。"
            else
                log_error "ルール '$package_name' のインストールに失敗しました。スキップします。"
            fi
        fi
    done
fi

echo ""
log_info "--- 設定ファイルのシンボリックリンクを作成します ---"

# バックアップディレクトリの作成
create_backup_dir "$BACKUP_DIR"

# シンボリックリンク作成用の汎用関数
create_symlink() {
    local source_file=$1
    local link_name=$2
    local file_label=$3

    if [ -L "$link_name" ] && [ "$(readlink "$link_name")" = "$source_file" ]; then
        log_success "$file_label は既に正しくリンクされています。"
    else
        log_info "$file_label の設定を開始します..."
        if [ -e "$link_name" ] || [ -L "$link_name" ]; then
            mv "$link_name" "$BACKUP_DIR/$(basename "$link_name")_${BACKUP_DATE}"
            log_success "既存の $file_label をバックアップしました。"
        fi
        ln -s "$source_file" "$link_name"
        log_success "$file_label のシンボリックリンクを作成しました。"
    fi
}

create_symlink "$ICLOUD_TEXTLINT_CONFIG" "$HOME_TEXTLINT_CONFIG" ".textlintrc.json"
create_symlink "$ICLOUD_PRH_CONFIG" "$HOME_PRH_CONFIG" "my-prh.yml"

# 完了メッセージの表示
symlinks_info="  .textlintrc.json: $HOME_TEXTLINT_CONFIG -> $ICLOUD_TEXTLINT_CONFIG
  my-prh.yml: $HOME_PRH_CONFIG -> $ICLOUD_PRH_CONFIG"

show_completion_message "textlintのセットアップ" "$symlinks_info" "$BACKUP_DIR"
log_info "VSCodeやCursorで 'textlint' 拡張機能をインストールすると、エディタ上でリアルタイムに校正が実行されます。"
