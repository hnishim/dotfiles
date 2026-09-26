#!/bin/bash

if [ -z "${BASH_VERSION:-}" ] || set -o | grep -q '^posix[[:space:]]*on$'; then
    exec /bin/bash "$0" "$@"
fi

# Custom InstructionsとSkillsをCodexとNotionへ同期する。

set -euo pipefail

# 共通ライブラリを読み込み
source "$(dirname "$0")/../../../lib/common.sh"
source "$(dirname "$0")/notion-account.sh"

export LC_ALL=C
export LANG=C
umask 077

SCRIPT_DIR=$(get_script_dir)
HARNESS_ROOT="${CODEX_HARNESS_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/../../../.." && pwd)/harness}"
ASSET_DIR="$SCRIPT_DIR"

LABEL='my.notion.sync'
APP_NAME='Custom Instructions Sync.app'
EXECUTABLE_NAME='CustomInstructionsSync'
SWIFT_SOURCE="$ASSET_DIR/CustomInstructionsSync.swift"
INFO_PLIST="$ASSET_DIR/Info.plist"
ENTITLEMENTS="$ASSET_DIR/CustomInstructionsSync.entitlements"
SOURCE_PLIST="$ASSET_DIR/$LABEL.plist"
MIRROR_LAYOUT_SOURCE="$ASSET_DIR/mirror-layout.sh"
SYNC_SOURCE="$ASSET_DIR/sync-custom-instructions"
ACCOUNT_HELPER_SOURCE="$ASSET_DIR/notion-account.sh"
CODEX_HOME_DIR="${CODEX_HOME_DIR_OVERRIDE:-${CODEX_HOME:-$HOME/.codex}}"
CUSTOM_INSTRUCTIONS_DIR_HINT="${CUSTOM_INSTRUCTIONS_DIR_HINT:-$HARNESS_ROOT/custom-instructions}"
SKILLS_DIR_HINT="${SKILLS_DIR_HINT:-$HARNESS_ROOT/skills}"
APPLICATIONS_DIR="${CUSTOM_INSTRUCTIONS_APPLICATIONS_DIR_OVERRIDE:-$HOME/Applications}"
APP_PATH="$APPLICATIONS_DIR/$APP_NAME"
HELPER_EXECUTABLE="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
APPLICATION_SUPPORT_DIR="${CUSTOM_INSTRUCTIONS_SUPPORT_DIR_OVERRIDE:-$HOME/Library/Application Support/$LABEL}"
MIRROR_ROOT="$APPLICATION_SUPPORT_DIR/mirrors"
SYNC_EXECUTABLE="$APPLICATION_SUPPORT_DIR/sync-custom-instructions"
ACCOUNT_HELPER_EXECUTABLE="$APPLICATION_SUPPORT_DIR/notion-account.sh"
NOTION_CONFIG="$APPLICATION_SUPPORT_DIR/notion-pages.conf"
if [ -n "${NTN_EXECUTABLE_OVERRIDE:-}" ]; then
    NTN_EXECUTABLE="$NTN_EXECUTABLE_OVERRIDE"
elif NTN_EXECUTABLE=$(command -v ntn 2>/dev/null); then
    :
else
    NTN_EXECUTABLE="$HOME/.local/bin/ntn"
fi
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR_OVERRIDE:-$HOME/Library/LaunchAgents}"
TARGET_PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
LOG_DIR="${CUSTOM_INSTRUCTIONS_LOG_DIR_OVERRIDE:-$HOME/Library/Logs}"
STDOUT_PATH="$LOG_DIR/$LABEL.log"
STDERR_PATH="$LOG_DIR/$LABEL.err.log"
DOMAIN="gui/$(id -u)"
MODULE_CACHE_DIR="${CUSTOM_INSTRUCTIONS_MODULE_CACHE_OVERRIDE:-$HOME/Library/Caches/$LABEL/SwiftModuleCache}"
BOOKMARK_DOMAIN='my.notion.sync.helper'
JQ_EXECUTABLE=/usr/bin/jq

