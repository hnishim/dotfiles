#!/bin/bash

# NextDNSセットアップスクリプト
# HomebrewでNextDNSをインストールし、構成IDを設定して起動する

set -euo pipefail # エラー時に即座に終了、未定義変数の使用を禁止

# --- 変数定義 ---

# NextDNS設定ID
NEXTDNS_CONFIG_ID="993725"

# スクリプト自身の場所を基準にパスを決定
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

echo "=== NextDNSセットアップスクリプト ==="

# --- 関数定義 ---
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_success() {
    echo "[SUCCESS] $1"
}

log_warning() {
    echo "[WARNING] $1"
}

# Homebrewがインストールされているかチェック
check_homebrew() {
    if ! command -v brew &> /dev/null; then
        log_error "Homebrewがインストールされていません。先にHomebrewをインストールしてください。"
        exit 1
    fi
    log_success "Homebrewが利用可能です"
}

# NextDNSがインストールされているかチェックし、なければインストール
check_and_install_nextdns() {
    log_info "NextDNSのインストール状態を確認中..."
    
    if brew list nextdns &> /dev/null; then
        log_success "NextDNSは既にインストールされています"
    else
        log_info "NextDNSをインストール中..."
        if brew install nextdns; then
            log_success "NextDNSのインストールが完了しました"
        else
            log_error "NextDNSのインストールに失敗しました"
            exit 1
        fi
    fi
}

# NextDNSの設定をインストール
install_nextdns_config() {
    log_info "NextDNSの設定をインストール中..."
    log_info "設定ID: $NEXTDNS_CONFIG_ID"
    
    if sudo nextdns install -config "$NEXTDNS_CONFIG_ID" -report-client-info -auto-activate; then
        log_success "NextDNSの設定が完了しました"
    else
        log_error "NextDNSの設定に失敗しました"
        exit 1
    fi
}

# NextDNSを再起動
restart_nextdns() {
    log_info "NextDNSを再起動中..."
    
    if sudo nextdns restart; then
        log_success "NextDNSの再起動が完了しました"
    else
        log_error "NextDNSの再起動に失敗しました"
        exit 1
    fi
}

# NextDNSのステータスを確認
check_nextdns_status() {
    log_info "NextDNSのステータスを確認中..."
    
    # 少し待機してからステータスを確認
    sleep 3
    
    local status_output
    if status_output=$(sudo nextdns status 2>&1); then
        if echo "$status_output" | grep -q "running"; then
            log_success "NextDNSが正常に動作しています"
            echo "ステータス詳細:"
            echo "$status_output"
        else
            log_error "NextDNSが正常に動作していません"
            echo "ステータス出力:"
            echo "$status_output"
            exit 1
        fi
    else
        log_error "NextDNSのステータス確認に失敗しました"
        exit 1
    fi
}

# --- メイン処理 ---

echo "NextDNS設定ID: $NEXTDNS_CONFIG_ID"
echo ""

# 1. Homebrewの確認
log_info "前提条件をチェック中..."
check_homebrew

# 2. NextDNSのインストール確認・インストール
check_and_install_nextdns

# 3. NextDNSの設定インストール
install_nextdns_config

# 4. NextDNSの再起動
restart_nextdns

# 5. ステータス確認
check_nextdns_status

echo ""
log_success "=== NextDNSセットアップ完了 ==="
echo "設定ID: $NEXTDNS_CONFIG_ID"
echo "NextDNSが正常に動作しています"