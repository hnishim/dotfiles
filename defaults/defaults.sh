# --- 言語設定 ---
# システム言語を英語と日本語に設定（英語を優先）
defaults write -g AppleLanguages -array en ja

# --- Dock ---
# Dockの自動表示/非表示機能を有効化
defaults write com.apple.dock autohide -bool true
# ホットコーナーを無効化
defaults write com.apple.dock wvous-tl-corner -int 1 && defaults write com.apple.dock wvous-tl-modifier -int 0
defaults write com.apple.dock wvous-tr-corner -int 1 && defaults write com.apple.dock wvous-tr-modifier -int 0
defaults write com.apple.dock wvous-bl-corner -int 1 && defaults write com.apple.dock wvous-bl-modifier -int 0
defaults write com.apple.dock wvous-br-corner -int 1 && defaults write com.apple.dock wvous-br-modifier -int 0

# --- Finder ---
# ファイルの拡張子を常に表示
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
# Finderウィンドウのタイトルバーにフルパスを表示
defaults write com.apple.finder _FXShowPosixPathInTitle -bool true
# 隠しファイルを常に表示
defaults write com.apple.Finder AppleShowAllFiles -bool true
# Finderウィンドウ下部のパスバーを表示
defaults write com.apple.finder ShowPathbar -bool true
# Finderにタブバーを表示
defaults write com.apple.finder ShowTabView -bool true
# 未確認のアプリケーションを開く際の警告を無効化
defaults write com.apple.LaunchServices LSQuarantine -bool false
# デスクトップにアイコンを表示しない
defaults write com.apple.finder CreateDesktop -bool false
# ネットワークドライブやUSBドライブに.DS_Storeファイルを作成しない
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true
# Finderを⌘ + Qで終了できるようにする
defaults write com.apple.finder QuitMenuItem -bool true
# 名前順でソートする際に、フォルダをファイルの前に表示
defaults write com.apple.finder _FXSortFoldersFirst -bool true
# ディスクイメージの検証を無効化
defaults write com.apple.frameworks.diskimages skip-verify -bool true
defaults write com.apple.frameworks.diskimages skip-verify-locked -bool true
defaults write com.apple.frameworks.diskimages skip-verify-remote -bool true
# Finderのデフォルト表示形式をカラムビューに設定
# 他の表示形式のコード: `icnv` (アイコン), `clmv` (カラム), `glyv` (ギャラリー)
defaults write com.apple.finder FXPreferredViewStyle -string "Clmv"
# Finderのデフォルト検索範囲を現在のフォルダに設定
defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"

# --- メニューバー ---
# メニューバーにバッテリー残量をパーセンテージで表示 (macOS 11 Big Sur以降)
defaults write com.apple.controlcenter "BatteryShowPercentage" -bool true
# メニューバーの時計のフォーマットを設定 (24時間表示、曜日、日付)
defaults write com.apple.menuextra.clock Show24Hour -bool true
defaults write com.apple.menuextra.clock ShowDayOfWeek -bool true
defaults write com.apple.menuextra.clock ShowDate -int 2
defaults write com.apple.menuextra.clock FlashDateSeparators -bool false
# メニューバーから不要なアイコンを非表示にする
# 24 = Don't Show in Menu Bar
defaults write com.apple.controlcenter "Spotlight" -int 24
defaults write com.apple.controlcenter "Siri" -int 24
defaults write com.apple.controlcenter "TimeMachine" -int 24
defaults write com.apple.controlcenter "Weather" -int 24

# --- Desktop & Window ---
# 書類を開くときにタブで開くようにする
defaults write -g AppleWindowTabbingMode -string "always"
# ウインドウを画面上部にドラッグしてフルスクリーンにする機能を無効化
defaults write com.apple.WindowManager dragToFullScreenEnabled -bool false

# --- トラックパッド ---
# トラックパッドのタップでクリックを有効化
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
defaults write NSGlobalDomain com.apple.mouse.tapBehavior -int 1

# --- Quicklook ---
# QuickLookでテキストを選択可能にする
defaults write com.apple.finder QLEnableTextSelection -bool true

# --- Bluetooth Audio ---
# Bluetoothヘッドフォン・ヘッドセットの音質を向上
defaults write com.apple.BluetoothAudioAgent "Apple Bitpool Min (editable)" -int 40

# --- Keyboard ---
# すべてのコントロールでフルキーボードアクセスを有効化（例: モーダルダイアログでのタブ操作）
defaults write NSGlobalDomain AppleKeyboardUIMode -int 3
# Fnキーを標準のファンクションキーとして使用
defaults write -g com.apple.keyboard.fnState -bool true
# ダブルスペースでピリオドを入力する機能を無効化
defaults write -g NSAutomaticPeriodSubstitutionEnabled -bool false

# --- 日本語入力（Mac標準） ---
# かわせみを使用する場合には特に不要な設定
# Windows風のキー操作を有効化
defaults write com.apple.inputmethod.Kotoeri 'JIMPrefWindowsLikeShortcut' -bool true
# 全角数字の使用を無効化
defaults write com.apple.inputmethod.Kotoeri 'JIMPrefFullWidthNumeralCharacters' -bool false

# --- 不要・競合するショートカットを無効化 ---
# 注意: これによりシステム設定のショートカット定義が上書きされます。
# 手動で再度有効にする場合は、キーの再割り当てが必要です。

# 標準のスクリーンショットショートカットを無効化 (Shottrなどの別アプリで設定するため)
# Save picture of screen as a file (⇧⌘3)
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 28 '{ enabled = 0; }'
# Save picture of selected area as a file (⇧⌘4)
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 29 '{ enabled = 0; }'
# Copy picture of screen to the clipboard (^⇧⌘3)
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 30 '{ enabled = 0; }'
# Copy picture of selected area to the clipboard (^⇧⌘4)
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 31 '{ enabled = 0; }'

# SpotlightのFinder検索ショートカット(⌥⌘Space)を無効化
# 65 = Show Finder search window
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 65 '{ enabled = 0; }'

# Services Menuの不要な項目を無効化
# "Convert Text to Simplified Chinese" を無効化（Raycasetで設定するCursor用ハイパーキーとの競合回避）
defaults write pbs NSServicesStatus -dict-add "com.apple.inputmethod.SCIM.ITService.TCSCTransformation" '{ enabled_services_menu = 0; }'

# --- ショートカットキーの変更 ---
# FinderとPreviewでタブ移動のショートカットキーを設定 (⌥⌘→, ⌥⌘←)
defaults write com.apple.finder NSUserKeyEquivalents -dict-add "Show Next Tab" "@~\\U2192"
defaults write com.apple.finder NSUserKeyEquivalents -dict-add "Show Previous Tab" "@~\\U2190"
defaults write com.apple.Preview NSUserKeyEquivalents -dict-add "Show Next Tab" "@~\\U2192"
defaults write com.apple.Preview NSUserKeyEquivalents -dict-add "Show Previous Tab" "@~\\U2190"

# Notionで「現在のページへのリンクをコピー」のショートカットを設定 (⌘⇧C)
defaults write notion.id NSUserKeyEquivalents -dict-add "Copy Link to Current Page" "@\$c"

# --- Software Update ---
# 注意: 以下のコマンドはsudo権限が必要な場合があります
# macOSアップデートを自動的にインストール
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool true
# App Storeからのアプリケーションアップデートを自動的にインストール
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool true

# --- 変更の反映 ---
killall Dock
killall Finder
killall SystemUIServer

echo "macOS defaults have been set. Some changes may require a restart to take effect."
