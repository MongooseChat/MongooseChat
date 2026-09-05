-- MongooseChat-owned overlay emergency close dispatcher.
-- Pages opt in with their own liveness and close semantics. This observer
-- never consumes Melee; the game's shove handlers keep receiving the event.
local MC_PageClose = {}

local stack = {}
local attached = false
local onKeyStartPressed

local function eventSeam()
    return Events and Events.OnKeyStartPressed or nil
end

local function detachIfIdle()
    if #stack ~= 0 or not attached then return end
    local event = eventSeam()
    if event and type(event.Remove) == "function" then
        pcall(event.Remove, onKeyStartPressed)
    end
    attached = false
end

local function attachIfNeeded()
    if attached or #stack == 0 then return attached end
    local event = eventSeam()
    if not event or type(event.Add) ~= "function" then return false end
    local ok = pcall(event.Add, onKeyStartPressed)
    attached = ok
    return ok
end

local function removeRoot(root)
    for i = #stack, 1, -1 do
        if stack[i].root == root then table.remove(stack, i) end
    end
end

function MC_PageClose.register(root, spec)
    if root == nil or type(spec) ~= "table"
        or type(spec.close) ~= "function" or type(spec.live) ~= "function" then
        return false
    end
    removeRoot(root)
    stack[#stack + 1] = {
        root = root,
        close = spec.close,
        live = spec.live,
    }
    attachIfNeeded()
    return true
end

function MC_PageClose.unregister(root)
    if root == nil then return false end
    local before = #stack
    removeRoot(root)
    detachIfIdle()
    return #stack ~= before
end

local function chatFocused()
    if ISChat and ISChat.focused == true then return true end
    local loaded = package and package.loaded and package.loaded.MC_ChatWindow
    local win = type(loaded) == "table" and loaded.instance or nil
    if not win or not win.entry then return false end
    local ok, focused = pcall(function()
        if type(win.isInputFocused) == "function" then
            return win:isInputFocused()
        end
        if type(win.entry.isFocused) == "function" then
            return win.entry:isFocused()
        end
        return false
    end)
    -- An owned entry whose focus state cannot be read is not safe to type over.
    return not ok or focused == true
end

local function meleeMatches(key)
    local ok, matched = pcall(function()
        local core = getCore()
        if not core or type(core.isKey) ~= "function" then return false end
        return core:isKey("Melee", key) == true
    end)
    return ok and matched == true
end

onKeyStartPressed = function(key)
    if chatFocused() or not meleeMatches(key) then return end
    while #stack > 0 do
        local entry = stack[#stack]
        table.remove(stack)
        local liveOK, live = pcall(entry.live, entry.root)
        if liveOK and live == true then
            pcall(entry.close, entry.root)
        end
    end
    detachIfIdle()
end

return MC_PageClose
