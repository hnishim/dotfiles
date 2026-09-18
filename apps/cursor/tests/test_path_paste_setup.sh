#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
SETUP="$DOTFILES_ROOT/apps/cursor/cursor-setup.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hir273-cursor-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

make_fake_tools() {
    local bin="$1"
    mkdir -p "$bin"

    cat >"$bin/yq" <<'EOF'
#!/bin/bash
printf '%s\n' 'example.existing-extension'
EOF

    cat >"$bin/cursor" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${CURSOR_LOG:?}"
case "${1:-}" in
    --list-extensions) exit 0 ;;
    --install-extension) exit 0 ;;
    *) exit 0 ;;
esac
EOF

    cat >"$bin/code" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${CODE_LOG:?}"
case "${1:-}" in
    --install-extension) exit 0 ;;
    *) exit 0 ;;
esac
EOF

    cat >"$bin/pnpm" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\t%s\n' "$PWD" "$*" >>"${PNPM_LOG:?}"
case " $* " in
    *" vsce "*" package "*|*" exec "*" vsce "*" package "*|*" dlx "*" vsce "*" package "*)
        out=""
        previous=""
        for arg in "$@"; do
            if [ "$previous" = "--out" ] || [ "$previous" = "-o" ]; then
                out="$arg"
                break
            fi
            previous="$arg"
        done
        if [ -z "$out" ]; then
            out="$PWD/path-paste-test.vsix"
        elif [ "${out#/}" = "$out" ]; then
            out="$PWD/$out"
        fi
        mkdir -p "$(dirname -- "$out")"
        : >"$out"
        ;;
esac
EOF
    chmod 755 "$bin/yq" "$bin/cursor" "$bin/code" "$bin/pnpm"
}

run_scenario() {
    local name="$1"
    local with_code="$2"
    local root="$TMP_ROOT/$name"
    local home="$root/home"
    local bin="$root/bin"

    mkdir -p "$home/Library/Application Support/Cursor/User"
    mkdir -p "$home/Library/Application Support/Code/User"
    printf '%s\n' '{"sentinel":true}' >"$home/Library/Application Support/Code/User/settings.json"
    : >"$root/cursor.log"
    : >"$root/code.log"
    : >"$root/pnpm.log"

    make_fake_tools "$bin"
    if [ "$with_code" = "no" ]; then
        rm "$bin/code"
    fi

    PATH="$bin:/usr/bin:/bin" \
    HOME="$home" \
    CURSOR_LOG="$root/cursor.log" \
    CODE_LOG="$root/code.log" \
    PNPM_LOG="$root/pnpm.log" \
        bash "$SETUP"

    [ -L "$home/Library/Application Support/Cursor/User/settings.json" ]
    [ -L "$home/Library/Application Support/Cursor/User/keybindings.json" ]
    grep -F -- '--install-extension example.existing-extension' "$root/cursor.log" >/dev/null

    grep -F -- '--frozen-lockfile' "$root/pnpm.log" >/dev/null
    runtime_root="$home/Library/Application Support/dotfiles"
    [ -d "$runtime_root" ]
    find "$runtime_root" -name '*.vsix' -type f -print -quit | grep -q .

    if find "$DOTFILES_ROOT/apps/cursor/path-paste-extension" -name node_modules -type d -print -quit 2>/dev/null | grep -q .; then
        echo "repository source must not contain node_modules" >&2
        exit 1
    fi

    grep -E -- '--install-extension .*\.vsix' "$root/cursor.log" >/dev/null
    if [ "$with_code" = "yes" ]; then
        grep -E -- '--install-extension .*\.vsix' "$root/code.log" >/dev/null
    else
        [ ! -s "$root/code.log" ]
    fi

    grep -F -- '"sentinel":true' "$home/Library/Application Support/Code/User/settings.json" >/dev/null
}

grep -F -- '"editor.pasteAs.preferences"' \
    "$DOTFILES_ROOT/apps/cursor/user-profile/settings.json" >/dev/null

run_scenario with-code yes
run_scenario without-code no
