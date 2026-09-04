#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
SETUP="$DOTFILES_ROOT/karabiner-elements/karabiner-setup.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hir119-karabiner-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

FIXTURE_ROOT="$TMP_ROOT/fixture"
FIXTURE_SETUP="$FIXTURE_ROOT/karabiner-setup.sh"
COMMON_FIXTURE="$TMP_ROOT/common-fixture.sh"
CALLS_FILE="$TMP_ROOT/calls"
RESTART_MARKER="$TMP_ROOT/restart-called"
export FIXTURE_ROOT CALLS_FILE RESTART_MARKER

mkdir -p "$FIXTURE_ROOT/config" "$FIXTURE_ROOT/goku"
printf '%s\n' '{}' >"$FIXTURE_ROOT/config/karabiner.json"
printf '%s\n' '{}' >"$FIXTURE_ROOT/goku/karabiner.edn"

cat >"$COMMON_FIXTURE" <<'EOF'
#!/bin/bash

set -euo pipefail

get_script_dir() { printf '%s\n' "$FIXTURE_ROOT"; }
check_path() { return 0; }
ensure_directory() { return 0; }
create_symlink() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$CALLS_FILE"
    [ "${HIR119_MODE:-success}" != link-failure ]
}
check_command() { [ "${HIR119_MODE:-success}" != goku-missing ]; }
log_info() { :; }
log_error() { :; }
log_success() { :; }
log_warning() { :; }
show_completion_message() { :; }
goku() { [ "${HIR119_MODE:-success}" != goku-failure ]; }
restart_process() { : >"$RESTART_MARKER"; return 0; }
launchctl() { : >"$RESTART_MARKER"; return 0; }
EOF

# Execute a copy whose common-library source is replaced by the test double.
sed "s|source \".*lib/common.sh\"|source \"$COMMON_FIXTURE\"|" "$SETUP" >"$FIXTURE_SETUP"
chmod +x "$FIXTURE_SETUP"

run_setup() {
    local mode="$1"
    rm -f -- "$CALLS_FILE" "$RESTART_MARKER"
    HIR119_MODE="$mode" HOME="$TMP_ROOT/home-$mode" bash "$FIXTURE_SETUP" >/dev/null 2>&1
}

assert_rc() {
    local expected="$1"
    local mode="$2"
    local actual
    set +e
    run_setup "$mode"
    actual=$?
    set -e
    [ "$actual" -eq "$expected" ]
}

scenario_success_does_not_restart() {
    assert_rc 0 success
    [ ! -e "$RESTART_MARKER" ]
    [ "$(cut -d '|' -f 1-2 "$CALLS_FILE")" = "$FIXTURE_ROOT/config|$TMP_ROOT/home-success/.config/karabiner" ]
}

scenario_goku_missing_returns_one() {
    assert_rc 1 goku-missing
    [ ! -e "$RESTART_MARKER" ]
}

scenario_goku_failure_returns_one() {
    assert_rc 1 goku-failure
    [ ! -e "$RESTART_MARKER" ]
}

scenario_link_failure_returns_one() {
    assert_rc 1 link-failure
    [ ! -e "$RESTART_MARKER" ]
    [ "$(wc -l <"$CALLS_FILE" | tr -d ' ')" -eq 1 ]
}

scenario_existing_directory_and_repository_edn_contract() {
    rg -n --fixed-strings 'create_symlink "$SCRIPT_DIR/config" "$LOCAL_KARABINER_DIR"' "$SETUP" >/dev/null
    rg -n --fixed-strings 'GOKU_EDN_CONFIG_FILE="$ICLOUD_KARABINER_EDN" goku' "$SETUP" >/dev/null
    ! rg -n --fixed-strings 'create_symlink "$ICLOUD_KARABINER_EDN"' "$SETUP" >/dev/null
    ! rg -n --fixed-strings 'LOCAL_KARABINER_EDN=' "$SETUP" >/dev/null
}

scenario_restart_removal_is_a_fixed_contract() {
    ! rg -n --fixed-strings 'restart_process ' "$SETUP" >/dev/null
    ! rg -n --fixed-strings 'launchctl kickstart' "$SETUP" >/dev/null
    ! rg -n --fixed-strings 'Karabiner-Elementsを再起動' "$SETUP" >/dev/null
}

failures=0
run_scenario() {
    local name="$1"
    if "$name"; then
        printf '%s\n' "[PASS] $name"
    else
        printf '%s\n' "[FAIL] $name" >&2
        failures=$((failures + 1))
    fi
}

run_scenario scenario_success_does_not_restart
run_scenario scenario_goku_missing_returns_one
run_scenario scenario_goku_failure_returns_one
run_scenario scenario_link_failure_returns_one
run_scenario scenario_existing_directory_and_repository_edn_contract
run_scenario scenario_restart_removal_is_a_fixed_contract

[ "$failures" -eq 0 ]
