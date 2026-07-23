#!/usr/bin/env bash

set -u

DEFAULTS_CHANGED=0
DEFAULTS_FAILURES=0
DOCK_CHANGED=0
FINDER_CHANGED=0
SYSTEM_UI_CHANGED=0

HAS_SUDO=0
if command -v sudo >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    HAS_SUDO=1
  elif [ -t 0 ]; then
    echo "[INFO] sudo authentication is required for system-wide defaults."
    if sudo -v; then
      HAS_SUDO=1
    fi
  fi
fi

mark_changed() {
  local restart_target=${1:-}

  DEFAULTS_CHANGED=1
  case "$restart_target" in
    dock) DOCK_CHANGED=1 ;;
    finder) FINDER_CHANGED=1 ;;
    system-ui) SYSTEM_UI_CHANGED=1 ;;
  esac
}

expected_type_name() {
  case "$1" in
    -bool) echo "boolean" ;;
    -int) echo "integer" ;;
    -float) echo "float" ;;
    -string) echo "string" ;;
  esac
}

values_equal() {
  local value_type=$1
  local current=$2
  local expected=$3

  case "$value_type" in
    -bool)
      case "$current" in true|TRUE|YES|yes) current=1 ;; false|FALSE|NO|no) current=0 ;; esac
      case "$expected" in true|TRUE|YES|yes) expected=1 ;; false|FALSE|NO|no) expected=0 ;; esac
      [ "$current" = "$expected" ]
      ;;
    -float)
      awk -v current="$current" -v expected="$expected" \
        'BEGIN { exit !(current + 0 == expected + 0) }'
      ;;
    *)
      [ "$current" = "$expected" ]
      ;;
  esac
}

# $1: scope (user/current-host/system), $2: domain, $3: key
# $4: type, $5: expected value, $6: process to restart (optional)
set_default() {
  local scope=$1
  local domain=$2
  local key=$3
  local value_type=$4
  local expected=$5
  local restart_target=${6:-}
  local current actual_type required_type
  local defaults_command=()

  case "$scope" in
    user)
      defaults_command=(defaults)
      ;;
    current-host)
      defaults_command=(defaults -currentHost)
      ;;
    system)
      if [ "$HAS_SUDO" -ne 1 ]; then
        echo "[WARN] Skipped (sudo unavailable): $domain $key"
        DEFAULTS_FAILURES=$((DEFAULTS_FAILURES + 1))
        return
      fi
      defaults_command=(sudo defaults)
      ;;
  esac

  current=$("${defaults_command[@]}" read "$domain" "$key" 2>/dev/null || true)
  actual_type=$("${defaults_command[@]}" read-type "$domain" "$key" 2>/dev/null || true)
  required_type=$(expected_type_name "$value_type")

  if [ "$actual_type" = "Type is $required_type" ] &&
     values_equal "$value_type" "$current" "$expected"; then
    echo "[INFO] Already set: $domain $key"
    return
  fi

  if ! "${defaults_command[@]}" write "$domain" "$key" "$value_type" "$expected"; then
    echo "[WARN] Failed to set: $domain $key"
    DEFAULTS_FAILURES=$((DEFAULTS_FAILURES + 1))
    return
  fi

  current=$("${defaults_command[@]}" read "$domain" "$key" 2>/dev/null || true)
  actual_type=$("${defaults_command[@]}" read-type "$domain" "$key" 2>/dev/null || true)
  if [ "$actual_type" != "Type is $required_type" ] ||
     ! values_equal "$value_type" "$current" "$expected"; then
    echo "[WARN] Verification failed: $domain $key"
    DEFAULTS_FAILURES=$((DEFAULTS_FAILURES + 1))
    return
  fi

  echo "[SUCCESS] Updated: $domain $key"
  mark_changed "$restart_target"
}

set_user_default() {
  set_default user "$@"
}

set_current_host_default() {
  set_default current-host "$@"
}

set_system_default() {
  set_default system "$@"
}

