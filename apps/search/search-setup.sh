#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROUTES_SCRIPT="$SCRIPT_DIR/search-routes-setup.py"
PREFERENCES_SCRIPT="$SCRIPT_DIR/search-preferences-setup.sh"

# macOSのBash 3.2ではset -uと空配列の展開が衝突するため、"$@"を直接渡す。
# --checkが含まれる場合も、argparseは重複した--checkを受け付ける。
check_only=false
for arg in "$@"; do
  if [[ $arg == "--check" ]]; then
    check_only=true
  fi
done

# --config / --support-dirを含む引数をルーティング側へそのまま渡す。
# 両方の設定を検証してから書く。Search起動中の書き込みは各処理が拒否する。
python3 "$ROUTES_SCRIPT" --check "$@"
bash "$PREFERENCES_SCRIPT" --check
if [[ $check_only == true ]]; then
  exit 0
fi

bash "$PREFERENCES_SCRIPT"
python3 "$ROUTES_SCRIPT" "$@"
