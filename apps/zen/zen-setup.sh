#!/bin/bash

# Zenショートカット設定を、対象プロファイル内のファイルへリンクする。
source "$(dirname "$0")/../../lib/common.sh"

SCRIPT_DIR=$(get_script_dir)
SOURCE="$SCRIPT_DIR/zen-keyboard-shortcuts.json"
ZEN_ROOT="$HOME/Library/Application Support/zen"
PROFILES_INI="$ZEN_ROOT/profiles.ini"

skip_zen() {
    log_warning "Zenショートカット: $1"
    exit 0
}

[ -f "$SOURCE" ] || skip_zen "管理JSONが未取込です。apps/zen/README.mdの初回移行手順を参照してください。"
[ -f "$PROFILES_INI" ] || skip_zen "Zenプロファイルが未生成です。Zenを初回起動して正常終了してください。"

if [ -n "${ZEN_PROFILE_PATH:-}" ]; then
    profile_candidate="$ZEN_PROFILE_PATH"
else
    # profiles.iniの[ProfileN]から、唯一のDefault=1または唯一のプロファイルを選択。
    selected=$(awk -F= '
        function flush() {
            if (!profile) return
            count++
            if (count == 1) { only_path = path; only_relative = relative }
            if (is_default == "1") {
                default_count++
                default_path = path
                default_relative = relative
            }
        }
        /^\[/ {
            flush()
            profile = ($0 ~ /^\[Profile[0-9]+\]$/)
            path = ""; relative = ""; is_default = ""
            next
        }
        profile && $1 == "Path" { path = substr($0, 6) }
        profile && $1 == "IsRelative" { relative = $2 }
        profile && $1 == "Default" { is_default = $2 }
        END {
            flush()
            if (default_count == 1 && default_path != "")
                printf "%s\n%s\n", default_relative, default_path
            else if (default_count == 0 && count == 1 && only_path != "")
                printf "%s\n%s\n", only_relative, only_path
        }
    ' "$PROFILES_INI") || exit 1
    [ -n "$selected" ] || skip_zen "利用プロファイルを一意に特定できません。about:profilesを確認し、ZEN_PROFILE_PATHを指定してください。"
    relative=${selected%%$'\n'*}
    path=${selected#*$'\n'}
    case "$relative" in
        1) profile_candidate="$ZEN_ROOT/$path" ;;
        0) profile_candidate="$path" ;;
        *) skip_zen "profiles.iniのIsRelativeを解釈できません。ZEN_PROFILE_PATHを明示してください。" ;;
    esac
fi

# 予期しない場所への書込みを避け、ZenのProfiles配下の実在ディレクトリに限定。
[ -d "$ZEN_ROOT/Profiles" ] || skip_zen "ZenのProfilesディレクトリがありません。"
profiles_root=$(cd -- "$ZEN_ROOT/Profiles" && pwd -P) || exit 1
[ -d "$profile_candidate" ] || skip_zen "対象プロファイルが存在しません。about:profilesで確認してください。"
profile_dir=$(cd -- "$profile_candidate" && pwd -P) || exit 1
case "$profile_dir" in
    "$profiles_root"/*) ;;
    *) skip_zen "対象プロファイルがZenのProfiles配下ではないため変更しません。" ;;
esac

TARGET="$profile_dir/zen-keyboard-shortcuts.json"
if check_symlink "$TARGET" "$SOURCE"; then
    log_success "Zenショートカットは管理JSONへリンク済みです。"
    exit 0
fi
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    skip_zen "既存の設定ファイルまたは別リンクを検出しました。上書きしません。READMEの手順で退避・移行してください: $TARGET"
fi

# GUI稼働中のリンク差替えはしない。終了確認後に再実行する。
if pgrep -x 'zen' >/dev/null 2>&1 || pgrep -x 'Zen' >/dev/null 2>&1 || pgrep -x 'Zen Browser' >/dev/null 2>&1; then
    skip_zen "Zenが起動中です。正常終了してから再実行してください。"
fi

create_symlink "$SOURCE" "$TARGET" "Zenショートカット設定" || exit 1
