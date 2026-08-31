#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
FERDIUM_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
MANIFEST="$FERDIUM_ROOT/recipes/google-calendar/upstream-manifest"
FIXTURE="$SCRIPT_DIR/fixtures/upstream/google-calendar/webview.js"
SETUP="$FERDIUM_ROOT/ferdium-setup.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ferdium-setup-test.XXXXXX")
TMP_ROOT=$(cd -- "$TMP_ROOT" && pwd)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

EXPECTED_REF=fc4675ab5724e83d59d92f38a63dcc503615a7c9
EXPECTED_WEBVIEW_SHA=24f28f7c340e89668e896e945d0a773c977feb5b979b547dd3c7b7c4e37b7344
SOURCE_USER="$FERDIUM_ROOT/recipes/google-calendar/user.js"
SOURCE_WEBVIEW="$FERDIUM_ROOT/recipes/google-calendar/webview.js"

failures=0

assert_link() {
    [ -L "$1" ]
    [ "$(readlink "$1")" = "$2" ]
}

assert_manifest_fixture() {
    [ "$(awk -F= '$1 == "source_ref" { print $2 }' "$MANIFEST")" = "$EXPECTED_REF" ]
    [ "$(awk -F= '$1 == "recipe_version" { print $2 }' "$MANIFEST")" = 2.4.7 ]
    ! rg -n '(^|[[:space:]])user\.js([[:space:]]|$)' "$MANIFEST" >/dev/null
    [ "$(shasum -a 256 "$FIXTURE" | awk '{ print $1 }')" = "$EXPECTED_WEBVIEW_SHA" ]
    [ "$(awk -F '\t' '$1 == "webview.js" { print $3 }' "$MANIFEST")" = "$EXPECTED_WEBVIEW_SHA" ]
}

make_recipe() {
    local root="$1"
    mkdir -p "$root/apps/ferdium/recipes/google-calendar" "$root/apps/ferdium/tests/fixtures/upstream/google-calendar"
    cp "$SETUP" "$root/apps/ferdium/ferdium-setup.sh"
    cp "$SOURCE_USER" "$root/apps/ferdium/recipes/google-calendar/user.js"
    cp "$SOURCE_WEBVIEW" "$root/apps/ferdium/recipes/google-calendar/webview.js"
    cp "$MANIFEST" "$root/apps/ferdium/recipes/google-calendar/upstream-manifest"
    cp "$FIXTURE" "$root/apps/ferdium/tests/fixtures/upstream/google-calendar/webview.js"
    mkdir -p "$root/lib"
    cp "$DOTFILES_ROOT/lib/common.sh" "$root/lib/common.sh"
}

run_setup_capture() {
    local root="$1"
    local home="$2"
    local output="$3"
    if HOME="$home" bash "$root/apps/ferdium/ferdium-setup.sh" >"$output" 2>&1; then
        return 0
    else
        local rc=$?
        return "$rc"
    fi
}

run_scenario() {
    local name="$1"
    set +e
    (
        set -e
        "$name"
    )
    local rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "[PASS] $name"
    else
        printf '%s\n' "[FAIL] $name"
        failures=$((failures + 1))
    fi
}

snapshot_tree() {
    local directory="$1"
    find -P "$directory" -print | sort | while IFS= read -r path; do
        if [ -L "$path" ]; then
            printf 'link %s -> %s\n' "$path" "$(readlink "$path")"
        elif [ -d "$path" ]; then
            printf 'directory %s\n' "$path"
        else
            printf 'file %s %s\n' "$path" "$(shasum -a 256 "$path" | awk '{ print $1 }')"
        fi
    done
}

assert_safe_stop() {
    local rc="$1"
    local output="$2"
    local before="$3"
    local target="$4"
    local after
    [ "$rc" -ne 0 ]
    rg -n '競合|既知|manifest|backup|リンク' "$output" >/dev/null
    after=$(snapshot_tree "$target")
    [ "$after" = "$before" ]
}

