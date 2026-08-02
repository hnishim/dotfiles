#!/bin/bash

# iCloud上のCodexスキルをローカルのCodex設定へシンボリックリンクで同期する

# 共通ライブラリを読み込み
source "$(dirname "$0")/../lib/common.sh"

# --- 変数定義 ---

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
DOTFILES_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DEV_ROOT=$(cd "$DOTFILES_ROOT/.." && pwd)

# テスト時のみ環境変数で差し替え可能。通常はdotfilesと同じDev配下のskillsを使用する。
ICLOUD_SKILLS_DIR="${ICLOUD_SKILLS_DIR_OVERRIDE:-$DEV_ROOT/skills}"
LOCAL_CODEX_SKILLS_DIR="${LOCAL_CODEX_SKILLS_DIR_OVERRIDE:-$HOME/.codex/skills}"

echo "=== Codexスキル同期スクリプト ==="

# --- メイン処理 ---

log_info "前提条件をチェック中..."
check_path "$ICLOUD_SKILLS_DIR" "iCloud Codexスキルディレクトリ" "directory" || exit 1

skill_count=0
link_count=0
skip_count=0
error_count=0

shopt -s nullglob
skill_paths=("$ICLOUD_SKILLS_DIR"/*)
shopt -u nullglob

for skill_path in "${skill_paths[@]}"; do
    if [ ! -d "$skill_path" ] || [ ! -f "$skill_path/SKILL.md" ]; then
        continue
    fi

    skill_count=$((skill_count + 1))
done

if [ "$skill_count" -eq 0 ]; then
    log_error "SKILL.mdを持つスキルが見つかりません: $ICLOUD_SKILLS_DIR"
    exit 1
fi

if [ ! -d "$LOCAL_CODEX_SKILLS_DIR" ]; then
    mkdir -p "$LOCAL_CODEX_SKILLS_DIR"
    log_success "ローカルCodexスキルディレクトリを作成しました: $LOCAL_CODEX_SKILLS_DIR"
else
    log_info "ローカルCodexスキルディレクトリは既に存在します: $LOCAL_CODEX_SKILLS_DIR"
fi

for skill_path in "${skill_paths[@]}"; do
    if [ ! -d "$skill_path" ] || [ ! -f "$skill_path/SKILL.md" ]; then
        continue
    fi

    skill_name=$(basename "$skill_path")
    link_path="$LOCAL_CODEX_SKILLS_DIR/$skill_name"

    if [ -L "$link_path" ]; then
        current_target=$(readlink "$link_path")
        if [ "$current_target" = "$skill_path" ]; then
            log_success "$skill_name は既に正しくリンクされています。スキップします。"
            skip_count=$((skip_count + 1))
        else
            log_error "$skill_name には別のシンボリックリンクがあります: $link_path -> $current_target"
            error_count=$((error_count + 1))
        fi
        continue
    fi

    if [ -e "$link_path" ]; then
        log_error "$skill_name と同名のファイルまたはディレクトリが存在します。上書きしません: $link_path"
        error_count=$((error_count + 1))
        continue
    fi

    if ln -s "$skill_path" "$link_path"; then
        log_success "$skill_name のシンボリックリンクを作成しました: $link_path -> $skill_path"
        link_count=$((link_count + 1))
    else
        log_error "$skill_name のシンボリックリンク作成に失敗しました: $link_path"
        error_count=$((error_count + 1))
    fi
done

if [ "$error_count" -gt 0 ]; then
    log_error "$error_count 件のスキルを同期できませんでした。"
    exit 1
fi

log_success "Codexスキル同期完了（対象: ${skill_count}、作成: ${link_count}、既存: ${skip_count}）"
