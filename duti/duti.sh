#!/bin/bash

# コマンドが失敗した場合、即座にスクリプトを終了する
set -euo pipefail

# duti を使ってファイルのデフォルトアプリケーションを設定するスクリプト
# duti_settings.yml ファイルに定義されたリストを元に設定を行います。

# --- 設定 ---
# スクリプトと同じディレクトリにあるduti_settings.ymlを指すように設定
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
SETTINGS_FILE="$SCRIPT_DIR/duti_settings.yml"

# --- 事前チェック ---

# Homebrewの存在チェック
if ! command -v brew &> /dev/null; then
  echo "エラー: Homebrewがインストールされていません。先にHomebrewをインストールしてください。"
  exit 1
fi

# dutiの存在チェックとインストール
if ! command -v duti &> /dev/null; then
  echo "dutiが見つかりません。Homebrew経由でインストールを試みます..."
  if ! brew install duti; then
      echo "dutiのインストールに失敗しました。手動でインストールしてから再度スクリプトを実行してください。"
      exit 1
  fi
fi

# yqの存在チェックとインストール
if ! command -v yq &> /dev/null; then
  echo "yq (YAMLプロセッサ)が見つかりません。Homebrew経由でインストールを試みます..."
  if ! brew install yq; then
      echo "yqのインストールに失敗しました。手動でインストールしてから再度スクリプトを実行してください。"
      exit 1
  fi
fi

# 設定ファイルの存在チェック
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "エラー: 設定ファイルが見つかりません: $SETTINGS_FILE"
    exit 1
fi

# --- メイン処理 ---

echo "--- dutiによるデフォルトアプリケーションの設定を開始します ---"

# yqを使ってYAMLファイルをパースし、各アプリケーション設定をループ処理
num_apps=$(yq e 'length' "$SETTINGS_FILE")

for i in $(seq 0 $((num_apps - 1))); do
    bundle_id=$(yq e ".[$i].bundle_id" "$SETTINGS_FILE")
    extensions=$(yq e ".[$i].extensions[]" "$SETTINGS_FILE")

    if [ -z "$bundle_id" ] || [ "$bundle_id" = "null" ] || [ -z "$extensions" ] || [ "$extensions" = "null" ]; then
        echo "警告: エントリ $i の情報が不完全なためスキップします。"
        continue
    fi

    echo "アプリケーション '$bundle_id' の設定中..."

    echo "$extensions" | while IFS= read -r ext; do
        if [ -z "$ext" ]; then continue; fi
        echo "  - 拡張子 '$ext' を関連付け"
        duti -s "$bundle_id" "$ext" all
    done
done

echo "--- デフォルトアプリケーションの設定が正常に完了しました！ ---"