scenario_target_missing_and_idempotent() {
    local root="$TMP_ROOT/missing" home="$TMP_ROOT/missing-home"
    make_recipe "$root"
    mkdir -p "$home"
    local output="$TMP_ROOT/missing.output"
    run_setup_capture "$root" "$home" "$output"
    local target="$home/Library/Application Support/Ferdium/recipes/google-calendar"
    assert_link "$target/user.js" "$root/apps/ferdium/recipes/google-calendar/user.js"
    assert_link "$target/webview.js" "$root/apps/ferdium/recipes/google-calendar/webview.js"
    local before
    before=$(snapshot_tree "$home")
    run_setup_capture "$root" "$home" "$output"
    [ "$(snapshot_tree "$home")" = "$before" ]
}

scenario_known_upstream_backup_and_relocation() {
    local root="$TMP_ROOT/known" home="$TMP_ROOT/known-home"
    make_recipe "$root"
    local target="$home/Library/Application Support/Ferdium/recipes/google-calendar"
    mkdir -p "$target" "$home"
    cp "$FIXTURE" "$target/webview.js"
    local output="$TMP_ROOT/known.output"
    run_setup_capture "$root" "$home" "$output"
    local backup_root="$home/Library/Application Support/Ferdium-dotfiles-backups/google-calendar"
    local backup
    backup=$(find "$backup_root" -type f -maxdepth 1 -print)
    [ -n "$backup" ]
    [ "$(shasum -a 256 "$backup" | awk '{ print $1 }')" = "$EXPECTED_WEBVIEW_SHA" ]
    assert_link "$target/webview.js" "$root/apps/ferdium/recipes/google-calendar/webview.js"
    rm -rf "$root/apps/ferdium/recipes/google-calendar"
    mkdir -p "$root/apps/ferdium/recipes/google-calendar"
    cp "$SOURCE_USER" "$root/apps/ferdium/recipes/google-calendar/user.js"
    cp "$SOURCE_WEBVIEW" "$root/apps/ferdium/recipes/google-calendar/webview.js"
    cp "$MANIFEST" "$root/apps/ferdium/recipes/google-calendar/upstream-manifest"
    run_setup_capture "$root" "$home" "$output"
    [ "$(find "$backup_root" -type f -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]
    [ "$(shasum -a 256 "$backup" | awk '{ print $1 }')" = "$EXPECTED_WEBVIEW_SHA" ]
}

scenario_unknown_and_unsafe_states_preserved() {
    local root="$TMP_ROOT/unsafe" home="$TMP_ROOT/unsafe-home"
    make_recipe "$root"
    local target="$home/Library/Application Support/Ferdium/recipes/google-calendar"
    mkdir -p "$target" "$home"
    ln -s "$root/apps/ferdium/recipes/google-calendar/user.js" "$target/user.js"
    for state in custom different broken directory; do
        rm -rf "$target/webview.js"
        case "$state" in
            custom) printf '%s\n' keep > "$target/webview.js" ;;
            different) ln -s "$target/other.js" "$target/webview.js" ;;
            broken) ln -s "$target/missing.js" "$target/webview.js" ;;
            directory) mkdir "$target/webview.js"; printf '%s\n' keep > "$target/webview.js/entry" ;;
        esac
        local before output="$TMP_ROOT/unsafe-$state.output"
        before=$(snapshot_tree "$target")
        local rc=0
        run_setup_capture "$root" "$home" "$output" || rc=$?
        assert_safe_stop "$rc" "$output" "$before" "$target"
    done
    rm -rf "$target/webview.js" "$target/user.js"
    printf '%s\n' keep > "$target/user.js"
    local user_before
    user_before=$(shasum -a 256 "$target/user.js")
    ln -s "$root/apps/ferdium/recipes/google-calendar/webview.js" "$target/webview.js"
    local output="$TMP_ROOT/unsafe-user.output" rc=0
    run_setup_capture "$root" "$home" "$output" || rc=$?
    [ "$rc" -ne 0 ]
    rg -n '競合|既知|manifest|backup|リンク' "$output" >/dev/null
    [ "$(shasum -a 256 "$target/user.js")" = "$user_before" ]
    assert_link "$target/webview.js" "$root/apps/ferdium/recipes/google-calendar/webview.js"
}

