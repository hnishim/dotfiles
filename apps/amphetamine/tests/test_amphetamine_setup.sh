#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
SETUP="$DOTFILES_ROOT/apps/amphetamine/amphetamine-setup.sh"
MASTER="$DOTFILES_ROOT/setup-macos.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/amphetamine-setup-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

assert_contains() {
    local needle="$1"
    local file="$2"
    rg -F -- "$needle" "$file" >/dev/null
}

make_fake_defaults() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/defaults" <<'EOF'
#!/bin/bash
set -euo pipefail

state=${FAKE_DEFAULTS_STATE:?}
log=${FAKE_DEFAULTS_LOG:?}
printf '%s\n' "$*" >>"$log"

command=$1
shift
case "$command" in
    write)
        domain=$1
        key=$2
        shift 2
        case "$domain|$key" in
            'com.if.Amphetamine|Start Session At Launch'|\
            'com.if.Amphetamine|Start Session On Wake'|\
            'com.if.Amphetamine|Enable Triggers')
                [ "$#" -eq 2 ]
                type=$1
                value=$2
                case "$domain|$key|$type|$value" in
                    'com.if.Amphetamine|Start Session At Launch|-int|0'|\
                    'com.if.Amphetamine|Start Session On Wake|-int|0'|\
                    'com.if.Amphetamine|Enable Triggers|-int|1')
                        ;;
                    *)
                        printf 'unexpected defaults write: %s\n' "$domain|$key|$type|$value" >&2
                        exit 2
                        ;;
                esac
                ;;
            'com.if.Amphetamine|Trigger Data')
                [ "$#" -eq 1 ]
                type='-array'
                value=$1
                expected_trigger_data='(
    {
        AllowDisplaySleep = 1;
        App = ChatGPT;
        Enabled = 1;
        Name = ChatGPT;
        TypeIDs = (1);
    }
)'
                [ "$value" = "$expected_trigger_data" ]
                ;;
            *)
                printf 'unexpected defaults write: %s\n' "$domain|$key|$*" >&2
                exit 2
                ;;
        esac
        tmp_state="${state}.tmp"
        awk -F '\t' -v wanted="$domain|$key" '$1 != wanted' "$state" >"$tmp_state"
        stored_value="$value"
        [ "$key" = 'Trigger Data' ] && stored_value='__trigger_data__'
        printf '%s\t%s\t%s\n' "$domain|$key" "$type" "$stored_value" >>"$tmp_state"
        mv -- "$tmp_state" "$state"
        ;;
    read)
        domain=$1
        key=${2:-}
        if [ "${FAKE_DEFAULTS_FAIL_READ_KEY:-}" = "$key" ]; then
            exit 73
        fi
        record=$(awk -F '\t' -v wanted="$domain|$key" '$1 == wanted { line=$0 } END { print line }' "$state")
        [ -n "$record" ]
        type=$(printf '%s\n' "$record" | cut -f2)
        value=$(printf '%s\n' "$record" | cut -f3-)
        if [ "$key" = "Trigger Data" ]; then
            printf '%s\n' '('
            printf '%s\n' '        {'
            printf '%s\n' '        AllowDisplaySleep = 1;'
            printf '%s\n' '        App = ChatGPT;'
            printf '%s\n' '        Enabled = 1;'
            printf '%s\n' '        Name = ChatGPT;'
            printf '%s\n' '        TypeIDs =         ('
            printf '%s\n' '            1'
            printf '%s\n' '        );'
            printf '%s\n' '    }'
            printf '%s\n' ')'
        else
            printf '%s\n' "$value"
        fi
        ;;
    read-type)
        domain=$1
        key=$2
        if [ "${FAKE_DEFAULTS_FAIL_READ_TYPE_KEY:-}" = "$key" ]; then
            exit 74
        fi
        record=$(awk -F '\t' -v wanted="$domain|$key" '$1 == wanted { line=$0 } END { print line }' "$state")
        [ -n "$record" ]
        if [ "${FAKE_DEFAULTS_MISMATCH_READ_TYPE_KEY:-}" = "$key" ]; then
            printf '%s\n' 'Type is string'
            exit 0
        fi
        type=$(printf '%s\n' "$record" | cut -f2)
        case "$type" in
            -int) printf '%s\n' 'Type is integer' ;;
            -array) printf '%s\n' 'Type is array' ;;
            *) exit 2 ;;
        esac
        ;;
    *)
        printf 'unsupported defaults command: %s\n' "$command" >&2
        exit 2
        ;;
