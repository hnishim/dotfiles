#!/bin/bash

# Application Supportにpnpm管理のtextlint runtimeを構築する。
# 既存のdotfiles/textlint/node_modules、ホーム設定、シェル設定は変更しない。
source "$(dirname "$0")/../lib/common.sh"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DOTFILES_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
PACKAGE_JSON="$SCRIPT_DIR/package.json"
LOCKFILE="$SCRIPT_DIR/pnpm-lock.yaml"
TEXTLINT_CONFIG="$SCRIPT_DIR/.textlintrc.json"
PRH_CONFIG="$SCRIPT_DIR/my-prh.yml"
WRAPPER="$DOTFILES_ROOT/bin/textlint"
RUNTIME_PARENT="$HOME/Library/Application Support/dotfiles"
RUNTIME_DIR="$RUNTIME_PARENT/textlint"
RUNTIME_NODE_MODULES="$RUNTIME_DIR/node_modules"

ensure_directory_shape() {
    local path="$1"
    local label="$2"

    if [ -L "$path" ]; then
        log_error "$labelがsymlinkのため変更しません: $path"
        return 1
    fi
    if [ -e "$path" ] && [ ! -d "$path" ]; then
        log_error "$labelがディレクトリではないため変更しません: $path"
        return 1
    fi
}

ensure_manifest_link() {
    local link_path="$1"
    local target_path="$2"
    local label="$3"

    if [ -L "$link_path" ] && [ "$(readlink "$link_path")" = "$target_path" ]; then
        return 0
    fi
    if [ -e "$link_path" ] || [ -L "$link_path" ]; then
        log_error "$labelが想定されたsymlinkではないため変更しません: $link_path"
        return 1
    fi
    ln -s "$target_path" "$link_path"
}

log_info "textlint runtimeの前提条件を確認しています..."
check_command "node" "Node.jsをインストールしてください。" || exit 1
check_command "pnpm" "pnpmをインストールしてください。" || exit 1
check_path "$PACKAGE_JSON" "package.json" "file" || exit 1
check_path "$LOCKFILE" "pnpm-lock.yaml" "file" || exit 1
check_path "$TEXTLINT_CONFIG" ".textlintrc.json" "file" || exit 1
check_path "$PRH_CONFIG" "my-prh.yml" "file" || exit 1
check_path "$WRAPPER" "textlint wrapper" "file" || exit 1

ensure_directory_shape "$HOME/Library" "Library" || exit 1
ensure_directory_shape "$HOME/Library/Application Support" "Application Support" || exit 1
ensure_directory_shape "$RUNTIME_PARENT" "runtime親ディレクトリ" || exit 1
ensure_directory_shape "$RUNTIME_DIR" "runtimeディレクトリ" || exit 1

if [ -L "$RUNTIME_NODE_MODULES" ]; then
    log_error "runtimeのnode_modulesは物理ディレクトリである必要があります: $RUNTIME_NODE_MODULES"
    exit 1
fi

mkdir -p "$RUNTIME_DIR"
ensure_manifest_link "$RUNTIME_DIR/package.json" "$PACKAGE_JSON" "runtimeのpackage.json" || exit 1
ensure_manifest_link "$RUNTIME_DIR/pnpm-lock.yaml" "$LOCKFILE" "runtimeのpnpm-lock.yaml" || exit 1

log_info "Application Support側に依存関係をインストールしています..."
if ! pnpm --dir "$RUNTIME_DIR" install --frozen-lockfile; then
    log_error "pnpm installに失敗しました。lockfileとpnpmのバージョンを確認してください。"
    exit 1
fi

if [ ! -d "$RUNTIME_NODE_MODULES" ] || [ -L "$RUNTIME_NODE_MODULES" ]; then
    log_error "runtimeのnode_modulesが物理ディレクトリとして作成されませんでした: $RUNTIME_NODE_MODULES"
    exit 1
fi

if ! "$RUNTIME_NODE_MODULES/.bin/textlint" --version >/dev/null; then
    log_error "Application Support側のtextlintを実行できません。"
    exit 1
fi

log_success "textlint runtimeを構築しました: $RUNTIME_DIR"
log_info "既存のdotfiles/textlint/node_modules、ホーム設定、.zprofileは変更していません。"
