#!/bin/bash

# textlintと関連ルールのセットアップ、設定ファイルの同期を行うスクリプト

set -euo pipefail # エラー時に即座に終了、未定義変数の使用を禁止

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

# --- ログ出力関数 ---
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_success() {
    echo "[SUCCESS] $1"
}

# --- 前提条件チェック ---
log_info "前提条件をチェックしています..."

# Node.jsのチェック (ご指定の `brew list | grep node` よりも確実な `command -v` を使用)
if ! command -v node &> /dev/null; then
    log_error "Node.jsがインストールされていません。'brew install node' またはリポジトリの 'brew-setup.sh' を実行してインストールしてください。"
    exit 1
fi
log_success "Node.js はインストール済みです。"

# npmのチェック
if ! command -v npm &> /dev/null; then
    log_error "npmがインストールされていません。Node.jsのインストール状況を確認してください。"
    exit 1
fi
log_success "npm はインストール済みです。"

# jqのチェック (ルールのパースに必要)
if ! command -v jq &> /dev/null; then
    log_error "jqがインストールされていません。'brew install jq' を実行してインストールしてください。"
    exit 1
fi
log_success "jq はインストール済みです。"

# 設定ファイルの存在チェック
if [ ! -f "$ICLOUD_TEXTLINT_CONFIG" ]; then
    log_error "textlint設定ファイルが見つかりません: $ICLOUD_TEXTLINT_CONFIG"
    exit 1
fi
# .textlintrc.json で prh が有効になっているため、辞書ファイルもチェック
if [ ! -f "$ICLOUD_PRH_CONFIG" ]; then
    log_error "prh辞書ファイルが見つかりません: $ICLOUD_PRH_CONFIG"
    exit 1
fi
log_success "設定ファイルが見つかりました。"

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
rule_keys=$(jq -r '.rules | to_entries[] | select(.value != false) | .key' "$ICLOUD_TEXTLINT_CONFIG")

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
mkdir -p "$BACKUP_DIR"

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

echo ""
log_success "=== textlintのセットアップが完了しました ==="
log_info "VSCodeやCursorで 'textlint' 拡張機能をインストールすると、エディタ上でリアルタイムに校正が実行されます。"
