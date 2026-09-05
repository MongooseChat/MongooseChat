--[[ ==========================================================================
    MC_LangAdmin.lua -- client-side admin context menu for native-language
    assignment. (v8.4 "Native Speakers")
    
    Right-clicking another player as an admin opens a "Languages >" submenu.
    Each registered non-English language gets two entries:
        Grant Native:  <Language>
        Revoke Native: <Language>
    
    The client doesn't track each player's native set -- it doesn't need to.
    Sending a redundant grant (player already has it) or a revoke for a
    language they don't have is harmless: the server reports the no-op state
    in the confirmation SystemMessage, and the admin sees what actually
    happened.
    
    Server is authoritative on:
      - the admin gate (client-side check is UX only; never trust the client)
      - the language-validity check
      - the actual mutation of MC_Lang's native set
    
    Sends ClientCommand "GrantLanguage" / "RevokeLanguage" to MC_Server's
    ServerCommands dispatch. Args: { target = <username>, language = <id> }.

    Also hosts the TOTAL WIPE entry ("Wipe ALL Their MongooseChat Data..."),
    which talks to MC_Lang's own listener on module "MongooseChatLang"
    (command "WipeAll") and is guarded by a type-their-username dialog --
    see the Total wipe section below.
========================================================================== ]]

local MC_Core         = require("MC_Core")
local MC_LangRegistry = require("MC_LangRegistry")
local MC_Bio          = require("MC_Bio")
local MC_Incident     = require("MC_Incident")
local MC_Config       = require("MC_Config")
local MC_PageClose    = require("MC_PageClose")

local dbg = MC_Core.debugger("LANGADMIN")

local function reportOperation(code, operation)
    MC_Incident.report(code or "LANGADMIN_OPERATION_FAILED",
        "operation=" .. tostring(operation or "unknown"))
end

-- Keep the fail-closed defaults used by the UI gate, but make every
-- substitution observable. A missing current player still refuses the menu;
-- a missing screen dimension can still use a safe layout default; neither is
-- allowed to masquerade as a successful engine read.
local function safeGet(operation, fn, default)
    local ok, value = pcall(fn)
    if ok and value ~= nil then return value, true end
    dbg("safeGet error (%s): %s", tostring(operation), tostring(value))
    reportOperation("LANGADMIN_OPERATION_FAILED", operation)
    return default, false
end

local function safeExec(operation, fn, code)
    local ok, err = MC_Core.safeExec(fn)
    if not ok then
        dbg("safeExec error (%s): %s", tostring(operation), tostring(err))
        reportOperation(code or "LANGADMIN_OPERATION_FAILED", operation)
    end
    return ok
end

-- Local, client-only line into the chat panel (no server round trip).
-- Lazy require mirrors MC_Input's pattern. If the panel isn't up yet the
-- failure is reported instead of silently discarding the only local feedback.
local function localLine(message, color)
    safeExec("local-feedback", function()
        local MC_ChatPanel = require("MC_ChatPanel")
        if not MC_ChatPanel
            or type(MC_ChatPanel.systemMessage) ~= "function"
        then
            error("chat panel system-message API unavailable")
        end
        MC_ChatPanel.systemMessage(message, { color = color })
    end)
end

-- Action callbacks. The first arg passed by the context menu is the
-- argument we registered with addOption -- we pack target+lang into a table.
local function onGrant(arg)
    if not arg or type(arg) ~= "table" then
        reportOperation("LANGADMIN_OPERATION_FAILED", "grant-invalid-argument")
        return
    end
    safeExec("grant-send", function()
        sendClientCommand("MongooseChat", "GrantLanguage", {
            target   = arg.target,
            language = arg.language,
        })
    end)
end

local function onRevoke(arg)
    if not arg or type(arg) ~= "table" then
        reportOperation("LANGADMIN_OPERATION_FAILED", "revoke-invalid-argument")
        return
    end
    safeExec("revoke-send", function()
        sendClientCommand("MongooseChat", "RevokeLanguage", {
            target   = arg.target,
            language = arg.language,
        })
    end)
