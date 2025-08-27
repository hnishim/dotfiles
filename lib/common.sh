#!/bin/bash

# 共通処理ライブラリ
# 各シェルスクリプトで使用する共通関数と変数を定義

# --- エラーハンドリング設定 ---
set -euo pipefail

# --- 共通変数 ---
# バックアップ用の日付（_YYYYMMDD形式）を取得
BACKUP_DATE=$(date +%Y%m%d)

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

log_error() {
    echo "[ERROR] $1" >&2
}

log_success() {
    echo "[SUCCESS] $1"
}

log_warning() {
    echo "[WARNING] $1"
}

# --- ユーティリティ関数 ---

# スクリプトのディレクトリパスを取得
get_script_dir() {
    cd -- "$(dirname -- "${BASH_SOURCE[1]}")" &> /dev/null && pwd
}

# スクリプトのルートディレクトリ（dotfiles）を取得
get_dotfiles_root() {
    cd "$(dirname -- "${BASH_SOURCE[1]}")" &> /dev/null && cd .. && pwd
}

# --- バックアップ処理関数 ---

# バックアップディレクトリを作成
create_backup_dir() {
    local backup_dir="$1"
    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir"
        log_success "バックアップディレクトリを作成しました: $backup_dir"
    else
        log_info "バックアップディレクトリは既に存在します: $backup_dir"
    fi
}

# 既存ファイルをバックアップ
backup_existing_file() {
    local source_file="$1"
    local backup_dir="$2"
    local backup_name="$3"
    
    if [ -e "$source_file" ] || [ -L "$source_file" ]; then
        mv "$source_file" "$backup_dir/${backup_name}_${BACKUP_DATE}"
        log_success "既存のファイルをバックアップしました: ${backup_name}_${BACKUP_DATE}"
        return 0
    fi
    return 1
}

# --- シンボリックリンク処理関数 ---

# シンボリックリンクの状態を確認
check_symlink() {
    local link_path="$1"
    local target_path="$2"
    
    if [ -L "$link_path" ] && [ "$(readlink "$link_path")" = "$target_path" ]; then
        return 0  # 正しくリンクされている
    else
        return 1  # リンクされていない、または間違ったリンク
    fi
}

# シンボリックリンクを作成（既存ファイルはバックアップ）
create_symlink() {
    local source_file="$1"
    local link_path="$2"
    local backup_dir="$3"
    local backup_name="$4"
    local file_label="$5"
    
    if check_symlink "$link_path" "$source_file"; then
        log_success "$file_label は既に正しくリンクされています。スキップします。"
        return 0
    fi
    
    log_info "$file_label の設定を開始します..."
    
    # 既存ファイルのバックアップ
    if backup_existing_file "$link_path" "$backup_dir" "$backup_name"; then
        log_info "既存ファイルのバックアップが完了しました"
    fi
    
    # シンボリックリンクの作成
    if ln -sf "$source_file" "$link_path"; then
        if [ -L "$link_path" ]; then
            log_success "$file_label のシンボリックリンクを作成しました"
            return 0
        else
            log_error "$file_label のシンボリックリンク作成に失敗しました"
            return 1
        fi
    else
        log_error "$file_label のシンボリックリンク作成に失敗しました"
        return 1
    fi
}

# --- 前提条件チェック関数 ---

# コマンドの存在確認
check_command() {
    local command_name="$1"
    local install_instruction="$2"
    
    if ! command -v "$command_name" &> /dev/null; then
        log_error "'$command_name' コマンドが見つかりません。$install_instruction"
        return 1
    fi
    log_success "$command_name は利用可能です"
    return 0
}

# パス（ファイルまたはディレクトリ）の存在確認
check_path() {
    local path="$1"
    local description="$2"
    local path_type="${3:-auto}"  # auto, file, directory
    
    case "$path_type" in
        "file")
            if [ ! -f "$path" ]; then
                log_error "$description が見つかりません: $path"
                return 1
            fi
            ;;
        "directory")
            if [ ! -d "$path" ]; then
                log_error "$description が存在しません: $path"
                return 1
            fi
            ;;
        "auto"|*)
            if [ ! -e "$path" ]; then
                log_error "$description が存在しません: $path"
                return 1
            fi
            ;;
    esac
    
    log_success "$description が存在します: $path"
    return 0
}

# --- パッケージ管理関数 ---

# Homebrewパッケージのインストール確認・インストール
check_and_install_brew_package() {
    local package_name="$1"
    local package_label="$2"
    
    log_info "$package_label のインストール状態を確認中..."
    
    if brew list "$package_name" &> /dev/null; then
        log_success "$package_label は既にインストールされています"
        return 0
    else
        log_info "$package_label をインストール中..."
        if brew install "$package_name"; then
            log_success "$package_label のインストールが完了しました"
            return 0
        else
            log_error "$package_label のインストールに失敗しました"
            return 1
        fi
    fi
}

# --- 設定ファイル処理関数 ---

# YAMLファイルから値を取得（yq使用）
get_yaml_value() {
    local yaml_file="$1"
    local yq_query="$2"
    
    check_command "yq" "'brew install yq' を実行してインストールしてください。" || return 1
    
    yq e "$yq_query" "$yaml_file" 2>/dev/null
}

# JSONファイルから値を取得（jq使用）
get_json_value() {
    local json_file="$1"
    local jq_query="$2"
    
    check_command "jq" "'brew install jq' を実行してインストールしてください。" || return 1
    
    jq -r "$jq_query" "$json_file" 2>/dev/null
}

# --- システム操作関数 ---

# プロセスの再起動
restart_process() {
    local process_name="$1"
    local service_name="$2"
    
    log_info "$process_name を再起動中..."
    
    if launchctl kickstart -k "gui/$(id -u)/$service_name"; then
        log_success "$process_name の再起動が完了しました"
        return 0
    else
        log_error "$process_name の再起動に失敗しました"
        return 1
    fi
}

# アプリケーションの終了
kill_app() {
    local app_name="$1"
    
    if killall "$app_name" 2>/dev/null; then
        log_success "$app_name を終了しました"
        return 0
    else
        log_warning "$app_name の終了に失敗しました（既に終了している可能性があります）"
        return 1
    fi
}

# --- 引数解析関数 ---

# ブール値フラグの解析
parse_boolean_flag() {
    local flag_name="$1"
    local flag_value="$2"
    
    case "$flag_value" in
        --"$flag_name")
            echo "true"
            ;;
        *)
            echo "false"
            ;;
    esac
}

# --- 完了メッセージ関数 ---

# セットアップ完了メッセージ
show_completion_message() {
    local script_name="$1"
    local symlinks="$2"
    local backup_dir="$3"
    
    echo ""
    log_success "=== $script_name 完了 ==="
    
    if [ -n "$symlinks" ]; then
        echo "作成されたシンボリックリンク:"
        echo "$symlinks"
    fi
    
    if [ -n "$backup_dir" ]; then
        echo "バックアップファイル:"
        echo "  $backup_dir/"
    fi
}
