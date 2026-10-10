#!/bin/bash

# sh から呼ばれた場合も、Bash専用の共通ライブラリを安全に使う。
if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi

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
    # profiles.iniのProfileN既定値とInstall既定値が矛盾する場合は自動選択しない。
    selected=$(awk -F= '
        function flush_profile() {
            if (!profile) return
            count++
            if (count == 1) { only_path = path; only_relative = relative }
            if (is_default == "1") {
                default_count++
                default_path = path
                default_relative = relative
            }
        }
        function flush_install() {
            if (!install_section || install_default == "") return
            install_default_count++
            install_default_path = install_default
        }
        /^\[/ {
            flush_profile()
            flush_install()
            profile = ($0 ~ /^\[Profile[0-9]+\]$/)
            install_section = ($0 ~ /^\[Install.*\]$/)
            path = ""; relative = ""; is_default = ""; install_default = ""
            next
        }
        profile && $1 == "Path" { path = substr($0, index($0, "=") + 1) }
        profile && $1 == "IsRelative" { relative = $2 }
        profile && $1 == "Default" { is_default = $2 }
        install_section && $1 == "Default" { install_default = substr($0, index($0, "=") + 1) }
        END {
            flush_profile()
            flush_install()
            if (default_count == 1 && default_path != "")
                printf "%s\n%s\n%d\n%s\n", default_relative, default_path, install_default_count, install_default_path
            else if (default_count == 0 && count == 1 && only_path != "")
                printf "%s\n%s\n%d\n%s\n", only_relative, only_path, install_default_count, install_default_path
        }
    ' "$PROFILES_INI") || exit 1
    [ -n "$selected" ] || skip_zen "利用プロファイルを一意に特定できません。about:profilesを確認し、ZEN_PROFILE_PATHを指定してください。"
    relative=$(printf '%s\n' "$selected" | sed -n '1p')
    path=$(printf '%s\n' "$selected" | sed -n '2p')
    install_default_count=$(printf '%s\n' "$selected" | sed -n '3p')
    install_default_path=$(printf '%s\n' "$selected" | sed -n '4p')
    case "$relative" in
        1) profile_candidate="$ZEN_ROOT/$path" ;;
        0) profile_candidate="$path" ;;
        *) skip_zen "profiles.iniのIsRelativeを解釈できません。ZEN_PROFILE_PATHを明示してください。" ;;
    esac

    if [ "$install_default_count" -gt 1 ]; then
        skip_zen "profiles.iniのInstall既定指定が複数あり、利用プロファイルを一意に特定できません。about:profilesを確認し、ZEN_PROFILE_PATHを指定してください。"
    elif [ "$install_default_count" -eq 1 ]; then
        case "$install_default_path" in
            /*) install_candidate="$install_default_path" ;;
            *) install_candidate="$ZEN_ROOT/$install_default_path" ;;
        esac
        [ -d "$profile_candidate" ] && [ -d "$install_candidate" ] || skip_zen "profiles.iniの既定プロファイルが見つからず、利用プロファイルを一意に特定できません。about:profilesを確認し、ZEN_PROFILE_PATHを指定してください。"
        profile_default=$(cd -- "$profile_candidate" && pwd -P) || exit 1
        install_default=$(cd -- "$install_candidate" && pwd -P) || exit 1
        [ "$profile_default" = "$install_default" ] || skip_zen "profiles.iniのProfileNとInstallの既定指定が一致しないため、利用プロファイルを一意に特定できません。about:profilesを確認し、ZEN_PROFILE_PATHを指定してください。"
    fi
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