for required_file in "$SWIFT_SOURCE" "$INFO_PLIST" "$ENTITLEMENTS" "$SOURCE_PLIST" "$MIRROR_LAYOUT_SOURCE" "$SYNC_SOURCE" "$ACCOUNT_HELPER_SOURCE"; do
    if [ ! -f "$required_file" ]; then
        log_error "必要なファイルが見つかりません: $required_file"
        exit 1
    fi
done
source "$MIRROR_LAYOUT_SOURCE"

preflight_application_support_dir() {
    local support_dir=$1
    if [ -L "$support_dir" ]; then
        log_error "Custom Instructions SyncのApplication Supportフォルダーがsymlinkのため停止します: $support_dir"
        return 1
    fi
    if [ -e "$support_dir" ] && [ ! -d "$support_dir" ]; then
        log_error "Custom Instructions SyncのApplication Supportフォルダーが通常のフォルダーではありません: $support_dir"
        return 1
    fi
}


if ! SWIFTC=$(xcrun --find swiftc 2>/dev/null); then
    log_error "Swiftコンパイラがありません。Command Line Toolsをインストールしてください。"
    exit 1
fi

preflight_application_support_dir "$APPLICATION_SUPPORT_DIR"
preflight_mirror_root "$MIRROR_ROOT"
mkdir -p "$CODEX_HOME_DIR" "$APPLICATIONS_DIR" "$APPLICATION_SUPPORT_DIR" "$LAUNCH_AGENTS_DIR" "$LOG_DIR" "$MODULE_CACHE_DIR"
chmod 700 "$APPLICATION_SUPPORT_DIR"
mkdir -p "$MIRROR_ROOT"
chmod 700 "$MIRROR_ROOT"
install -m 755 "$SYNC_SOURCE" "$SYNC_EXECUTABLE"
install -m 644 "$ACCOUNT_HELPER_SOURCE" "$ACCOUNT_HELPER_EXECUTABLE"

DEFAULTS_EXECUTABLE=$(command -v defaults 2>/dev/null || true)
bookmark_domain_was_present=false
if [ -n "$DEFAULTS_EXECUTABLE" ] && "$DEFAULTS_EXECUTABLE" read "$BOOKMARK_DOMAIN" >/dev/null 2>&1; then
    bookmark_domain_was_present=true
fi

build_root=$(mktemp -d "${TMPDIR:-/tmp}/custom-instructions-sync-build.XXXXXX")
case "${build_root:?}" in
    "${TMPDIR:-/tmp}"/custom-instructions-sync-build.*) ;;
    *)
        log_error "想定外のビルド一時パスです: $build_root"
        exit 1
        ;;
esac

cleanup() {
    local status=$?
    unset ACCOUNT_TOKEN ACCOUNT_USE_NTN_DEFAULT
    case "${build_root:?}" in
        "${TMPDIR:-/tmp}"/custom-instructions-sync-build.*) rm -rf -- "$build_root" ;;
        *) log_error "一時ディレクトリを削除しません: $build_root" ;;
    esac
    if [ "$status" -ne 0 ] && [ "$bookmark_domain_was_present" != true ] && [ -n "$DEFAULTS_EXECUTABLE" ]; then
        "$DEFAULTS_EXECUTABLE" delete "$BOOKMARK_DOMAIN" >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT

# Legacy persistent mirrors are not inputs. Unknown contents and symlinks
# must not prevent setup or be removed without an explicit inspection.
for legacy in "$MIRROR_ROOT/custom-instructions-sync" "$MIRROR_ROOT/skills-notion-sync"; do
    if [ -e "$legacy" ] || [ -L "$legacy" ]; then
        log_warning "旧Notion同期ミラーは参照・更新しません。内容を確認して手動で整理してください: $legacy"
    fi
done

