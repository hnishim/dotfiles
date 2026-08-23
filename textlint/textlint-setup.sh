#!/bin/bash

# Application Supportにpnpm管理のtextlint runtimeを構築する。
# リポジトリ外のruntimeを管理し、成功時にログインシェルのPATHを更新する。
source "$(dirname "$0")/../lib/common.sh"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PACKAGE_JSON="$SCRIPT_DIR/package.json"
LOCKFILE="$SCRIPT_DIR/pnpm-lock.yaml"
TEXTLINT_CONFIG="$SCRIPT_DIR/.textlintrc.json"
PRH_CONFIG="$SCRIPT_DIR/my-prh.yml"
RUNTIME_PARENT="$HOME/Library/Application Support/dotfiles"
RUNTIME_DIR="$RUNTIME_PARENT/textlint"
RUNTIME_NODE_MODULES="$RUNTIME_DIR/node_modules"
ZPROFILE="$HOME/.zprofile"
PATH_BLOCK_BEGIN="# BEGIN dotfiles textlint PATH"
PATH_BLOCK_END="# END dotfiles textlint PATH"

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

update_zprofile() {
    local profile="$1"
    local temporary

    if [ -L "$profile" ] || { [ -e "$profile" ] && [ ! -f "$profile" ]; }; then
        log_error ".zprofileが通常ファイルではないため変更しません: $profile"
        return 1
    fi

    temporary=$(mktemp "${profile}.tmp.XXXXXX") || {
        log_error ".zprofileの一時ファイルを作成できません: $profile"
        return 1
    }
    if [ -f "$profile" ]; then
        if ! awk -v begin="$PATH_BLOCK_BEGIN" -v end="$PATH_BLOCK_END" '
            $0 == begin {
                if (skipping) { malformed = 1 }
                skipping = 1
                next
            }
            skipping && $0 == end { skipping = 0; next }
            !skipping { print }
            END {
                if (skipping || malformed) { exit 2 }
            }
        ' "$profile" >"$temporary"; then
            rm -f "$temporary"
            log_error ".zprofileのmanaged blockが不完全なため変更しません: $profile"
            return 1
        fi
    fi
    if ! cat >>"$temporary" <<EOF
$PATH_BLOCK_BEGIN
export PATH="\$HOME/Library/Application Support/dotfiles/textlint/node_modules/.bin:\$PATH"
$PATH_BLOCK_END
EOF
    then
        rm -f "$temporary"
        return 1
    fi

    if [ -f "$profile" ] && cmp -s "$temporary" "$profile"; then
        rm -f "$temporary"
        return 0
    fi
    if ! mv "$temporary" "$profile"; then
        rm -f "$temporary"
        log_error ".zprofileを更新できません: $profile"
        return 1
    fi
}

if ! update_zprofile "$ZPROFILE"; then
    log_error "textlint runtimeは構築しましたが、.zprofileを更新できません。"
    exit 1
fi

log_success "textlint runtimeを構築しました: $RUNTIME_DIR"
log_info ".zprofileにApplication Support側textlintのPATHを設定しました。"