scenario_backup_root_conflict_and_link_failure() {
    local root="$TMP_ROOT/failure" home="$TMP_ROOT/failure-home"
    make_recipe "$root"
    local target="$home/Library/Application Support/Ferdium/recipes/google-calendar"
    local backup_parent="$home/Library/Application Support/Ferdium-dotfiles-backups"
    local backup_root="$backup_parent/google-calendar"
    mkdir -p "$target" "$backup_parent" "$home/bin" "$home"
    ln -s "$root/apps/ferdium/recipes/google-calendar/user.js" "$target/user.js"
    cp "$FIXTURE" "$target/webview.js"
    printf '%s\n' conflict > "$backup_root"
    local before output="$TMP_ROOT/failure-conflict.output" rc=0
    before=$(shasum -a 256 "$target/webview.js")
    run_setup_capture "$root" "$home" "$output" || rc=$?
    [ "$rc" -ne 0 ]
    rg -n '競合|既知|manifest|backup|リンク' "$output" >/dev/null
    [ "$(shasum -a 256 "$target/webview.js")" = "$before" ]
    rm -rf "$backup_root"
    mkdir -p "$backup_parent"
    cp "$FIXTURE" "$target/webview.js"
    local ln_counter="$home/bin/ln.count"
    printf '%s\n' 0 > "$ln_counter"
    printf '#!/bin/bash\ncount=$(cat "%s")\ncount=$((count + 1))\nprintf "%%s\\n" "$count" > "%s"\nif [ "$count" -eq 1 ]; then exit 1; fi\nexec /bin/ln "$@"\n' "$ln_counter" "$ln_counter" > "$home/bin/ln"
    chmod +x "$home/bin/ln"
    output="$TMP_ROOT/failure-link.output" rc=0
    PATH="$home/bin:$PATH" HOME="$home" bash "$root/apps/ferdium/ferdium-setup.sh" >"$output" 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
    rg -n 'backup|復旧|手動|リンク|target' "$output" >/dev/null
    [ ! -e "$target/webview.js" ]
    [ ! -L "$target/webview.js" ]
    [ "$(cat "$ln_counter")" -eq 1 ]
    [ -d "$backup_root" ]
    local backup
    backup=$(find "$backup_root" -type f -maxdepth 1 -print)
    [ -n "$backup" ]
    [ "$(shasum -a 256 "$backup" | awk '{ print $1 }')" = "$EXPECTED_WEBVIEW_SHA" ]
    output="$TMP_ROOT/failure-link-retry.output" rc=0
    PATH="$home/bin:$PATH" HOME="$home" bash "$root/apps/ferdium/ferdium-setup.sh" >"$output" 2>&1 || rc=$?
    [ "$rc" -eq 0 ]
    [ "$(cat "$ln_counter")" -eq 2 ]
    assert_link "$target/webview.js" "$root/apps/ferdium/recipes/google-calendar/webview.js"
    [ "$(find "$backup_root" -type f -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]
    [ "$(shasum -a 256 "$backup" | awk '{ print $1 }')" = "$EXPECTED_WEBVIEW_SHA" ]
}

assert_manifest_fixture
run_scenario scenario_target_missing_and_idempotent
run_scenario scenario_known_upstream_backup_and_relocation
run_scenario scenario_unknown_and_unsafe_states_preserved
run_scenario scenario_backup_root_conflict_and_link_failure

[ "$failures" -eq 0 ]