build_app="$build_root/$APP_NAME"
mkdir -p "$build_app/Contents/MacOS"
install -m 644 "$INFO_PLIST" "$build_app/Contents/Info.plist"

compile_log="$build_root/swiftc.log"
compile_succeeded=false
if "$SWIFTC" "$SWIFT_SOURCE" \
    -o "$build_app/Contents/MacOS/$EXECUTABLE_NAME" \
    -framework AppKit -O -parse-as-library \
    -module-cache-path "$MODULE_CACHE_DIR" >"$compile_log" 2>&1; then
    compile_succeeded=true
else
    default_sdk=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
    while IFS= read -r sdk_path; do
        [ -n "$sdk_path" ] || continue
        if [ -n "$default_sdk" ] && [ "$sdk_path" -ef "$default_sdk" ]; then
            continue
        fi
        log_info "互換SDKでSwiftヘルパーを構築します: $sdk_path"
        if "$SWIFTC" "$SWIFT_SOURCE" \
            -o "$build_app/Contents/MacOS/$EXECUTABLE_NAME" \
            -framework AppKit -O -parse-as-library \
            -sdk "$sdk_path" -module-cache-path "$MODULE_CACHE_DIR" >"$compile_log" 2>&1; then
            compile_succeeded=true
            break
        fi
    done < <(find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -type d -name 'MacOSX*.sdk' | sort -Vr)
fi

if [ "$compile_succeeded" != true ]; then
    sed -n '1,120p' "$compile_log" >&2
    log_error "Swiftヘルパーの構築に失敗しました。"
    exit 1
fi

chmod 755 "$build_app/Contents/MacOS/$EXECUTABLE_NAME"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$build_app" >/dev/null
codesign --verify --strict "$build_app"

log_info "Swiftヘルパーを配置します: $APP_PATH"
ditto "$build_app" "$APP_PATH"
codesign --verify --strict "$APP_PATH"

if ! "$HELPER_EXECUTABLE" --status >/dev/null 2>&1; then
    if [ ! -d "$CUSTOM_INSTRUCTIONS_DIR_HINT" ] || [ ! -d "$SKILLS_DIR_HINT" ]; then
        log_error "正本フォルダー候補が見つかりません: custom=$CUSTOM_INSTRUCTIONS_DIR_HINT skills=$SKILLS_DIR_HINT"
        exit 1
    fi
    log_info "初回フォルダーアクセス権を設定します。4つのフォルダーを順に選択してください。"
    "$HELPER_EXECUTABLE" --authorize "$CODEX_HOME_DIR" "$CUSTOM_INSTRUCTIONS_DIR_HINT" "$SKILLS_DIR_HINT" "$MIRROR_ROOT"
fi

status_output=$("$HELPER_EXECUTABLE" --status)
printf '%s\n' "$status_output"
custom_instructions_dir=$(printf '%s\n' "$status_output" | sed -n 's/^source=//p')
skills_dir=$(printf '%s\n' "$status_output" | sed -n 's/^skills=//p')
authorized_output_dir=$(printf '%s\n' "$status_output" | sed -n 's/^output=//p')
authorized_mirror_root=$(printf '%s\n' "$status_output" | sed -n 's/^mirror=//p')

if [ -z "$custom_instructions_dir" ] || [ ! -d "$custom_instructions_dir" ] ||
   [ -z "$skills_dir" ] || [ ! -d "$skills_dir" ]; then
    log_error "保存済みの正本フォルダーを確認できません。"
    exit 1
fi

if [ "$authorized_output_dir" != "$CODEX_HOME_DIR" ]; then
    log_error "認可済み出力先がCodexホームと一致しません: $authorized_output_dir"
    exit 1
fi

if [ "$authorized_mirror_root" != "$MIRROR_ROOT" ]; then
    log_error "認可済みNotion同期ミラーrootが想定と一致しません: $authorized_mirror_root"
    exit 1
fi

