--- MongooseChat public compatibility API.
-- This is an observe-only surface for other mods. Event payloads are copies;
-- changing one cannot change MongooseChat's own send or rendered line.
-- @module MC_API

local MC_Core = require("MC_Core")
local MC_Incident = require("MC_Incident")

local MC_API = { VERSION = 1 }
local EVENT_NAMES = {
    MCOutboundMessage = true,
    MCInboundMessage = true,
}

-- PZ reloads shared modules between the main menu and a joined game. Keep
-- only the v1 handler registry outside package.loaded so subscriptions made
-- by a compat mod at boot survive that reload. Every load validates the
-- private table before using it; no message or player state lives here.
local REGISTRY_KEY = "__MONGOOSECHAT_COMPAT_API_V1"
local function freshRegistry()
    return {
        version = 1,
        nextToken = 0,
        subscribers = {
            MCOutboundMessage = {},
            MCInboundMessage = {},
        },
        declaredEvents = {},
    }
end

local function validateRegistry(candidate)
    local ok, clean = pcall(function()
        if type(candidate) ~= "table" or candidate.version ~= 1
            or type(candidate.subscribers) ~= "table" then
            return nil
        end
        local result = freshRegistry()
        local seenIds = {}
        for eventName, _ in pairs(EVENT_NAMES) do
            local source = candidate.subscribers[eventName]
            if type(source) == "table" then
                for i = 1, #source do
                    local row = source[i]
                    local token = type(row) == "table" and row.token or nil
                    local id = type(token) == "table" and token.id or nil
                    if type(row) == "table" and type(row.handler) == "function"
                        and type(token) == "table"
                        and token.eventName == eventName
                        and type(id) == "number" and id > 0
                        and id == math.floor(id) and not seenIds[id] then
                        result.subscribers[eventName][#result.subscribers[eventName] + 1] = row
                        seenIds[id] = true
                        if id > result.nextToken then result.nextToken = id end
                    end
                end
            end
        end
        if type(candidate.declaredEvents) == "table" then
            for eventName, _ in pairs(EVENT_NAMES) do
                if candidate.declaredEvents[eventName] == true then
                    result.declaredEvents[eventName] = true
                end
            end
        end
        return result
    end)
    if not ok or not clean then return freshRegistry() end
    return clean
end

local registry = validateRegistry(rawget(_G, REGISTRY_KEY))
rawset(_G, REGISTRY_KEY, registry)
local subscribers = registry.subscribers

local function copyTable(source)
    local result = {}
    if type(source) ~= "table" then return result end
    for key, value in pairs(source) do result[key] = value end
    return result
end

local function declareEvent(name)
    -- Events is an engine bridge in live PZ. Its entries need not be raw Lua
    -- table keys, so rawget(Events, name) cannot tell whether our event was
    -- already declared. Keep that fact beside the reload-stable handlers.
    -- Re-declaring at join time can replace the native event and lose every
    -- Events.<name>.Add callback while MC_API.subscribe keeps working.
    if registry.declaredEvents[name] == true then return end
    local ok = MC_Core.safeExec(function()
        LuaEventManager.AddEvent(name)
    end)
    if not ok then
        MC_Incident.report("API_DISPATCH_FAILED", "event=" .. name)
        return
    end
    registry.declaredEvents[name] = true
end

declareEvent("MCOutboundMessage")
declareEvent("MCInboundMessage")

--- Subscribe to a MongooseChat event.
-- Each handler gets its own payload copy;
-- one broken handler cannot stop the rest. Tokens are opaque to callers.
-- @param eventName `MCOutboundMessage` or `MCInboundMessage`.
-- @param handler Function called with one event payload table.
-- @return An opaque subscription token, or `nil` for invalid arguments.
function MC_API.subscribe(eventName, handler)
    if not EVENT_NAMES[eventName] or type(handler) ~= "function" then return nil end
    registry.nextToken = registry.nextToken + 1
    local token = { eventName = eventName, id = registry.nextToken }
    subscribers[eventName][#subscribers[eventName] + 1] = {
        token = token,
        handler = handler,
    }
    return token
end

--- Remove an event subscription.
-- @param token The opaque token returned by `subscribe`.
-- @return `true` when the subscription was removed; otherwise `false`.
function MC_API.unsubscribe(token)
    if type(token) ~= "table" or not EVENT_NAMES[token.eventName] then return false end
    local list = subscribers[token.eventName]
    for i = #list, 1, -1 do
        if list[i].token == token then
            table.remove(list, i)
            return true
        end
    end
    return false
end

-- Internal producer seam. Call only after the send or render has succeeded.
function MC_API._fire(eventName, payload)
    if not EVENT_NAMES[eventName] then return false end
    local failed = false
    local snapshot = {}
    local list = subscribers[eventName]
    for i = 1, #list do snapshot[i] = list[i] end
    for i = 1, #snapshot do
        local ok = MC_Core.safeExec(function()
            snapshot[i].handler(copyTable(payload))
        end)
        if not ok then failed = true end
    end
    local nativeOK = MC_Core.safeExec(function()
        triggerEvent(eventName, copyTable(payload))
    end)
    if not nativeOK then failed = true end
    if failed then
        MC_Incident.report("API_DISPATCH_FAILED", "event=" .. tostring(eventName))
    end
    return not failed
end

--- Get the compatibility API version.
-- @return The API version number.
function MC_API.version()
    return MC_API.VERSION
end

local function clientModule(name)
    if type(isServer) == "function" then
        local ok, server = pcall(isServer)
        if ok and server == true then return nil end
    end
    local ok, module = pcall(require, name)
    if ok and type(module) == "table" then return module end
    return nil
end

--- Get the current input channel.
-- @return The channel name, or `nil` outside a ready client.
function MC_API.currentChannel()
    local module = clientModule("MC_Input")
    return module and type(module.channel) == "string" and module.channel or nil
end

--- Get the most recent MongooseChat slash prefix.
-- @return The slash prefix, or `nil` outside a ready client.
function MC_API.lastSlashPrefix()
    local module = clientModule("MC_Input")
    return module and type(module.lastSlashPrefix) == "string"
        and module.lastSlashPrefix or nil
end

--- Check whether the MongooseChat window is open.
-- @return `true` when the window is visible; otherwise `false`.
function MC_API.isWindowOpen()
    local module = clientModule("MC_ChatWindow")
    local window = module and module.instance or nil
    if not window then return false end
    local ok, visible = pcall(function() return window:getIsVisible() end)
    return ok and visible == true
end

--- Check whether the MongooseChat input has focus.
-- @return `true` when the input has focus; otherwise `false`.
function MC_API.isChatFocused()
    local module = clientModule("MC_ChatWindow")
    local window = module and module.instance or nil
    if not window or type(window.isInputFocused) ~= "function" then return false end
    local ok, focused = pcall(function() return window:isInputFocused() end)
    return ok and focused == true
end

--- Get the local player's identity colour.
-- @return A fresh RGB table, or `nil` when the colour is not ready.
function MC_API.identityColor()
    local module = clientModule("MC_IdentityColor")
    if not module or type(module.current) ~= "function" then return nil end
    local ok, color = pcall(module.current)
    if not ok or type(color) ~= "table" then return nil end
    return copyTable(color)
end

--- Check whether the local player is masked.
-- @return `true` when the local player is masked; otherwise `false`.
function MC_API.isMasked()
    local module = clientModule("MC_Anonymity")
    if not module or type(module.isMasked) ~= "function"
        or type(getPlayer) ~= "function" then return false end
    local playerOK, player = pcall(getPlayer)
    if not playerOK or not player then return false end
    local ok, masked = pcall(module.isMasked, player)
    return ok and masked == true
end

--- Check whether the local player is deaf.
-- @return `true` when the local player is deaf; otherwise `false`.
function MC_API.isDeaf()
    local module = clientModule("MC_Anonymity")
    if not module or type(module.localPlayerIsDeaf) ~= "function" then return false end
    local ok, deaf = pcall(module.localPlayerIsDeaf)
    return ok and deaf == true
end

--- Check a channel's sandbox switch.
-- @param name Channel name without the `Enabled` suffix.
-- @return `true` or `false`, or `nil` when the channel has no switch.
function MC_API.channelEnabled(name)
    if type(name) ~= "string" or name == "" then return nil end
    local module = clientModule("MC_Config")
    local channels = module and module.Channels or nil
    if type(channels) ~= "table" then return nil end
    local key = string.lower(name) .. "Enabled"
    local value = channels[key]
    if type(value) ~= "boolean" then return nil end
    return value
end

return MC_API
