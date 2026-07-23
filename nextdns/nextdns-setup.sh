#!/bin/bash

# NextDNSセットアップスクリプト
# HomebrewでNextDNSをインストールし、構成IDを設定して起動する

# 共通ライブラリを読み込み
NEXTDNS_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
source "$NEXTDNS_SCRIPT_DIR/../lib/common.sh"

# --- 変数定義 ---

# NextDNS設定ID
NEXTDNS_CONFIG_ID="993725"
NEXTDNS_PATH=""
NEXTDNS_CHANGED=0

log_header "=== NextDNSセットアップスクリプト ==="

run_as_root() {
    sudo "$@"
}

# 過去のスクリプトが追加した危険な NOPASSWD 設定を削除
remove_legacy_nextdns_sudoers_rule() {
    local target_user
    target_user="${SUDO_USER:-$(whoami)}"
    local sudoers_file="/private/etc/sudoers.d/nextdns"
    local expected_rule
    expected_rule="$target_user ALL=(root) NOPASSWD: $NEXTDNS_PATH"

    if ! run_as_root test -f "$sudoers_file"; then
        return
    fi

    local tmpfile
    tmpfile=$(mktemp "/tmp/nextdns_sudoers.XXXXXX")
    printf '%s\n' "$expected_rule" > "$tmpfile"

    if run_as_root cmp -s "$tmpfile" "$sudoers_file"; then
        if run_as_root rm -f "$sudoers_file"; then
            log_success "旧NextDNS NOPASSWD設定を削除しました: $sudoers_file"
        else
            rm -f "$tmpfile"
            log_error "旧NextDNS NOPASSWD設定の削除に失敗しました"
            exit 1
        fi
    else
        log_warning "$sudoers_file は旧ルールと一致しないため、自動削除しません"
    fi

    rm -f "$tmpfile"
}

# NextDNSがインストールされているかチェックし、なければインストール
check_and_install_nextdns() {
    check_and_install_brew_package "nextdns" "NextDNS"
}

# 現在のNextDNS設定が期待値と一致するか確認
nextdns_config_matches() {
    local current_config
    if ! current_config=$("$NEXTDNS_PATH" config 2>/dev/null); then
        return 1
    fi

    grep -Fqx "profile $NEXTDNS_CONFIG_ID" <<< "$current_config" &&
        grep -Fqx "report-client-info true" <<< "$current_config" &&
        grep -Fqx "auto-activate true" <<< "$current_config"
}

# NextDNSのlaunchdサービスがインストール済みか確認
nextdns_service_is_installed() {
    [ -f "/Library/LaunchDaemons/nextdns.plist" ]
}

# NextDNSのサービスと設定をインストール
install_nextdns_config() {
    log_info "NextDNSの設定をインストール中..."
    log_info "設定ID: $NEXTDNS_CONFIG_ID"
    
    if run_as_root "$NEXTDNS_PATH" install -profile "$NEXTDNS_CONFIG_ID" -report-client-info -auto-activate; then
        NEXTDNS_CHANGED=1
        log_success "NextDNSの設定が完了しました"
    else
        log_error "NextDNSの設定に失敗しました"
        exit 1
    fi
}

# NextDNSのステータスを取得
get_nextdns_status() {
    local status_output
    if ! status_output=$(run_as_root "$NEXTDNS_PATH" status 2>&1); then
        printf '%s\n' "$status_output" >&2
        return 1
    fi
    printf '%s\n' "$status_output"
}

# NextDNSのステータスを確認（runningかどうかチェック）
check_nextdns_running() {
    local status_output="$1"
    if echo "$status_output" | grep -q "running"; then
        return 0  # running
    else
        return 1  # not running
    fi
}

# NextDNSが停止中の場合だけ起動
ensure_nextdns_running() {
    log_info "NextDNSのステータスを確認中..."
    
    local status_output
    if ! status_output=$(get_nextdns_status); then
        log_error "NextDNSサービスの状態を確認できませんでした"
        exit 1
    fi
    
    if check_nextdns_running "$status_output"; then
        log_success "NextDNSは既に動作中です"
    elif echo "$status_output" | grep -q "stopped"; then
        log_info "NextDNSが停止中です。起動を実行します..."
        if run_as_root "$NEXTDNS_PATH" start; then
            NEXTDNS_CHANGED=1
            log_success "NextDNSの起動が完了しました"
        else
            log_error "NextDNSの起動に失敗しました"
            exit 1
        fi
    else
        log_error "予期しないステータスです: $status_output"
        exit 1
    fi
}

# NextDNSのステータスを確認
check_nextdns_status() {
    log_info "NextDNSのステータスを確認中..."
    
    if [ "$NEXTDNS_CHANGED" -eq 1 ]; then
        sleep 3
    fi
    
    local status_output
    status_output=$(get_nextdns_status)
    
    if check_nextdns_running "$status_output"; then
        log_success "NextDNSが正常に動作しています"
        echo "ステータス詳細:"
        echo "$status_output"
    else
        log_error "NextDNSが正常に動作していません"
        echo "ステータス出力:"
        echo "$status_output"
        exit 1
    fi
}

# --- メイン処理 ---

# 1. Homebrewの確認
log_info "前提条件をチェック中..."
check_command "brew" "先にHomebrewをインストールしてください。" || exit 1

# 2. NextDNSのインストール確認・インストール
check_and_install_nextdns
NEXTDNS_PATH=$(command -v nextdns)

# 2.5 管理者権限の確認と旧NOPASSWD設定の削除
# defaults-setup.sh と同様に、必要な場合だけ対話認証する。
if sudo -n true </dev/null >/dev/null 2>&1; then
    :
elif [ -t 0 ]; then
    log_info "NextDNSの設定にsudo認証が必要です。パスワードを入力してください。"
    if ! sudo -v; then
        log_error "sudoの認証に失敗しました"
        exit 1
    fi
else
    log_error "sudo認証が必要ですが、対話可能なTerminalではありません"
    exit 1
fi
remove_legacy_nextdns_sudoers_rule

# 3. サービスが未導入、または設定が異なる場合だけ更新
if ! nextdns_service_is_installed; then
    log_info "NextDNSサービスが未インストールです"
    install_nextdns_config
elif nextdns_config_matches; then
    log_success "NextDNSの設定は既に期待値と一致しています"
else
    install_nextdns_config
fi

# 4. 停止中の場合だけ起動
ensure_nextdns_running

# 5. ステータス確認
check_nextdns_status

# 完了メッセージの表示
show_completion_message "NextDNSセットアップ" "" ""
