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
CODEX_HOME_DIR="${CODEX_HOME_DIR_OVERRIDE:-${CODEX_HOME:-$HOME/.codex}}"

log_info "harnessのAgentsを準備します。"
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$CODEX_HOME_DIR/agents" \
    /bin/bash "$SCRIPT_DIR/agents/agents-setup.sh"

log_info "harnessのSkills runtimeを準備します。"
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
CODEX_HOME_DIR_OVERRIDE="$CODEX_HOME_DIR" \
    /bin/bash "$SCRIPT_DIR/custom-instructions/custom-instructions-setup.sh"

verify_system_skills_gate

log_info "Codex Hooksを準備します。"
    /bin/bash "$SCRIPT_DIR/hooks/hooks-setup.sh" "$CODEX_HOME_DIR"