end

-- Total wipe (/lang resetall from the context menu)
--
-- The disaster this dialog is designed against is an irreversible wipe landing
-- on the WRONG player -- an exact-match refusal guards against two players
-- sharing a forename, or a mistyped/misremembered one. Three defenses:
--   1. The target comes from the clicked IsoPlayer's own getUsername() --
--      exact store key, no forename guessing.
--   2. The dialog shows the resolved CHARACTER name next to the username, so
--      the admin confirms a person, not a string.
--   3. Confirming requires TYPING the username exactly -- a click is too
--      cheap for something this permanent. Mismatch = nothing happens.
-- The wipe itself goes over "MongooseChatLang"/"WipeAll" (MC_Lang's own
-- OnClientCommand listener); the server re-checks the admin gate and prints
-- the store-by-store preview/report back as SystemMessages.

local function onWipeAllDialogClick(arg, button)
    local modal = button and button.parent or nil
    if modal then MC_PageClose.unregister(modal) end
    if not arg or type(arg) ~= "table" or not button then
        reportOperation("LANGADMIN_OPERATION_FAILED",
            "wipe-confirm-invalid-argument")
        return
    end
    local internal = safeGet("confirmation-button",
        function() return button.internal end, nil)
    if internal ~= "OK" then return end
    local typed = safeGet("confirmation-text",
        function() return button.parent.entry:getText() end, nil)
    if type(typed) ~= "string" then typed = "" end
    typed = typed:match("^%s*(.-)%s*$") or ""
    if typed ~= arg.target then
        localLine("That doesn't match " .. arg.display .. "'s username exactly -- " ..
            "nothing was touched.", {255, 200, 100})
        return
    end
    safeExec("wipe-confirm-send", function()
        sendClientCommand("MongooseChatLang", "WipeAll", {
            target  = arg.target,
            confirm = true,
        })
    end)
end

local function onWipeAll(arg)
    if not arg or type(arg) ~= "table" then
        reportOperation("LANGADMIN_OPERATION_FAILED", "wipe-invalid-argument")
        return
    end
    -- Preview first: the server prints the store-by-store cost of the wipe
    -- into the admin's chat, so it's on screen while the dialog is up.
    local previewSent = safeExec("wipe-preview-send", function()
        sendClientCommand("MongooseChatLang", "WipeAll", {
            target  = arg.target,
            confirm = false,
        })
    end)
    if not previewSent then return end

    if not ISTextBox then
        -- No dialog class available: fall back to the chat command, which
        -- carries the same two-step protection. This remains usable, but the
        -- degraded UI boundary is always reported to operators.
        reportOperation("LANGADMIN_DIALOG_UNAVAILABLE", "class-unavailable")
        localLine('No dialog available here -- use: /lang resetall "' ..
            arg.target .. '" and read the preview before confirming.', {255, 200, 100})
        return
    end

    local dialogShown = safeExec("dialog-create", function()
        local w, h = 460, 130
        local screenW = safeGet("screen-width",
            function() return getCore():getScreenWidth() end, 1280)
        local screenH = safeGet("screen-height",
            function() return getCore():getScreenHeight() end, 720)
        local prompt = "Erase everything MongooseChat remembers about " ..
            arg.display .. "? This cannot be undone. " ..
            "Type their username (" .. arg.target .. ") to confirm."
        -- Vanilla ISTextBox invokes onclick(self.target, button, ...), so the
        -- packed arg table rides in the `target` slot.
        local modal = ISTextBox:new((screenW - w) / 2, (screenH - h) / 2, w, h,
            prompt, "", arg, onWipeAllDialogClick, arg.playerIndex)
        modal:initialise()
        modal:addToUIManager()
        local originalPrerender = modal.prerender
        modal.prerender = function(self, ...)
            if not MC_Config.featureOn("LanguagesEnabled") then
                MC_PageClose.unregister(self)
                self:destroy()
                return
            end
            if originalPrerender then return originalPrerender(self, ...) end
        end
        MC_PageClose.register(modal, {
            live = function(root)
                local visible = true
                if type(root.getIsVisible) == "function" then
                    visible = root:getIsVisible() == true
                end
                return visible and MC_Config.featureOn("LanguagesEnabled")
            end,
            close = function(root)
                root:destroy()
                MC_PageClose.unregister(root)
                return true
            end,
        })
    end, "LANGADMIN_DIALOG_UNAVAILABLE")
    if not dialogShown then
        localLine('The confirmation dialog failed -- use: /lang resetall "' ..
            arg.target .. '" and read the preview before confirming.', {255, 200, 100})
    end
