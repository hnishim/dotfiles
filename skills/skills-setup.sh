#!/bin/bash

# iCloud上のCodexスキルをローカルのCodex設定へシンボリックリンクで同期する

# 共通ライブラリを読み込み
source "$(dirname "$0")/../lib/common.sh"

# --- 変数定義 ---

SCRIPT_DIR=$(get_script_dir)
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

ensure_directory "$LOCAL_CODEX_SKILLS_DIR" "ローカルCodexスキルディレクトリ" || exit 1

for skill_path in "${skill_paths[@]}"; do
    if [ ! -d "$skill_path" ] || [ ! -f "$skill_path/SKILL.md" ]; then
        continue
    fi

    skill_name=$(basename "$skill_path")
    link_path="$LOCAL_CODEX_SKILLS_DIR/$skill_name"

    if check_symlink "$link_path" "$skill_path"; then
        log_success "$skill_name は既に正しくリンクされています。スキップします。"
        skip_count=$((skip_count + 1))
        continue
    fi

    create_symlink "$skill_path" "$link_path" "$skill_name" || exit 1
    link_count=$((link_count + 1))
done

if [ "$error_count" -gt 0 ]; then
    log_error "$error_count 件のスキルを同期できませんでした。"
    exit 1
fi

log_success "Codexスキル同期完了（対象: ${skill_count}、作成: ${link_count}、既存: ${skip_count}）"
