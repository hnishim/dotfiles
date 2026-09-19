#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
TMP_ROOT=$(mktemp -d /tmp/hir278-swift-snapshot.XXXXXX)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

swiftc "$SCRIPT_DIR/../CustomInstructionsSync.swift" \
    "$SCRIPT_DIR/temporary-snapshot-test.swift" \
    -DTESTING -framework AppKit -parse-as-library \
    -module-cache-path "$TMP_ROOT/swift-module-cache" \
    -o "$TMP_ROOT/temporary-snapshot-test"

"$TMP_ROOT/temporary-snapshot-test" "$TMP_ROOT/fixtures"
