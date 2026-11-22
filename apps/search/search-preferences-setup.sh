#!/usr/bin/env bash
# Search Browserの利用者設定だけを管理する。振り分けルールはsearch-routes-setup.pyが担当。
set -euo pipefail

DOMAIN="com.officecommun.search"
MODE="apply"

if [[ $# -gt 1 || ( $# -eq 1 && $1 != "--check" ) ]]; then
  echo "Usage: $0 [--check]" >&2
  exit 2
fi
if [[ ${1:-} == "--check" ]]; then MODE="check"; fi
if [[ $(uname -s) != Darwin ]]; then
  echo "[ERROR] macOS専用のスクリプトです" >&2
  exit 1
fi
if [[ $MODE == apply ]] && pgrep -x Search >/dev/null 2>&1; then
  echo "[ERROR] Searchを完全終了してから実行してください" >&2
  exit 1
fi

CHANGED=0
set_pref() {
  local key="$1" kind="$2" expected="$3" flag type_name current_type current
  case "$kind" in
    bool) flag="-bool"; type_name="boolean" ;;
    int) flag="-int"; type_name="integer" ;;
    float) flag="-float"; type_name="float" ;;
    string) flag="-string"; type_name="string" ;;
    *) echo "[ERROR] 未対応の型: $kind" >&2; exit 2 ;;
  esac
  current_type=$(defaults read-type "$DOMAIN" "$key" 2>/dev/null || true)
  current=$(defaults read "$DOMAIN" "$key" 2>/dev/null || true)
  if [[ $kind == bool ]]; then
    case "$current" in
      1|true|TRUE|YES|yes) current="true" ;;
      0|false|FALSE|NO|no) current="false" ;;
    esac
  fi
  if [[ "$current_type" == "Type is $type_name" && "$current" == "$expected" ]]; then
    return
  fi
  CHANGED=$((CHANGED + 1))
  if [[ $MODE == check ]]; then
    printf '[CHECK] %s: %s → %s\n' "$key" "${current:-<未設定>}" "$expected"
    return
  fi
  defaults write "$DOMAIN" "$key" "$flag" "$expected"
  local verified_type verified
  verified_type=$(defaults read-type "$DOMAIN" "$key" 2>/dev/null || true)
  verified=$(defaults read "$DOMAIN" "$key" 2>/dev/null || true)
  if [[ $kind == bool ]]; then
    case "$verified" in
      1|true|TRUE|YES|yes) verified="true" ;;
      0|false|FALSE|NO|no) verified="false" ;;
    esac
  fi
  if [[ "$verified_type" != "Type is $type_name" || "$verified" != "$expected" ]]; then
    echo "[ERROR] 設定の書込検証に失敗しました: $key" >&2
    exit 1
  fi
  printf '[SET] %s = %s\n' "$key" "$expected"
}

# 外観
set_pref glyph string icons
set_pref layout.cards bool true
set_pref window.glass bool true
set_pref address.shown bool false
set_pref motion.light bool true

# サイドバー
set_pref sidebar bool true
set_pref sidebar.position string left
set_pref sidebar.width float 176
set_pref sidebar.doorsUp bool false
set_pref sidebar.foldIcons bool false
set_pref sidebar.hides bool false
set_pref sidebar.icons bool false
set_pref sidebar.player bool true
set_pref sidebar.roomy bool false
set_pref sidebar.slides bool false

# タブ
set_pref tabs.close.after int 12
set_pref tabs.give bool false
set_pref tabs.reading bool true
set_pref tabs.shortcuts bool true
set_pref tabs.sleep.dim bool false

# スペース・プロファイル（スペースのルールとUUIDはここでは管理しない）
set_pref spaces bool true
set_pref profiles.oneWindow bool true
set_pref pins.folders bool true
set_pref pins.list bool true

# 外部リンク
set_pref links.ask bool true
set_pref links.little bool true
set_pref links.little.tabs bool true

# ブックマーク・検索
set_pref bookmarks.bar bool false
set_pref search.suggest bool true

# 閲覧・翻訳
set_pref reader.follows bool true
set_pref reader.twins bool true
set_pref sites.styles bool false
set_pref translate.target string ja

# メール・ダウンロード
set_pref mail.webmail string gmail
set_pref downloads.button bool false

# パスワード・フォーム。OS側の権限・署名要件はこの設定とは別。
set_pref passwords.apple bool false
set_pref passkeys bool true
set_pref contacts.fill bool true

if [[ $MODE == check ]]; then
  printf '[CHECK] 相違する設定: %d 件（変更なし）\n' "$CHANGED"
else
  printf '[OK] Searchの利用者設定を適用しました（変更: %d 件）\n' "$CHANGED"
fi
