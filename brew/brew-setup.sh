#!/bin/bash

# HomebrewとMac App Store経由でアプリをインストールするスクリプト
# packages.yml ファイルに定義されたリストを元にインストールを行います。

# 共通ライブラリを読み込み
source "$(dirname "$0")/../lib/common.sh"

# --- Configuration ---
# スクリプトと同じディレクトリにあるpackages.ymlを指すように変更
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PACKAGE_FILE="$SCRIPT_DIR/packages.yml"

# --- Argument Parsing ---
INSTALL_PERSONAL=false
INSTALL_BUSINESS=false

for arg in "$@"
do
    case $arg in
        --personal)
        INSTALL_PERSONAL=true
        shift
        ;;
        --business)
        INSTALL_BUSINESS=true
        shift
        ;;
    esac
done

# --- Homebrew Install ---
log_info "Homebrewのインストール状態を確認中..."
if ! command -v brew &> /dev/null; then
  log_info "Homebrewが見つかりません。インストールを開始します..."
  # Run in non-interactive mode
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  log_success "Homebrewのインストールが完了しました"
else
  log_success "Homebrewは既にインストールされています"
fi

# --- Set Homebrew PATH (for Apple Silicon) ---
log_info "シェルでHomebrewを使用するように設定中..."

# Add Homebrew to PATH in .zprofile if not already there
# On Apple Silicon, the path is /opt/homebrew
if ! grep -q 'eval "$(/opt/homebrew/bin/brew shellenv)"' ~/.zprofile 2>/dev/null; then
  log_info "~/.zprofileにHomebrewのPATHを追加中..."
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
  log_success "~/.zprofileにHomebrewのPATHを追加しました"
else
  log_info "~/.zprofileには既にHomebrewのPATHが設定されています"
fi

# Add Homebrew to the current shell session's PATH
eval "$(/opt/homebrew/bin/brew shellenv)"

log_info "Homebrewを更新中..."
brew update
log_success "Homebrewの更新が完了しました"

# --- Prerequisite Check (yq) ---
log_info "yq (YAML processor) の確認中..."
if ! command -v yq &> /dev/null; then
  log_info "yqが見つかりません。Homebrewでインストールを試行中..."
  if ! brew install yq; then
      log_error "yqのインストールに失敗しました。手動でインストールしてから再実行してください"
      exit 1
  fi
  log_success "yqのインストールが完了しました"
else
  log_success "yqは既にインストールされています"
fi

# パッケージ定義ファイルの存在確認
check_path "$PACKAGE_FILE" "パッケージ定義ファイル" "file" || exit 1

# --- Function Definitions ---

# Installs Homebrew formulae/casks.
# $1: Type argument for brew command ("" for formula, "--cask" for cask)
# $2: yq query to get the list of packages
# $3: Label for logging (e.g., "Formula", "Cask")
install_brew_packages() {
	local type_arg=$1
	local yaml_query=$2
	local package_label=$3

	log_info "--- ${package_label}の確認・インストール中 ---"

	# yqでパッケージリストを取得。リストが存在しない/空の場合は何もしない
	local packages
	packages=$(get_yaml_value "$PACKAGE_FILE" "$yaml_query")
	if [ -z "$packages" ] || [ "$packages" = "null" ]; then
		log_info "インストール対象の${package_label}はありません"
		return
	fi

	echo "$packages" | while IFS= read -r package; do
		# Skip empty lines that might result from yq output
		if [ -z "$package" ]; then continue; fi

		# Build arguments for brew command to handle optional type_arg correctly.
		# This prevents passing an empty argument for formulae.
		local brew_args=()
		if [ -n "$type_arg" ]; then
			brew_args+=("$type_arg")
		fi
		brew_args+=("$package")

		if brew list "${brew_args[@]}" &>/dev/null; then
			log_success "${package_label} '$package' は既にインストールされています。スキップします"
		else
			log_info "${package_label} '$package' をインストール中..."
			brew install "${brew_args[@]}"
		fi
	done
}

# Installs Mac App Store apps.
# $1: yq query to get the list of apps
# $2: Label for logging (e.g., "Common App", "Personal App")
install_mas_packages() {
	local yaml_query=$1
	local package_label=$2

	log_info "--- ${package_label}の確認・インストール中 ---"

	# yqでアプリリストをTSV形式（ID, Name）で取得。リストが存在しない/空の場合は何もしない
	# 各要素からidとnameをタブ区切りで出力
	local apps_tsv
	apps_tsv=$(get_yaml_value "$PACKAGE_FILE" "($yaml_query) | [.id, .name] | @tsv")
	if [ -z "$apps_tsv" ] || [ "$apps_tsv" = "null" ]; then
		log_info "インストール対象の${package_label}はありません"
		return
	fi

	# `mas list`の結果を一度だけ取得して高速化
	local installed_apps
	installed_apps=$(mas list)

	# yqから受け取ったTSVリストをループ処理
	echo "$apps_tsv" | while IFS=$'\t' read -r app_id app_name; do
		# Skip empty lines
		if [ -z "$app_id" ]; then continue; fi

		if echo "$installed_apps" | grep -q "^$app_id "; then
			log_success "${package_label} '$app_name' (ID: $app_id) は既にインストールされています。スキップします"
		else
			log_info "${package_label} '$app_name' (ID: $app_id) をインストール中..."
			mas install "$app_id"
		fi
	done
}

# --- Main Installation Logic ---

log_header "Homebrew経由でのインストールを開始します"

# Install common formulae and casks (always run)
install_brew_packages "" '.formulae[]' "Formula"
install_brew_packages "--cask" '.casks.common[]' "Common Cask"
install_mas_packages '.mas.common[]' "Common App"

# Install personal packages if requested
if [ "$INSTALL_PERSONAL" = true ]; then
    log_info "個人用パッケージのインストールを開始します"
    install_brew_packages "--cask" '.casks.personal[]' "Personal Cask"
    install_mas_packages '.mas.personal[]' "Personal App"
fi

# Install business packages if requested
if [ "$INSTALL_BUSINESS" = true ]; then
    log_info "ビジネス用パッケージのインストールを開始します"
    install_brew_packages "--cask" '.casks.business[]' "Business Cask"
    install_mas_packages '.mas.business[]' "Business App"
fi

log_success "Homebrewセットアップが完了しました！"