target_agents="$CODEX_HOME_DIR/AGENTS.md"
log_info "Codex用AGENTS.mdの初期同期を実行します。"
"$HELPER_EXECUTABLE" --sync

if [ ! -f "$target_agents" ] || [ -L "$target_agents" ]; then
    log_error "AGENTS.mdの初期同期結果が通常ファイルではありません: $target_agents"
    exit 1
fi

# The normal helper operation only updates Codex output. Notion snapshots
# are generated by the lock-protected sync script and never persisted here.
install_sync_launch_agent() {
    local temp_plist="$build_root/$LABEL.plist"
    local attempt
    local job_state
    local previous_runs=0
    local current_runs
    local run_observed=false

    cp "$SOURCE_PLIST" "$temp_plist"
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $SYNC_EXECUTABLE" "$temp_plist"
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:1 $HELPER_EXECUTABLE" "$temp_plist"
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:2 $NTN_EXECUTABLE" "$temp_plist"
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:3 $CODEX_HOME_DIR" "$temp_plist"
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:4 $NOTION_CONFIG" "$temp_plist"
    /usr/libexec/PlistBuddy -c "Set :WatchPaths:0 $custom_instructions_dir" "$temp_plist"
    /usr/libexec/PlistBuddy -c "Set :WatchPaths:1 $skills_dir" "$temp_plist"
    /usr/libexec/PlistBuddy -c "Set :StandardOutPath $STDOUT_PATH" "$temp_plist"
    /usr/libexec/PlistBuddy -c "Set :StandardErrorPath $STDERR_PATH" "$temp_plist"
    plutil -lint "$temp_plist" >/dev/null

    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        launchctl bootout "$DOMAIN/$LABEL"
    fi
    install -m 600 "$temp_plist" "$TARGET_PLIST"
    if [ "${CODEX_HARNESS_PREPARE_ONLY:-0}" = "1" ]; then
        log_info "harness準備モードのためLaunchAgentは有効化しません。"
        return 0
    fi
    launchctl bootstrap "$DOMAIN" "$TARGET_PLIST"
    attempt=1
    while [ "$attempt" -le 40 ]; do
        job_state=$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null || true)
        current_runs=$(printf '%s\n' "$job_state" | sed -n 's/^[[:space:]]*runs = \([0-9][0-9]*\).*$/\1/p' | head -n 1)
        if [ -n "$current_runs" ] && [ "$current_runs" -gt "$previous_runs" ]; then
            run_observed=true
            break
        fi
        sleep 0.25
        attempt=$((attempt + 1))
    done

    if [ "$run_observed" = false ]; then
        log_info "RunAtLoadによるLaunchAgent実行を確認できないため、一度だけkickstartします。"
        launchctl kickstart -k "$DOMAIN/$LABEL"
    fi

    attempt=1
    while [ "$attempt" -le 240 ]; do
        job_state=$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null || true)
        current_runs=$(printf '%s\n' "$job_state" | sed -n 's/^[[:space:]]*runs = \([0-9][0-9]*\).*$/\1/p' | head -n 1)
        if [ -n "$current_runs" ] && [ "$current_runs" -gt "$previous_runs" ]; then
            run_observed=true
        fi
        if [ "$run_observed" = true ] &&
           printf '%s\n' "$job_state" | grep -q 'active count = 0' &&
           printf '%s\n' "$job_state" | grep -q 'last exit code = 0'; then
            if [ ! -f "$target_agents" ] || [ -L "$target_agents" ]; then
                log_error "通常ファイルのAGENTS.mdを確認できません: $target_agents"
                return 1
            fi
            log_success "LaunchAgentの正常終了を確認しました。"
            log_success "Codex用AGENTS.mdを確認しました: $target_agents"
            return 0
        fi
        sleep 0.25
        attempt=$((attempt + 1))
    done

    tail -n 40 "$STDERR_PATH" 2>/dev/null || true
    log_error "LaunchAgentの正常終了を確認できませんでした。"
    return 1
}

