#!/bin/bash

# 共通処理ライブラリ
# 各シェルスクリプトで使用する共通関数と変数を定義

# --- エラーハンドリング設定 ---
set -euo pipefail

# --- ログ出力関数 ---
log_header() {
    echo "" >&2
    echo "================================================================================" >&2
    echo " $1" >&2
    echo "================================================================================" >&2
    echo "" >&2
}

log_info() {
    echo "[INFO] $1" >&2
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_success() {
    echo "[SUCCESS] $1" >&2
}

log_warning() {
    echo "[WARNING] $1" >&2
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

# ディレクトリが存在することを保証する
ensure_directory() {
    local directory="$1"
    local description="${2:-ディレクトリ}"

    if [ -d "$directory" ]; then
        log_info "${description}は既に存在します: $directory"
    elif mkdir -p "$directory"; then
        log_success "${description}を作成しました: $directory"
    else
        log_error "${description}の作成に失敗しました: $directory"
        return 1
    fi
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

# シンボリックリンクを作成（既存の競合対象は変更しない）
create_symlink() {
    local source_file="$1"
    local link_path="$2"
    local file_label="$3"
    
    if check_symlink "$link_path" "$source_file"; then
        log_success "$file_label は既に正しくリンクされています。スキップします。"
        return 0
    fi
    
    log_info "$file_label の設定を開始します..."

    if [ -e "$link_path" ] || [ -L "$link_path" ]; then
        log_error "$file_label のリンク先に既存の競合があるため変更しません: $link_path"
        return 1
    fi

    if ! ln -s "$source_file" "$link_path"; then
        log_error "$file_label のシンボリックリンク作成に失敗しました"
        return 1
    fi

    if check_symlink "$link_path" "$source_file"; then
        log_success "$file_label のシンボリックリンクを作成しました"
        return 0
    fi

    log_error "$file_label のシンボリックリンク作成結果を確認できません"
    return 1
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
