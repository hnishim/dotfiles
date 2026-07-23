#!/bin/bash

# macOSセットアップ用マスタースクリプト
# 各種設定スクリプトを依存関係を考慮して実行する

# 共通ライブラリを読み込み
source "$(dirname "$0")/lib/common.sh"

# --- 変数定義 ---
# このスクリプトが存在するディレクトリをdotfilesのルートとする
DOTFILES_ROOT=$(cd "$(dirname "$0")" && pwd)

# --- メイン処理 ---
log_header "macOS セットアップ開始"

# 1. Homebrew & アプリケーションのインストール
# このスクリプトに渡された引数（--personal, --business, --update）をそのままbrew.shに渡す
log_header "Step 1: Homebrew & アプリケーションのインストール"
if "$DOTFILES_ROOT/brew/brew-setup.sh" "$@"; then
    log_success "Homebrew & アプリケーションのインストール完了"
else
    brew_status=$?
    log_error "Homebrew & アプリケーションのインストールに失敗しました（終了コード: ${brew_status}）"
    exit "$brew_status"
fi

# 2. それ以外の設定
# 実行するセットアップスクリプトを配列で定義
setup_scripts=(
    "defaults/defaults-setup.sh"
    "nextdns/nextdns-setup.sh"
    "duti/duti-setup.sh"
    "karabiner-elements/karabiner-setup.sh"
    "gitignore/global-gitignore-setup.sh"
    "warp/warp-setup.sh"
    "cursor/cursor-setup.sh"
    "ferdium/ferdium-setup.sh"
    "textlint/textlint-setup.sh"
)

for script in "${setup_scripts[@]}"; do
    script_path="$DOTFILES_ROOT/$script"
    log_info "実行中: $script"
    if bash "$script_path"; then
        log_success "$script の実行が完了しました"
    else
        script_status=$?
        log_error "$script の実行に失敗しました（終了コード: ${script_status}）"
        exit "$script_status"
    fi
done

log_header "全てのセットアップが完了しました！"
echo "一部の設定を反映させるには、システムの再起動が必要な場合があります。"
