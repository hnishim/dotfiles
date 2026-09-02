#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SWIFT_SOURCE="$SCRIPT_DIR/../CustomInstructionsSync.swift"
TEST_SOURCE="$SCRIPT_DIR/mirror-layout-test.swift"
TMP_ROOT=$(mktemp -d /tmp/hir99-mirror-layout.XXXXXX)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

swiftc "$SWIFT_SOURCE" "$TEST_SOURCE" \
    -DTESTING \
    -o "$TMP_ROOT/mirror-layout-test" \
    -framework AppKit -O -parse-as-library \
    -module-cache-path "$TMP_ROOT/swift-module-cache"

"$TMP_ROOT/mirror-layout-test" "$TMP_ROOT/fixtures"
