# --- Language & Region ---
# システム言語を英語と日本語に設定（英語を優先）
defaults write NSGlobalDomain AppleLanguages -array en ja
# ロケール：システム言語は英語、地域は日本
defaults write NSGlobalDomain AppleLocale "en_JP"
# 月曜日始まり
defaults write NSGlobalDomain AppleFirstWeekday -int 2
# 単位系：センチメートル
defaults write NSGlobalDomain AppleMeasurementUnits "Centimeters"
# メートル法
defaults write NSGlobalDomain AppleMetricUnits -bool YES
# 摂氏
defaults write NSGlobalDomain AppleTemperatureUnit "Celsius"
# 日付表示
defaults write NSGlobalDomain AppleDateFormat -string "yyyy/MM/dd"

# --- System ---
# 保存時のファイル選択ダイアログパネルをデフォルトで拡げた状態にする
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true

# --- Software Update ---
# 注意: 以下のコマンドはsudo権限が必要な場合があります
# macOSアップデートを自動的にチェック
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
# アプリケーションアップデートを7日ごとに自動的にチェック
# ※この設定はユーザー単位でも有効ですが、システム全体に統一することで一貫性を保ちます
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate ScheduleFrequency -string 7
# アプリケーションアップデートを自動的にダウンロード
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool true
# アプリケーションアップデートを自動的にインストール（セキュリティアップデートなど）
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
# macOSアップデートを自動的にインストール
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool true
# App Storeからのアプリケーションアップデートを自動的にインストール
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool true
# App StoreからのOSアップデートを自動的に再起動
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdateRestartRequired -bool true

# ====== 入力系 ======
# --- トラックパッド ---
# トラックパッドのタップでクリックを有効化
defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
defaults write NSGlobalDomain com.apple.mouse.tapBehavior -int 1

# --- キーボード ---
# すべてのコントロールでフルキーボードアクセスを有効化（例: モーダルダイアログでのタブ操作）
defaults write NSGlobalDomain AppleKeyboardUIMode -int 3
# Fnキーを標準のファンクションキーとして使用
defaults write NSGlobalDomain com.apple.keyboard.fnState -bool true
# ダブルスペースでピリオドを入力する機能を無効化
defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false

# ====== 出力系 ======
# --- 画面 ---
# フォントの表示がLCD向けに最適化された、中程度のアンチエイリアスに変更（Retinaの場合は削除推奨）
defaults write NSGlobalDomain AppleFontSmoothing -int 2

# --- Bluetooth Audio ---
# Bluetoothヘッドフォン・ヘッドセットの音質を向上
defaults write com.apple.BluetoothAudioAgent "Apple Bitpool Min (editable)" -int 40

# ====== UI ======
# --- Dock ---
# Dockの自動表示/非表示機能を有効化
defaults write com.apple.dock autohide -bool true
# ホットコーナーを無効化
defaults write com.apple.dock wvous-tl-corner -int 0
defaults write com.apple.dock wvous-tr-corner -int 0
defaults write com.apple.dock wvous-bl-corner -int 0
defaults write com.apple.dock wvous-br-corner -int 0

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
# 新規Finderウィンドウの表示先をDownloadsフォルダに設定
defaults write com.apple.finder NewWindowTarget -string "PfLo"
defaults write com.apple.finder NewWindowTargetPath -string "file://${HOME}/Downloads"

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
defaults write NSGlobalDomain AppleWindowTabbingMode -string "always"
# ウインドウを画面上部にドラッグしてフルスクリーンにする機能を無効化
defaults write com.apple.WindowManager dragToFullScreenEnabled -bool false

# --- Quicklook ---
# QuickLookでテキストを選択可能にする
defaults write com.apple.finder QLEnableTextSelection -bool true

# --- Accessibility ---
# ズーム機能のキーボードショートカットを有効化
defaults write com.apple.universalaccess closeViewHotkeysEnabled -bool true

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

# --- 変更の反映 ---
killall Dock
killall Finder
killall SystemUIServer

echo "macOS defaults have been set. Some changes may require a restart to take effect."
