#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -euo pipefail

# HomebrewとMac App Store経由でアプリをインストールするスクリプト
# packages.yml ファイルに定義されたリストを元にインストールを行います。

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
if ! command -v brew &> /dev/null; then
  echo "Homebrew not found. Installing Homebrew..."
  # Run in non-interactive mode
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
  echo "Homebrew is already installed."
fi

# --- Set Homebrew PATH (for Apple Silicon) ---
echo "Configuring shell to use Homebrew..."

# Add Homebrew to PATH in .zprofile if not already there
# On Apple Silicon, the path is /opt/homebrew
if ! grep -q 'eval "$(/opt/homebrew/bin/brew shellenv)"' ~/.zprofile 2>/dev/null; then
  echo "Adding Homebrew to your PATH in ~/.zprofile..."
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
fi

# Add Homebrew to the current shell session's PATH
eval "$(/opt/homebrew/bin/brew shellenv)"

echo "Updating Homebrew..."
brew update

# --- Prerequisite Check (yq) ---
if ! command -v yq &> /dev/null; then
  echo "yq (YAML processor) not found. Attempting to install via Homebrew..."
  if ! brew install yq; then
      echo "Failed to install yq. Please install it manually and run this script again."
      exit 1
  fi
fi

if [ ! -f "$PACKAGE_FILE" ]; then
    echo "Error: Package definition file not found: $PACKAGE_FILE"
    exit 1
fi

# --- Function Definitions ---

# Installs Homebrew formulae/casks.
# $1: Type argument for brew command ("" for formula, "--cask" for cask)
# $2: yq query to get the list of packages
# $3: Label for logging (e.g., "Formula", "Cask")
install_brew_packages() {
	local type_arg=$1
	local yaml_query=$2
	local package_label=$3

	echo "--- Checking and installing ${package_label}s ---"

	# yqでパッケージリストを取得。リストが存在しない/空の場合は何もしない
	local packages
	packages=$(yq e "$yaml_query" "$PACKAGE_FILE")
	if [ -z "$packages" ] || [ "$packages" = "null" ]; then
		echo "No ${package_label}s to install."
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
			echo "${package_label} '$package' is already installed. Skipping."
		else
			echo "Installing ${package_label} '$package'..."
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

	echo "--- Checking and installing ${package_label}s ---"

	# yqでアプリリストをTSV形式（ID, Name）で取得。リストが存在しない/空の場合は何もしない
	# 各要素からidとnameをタブ区切りで出力
	local apps_tsv
	apps_tsv=$(yq e "($yaml_query) | [.id, .name] | @tsv" "$PACKAGE_FILE")
	if [ -z "$apps_tsv" ] || [ "$apps_tsv" = "null" ]; then
		echo "No ${package_label}s to install."
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
			echo "${package_label} '$app_name' (ID: $app_id) is already installed. Skipping."
		else
			echo "Installing ${package_label} '$app_name' (ID: $app_id)..."
			mas install "$app_id"
		fi
	done
}

# --- Main Installation Logic ---

echo "Starting installs via Homebrew..."

# Install common formulae and casks (always run)
install_brew_packages "" '.formulae[]' "Formula"
install_brew_packages "--cask" '.casks.common[]' "Common Cask"
install_mas_packages '.mas.common[]' "Common App"

# Install personal packages if requested
if [ "$INSTALL_PERSONAL" = true ]; then
    install_brew_packages "--cask" '.casks.personal[]' "Personal Cask"
    install_mas_packages '.mas.personal[]' "Personal App"
fi

# Install business packages if requested
if [ "$INSTALL_BUSINESS" = true ]; then
    install_brew_packages "--cask" '.casks.business[]' "Business Cask"
    install_mas_packages '.mas.business[]' "Business App"
fi

echo "Setup complete!"
