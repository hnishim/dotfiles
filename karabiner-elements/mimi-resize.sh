#!/bin/bash

# Karabinerのshell_commandからMimiを呼び出すラッパー
#
# `mimi status`をこのプロセスツリー（Karabinerのconsole_user_server配下）で
# 実行し、Accessibility許可がない場合はウインドウ操作を実行せず終了する。

set -u

MIMI_BIN="${MIMI_BIN:-/opt/homebrew/bin/mimi}"

if [ "$#" -ne 3 ]; then
    echo "[ERROR] Usage: mimi-resize.sh WIDTH_PERCENT HEIGHT_PERCENT ANCHOR" >&2
    exit 64
fi

width_percent="$1"
height_percent="$2"
anchor="$3"

case "$width_percent" in
    ''|*[!0-9.]*)
        echo "[ERROR] Width and height percentages must be numeric." >&2
        exit 64
        ;;
esac

case "$height_percent" in
    ''|*[!0-9.]*)
        echo "[ERROR] Width and height percentages must be numeric." >&2
        exit 64
        ;;
esac

case "$anchor" in
    tl|tc|tr|cl|cc|cr|bl|bc|br) ;;
    *)
        echo "[ERROR] Unknown anchor: $anchor" >&2
        exit 64
        ;;
esac

if [ ! -x "$MIMI_BIN" ]; then
    echo "[ERROR] Mimi CLI was not found or is not executable: $MIMI_BIN" >&2
    exit 127
fi

status_output=$("$MIMI_BIN" status 2>&1) || {
    status_exit=$?
    echo "[ERROR] mimi status failed in the Karabiner shell-command context (exit $status_exit)." >&2
    echo "$status_output" >&2
    exit "$status_exit"
}

if ! printf '%s\n' "$status_output" | /usr/bin/grep -Fqx 'accessibility: granted'; then
    echo "[ERROR] Mimi cannot control windows from Karabiner because Accessibility is not granted." >&2
    echo "[ERROR] Enable karabiner_console_user_server in System Settings > Privacy & Security > Accessibility, then restart Karabiner-Elements." >&2
    echo "$status_output" >&2
    exit 77
fi

exec "$MIMI_BIN" action resize_window \
    --width-percent "$width_percent" \
    --height-percent "$height_percent" \
    --anchor "$anchor"
