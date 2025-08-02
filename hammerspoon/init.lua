-- 設定いじったら自動でリロード
hs.loadSpoon("ReloadConfiguration")
spoon.ReloadConfiguration:start()

-- window-manager.luaの読み込み
local window_management = require("_window-manager")

-- ウィンドウ移動
local cmd_ctrl = {"command", "control"}
hs.hotkey.bind(cmd_ctrl, "h", window_management.moveWindowLeft)
hs.hotkey.bind(cmd_ctrl, "l", window_management.moveWindowRight)
hs.hotkey.bind(cmd_ctrl, "j", window_management.moveWindowDown)
hs.hotkey.bind(cmd_ctrl, "k", window_management.moveWindowUp)
hs.hotkey.bind(cmd_ctrl, "f", window_management.maximizeWindow)
hs.hotkey.bind(cmd_ctrl, "c", window_management.centerWindow)

-- Apple Music
hs.hotkey.bind({"option"}, "space", function()
    hs.itunes.playpause()
end)

-- 英かな
local eikana = require("_eikana")
eikana.start()