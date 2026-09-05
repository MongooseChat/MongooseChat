--[[
================================================================================
    MongooseChat - Key Bindings

    Adds a [MongooseChat] section to the game's own Key Bindings screen.
    Every key here is rebindable there, read at runtime with
    getCore():getKey(name). Nothing in MongooseChat needs a chord or a
    held key; each of these is a single press.

    All default to unbound. The game's own "Toggle chat" key already
    opens MongooseChat; the entries here are extras a player may choose.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_KeyBindings = {}

-- These stable names are stored in keysB42.ini.  The English UI string file
-- holds the short words shown on screen; changing the stored names would
-- silently discard a player's chosen keys.
MC_KeyBindings.NAMES = {
    TOGGLE      = "MongooseChat: open chat",
    NEXT_TAB    = "MongooseChat: next tab",
    PREV_TAB    = "MongooseChat: previous tab",
    LOCK        = "MongooseChat: lock window",
    TEXT_BIGGER = "MongooseChat: text bigger",
    TEXT_SMALLER = "MongooseChat: text smaller",
}

local function addBind(name, key)
    local bind = {}
    bind.value = name
    bind.key = key
    table.insert(keyBinding, bind)
end

-- keyBinding is the game's global list (shared/keyBinding.lua). Absent in
-- the offline suite and on a dedicated server: then there is nothing to
-- register and every getKey read returns nil, which callers treat as
-- "unbound".
if type(keyBinding) == "table" and type(Keyboard) == "table" then
    local none = Keyboard.KEY_NONE or 0
    local section = {}
    section.value = "[MongooseChat]"
    table.insert(keyBinding, section)

    -- Unbound: the game's own "Toggle chat" key already opens MongooseChat.
    -- This one is for a player who wants a second, different key.
    addBind(MC_KeyBindings.NAMES.TOGGLE,       none)
    addBind(MC_KeyBindings.NAMES.NEXT_TAB,     none)
    addBind(MC_KeyBindings.NAMES.PREV_TAB,     none)
    addBind(MC_KeyBindings.NAMES.LOCK,         none)
    addBind(MC_KeyBindings.NAMES.TEXT_BIGGER,  none)
    addBind(MC_KeyBindings.NAMES.TEXT_SMALLER, none)
end

--[[
    The bound key code for a name, or nil when unbound / unavailable.
    A nil never matches a real key press, so callers need no guard.
]]
function MC_KeyBindings.key(name)
    local ok, code = pcall(function() return getCore():getKey(name) end)
    if not ok or type(code) ~= "number" then return nil end
    local none = (Keyboard and Keyboard.KEY_NONE) or 0
    if code == none then return nil end
    return code
end

return MC_KeyBindings