if [ ! -x "$NTN_EXECUTABLE" ]; then
    log_warning "Notion CLIが見つかりません。Notion同期の設定をスキップします: $NTN_EXECUTABLE"
    install_sync_launch_agent || exit 1
    exit 0
fi

read_local_config() {
    local key=$1
    [ "${ACCOUNT_SELECTION_CHANGED:-false}" = false ] || return 0
    [ -f "$NOTION_CONFIG" ] || return 0
    notion_config_value "$NOTION_CONFIG" "$key"
}

if [ -L "$NOTION_CONFIG" ]; then
    log_error "Notion設定がsymlinkのため停止します。"
    exit 1
fi

ACCOUNT_ID=''
CREDENTIAL_SOURCE=''
EXPECTED_USER_ID=''
ACCOUNT_WORKSPACE_ID=''
ACCOUNT_CUSTOM_PAGE_ID=''
ACCOUNT_PROFILE_PAGE_ID=''
ACCOUNT_SKILLS_DATA_SOURCE_ID=''
ACCOUNT_CONFIG_LEGACY=false
ACCOUNT_SELECTION_CHANGED=false
if [ -f "$NOTION_CONFIG" ]; then
    if ! notion_account_load_config "$NOTION_CONFIG" 1; then
        log_error "Notion設定のアカウント選択を確認できません。"
        exit 1
    fi
    if [ -n "${NOTION_ACCOUNT_ID_OVERRIDE:-}" ]; then
        case "$NOTION_ACCOUNT_ID_OVERRIDE" in
            molcure|personal) ;;
            *) log_error "NOTION_ACCOUNT_ID_OVERRIDEはmolcureまたはpersonalを指定してください。"; exit 1 ;;
        esac
        if [ "$NOTION_ACCOUNT_ID_OVERRIDE" != "$ACCOUNT_ID" ]; then
            ACCOUNT_SELECTION_CHANGED=true
            ACCOUNT_ID=$NOTION_ACCOUNT_ID_OVERRIDE
            case "$ACCOUNT_ID" in
                molcure) CREDENTIAL_SOURCE="${NOTION_CREDENTIAL_SOURCE_OVERRIDE:-ntn-default}" ;;
                personal) CREDENTIAL_SOURCE="${NOTION_CREDENTIAL_SOURCE_OVERRIDE:-keychain}" ;;
            esac
            EXPECTED_USER_ID="${NOTION_EXPECTED_USER_ID_OVERRIDE:-}"
            ACCOUNT_WORKSPACE_ID=''
            ACCOUNT_CUSTOM_PAGE_ID=''
            ACCOUNT_PROFILE_PAGE_ID=''
            ACCOUNT_SKILLS_DATA_SOURCE_ID=''
            ACCOUNT_CONFIG_LEGACY=false
        fi
    fi
else
    ACCOUNT_ID="${NOTION_ACCOUNT_ID_OVERRIDE:-}"
    if [ -z "$ACCOUNT_ID" ] && [ -t 0 ]; then
        read -r -p 'Notion account_id (molcure/personal): ' ACCOUNT_ID
    fi
    case "$ACCOUNT_ID" in
        molcure) CREDENTIAL_SOURCE="${NOTION_CREDENTIAL_SOURCE_OVERRIDE:-ntn-default}" ;;
        personal) CREDENTIAL_SOURCE="${NOTION_CREDENTIAL_SOURCE_OVERRIDE:-keychain}" ;;
        *) log_error "Notion account_idを明示してください（molcure/personal）。"; exit 1 ;;
    esac
    EXPECTED_USER_ID="${NOTION_EXPECTED_USER_ID_OVERRIDE:-}"
    ACCOUNT_CONFIG_LEGACY=false
fi