esac
EOF
    chmod 755 "$bin/defaults"
}

make_fake_plutil() {
    local bin="$1"
    cat >"$bin/plutil" <<'EOF'
#!/bin/bash
set -euo pipefail
# The fixture setup uses plutil for the readback boundary.  The fake keeps
# the test independent of the host preference store while preserving the
# command contract.
printf '%s\n' "$*" >>"${FAKE_PLUTIL_LOG:?}"
cat >/dev/null
if [ "${FAKE_PLUTIL_FAIL:-0}" = 1 ]; then
    exit 75
fi
case "$*" in
    '-convert xml1 -o - -') exit 0 ;;
    *) exit 2 ;;
esac
EOF
    chmod 755 "$bin/plutil"
}

make_setup_fixture() {
    local path="$1"
    mkdir -p "$(dirname -- "$path")"
    cat >"$path" <<'EOF'
#!/bin/bash
set -euo pipefail

domain='com.if.Amphetamine'
write_integer_and_verify() {
    local key="$1" value="$2"
    defaults write "$domain" "$key" -int "$value"
    defaults read "$domain" "$key" >/dev/null
    [ "$(defaults read-type "$domain" "$key")" = 'Type is integer' ]
}

write_integer_and_verify 'Start Session At Launch' 0
write_integer_and_verify 'Start Session On Wake' 0
write_integer_and_verify 'Enable Triggers' 1
trigger_data_plist='(
    {
        AllowDisplaySleep = 1;
        App = ChatGPT;
        Enabled = 1;
        Name = ChatGPT;
        TypeIDs = (1);
    }
)'
defaults write "$domain" 'Trigger Data' "$trigger_data_plist"
defaults read "$domain" 'Trigger Data' >/dev/null
[ "$(defaults read-type "$domain" 'Trigger Data')" = 'Type is array' ]
defaults read "$domain" 'Trigger Data' | plutil -convert xml1 -o - - >/dev/null
EOF
    chmod 755 "$path"
}

make_master_fixture() {
    local path="$1"
    cat >"$path" <<'EOF'
setup_scripts=(
    "apps/amphetamine/amphetamine-setup.sh"
)
EOF
}

run_setup_scenario() {
    local setup_path="$1"
    local root="$2"
    local fake_bin="$root/bin"
    mkdir -p "$root"
    make_fake_defaults "$fake_bin"
    make_fake_plutil "$fake_bin"
    mkdir -p "$root/home"
    : >"$root/defaults.log"
    : >"$root/plutil.log"
    : >"$root/state"
    PATH="$fake_bin:$PATH" \
        FAKE_DEFAULTS_STATE="$root/state" \
        FAKE_DEFAULTS_LOG="$root/defaults.log" \
        FAKE_PLUTIL_LOG="$root/plutil.log" \
        HOME="$root/home" bash "$setup_path"

    for expected in \
        'write com.if.Amphetamine Start Session At Launch -int 0' \
        'write com.if.Amphetamine Start Session On Wake -int 0' \
        'write com.if.Amphetamine Enable Triggers -int 1' \
        'write com.if.Amphetamine Trigger Data ('; do
        assert_contains "$expected" "$root/defaults.log"
        [ "$(rg -c -F -- "$expected" "$root/defaults.log")" -eq 1 ]
    done
    assert_contains 'read com.if.Amphetamine Trigger Data' "$root/defaults.log"
    assert_contains 'read-type com.if.Amphetamine Trigger Data' "$root/defaults.log"
    for key in 'Start Session At Launch' 'Start Session On Wake' 'Enable Triggers'; do
        PATH="$fake_bin:$PATH" FAKE_DEFAULTS_STATE="$root/state" FAKE_DEFAULTS_LOG="$root/defaults.log" \
            defaults read-type com.if.Amphetamine "$key" | rg -F 'Type is integer' >/dev/null
    done
    PATH="$fake_bin:$PATH" FAKE_DEFAULTS_STATE="$root/state" FAKE_DEFAULTS_LOG="$root/defaults.log" \
        defaults read-type com.if.Amphetamine 'Trigger Data' | rg -F 'Type is array' >/dev/null
    assert_contains '-convert xml1 -o - -' "$root/plutil.log"
    PATH="$fake_bin:$PATH" FAKE_DEFAULTS_STATE="$root/state" FAKE_DEFAULTS_LOG="$root/defaults.log" \
        defaults read com.if.Amphetamine 'Trigger Data' >"$root/trigger-read"
    for expected in '(' 'AllowDisplaySleep = 1;' 'App = ChatGPT;' \
        'Enabled = 1;' 'Name = ChatGPT;' 'TypeIDs =         (' '            1' '        );'; do
        assert_contains "$expected" "$root/trigger-read"
    done
    assert_contains ')' "$root/trigger-read"
    ! rg -n 'history|statistic|statistics|symlink|delete|rm -|login|ServiceManagement' "$root/defaults.log" "$setup_path" 2>/dev/null

    before=$(shasum -a 256 "$root/state")
    PATH="$fake_bin:$PATH" FAKE_DEFAULTS_STATE="$root/state" FAKE_DEFAULTS_LOG="$root/defaults.log" FAKE_PLUTIL_LOG="$root/plutil.log" HOME="$root/home" bash "$setup_path"
    [ "$(shasum -a 256 "$root/state")" = "$before" ]
    for expected in \
        'write com.if.Amphetamine Start Session At Launch -int 0' \
        'write com.if.Amphetamine Start Session On Wake -int 0' \
        'write com.if.Amphetamine Enable Triggers -int 1' \
        'write com.if.Amphetamine Trigger Data ('; do
        [ "$(rg -c -F -- "$expected" "$root/defaults.log")" -eq 2 ]
    done
}

