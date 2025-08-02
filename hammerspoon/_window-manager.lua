-- ウィンドウサイズ・位置を制御
local window_management = {}

-- フォーカスされているウィンドウを取得する処理の繰り返しを避けるためのヘルパー関数
local function applyToFocusedWindow(fn)
    return function()
        local win = hs.window.focusedWindow()
        if win then
            fn(win)
        end
    end
end

-- ウィンドウを画面の左半分に移動
window_management.moveWindowLeft = applyToFocusedWindow(function(win)
    win:moveToUnit(hs.layout.left50)
end)

-- ウィンドウを画面の右半分に移動
window_management.moveWindowRight = applyToFocusedWindow(function(win)
    win:moveToUnit(hs.layout.right50)
end)

-- ウィンドウを画面の下半分に移動
window_management.moveWindowDown = applyToFocusedWindow(function(win)
    win:moveToUnit({x = 0.0, y = 0.5, w = 1.0, h = 0.5})
end)

-- ウィンドウを画面の上半分に移動
window_management.moveWindowUp = applyToFocusedWindow(function(win)
    win:moveToUnit({x = 0.0, y = 0.0, w = 1.0, h = 0.5})
end)

-- ウィンドウを最大化
window_management.maximizeWindow = applyToFocusedWindow(function(win)
    win:maximize()
end)

-- ウィンドウを中央に配置（幅50%）
window_management.centerWindow = applyToFocusedWindow(function(win)
    win:moveToUnit({x = 0.25, y = 0, w = 0.5, h = 1.0})
end)

return window_management
