#!/bin/bash
# HIR-310: isolated source-main update contract. No real network, npm or Cursor is used.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../../.." && pwd)
SOURCE="$REPO/apps/cursor/cursor-setup.sh"
ROOT=$(mktemp -d)
trap 'rm -rf -- "$ROOT"' EXIT
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: actual [$1], expected [$2]"; }
count() { grep -c "^$2$" "$ROOT/$1/events" || true; }
assert_count() { assert_eq "$(count "$1" "$2")" "$3" "$1: $2 count"; }
record() { cat "$ROOT/$1/home/Library/Application Support/my.cursor.mac-path-paste/installed-commit"; }

make_case() {
    local name="$1" base="$ROOT/$1" repo="$ROOT/$1/repo"
    mkdir -p "$repo/apps/cursor/extensions" "$repo/apps/cursor/user-profile" "$repo/lib" \
        "$base/bin" "$base/tmp" "$base/home/Library/Application Support/Cursor/User"
    cp "$SOURCE" "$repo/apps/cursor/cursor-setup.sh"
    cp "$REPO/lib/common.sh" "$repo/lib/common.sh"
    printf 'extensions:\n  - openai.chatgpt\n' > "$repo/apps/cursor/extensions/extensions.yml"
    printf '{}\n' > "$repo/apps/cursor/user-profile/settings.json"
    printf '[]\n' > "$repo/apps/cursor/user-profile/keybindings.json"
    printf 'openai.chatgpt\n' > "$base/installed"
    printf '1111111111111111111111111111111111111111\n' > "$base/remote_sha"
    cp "$base/remote_sha" "$base/clone_sha"
    : > "$base/events"

    cat > "$base/bin/yq" <<'MOCK'
#!/bin/bash
printf 'openai.chatgpt\n'
MOCK
    cat > "$base/bin/git" <<'MOCK'
#!/bin/bash
case "$1" in
    ls-remote)
        printf 'remote\n' >> "$TEST_DIR/events"
        [ "$TEST_FAULT" != remote-fail ] || exit 12
        [[ " $* " == *" https://github.com/hnishim/vscode-path-paste.git "* ]] || exit 13
        [[ " $* " == *" refs/heads/main "* ]] || exit 14
        printf '%s\trefs/heads/main\n' "$(cat "$TEST_DIR/remote_sha")" ;;
    clone)
        printf 'clone\n' >> "$TEST_DIR/events"
        [ "$TEST_FAULT" != clone-fail ] || exit 15
        [[ " $* " == *" https://github.com/hnishim/vscode-path-paste.git "* ]] || exit 16
        [[ " $* " == *" main "* ]] || exit 17
        destination=""
        for arg in "$@"; do destination="$arg"; done
        mkdir -p "$destination"
        cp "$TEST_DIR/clone_sha" "$destination/.fake-head"
        printf '{"name":"vscode-path-paste","version":"0.1.0"}\n' > "$destination/package.json"
        printf '{}\n' > "$destination/package-lock.json" ;;
    -C)
        dir="$2"
        shift 2
        [ "$1" = rev-parse ] && [ "$2" = HEAD ] || exit 18
        printf 'head\n' >> "$TEST_DIR/events"
        cat "$dir/.fake-head" ;;
    rev-parse)
        [ "$2" = HEAD ] || exit 19
        printf 'head\n' >> "$TEST_DIR/events"
        cat .fake-head ;;
    *) exit 20 ;;
esac
MOCK
    cat > "$base/bin/npm" <<'MOCK'
#!/bin/bash
case "$1" in
    ci)
        printf 'ci\n' >> "$TEST_DIR/events"
        [ "$TEST_FAULT" != npm-ci-fail ] || exit 21 ;;
    run)
        [ "$2" = package:vsix ] || exit 22
        printf 'package\n' >> "$TEST_DIR/events"
        [ "$TEST_FAULT" != package-fail ] || exit 23
        [ "$TEST_FAULT" = no-vsix ] || printf 'mock VSIX\n' > vscode-path-paste.vsix ;;
    *) exit 24 ;;
esac
MOCK
    cat > "$base/bin/cursor" <<'MOCK'
