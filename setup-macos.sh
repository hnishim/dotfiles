#!/bin/bash

# macOSセットアップ用マスタースクリプト
# 各種設定スクリプトを依存関係を考慮して実行する

# 共通ライブラリを読み込み
source "$(dirname "$0")/lib/common.sh"

# --- 変数定義 ---
# このスクリプトが存在するディレクトリをdotfilesのルートとする
DOTFILES_ROOT=$(cd "$(dirname "$0")" && pwd)

refresh_sudo_credentials() {
    # バックグラウンドでsudoを実行すると、TTY操作時にジョブが停止することがあるため、
    # 必要なタイミングでフォアグラウンドから認証を更新する。
    if sudo -n true </dev/null >/dev/null 2>&1; then
        return
    fi

    log_info "sudoの認証期限が切れています。パスワードを入力してください。"
    if ! sudo -v; then
        log_error "sudoの認証に失敗しました"
        exit 1
    fi
}

# --- メイン処理 ---
log_header "macOS セットアップ開始"

# sudoのパスワードを最初に入力させる
log_info "一部の処理で管理者権限が必要です。パスワードを入力してください。"
if ! sudo -v; then
    log_error "sudoの認証に失敗しました"
    exit 1
fi

# 1. Homebrew & アプリケーションのインストール
# このスクリプトに渡された引数（--personal, --business）をそのままbrew.shに渡す
log_header "Step 1: Homebrew & アプリケーションのインストール"
"$DOTFILES_ROOT/brew/brew-setup.sh" "$@"
log_success "Homebrew & アプリケーションのインストール完了"

# 2. それ以外の設定
# 実行するセットアップスクリプトを配列で定義
setup_scripts=(
    "defaults/defaults-setup.sh"
    "duti/duti-setup.sh"
    "karabiner-elements/karabiner-setup.sh"
    "gitignore/global-gitignore-setup.sh"
    "warp/warp-setup.sh"
    "cursor/cursor-setup.sh"
    "ferdium/ferdium-setup.sh"
    "textlint/textlint-setup.sh"
    "nextdns/nextdns-setup.sh"
)

for script in "${setup_scripts[@]}"; do
    script_path="$DOTFILES_ROOT/$script"
    refresh_sudo_credentials
    log_info "実行中: $script"
    bash "$script_path"
done

log_header "全てのセットアップが完了しました！"
echo "一部の設定を反映させるには、システムの再起動が必要な場合があります。"
