#!/bin/bash

# macOSセットアップ用マスタースクリプト
# 各種設定スクリプトを依存関係を考慮して実行する

set -euo pipefail

# --- 変数定義 ---
# このスクリプトが存在するディレクトリをdotfilesのルートとする
DOTFILES_ROOT=$(cd "$(dirname "$0")" && pwd)

# --- ログ出力関数 ---
log_header() {
    echo ""
    echo "================================================================================"
    echo " $1"
    echo "================================================================================"
    echo ""
}

log_info() {
    echo "[INFO] $1"
}

log_success() {
    echo "[SUCCESS] $1"
}

# --- メイン処理 ---
log_header "macOS セットアップ開始"

# sudoのパスワードを最初に入力させる
log_info "一部の処理で管理者権限が必要です。パスワードを入力してください。"
sudo -v
# セッションが切れないように、バックグラウンドでsudoの状態を維持する
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

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
)

for script in "${setup_scripts[@]}"; do
    script_path="$DOTFILES_ROOT/$script"
    log_info "実行中: $script"
    bash "$script_path"
done

log_header "全てのセットアップが完了しました！"
echo "一部の設定を反映させるには、システムの再起動が必要な場合があります。"