# Removes an obsolete system-wide preference when it exists.
delete_system_default() {
  local domain=$1
  local key=$2

  if [ "$HAS_SUDO" -ne 1 ]; then
    echo "[WARN] Skipped obsolete key removal (sudo unavailable): $domain $key"
    DEFAULTS_FAILURES=$((DEFAULTS_FAILURES + 1))
    return
  fi

  if ! sudo defaults read "$domain" "$key" >/dev/null 2>&1; then
    echo "[INFO] Already removed: $domain $key"
    return
  fi

  if ! sudo defaults delete "$domain" "$key"; then
    echo "[WARN] Failed to remove obsolete key: $domain $key"
    DEFAULTS_FAILURES=$((DEFAULTS_FAILURES + 1))
    return
  fi

  if sudo defaults read "$domain" "$key" >/dev/null 2>&1; then
    echo "[WARN] Verification failed after removing: $domain $key"
    DEFAULTS_FAILURES=$((DEFAULTS_FAILURES + 1))
    return
  fi

  echo "[SUCCESS] Removed obsolete key: $domain $key"
  mark_changed
}

# Arrays are compared as JSON to avoid depending on `defaults read` formatting.
set_user_array_default() {
  local domain=$1
  local key=$2
  local expected_json=$3
  local restart_target=$4
  shift 4
  local current_json

  current_json=$(defaults read "$domain" "$key" 2>/dev/null |
    plutil -convert json -o - -- - 2>/dev/null || true)
  if [ "$current_json" = "$expected_json" ]; then
    echo "[INFO] Already set: $domain $key"
    return
  fi

  if ! defaults write "$domain" "$key" -array "$@"; then
    echo "[WARN] Failed to set: $domain $key"
    DEFAULTS_FAILURES=$((DEFAULTS_FAILURES + 1))
    return
  fi

  current_json=$(defaults read "$domain" "$key" 2>/dev/null |
    plutil -convert json -o - -- - 2>/dev/null || true)
  if [ "$current_json" != "$expected_json" ]; then
    echo "[WARN] Verification failed: $domain $key"
    DEFAULTS_FAILURES=$((DEFAULTS_FAILURES + 1))
    return
  fi

  echo "[SUCCESS] Updated: $domain $key"
  mark_changed "$restart_target"
}