end

-- Find an IsoPlayer under the cursor. Shared with MC_Bio.onContextMenu's
-- own resolution -- walks worldObjects -> square -> movingObjects.
local findClickedPlayer = MC_Bio._findClickedPlayer

local function onContextMenu(playerIndex, context, worldObjects, test)
    if test then return true end

    local self = safeGet("current-player",
        function() return getSpecificPlayer(playerIndex) end, nil)
    if not self then return end

    -- Admin gate (UX only -- server validates again). PZ access levels
    -- aren't reliably lowercase (this file's own fallback default above is
    -- capitalized "None"); normalize before comparing, same as
    -- Other server-side admin gates.
    local accessLevel = safeGet("access-level",
        function() return self:getAccessLevel() end, "None")
    accessLevel = tostring(accessLevel or "None"):lower()
    if accessLevel ~= "admin" then return end

    local clickedOK, clickedPlayer = pcall(findClickedPlayer, worldObjects)
    if not clickedOK then
        reportOperation("LANGADMIN_OPERATION_FAILED", "clicked-player")
        return
    end
    if not clickedPlayer then return end

    local targetUsername = safeGet("target-username",
        function() return clickedPlayer:getUsername() end, nil)
    if not targetUsername then return end

    -- Targeting yourself works too -- useful for testing or self-promotion.
    local targetDisplay = safeGet("target-display", function()
        return MC_Bio._getCharacterName(clickedPlayer, targetUsername)
    end, targetUsername)

    -- Top-level "Languages >" entry.
    local langsOK, langs = pcall(MC_LangRegistry.listLanguages)
    if not langsOK or type(langs) ~= "table" then
        reportOperation("LANGADMIN_OPERATION_FAILED", "language-list")
        return
    end
    -- Filter out English (universal baseline, not assignable).
    local assignable = {}
    for _, lang in ipairs(langs) do
        if lang ~= "english" then table.insert(assignable, lang) end
    end
    if #assignable == 0 then return end  -- nothing to assign

    safeExec("context-menu-build", function()
        local topOption = context:addOption("Languages (" .. targetDisplay .. ")", nil, nil)
        local subMenu = ISContextMenu:getNew(context)
        context:addSubMenu(topOption, subMenu)

        -- For each language, add Grant + Revoke. No checkmark state because
        -- the client doesn't track it -- admins can read confirmation chat.
        for _, lang in ipairs(assignable) do
            local displayLang = MC_LangRegistry.displayName(lang)
            subMenu:addOption("Grant Native: " .. displayLang,
                { target = targetUsername, language = lang }, onGrant)
            subMenu:addOption("Revoke Native: " .. displayLang,
                { target = targetUsername, language = lang }, onRevoke)
        end

        -- The total wipe, deliberately LAST -- past every grant/revoke pair
        -- and behind a type-their-username dialog (see onWipeAll above).
        subMenu:addOption("Wipe ALL Their MongooseChat Data...", {
            target      = targetUsername,
            display     = targetDisplay,
            playerIndex = playerIndex,
        }, onWipeAll)
    end)
end

safeExec("event-registration",
    function() Events.OnFillWorldObjectContextMenu.Add(onContextMenu) end)

return {
    onContextMenu = onContextMenu,
    _onWipeAllForTest = onWipeAll,
}
