#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROUTES_SCRIPT="$SCRIPT_DIR/search-routes-setup.py"
PREFERENCES_SCRIPT="$SCRIPT_DIR/search-preferences-setup.sh"

# 既存の--config / --support-dirはルーティング側へそのまま渡す。
check_only=false
route_args=()
for arg in "$@"; do
  if [[ $arg == "--check" ]]; then
    check_only=true
  else
    route_args+=("$arg")
  fi
done

# 両方の設定を検証してから書く。Search起動中の書き込みは各処理が拒否する。
python3 "$ROUTES_SCRIPT" --check "${route_args[@]}"
bash "$PREFERENCES_SCRIPT" --check
if [[ $check_only == true ]]; then
  exit 0
fi

bash "$PREFERENCES_SCRIPT"
python3 "$ROUTES_SCRIPT" "${route_args[@]}"