workspace_id="${NOTION_WORKSPACE_ID_OVERRIDE:-${ACCOUNT_WORKSPACE_ID:-$(read_local_config workspace_id)}}"
custom_page_id="${NOTION_CUSTOM_INSTRUCTIONS_PAGE_ID_OVERRIDE:-${ACCOUNT_CUSTOM_PAGE_ID:-$(read_local_config custom_instructions_page_id)}}"
profile_page_id="${NOTION_USER_PROFILE_PAGE_ID_OVERRIDE:-${ACCOUNT_PROFILE_PAGE_ID:-$(read_local_config user_profile_page_id)}}"
skills_data_source_id="${NOTION_SKILLS_DATA_SOURCE_ID_OVERRIDE:-${ACCOUNT_SKILLS_DATA_SOURCE_ID:-$(read_local_config skills_data_source_id)}}"

if [ -z "$workspace_id" ] && [ -t 0 ]; then
    read -r -p 'Notion workspace ID: ' workspace_id
fi

if [ -z "$custom_page_id" ] && [ -t 0 ]; then
    read -r -p '基本的なガイドラインのNotionページID: ' custom_page_id
fi
if [ -z "$profile_page_id" ] && [ -t 0 ]; then
    read -r -p 'ユーザープロファイルのNotionページID: ' profile_page_id
fi
if [ -z "$skills_data_source_id" ] && [ -t 0 ]; then
    read -r -p 'SkillsデータソースID: ' skills_data_source_id
fi

for notion_id in "$workspace_id" "$custom_page_id" "$profile_page_id" "$skills_data_source_id"; do
    if ! notion_valid_id "$notion_id"; then
        log_error "選択したNotionアカウントのワークスペースID、ページID、SkillsデータソースIDを確認できません。"
        exit 1
    fi
done

if [ ! -x "$JQ_EXECUTABLE" ]; then
    log_error "Notion認証応答の確認に必要なJSON解析ツールが見つかりません: $JQ_EXECUTABLE"
    exit 1
fi

if [ "$CREDENTIAL_SOURCE" = ntn-default ] && [ "$ACCOUNT_ID" != molcure ]; then
    log_error "ntn既定認証はMOLCUREアカウントにだけ指定できます。"
    exit 1
fi
if [ "$ACCOUNT_ID" = personal ] && [ "$CREDENTIAL_SOURCE" != keychain ]; then
    log_error "個人用Notion認証にはKeychainを指定してください。"
    exit 1
fi
ACCOUNT_WORKSPACE_ID=$workspace_id
if ! notion_account_select_credential; then
    log_error "選択したNotionアカウントの認証情報を取得できません。"
    exit 1
fi
if ! notion_account_verify_identity "$EXPECTED_USER_ID" "$workspace_id" "$build_root/notion-whoami.json" "$JQ_EXECUTABLE"; then
    log_error "Notionの認証先、利用者、またはワークスペースが設定と一致しません。"
    exit 1
fi
if [ -z "$EXPECTED_USER_ID" ]; then
    EXPECTED_USER_ID=$NOTION_ACTUAL_USER_ID
fi

notion_config_temp="$build_root/notion-pages.conf"
printf 'account_id=%s\ncredential_source=%s\nexpected_user_id=%s\nworkspace_id=%s\ncustom_instructions_page_id=%s\nuser_profile_page_id=%s\nskills_data_source_id=%s\n' \
    "$ACCOUNT_ID" "$CREDENTIAL_SOURCE" "$EXPECTED_USER_ID" "$workspace_id" "$custom_page_id" "$profile_page_id" "$skills_data_source_id" >"$notion_config_temp"
install -m 600 "$notion_config_temp" "$NOTION_CONFIG"

if [ "${CODEX_HARNESS_PREPARE_ONLY:-0}" = "1" ]; then
    log_info "Harness準備モードのためNotion同期を実行しません。"
else
    log_info "選択したNotionアカウントの同期はLaunchAgentの通常起動で一度だけ実行します。"
fi

install_sync_launch_agent || exit 1
