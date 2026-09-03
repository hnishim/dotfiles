#!/bin/bash

if [ -z "${BASH_VERSION:-}" ] || set -o | grep -q '^posix[[:space:]]*on$'; then
    exec /bin/bash "$0" "$@"
fi

set -euo pipefail

source "$(dirname "$0")/../../lib/common.sh"

export LC_ALL=C
export LANG=C
umask 077

SCRIPT_DIR=$(get_script_dir)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
HARNESS_ROOT="${CODEX_HARNESS_ROOT_OVERRIDE:-$DOTFILES_ROOT/../harness}"
CODEX_HOME_DIR="${CODEX_HOME_DIR_OVERRIDE:-${CODEX_HOME:-$HOME/.codex}}"
LABEL='com.hnishim.custom-instructions-sync'
APP_NAME='Custom Instructions Sync.app'
APPLICATIONS_DIR="${CUSTOM_INSTRUCTIONS_APPLICATIONS_DIR_OVERRIDE:-$HOME/Applications}"
APP_PATH="$APPLICATIONS_DIR/$APP_NAME"
APPLICATION_SUPPORT_DIR="${CUSTOM_INSTRUCTIONS_SUPPORT_DIR_OVERRIDE:-$HOME/Library/Application Support/$LABEL}"
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR_OVERRIDE:-$HOME/Library/LaunchAgents}"
TARGET_PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
LOG_DIR="${CUSTOM_INSTRUCTIONS_LOG_DIR_OVERRIDE:-$HOME/Library/Logs}"
STDOUT_PATH="$LOG_DIR/$LABEL.log"
STDERR_PATH="$LOG_DIR/$LABEL.err.log"
DOMAIN="gui/$(id -u)"
MODULE_CACHE_DIR="${CUSTOM_INSTRUCTIONS_MODULE_CACHE_OVERRIDE:-$HOME/Library/Caches/$LABEL/SwiftModuleCache}"
BOOKMARK_DOMAIN='com.hnishim.custom-instructions-sync-helper'

if [ "${CODEX_HARNESS_TRANSACTION_CHILD:-0}" != "1" ]; then
    TRANSACTION="$HARNESS_ROOT/transaction.py"
    if [ ! -f "$TRANSACTION" ]; then
        log_error "harness transactionが見つかりません: $TRANSACTION"
        exit 1
    fi
    exec /usr/bin/python3 "$TRANSACTION" \
        --real \
        --codex-home "$CODEX_HOME_DIR" \
        --launchagent-domain "$DOMAIN" \
        --launchagent-label "$LABEL" \
        --launchagent-plist "$TARGET_PLIST" \
        --bookmark-domain "$BOOKMARK_DOMAIN" \
        --path "$CODEX_HOME_DIR/AGENTS.md" \
        --path "$CODEX_HOME_DIR/hooks" \
        --path "$CODEX_HOME_DIR/hooks.json" \
        --path "$CODEX_HOME_DIR/agents" \
        --path "$CODEX_HOME_DIR/skills" \
        --path "$CODEX_HOME_DIR/backups" \
        --path "$TARGET_PLIST" \
        --path "$APP_PATH" \
        --path "$APPLICATION_SUPPORT_DIR" \
        --path "$STDOUT_PATH" \
        --path "$STDERR_PATH" \
        --path "$MODULE_CACHE_DIR" \
        --evidence-dir "$HARNESS_ROOT/.local-state/transaction-evidence" \
        --command /bin/bash "$SCRIPT_DIR/codex-setup.sh" "$@"
fi

log_info "harnessのAgentsを準備します。"
CODEX_HARNESS_TRANSACTION_CHILD=1 \
CODEX_HARNESS_ROOT_OVERRIDE="$HARNESS_ROOT" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$CODEX_HOME_DIR/agents" \
    /bin/bash "$SCRIPT_DIR/agents/agents-setup.sh"

log_info "harnessのSkills runtimeを準備します。"
CODEX_HARNESS_TRANSACTION_CHILD=1 \
CODEX_HARNESS_ROOT_OVERRIDE="$HARNESS_ROOT" \
LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$CODEX_HOME_DIR/skills" \
    /bin/bash "$SCRIPT_DIR/skills/skills-setup.sh"

verify_system_skills_gate() {
    local system_runtime="$CODEX_HOME_DIR/skills/.system"
    local recognition_command="${CODEX_SYSTEM_SKILLS_RECOGNITION_COMMAND:-}"
    local codex_executable
    local probe_output

    if [ ! -e "$system_runtime" ] || [ ! -s "$system_runtime/.codex-system-skills.marker" ]; then
        log_error "Codex plugin-managed .systemの認識を確認できません: $system_runtime"
        return 1
    fi
    if [ -n "$recognition_command" ]; then
        if ! CODEX_HOME_DIR="$CODEX_HOME_DIR" CODEX_SYSTEM_SKILLS_DIR="$system_runtime" \
            /bin/bash -c "$recognition_command"; then
            log_error "Codex plugin-managed .systemの明示的認識gateに失敗しました。"
            return 1
        fi
        return 0
    fi

    resolve_codex_executable() {
        local candidate

        if [ -n "${CODEX_EXECUTABLE_OVERRIDE:-}" ]; then
            printf '%s\n' "$CODEX_EXECUTABLE_OVERRIDE"
            return 0
        fi

        for candidate in \
            "/Applications/ChatGPT.app/Contents/Resources/codex" \
            "$HOME/Applications/ChatGPT.app/Contents/Resources/codex"; do
            if [ -x "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done

        command -v codex 2>/dev/null || true
    }

    codex_executable="$(resolve_codex_executable)"
    if [ -z "$codex_executable" ] || [ ! -x "$codex_executable" ]; then
        log_error "Codex CLIが見つからないため.system認識gateを実行できません。"
        return 1
    fi

    probe_output=$(mktemp "${TMPDIR:-/tmp}/codex-system-skills-probe.XXXXXX")
    if ! CODEX_HOME="$CODEX_HOME_DIR" "$codex_executable" debug prompt-input \
        'Load the available Codex system skills for this recognition probe.' >"$probe_output" 2>&1; then
        rm -f -- "$probe_output"
        log_error "Codex CLIの.system認識probeに失敗しました。"
        return 1
    fi
    if ! grep -Eq 'skill-creator|openai-docs|plugin-creator' "$probe_output"; then
        rm -f -- "$probe_output"
        log_error "Codex CLIのprobe出力にplugin-managed system skillがありません。"
        return 1
    fi
    rm -f -- "$probe_output"
}

log_info "Custom Instructionsを準備します。"
CODEX_HARNESS_TRANSACTION_CHILD=1 \
CODEX_HARNESS_ROOT_OVERRIDE="$HARNESS_ROOT" \
CODEX_HOME_DIR_OVERRIDE="$CODEX_HOME_DIR" \
    /bin/bash "$SCRIPT_DIR/custom-instructions/custom-instructions-setup.sh"

verify_system_skills_gate

log_info "Codex Hooksを準備します。"
CODEX_HARNESS_TRANSACTION_CHILD=1 \
CODEX_HARNESS_ROOT_OVERRIDE="$HARNESS_ROOT" \
    /bin/bash "$SCRIPT_DIR/hooks/hooks-setup.sh" "$CODEX_HOME_DIR"