run_failure_scenario() {
    local setup_path="$1"
    local root="$2"
    local injection="$3"
    local fake_bin="$root/bin"
    mkdir -p "$root/home"
    make_fake_defaults "$fake_bin"
    make_fake_plutil "$fake_bin"
    : >"$root/defaults.log"
    : >"$root/plutil.log"
    : >"$root/state"

    local rc=0
    set +e
    case "$injection" in
        read)
            env PATH="$fake_bin:$PATH" HOME="$root/home" \
                FAKE_DEFAULTS_STATE="$root/state" FAKE_DEFAULTS_LOG="$root/defaults.log" \
                FAKE_PLUTIL_LOG="$root/plutil.log" FAKE_DEFAULTS_FAIL_READ_KEY='Enable Triggers' \
                bash "$setup_path"
            rc=$?
            ;;
        read-type)
            env PATH="$fake_bin:$PATH" HOME="$root/home" \
                FAKE_DEFAULTS_STATE="$root/state" FAKE_DEFAULTS_LOG="$root/defaults.log" \
                FAKE_PLUTIL_LOG="$root/plutil.log" FAKE_DEFAULTS_MISMATCH_READ_TYPE_KEY='Enable Triggers' \
                bash "$setup_path"
            rc=$?
            ;;
        read-type-failure)
            env PATH="$fake_bin:$PATH" HOME="$root/home" \
                FAKE_DEFAULTS_STATE="$root/state" FAKE_DEFAULTS_LOG="$root/defaults.log" \
                FAKE_PLUTIL_LOG="$root/plutil.log" FAKE_DEFAULTS_FAIL_READ_TYPE_KEY='Enable Triggers' \
                bash "$setup_path"
            rc=$?
            ;;
        plutil)
            env PATH="$fake_bin:$PATH" HOME="$root/home" \
                FAKE_DEFAULTS_STATE="$root/state" FAKE_DEFAULTS_LOG="$root/defaults.log" \
                FAKE_PLUTIL_LOG="$root/plutil.log" FAKE_PLUTIL_FAIL=1 \
                bash "$setup_path"
            rc=$?
            ;;
        *)
            printf 'unknown failure injection: %s\n' "$injection" >&2
            rc=2
            ;;
    esac
    set -e
    [ "$rc" -ne 0 ]
}

run_production_scenario_if_present() {
    [ -f "$SETUP" ] || return 0
    [ -f "$MASTER" ]
    [ "$(rg -c '^    "apps/amphetamine/amphetamine-setup\.sh"$' "$MASTER")" -eq 1 ]
    run_setup_scenario "$SETUP" "$TMP_ROOT/production"
    for injection in read read-type read-type-failure plutil; do
        run_failure_scenario "$SETUP" "$TMP_ROOT/production-$injection" "$injection"
    done
}

fixture_setup="$TMP_ROOT/fixture/apps/amphetamine/amphetamine-setup.sh"
make_setup_fixture "$fixture_setup"
run_setup_scenario "$fixture_setup" "$TMP_ROOT/fixture"
for injection in read read-type read-type-failure plutil; do
    run_failure_scenario "$fixture_setup" "$TMP_ROOT/fixture-$injection" "$injection"
done
run_production_scenario_if_present
printf '%s\n' '[PASS] Amphetamine setup defaults, Trigger Data, readback, scope, registration, and idempotency contract'
