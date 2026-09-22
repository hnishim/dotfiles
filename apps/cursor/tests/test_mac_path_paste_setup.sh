#!/bin/bash
# HIR-310: isolated Cursor installation behavior; no real Cursor or network calls.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../../.." && pwd)
SOURCE="$REPO/apps/cursor/cursor-setup.sh"
ROOT=$(mktemp -d "/tmp/hir-310-test.XXXXXX")
trap 'rm -rf -- "$ROOT"' EXIT
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

# The release URL and SHA-256 must be pinned in production, not invented in tests.
grep -Eq 'https://github.com/hnishim/vscode-path-paste/releases/download/[^[:space:]"]+\.vsix' "$SOURCE" \
    || fail 'version-pinned GitHub Releases VSIX URL is missing'
grep -Eq '[[:xdigit:]]{64}' "$SOURCE" || fail 'pinned SHA-256 is missing'

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
    printf 'fixture VSIX data\n' > "$base/payload.vsix"
    : > "$base/events"
    cat > "$base/bin/yq" <<'MOCK'
#!/bin/bash
[ "$1" = "e" ] && [ "$2" = ".extensions[]" ] || exit 9
printf 'openai.chatgpt\n'
MOCK
    cat > "$base/bin/cursor" <<'MOCK'
#!/bin/bash
case "$1" in
    --list-extensions)
        printf 'list\n' >> "$TEST_DIR/events"
        [ "$TEST_SCENARIO" != "list-fail" ] || exit 19
        cat "$TEST_DIR/installed" ;;
    --install-extension)
        [ "$#" -eq 2 ] || exit 17
        case "$2" in
            *.vsix)
                printf 'vsix\n' >> "$TEST_DIR/events"
                [ -s "$2" ] || exit 18
                [ "$TEST_SCENARIO" != "install-fail" ] || exit 20
                if [ "$TEST_SCENARIO" != "install-no-register" ]; then
                    printf 'hnishim.vscode-path-paste\n' >> "$TEST_DIR/installed"
                fi ;;
            *) printf 'other\n' >> "$TEST_DIR/events" ;;
        esac ;;
    *) exit 21 ;;
esac
MOCK
    cat > "$base/bin/curl" <<'MOCK'
#!/bin/bash
output= url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--output) shift; output="$1" ;;
        https://*) url="$1" ;;
    esac
    shift
done
printf 'curl\n' >> "$TEST_DIR/events"
[ -n "$output" ] && [ -n "$url" ] || exit 23
case "$url" in
    https://github.com/hnishim/vscode-path-paste/releases/download/*/*.vsix) ;;
    *) exit 24 ;;
esac
[ "$TEST_SCENARIO" != "download-fail" ] || exit 22
if [ "$TEST_SCENARIO" = "empty-download" ]; then
    : > "$output"
else
    cp "$TEST_DIR/payload.vsix" "$output"
fi
MOCK
    cat > "$base/bin/shasum" <<'MOCK'
#!/bin/bash
[ "$1" = "-a" ] && [ "$2" = "256" ] && [ -s "$3" ] || exit 25
printf 'sha\n' >> "$TEST_DIR/events"
if [ "$TEST_SCENARIO" = "hash-mismatch" ]; then
    digest=0000000000000000000000000000000000000000000000000000000000000000
else
    digest=$(grep -Eo '[[:xdigit:]]{64}' "$TEST_DIR/repo/apps/cursor/cursor-setup.sh" | head -n 1)
    [ -n "$digest" ] || exit 26
fi
printf '%s  %s\n' "$digest" "$3"
MOCK
    chmod +x "$base/bin/"*
    if [ "$name" = "preinstalled" ]; then
        printf 'HNISHIM.VSCODE-PATH-PASTE\n' >> "$base/installed"
    fi
    if [ "$name" = "missing-curl" ]; then
        mkdir -p "$base/minbin"
        for cmd in dirname pwd ln readlink grep mktemp rm cat shasum head tr awk sed cp; do
            real=$(command -v "$cmd") || fail "test prerequisite missing: $cmd"
            ln -s "$real" "$base/minbin/$cmd"
        done
        ln -s "$base/bin/cursor" "$base/minbin/cursor"
        ln -s "$base/bin/yq" "$base/minbin/yq"
    fi
}

run_setup() {
    local name="$1" expected="$2" base="$ROOT/$1" path="$ROOT/$1/bin:$PATH" rc=0
    if [ "$name" = "missing-curl" ]; then path="$base/minbin"; fi
    env HOME="$base/home" TMPDIR="$base/tmp" PATH="$path" TEST_DIR="$base" \
        TEST_SCENARIO="$name" /bin/bash "$base/repo/apps/cursor/cursor-setup.sh" \
        >"$base/output" 2>&1 || rc=$?
    if [ "$expected" = "pass" ] && [ "$rc" -ne 0 ]; then
        cat "$base/output" >&2; fail "$name should succeed (exit $rc)"
    fi
    if [ "$expected" = "fail" ] && [ "$rc" -eq 0 ]; then
        cat "$base/output" >&2; fail "$name should fail closed"
    fi
    [ -z "$(find "$base/tmp" -mindepth 1 -print)" ] || fail "$name leaked a temporary download"
}
events() {
    local actual
    actual=$(grep -c "^$2$" "$ROOT/$1/events" || true)
    [ "$actual" -eq "$3" ] || fail "$1: $2 count $actual, expected $3"
}

make_case fresh
run_setup fresh pass
events fresh curl 1
events fresh sha 1
events fresh vsix 1
events fresh list 2
[ -L "$ROOT/fresh/home/Library/Application Support/Cursor/User/settings.json" ] \
    || fail 'settings link missing'
[ -L "$ROOT/fresh/home/Library/Application Support/Cursor/User/keybindings.json" ] \
    || fail 'keybindings link missing'
run_setup fresh pass
events fresh curl 1
events fresh vsix 1
events fresh other 0
printf '[PASS] fresh install, links, and rerun idempotency\n'

make_case preinstalled
run_setup preinstalled pass
events preinstalled curl 0
events preinstalled sha 0
events preinstalled vsix 0
printf '[PASS] existing extension is not reinstalled or updated\n'

for scenario in list-fail download-fail empty-download hash-mismatch install-fail install-no-register missing-curl; do
    make_case "$scenario"
    run_setup "$scenario" fail
    case "$scenario" in
        list-fail|missing-curl) events "$scenario" curl 0 ;;
        *) events "$scenario" curl 1 ;;
    esac
    case "$scenario" in
        install-fail|install-no-register) events "$scenario" vsix 1 ;;
        *) events "$scenario" vsix 0 ;;
    esac
    printf '[PASS] %s fails closed\n' "$scenario"
done
printf '[PASS] HIR-310 isolated installation contract\n'
