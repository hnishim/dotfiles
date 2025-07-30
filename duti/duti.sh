#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -euo pipefail

# Sets default applications using duti.
# It processes a settings file in the format recommended by the official duti documentation.

# --- Configuration ---
# Point to the settings file in the same directory as the script.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
SETTINGS_FILE="$SCRIPT_DIR/duti_settings.duti"

# --- 事前チェック ---

# Homebrewの存在チェック
if ! command -v brew &> /dev/null; then
  echo "エラー: Homebrewがインストールされていません。先にHomebrewをインストールしてください。"
  exit 1
fi

# dutiの存在チェックとインストール
if ! command -v duti &> /dev/null; then
  echo "duti not found. Attempting to install via Homebrew..."
  if ! brew install duti; then
      echo "Failed to install duti. Please install it manually and run this script again."
      exit 1
  fi
fi

# 設定ファイルの存在チェック
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "Error: Settings file not found: $SETTINGS_FILE"
    exit 1
fi

# --- メイン処理 ---

echo "--- Setting default applications using duti ---"
echo "Processing settings from: $SETTINGS_FILE"

duti "$SETTINGS_FILE"

echo "--- Default application settings have been successfully applied! ---"
