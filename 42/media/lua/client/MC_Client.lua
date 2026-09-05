--[[
================================================================================
    MongooseChat - Client Main
    
    The client-side coordinator for MongooseChat. Receives messages from server,
    manages UI elements (bubbles, typing indicators, chat panel), and integrates
    with the vanilla ISChat system.
    
    RESPONSIBILITIES:
    - Server command handling (ChatMessage, RadioMessage, Typing)
    - Bubble lifecycle management
    - Typing indicator management
    - Chat panel creation and vanilla view suppression
    - Vanilla-chat bypass suppression
    - Boredom reduction for RP activity
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Config = require("MC_Config")
local MC_ChatPanel = require("MC_ChatPanel")
local MC_ChatWindow = require("MC_ChatWindow")
local MC_Bubble = require("MC_Bubble")
local MC_Input = require("MC_Input")
local MC_Typing = require("MC_Typing")
local MC_Anonymity = require("MC_Anonymity")
local MC_Bio = require("MC_Bio")
local MC_BabbleHint = require("MC_BabbleHint")
local MC_LangRegistry = require("MC_LangRegistry")
local MC_SignGesture = require("MC_SignGesture")
local MC_Incident = require("MC_Incident")
local MC_Radio = require("MC_Radio")
local MC_IdentityColor = require("MC_IdentityColor")

local dbg = MC_Core.debugger("CLIENT")

-- Helper: Get local player's UI manager index (0 for single player)
local function getPlayerUIIndex()
    local player = getPlayer()
    if player and player.getPlayerNum then
        return player:getPlayerNum() or 0
    end
    return 0
end

local MC_Client = {}

-- STATE

-- Active bubbles (keyed by player online ID)
local activeBubbles = {}

-- Active radio bubbles (keyed by "radio_<type>_<position>")
local activeRadioBubbles = {}

-- Active typing indicators (keyed by username)
local activeTyping = {}

-- Chat panel instance
local chatPanel = nil
local chatWindow = nil

-- Signing-gesture cooldown tracker (v1). Pure decision logic lives in
-- MC_SignGesture.lua; this is its one glue-side instance for the whole
-- client session (see onChatMessage below).
local signGesture = MC_SignGesture.new()

-- Flags
local panelCreated = false
local vanillaChatHooked = false
local vanillaChatOriginal = nil
local vanillaChatWrapper = nil
local vanillaChatExpected = false
local lastLoggedTab = nil

-- MC may start before the server sandbox has reached the client. If the
-- chat-window switch then lands Off, put every vanilla view back exactly as
-- we found it instead of leaving zero-sized panels behind another mod.
local vanillaViewState = {}
local vanillaWindowState = nil

local adminMessageEvent = nil
local adminMessageHandlerInstalled = false
local adminMessageForceRebind = false
local adminMessageLastFailure = nil
local renderedAdminMessages = setmetatable({}, { __mode = "k" })
local IDENTITY_COLOR_REPAIR_COOLDOWN_MS = 3000
local lastIdentityColorRepair = -IDENTITY_COLOR_REPAIR_COOLDOWN_MS
local IDENTITY_COLOR_SYNC_RETRY_MS = 1500
local IDENTITY_COLOR_SYNC_MAX_REQUESTS = 5
local identityColorSyncActive = false
local identityColorSyncRequests = 0
local identityColorSyncNextAt = 0
local identityColorSyncExhaustedReported = false
local identityColorReceiptGeneration = nil
local identityColorReceiptRevision = nil

local function isOwnIdentityColorPacket(args)
    if type(args) ~= "table" or type(getPlayer) ~= "function" then return false end
    local ok, player = pcall(getPlayer)
    if not ok or not player then return false end
    local nameOk, username = pcall(function() return player:getUsername() end)
    return nameOk and type(username) == "string" and args.username == username
end

local function printOwnIdentityColorReceipt(args)
    if not isOwnIdentityColorPacket(args) then return end
    -- applySync has already bounded origin and revision. Keep this receipt
    -- small: it proves acceptance without identity, session, colour, or body.
    local stamp = MC_IdentityColor.currentStamp()
    if not stamp then return end
    if identityColorReceiptGeneration == stamp.generation
        and identityColorReceiptRevision == stamp.revision then return end
    identityColorReceiptGeneration = stamp.generation
    identityColorReceiptRevision = stamp.revision
    print("[MongooseChat][IdentityColorSync] status=accepted origin="
        .. args.origin .. " revision=" .. tostring(args.revision))
end

local function requestOwnIdentityColor(now)
    if not identityColorSyncActive then return false end
    if MC_IdentityColor.current() then
        identityColorSyncActive = false
        return true
    end
    if identityColorSyncRequests >= IDENTITY_COLOR_SYNC_MAX_REQUESTS then
        identityColorSyncActive = false
        if not identityColorSyncExhaustedReported then
            identityColorSyncExhaustedReported = true
            MC_Incident.report("IDENTITY_COLOR_SYNC_EXHAUSTED", "retry limit reached")
        end
        return false
    end
    local requested = MC_Core.safeExec(function()
        sendClientCommand("MongooseChat", "IdentityColorSyncRequest", { protocol = 1 })
    end)
    identityColorSyncRequests = identityColorSyncRequests + 1
    identityColorSyncNextAt = now + IDENTITY_COLOR_SYNC_RETRY_MS
    if not requested and identityColorSyncRequests == 1 then
        MC_Incident.report("IDENTITY_COLOR_SYNC_FAILED", "stage=request")
    end
    return requested
end

local function beginOwnIdentityColorSync()
    identityColorSyncActive = true
    identityColorSyncRequests = 0
    identityColorSyncNextAt = 0
    identityColorSyncExhaustedReported = false
    requestOwnIdentityColor(MC_Core.safe(function() return MC_Core.getTimeMs() end, 0))
end

local function reportClientFailure(code, stage)
    MC_Incident.report(code, "stage=" .. tostring(stage or "unknown"))
end

local function chatPanelHas(methodName, stage)
    if MC_ChatPanel and type(MC_ChatPanel[methodName]) == "function" then
        return true
    end
    reportClientFailure("CLIENT_RENDER_FAILED",
        tostring(stage or "unknown") .. "-panel-unavailable")
    return false
end

-- The shipped B42 ISChat builds each tab's `chatStreams` from exact table
-- references in ISChat.allChatStreams. Use that semantic identity for UI
-- visibility; tab positions, localized titles, and numeric IDs confer no
-- Admin trust.
local function canonicalAdminStream()
    if type(ISChat) ~= "table"
        or type(ISChat.allChatStreams) ~= "table"
        or type(ISChat.defaultTabStream) ~= "table"
    then
        return nil, false
    end

    local adminStream = nil
    local known = {}
    for _, stream in ipairs(ISChat.allChatStreams) do
        if type(stream) ~= "table" or type(stream.name) ~= "string" then
            return nil, false
        end
        known[stream] = true
        if stream.name == "admin" then
            if adminStream ~= nil then return nil, false end
            adminStream = stream
        end
    end
    if adminStream == nil then return nil, false end

    local isDefault = false
    for _, stream in pairs(ISChat.defaultTabStream) do
        if stream == adminStream then isDefault = true end
        if stream ~= nil and not known[stream] then return nil, false end
    end
    if not isDefault then return nil, false end
    return adminStream, true
end

-- @return isAdmin, authoritative
local function verifiedAdminTabView(view)
    if type(view) ~= "table" or type(view.chatStreams) ~= "table" then
        return false, false
    end
    local adminStream, metadataOK = canonicalAdminStream()
    if not metadataOK then return false, false end

    local known = {}
    for _, stream in ipairs(ISChat.allChatStreams) do known[stream] = true end

    local count, adminCount = 0, 0
    local seen = {}
    for _, stream in ipairs(view.chatStreams) do
        count = count + 1
        if not known[stream] or seen[stream] then return false, false end
        seen[stream] = true
        if stream == adminStream then adminCount = adminCount + 1 end
    end
    if count == 0 or count ~= #view.chatStreams then return false, false end
    if adminCount == 0 then return false, true end
    -- Vanilla's Admin tab contains exactly the canonical Admin stream. A
    -- mixed or duplicated stream list is not safe to hand back to vanilla.
    return adminCount == 1 and count == 1, adminCount == 1 and count == 1
end

-- A verified admin line, drawn in OUR panel on the Admin tab. Author and
-- text come straight from the engine's ChatMessage; nothing is parsed out
-- of a formatted string. An unreadable field degrades to a plain line
-- rather than dropping staff traffic on the floor.
local function renderAdminLine(message)
    local author = MC_Core.safe(function() return message:getAuthor() end, nil)
    local text = MC_Core.safe(function() return message:getText() end, nil)
    if type(text) ~= "string" or text == "" then
        MC_Incident.report("ADMIN_LINE_UNREADABLE",
            "verified admin message carried no text")
        return
    end
    if type(author) ~= "string" or author == "" then author = "[ADMIN]" end
    if not chatPanelHas("addMessage", "admin-line") then return end
    -- onAdminMessageBody has already proved entitlement before this renderer.
    local presentation = MC_IdentityColor.resolveAdminPresentation(author, true)
    local identityColor = presentation and presentation.color or nil
    if not identityColor then
        local now = MC_Core.safe(function() return MC_Core.getTimeMs() end, 0)
        if now - lastIdentityColorRepair >= IDENTITY_COLOR_REPAIR_COOLDOWN_MS then
            lastIdentityColorRepair = now
            MC_Core.safeExec(function()
                sendClientCommand("MongooseChat", "IdentityColorSyncRequest", { protocol = 1 })
            end)
        end
    end
    local panelData = {
        channel = "admin",
        username = author,
        characterName = author,
        message = text,
        timestamp = MC_Core.getTimeSeconds(),
        playerColor = identityColor
            or MC_Config.ChannelColors.admin or { 240, 117, 121 },
        hoverName = presentation and presentation.name or nil,
    }
    local own = MC_IdentityColor.isAdminAuthorLocal(author, true)
    if type(MC_ChatPanel.addVerifiedAdminMessage) == "function" then
        MC_ChatPanel.addVerifiedAdminMessage(panelData, own)
    else
        MC_ChatPanel.addMessage(panelData)
    end
end

local function reportAdminBoundary(stage)
    MC_Incident.report("VANILLA_ADMIN_UNVERIFIED",
        "stage=" .. tostring(stage or "unknown") .. "; raw vanilla view suppressed")
end

local function hasMember(value, name)
    local kind = type(value)
    if kind ~= "table" and kind ~= "userdata" then return false end
    local ok, member = pcall(function() return value[name] end)
    return ok and member ~= nil
end

local function looksLikeChatMessage(value)
    local kind = type(value)
    if kind ~= "table" and kind ~= "userdata" then return false end
    return hasMember(value, "getAuthor") and hasMember(value, "getText")
end

local KNOWN_CHAT_TYPES = {
    notDefined = true,
    general = true,
    whisper = true,
    say = true,
    shout = true,
    faction = true,
    safehouse = true,
    radio = true,
    admin = true,
    server = true,
}

local function resolvedChatTypeName(chatType)
    -- Some bridges expose the canonical Java enum objects through a Lua table.
    -- Identity is authoritative; a lookalike table or name() method is not.
    if type(ChatType) == "table" then
        for typeName in pairs(KNOWN_CHAT_TYPES) do
            local ok, canonical = pcall(function() return ChatType[typeName] end)
            if ok and canonical ~= nil and chatType == canonical then
                return typeName, true
            end
        end
        if type(chatType) == "table" then return nil, false end
    end

    -- B42 can bridge ChatType as a non-table display value. Keep this closed
    -- to the one observed Admin spelling; case variants and other primitives
    -- cannot grant an Admin render.
    if type(chatType) == "userdata" then
        local ok, display = pcall(tostring, chatType)
        if ok and display == "admin" then return "admin", true end
        return nil, false
    end
    if type(chatType) == "string" and chatType == "admin" then
        return "admin", true
    end
    return nil, false
end

-- ChatMessage exposes getChat(); ChatBase exposes getType()/getTabID(). A
-- numeric destination tab is only a consistency check against ChatBase,
-- never evidence of Admin by itself.
-- @return isAdmin, authoritative
local function verifiedAdminMessage(message, destinationTabID)
    if not hasMember(message, "getChat") then return false, false end
    local chatOK, chat = pcall(function() return message:getChat() end)
    if not chatOK or chat == nil
        or not hasMember(chat, "getType")
        or not hasMember(chat, "getTabID")
    then
        return false, false
    end

    local typeOK, chatType = pcall(function() return chat:getType() end)
    if not typeOK or chatType == nil then return false, false end
    local typeName, typeAuthoritative = resolvedChatTypeName(chatType)
    if not typeAuthoritative then return false, false end
    if typeName ~= "admin" then return false, true end

    local tabOK, declaredTabID = pcall(function() return chat:getTabID() end)
    if not tabOK or type(declaredTabID) ~= "number"
        or type(destinationTabID) ~= "number"
        or declaredTabID ~= destinationTabID
    then
        return false, false
    end
    return true, true
end

MC_Client._verifiedAdminTabView = verifiedAdminTabView
MC_Client._verifiedAdminMessage = verifiedAdminMessage

local function hasVerifiedAdminEntitlement()
    if not ISChat or not ISChat.instance then return false end
    for _, tab in ipairs(ISChat.instance.tabs or {}) do
        local isAdmin, authoritative = verifiedAdminTabView(tab)
        if isAdmin and authoritative then return true end
    end
    return false
end

local adminMessageVerifier = verifiedAdminMessage

local function isSafeTabID(value)
    return type(value) == "number"
        and value == value
        and value >= 0
        and value <= 2147483647
        and value == math.floor(value)
end

-- OnAddMessage is global: General/server traffic reaches this handler too.
-- Only a destination matching the engine's already verified Admin tab may
-- cross into the strict Admin message boundary below. A numeric destination
-- alone grants nothing; the tab view and its sole canonical stream must both
-- have passed verifiedAdminTabView first.
local function targetsVerifiedAdminTab(destinationTabID)
    if not isSafeTabID(destinationTabID)
        or type(ISChat) ~= "table"
        or type(ISChat.instance) ~= "table"
        or type(ISChat.instance.tabs) ~= "table"
    then
        return false
    end
    for _, tab in ipairs(ISChat.instance.tabs) do
        local isAdmin, authoritative = verifiedAdminTabView(tab)
        if isAdmin and authoritative then
            local ok, tabID = pcall(function()
                return tab.chatStreams[1].tabID
            end)
            if ok and isSafeTabID(tabID) and tabID == destinationTabID then
                return true
            end
        end
    end
    return false
end

local function onAdminMessageBody(message, destinationTabID)
    if not MC_Config.featureOn("ChatWindowEnabled") then return end
    if not looksLikeChatMessage(message) then return end
    if not targetsVerifiedAdminTab(destinationTabID) then return end
    local isAdmin, authoritative = adminMessageVerifier(message, destinationTabID)
    if not isAdmin then
        if not authoritative then reportAdminBoundary("event-message") end
        return
    end
    if not hasVerifiedAdminEntitlement() then
        reportAdminBoundary("event-entitlement")
        return
    end
    if renderedAdminMessages[message] then return end
    renderedAdminMessages[message] = true
    renderAdminLine(message)
end

local function onAdminMessage(message, destinationTabID)
    local ok = pcall(onAdminMessageBody, message, destinationTabID)
    if not ok then
        pcall(function()
            MC_Incident.report("ADMIN_EVENT_CALLBACK_FAILED",
                "admin event callback failed; transport left untouched")
        end)
    end
end

local function adminHandlerFailure(reason)
    if adminMessageLastFailure == reason then return end
    adminMessageLastFailure = reason
    print("[MongooseChat][ADMIN_EVENT_HANDLER] stage=install-failed;reason="
        .. tostring(reason))
end

local function installAdminMessageHandler(force)
    if not MC_Config.featureOn("ChatWindowEnabled") then return false end
    if not ISChat or not ISChat.instance then
        adminHandlerFailure("chat-unavailable")
        return false
    end
    local event = Events and Events.OnAddMessage or nil
    if not event or not hasMember(event, "Add") then
        adminHandlerFailure("event-unavailable")
        return false
    end

    local eventChanged = event ~= adminMessageEvent
    if adminMessageHandlerInstalled and not eventChanged and not force then
        return true
    end

    if adminMessageHandlerInstalled and not eventChanged and force then
        if hasMember(event, "Remove") then
            local removed = MC_Core.safeExec(function()
                event.Remove(onAdminMessage)
            end)
            if not removed then
                adminHandlerFailure("remove-raised")
                return false
            end
        else
            -- The stable function is already retained. Without Remove, adding
            -- again would be the only unsafe act, so keep the known binding.
            adminMessageForceRebind = false
            return true
        end
    end

    local added = MC_Core.safeExec(function() event.Add(onAdminMessage) end)
    if not added then
        adminHandlerFailure("add-raised")
        return false
    end
    adminMessageEvent = event
    adminMessageHandlerInstalled = true
    adminMessageForceRebind = false
    adminMessageLastFailure = nil
    print("[MongooseChat][ADMIN_EVENT_HANDLER] stage=installed;reason="
        .. (eventChanged and "event-change-or-start" or "forced-rebind"))
    return true
end

local function uninstallAdminMessageHandler()
    if not adminMessageHandlerInstalled then return true end
    local event = adminMessageEvent
    if event and hasMember(event, "Remove") then
        local removed = MC_Core.safeExec(function()
            event.Remove(onAdminMessage)
        end)
        if not removed then return false end
    end
    -- If this engine has no Remove seam, the stable callback remains inert:
    -- onAdminMessageBody checks the live feature switch before doing any work.
    adminMessageEvent = nil
    adminMessageHandlerInstalled = false
    adminMessageForceRebind = false
    adminMessageLastFailure = nil
    renderedAdminMessages = setmetatable({}, { __mode = "k" })
    return true
end

MC_Client._installAdminMessageHandlerForTest = installAdminMessageHandler
MC_Client._onAdminMessageForTest = onAdminMessage
MC_Client._setAdminMessageVerifierForTest = function(verifier)
    adminMessageVerifier = verifier or verifiedAdminMessage
end

-- PLAYER LOOKUP

local function getPlayerByUsername(username)
    local players = getOnlinePlayers()
    if not players then 
        dbg("getPlayerByUsername: getOnlinePlayers() nil")
        return nil 
    end
    
    dbg("getPlayerByUsername: searching %d players for '%s'", players:size(), tostring(username))
    
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p:getUsername() == username then
            dbg("getPlayerByUsername: FOUND at index %d", i)
            return p
        end
    end
    
    dbg("getPlayerByUsername: NOT FOUND")
    return nil
end

-- LIVE SANDBOX VAR HELPERS
-- Read directly from SandboxVars for settings that need to work mid-game

local function areBubblesEnabled()
    return MC_Config.optionalOn("BubblesEnabled",
        MC_Config.Bubble and MC_Config.Bubble.enabled == true)
end

local function areTypingIndicatorsEnabled()
    return MC_Config.optionalOn("TypingIndicatorsEnabled",
        MC_Config.TypingIndicators
            and MC_Config.TypingIndicators.enabled == true)
end

-- BUBBLE MANAGEMENT

local function showBubble(player, message, channel, hideAvatar, characterName, isAnonymous, modality, playerColor)
    if not areBubblesEnabled() then return end
    if not player then
        dbg("showBubble: nil player")
        return
    end

    local id = player:getOnlineID()
    local username = player:getUsername()

    dbg("showBubble: player=%s id=%s msg=%s hideAvatar=%s isAnonymous=%s", username, tostring(id), tostring(message):sub(1, 30), tostring(hideAvatar), tostring(isAnonymous))
    
    -- Remove existing bubble
    if activeBubbles[id] then
        dbg("showBubble: removing existing")
        activeBubbles[id].dead = true
        activeBubbles[id]:removeFromUIManager()
        activeBubbles[id] = nil
    end
    
    -- Remove typing indicator
    if activeTyping[username] then
        dbg("showBubble: removing typing")
        activeTyping[username].dead = true
        activeTyping[username]:removeFromUIManager()
        activeTyping[username] = nil
    end
    
    -- Create new bubble (pass hideAvatar, characterName, and the anonymity
    -- state for caller compatibility and anonymous emote handling).
    local bubble = MC_Bubble:new(player, message, channel, hideAvatar,
        characterName, isAnonymous, modality, playerColor)
    
    if not bubble then
        dbg("showBubble: MC_Bubble:new returned nil")
        return
    end
    
    bubble:initialise()
    bubble:addToUIManager(getPlayerUIIndex())
    bubble:setVisible(true)
    
    activeBubbles[id] = bubble
    dbg("showBubble: created")
end

local function showEmoteBubble(player, characterName, action, playerColor)
    if not areBubblesEnabled() then return end
    if not player then 
        dbg("showEmoteBubble: nil player")
        return 
    end
    
    local id = player:getOnlineID()
    local username = player:getUsername()
    
    dbg("showEmoteBubble: player=%s action=%s", username, tostring(action):sub(1, 30))
    
    if activeBubbles[id] then
        activeBubbles[id].dead = true
        activeBubbles[id]:removeFromUIManager()
        activeBubbles[id] = nil
    end
    
    if activeTyping[username] then
        activeTyping[username].dead = true
        activeTyping[username]:removeFromUIManager()
        activeTyping[username] = nil
    end
    
    local bubble = MC_Bubble:newEmote(characterName, action, player, playerColor)
    
    if not bubble then
        dbg("showEmoteBubble: MC_Bubble:newEmote returned nil")
        return
    end
    
    bubble:initialise()
    bubble:addToUIManager(getPlayerUIIndex())
    bubble:setVisible(true)
    
    activeBubbles[id] = bubble
    dbg("showEmoteBubble: created")
end

local function showDoBubble(player, narration, playerColor)
    if not areBubblesEnabled() then return end
    if not player then 
        dbg("showDoBubble: nil player")
        return 
    end
    
    local id = player:getOnlineID()
    local username = player:getUsername()
    
    dbg("showDoBubble: player=%s narration=%s", username, tostring(narration):sub(1, 30))
    
    if activeBubbles[id] then
        activeBubbles[id].dead = true
        activeBubbles[id]:removeFromUIManager()
        activeBubbles[id] = nil
    end
    
    if activeTyping[username] then
        activeTyping[username].dead = true
        activeTyping[username]:removeFromUIManager()
        activeTyping[username] = nil
    end
    
    local bubble = MC_Bubble:newDo(narration, player, playerColor)
    
    if not bubble then
        dbg("showDoBubble: MC_Bubble:newDo returned nil")
        return
    end
    
    bubble:initialise()
    bubble:addToUIManager(getPlayerUIIndex())
    bubble:setVisible(true)
    
    activeBubbles[id] = bubble
    dbg("showDoBubble: created")
end

local function showRadioBubble(msgData, playerColor)
    if not areBubblesEnabled() then return end
    dbg("showRadioBubble: receiverType=%s isPrivate=%s freq=%s",
        tostring(msgData.receiverType), tostring(msgData.isPrivate), tostring(msgData.frequency))
    
    local target = nil
    local bubbleKey = nil
    
    if msgData.receiverType == "player" then
        local ownerPlayer = getPlayerByUsername(msgData.receiverOwnerId)
        if ownerPlayer then
            target = ownerPlayer
            bubbleKey = "radio_player_" .. ownerPlayer:getOnlineID()
            dbg("showRadioBubble: player target: %s", msgData.receiverOwnerId)
        else
            dbg("showRadioBubble: player not found: %s", tostring(msgData.receiverOwnerId))
            if msgData.receiverPosition then
                target = msgData.receiverPosition
                bubbleKey = "radio_pos_" .. msgData.frequency
            else
                return
            end
        end
    elseif msgData.receiverType == "ground" or msgData.receiverType == "vehicle" then
        if msgData.receiverPosition then
            target = msgData.receiverPosition
            local posKey = math.floor(target.x) .. "_" .. math.floor(target.y)
            bubbleKey = "radio_" .. msgData.receiverType .. "_" .. posKey
            dbg("showRadioBubble: world target at %s", posKey)
        else
            dbg("showRadioBubble: no position")
            return
        end
    else
        dbg("showRadioBubble: unknown receiverType")
        return
    end
    
    if bubbleKey and activeRadioBubbles[bubbleKey] then
        dbg("showRadioBubble: removing existing: %s", bubbleKey)
        activeRadioBubbles[bubbleKey].dead = true
        activeRadioBubbles[bubbleKey]:removeFromUIManager()
        activeRadioBubbles[bubbleKey] = nil
    end
    
    local bubble = MC_Bubble:newRadio(
        msgData.message,
        msgData.channel,
        target,
        msgData.isPrivate,
        msgData.volume,
        playerColor
    )
    
    if not bubble then
        dbg("showRadioBubble: MC_Bubble:newRadio returned nil")
        return
    end
    
    bubble:initialise()
    bubble:addToUIManager(getPlayerUIIndex())
    bubble:setVisible(true)
    
    if bubbleKey then
        activeRadioBubbles[bubbleKey] = bubble
        dbg("showRadioBubble: created key=%s", bubbleKey)
    end
end

-- TYPING INDICATOR

local function showTyping(player)
    if not areTypingIndicatorsEnabled() then return end
    if not player then 
        dbg("showTyping: nil player")
        return 
    end
    
    local localPlayer = getPlayer()
    if not localPlayer then 
        dbg("showTyping: no local player")
        return 
    end
    
    local username = player:getUsername()
    
    if player:getOnlineID() == localPlayer:getOnlineID() then 
        dbg("showTyping: ignoring self")
        return 
    end
    
    if activeTyping[username] then
        dbg("showTyping: refreshing %s", username)
        activeTyping[username]:refresh()
    else
        dbg("showTyping: creating %s", username)
        local typing = MC_Typing:new(player, 3)
        typing:initialise()
        typing:addToUIManager(getPlayerUIIndex())
        typing:setVisible(true)
        activeTyping[username] = typing
    end
end

-- UI CLEANUP

local function cleanupUI()
    local bubblesEnabled = areBubblesEnabled()
    local radioEnabled = MC_Config.featureOn("RadioEnabled")
    local typingEnabled = areTypingIndicatorsEnabled()

    for id, bubble in pairs(activeBubbles) do
        if not bubblesEnabled or bubble.dead then
            bubble:removeFromUIManager()
            activeBubbles[id] = nil
        end
    end
    
    for key, bubble in pairs(activeRadioBubbles) do
        if not bubblesEnabled or not radioEnabled or bubble.dead then
            bubble:removeFromUIManager()
            activeRadioBubbles[key] = nil
        end
    end
    
    for username, typing in pairs(activeTyping) do
        if not typingEnabled or typing.dead then
            typing:removeFromUIManager()
            activeTyping[username] = nil
        end
    end
end

-- BOREDOM REDUCTION

-- Cooldown for boredom reduction requests. With default reductionAmount=100
-- (full cure per message), there's zero gameplay value in firing more than
-- once per window -- you're already at zero boredom. In a 10-person scene
-- without this throttle, one message generated N*(N-1) = 90 server commands.
local BOREDOM_COOLDOWN_MS = 30 * 1000
local lastBoredomRequestMs = 0

--[[
    B42 Boredom Reduction (Server-Authoritative)
    
    Client-side stat changes don't persist in B42 MP - server overwrites them.
    We send a request to the server, which performs the actual stat modification.
    
    Fix for C9 (0.8.0): throttled to once per 30s. Reduces RCP pressure in
    busy RP scenes with no gameplay impact at default reductionAmount.
]]
local function reduceBoredom()
    if not MC_Config.Boredom.enabled then return end
    if not isClient() then return end
    
    local now = MC_Core.getTimeMs()
    if (now - lastBoredomRequestMs) < BOREDOM_COOLDOWN_MS then
        dbg("reduceBoredom: suppressed (cooldown, %dms since last)", now - lastBoredomRequestMs)
        return
    end
    lastBoredomRequestMs = now
    
    dbg("reduceBoredom: sending request to server")
    sendClientCommand("MongooseChat", "ReduceBoredom", {})
end

-- MESSAGE HANDLERS

local function runSignGesture(msgData)
    local ok = MC_Core.safeExec(function()
        local localPlayer = getPlayer()
        local gestureCandidate = MC_Config.SignGesture.enabled == true
            and msgData.modality == "signed"
            and (msgData.channel == "say"
                or msgData.channel == "whisper"
                or msgData.channel == "low"
                or msgData.channel == "yell")
        if gestureCandidate and not localPlayer then
            error("local player unavailable")
        end
        local localUsername = localPlayer and localPlayer:getUsername()
        if gestureCandidate
            and (type(localUsername) ~= "string" or localUsername == "")
        then
            error("local username unavailable")
        end
        local isOwnMessage = localUsername ~= nil
            and msgData.username == localUsername
        local emote = signGesture:consider(MC_Core.getTimeMs(), {
            channel = msgData.channel,
            modality = msgData.modality,
            isOwnMessage = isOwnMessage,
            enabled = MC_Config.SignGesture.enabled,
            cooldownMs = MC_Config.SignGesture.cooldownMs,
            gestureDefault = MC_Config.SignGesture.gestureDefault,
            gestureYell = MC_Config.SignGesture.gestureYell,
        })
        if emote then
            localPlayer:playEmote(emote)
            dbg("onChatMessage: signing gesture '%s' fired (channel=%s)",
                emote, tostring(msgData.channel))
        end
    end)
    if not ok then
        reportClientFailure("SIGN_GESTURE_FAILED", "incoming-message")
    end
    return ok
end

local function maybeShowBabbleHint(msgData)
    if not MC_Config.featureOn("BabbleHintsEnabled") then return true end
    local consumedStore = nil
    local hintConsumed = false
    local ok = MC_Core.safeExec(function()
        local localPlayer = getPlayer()
        if not localPlayer then
            if msgData.babbled then error("local player unavailable") end
            return
        end
        local localUsername = localPlayer:getUsername()
        if msgData.babbled
            and (type(localUsername) ~= "string" or localUsername == "")
        then
            error("local username unavailable")
        end
        local modData = localPlayer:getModData()
        if MC_BabbleHint.isQualifyingBabble(msgData, localUsername)
            and type(modData) ~= "table"
        then
            error("character hint store unavailable")
        end
        if MC_BabbleHint.shouldFire(msgData, localUsername, modData) then
            consumedStore = modData
            hintConsumed = true
            if not MC_ChatPanel or type(MC_ChatPanel.addMessage) ~= "function" then
                error("chat panel unavailable")
            end
            MC_ChatPanel.systemMessage(
                "You don't recognize that tongue -- yet. "
                    .. "Keep listening; /lang shows what you "
                    .. "understand so far.",
                { color = {210, 190, 140} })
            dbg("onChatMessage: first-babble hint shown")
        end
    end)
    if not ok then
        local rollbackOK = true
        if hintConsumed and consumedStore then
            rollbackOK = pcall(function()
                consumedStore[MC_BabbleHint.MARKER] = nil
            end)
        end
        reportClientFailure("BABBLE_HINT_FAILED",
            rollbackOK and "display-or-state" or "display-and-rollback")
    end
    return ok
end

MC_Client._runSignGesture = runSignGesture
MC_Client._maybeShowBabbleHint = maybeShowBabbleHint

local function onChatMessage(msgData)
    if not msgData then
        dbg("onChatMessage: nil msgData")
        return
    end

    dbg("onChatMessage: username=%s channel=%s msg=%s",
        tostring(msgData.username), tostring(msgData.channel),
        tostring(msgData.message and msgData.message:sub(1,30) or "nil"))
    
    -- Get speaker player for anonymity check and bubble display
    local player = getPlayerByUsername(msgData.username)

    -- Signing gesture (v1, presentation-only -- see MC_SignGesture.lua's
    -- header for why this echo IS the send seam). Runs before every
    -- early-return below (sight gate, Deaf reception, etc.) on purpose:
    -- this is about the SENDER's own body animating, not about what any
    -- receiver can perceive, so it must not depend on those gates.
    -- Presentation failure never blocks chat, but it is still an observable
    -- boundary incident rather than a silent dropped gesture.
    runSignGesture(msgData)

    -- Apply anonymity for IC channels (not OOC, admin, etc.)
    local icChannels = {say = true, yell = true, low = true, whisper = true, emote = true, ["do"] = true}
    if icChannels[msgData.channel] then
        MC_Anonymity.anonymizeMessageData(msgData, player)
        if msgData.isAnonymous then
            dbg("onChatMessage: anonymized to '%s'", msgData.characterName)
        end
    end

    -- Sight gate + Deaf reception. Spoken/whisper/low/
    -- yell only -- emote/do are narration, not speech or signing.
    local speechChannels = {say = true, yell = true, low = true, whisper = true}
    if speechChannels[msgData.channel] then
        if msgData.modality == "signed" then
            -- Fail-closed: cannot verify sight -> not shown at all.
            if not MC_Anonymity.canSee(player) then
                dbg("onChatMessage: signed message suppressed -- no line of sight")
                return
            end
        else
            local deaf = MC_Anonymity.deafReception(player)
            if deaf.mode == "nothing" then
                dbg("onChatMessage: spoken message suppressed for a Deaf receiver with no sight")
                return
            elseif deaf.mode == "presence" then
                local who = (msgData.characterName and msgData.characterName ~= "")
                    and msgData.characterName or "A figure"
                msgData.message = who .. "'s lips move"
                msgData.chunks = nil
            elseif deaf.mode == "lipread" then
                if MC_Config.featureOn("LipreadEnabled") then
                    local MC_Lipread = require("MC_Lipread")
                    msgData.message = MC_Lipread.gapify(msgData.message, msgData.timestamp or 0)
                else
                    -- Lip reading handed to another mod (or off): presence only.
                    local who = (msgData.characterName and msgData.characterName ~= "")
                        and msgData.characterName or "A figure"
                    msgData.message = who .. "'s lips move"
                end
                msgData.chunks = nil  -- flat text from here; stale L2 chunk coloring would desync
            end
            -- "full": not Deaf (or the sandbox has it off) -- unaffected.
        end
    end

    -- Narration (/me, /do) is watched, not heard, so it is never suppressed
    -- here -- but words quoted inside it WERE spoken aloud, and a receiver
    -- who cannot hear does not get them. The action survives, the speech does
    -- not: what a Deaf watcher sees is that someone said something.
    local narrationChannels = {emote = true, ["do"] = true}
    if narrationChannels[msgData.channel] and msgData.message
        and #MC_Core.findQuotedRuns(msgData.message) > 0
    then
        if msgData.modality == "signed" then
            -- Signed words are seen, not heard, so hearing has no say in
            -- them: a Deaf watcher reads them perfectly. Sight decides
            -- instead, and fails closed -- someone who cannot see the
            -- speaker gets the action they were given but none of the signs.
            if not MC_Anonymity.canSee(player) then
                msgData.message = MC_Core.mapQuotedSpeech(msgData.message, function()
                    return "..."
                end)
            end
        else
            local deaf = MC_Anonymity.deafReception(player)
            if deaf.mode == "lipread" and MC_Config.featureOn("LipreadEnabled") then
                local MC_Lipread = require("MC_Lipread")
                local timestamp = msgData.timestamp or 0
                msgData.message = MC_Core.mapQuotedSpeech(msgData.message, function(spoken)
                    return MC_Lipread.gapify(spoken, timestamp)
                end)
            elseif deaf.mode == "nothing" or deaf.mode == "presence" or deaf.mode == "lipread" then
                msgData.message = MC_Core.mapQuotedSpeech(msgData.message, function()
                    return "..."
                end)
            end
            -- "full": hears normally -- unaffected.
        end
    end

    -- Language tag. Server marks deliveries with msgData.language
    -- only once the receiver has identified the language (acquired at least
    -- one word in it). Until then, non-comprehenders see babbled text with
    -- no label — they can guess from the phonetic texture (French vs Slavic
    -- vs Turkish sound distinct) but the engine doesn't name it for them.
    -- Prefix here so both the chat panel and the bubble pick it up.
    -- 
    -- Two paths:
    --   1. Flat-string only (msgData.chunks nil): prefix the tag onto
    --      msgData.message; parseColorSegments client-side handles styling.
    --   2. Chunks present (v8.5+): prefix the tag onto msgData.message
    --      (so bubble + flat-string consumers still see it) AND prepend a
    --      matching base chunk (color = nil -> channel tagColor) so the
    --      ChatPanel render path sees the tag in the chunk array too.
    if msgData.language and msgData.language ~= "" then
        local tag = MC_LangRegistry.displayName(msgData.language)
        local prefix = "[" .. tag .. "] "
        msgData.message = prefix .. (msgData.message or "")
        if msgData.chunks then
            table.insert(msgData.chunks, 1, { text = prefix })  -- nil color -> channel default
        end
    end
    
    -- Add to chat panel
    if chatPanelHas("addMessage", "chat-message") then
        MC_ChatPanel.addMessage(msgData)
        dbg("onChatMessage: added to panel")
    end

    -- One-time first-babble hint.
    --
    -- The mod's one proactive "you're learning" notice (AcquisitionMoment's
    -- firstInLanguage) deliberately never fires for a listener who hasn't
    -- acquired a single word yet -- so a brand-new player's FIRST contact
    -- with the headline babble mechanic explains nothing; it just sounds
    -- broken. This fires exactly once per character, the first time
    -- msgData.babbled is true (MC_Server's additive signal for "genuinely
    -- unlabeled babble, for THIS listener") and it isn't the listener's own
    -- speech. MC_BabbleHint is the pure, offline-testable decision; the
    -- once-flag persists via the local player's modData -- the same
    -- per-character-stamp idiom MC_Server.checkFreshCharacter already uses.
    maybeShowBabbleHint(msgData)

    -- Show bubble
    if player and msgData.channel == "emote" then
        showEmoteBubble(player, msgData.characterName, msgData.message, msgData.playerColor)
    elseif player and msgData.channel == "do" then
        showDoBubble(player, msgData.message, msgData.playerColor)
    elseif player then
        local bubbleChannels = {say = true, yell = true, low = true}
        if bubbleChannels[msgData.channel] then
            -- Pass hideAvatar (only for distant speakers), characterName
            -- for anonymous emote handling, and the resolved anonymity state.
            showBubble(player, msgData.message, msgData.channel, msgData.isDistant,
                msgData.characterName, msgData.isAnonymous, msgData.modality,
                msgData.playerColor)
        end
    end
    
    -- Boredom reduction for hearing others talk (not yourself)
    local boredomChannels = {say = true, yell = true, low = true, whisper = true}
    if boredomChannels[msgData.channel] then
        local localPlayer = getPlayer()
        local localUsername = localPlayer and localPlayer:getUsername()

        -- Only reduce boredom when hearing OTHERS, not yourself
        if localUsername and msgData.username ~= localUsername then
            reduceBoredom()
            dbg("onChatMessage: boredom reduction triggered (heard %s)", msgData.username)
        else
            dbg("onChatMessage: skipping boredom reduction (own message)")
        end
    end
    
    dbg("onChatMessage: done")
end

local function onRadioMessage(msgData)
    if not MC_Config.featureOn("RadioEnabled") then return end
    dbg("onRadioMessage: sender=%s freq=%s receiverType=%s",
        tostring(msgData.senderUsername), tostring(msgData.frequency),
        tostring(msgData.receiverType))
    
    if not msgData then
        dbg("onRadioMessage: nil msgData")
        return
    end
    
    local isSelfEcho = (msgData.receiverType == "self")
    if isSelfEcho then
        dbg("onRadioMessage: self-echo, chat only")
    end

    -- Deaf gate: radio is voice-only and disembodied -- there are
    -- no lips to read, so unlike face-to-face speech (which still gets a
    -- presence line or a gappy lipread render depending on sight/distance,
    -- see onChatMessage + MC_Anonymity.deafReception) a Deaf receiver gets
    -- NOTHING from radio at all: no chat line, no bubble, no boredom tick.
    -- The speaker's own self-echo is exempt -- this suppresses HEARING
    -- someone else's radio voice, not the courtesy reflection of what the
    -- Deaf player themselves just transmitted.
    if not isSelfEcho
       and MC_Config.liveSandbox("DeafTraitEnforced", true) ~= false
       and MC_Anonymity.localPlayerIsDeaf() then
        dbg("onRadioMessage: suppressed entirely for a Deaf receiver -- radio has no lips to read")
        return
    end

    -- Local carried-device veto: a B42.20 dedicated server drops Device
    -- Options state packets for non-hand (belt/bag) radios, so the server's
    -- receiver discovery can route a line through a carried radio this
    -- client already turned off or muted. The server stays authoritative
    -- for emitter existence and routing; this client is the only side that
    -- reliably sees its OWN carried device state at the instant of
    -- delivery -- the same subtractive boundary as the transmit-side
    -- emitter snapshot, pointed the other way. A "player" delivery is by
    -- definition this client's carried radio; ground and vehicle device
    -- state is server-owned and passes through untouched. Uncertain local
    -- discovery fails the radio branch closed, exactly like the transmit
    -- path (getAllPlayerRadios reports its own incidents on the
    -- unreliable read). Mic mute stays irrelevant to reception: canReceive
    -- checks power and audible volume only.
    if not isSelfEcho and msgData.receiverType == "player" then
        local locallyLive = false
        local okScan, radios, authoritative = pcall(
            MC_Radio.getAllPlayerRadios, getPlayer())
        if okScan and authoritative == true and type(radios) == "table" then
            for _, state in ipairs(radios) do
                if MC_Radio.canReceive(state)
                   and state.frequency == msgData.frequency then
                    locallyLive = true
                    break
                end
            end
        end
        if not locallyLive then
            dbg("onRadioMessage: no locally live carried radio on freq %s -- dropped",
                tostring(msgData.frequency))
            return
        end
    end

    -- Language tag. Same logic as onChatMessage: server only
    -- sends the tag once the receiver has identified the language.
    -- v8.5.1: when the server sent chunks (chunked radio render with packet
    -- loss applied to chunks), prepend the tag as a base chunk too so the
    -- ChatPanel render path sees the prefix in the chunk array, matching
    -- proximity-chat behaviour.
    if msgData.language and msgData.language ~= "" then
        local tag = MC_LangRegistry.displayName(msgData.language)
        local prefix = "[" .. tag .. "] "
        msgData.message = prefix .. (msgData.message or "")
        if msgData.chunks then
            table.insert(msgData.chunks, 1, { text = prefix })
        end
    end
    
    -- Resolve the radio identity once for every visible consumer. The current
    -- policy keeps it plain, but routing the bubble through the same scrub seam
    -- makes a later anonymous-radio policy fail closed without another leak.
    local radioPresentation = {
        username = msgData.senderUsername,
        characterName = msgData.senderCharacter,
        playerColor = msgData.playerColor
            or MC_Config.ChannelColors.radio
            or {120, 220, 200}
    }
    local radioSpeaker = getPlayerByUsername(msgData.senderUsername)
    MC_Anonymity.anonymizeRadioMessageData(radioPresentation, radioSpeaker)

    -- Add to chat panel
    if chatPanelHas("addMessage", "radio-message") then
        local panelData = {
            username = msgData.senderUsername,
            characterName = radioPresentation.characterName,
            message = msgData.message,
            chunks = msgData.chunks,  -- v8.5.1: chunked radio render
            channel = "radio",
            originalChannel = msgData.channel,
            frequency = msgData.frequency,
            -- The server derives this from the authenticated speaker's hue
            -- store. Keep the radio color only as compatibility for packets
            -- sent by an older server that did not include the field.
            playerColor = radioPresentation.playerColor
        }
        -- 0.9.x radio identity is deliberately plain: always retain the real
        -- character name supplied by the server. Mask/cross-cell radio
        -- anonymity returns only with the complete 0.10.x anonymity pass.
        MC_ChatPanel.addMessage(panelData)
    end
    
    -- Show bubble (skip self-echo)
    if not isSelfEcho then
        local bubbleChannels = {say = true, yell = true, low = true}
        if bubbleChannels[msgData.channel] then
            showRadioBubble(msgData, radioPresentation.playerColor)
        end
    end
    
    -- Radio chat reduces boredom (only when hearing others)
    local localPlayer = getPlayer()
    local localUsername = localPlayer and localPlayer:getUsername()
    if localUsername and msgData.senderUsername ~= localUsername then
        reduceBoredom()
        dbg("onRadioMessage: boredom reduction triggered (heard %s)", msgData.senderUsername)
    else
        dbg("onRadioMessage: skipping boredom reduction (own transmission)")
    end
    
    dbg("onRadioMessage: done")
end

-- COMMAND HANDLERS

local ClientCommands = {}

ClientCommands.ChatMessage = function(args)
    dbg("ClientCommands.ChatMessage")
    if not args then
        reportClientFailure("CLIENT_RENDER_FAILED", "chat-payload")
        return
    end
    onChatMessage(args)
end

ClientCommands.RadioMessage = function(args)
    dbg("ClientCommands.RadioMessage")
    if not args then
        reportClientFailure("CLIENT_RENDER_FAILED", "radio-payload")
        return
    end
    onRadioMessage(args)
end

ClientCommands.Typing = function(args)
    if not args then
        reportClientFailure("CLIENT_RENDER_FAILED", "typing-payload")
        return
    end
    dbg("ClientCommands.Typing from %s", tostring(args.username))
    local player = getPlayerByUsername(args.username)
    if player then
        showTyping(player)
    end
end

ClientCommands.SystemMessage = function(args)
    if not args or type(args.message) ~= "string" then
        reportClientFailure("CLIENT_RENDER_FAILED", "system-payload")
        return
    end
    dbg("ClientCommands.SystemMessage: %s", tostring(args.message))

    if not chatPanelHas("systemMessage", "system-message") then return end

    -- v8.9.2: forward server-provided chunks if present.
    -- author (optional): custom speaker label -- systemMessage validates it
    -- and falls back to "[MongooseChat]" rather than ever dropping the line.
    MC_ChatPanel.systemMessage(args.message,
        { color = args.color, chunks = args.chunks, author = args.author })
end

ClientCommands.ConnectionNotification = function(args)
    if MC_Config.liveSandbox("EnableConnectionNotifs", true) == false
        or MC_Config.liveSandbox("OOCEnabled", true) == false
        or MC_Config.liveSandbox("ChatWindowEnabled", true) == false then
        return
    end
    local fieldCount = 0
    local exactFields = type(args) == "table"
    if exactFields then
        for key in pairs(args) do
            fieldCount = fieldCount + 1
            if key ~= "kind" and key ~= "displayName" then
                exactFields = false
            end
        end
    end
    if not exactFields or fieldCount ~= 2
        or (args.kind ~= "join" and args.kind ~= "leave")
        or type(args.displayName) ~= "string"
        or args.displayName == "" or args.displayName:match("^%s*$") ~= nil
        or #args.displayName > 128
        or args.displayName:find("[%c]") ~= nil then
        reportClientFailure("CLIENT_RENDER_FAILED", "connection-notification")
        return
    end
    if not chatPanelHas("addMessage", "connection-notification") then return end
    local verb = args.kind == "join" and " connected." or " disconnected."
    MC_ChatPanel.addMessage({
        channel = "ooc",
        username = "system",
        characterName = "[SERVER]",
        message = args.displayName .. verb,
        timestamp = MC_Core.getTimeSeconds(),
        playerColor = {200, 200, 200},
    })
end

ClientCommands.IdentityColorSync = function(args)
    if not MC_IdentityColor.applySync(args) then
        MC_Incident.report("IDENTITY_COLOR_SYNC_INVALID", "packet rejected")
    else
        printOwnIdentityColorReceipt(args)
        if MC_IdentityColor.current() then identityColorSyncActive = false end
    end
end

ClientCommands.IdentityColorSnapshot = function(args)
    if not MC_IdentityColor.applySnapshot(args) then
        MC_Incident.report("IDENTITY_COLOR_SYNC_INVALID", "snapshot rejected")
    elseif MC_IdentityColor.current() then
        identityColorSyncActive = false
    end
end

-- ACQUISITION MOMENTS (v8.16.1)
-- 
-- The reward loop. The server emits AcquisitionMoment payloads whenever a
-- listener acquires new words; the payload carries milestone flags shaped
-- to the 8.17 spec (firstInLanguage, comprehension band crossings). This
-- handler fires quiet, immersive observations at the milestones that
-- matter -- not on every individual word (the per-word honey-gold render
-- bracket carries that signal), but on the moments that mark real shifts
-- in comprehension. The tone is internal observation, not game notification.

ClientCommands.AcquisitionMoment = function(args)
    if not args then
        reportClientFailure("CLIENT_RENDER_FAILED", "acquisition-payload")
        return
    end
    if not chatPanelHas("addMessage", "acquisition-moment") then return end

    local lang = args.language
    if type(lang) ~= "string" or lang == "" then
        reportClientFailure("CLIENT_RENDER_FAILED", "acquisition-language")
        return
    end
    local displayLang = MC_LangRegistry.displayName(lang)

    -- Quiet gold -- warm enough to read as positive, muted enough to sit
    -- below the honey-gold per-word reward in visual hierarchy.
    local momentColor = {210, 190, 140}

    -- First acquisition in this language: the moment the noise becomes
    -- speech. Ties to the language-identification gating -- the [Turkish]
    -- tag just appeared in their chat for the first time.
    if args.firstInLanguage then
        MC_ChatPanel.systemMessage(
            "You've learned your first word of " .. displayLang .. ".",
            { color = momentColor })
    end

    -- Comprehension band crossings (25%, 50%, 75% of core vocabulary).
    -- Each gets its own message; multiple bands crossing in one batch
    -- (unlikely but possible with teaching) fire sequentially.
    if args.bands then
        local bandMessages = {
            [25] = "You're starting to follow " .. displayLang .. ".",
            [50] = "You follow about half of " .. displayLang .. " now.",
            [75] = "You follow most of " .. displayLang .. " now.",
        }
        for _, band in ipairs(args.bands) do
            local msg = bandMessages[band]
            if msg then
                MC_ChatPanel.systemMessage(msg, { color = momentColor })
            end
        end
    end
end

local function OnServerCommand(module, command, args)
    if module ~= "MongooseChat" then return end
    
    dbg("OnServerCommand: %s", command)
    
    local handler = ClientCommands[command]
    if handler then
        local ok = pcall(handler, args)
        if not ok then
            MC_Incident.report("CLIENT_RENDER_FAILED",
                "command=" .. tostring(command))
        end
    elseif MC_Bio.handlesServerCommand(command) then
        -- Events.OnServerCommand broadcasts to every registered listener.
        -- MC_Bio owns identity packets and has already received this same
        -- delivery; treating them as unknown here creates a false incident on
        -- every join even though the character-sheet cache updated normally.
        dbg("OnServerCommand: delegated to MC_Bio (%s)", command)
    else
        MC_Incident.report("SERVER_COMMAND_UNHANDLED",
            "command=" .. tostring(command))
    end
end

-- CHAT PANEL SETUP

--[[
    Stand up MongooseChat's own chat window.

    Before 1.0 this built MC_ChatPanel as a CHILD of ISChat.instance and
    lived inside vanilla's frame. It now builds MC_ChatWindow, which owns
    its own frame, tab strip and text entry, and hosts the same panel.

    Vanilla ISChat is deliberately kept alive and hidden: it is still the
    Admin pipeline (access-level filtering is vanilla's, not ours) and
    still the server-welcome path. We show its window only while the
    player is standing on our own Admin tab.
]]
local function rememberVanillaView(view)
    if not view or vanillaViewState[view] then return end
    local state = {}
    local okVisible, visible = pcall(function() return view:isVisible() end)
    local okWidth, width = pcall(function() return view:getWidth() end)
    local okHeight, height = pcall(function() return view:getHeight() end)
    if okVisible then state.visible = visible == true end
    if okWidth and type(width) == "number" then state.width = width end
    if okHeight and type(height) == "number" then state.height = height end
    vanillaViewState[view] = state
end

local function rememberVanillaWindow(chat)
    if vanillaWindowState ~= nil or not chat then return end
    local ok, visible = pcall(function() return chat:isVisible() end)
    if ok then vanillaWindowState = { visible = visible == true }
    else vanillaWindowState = {} end
end

local function restoreVanillaViews()
    for view, state in pairs(vanillaViewState) do
        pcall(function()
            if state.width ~= nil then view:setWidth(state.width) end
            if state.height ~= nil then view:setHeight(state.height) end
            if state.visible ~= nil then view:setVisible(state.visible) end
        end)
    end
    vanillaViewState = {}

    local chat = ISChat and ISChat.instance or nil
    if chat and vanillaWindowState then
        pcall(function()
            if vanillaWindowState.visible ~= nil then
                chat:setVisible(vanillaWindowState.visible)
            end
        end)
    end
    vanillaWindowState = nil
end

local function createChatPanel()
    -- A disabled surface is not a fallback mode. Build nothing and leave
    -- vanilla untouched so another chat UI can own the space cleanly.
    if not MC_Config.featureOn("ChatWindowEnabled") then return true end

    if chatWindow then
        dbg("createChatPanel: already exists")
        return true
    end

    -- Vanilla still has to exist before we take over -- its live tab list is
    -- our Admin entitlement, and the addLineInChat seam depends on it.
    if not ISChat or not ISChat.instance then
        dbg("createChatPanel: ISChat not ready")
        return false
    end

    local chat = ISChat.instance

    if not chat.panel then
        dbg("createChatPanel: ISChat.panel not found")
        return false
    end

    -- Admin handoff: when our Admin tab is chosen, activate vanilla's
    -- verified Admin view, park vanilla's window inside our frame and put
    -- it on top; leaving the tab hides it again (suppressVanillaViews
    -- keeps that state every tick).
    -- 0.10.6: no vanilla surface anywhere, on any tab. The Admin tab is
    -- drawn by our own panel from verified OnAddMessage events,
    -- so vanilla's window is never parked, raised, or shown -- it stays
    -- hidden and simply holds the engine's tab list, which is still what
    -- tells us whether this player is staff at all.
    MC_ChatWindow.adminHandoff = function(_, _)
        local inst = ISChat and ISChat.instance
        if not inst then return end
        pcall(function() inst:setVisible(false) end)
    end
    MC_ChatWindow.adminRaise = nil

    chatWindow = MC_ChatWindow.create()
    if chatWindow and chatWindow.chatPanel then
        chatPanel = chatWindow.chatPanel
        dbg("createChatPanel: own window up, vanilla retained for Admin")
    else
        -- The window could not build on this client (an engine seam we do
        -- not have, a texture set missing). Chat must still work: host our
        -- panel inside vanilla's frame exactly as before 1.0. One incident,
        -- then this path is permanent for the session.
        chatWindow = nil
        if not MC_ChatWindow.unavailable then
            reportClientFailure("CLIENT_RENDER_FAILED", "chat-window-unavailable")
            return false
        end
        local panelX = 0
        local panelY = chat.panel:getY() + 20
        local panelW = chat.panel:getWidth()
        local panelH = chat.panel:getHeight() - 20
        chatPanel = MC_ChatPanel:new(panelX, panelY, panelW, panelH)
        chatPanel:initialise()
        chatPanel:setAnchorLeft(true)
        chatPanel:setAnchorRight(true)
        chatPanel:setAnchorTop(true)
        chatPanel:setAnchorBottom(true)
        chatPanel.background = true
        chatPanel.backgroundColor = { r = 0, g = 0, b = 0, a = 0.6 }
        chat:addChild(chatPanel)
        chatPanel:setVisible(true)
        chatPanel:bringToTop()
        dbg("createChatPanel: window unavailable; panel hosted in vanilla frame")
    end
    
    -- Hide every vanilla view except a semantically verified Admin tab.
    if chat.panel.viewList then
        for _, viewInfo in ipairs(chat.panel.viewList) do
            if viewInfo.view then
                rememberVanillaView(viewInfo.view)
                local isAdminView, adminAuthoritative =
                    verifiedAdminTabView(viewInfo.view)
                
                if not isAdminView and not adminAuthoritative then
                    reportAdminBoundary("create-view")
                end
                -- Every vanilla view is hidden, admin included: our stable
                -- OnAddMessage handler draws verified Admin traffic.
                dbg("createChatPanel: hiding vanilla view: %s",
                    tostring(viewInfo.name))
                viewInfo.view:setVisible(false)
                viewInfo.view:setHeight(0)
                viewInfo.view:setWidth(0)
            end
        end
    end
    
    local chatTextIsAdmin, chatTextAuthoritative =
        verifiedAdminTabView(chat.chatText)
    if chat.chatText then
        rememberVanillaView(chat.chatText)
        if not chatTextIsAdmin and not chatTextAuthoritative then
            reportAdminBoundary("create-active-view")
        end
        chat.chatText:setVisible(false)
        chat.chatText:setHeight(0)
    end
    
    dbg("createChatPanel: done")
    return true
end

local function suppressVanillaViews()
    if not ISChat or not ISChat.instance or not ISChat.instance.panel then return end
    
    local chat = ISChat.instance
    
    -- Staff-only Admin tab. The engine calls ISChat.onTabAdded once per tab
    -- THIS player is entitled to, so a verified admin view among vanilla's
    -- own tabs is the engine's own access answer -- no access-level string
    -- to guess at. Refreshed every tick so a mid-session grant or demotion
    -- lands; MC_ChatWindow fails closed when it is false.
    local adminAvailable = false
    for _, tab in ipairs(chat.tabs or {}) do
        local isAdminTab, tabAuthoritative = verifiedAdminTabView(tab)
        if isAdminTab and tabAuthoritative then
            adminAvailable = true
            break
        end
    end
    MC_ChatWindow.adminAvailable = adminAvailable

    -- Our own window owns tab selection now; vanilla's currentTabID is no
    -- longer the source of truth. MC_ChatWindow:setActiveTab already told
    -- MC_ChatPanel which tab it is on, so there is nothing to mirror.
    local onAdminTab
    if chatWindow then
        onAdminTab = (chatWindow.activeTab == MC_ChatPanel.TAB_ADMIN)
    else
        -- Fallback (no own window): vanilla's active view decides, as before.
        local isAdmin, authoritative = verifiedAdminTabView(chat.chatText)
        if not isAdmin and not authoritative then reportAdminBoundary("active-tab") end
        onAdminTab = isAdmin
        MC_ChatPanel.setCurrentTab(onAdminTab and MC_ChatPanel.TAB_ADMIN
            or MC_ChatPanel.TAB_LOCAL)
        if chatPanel then chatPanel:setVisible(not onAdminTab) end
    end

    if onAdminTab ~= lastLoggedTab then
        dbg("tab changed; admin=%s", tostring(onAdminTab))
        lastLoggedTab = onAdminTab
    end

    -- Vanilla's window never shows. Not on Admin, not anywhere: every
    -- line we are willing to draw is drawn by our own panel.
    if chatWindow then
        rememberVanillaWindow(chat)
        pcall(function() chat:setVisible(false) end)
    end
    
    -- Suppress every vanilla view except an exact canonical Admin stream.
    local viewList = ISChat.instance.panel.viewList
    if viewList then
        for _, viewInfo in ipairs(viewList) do
            if viewInfo.view then
                rememberVanillaView(viewInfo.view)
                local isAdminView, viewAuthoritative =
                    verifiedAdminTabView(viewInfo.view)
                
                if not isAdminView and not viewAuthoritative then
                    reportAdminBoundary("suppress-view")
                end
                -- Every vanilla view is suppressed, the Admin one included:
                -- our panel draws admin traffic now, so nothing of
                -- vanilla's may paint into the chat area.
                if viewInfo.view:isVisible() then
                    viewInfo.view:setVisible(false)
                end
                if viewInfo.view:getHeight() > 0 then
                    viewInfo.view:setHeight(0)
                    viewInfo.view:setWidth(0)
                end
            end
        end
    end
    
    -- Also suppress chatText, except while vanilla is legitimately
    -- hosted on the Admin tab AND chatText is the verified Admin view --
    -- that is the one view vanilla renders admin traffic into. Any other
    -- view (a non-staff client's General, or vanilla flipped to another
    -- tab while parked) stays hidden.
    if chat.chatText and chat.chatText:isVisible() then
        rememberVanillaView(chat.chatText)
        chat.chatText:setVisible(false)
        chat.chatText:setHeight(0)
    end
end

-- VANILLA CHAT HOOKS

MC_Client._suppressVanillaViews = suppressVanillaViews

local function hookVanillaChat()
    if not MC_Config.featureOn("ChatWindowEnabled") then return false end
    if vanillaChatHooked then return true end
    if not ISChat or not ISChat.instance then
        if vanillaChatExpected then
            MC_Incident.report("VANILLA_CHAT_HOOK_UNAVAILABLE",
                "ISChat instance unavailable; unresolved vanilla general chat cannot be trusted")
        end
        return false
    end
    
    local original_addLineInChat = ISChat.addLineInChat
    if type(original_addLineInChat) ~= "function" then
        if vanillaChatExpected then
            MC_Incident.report("VANILLA_CHAT_HOOK_UNAVAILABLE",
                "ISChat.addLineInChat unavailable; interception will retry")
        end
        return false
    end

    -- Admin is the only vanilla message type retained through the engine
    -- event. Every other line lacks MongooseChat's authoritative language,
    -- Deaf, modality, and identity decisions. Even a real getRadioChannel()
    -- proves transport only;
    -- it cannot prove that the payload passed those gates. Suppress and report
    -- rather than converting an unverified line into plausible IC speech.
    vanillaChatOriginal = original_addLineInChat
    vanillaChatWrapper = function(arg1, arg2, arg3)
        -- If another mod wrapped this function after us, we cannot safely pull
        -- our closure out of the middle of its chain. The live check makes that
        -- rare retained wrapper a plain pass-through while our feature is Off.
        if not MC_Config.featureOn("ChatWindowEnabled") then
            return original_addLineInChat(arg1, arg2, arg3)
        end
        if looksLikeChatMessage(arg1) then
            local isAdmin, adminAuthoritative =
                verifiedAdminMessage(arg1, arg2)
            if isAdmin then
                -- Events.OnAddMessage is the sole Admin render owner. A saved
                -- vanilla listener may still call this replaced table slot;
                -- suppress it here so no direct path can paint twice.
                return
            end
            if not adminAuthoritative then
                reportAdminBoundary("message-object")
                return
            end

            local radioChannel = MC_Core.safe(function()
                return arg1:getRadioChannel()
            end, nil)
            if type(radioChannel) == "number" and radioChannel ~= -1 then
                MC_Incident.report("VANILLA_RADIO_UNVERIFIED",
                    "radio transport bypassed authoritative chat rendering")
            else
                MC_Incident.report("VANILLA_CHAT_UNVERIFIED",
                    "non-admin vanilla message object suppressed")
            end
            return
        end

        if type(arg1) == "string"
            or arg1 == ISChat.instance
            or (type(arg1) == "table" and arg1.tabCnt)
        then
            MC_Incident.report("VANILLA_CHAT_UNVERIFIED",
                "string/method chat line suppressed")
            return
        end

        MC_Incident.report("VANILLA_CHAT_SHAPE_UNKNOWN",
            "addLineInChat arg1 type=" .. tostring(type(arg1)))
        return
    end
    ISChat.addLineInChat = vanillaChatWrapper

    vanillaChatHooked = true
    dbg("Vanilla chat hook installed")
    return true
end

local function unhookVanillaChat()
    if not vanillaChatHooked then return true end
    if ISChat and ISChat.addLineInChat == vanillaChatWrapper
        and type(vanillaChatOriginal) == "function" then
        ISChat.addLineInChat = vanillaChatOriginal
        vanillaChatHooked = false
        vanillaChatOriginal = nil
        vanillaChatWrapper = nil
        dbg("Vanilla chat hook removed")
        return true
    end
    -- A later wrapper owns the table slot. Do not overwrite it. Our retained
    -- closure is inert while Off and becomes live again if the host re-enables
    -- the feature.
    return false
end

local function disableChatSurface()
    local oldPanel = chatPanel
    if chatWindow then
        MC_ChatWindow.destroy()
    elseif oldPanel then
        pcall(function() oldPanel:setVisible(false) end)
        local chat = ISChat and ISChat.instance or nil
        if chat and type(chat.removeChild) == "function" then
            pcall(function() chat:removeChild(oldPanel) end)
        end
        pcall(function() oldPanel:removeFromUIManager() end)
    end
    if MC_ChatPanel.instance == oldPanel then MC_ChatPanel.instance = nil end
    chatPanel = nil
    chatWindow = nil
    panelCreated = false
    lastLoggedTab = nil
    MC_ChatWindow.adminAvailable = false
    MC_ChatWindow.adminHandoff = nil
    unhookVanillaChat()
    uninstallAdminMessageHandler()
    restoreVanillaViews()
end

MC_Client._hookVanillaChatForTest = hookVanillaChat
MC_Client._disableChatSurfaceForTest = disableChatSurface

-- EVENT HANDLERS

local function OnTickBody()
    if identityColorSyncActive then
        local now = MC_Core.safe(function() return MC_Core.getTimeMs() end, 0)
        if now >= identityColorSyncNextAt then requestOwnIdentityColor(now) end
    end
    if not MC_Config.featureOn("ChatWindowEnabled") then
        disableChatSurface()
        cleanupUI()
        return
    end
    if not panelCreated then
        if createChatPanel() then
            panelCreated = true
        end
    end
    
    hookVanillaChat()
    installAdminMessageHandler(adminMessageForceRebind)
    
    if panelCreated then
        suppressVanillaViews()
    end
    
    cleanupUI()
end
MC_Client._onTickBodyForTest = OnTickBody

-- PZ's event dispatch aborts the remaining handlers when one throws, so an
-- unguarded error here would starve every mod registered after us on the
-- shared OnTick. MC_Core.safeExec swallows into a rate-limited incident.
local function OnTick()
    local ok = MC_Core.safeExec(OnTickBody)
    if not ok then
        reportClientFailure("CLIENT_TICK_FAILED", "client-ontick")
    end
end

local function reloadSandboxBoundary(stage)
    local ok, authoritative = pcall(MC_Config.reloadSandboxVars)
    if not ok then
        reportClientFailure("SANDBOX_RELOAD_FAILED",
            tostring(stage or "unknown") .. "-exception")
        return false
    end
    if type(authoritative) ~= "boolean" then
        reportClientFailure("SANDBOX_RELOAD_FAILED",
            tostring(stage or "unknown") .. "-invalid-result")
        return false
    end
    -- A verified `false` is already reported by MC_Config as
    -- SANDBOX_CONFIG_FALLBACK, with its per-key detail. Do not double-report
    -- that known degraded state here; this boundary owns exceptions and broken
    -- return contracts.
    return authoritative
end

local function applyInputLimitBoundary(stage)
    local ok, applied = pcall(MC_Input.applyChatBoxMaxLength)
    if not ok then
        reportClientFailure("CHAT_INPUT_LIMIT_UNAVAILABLE",
            tostring(stage or "unknown") .. "-exception")
        return false
    end
    if type(applied) ~= "boolean" then
        reportClientFailure("CHAT_INPUT_LIMIT_UNAVAILABLE",
            tostring(stage or "unknown") .. "-invalid-result")
        return false
    end
    -- MC_Input reports the concrete inability before returning false.
    return applied
end

MC_Client._reloadSandboxBoundary = reloadSandboxBoundary
MC_Client._applyInputLimitBoundary = applyInputLimitBoundary

local function OnGameStart()
    -- Pull the server's actual sandbox config into MC_Config.
    -- MC_Config loaded with defaults before SandboxVars was populated; this is
    -- what makes server-configured ranges/toggles actually take effect.
    reloadSandboxBoundary("game-start")

    MC_Core.printBanner()
    dbg("=== CLIENT MODULE LOADED ===")
end

-- WELCOME MESSAGE INJECTION
-- Vanilla injects ServerWelcomeMessage into ISRichTextPanel which we suppress.
-- We need to grab it and inject into our panel instead.

local pendingWelcomeHandler = nil  -- Holds the OnTick closure while we wait

local function notifyPanelSessionReset()
    if type(MC_ChatPanel.onSessionReset) ~= "function" then return end
    local ok = pcall(MC_ChatPanel.onSessionReset)
    if not ok then
        MC_Incident.report("CHAT_SESSION_RESET_HOOK_FAILED",
            "connection reset hook failed")
    end
end

local function OnConnected()
    dbg("OnConnected fired")
    adminMessageForceRebind = true
    MC_IdentityColor.clear()
    identityColorReceiptGeneration = nil
    identityColorReceiptRevision = nil
    notifyPanelSessionReset()
    beginOwnIdentityColorSync()

    -- Pick up the server's sandbox config. By the time OnConnected fires, the
    -- sandbox handshake has completed and SandboxVars.MongooseChat is populated
    -- with server values. This is the most reliable point to refresh MC_Config.
    reloadSandboxBoundary("connected")

    -- The chat input box is hooked (and its max length set) before this sync
    -- lands, so re-apply now that the server's MaxMessageLength is in MC_Config.
    MC_Input.markChatBoxMaxLengthPending()
    applyInputLimitBoundary("connected")

    -- If a previous OnConnected already queued a welcome handler that hasn't
    -- fired yet, remove it. Prevents multiple handlers stacking if OnConnected
    -- fires twice in rapid succession (reconnect-in-session). This is the
    -- actual C14 fix; no flag needed -- the queued handler is the state.
    if pendingWelcomeHandler then
        local removed = MC_Core.safeExec(function()
            Events.OnTick.Remove(pendingWelcomeHandler)
        end)
        if not removed then
            reportClientFailure("WELCOME_MESSAGE_FAILED",
                "remove-stale-handler")
            return
        end
        pendingWelcomeHandler = nil
    end

    -- Vanilla owns its own welcome line while MC's chat surface is handed
    -- off. Do not duplicate it into MC's hidden transcript or keep a timer.
    if not MC_Config.featureOn("ChatWindowEnabled") then return end

    -- Small delay to ensure our panel exists
    local ticksToWait = 60  -- ~1 second
    local tickCount = 0
    local completed = false
    
    local function tryShowWelcome()
        if completed then return end
        tickCount = tickCount + 1
        if tickCount < ticksToWait then return end
        completed = true

        -- Remove this tick handler and clear the pending reference
        local removed = MC_Core.safeExec(function()
            Events.OnTick.Remove(tryShowWelcome)
        end)
        if not removed then
            reportClientFailure("WELCOME_MESSAGE_FAILED",
                "remove-handler")
        end
        pendingWelcomeHandler = nil
        
        -- Get the welcome message from server options
        local welcomeText = nil
        local readOK = MC_Core.safeExec(function()
            -- ServerOptions/options are Java bridge objects in live PZ; do
            -- not require Lua's type() to call them "table"/"function".
            -- Presence plus the protected invocation below is the reliable
            -- compatibility check across Kahlua builds.
            if not ServerOptions or not ServerOptions.getInstance then
                error("server options API unavailable")
            end
            local options = ServerOptions.getInstance()
            if not options or not options.getOptionByName then
                error("server options instance unavailable")
            end
            local welcomeOption = options:getOptionByName("ServerWelcomeMessage")
            if not welcomeOption or not welcomeOption.getValue then
                error("welcome option unavailable")
            end
            welcomeText = welcomeOption:getValue()
            if type(welcomeText) ~= "string" then
                error("welcome option returned non-string")
            end
        end)
        if not readOK then
            reportClientFailure("WELCOME_MESSAGE_FAILED", "read-option")
            return
        end
        
        if welcomeText == "" then
            dbg("OnConnected: no welcome message configured")
            return
        end
        
        local displayOK = MC_Core.safeExec(function()
            dbg("OnConnected: injecting welcome message (%d chars)", #welcomeText)

            -- Convert <LINE> tags to newlines for our panel
            -- Convert <RGB:r,g,b> tags (we'll strip them for now, could parse later)
            local cleanText = welcomeText
            cleanText = cleanText:gsub("<LINE>", "\n")
            cleanText = cleanText:gsub("<RGB:[%d,.]+>", "")  -- Strip color tags for now
            cleanText = cleanText:gsub("<[^>]+>", "")  -- Strip any other tags

            -- Split by newlines and add each line as a system message
            local lines = {}
            for line in cleanText:gmatch("[^\n]+") do
                local trimmed = line:match("^%s*(.-)%s*$")
                if trimmed and trimmed ~= "" then
                    table.insert(lines, trimmed)
                end
            end
            
            -- Add to our chat panel as server/system messages
            if #lines > 0 then
                if not MC_ChatPanel
                    or type(MC_ChatPanel.addMessage) ~= "function"
                then
                    error("chat panel unavailable")
                end
                -- Add a header line
                MC_ChatPanel.addMessage({
                    channel = "system",
                    username = "server",
                    characterName = "[SERVER]",
                    message = "=== Welcome Message ===",
                    timestamp = MC_Core.getTimeSeconds(),
                    playerColor = {200, 200, 200},
                })

                for _, line in ipairs(lines) do
                    MC_ChatPanel.addMessage({
                        channel = "system",
                        username = "server",
                        characterName = "[SERVER]",
                        message = line,
                        timestamp = MC_Core.getTimeSeconds(),
                        playerColor = {200, 200, 200},
                    })
                end
            end
        end)
        if not displayOK then
            reportClientFailure("WELCOME_MESSAGE_FAILED", "display")
        end
    end
    
    pendingWelcomeHandler = tryShowWelcome
    local added = MC_Core.safeExec(function()
        Events.OnTick.Add(tryShowWelcome)
    end)
    if not added then
        pendingWelcomeHandler = nil
        reportClientFailure("WELCOME_MESSAGE_FAILED", "add-handler")
    end
end


local function OnDisconnected()
    MC_IdentityColor.clear()
    identityColorReceiptGeneration = nil
    identityColorReceiptRevision = nil
    notifyPanelSessionReset()
    lastIdentityColorRepair = -IDENTITY_COLOR_REPAIR_COOLDOWN_MS
    identityColorSyncActive = false
    identityColorSyncRequests = 0
    identityColorSyncNextAt = 0
    identityColorSyncExhaustedReported = false
end


local function OnChatWindowInit()
    vanillaChatExpected = true
    if MC_Config.featureOn("ChatWindowEnabled") then hookVanillaChat() end
end

MC_Client._onChatWindowInitForTest = OnChatWindowInit

-- INITIALIZATION

Events.OnServerCommand.Add(OnServerCommand)
Events.OnTick.Add(OnTick)
Events.OnGameStart.Add(OnGameStart)
Events.OnConnected.Add(OnConnected)
if Events.OnDisconnect then Events.OnDisconnect.Add(OnDisconnected) end
if Events.OnChatWindowInit then
    Events.OnChatWindowInit.Add(OnChatWindowInit)
end

return MC_Client