# Adds or updates one dictionary entry while preserving all other entries.
# $4 is a key path below the dictionary entry, or empty for a scalar entry.
set_user_dict_entry() {
  local domain=$1
  local dictionary_key=$2
  local entry_key=$3
  local child_key_path=$4
  local expected=$5
  local write_value=$6
  local restart_target=${7:-}
  local escaped_entry key_path current

  escaped_entry=${entry_key//./\\.}
  key_path=$escaped_entry
  if [ -n "$child_key_path" ]; then
    key_path="${key_path}.${child_key_path}"
  fi

  current=$(defaults read "$domain" "$dictionary_key" 2>/dev/null |
    plutil -extract "$key_path" raw -o - -- - 2>/dev/null || true)
  if [ "$current" = "$expected" ]; then
    echo "[INFO] Already set: $domain ${dictionary_key}[$entry_key]"
    return
  fi

  if ! defaults write "$domain" "$dictionary_key" -dict-add "$entry_key" "$write_value"; then
    echo "[WARN] Failed to set: $domain ${dictionary_key}[$entry_key]"
    DEFAULTS_FAILURES=$((DEFAULTS_FAILURES + 1))
    return
  fi

  current=$(defaults read "$domain" "$dictionary_key" 2>/dev/null |
    plutil -extract "$key_path" raw -o - -- - 2>/dev/null || true)
  if [ "$current" != "$expected" ]; then
    echo "[WARN] Verification failed: $domain ${dictionary_key}[$entry_key]"
    DEFAULTS_FAILURES=$((DEFAULTS_FAILURES + 1))
    return
  fi

  echo "[SUCCESS] Updated: $domain ${dictionary_key}[$entry_key]"
  mark_changed "$restart_target"
}

# --- Language & Region ---
# システム言語を英語と日本語に設定（英語を優先）
set_user_array_default NSGlobalDomain AppleLanguages '["en","ja"]' "" en ja
# ロケール：システム言語は英語、地域は日本
set_user_default NSGlobalDomain AppleLocale -string "en_JP"
# 月曜日始まり
set_user_default NSGlobalDomain AppleFirstWeekday -int 2
# 単位系：センチメートル
set_user_default NSGlobalDomain AppleMeasurementUnits -string "Centimeters"
# メートル法
set_user_default NSGlobalDomain AppleMetricUnits -bool true
# 摂氏
set_user_default NSGlobalDomain AppleTemperatureUnit -string "Celsius"
# 日付表示
set_user_default NSGlobalDomain AppleDateFormat -string "yyyy/MM/dd"

# --- System ---
# 保存時のファイル選択ダイアログパネルをデフォルトで拡げた状態にする
set_user_default NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
set_user_default NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true

# --- Software Update ---
# 注意: 以下のコマンドはsudo権限が必要な場合があります
# macOSアップデートを自動的にチェック
set_system_default /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
# 現行macOSでは利用されない旧チェック間隔キーを削除
delete_system_default /Library/Preferences/com.apple.SoftwareUpdate ScheduleFrequency
# アプリケーションアップデートを自動的にダウンロード
set_system_default /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool true
# アプリケーションアップデートを自動的にインストール（セキュリティアップデートなど）
set_system_default /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
# macOSアップデートを自動的にインストール
set_system_default /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool true
# App Storeからのアプリケーションアップデートを自動的にインストール
set_system_default /Library/Preferences/com.apple.commerce AutoUpdate -bool true
# App StoreからのOSアップデートを自動的に再起動
set_system_default /Library/Preferences/com.apple.commerce AutoUpdateRestartRequired -bool true

# ====== 入力系 ======
# --- トラックパッド ---
# トラックパッドのタップでクリックを有効化
set_user_default com.apple.AppleMultitouchTrackpad Clicking -bool true
set_user_default com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
set_current_host_default NSGlobalDomain com.apple.mouse.tapBehavior -int 1
set_user_default NSGlobalDomain com.apple.mouse.tapBehavior -int 1

# --- キーボード ---
# すべてのコントロールでフルキーボードアクセスを有効化（例: モーダルダイアログでのタブ操作）
set_user_default NSGlobalDomain AppleKeyboardUIMode -int 3
# Fnキーを標準のファンクションキーとして使用
set_user_default NSGlobalDomain com.apple.keyboard.fnState -bool true
# ダブルスペースでピリオドを入力する機能を無効化
set_user_default NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false

# ====== 出力系 ======
# --- 画面 ---
# フォントの表示がLCD向けに最適化された、中程度のアンチエイリアスに変更（Retinaの場合は削除推奨）
set_user_default NSGlobalDomain AppleFontSmoothing -int 2

# --- Bluetooth Audio ---
# Bluetoothヘッドフォン・ヘッドセットの音質を向上
set_user_default com.apple.BluetoothAudioAgent "Apple Bitpool Min (editable)" -int 40

# ====== UI ======
# --- Dock ---
# Dockの自動表示/非表示機能を有効化
set_user_default com.apple.dock autohide -bool true dock
# Dockを自動表示するまでの遅延と表示/非表示アニメーション速度を設定し、実質的にDockを非表示にする
set_user_default com.apple.dock autohide-delay -float 1000 dock
set_user_default com.apple.dock autohide-time-modifier -float 0 dock
# ホットコーナーを無効化
set_user_default com.apple.dock wvous-tl-corner -int 0 dock
set_user_default com.apple.dock wvous-tr-corner -int 0 dock
set_user_default com.apple.dock wvous-bl-corner -int 0 dock
set_user_default com.apple.dock wvous-br-corner -int 0 dock

# --- Finder ---
# ファイルの拡張子を常に表示
set_user_default NSGlobalDomain AppleShowAllExtensions -bool true finder
# Finderウィンドウのタイトルバーにフルパスを表示
set_user_default com.apple.finder _FXShowPosixPathInTitle -bool true finder
# 隠しファイルを常に表示
set_user_default com.apple.Finder AppleShowAllFiles -bool true finder
# Finderウィンドウ下部のパスバーを表示
set_user_default com.apple.finder ShowPathbar -bool true finder
# Finderにタブバーを表示
set_user_default com.apple.finder ShowTabView -bool true finder
# 未確認のアプリケーションを開く際の警告を有効化
set_user_default com.apple.LaunchServices LSQuarantine -bool true
# デスクトップにアイコンを表示しない
set_user_default com.apple.finder CreateDesktop -bool false finder
# ネットワークドライブやUSBドライブに.DS_Storeファイルを作成しない
set_user_default com.apple.desktopservices DSDontWriteNetworkStores -bool true
set_user_default com.apple.desktopservices DSDontWriteUSBStores -bool true
# Finderを⌘ + Qで終了できるようにする
set_user_default com.apple.finder QuitMenuItem -bool true finder
# 名前順でソートする際に、フォルダをファイルの前に表示
set_user_default com.apple.finder _FXSortFoldersFirst -bool true finder
# ディスクイメージの検証を有効化
set_user_default com.apple.frameworks.diskimages skip-verify -bool false
set_user_default com.apple.frameworks.diskimages skip-verify-locked -bool false
set_user_default com.apple.frameworks.diskimages skip-verify-remote -bool false
# Finderのデフォルト表示形式をカラムビューに設定
# 他の表示形式のコード: `icnv` (アイコン), `clmv` (カラム), `glyv` (ギャラリー)
set_user_default com.apple.finder FXPreferredViewStyle -string "Clmv" finder
# Finderのデフォルト検索範囲を現在のフォルダに設定
set_user_default com.apple.finder FXDefaultSearchScope -string "SCcf" finder
# 新規Finderウィンドウの表示先をDownloadsフォルダに設定
set_user_default com.apple.finder NewWindowTarget -string "PfLo" finder
set_user_default com.apple.finder NewWindowTargetPath -string "file://${HOME}/Downloads" finder

# --- メニューバー ---
macos_major_version="$(sw_vers -productVersion | awk -F. '{print $1}')"

# メニューバーにバッテリー残量をパーセンテージで表示 (macOS 11 Big Sur以降)
if [ "$macos_major_version" -ge 11 ]; then
set_user_default com.apple.controlcenter "BatteryShowPercentage" -bool true system-ui
# メニューバーの時計のフォーマットを設定 (24時間表示、曜日、日付)
set_user_default com.apple.menuextra.clock Show24Hour -bool true system-ui
set_user_default com.apple.menuextra.clock ShowDayOfWeek -bool true system-ui
set_user_default com.apple.menuextra.clock ShowDate -int 2 system-ui
set_user_default com.apple.menuextra.clock FlashDateSeparators -bool false system-ui
# メニューバーから不要なアイコンを非表示にする
# 24 = Don't Show in Menu Bar
set_user_default com.apple.controlcenter "Spotlight" -int 24 system-ui
set_user_default com.apple.controlcenter "Siri" -int 24 system-ui
set_user_default com.apple.controlcenter "TimeMachine" -int 24 system-ui
set_user_default com.apple.controlcenter "Weather" -int 24 system-ui
else
  echo "[INFO] Skipped Control Center settings on macOS < 11."
fi

# --- Desktop & Window ---
# 書類を開くときにタブで開くようにする
set_user_default NSGlobalDomain AppleWindowTabbingMode -string "always"
# ウインドウを画面上部にドラッグしてフルスクリーンにする機能を無効化
set_user_default com.apple.WindowManager dragToFullScreenEnabled -bool false

# --- Quicklook ---
# QuickLookでテキストを選択可能にする
set_user_default com.apple.finder QLEnableTextSelection -bool true finder

# --- Accessibility ---
# ズーム機能のキーボードショートカットを有効化
set_user_default com.apple.universalaccess closeViewHotkeysEnabled -bool true

# --- 日本語入力（Mac標準） ---
# かわせみを使用する場合には特に不要な設定
# Windows風のキー操作を有効化
set_user_default com.apple.inputmethod.Kotoeri 'JIMPrefWindowsLikeShortcut' -bool true
# 全角数字の使用を無効化
set_user_default com.apple.inputmethod.Kotoeri 'JIMPrefFullWidthNumeralCharacters' -bool false

# --- 不要・競合するショートカットを無効化 ---
# 注意: これによりシステム設定のショートカット定義が上書きされます。
# 手動で再度有効にする場合は、キーの再割り当てが必要です。

# 標準のスクリーンショットショートカットを無効化 (Shottrなどの別アプリで設定するため)
# Save picture of screen as a file (⇧⌘3)
set_user_dict_entry com.apple.symbolichotkeys AppleSymbolicHotKeys 28 enabled 0 \
  '{ enabled = 0; }' system-ui
# Save picture of selected area as a file (⇧⌘4)
set_user_dict_entry com.apple.symbolichotkeys AppleSymbolicHotKeys 29 enabled 0 \
  '{ enabled = 0; }' system-ui
# Copy picture of screen to the clipboard (^⇧⌘3)
set_user_dict_entry com.apple.symbolichotkeys AppleSymbolicHotKeys 30 enabled 0 \
  '{ enabled = 0; }' system-ui
# Copy picture of selected area to the clipboard (^⇧⌘4)
set_user_dict_entry com.apple.symbolichotkeys AppleSymbolicHotKeys 31 enabled 0 \
  '{ enabled = 0; }' system-ui

# SpotlightのFinder検索ショートカット(⌥⌘Space)を無効化
# 65 = Show Finder search window
set_user_dict_entry com.apple.symbolichotkeys AppleSymbolicHotKeys 65 enabled 0 \
  '{ enabled = 0; }' system-ui

# Services Menuの不要な項目を無効化
# "Convert Text to Simplified Chinese" を無効化（Raycasetで設定するCursor用ハイパーキーとの競合回避）
set_user_dict_entry pbs NSServicesStatus \
  "com.apple.inputmethod.SCIM.ITService.TCSCTransformation" \
  enabled_services_menu 0 '{ enabled_services_menu = 0; }'

# --- ショートカットキーの変更 ---
# FinderとPreviewでタブ移動のショートカットキーを設定 (⌥⌘→, ⌥⌘←)
set_user_dict_entry com.apple.finder NSUserKeyEquivalents \
  "Show Next Tab" "" "@~\\U2192" "@~\\U2192" finder
set_user_dict_entry com.apple.finder NSUserKeyEquivalents \
  "Show Previous Tab" "" "@~\\U2190" "@~\\U2190" finder
set_user_dict_entry com.apple.Preview NSUserKeyEquivalents \
  "Show Next Tab" "" "@~\\U2192" "@~\\U2192"
set_user_dict_entry com.apple.Preview NSUserKeyEquivalents \
  "Show Previous Tab" "" "@~\\U2190" "@~\\U2190"

# Notionで「現在のページへのリンクをコピー」のショートカットを設定 (⌘⇧C)
set_user_dict_entry notion.id NSUserKeyEquivalents \
  "Copy Link to Current Page" "" "@\$c" "@\$c"

# PowerPointでオブジェクト整列メニューのショートカットを設定
# 対象: Arrange → Align or Distribute
# - Align Left:              ⌃⌥L
# - Align Center:            ⌃⌥C
# - Align Right:             ⌃⌥R
# - Align Top:               ⌃⌥T
# - Align Middle:            ⌃⌥M
# - Align Bottom:            ⌃⌥B
# - Distribute Horizontally: ⌃⌥H
# - Distribute Vertically:   ⌃⌥V
# 参考: メニュー階層を含めて指定することで、他の「Align Left」「Align Right」等との競合を防ぐ
if pgrep -x "Microsoft PowerPoint" >/dev/null 2>&1; then
  echo "[WARN] Skipped PowerPoint shortcut settings because PowerPoint is running."
  DEFAULTS_FAILURES=$((DEFAULTS_FAILURES + 1))
else
python3 - <<'PY'
import os
import plistlib
import shutil
import tempfile
from pathlib import Path
from xml.parsers.expat import ExpatError

domain = "com.microsoft.Powerpoint"
plist_path = Path.home() / "Library" / "Containers" / domain / "Data" / "Library" / "Preferences" / f"{domain}.plist"
try:
    plist_path.parent.mkdir(parents=True, exist_ok=True)

    data = {}
    if plist_path.exists():
        with plist_path.open("rb") as f:
            data = plistlib.load(f)

    equivs = data.get("NSUserKeyEquivalents")
    if not isinstance(equivs, dict):
        equivs = {}

    expected = {
        "Arrange->Align or Distribute->Align Left": "^~l",
        "Arrange->Align or Distribute->Align Center": "^~c",
        "Arrange->Align or Distribute->Align Right": "^~r",
        "Arrange->Align or Distribute->Align Top": "^~t",
        "Arrange->Align or Distribute->Align Middle": "^~m",
        "Arrange->Align or Distribute->Align Bottom": "^~b",
        "Arrange->Align or Distribute->Distribute Horizontally": "^~h",
        "Arrange->Align or Distribute->Distribute Vertically": "^~v",
    }
    if all(equivs.get(key) == value for key, value in expected.items()):
        print("[INFO] PowerPoint shortcut settings are already set.")
        raise SystemExit(0)

    equivs.update(expected)

    data["NSUserKeyEquivalents"] = equivs
    # Interrupted writes must not leave the preferences file truncated.
    fd, temporary_path = tempfile.mkstemp(dir=plist_path.parent, prefix=f".{plist_path.name}.")
    try:
        with os.fdopen(fd, "wb") as f:
            plistlib.dump(data, f)
            f.flush()
            os.fsync(f.fileno())
        if plist_path.exists():
            shutil.copystat(plist_path, temporary_path)
            os.utime(temporary_path, None)
        os.replace(temporary_path, plist_path)
    finally:
        if os.path.exists(temporary_path):
            os.unlink(temporary_path)
    print("[SUCCESS] Updated PowerPoint shortcut settings.")
    raise SystemExit(10)
except PermissionError:
    print(f"[WARN] Skipped PowerPoint shortcut settings (permission denied): {plist_path}")
    raise SystemExit(1)
except (plistlib.InvalidFileException, ExpatError) as error:
    print(f"[WARN] Skipped PowerPoint shortcut settings (invalid plist: {error}): {plist_path}")
    raise SystemExit(1)
PY
  powerpoint_status=$?
  if [ "$powerpoint_status" -eq 10 ]; then
    mark_changed
  elif [ "$powerpoint_status" -ne 0 ]; then
    DEFAULTS_FAILURES=$((DEFAULTS_FAILURES + 1))
  fi
fi

# --- 変更の反映 ---
if [ "$DOCK_CHANGED" -eq 1 ]; then
  killall Dock >/dev/null 2>&1 || true
fi
if [ "$FINDER_CHANGED" -eq 1 ]; then
  killall Finder >/dev/null 2>&1 || true
fi
if [ "$SYSTEM_UI_CHANGED" -eq 1 ]; then
  killall SystemUIServer >/dev/null 2>&1 || true
fi

if [ "$DEFAULTS_FAILURES" -gt 0 ]; then
  if [ "$DEFAULTS_CHANGED" -eq 1 ]; then
    echo "macOS defaults were updated, but some settings could not be applied."
  else
    echo "macOS defaults check completed, but some settings could not be applied."
  fi
  echo "[WARN] $DEFAULTS_FAILURES default setting(s) could not be applied."
  exit 1
elif [ "$DEFAULTS_CHANGED" -eq 0 ]; then
  echo "macOS defaults are already up to date."
else
  echo "macOS defaults have been updated. Some changes may require a restart to take effect."
fi
