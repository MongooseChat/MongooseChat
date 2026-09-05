--[[
================================================================================
    MongooseChat - Language Command Surface

    Every player/admin-facing /lang subcommand, plus /lex, /comp, and /forget.
    MC_Lang.lua (required below) owns the language-state
    model and the render/babble engine; this module owns everything a
    person types. A handful of MC_Lang internals that the engine also
    still uses are reached through leading-underscore exposures on MC_Lang
    rather than duplicated here -- see the "Internal contract" comments at
    each one's definition in MC_Lang.lua.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Lang = require("MC_Lang")
local MC_Core = require("MC_Core")
local MC_Config = require("MC_Config")
local MC_LangRegistry = require("MC_LangRegistry")
local MC_Acquisition = require("MC_Acquisition")
local MC_Resolve = require("MC_Resolve")
local MC_Incident = require("MC_Incident")

local MC_LangCommands = {}

local dbg = MC_Core.debugger("LANG")

local MAX_USERNAME_LENGTH = 64
local MAX_ROSTER_SIZE = 10000

local INCIDENT = {
    adminAuthority = "LANG_ADMIN_AUTHORITY_UNAVAILABLE",
    identity = "LANG_COMMAND_IDENTITY_UNAVAILABLE",
    roster = "LANG_ROSTER_UNAVAILABLE",
    state = "LANG_COMMAND_STATE_UNAVAILABLE",
    target = "LANG_TARGET_INVALID",
}

local function reportBoundary(code, command, stage)
    MC_Incident.report(code,
        "command=" .. tostring(command or "unknown")
            .. " stage=" .. tostring(stage or "unknown"))
end

local function validIdentityString(value)
    return type(value) == "string"
        and value ~= ""
        and value:find("%S") ~= nil
        and #value <= MAX_USERNAME_LENGTH
        and value:find("[%c]") == nil
end

-- Resolve an exact, complete snapshot of the online roster. Targeted language
-- mutations must never turn "the roster could not be read" into "that person
-- is offline", nor skip one unreadable record and accidentally make a common
-- forename look unique.
local function onlineTargetRecords(command, nameMode)
    local rosterOk, onlinePlayers = pcall(getOnlinePlayers)
    if not rosterOk or not onlinePlayers then
        reportBoundary(INCIDENT.roster, command, "list")
        return nil
    end

    local sizeOk, size = pcall(function() return onlinePlayers:size() end)
    if not sizeOk or type(size) ~= "number" or size ~= size
        or size <= -math.huge or size >= math.huge
        or size < 0 or size ~= math.floor(size)
        or size > MAX_ROSTER_SIZE then
        reportBoundary(INCIDENT.roster, command, "size")
        return nil
    end

    local records = {}
    for i = 0, size - 1 do
        local playerOk, targetPlayer =
            pcall(function() return onlinePlayers:get(i) end)
        if not playerOk or not targetPlayer then
            reportBoundary(INCIDENT.roster, command, "entry")
            return nil
        end

        local usernameOk, username =
            pcall(function() return targetPlayer:getUsername() end)
        if not usernameOk or not validIdentityString(username) then
            reportBoundary(INCIDENT.roster, command, "identity")
            return nil
        end

        local descriptor
        local forename, surname = "", ""
        if nameMode ~= nil then
            local descriptorOk
            descriptorOk, descriptor =
                pcall(function() return targetPlayer:getDescriptor() end)
            if not descriptorOk or not descriptor then
                reportBoundary(INCIDENT.roster, command, "identity")
                return nil
            end

            local forenameOk
            forenameOk, forename =
                pcall(function() return descriptor:getForename() end)
            if not forenameOk or not validIdentityString(forename) then
                reportBoundary(INCIDENT.roster, command, "character-name")
                return nil
            end

            if nameMode == "full-name" then
                local surnameOk
                surnameOk, surname =
                    pcall(function() return descriptor:getSurname() end)
                if not surnameOk
                    or (surname ~= nil and surname ~= ""
                        and (type(surname) ~= "string"
                            or surname:find("[%c]") ~= nil
                            or #surname > MAX_USERNAME_LENGTH)) then
                    reportBoundary(INCIDENT.roster, command, "character-name")
                    return nil
                end
                surname = surname or ""
            end
        end

        records[#records + 1] = {
            player = targetPlayer,
            username = username,
            forename = forename,
            surname = surname,
            descriptor = descriptor,
        }
    end
    return records
end

local function requireRosterSurnames(records, command)
    for _, rec in ipairs(records) do
        local surnameOk, surname =
            pcall(function() return rec.descriptor:getSurname() end)
        if not surnameOk
            or (surname ~= nil and surname ~= ""
                and (type(surname) ~= "string"
                    or surname:find("[%c]") ~= nil
                    or #surname > MAX_USERNAME_LENGTH)) then
            reportBoundary(INCIDENT.roster, command, "character-name")
            return false
        end
        rec.surname = surname or ""
    end
    return true
end

-- /lang COMMAND
-- 
-- Single command, two access tiers:
--   /lang <language>             -> self-set (any player)
--   /lang "<character>" <lang>   -> admin-set on target character (admin only)
--   /lang <character> <lang>     -> same, unquoted (works for single-word names)
-- 
-- The admin check fires only when a target name is supplied (two-arg form).
-- A non-admin typing the two-arg form gets denied; the one-arg form always
-- works for self-set.
-- 
-- Target resolution: forename or full "Forename Surname" match against the
-- online roster, case-insensitive. Targets must currently be online. (There
-- is no offline-edit path anymore: saves live in generation-stamped A/B slot
-- files. Use the admin commands.)

-- /lang COMMAND DISPATCHER (v8.4)
-- 
-- Subcommands:
--   /lang <language>                      -> self-set speaking (any player)
--   /lang "<character>" <lang>            -> admin set target's speaking
--   /lang <character> <lang>              -> same, unquoted (single-word names)
--   /lang grant <character> <lang>        -> admin grant native (v8.4)
--   /lang revoke <character> <lang>       -> admin revoke native (v8.4)
-- 
-- The dispatcher peeks at the first token. "grant" and "revoke" route to
-- the native-status handlers. Everything else falls through to the existing
-- self-set/admin-set-speaking behaviour.
-- 
-- Target resolution: forename or full "Forename Surname" match against the
-- online roster, case-insensitive. Targets must currently be online. (There
-- is no offline-edit path anymore: saves live in generation-stamped A/B slot
-- files. Use the admin commands.)

local function resolveTargetByName(targetName, command)
    if not validIdentityString(targetName) then
        reportBoundary(INCIDENT.target, command, "target")
        return nil, nil, "invalid"
    end
    local records = onlineTargetRecords(command, "forename")
    if not records then return nil, nil, "unavailable" end

    -- An exact account username is the unambiguous escape hatch when two
    -- characters share a forename or even the same full character name.
    local usernameMatches = {}
    for _, rec in ipairs(records) do
        if rec.username == targetName then
            usernameMatches[#usernameMatches + 1] = rec
        end
    end
    if #usernameMatches == 1 then
        local rec = usernameMatches[1]
        return rec.username, rec.forename, "exact"
    elseif #usernameMatches > 1 then
        return nil, nil, "ambiguous"
    end

    local needsSurname = targetName:find("%s") ~= nil
    if needsSurname and not requireRosterSurnames(records, command) then
        return nil, nil, "unavailable"
    end

    local needle = targetName:lower()
    local matches = {}
    for _, rec in ipairs(records) do
        local matched = rec.forename:lower() == needle
        if not matched and needsSurname and rec.surname ~= "" then
            matched = (rec.forename .. " " .. rec.surname):lower() == needle
        end
        if matched then
            matches[#matches + 1] = rec
        end
    end
    if #matches == 1 then
        local rec = matches[1]
        return rec.username, rec.forename, "exact"
    elseif #matches > 1 then
        return nil, nil, "ambiguous"
    end
    return nil, nil, "not-found"
end

local function resolveTargetByUsername(username, command)
    if not validIdentityString(username) then
        reportBoundary(INCIDENT.target, command, "target")
        return nil, nil, "invalid"
    end
    local records = onlineTargetRecords(command, "forename")
    if not records then return nil, nil, "unavailable" end
    local match = nil
    for _, rec in ipairs(records) do
        if rec.username == username then
            if match then return nil, nil, "ambiguous" end
            match = rec
        end
    end
    if not match then return nil, nil, "not-found" end
    return match.player, match.forename, "exact"
end

-- Common parse for "<target> <language>" with optional quoted target.
-- Returns (target, language) or (nil, nil) on parse failure.
local function parseTargetAndLanguage(argString)
    local target, language = argString:match('^%s*"([^"]+)"%s+(%S+)%s*$')
    if not target then
        target, language = argString:match('^%s*(%S+)%s+(%S+)%s*$')
    end
    return target, language
end

local function sysMsgRed(player, msg)
    sendServerCommand(player, "MongooseChat", "SystemMessage", {
        message = msg, color = {255, 100, 100}
    })
end
local function sysMsgGreen(player, msg)
    sendServerCommand(player, "MongooseChat", "SystemMessage", {
        message = msg, color = {100, 255, 100}
    })
end

local function requirePlayerUsername(player, command)
    if not player then
        reportBoundary(INCIDENT.identity, command, "player")
        return nil
    end
    local ok, username = pcall(function() return player:getUsername() end)
    if not ok or not validIdentityString(username) then
        reportBoundary(INCIDENT.identity, command, "username")
        sysMsgRed(player,
            "Your identity could not be verified. Nothing was changed; check the server incident log.")
        return nil
    end
    return username
end

local function refuseTargetResolution(player, target, status)
    if status == "unavailable" then
        sysMsgRed(player,
            "The online roster could not be verified. Nothing was changed; check the server incident log.")
    elseif status == "ambiguous" then
        sysMsgRed(player,
            "More than one online character matches '" .. target
                .. "'. Use the exact account username shown by /lang list.")
    elseif status == "invalid" then
        sysMsgRed(player, "That target name is invalid.")
    else
        sysMsgRed(player, "No online character named '" .. target .. "'.")
    end
end

-- Returns (true, authenticatedAdminUsername) only when both authority and
-- attribution are readable. A genuine non-admin is an ordinary policy denial;
-- an unreadable access level is an incident, not an implicit "none".
local function requireAdmin(player, label)
    local adminUsername = requirePlayerUsername(player, label)
    if not adminUsername then return false, nil end

    local ok, accessLevel =
        pcall(function() return player:getAccessLevel() end)
    if not ok or type(accessLevel) ~= "string" or accessLevel == "" then
        reportBoundary(INCIDENT.adminAuthority, label, "access")
        sysMsgRed(player,
            "Administrator authority could not be verified. Nothing was changed; check the server incident log.")
        return false, nil
    end
    if accessLevel:lower() ~= "admin" then
        sysMsgRed(player, "/" .. label .. " is admin-only.")
        return false, nil
    end
    return true, adminUsername
end

local function requireStorageProbe(player, command, storeName, probe)
    if type(probe) ~= "function" then
        reportBoundary(INCIDENT.state, command, storeName .. "-probe")
        sysMsgRed(player,
            "Language state could not be verified. Nothing was changed; check the server incident log.")
        return false
    end
    local ok, available = pcall(probe)
    if not ok or available ~= true then
        reportBoundary(INCIDENT.state, command, storeName .. "-storage")
        sysMsgRed(player,
            "Language state could not be verified. Nothing was changed; check the server incident log.")
        return false
    end
    return true
end

local function requireLanguageStorage(player, command)
    return requireStorageProbe(player, command, "language",
        MC_Lang.isStorageAvailable)
end

local function requireAcquisitionStorage(player, command)
    return requireStorageProbe(player, command, "acquisition",
        MC_Acquisition.isStorageAvailable)
end

local function requireLanguageAndAcquisition(player, command)
    if not requireLanguageStorage(player, command) then return false end
    return requireAcquisitionStorage(player, command)
end

local function requirePalette(player, command, language)
    local ok, palette = pcall(MC_LangRegistry.getPalette, language)
    if not ok or type(palette) ~= "table"
        or type(palette.lex) ~= "table" then
        reportBoundary("LANG_PALETTE_UNAVAILABLE", command, "palette")
        sysMsgRed(player,
            "That language's palette could not be verified. Nothing was inferred; check the server incident log.")
        return nil
    end
    local validateOk, valid =
        pcall(MC_LangRegistry.validate, palette)
    if not validateOk or valid ~= true then
        reportBoundary("LANG_PALETTE_UNAVAILABLE", command, "palette-shape")
        sysMsgRed(player,
            "That language's palette could not be verified. Nothing was inferred; check the server incident log.")
        return nil
    end
    local hasLex = false
    for _ in pairs(palette.lex) do
        hasLex = true
        break
    end
    if not hasLex then
        reportBoundary("LANG_PALETTE_UNAVAILABLE", command, "lexicon")
        sysMsgRed(player,
            "That language's palette could not be verified. Nothing was inferred; check the server incident log.")
        return nil
    end
    return palette
end

local function requireLanguageList(player, command)
    local ok, languages = pcall(MC_LangRegistry.listLanguages)
    if not ok or type(languages) ~= "table" then
        reportBoundary("LANG_PALETTE_UNAVAILABLE", command, "registry")
        sysMsgRed(player,
            "The language registry could not be verified. Nothing was inferred; check the server incident log.")
        return nil
    end
    local seen, count, hasEnglish = {}, 0, false
    for index, language in pairs(languages) do
        if type(index) ~= "number" or index < 1
            or index ~= math.floor(index)
            or not validIdentityString(language)
            or seen[language] then
            reportBoundary("LANG_PALETTE_UNAVAILABLE", command, "registry")
            sysMsgRed(player,
                "The language registry could not be verified. Nothing was inferred; check the server incident log.")
            return nil
        end
        seen[language] = true
        count = count + 1
        if language == "english" then hasEnglish = true end
    end
    if count ~= #languages or not hasEnglish then
        reportBoundary("LANG_PALETTE_UNAVAILABLE", command, "registry")
        sysMsgRed(player,
            "The language registry could not be verified. Nothing was inferred; check the server incident log.")
        return nil
    end
    return languages
end

local function requireAllPalettes(player, command, languages)
    local palettes = {}
    for _, language in ipairs(languages) do
        if language ~= "english" then
            local palette = requirePalette(player, command, language)
            if not palette then return nil end
            palettes[language] = palette
        end
    end
    return palettes
end

-- E4 ergonomics (2026-07-08): "name" or "name (prefix)" for one language --
-- the parenthetical is omitted when the language's shortest unique prefix
-- IS its full name (no shortcut shorter than typing the whole thing
-- exists). Shared by unknownLanguageMsg and /lang list's language-reference
-- header so the shortcuts teach themselves wherever a language listing
-- appears.
local function describeLangWithPrefix(lang, pool)
    local prefix = MC_LangRegistry.shortestUniquePrefix(lang, pool)
    local display = MC_LangRegistry.displayName(lang)
    if prefix == lang then return display end
    return display .. " (" .. prefix .. ")"
end

local function languageListWithPrefixes()
    local pool = MC_LangRegistry.listLanguages()
    local parts = {}
    for _, lang in ipairs(pool) do
        parts[#parts + 1] = describeLangWithPrefix(lang, pool)
    end
    return table.concat(parts, ", ")
end

-- The "Unknown language" refusal is identical at every call site (6 of
-- them); single-sourced here rather than each rebuilding the available-
-- languages list.
local function unknownLanguageMsg(player)
    sysMsgRed(player, "Unknown language. Available: " .. languageListWithPrefixes())
end

-- E1 ergonomics (2026-07-08): unique-prefix language resolution
--
-- Resolves a player-typed language token via MC_LangRegistry.matchLanguage
-- against every known language, and sends the appropriate kind refusal
-- itself (unknown / ambiguous) so every call site gets identical wording.
-- Returns the resolved lowercase language name on success, or nil (a
-- refusal has already been sent -- caller should just `return`).
--
-- Wherever a language name is accepted from a player: /lang set (both
-- self- and admin-target forms), /forget, /lang grant, /lang revoke.
local function resolveLanguageInput(player, input)
    local kind, result = MC_LangRegistry.matchLanguage(input, MC_LangRegistry.listLanguages())
    if kind == "exact" or kind == "prefix" then
        return result
    end
    if kind == "ambiguous" then
        local displayNames = {}
        for _, lang in ipairs(result) do
            displayNames[#displayNames + 1] = MC_LangRegistry.displayName(lang)
        end
        sysMsgRed(player, input .. " could be: " .. table.concat(displayNames, ", ") .. ".")
        return nil
    end
    unknownLanguageMsg(player)
    return nil
end

-- /lang grant <character> <language> (admin-only)
--
-- runGrantNative is the single core for BOTH transports: this chat command
-- (below, after name resolution) and MC_Server's GrantLanguage menu
-- command (which already holds the exact username -- no resolution needed,
-- see its own comment). `target` is a raw username; the display name is
-- looked up here via the online roster so neither caller has to carry a
-- forename. Mirrors runResetAll's shape (admin gate lives in the shared
-- core, not in each transport).

function MC_LangCommands.runGrantNative(player, target, language)
    if not player or type(target) ~= "string" or target == ""
       or type(language) ~= "string" or language == "" then
        reportBoundary(INCIDENT.target, "lang grant", "arguments")
        return
    end
    local adminOk, adminUsername = requireAdmin(player, "lang grant")
    if not adminOk then return end

    local _, targetForename, targetStatus =
        resolveTargetByUsername(target, "lang grant")
    if not targetForename then
        refuseTargetResolution(player, target, targetStatus)
        return
    end

    language = resolveLanguageInput(player, language)
    if not language then return end
    if language == "english" then
        sysMsgRed(player, "English is the universal baseline -- already known by everyone.")
        return
    end

    local display = targetForename
    local displayLang = MC_Lang._describeLang(language)

    local ok, alreadyHad = MC_Lang.grantNative(target, language)
    if not ok then
        sysMsgRed(player, "Failed to grant " .. displayLang .. " to " .. display .. ".")
        return
    end

    if alreadyHad then
        sysMsgGreen(player, display .. " already natively speaks " .. displayLang .. ".")
    else
        sysMsgGreen(player, display .. " now natively speaks " .. displayLang .. ".")
    end
    dbg("runGrantNative: %s granted %s (%s) native %s",
        adminUsername,
        target, display, language)
end

function MC_LangCommands.handleGrantCommand(player, argString)
    if not requirePlayerUsername(player, "lang grant") then return end
    if type(argString) ~= "string" then
        reportBoundary(INCIDENT.target, "lang grant", "arguments")
        return
    end

    local target, language = parseTargetAndLanguage(argString)
    if not target or not language then
        sysMsgRed(player, 'Usage: /lang grant <character> <language>')
        return
    end

    local resolvedUsername, _, status =
        resolveTargetByName(target, "lang grant")
    if not resolvedUsername then
        refuseTargetResolution(player, target, status)
        return
    end

    MC_LangCommands.runGrantNative(player, resolvedUsername, language)
end

-- /lang revoke <character> <language> (admin-only)
--
-- runRevokeNative is grant's twin core -- see the comment above it.

function MC_LangCommands.runRevokeNative(player, target, language)
    if not player or type(target) ~= "string" or target == ""
       or type(language) ~= "string" or language == "" then
        reportBoundary(INCIDENT.target, "lang revoke", "arguments")
        return
    end
    local adminOk, adminUsername = requireAdmin(player, "lang revoke")
    if not adminOk then return end

    local _, targetForename, targetStatus =
        resolveTargetByUsername(target, "lang revoke")
    if not targetForename then
        refuseTargetResolution(player, target, targetStatus)
        return
    end

    language = resolveLanguageInput(player, language)
    if not language then return end
    if language == "english" then
        sysMsgRed(player, "English cannot be revoked -- it's the universal baseline.")
        return
    end

    local display = targetForename
    local displayLang = MC_Lang._describeLang(language)

    local ok, hadIt = MC_Lang.revokeNative(target, language)
    if not ok then
        sysMsgRed(player, "Failed to revoke " .. displayLang .. " from " .. display .. ".")
        return
    end

    if not hadIt then
        sysMsgGreen(player, display .. " didn't natively speak " .. displayLang .. " to begin with.")
    else
        sysMsgGreen(player, display .. " no longer natively speaks " .. displayLang ..
            " (they may still know vocabulary they've acquired).")
    end
    dbg("runRevokeNative: %s revoked %s (%s) native %s",
        adminUsername,
        target, display, language)
end

function MC_LangCommands.handleRevokeCommand(player, argString)
    if not requirePlayerUsername(player, "lang revoke") then return end
    if type(argString) ~= "string" then
        reportBoundary(INCIDENT.target, "lang revoke", "arguments")
        return
    end

    local target, language = parseTargetAndLanguage(argString)
    if not target or not language then
        sysMsgRed(player, 'Usage: /lang revoke <character> <language>')
        return
    end

    local resolvedUsername, _, status =
        resolveTargetByName(target, "lang revoke")
    if not resolvedUsername then
        refuseTargetResolution(player, target, status)
        return
    end

    MC_LangCommands.runRevokeNative(player, resolvedUsername, language)
end

-- /lang reset <character> [confirm] (admin-only)
--
-- Composite wipe of a character's linguistic identity: speaking choice,
-- all native grants, and ALL acquired vocabulary. Built for character
-- death / re-roll -- language state is per-username, so without this a
-- player's new character inherits the dead one's languages and weeks of
-- learned words.
--
-- DESTRUCTIVE AND IRREVERSIBLE, so it's two-step and stateless: bare
-- `/lang reset <char>` previews exactly what would be wiped;
-- `/lang reset <char> confirm` executes. No pending-confirmation state
-- to leak or time out -- the confirm token is part of the command.

-- Parse '<target> [confirm]' with optional quoted target. Returns
-- (target, confirmed) or (nil, false) on parse failure.
local function parseResetArgs(argString)
    if type(argString) ~= "string" then return nil, false end
    local target, rest = argString:match('^%s*"([^"]+)"%s*(.*)$')
    if not target then
        target, rest = argString:match('^%s*(%S+)%s*(.*)$')
    end
    if not target or target == "" then return nil, false end
    rest = (rest or ""):match("^%s*(%S*)%s*$") or ""
    if rest == "" then return target, false end
    if rest:lower() == "confirm" then return target, true end
    return nil, false  -- trailing junk that isn't "confirm": refuse, don't guess
end

function MC_LangCommands.handleResetCommand(player, argString)
    if type(argString) ~= "string" then
        reportBoundary(INCIDENT.target, "lang reset", "arguments")
        return
    end
    local adminOk, adminUsername = requireAdmin(player, "lang reset")
    if not adminOk then return end

    local target, confirmed = parseResetArgs(argString)
    if not target then
        sysMsgRed(player, 'Usage: /lang reset <character>  -- preview, then /lang reset <character> confirm')
        return
    end

    local resolvedUsername, resolvedForename, status =
        resolveTargetByName(target, "lang reset")
    if not resolvedUsername then
        refuseTargetResolution(player, target, status)
        return
    end

    if not requireLanguageAndAcquisition(player, "lang reset") then
        MC_Incident.report("LANG_RESET_FAILED", "stage=inventory")
        return
    end

    -- Build the inventory (used by both preview and the post-wipe report).
    -- Storage availability is necessary but not sufficient: a query seam can
    -- still raise or return malformed data, which must not become a confident
    -- empty preview.
    local inventoryOk, speaking, previous, natives, acqParts = pcall(function()
        local inventorySpeaking = MC_Lang.getLanguage(resolvedUsername)
        local inventoryPrevious = MC_Lang.getPreviousLanguage(resolvedUsername)
        if type(inventorySpeaking) ~= "string"
            or (inventoryPrevious ~= nil
                and type(inventoryPrevious) ~= "string") then
            return nil
        end

        local nativeLanguages =
            MC_Lang.getNativeLanguages(resolvedUsername)
        if type(nativeLanguages) ~= "table" then return nil end
        local inventoryNatives = {}
        for _, lang in ipairs(nativeLanguages) do
            if not validIdentityString(lang) then return nil end
            if lang ~= "english" then
                inventoryNatives[#inventoryNatives + 1] =
                    MC_Lang._describeLang(lang)
            end
        end

        local acquisitionLanguages =
            MC_Acquisition.languagesWithData(resolvedUsername)
        if type(acquisitionLanguages) ~= "table" then return nil end
        local inventoryAcquisition = {}
        for _, entry in ipairs(acquisitionLanguages) do
            if type(entry) ~= "table"
                or not validIdentityString(entry.lang)
                or type(entry.tokens) ~= "number"
                or entry.tokens ~= entry.tokens
                or entry.tokens < 0
                or entry.tokens ~= math.floor(entry.tokens) then
                return nil
            end
            inventoryAcquisition[#inventoryAcquisition + 1] =
                string.format("%s (%d tokens)",
                    MC_Lang._describeLang(entry.lang), entry.tokens)
        end
        return inventorySpeaking, inventoryPrevious,
            inventoryNatives, inventoryAcquisition
    end)
    if not inventoryOk or type(speaking) ~= "string"
        or type(natives) ~= "table" or type(acqParts) ~= "table" then
        MC_Incident.report("LANG_RESET_FAILED", "stage=inventory")
        sysMsgRed(player,
            "Reset inventory could not be verified. Nothing was changed; check the server incident log.")
        return
    end

    local speakingLine = (speaking == "english")
        and "Speaking: English (baseline)"
        or  ("Speaking: " .. MC_Lang._describeLang(speaking))
    local nativeLine = "Native: " ..
        (#natives > 0 and table.concat(natives, ", ") or "none beyond English")
    local previousLine = "Previous: " ..
        (previous and MC_Lang._describeLang(previous) or "none")
    local acqLine = "Acquired vocabulary: " ..
        (#acqParts > 0 and table.concat(acqParts, ", ") or "none")

    if not confirmed then
        MC_Lang._sysMsg(player, "Reset preview for " .. resolvedForename ..
            " (" .. resolvedUsername .. "):")
        MC_Lang._sysMsg(player, "  " .. speakingLine)
        MC_Lang._sysMsg(player, "  " .. previousLine)
        MC_Lang._sysMsg(player, "  " .. nativeLine)
        MC_Lang._sysMsg(player, "  " .. acqLine)
        if speaking == "english" and previous == nil
            and #natives == 0 and #acqParts == 0 then
            MC_Lang._sysMsg(player, "Nothing to wipe -- this character is already at baseline.")
            return
        end
        sysMsgRed(player, "This wipes ALL of the above, irreversibly. " ..
            'To proceed: /lang reset "' .. resolvedForename .. '" confirm')
        return
    end

    local resetCallOk, summary =
        pcall(MC_Lang.resetUser, resolvedUsername)
    if not resetCallOk or type(summary) ~= "table"
        or summary.ok ~= true or type(summary.natives) ~= "table" then
        MC_Incident.report("LANG_RESET_FAILED", "stage=language-identity")
        print(string.format(
            "[MongooseChat][LANG_RESET][FAILED] %s requested language reset for %s stage=language-identity",
            adminUsername, resolvedUsername))
        sysMsgRed(player, "Reset write could not be verified. No success is being reported; the disk outcome is uncertain. Check the server incident log before retrying.")
        return
    end
    local acquisitionCallOk, acquisitionOk, langsWiped =
        pcall(MC_Acquisition.forgetUserPersisted, resolvedUsername)
    if not acquisitionCallOk or acquisitionOk ~= true
        or type(langsWiped) ~= "number" or langsWiped ~= langsWiped
        or langsWiped < 0 or langsWiped ~= math.floor(langsWiped) then
        MC_Incident.report("LANG_RESET_FAILED", "stage=acquisition")
        print(string.format(
            "[MongooseChat][LANG_RESET][INCOMPLETE] %s requested language reset for %s stage=acquisition",
            adminUsername, resolvedUsername))
        sysMsgRed(player, "Reset is incomplete: language identity cleared, but vocabulary did not commit. Check the server incident log and retry.")
        return
    end

    print(string.format(
        "[MongooseChat][LANG_RESET][COMPLETE] %s reset language identity for %s: native=%d acquisition_languages=%d",
        adminUsername, resolvedUsername, #summary.natives, langsWiped))
    sysMsgGreen(player, string.format(
        "Reset %s (%s): speaking cleared, %d native grant(s) revoked, " ..
        "acquired vocabulary wiped for %d language(s).",
        resolvedForename, resolvedUsername, #summary.natives, langsWiped))
    dbg("handleResetCommand: %s reset %s (%s): speaking=%s natives=%d acqLangs=%d",
        adminUsername,
        resolvedUsername, resolvedForename,
        tostring(summary.speaking), #summary.natives, langsWiped)
end

-- /lang prune <character> [confirm] (admin-only)
--
-- Surgical cleanup for orphaned native grants: a native-language key that
-- was registered once but has since been renamed or removed from the live
-- registry (MC_LangRegistry.isKnownLanguage), left behind on a character's
-- record from before the change -- MC_LangRegistry.displayName already
-- marks one honestly wherever it's shown ("Japonic (no longer spoken
-- here)"), but display never deletes on its own. Unlike /lang reset (the
-- composite wipe, which also clears orphans but only as a side effect of
-- clearing EVERYTHING), prune touches ONLY the dead key(s) -- speaking
-- choice, every native grant that's still a real registered language, and
-- all acquired vocabulary are left exactly as they were.
--
-- Same stateless two-step shape as /lang reset: bare preview, `confirm`
-- executes. Reuses parseResetArgs -- identical '<target> [confirm]' shape.

function MC_LangCommands.handlePruneCommand(player, argString)
    if type(argString) ~= "string" then
        reportBoundary(INCIDENT.target, "lang prune", "arguments")
        return
    end
    local adminOk, adminUsername = requireAdmin(player, "lang prune")
    if not adminOk then return end

    local target, confirmed = parseResetArgs(argString)
    if not target then
        sysMsgRed(player, 'Usage: /lang prune <character>  -- preview, then /lang prune <character> confirm')
        return
    end

    local resolvedUsername, resolvedForename, status =
        resolveTargetByName(target, "lang prune")
    if not resolvedUsername then
        refuseTargetResolution(player, target, status)
        return
    end

    if not requireLanguageStorage(player, "lang prune") then
        MC_Incident.report("LANG_PRUNE_FAILED", "stage=inventory")
        return
    end

    local inventoryOk, orphans =
        pcall(MC_Lang.getOrphanedNatives, resolvedUsername)
    if not inventoryOk or type(orphans) ~= "table" then
        MC_Incident.report("LANG_PRUNE_FAILED", "stage=inventory")
        sysMsgRed(player,
            "Prune inventory could not be verified. Nothing was changed; check the server incident log.")
        return
    end
    for _, orphan in ipairs(orphans) do
        if not validIdentityString(orphan) then
            MC_Incident.report("LANG_PRUNE_FAILED", "stage=inventory")
            sysMsgRed(player,
                "Prune inventory could not be verified. Nothing was changed; check the server incident log.")
            return
        end
    end

    if #orphans == 0 then
        MC_Lang._sysMsg(player, resolvedForename .. " (" .. resolvedUsername ..
            ") carries no orphaned native languages -- nothing to prune.")
        return
    end

    if not confirmed then
        MC_Lang._sysMsg(player, "Prune preview for " .. resolvedForename ..
            " (" .. resolvedUsername .. "):")
        MC_Lang._sysMsg(player, "  Orphaned native(s) -- no longer a registered language: " ..
            table.concat(orphans, ", "))
        MC_Lang._sysMsg(player, "  Everything else (speaking choice, other native grants, " ..
            "acquired vocabulary) is left untouched.")
        sysMsgRed(player, "This removes the above native grant(s), irreversibly. " ..
            'To proceed: /lang prune "' .. resolvedForename .. '" confirm')
        return
    end

    local pruneCallOk, pruned, committed =
        pcall(MC_Lang.pruneOrphanedNatives, resolvedUsername)
    if not pruneCallOk or type(pruned) ~= "table"
        or committed ~= true then
        MC_Incident.report("LANG_PRUNE_FAILED", "stage=persistence")
        sysMsgRed(player,
            "Prune write could not be verified. No success is being reported; the disk outcome is uncertain. Check the server incident log.")
        return
    end
    for _, orphan in ipairs(pruned) do
        if not validIdentityString(orphan) then
            MC_Incident.report("LANG_PRUNE_FAILED", "stage=result")
            sysMsgRed(player,
                "Prune result could not be verified. No success is being reported; check the server incident log.")
            return
        end
    end
    sysMsgGreen(player, string.format(
        "Pruned %d orphaned native grant(s) from %s (%s): %s.",
        #pruned, resolvedForename, resolvedUsername, table.concat(pruned, ", ")))

    -- Loud, ALWAYS-ON audit line -- same always-on print class as
    -- runResetAll's [MongooseChat][WIPE] line: an operator must be able to
    -- answer "who pruned whom, and what was removed" with DEBUG off.
    print(string.format(
        "[MongooseChat][PRUNE] %s pruned orphaned native(s) from %s (%s): %s",
        adminUsername, resolvedForename, resolvedUsername, table.concat(pruned, ", ")))

    dbg("handlePruneCommand: %s pruned %s (%s): %s",
        adminUsername, resolvedUsername, resolvedForename, table.concat(pruned, ", "))
end

-- /lang resetall <username> [confirm] (admin-only) -- the TOTAL wipe
--
-- Everything MongooseChat remembers about one username, across every durable
-- store, in one two-step command:
--
--   MC_Languages    (MC_Lang.lua)        speaking choice + native grants
--   MC_Acquisitions (MC_Acquisition)   every heard/acquired word, production
--                                      practice, misheard meanings, teaching
--                                      provenance (voices/firstVoice)
--   MC_Taglines     (MC_Server)        the bio line -- via a registered wipe
--                                      extension (see below; wired)
--   MC_Descriptions (MC_Server)        character-sheet description -- same
--                                      extension mechanism (wired)
--   MC_Notes        (MC_Server)        private viewer/target notes -- same
--                                      extension mechanism (wired)
--   MC_Hues         (MC_Server)        the /hue chosen name color -- same
--                                      extension mechanism (wired)
--
-- WHY USERNAME, NOT FORENAME: /lang reset resolves forenames against the
-- online roster, which is friendly but ambiguous -- two characters can share
-- a forename, and a total wipe pointed at the wrong player is unrecoverable.
-- resetall therefore matches the USERNAME exactly (the stores' own key,
-- case-sensitive), shows the resolved character name in the preview, and
-- works for offline usernames too -- the data outlives the character, so
-- the broom must reach where the roster can't. A typo'd username has no
-- store data behind it and is refused outright, so nothing can be lost to
-- a slip of the finger.
--
-- MC_Server registers its session-local language-identification cache
-- (identifiedLangs) through this same wipe-extension registry. A successful
-- total wipe therefore retracts recognised-language tags along with every
-- durable identity store; it is not an accepted session remainder.

-- The core runner, shared by the /lang resetall chat form and the admin
-- context menu's WipeAll client command. `target` is a raw username string;
-- gate, resolution, preview, and execution all live here (server-side truth).
local function runResetAll(player, target, confirmed)
    if type(target) ~= "string" or not validIdentityString(target) then
        reportBoundary(INCIDENT.target, "lang resetall", "target")
        if player then sysMsgRed(player, "That exact username is invalid.") end
        return
    end
    local adminOk, adminUsername = requireAdmin(player, "lang resetall")
    if not adminOk then return end

    local targetPlayer, forename, rosterStatus =
        resolveTargetByUsername(target, "lang resetall")
    if rosterStatus == "unavailable" or rosterStatus == "ambiguous"
        or rosterStatus == "invalid" then
        refuseTargetResolution(player, target, rosterStatus)
        return
    end

    local inv = MC_Lang._buildWipeInventory(target)

    if inv.ready ~= true then
        MC_Incident.report("TOTAL_WIPE_FAILED", "stage=inventory")
        MC_Lang._sysMsg(player, "Total wipe safety check for " ..
            (forename and (forename .. " (" .. target .. ")") or target) .. ":")
        for _, line in ipairs(MC_Lang._wipeInventoryLines(inv)) do
            MC_Lang._sysMsg(player, "  " .. line)
        end
        sysMsgRed(player, "Wipe refused: one or more stores could not be authoritatively inspected. Check the server incident log.")
        return
    end

    -- Nobody online under that exact username AND nothing in any store:
    -- almost certainly a typo. Refusing is what makes exact-match safe.
    if not targetPlayer and inv.empty then
        sysMsgRed(player, "MongooseChat carries nothing under the username '" ..
            target .. "', and no one online matches it exactly. " ..
            "(resetall matches usernames exactly -- /lang list shows them.)")
        return
    end

    local who = forename
        and (forename .. " (" .. target .. ")")
        or  (target .. " (offline right now)")

    if not confirmed then
        MC_Lang._sysMsg(player, "Total wipe preview for " .. who .. ":")
        for _, line in ipairs(MC_Lang._wipeInventoryLines(inv)) do
            MC_Lang._sysMsg(player, "  " .. line)
        end
        if inv.empty then
            MC_Lang._sysMsg(player, "Nothing to wipe -- MongooseChat carries nothing for them.")
            return
        end
        sysMsgRed(player, "This erases everything above, irreversibly. " ..
            'To proceed: /lang resetall "' .. target .. '" confirm')
        return
    end

    if inv.empty then
        MC_Lang._sysMsg(player, "Nothing to wipe -- MongooseChat already carries nothing for " .. who .. ".")
        return
    end

    -- Execute, store by store.
    local languageSummary = MC_Lang.resetUser(target)       -- MC_Languages (saves itself)
    if languageSummary.ok ~= true then
        MC_Incident.report("TOTAL_WIPE_FAILED", "stage=language-identity")
        sysMsgRed(player, "Total wipe did not commit. Check the server incident log and retry.")
        return
    end
    local acquisitionOk, langsWiped =
        MC_Acquisition.forgetUserPersisted(target)           -- MC_Acquisitions
    if acquisitionOk ~= true then
        MC_Incident.report("TOTAL_WIPE_FAILED", "stage=acquisition")
        sysMsgRed(player, "Total wipe is incomplete: language identity cleared, but vocabulary did not commit. Check the server incident log and retry.")
        return
    end
    local extsWiped, extsFailed = {}, {}
    for id, ext in pairs(MC_Lang._wipeExtensions) do
        if inv.exts[id] then
            local ok, removed = pcall(ext.clear, target)
            if ok and removed == true then
                if ext.hidden ~= true then
                    extsWiped[#extsWiped + 1] = ext.label:lower()
                end
            else
                -- Held data but didn't confirm the clear: a partial wipe
                -- must never pass silently as a full one.
                extsFailed[#extsFailed + 1] = ext.hidden == true
                    and "internal identity store" or ext.label:lower()
                if not ok then
                    dbg("runResetAll: extension '%s' clear threw: %s", id, tostring(removed))
                end
                MC_Incident.report("TOTAL_WIPE_FAILED",
                    "store=" .. tostring(id) .. " stage=clear")
            end
        end
    end
    table.sort(extsWiped)
    table.sort(extsFailed)
    MC_Lang._traceUsers[target] = nil                                 -- session: trace opt-in

    -- Loud, ALWAYS-ON audit line -- same always-on print class as
    -- MC_Persist's corruption warnings. An operator must be able to answer
    -- "who wiped whom, and what was lost" with DEBUG off.
    local wipeStatus = (#extsFailed == 0) and "COMPLETE" or "INCOMPLETE"
    print(string.format("[MongooseChat][WIPE][%s] %s requested ALL MongooseChat data wipe for %s: %s%s",
        wipeStatus,
        adminUsername, who, table.concat(MC_Lang._wipeInventoryLines(inv), "; "),
        (#extsFailed > 0)
            and (" [NOT cleared: " .. table.concat(extsFailed, ", ") .. "]")
            or ""))

    local extraBits = ""
    if #extsWiped > 0 then
        extraBits = ", " .. table.concat(extsWiped, " erased, ") .. " erased"
    end
    if #extsFailed == 0 then
        sysMsgGreen(player, string.format(
            "Every trace of %s is gone: language identity cleared, vocabulary wiped " ..
            "for %d language(s)%s.",
            who, langsWiped, extraBits))
    else
        sysMsgRed(player, "One part would not let go: " ..
            table.concat(extsFailed, ", ") ..
            " didn't confirm its wipe. This wipe is incomplete; check the server log and try again.")
    end
    dbg("runResetAll: %s wiped %s (langsWiped=%d extsWiped=%d extsFailed=%d)",
        adminUsername, target, langsWiped, #extsWiped, #extsFailed)
end

function MC_LangCommands.handleResetAllCommand(player, argString)
    if not requirePlayerUsername(player, "lang resetall") then return end
    if type(argString) ~= "string" then
        reportBoundary(INCIDENT.target, "lang resetall", "arguments")
        return
    end
    -- Same '<target> [confirm]' shape as /lang reset (quoted target
    -- supported; trailing junk that isn't "confirm" is refused, not guessed).
    local target, confirmed = parseResetArgs(argString)
    if not target then
        sysMsgRed(player, 'Usage: /lang resetall <username>  -- preview, then ' ..
            '/lang resetall <username> confirm. Matches usernames exactly.')
        return
    end
    runResetAll(player, target, confirmed)
end

-- MENU TRANSPORT for the total wipe
--
-- The admin context menu (client/MC_LangAdmin) reaches resetall through its
-- own client command on its own module name -- MC_Server's dispatch stays
-- untouched (its OnClientCommand listener returns early on foreign module
-- names). The admin gate and every validation live in runResetAll; this
-- listener only shapes the args, exactly as cautiously as MC_Server's
-- validString does (C15: malicious clients can send anything).

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= "MongooseChatLang" then return end
    if command ~= "WipeAll" then return end
    if not requirePlayerUsername(player, "lang resetall") then return end
    if type(args) ~= "table" then
        MC_Incident.report("LANG_WIPE_COMMAND_FAILED",
            "command=WipeAll stage=arguments")
        return
    end
    local target = args.target
    if not validIdentityString(target) then
        MC_Incident.report("LANG_WIPE_COMMAND_FAILED",
            "command=WipeAll stage=target")
        sysMsgRed(player,
            "That wipe target was invalid and was not changed or executed.")
        return
    end
    local ok = pcall(runResetAll, player, target, args.confirm == true)
    if not ok then
        MC_Incident.report("LANG_WIPE_COMMAND_FAILED",
            "command=WipeAll stage=execute")
    end
end)

-- /forget <language> [confirm] (self-serve)
--
-- A player lets go of a language they've been learning: wipes THEIR OWN
-- acquired vocabulary and exposure for that one language, and nothing else.
-- Built for re-rolled characters who inherited an old life's words (see
-- MC_Lang.handleFreshCharacter), but open to anyone -- it only ever acts on
-- the caller. Speaking choice and native grants are untouched (those are
-- /lang's to manage).
--
-- DESTRUCTIVE AND IRREVERSIBLE, so it mirrors /lang reset's stateless
-- two-step: bare `/forget <language>` previews what would be lost;
-- `/forget <language> confirm` executes.

-- Parse '<language> [confirm]'. Returns (language, confirmed) or (nil, false).
local function parseForgetArgs(argString)
    if type(argString) ~= "string" then return nil, false end
    local lang, rest = argString:match("^%s*(%S+)%s*(.*)$")
    if not lang or lang == "" then return nil, false end
    rest = (rest or ""):match("^%s*(%S*)%s*$") or ""
    if rest == "" then return lang, false end
    if rest:lower() == "confirm" then return lang, true end
    return nil, false  -- trailing junk that isn't "confirm": refuse, don't guess
end

function MC_LangCommands.handleForgetCommand(player, argString)
    local username = requirePlayerUsername(player, "forget")
    if not username then return end

    if not requireLanguageAndAcquisition(player, "forget") then
        MC_Incident.report("LANG_FORGET_FAILED", "stage=inventory")
        return
    end

    local lang, confirmed = parseForgetArgs(argString or "")
    if not lang then
        MC_Lang._sysMsg(player, "Usage: /forget <language>  -- see what you'd lose, then /forget <language> confirm")
        return
    end

    lang = resolveLanguageInput(player, lang)
    if not lang then return end
    local displayLang = MC_Lang._describeLang(lang)
    if lang == "english" then
        sysMsgRed(player, "English is the universal baseline -- it can't be forgotten.")
        return
    end
    if MC_Lang.isNative(username, lang) then
        sysMsgRed(player, displayLang .. " is your native tongue -- it isn't yours to forget.")
        return
    end

    -- Inventory: everything tracked for this language, and how much of it
    -- the player has genuinely made their own (acquired).
    local tracked = 0
    for _, entry in ipairs(MC_Acquisition.languagesWithData(username)) do
        if entry.lang == lang then tracked = entry.tokens end
    end
    if tracked == 0 then
        MC_Lang._sysMsg(player, "You carry nothing of " .. displayLang .. " -- there's nothing to forget.")
        return
    end
    local palette = MC_LangRegistry.getPalette(lang)
    if not palette then
        MC_Incident.report("LANG_FORGET_FAILED", "stage=palette")
        sysMsgRed(player, "Forget refused: that language's palette is unavailable. Check the server incident log.")
        return
    end
    local acquiredN = 0
    acquiredN = MC_Acquisition.acquiredCountForPalette(username, lang, palette)

    if not confirmed then
        MC_Lang._sysMsg(player, string.format(
            "Forgetting %s: %d word(s) you've made your own, %d heard in all -- every one of them would fade.",
            displayLang, acquiredN, tracked))
        sysMsgRed(player, "Gone is gone -- there's no earning them back but the long way. " ..
            "To let " .. displayLang .. " go: /forget " .. lang .. " confirm")
        return
    end

    local wiped = MC_Acquisition.forgetLanguagePersisted(username, lang)
    if wiped ~= true then
        MC_Incident.report("LANG_FORGET_FAILED", "stage=acquisition")
        sysMsgRed(player, displayLang .. " did not fade: the wipe failed verification. Check the server incident log and retry.")
        return
    end
    sysMsgGreen(player, displayLang .. " slips away. The words of that life are gone.")
    if MC_Lang.getLanguage(username) == lang then
        MC_Lang._sysMsg(player, "You're still set to speak it -- /lang english if you'd rather not.")
    end
    dbg("handleForgetCommand: %s forgot %s (wiped=%s, tracked=%d)",
        username, lang, tostring(wiped), tracked)
end

-- /lang list (admin-only)
--
-- Roster overview: every username with language state (speaking and/or
-- native grants), with online forenames marked. Capped to avoid flooding
-- the panel on large databases.

local LIST_MAX_LINES = 60

function MC_LangCommands.handleListCommand(player)
    local adminOk = requireAdmin(player, "lang list")
    if not adminOk then return end
    if not requireLanguageStorage(player, "lang list") then return end

    local onlineRecords = onlineTargetRecords("lang list", "forename")
    if not onlineRecords then
        sysMsgRed(player,
            "The online roster could not be verified. No language list was inferred; check the server incident log.")
        return
    end

    local usersOk, langUsers = pcall(MC_Lang._langDBUsers)
    if not usersOk or type(langUsers) ~= "table" then
        reportBoundary(INCIDENT.state, "lang list", "language-records")
        sysMsgRed(player,
            "Language assignments could not be verified. No list was inferred; check the server incident log.")
        return
    end

    -- Online username -> forename map, one roster pass.
    local onlineForename = {}
    for _, rec in ipairs(onlineRecords) do
        onlineForename[rec.username] = rec.forename
    end

    -- Collect + sort usernames with any language state.
    local usernames = {}
    for username, rec in pairs(langUsers) do
        if not validIdentityString(username) or type(rec) ~= "table"
            or (rec.speaking ~= nil
                and not validIdentityString(rec.speaking))
            or type(rec.native) ~= "table" then
            reportBoundary(INCIDENT.state, "lang list", "language-record")
            sysMsgRed(player,
                "Language assignments could not be verified. No list was inferred; check the server incident log.")
            return
        end
        for lang, present in pairs(rec.native) do
            if not validIdentityString(lang) or present ~= true then
                reportBoundary(INCIDENT.state, "lang list", "native-record")
                sysMsgRed(player,
                    "Language assignments could not be verified. No list was inferred; check the server incident log.")
                return
            end
        end
        usernames[#usernames + 1] = username
    end
    table.sort(usernames)

    local referenceOk, languageReference =
        pcall(languageListWithPrefixes)
    if not referenceOk or type(languageReference) ~= "string"
        or languageReference == "" then
        reportBoundary(INCIDENT.state, "lang list", "language-reference")
        sysMsgRed(player,
            "Language assignments could not be verified. No list was inferred; check the server incident log.")
        return
    end

    -- E4 ergonomics: the language reference (with each name's shortest
    -- unique prefix) heads the roster, so admins running the one command
    -- that surfaces "every language" also see the shortcuts.
    MC_Lang._sysMsg(player, "Languages: " .. languageReference)

    if #usernames == 0 then
        MC_Lang._sysMsg(player, "No language assignments yet -- everyone is at the English baseline.")
        return
    end

    MC_Lang._sysMsg(player, string.format("Language assignments (%d):", #usernames))
    for i, username in ipairs(usernames) do
        if i > LIST_MAX_LINES then
            MC_Lang._sysMsg(player, string.format("  ...and %d more.",
                #usernames - LIST_MAX_LINES))
            break
        end
        local rec = langUsers[username]
        local speaking = rec.speaking and MC_Lang._describeLang(rec.speaking) or "English"
        local natives = {}
        for lang in pairs(rec.native) do natives[#natives + 1] = MC_Lang._describeLang(lang) end
        table.sort(natives)
        local nativeStr = (#natives > 0) and (" | native: " .. table.concat(natives, ", ")) or ""
        local onlineStr = onlineForename[username]
            and (" [online: " .. onlineForename[username] .. "]") or ""
        MC_Lang._sysMsg(player, string.format("  %s -- speaking %s%s%s",
            username, speaking, nativeStr, onlineStr))
    end
end

-- /lang DISPATCHER ENTRY POINT
--
-- Peeks at first token; routes "grant"/"revoke" to native-status handlers,
-- "reset"/"resetall" to the wipe handlers, "prune" to the orphaned-native
-- cleanup handler, "forget"/"list" likewise, otherwise falls through to the
-- original self-set/admin-set-speaking logic.

function MC_LangCommands.handleSetCommand(player, argString)
    local senderUsername = requirePlayerUsername(player, "lang")
    if not senderUsername then return end
    if type(argString) ~= "string" then
        reportBoundary(INCIDENT.target, "lang", "arguments")
        return
    end

    -- Subcommand routing.
    local firstToken = argString:match("^%s*(%S+)")
    if firstToken then
        local lower = firstToken:lower()
        if lower == "grant" then
            local rest = argString:match("^%s*%S+%s*(.*)$") or ""
            return MC_LangCommands.handleGrantCommand(player, rest)
        elseif lower == "revoke" then
            local rest = argString:match("^%s*%S+%s*(.*)$") or ""
            return MC_LangCommands.handleRevokeCommand(player, rest)
        elseif lower == "reset" then
            local rest = argString:match("^%s*%S+%s*(.*)$") or ""
            return MC_LangCommands.handleResetCommand(player, rest)
        elseif lower == "prune" then
            -- Surgical orphaned-native cleanup: everything else untouched.
            local rest = argString:match("^%s*%S+%s*(.*)$") or ""
            return MC_LangCommands.handlePruneCommand(player, rest)
        elseif lower == "resetall" then
            -- The total wipe: every store, one username, two steps.
            local rest = argString:match("^%s*%S+%s*(.*)$") or ""
            return MC_LangCommands.handleResetAllCommand(player, rest)
        elseif lower == "forget" then
            -- Self-serve twin of /forget -- same handler, same two-step.
            local rest = argString:match("^%s*%S+%s*(.*)$") or ""
            return MC_LangCommands.handleForgetCommand(player, rest)
        elseif lower == "list" then
            return MC_LangCommands.handleListCommand(player)
        end
    end

    -- Parse forms, in order of specificity:
    --   '"name" lang' -> two args, quoted target
    --   'name lang'   -> two args, unquoted target
    --   'lang'        -> single arg, self-set
    local target, language = parseTargetAndLanguage(argString)
    if not target and not language then
        language = argString:match('^%s*(%S+)%s*$')
    end

    if not language or language == "" then
        if not requireLanguageStorage(player, "lang status") then return end

        -- Bare /lang: show the character's current status. Players forget
        -- what they've set; the frictionless answer is to just tell them.
        local speaking = MC_Lang.getLanguage(senderUsername)
        local speakingLine
        if speaking == "english" then
            speakingLine = "You're speaking English (baseline)."
        else
            local displaySpeaking = MC_Lang._describeLang(speaking)
            local fluency = MC_Lang.isNative(senderUsername, speaking)
                and "native" or "learner -- your words will come out broken until you've picked up more of the language"
            speakingLine = "You're speaking " .. displaySpeaking .. " (" .. fluency .. ")."
        end
        MC_Lang._sysMsg(player, speakingLine, {140, 200, 220})

        local natives = {}
        for _, lang in ipairs(MC_Lang.getNativeLanguages(senderUsername)) do
            natives[#natives + 1] = MC_Lang._describeLang(lang)
        end
        MC_Lang._sysMsg(player, "Native: " .. table.concat(natives, ", ") ..
            ". Use /comp for comprehension estimates.")

        -- E3: previous language (what /ll switches back to), plain and
        -- either way -- always answered, never a silent gap.
        local previous = MC_Lang.getPreviousLanguage(senderUsername)
        if previous then
            MC_Lang._sysMsg(player, "Previous: " .. MC_Lang._describeLang(previous) .. ".")
        else
            MC_Lang._sysMsg(player, "Previous: none yet.")
        end

        local accessOk, accessLevel =
            pcall(function() return player:getAccessLevel() end)
        local isAdmin = accessOk and type(accessLevel) == "string"
            and accessLevel:lower() == "admin"
        if not accessOk or type(accessLevel) ~= "string"
            or accessLevel == "" then
            reportBoundary(INCIDENT.adminAuthority, "lang status", "access")
        end
        local usage = isAdmin
            and 'Switch: /lang <language>  OR  /lang "<character>" <language>  OR  /lang grant|revoke|reset|prune <character> ...  OR  /lang resetall <username>  OR  /lang list'
            or  ("Switch: /lang <" .. table.concat(MC_LangRegistry.listLanguages(), "|") .. ">")
        MC_Lang._sysMsg(player, usage)
        MC_Lang._sysMsg(player, "Let a language you've been learning go: /forget <language>")
        -- E3/E2 hint: plain, one line, no flourish -- the shortcuts teach
        -- themselves from here rather than needing to be discovered.
        MC_Lang._sysMsg(player, "Tip: /ll switches back to your previous language. " ..
            "@<language> at the start of a message speaks just that one line in " ..
            "another language (e.g. @french bonjour), without changing what you're set to.")
        return
    end

    language = resolveLanguageInput(player, language)
    if not language then return end
    -- ASL toggle (the first per-language one): checked live, not through
    -- the boot-time cache, so a server operator flipping it mid-session
    -- takes effect immediately. ASL stays registered either way -- this
    -- only gates picking it as a speaking language, same "inert, not
    -- unregistered" shape as MongooseChat.LanguagesEnabled above it.
    if language == "asl"
        and MC_Config.liveSandbox("ASLEnabled", false) == false then
        sysMsgRed(player, "ASL is disabled on this server.")
        return
    end

    local targetUsername = senderUsername
    local targetDisplay = nil  -- nil = self

    if target then
        local accessOk, accessLevel =
            pcall(function() return player:getAccessLevel() end)
        if not accessOk or type(accessLevel) ~= "string"
            or accessLevel == "" then
            reportBoundary(INCIDENT.adminAuthority, "lang set", "access")
            sysMsgRed(player,
                "Administrator authority could not be verified. Nothing was changed; check the server incident log.")
            return
        end
        if accessLevel:lower() ~= "admin" then
            sysMsgRed(player,
                "Only admins can assign speaking languages to other characters.")
            return
        end
        local resolvedUsername, resolvedForename, status =
            resolveTargetByName(target, "lang set")
        if not resolvedUsername then
            refuseTargetResolution(player, target, status)
            return
        end
        targetUsername = resolvedUsername
        targetDisplay = resolvedForename
    end

    if MC_Lang.setLanguage(targetUsername, language) ~= true then
        MC_Incident.report("LANG_SET_FAILED", "stage=persistence")
        sysMsgRed(player,
            "The language change could not be verified. No success is being reported; the disk outcome is uncertain. Check the server incident log.")
        return
    end

    local displayLang = MC_Lang._describeLang(language)
    local who = targetDisplay or "Your"
    local nativeNote = ""
    if language ~= "english" and not MC_Lang.isNative(targetUsername, language) then
        nativeNote = targetDisplay
            and " (learner -- their words will come out broken until they've picked up more of the language)"
            or  " (learner -- your words will come out broken until you've picked up more of the language)"
    end
    local confirmMsg = targetDisplay
        and (targetDisplay .. " is now speaking " .. displayLang .. nativeNote .. ".")
        or  ("You are now speaking " .. displayLang .. nativeNote .. ".")
    sysMsgGreen(player, confirmMsg)

    dbg("handleSetCommand: %s set %s (%s) speaking -> %s (native=%s)",
        senderUsername, targetUsername, tostring(targetDisplay or "self"), language,
        tostring(MC_Lang.isNative(targetUsername, language)))
end

-- /ll (E3 ergonomics, 2026-07-08): toggle back to your previous language
--
-- The alt-tab: most bilingual RP bounces between exactly two languages, and
-- typing "/lang french" every time gets exhausting. /ll re-sets whatever
-- MC_Lang.getPreviousLanguage reports -- which MC_Lang.setLanguage itself
-- keeps current on every REAL change (see its own comment) -- so calling
-- /ll again immediately swaps back, a genuine two-way toggle with no extra
-- bookkeeping here.
--
-- Self-serve only (no admin-on-target form): this is personal ergonomics,
-- like /forget, not an admin tool. Takes no arguments.

function MC_LangCommands.handleToggleLastCommand(player, _argString)
    local username = requirePlayerUsername(player, "ll")
    if not username then return end
    if not requireLanguageStorage(player, "ll") then return end

    local previousOk, previous =
        pcall(MC_Lang.getPreviousLanguage, username)
    if not previousOk or (previous ~= nil and type(previous) ~= "string") then
        reportBoundary(INCIDENT.state, "ll", "previous-language")
        sysMsgRed(player,
            "Your previous language could not be verified. Nothing was switched; check the server incident log.")
        return
    end
    if not previous then
        MC_Lang._sysMsg(player, "You don't have a previous language to switch back to yet -- " ..
            "/ll remembers whatever you were speaking before your current language.")
        return
    end

    -- `previous` was only ever recorded by a prior successful setLanguage,
    -- so it's a real registered language -- but a server operator could
    -- have live-disabled it (ASL) since then. Same guard handleSetCommand
    -- applies before calling into MC_Lang.setLanguage.
    if not MC_Lang.isSelectableLanguage(previous) then
        sysMsgRed(player, MC_Lang._describeLang(previous) .. " isn't available right now.")
        return
    end

    if MC_Lang.setLanguage(username, previous) ~= true then
        MC_Incident.report("LANG_SET_FAILED", "stage=toggle-persistence")
        sysMsgRed(player,
            "The language switch could not be verified. No success is being reported; the disk outcome is uncertain. Check the server incident log.")
        return
    end

    local displayLang = MC_Lang._describeLang(previous)
    local nativeNote = ""
    if previous ~= "english" and not MC_Lang.isNative(username, previous) then
        nativeNote = " (learner -- your words will come out broken until you've picked up more of the language)"
    end
    sysMsgGreen(player, "Switched back to " .. displayLang .. nativeNote .. ".")

    dbg("handleToggleLastCommand: %s toggled -> %s", username, previous)
end

-- /lex COMMAND
-- 
-- List tokens the player has acquired in a given language (or all languages
-- they have any exposure in, if no arg). For each L2 form, the concept it
-- lexicalizes is recovered via the reverse-lex map, and the primary English
-- alias of that concept is shown as the L1 meaning.
-- 
-- Usage:
--   /lex             -> summary across all languages
--   /lex french      -> detailed list for one language

local function listAcquiredForLang(username, sourceLang, palette)
    -- l2_lower -> primary L1 alias -- MC_Resolve.reverseLexL1 exists for
    -- exactly this display purpose (same tie-break as reverseLex: sorted
    -- concept ids, first writer wins). reverseLexAll additionally surfaces
    -- every sense a conflated form carries (below).
    local reverseL1 = MC_Resolve.reverseLexL1(palette)
    local reverseAll = MC_Resolve.reverseLexAll(palette)
    local Concepts = require("MC_Concepts")
    local lexSize = 0
    if palette.lex then
        for _ in pairs(palette.lex) do lexSize = lexSize + 1 end
    end

    -- Zipf rank lookup: L2_lower -> rank. Rank is a palette-level fact, not
    -- stored per-exposure, so we resolve it here at query time. Cached on
    -- the palette by getZipfRankMap.
    local rankMap = MC_Lang._getZipfRankMap(palette)

    local acquired = {}
    local familyCloseness = MC_Acquisition.familyClosenessForLang(sourceLang)
    local all = MC_Acquisition.getAllTokens(username, sourceLang)
    for token, exp in pairs(all) do
        -- The explicit acquired flag is the authority here -- the same one
        -- the render and /comp consult. Recomputing the raw probability
        -- used to hide words earned through teaching or form migration
        -- whose count sat below the statistical threshold: a word earned
        -- is a word listed.
        if exp.acquired then
            -- only surface tokens that the current palette actually
            -- lexicalizes through the concept tree. Orphan records (acquired
            -- L2 forms whose concept was removed from the palette, e.g.
            -- v8.x "bonjour" or "danger" on a concept-keyed French palette)
            -- are filtered out rather than displayed as "bonjour (?)" --
            -- the player has no actionable signal from a question mark, and
            -- the record will decay out naturally without disuse-reinforcement.
            local l1 = reverseL1 and reverseL1[token:lower()] or nil
            if l1 then
                -- v8.16.1: conflated forms gloss EVERY sense ("vurmak =
                -- hit / shoot") instead of an arbitrary single concept --
                -- a player who learned the word for both shouldn't see
                -- half of what they know.
                local allIds = reverseAll and reverseAll[token:lower()] or nil
                if allIds and #allIds > 1 then
                    local glosses = {}
                    for _, cid in ipairs(allIds) do
                        local c = Concepts.get(cid)
                        local g = c and c.en and c.en[1] or nil
                        if g then glosses[#glosses + 1] = g end
                    end
                    if #glosses > 1 then
                        l1 = table.concat(glosses, " / ")
                    end
                end
                if l1 then
                    -- Qualitative state for display (fresh/familiar) -- the
                    -- same classifier the render uses. Raw counts aren't
                    -- surfaced to players here.
                    local rank = rankMap and rankMap[token:lower()] or nil
                    local ts = MC_Acquisition.tokenState(exp, rank, familyCloseness)
                    -- Voice diversity is useful player feedback, but account
                    -- identifiers from acquisition provenance stay private.
                    local nVoices = 1
                    if type(exp.voices) == "table" and #exp.voices > 0 then
                        nVoices = #exp.voices
                    end
                    -- Misacquisition: show the wrong meaning if active.
                    local displayL1 = l1
                    local misacquired = false
                    if exp.misacquiredAs then
                        local wrongConcept = Concepts.get(exp.misacquiredAs)
                        if wrongConcept and wrongConcept.en and wrongConcept.en[1] then
                            displayL1 = wrongConcept.en[1]
                            misacquired = true
                        end
                    end
                    table.insert(acquired, {
                        l2 = token, l1 = displayL1, state = ts.state,
                        voices = nVoices,
                        lastHeard = exp.lastHeard,
                        misacquired = misacquired,
                    })
                end
            end
        end
    end
    -- Stable display order: by L2 form.
    table.sort(acquired, function(a, b) return a.l2 < b.l2 end)
    return acquired, #acquired, lexSize
end

local function requireAcquiredSummary(player, command, username, language,
                                      palette)
    local ok, acquired, count, lexSize =
        pcall(listAcquiredForLang, username, language, palette)
    if not ok or type(acquired) ~= "table"
        or type(count) ~= "number" or count < 0
        or count ~= math.floor(count) or count ~= #acquired
        or type(lexSize) ~= "number" or lexSize <= 0
        or lexSize ~= math.floor(lexSize) then
        reportBoundary(INCIDENT.state, command, "acquisition-records")
        sysMsgRed(player,
            "Acquisition records could not be verified. Nothing was inferred; check the server incident log.")
        return nil
    end
    return acquired, count, lexSize
end

function MC_LangCommands.handleLexCommand(player, argString)
    local username = requirePlayerUsername(player, "lex")
    if not username then return end
    if not requireLanguageAndAcquisition(player, "lex") then return end
    if argString ~= nil and type(argString) ~= "string" then
        reportBoundary(INCIDENT.state, "lex", "arguments")
        return
    end

    local arg = argString and argString:match("^%s*(%S+)%s*$") or nil

    if arg then
        local lang = arg:lower()
        -- v8.16.1: /lex trace -- toggle the per-utterance acquisition trace.
        -- Admin-only (it reveals raw mechanics numbers). Used to also allow
        -- self-serve under the "test" acquisition profile; that profile was
        -- stripped from the stable cut (AcquisitionTestMode removed this
        -- release, MC_Acquisition's PROFILES table now holds only "live"),
        -- so the admin check is the whole gate.
        if lang == "trace" then
            if not requireAdmin(player, "lex trace") then return end
            MC_Lang._traceUsers[username] = not MC_Lang._traceUsers[username] or nil
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = MC_Lang._traceUsers[username]
                    and "Acquisition trace ON -- every utterance you hear reports what registered."
                    or "Acquisition trace off.",
                color = {120, 180, 180},
            })
            return
        end
        if not MC_LangRegistry.isKnownLanguage(lang) then
            unknownLanguageMsg(player)
            return
        end
        if lang == "english" then
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = "English is the baseline -- natively known by everyone.",
                color = {200, 200, 200},
            })
            return
        end

        local displayLang = MC_Lang._describeLang(lang)
        local palette = requirePalette(player, "lex", lang)
        if not palette then return end

        -- Native? Short-circuit with a different shape -- no acquisition tracking
        -- for native languages.
        local nativeOk, isNative =
            pcall(MC_Lang.isNative, username, lang)
        if not nativeOk or type(isNative) ~= "boolean" then
            reportBoundary(INCIDENT.state, "lex", "native-status")
            sysMsgRed(player,
                "Language status could not be verified. Nothing was inferred; check the server incident log.")
            return
        end
        if isNative then
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = string.format("%s: you natively speak this -- full fluency, no acquisition tracking.", displayLang),
                color = MC_Core.Colors.SOFT_PURPLE,
            })
            return
        end

        local acquired, count, lexSize =
            requireAcquiredSummary(player, "lex", username, lang, palette)
        if not acquired then return end

        -- Comprehension percentage (inline -- saves a separate /comp).
        local pctOk, pct = pcall(
            MC_Acquisition.estimateComprehension,
            username, lang, palette)
        if not pctOk or type(pct) ~= "number" or pct ~= pct
            or pct < 0 or pct > 100 or pct ~= math.floor(pct) then
            reportBoundary(INCIDENT.state, "lex", "comprehension")
            sysMsgRed(player,
                "Comprehension could not be verified. No estimate was inferred; check the server incident log.")
            return
        end

        if count == 0 then
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = string.format("%s (learning): no words acquired yet (0 / %d).", displayLang, lexSize),
                color = {200, 200, 200},
            })
            -- Even with no acquisitions, show near-acquisition words if any.
        else
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = string.format(
                    "%s (learning): %d / %d words acquired, ~%d%% comprehension.",
                    displayLang, count, lexSize, pct),
                color = {140, 200, 220},
            })

            -- Fading detection: acquired words past their receptive grace
            -- period are actively decaying. A quiet "[fading]" suffix lets
            -- the player know "use it or lose it" without engine narration.
            local now = MC_Core.getTimeSeconds()
            local graceSeconds = MC_Acquisition.graceDaysReceptive()
                * MC_Acquisition.secondsPerDay()

            for _, entry in ipairs(acquired) do
                local voiceBits
                if (entry.voices or 1) >= MC_Acquisition.voicesTrackCap() then
                    voiceBits = MC_Acquisition.voicesTrackCap() .. "+ voices"
                elseif (entry.voices or 1) == 1 then
                    voiceBits = "1 voice"
                else
                    voiceBits = entry.voices .. " voices"
                end
                local fadeSuffix = ""
                if entry.lastHeard and (now - entry.lastHeard) > graceSeconds then
                    fadeSuffix = "  [fading]"
                end
                local glossSuffix = entry.misacquired and " (?)" or ""
                sendServerCommand(player, "MongooseChat", "SystemMessage", {
                    message = string.format("  %s = %s%s  (%s; %s)%s",
                        entry.l2, entry.l1, glossSuffix, entry.state, voiceBits, fadeSuffix),
                    color = entry.misacquired and {220, 190, 150}
                        or (fadeSuffix ~= "" and {180, 160, 160} or {200, 200, 200}),
                })
            end
        end

        -- Near-acquisition: words the player is CLOSE to acquiring but
        -- hasn't crossed yet. Shows L2 forms only -- no L1 gloss, because
        -- the player should discover the meaning through exposure, not by
        -- reading /lex. Limited to 5 words, sorted by proximity (closest
        -- to acquisition first). Only shown if any exist.
        local threshold = MC_Acquisition.acquisitionThreshold()
        local rankMap = MC_Lang._getZipfRankMap(palette)
        local reverse = MC_Lang._getReverseLex(palette)
        local familyCloseness = MC_Acquisition.familyClosenessForLang(lang)
        local all = MC_Acquisition.getAllTokens(username, lang)
        local emerging = {}
        for token, exp in pairs(all) do
            if not exp.acquired and (exp.count or 0) > 0 then
                local rank = rankMap and rankMap[token:lower()] or nil
                -- Only show tokens the palette currently lexicalizes.
                local conceptId = reverse and reverse[token:lower()] or nil
                if conceptId then
                    local prob = MC_Acquisition.comprehensionProb(
                        exp.count or 0, exp.contextBoost or 1.0,
                        rank, familyCloseness)
                    -- Show words at 50%+ of threshold (meaningful proximity).
                    if prob >= threshold * 0.5 then
                        emerging[#emerging + 1] = { l2 = token, prob = prob }
                    end
                end
            end
        end
        if #emerging > 0 then
            table.sort(emerging, function(a, b) return a.prob > b.prob end)
            local shown = {}
            for i = 1, math.min(5, #emerging) do
                shown[#shown + 1] = emerging[i].l2
            end
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = "  Emerging: " .. table.concat(shown, ", "),
                color = {210, 190, 140},
            })
        end

        -- Profile marker (test servers) and hint.
        if MC_Acquisition.activeProfile() ~= "live" then
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = "  [" .. MC_Acquisition.activeProfile() .. " profile]",
                color = {200, 200, 200},
            })
        end
        return
    end

    -- No arg: layered summary. Native languages first (with cultural-fluency
    -- note), learning languages below with progress.
    local langs = requireLanguageList(player, "lex")
    if not langs then return end
    local palettes = requireAllPalettes(player, "lex", langs)
    if not palettes then return end
    local nativeOk, nativeList =
        pcall(MC_Lang.getNativeLanguages, username)
    if not nativeOk or type(nativeList) ~= "table" then
        reportBoundary(INCIDENT.state, "lex", "native-languages")
        sysMsgRed(player,
            "Language status could not be verified. Nothing was inferred; check the server incident log.")
        return
    end

    local nativeSet, nativeDisplay = {}, {}
    local nativeCount, hasEnglish = 0, false
    for index, lang in pairs(nativeList) do
        if type(index) ~= "number" or index < 1
            or index ~= math.floor(index)
            or not validIdentityString(lang)
            or nativeSet[lang] then
            reportBoundary(INCIDENT.state, "lex", "native-languages")
            sysMsgRed(player,
                "Language status could not be verified. Nothing was inferred; check the server incident log.")
            return
        end
        nativeSet[lang] = true
        nativeCount = nativeCount + 1
        if lang == "english" then hasEnglish = true end
    end
    if nativeCount ~= #nativeList or not hasEnglish then
        reportBoundary(INCIDENT.state, "lex", "native-languages")
        sysMsgRed(player,
            "Language status could not be verified. Nothing was inferred; check the server incident log.")
        return
    end
    for _, lang in ipairs(nativeList) do
        nativeDisplay[#nativeDisplay + 1] =
            MC_Lang._describeLang(lang)
    end

    local learningLines = {}
    for _, lang in ipairs(langs) do
        if lang ~= "english" and not nativeSet[lang] then
            local acquired, count, lexSize =
                requireAcquiredSummary(
                    player, "lex", username, lang, palettes[lang])
            if not acquired then return end
            local displayLang = MC_Lang._describeLang(lang)
            if count > 0 or lexSize > 0 then
                learningLines[#learningLines + 1] =
                    string.format("  %s: %d / %d",
                        displayLang, count, lexSize)
            end
        end
    end

    local impactOk, taughtWords, taughtLearners =
        pcall(MC_Acquisition.teachingImpact, username)
    if not impactOk or type(taughtWords) ~= "number"
        or taughtWords < 0 or taughtWords ~= math.floor(taughtWords)
        or type(taughtLearners) ~= "number" or taughtLearners < 0
        or taughtLearners ~= math.floor(taughtLearners) then
        reportBoundary(INCIDENT.state, "lex", "teaching-impact")
        sysMsgRed(player,
            "Language history could not be verified. Nothing was inferred; check the server incident log.")
        return
    end

    sendServerCommand(player, "MongooseChat", "SystemMessage", {
        message = "Languages:",
        color = {140, 200, 220},
    })

    -- Native section.
    if #nativeList == 1 then
        -- Only English -- common case for new players.
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "  Native: English",
            color = MC_Core.Colors.SOFT_PURPLE,
        })
    else
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "  Native: " .. table.concat(nativeDisplay, ", "),
            color = MC_Core.Colors.SOFT_PURPLE,
        })
    end

    -- Learning section.
    if #learningLines > 0 then
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "  Learning:",
            color = {200, 200, 200},
        })
        for _, line in ipairs(learningLines) do
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = line,
                color = {200, 200, 200},
            })
        end
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Use /lex <language> for the full word list."
                .. (MC_Acquisition.activeProfile() ~= "live"
                    and "  [" .. MC_Acquisition.activeProfile() .. " profile]" or ""),
            color = {200, 200, 200},
        })
    end

    -- Teaching impact: how many words have YOU been firstVoice for?
    -- Only shown if the player has taught at least one word to someone.
    if taughtWords > 0 then
        local learnersNote = taughtLearners == 1
            and "1 person"
            or (taughtLearners .. " people")
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = string.format(
                "  You've been the first voice for %d word%s, for %s.",
                taughtWords, taughtWords == 1 and "" or "s", learnersNote),
            color = {210, 190, 140},
        })
    end
end

-- /comp COMMAND
-- 
-- Estimate the player's comprehension percentage for one or all languages.
-- Computed from acquired count / dictionary size -- a rough proxy, not a true
-- fluency metric. Useful for the player to gauge progress.
-- 
-- Usage:
--   /comp            -> all non-English languages
--   /comp french     -> single language

function MC_LangCommands.handleCompCommand(player, argString)
    local username = requirePlayerUsername(player, "comp")
    if not username then return end
    if not requireLanguageAndAcquisition(player, "comp") then return end
    if argString ~= nil and type(argString) ~= "string" then
        reportBoundary(INCIDENT.state, "comp", "arguments")
        return
    end

    local arg = argString and argString:match("^%s*(%S+)%s*$") or nil

    local function reportOne(lang, palette)
        local countOk, _, total = pcall(
            MC_Acquisition.acquiredCountForPalette,
            username, lang, palette)
        if not countOk or type(total) ~= "number" or total ~= total
            or total <= 0 or total ~= math.floor(total) then
            reportBoundary(INCIDENT.state, "comp", "denominator")
            sysMsgRed(player,
                "Comprehension could not be verified. No estimate was inferred; check the server incident log.")
            return false
        end

        local nativeOk, isNative =
            pcall(MC_Lang.isNative, username, lang)
        if not nativeOk or type(isNative) ~= "boolean" then
            reportBoundary(INCIDENT.state, "comp", "native-status")
            sysMsgRed(player,
                "Comprehension could not be verified. No estimate was inferred; check the server incident log.")
            return false
        end

        local pct
        if isNative then
            pct = 100
        else
            -- estimateComprehension already returns 0-100 (integer
            -- percentage), not a 0-1 ratio.
            local pctOk
            pctOk, pct = pcall(
                MC_Acquisition.estimateComprehension,
                username, lang, palette)
            if not pctOk or type(pct) ~= "number" or pct ~= pct
                or pct < 0 or pct > 100
                or pct ~= math.floor(pct) then
                reportBoundary(INCIDENT.state, "comp", "estimate")
                sysMsgRed(player,
                    "Comprehension could not be verified. No estimate was inferred; check the server incident log.")
                return false
            end
        end

        local displayLang = MC_Lang._describeLang(lang)
        local line
        if isNative then
            line = string.format("  %s: 100%% (native; of %d words)",
                displayLang, total)
        else
            line = string.format("  %s: ~%d%% (of %d words)",
                displayLang, pct, total)
        end
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = line,
            color = {200, 200, 200},
        })
        return true
    end

    if arg then
        local lang = arg:lower()
        if not MC_LangRegistry.isKnownLanguage(lang) then
            unknownLanguageMsg(player)
            return
        end
        if lang == "english" then
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = "English: 100% (baseline).",
                color = {140, 200, 220},
            })
            return
        end
        local palette = requirePalette(player, "comp", lang)
        if not palette then return end
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Estimated comprehension:",
            color = {140, 200, 220},
        })
        reportOne(lang, palette)
        return
    end

    -- No arg: all non-English languages.
    local langs = requireLanguageList(player, "comp")
    if not langs then return end
    local palettes = requireAllPalettes(player, "comp", langs)
    if not palettes then return end
    sendServerCommand(player, "MongooseChat", "SystemMessage", {
        message = "Estimated comprehension:",
        color = {140, 200, 220},
    })
    local anyShown = false
    for _, lang in ipairs(langs) do
        if lang ~= "english" then
            if reportOne(lang, palettes[lang]) then
                anyShown = true
            else
                return
            end
        end
    end
    if not anyShown then
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "  (no non-English languages registered)",
            color = {200, 200, 200},
        })
    end
end

return MC_LangCommands
