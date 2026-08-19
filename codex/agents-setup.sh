#!/bin/bash

# dotfiles内のCustom Agent定義をローカルのCodex設定へシンボリックリンクで同期する

# 共通ライブラリを読み込み
source "$(dirname "$0")/../lib/common.sh"

# --- 変数定義 ---

SCRIPT_DIR=$(get_script_dir)

# テスト時のみ環境変数で差し替え可能。通常はcodex/agentsを正本として使用する。
CODEX_AGENTS_SOURCE_DIR="${CODEX_AGENTS_SOURCE_DIR_OVERRIDE:-$SCRIPT_DIR/agents}"
LOCAL_CODEX_AGENTS_DIR="${LOCAL_CODEX_AGENTS_DIR_OVERRIDE:-$HOME/.codex/agents}"

echo "=== Codex Custom Agent同期スクリプト ==="

# --- メイン処理 ---

log_info "前提条件をチェック中..."
check_path "$CODEX_AGENTS_SOURCE_DIR" "Custom Agent正本ディレクトリ" "directory" || exit 1

agent_count=0
link_count=0
skip_count=0
error_count=0

agent_paths=("$CODEX_AGENTS_SOURCE_DIR"/*.toml)

for agent_path in "${agent_paths[@]}"; do
    if [ ! -f "$agent_path" ]; then
        continue
    fi

    agent_count=$((agent_count + 1))
done

if [ "$agent_count" -eq 0 ]; then
    log_error "TOML形式のCustom Agent定義が見つかりません: $CODEX_AGENTS_SOURCE_DIR"
    exit 1
fi

ensure_directory "$LOCAL_CODEX_AGENTS_DIR" "ローカルCodex Custom Agentディレクトリ" || exit 1

for agent_path in "${agent_paths[@]}"; do
    if [ ! -f "$agent_path" ]; then
        continue
    fi

    agent_filename=$(basename "$agent_path")
    link_path="$LOCAL_CODEX_AGENTS_DIR/$agent_filename"

    if [ -L "$link_path" ]; then
        current_target=$(readlink "$link_path")
        if [ "$current_target" = "$agent_path" ]; then
            log_success "$agent_filename は既に正しくリンクされています。スキップします。"
            skip_count=$((skip_count + 1))
        else
            log_error "$agent_filename には別のシンボリックリンクがあります: $link_path -> $current_target"
            error_count=$((error_count + 1))
        fi
        continue
    fi

    if [ -e "$link_path" ]; then
        log_error "$agent_filename と同名のファイルまたはディレクトリが存在します。上書きしません: $link_path"
        error_count=$((error_count + 1))
        continue
    fi

    if ln -s "$agent_path" "$link_path"; then
        log_success "$agent_filename のシンボリックリンクを作成しました: $link_path -> $agent_path"
        link_count=$((link_count + 1))
    else
        log_error "$agent_filename のシンボリックリンク作成に失敗しました: $link_path"
        error_count=$((error_count + 1))
    fi
done

if [ "$error_count" -gt 0 ]; then
    log_error "$error_count 件のCustom Agent定義を同期できませんでした。"
    exit 1
fi

log_success "Codex Custom Agent同期完了（対象: ${agent_count}、作成: ${link_count}、既存: ${skip_count}）"
