-- 左commandキーtapで「英数」、右commandキーtapで「かな」
local eikana = {}

local keycodes = hs.keycodes.map
local eventTypes = hs.eventtap.event.types
local keyStroke = hs.eventtap.keyStroke
local isCmdAsModifier = false
local eventTap = nil -- eventtapオブジェクトを保持する

local function switchInputSourceEvent(event)
    local eventType = event:getType()
    local keyCode = event:getKeyCode()
    local flags = event:getFlags()
    local isCmd = flags.cmd

    if eventType == eventTypes.keyDown then
        if isCmd then
            isCmdAsModifier = true
        end
    elseif eventType == eventTypes.flagsChanged then
        if not isCmd then
            if not isCmdAsModifier then
                if keyCode == keycodes['cmd'] then
                    keyStroke({}, 0x66, 0) -- 英数キー
                elseif keyCode == keycodes['rightcmd'] then
                    keyStroke({}, 0x68, 0) -- かなキー
                end
            end
            isCmdAsModifier = false -- 状態をリセット
        end
    end
end

function eikana.start()
    -- 既に開始済みの場合は何もしない (リロード時の重複起動を防止)
    if eventTap then return end

    eventTap = hs.eventtap.new({ eventTypes.keyDown, eventTypes.flagsChanged }, switchInputSourceEvent)
    eventTap:start()
end

return eikana
