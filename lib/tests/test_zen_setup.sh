#!/bin/bash

# Zen固有のセットアップ境界だけを、仮のHOMEとプロファイルで確認する。
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
SETUP="$ROOT/apps/zen/zen-setup.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/zen-setup-test.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

[ -f "$SETUP" ] || { echo "[FAIL] Zen setup not implemented" >&2; exit 1; }

mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 1\n' >"$TMP/bin/pgrep"
chmod +x "$TMP/bin/pgrep"

init_case() {
    local name="$1"
    HOME_DIR="$TMP/home-$name"
    FIXTURE="$TMP/repo-$name"
    ZEN_ROOT="$HOME_DIR/Library/Application Support/zen"
    PROFILE="$ZEN_ROOT/Profiles/fixture.default"
    TARGET="$PROFILE/zen-keyboard-shortcuts.json"
    SOURCE="$FIXTURE/apps/zen/zen-keyboard-shortcuts.json"
    mkdir -p "$FIXTURE/apps/zen" "$FIXTURE/lib" "$PROFILE"
    cp "$SETUP" "$FIXTURE/apps/zen/zen-setup.sh"
    cp "$ROOT/lib/common.sh" "$FIXTURE/lib/common.sh"
}

write_profile() {
    cat >"$ZEN_ROOT/profiles.ini" <<'INI'
[Profile0]
Name=default
IsRelative=1
Path=Profiles/fixture.default
Default=1
INI
}

write_source() {
    printf '%s\n' '{"shortcuts":[]}' >"$SOURCE"
}

run_setup() {
    HOME="$HOME_DIR" PATH="$TMP/bin:$PATH" bash "$FIXTURE/apps/zen/zen-setup.sh" >/dev/null 2>&1
}

scenario_uninitialized_skips() {
    init_case uninitialized
    write_source
    run_setup || return 1
    { [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; } || return 1
    write_profile
    rm -f -- "$SOURCE"
    run_setup || return 1
    { [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; } || return 1
}

scenario_link_and_rerun() {
    init_case linking
    write_profile
    write_source
    run_setup || return 1
    [ -L "$TARGET" ] || return 1
    [ "$(readlink "$TARGET")" = "$SOURCE" ] || return 1
    [ "$(cat "$TARGET")" = '{"shortcuts":[]}' ] || return 1
    run_setup || return 1
    [ -L "$TARGET" ] || return 1
    [ "$(readlink "$TARGET")" = "$SOURCE" ] || return 1
}

scenario_conflict_is_preserved() {
    init_case conflict
    write_profile
    write_source
    printf '%s\n' keep-original >"$TARGET"
    run_setup || return 1
    [ ! -L "$TARGET" ] || return 1
    [ "$(cat "$TARGET")" = keep-original ] || return 1
    [ "$(cat "$SOURCE")" = '{"shortcuts":[]}' ] || return 1
}

scenario_ambiguous_profile_skips() {
    init_case ambiguous
    write_source
    mkdir -p "$ZEN_ROOT/Profiles/other.default"
    cat >"$ZEN_ROOT/profiles.ini" <<'INI'
[Profile0]
Name=first
IsRelative=1
Path=Profiles/fixture.default
[Profile1]
Name=second
IsRelative=1
Path=Profiles/other.default
INI
    run_setup || return 1
    { [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ]; } || return 1
    [ ! -e "$ZEN_ROOT/Profiles/other.default/zen-keyboard-shortcuts.json" ] || return 1
}

failures=0
for scenario in scenario_uninitialized_skips scenario_link_and_rerun scenario_conflict_is_preserved scenario_ambiguous_profile_skips; do
    if (set -e; "$scenario"); then
        printf '[PASS] %s\n' "$scenario"
    else
        printf '[FAIL] %s\n' "$scenario" >&2
        failures=$((failures + 1))
    fi
done

[ "$failures" -eq 0 ]