#!/bin/bash
case "$1" in
    --list-extensions)
        printf 'list\n' >> "$TEST_DIR/events"
        [ "$TEST_FAULT" != list-fail ] || exit 25
        if [ "$TEST_FAULT" = post-list-fail ]; then
            calls=$(grep -c '^list$' "$TEST_DIR/events")
            [ "$calls" -eq 1 ] || exit 26
        fi
        cat "$TEST_DIR/installed" ;;
    --install-extension)
        case "$2" in
            *.vsix)
                printf 'vsix\n' >> "$TEST_DIR/events"
                [ -s "$2" ] || exit 27
                if [ "$#" -eq 3 ] && [ "$3" = --force ]; then
                    printf 'force\n' >> "$TEST_DIR/events"
                fi
                [ "$TEST_FAULT" != install-fail ] || exit 28
                if [ "$TEST_FAULT" != install-no-register ]; then
                    grep -qi '^hnishim\.vscode-path-paste$' "$TEST_DIR/installed" ||
                        printf 'hnishim.vscode-path-paste\n' >> "$TEST_DIR/installed"
                fi ;;
            *) printf 'other\n' >> "$TEST_DIR/events"; exit 29 ;;
        esac ;;
    *) exit 30 ;;
esac
MOCK
    cat > "$base/bin/mv" <<'MOCK'
#!/bin/bash
case "$*" in
    *my.cursor.mac-path-paste/installed-commit*)
        [ "$TEST_FAULT" != record-fail ] || exit 31 ;;
esac
exec /bin/mv "$@"
MOCK
    chmod +x "$base/bin/"*
}

run_setup() {
    local name="$1" expected="$2" fault="$3" base="$ROOT/$1" status=0
    env HOME="$base/home" TMPDIR="$base/tmp" PATH="$base/bin:$PATH" \
        TEST_DIR="$base" TEST_FAULT="$fault" /bin/bash "$base/repo/apps/cursor/cursor-setup.sh" \
        > "$base/output" 2>&1 || status=$?
    if [ "$expected" = pass ] && [ "$status" -ne 0 ]; then
        cat "$base/output" >&2
        fail "$name/$fault should pass, exit $status"
    fi
    if [ "$expected" = fail ] && [ "$status" -eq 0 ]; then
        cat "$base/output" >&2
        fail "$name/$fault should fail"
    fi
    [ -z "$(find "$base/tmp" -mindepth 1 -print)" ] || fail "$name/$fault leaked temporary files"
    [ -L "$base/home/Library/Application Support/Cursor/User/settings.json" ] ||
        fail "$name/$fault settings symlink damaged"
    [ -L "$base/home/Library/Application Support/Cursor/User/keybindings.json" ] ||
        fail "$name/$fault keybindings symlink damaged"
    assert_count "$name" other 0
    grep -qx 'openai.chatgpt' "$base/installed" || fail "$name/$fault other extension damaged"
}

make_case fresh
run_setup fresh pass none
assert_eq "$(record fresh)" "1111111111111111111111111111111111111111" 'initial commit record'
assert_count fresh clone 1
assert_count fresh ci 1
assert_count fresh package 1
assert_count fresh vsix 1
run_setup fresh pass none
assert_count fresh clone 1
assert_count fresh ci 1
assert_count fresh vsix 1
printf '2222222222222222222222222222222222222222\n' > "$ROOT/fresh/remote_sha"
cp "$ROOT/fresh/remote_sha" "$ROOT/fresh/clone_sha"
run_setup fresh pass none
assert_eq "$(record fresh)" "2222222222222222222222222222222222222222" 'changed upstream commit'
assert_count fresh vsix 2
assert_count fresh force 1
run_setup fresh pass none
assert_count fresh vsix 2
printf '3333333333333333333333333333333333333333\n' > "$ROOT/fresh/remote_sha"
printf '4444444444444444444444444444444444444444\n' > "$ROOT/fresh/clone_sha"
run_setup fresh pass none
assert_eq "$(record fresh)" "4444444444444444444444444444444444444444" 'actual cloned HEAD must be recorded'
assert_count fresh force 2

make_case missing
mkdir -p "$ROOT/missing/home/Library/Application Support/my.cursor.mac-path-paste"
cp "$ROOT/missing/remote_sha" "$ROOT/missing/home/Library/Application Support/my.cursor.mac-path-paste/installed-commit"
run_setup missing pass none
assert_count missing vsix 1

for fault in remote-fail clone-fail npm-ci-fail package-fail no-vsix install-fail \
    install-no-register post-list-fail record-fail list-fail; do
    make_case "$fault"
    printf 'HNISHIM.VSCODE-PATH-PASTE\n' >> "$ROOT/$fault/installed"
    mkdir -p "$ROOT/$fault/home/Library/Application Support/my.cursor.mac-path-paste"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' \
        > "$ROOT/$fault/home/Library/Application Support/my.cursor.mac-path-paste/installed-commit"
    run_setup "$fault" fail "$fault"
    assert_eq "$(record "$fault")" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$fault must preserve previous record"
    if [ "$fault" = remote-fail ] || [ "$fault" = list-fail ]; then
        assert_count "$fault" clone 0
    fi
done

printf '[PASS] HIR-310 source-main sync, same-version force update, failure safety, isolation\n'
