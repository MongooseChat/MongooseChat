--[[
================================================================================
    MongooseChat - Server Handler
    
    Server-side message processing. Receives chat messages from clients,
    calculates proximity, routes to players in range, handles radio
    transmission with weather-based signal degradation.
    
    RESPONSIBILITIES:
    - Proximity calculation for all chat channels
    - Radio receiver discovery and message routing
    - Weather interference calculation
    - Zombie attraction sound generation
    - Message logging
    - Slash-command dispatch (/lang, /lex, /comp, /forget, /hue, /ll)
    - /tell target resolution
    - Bio/tagline storage
    - Description (character sheet) storage
    - Personal notes storage
    - Name color (/hue) storage
    - Admin language grant/revoke (GrantLanguage/RevokeLanguage)
    - Boredom reduction (ReduceBoredom)
    - Fresh-character detection (carried-over language state on a new body)

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Config = require("MC_Config")
local MC_Radio = require("MC_Radio")
local MC_Lang = require("MC_Lang")
local MC_LangCommands = require("MC_LangCommands")
local MC_LangRegistry = require("MC_LangRegistry")
local MC_Acquisition = require("MC_Acquisition")
local MC_Persist = require("MC_Persist")
local MC_HueNames = require("MC_HueNames")
local MC_Incident = require("MC_Incident")
local MC_ConnectionNotifs = require("MC_ConnectionNotifs")

local dbg = MC_Core.debugger("SERVER")

local MC_Server = {}

-- MC_Acquisition stays lifecycle/engine pure; the composition root supplies
-- its objective-level health reporter.
MC_Acquisition.setIncidentSink(function(code, detail)
    MC_Incident.report(code, detail)
end)

-- LANGUAGE IDENTIFICATION CACHE
-- A listener who has never acquired a word in a language doesn't know what
-- language they're hearing -- they see babble with no [Turkish] tag. Once
-- any word crosses the acquisition threshold, they've identified the
-- language and the tag appears for the rest of the session. Cache avoids
-- scanning the token table on every message; reset on server restart
-- (after restart, identification requires at least one currently-acquired
-- word). Natives always identify (they know their own language by
-- definition). Design note: identification is permanent -- even if a
-- player later forgets all their words, they still recognise the language
-- when they hear it, the same way a human who has forgotten their high-
-- school French still knows French when they hear it.
local identifiedLangs = {}   -- [username] = { [lang] = true }

local function hasIdentifiedLanguage(username, lang)
    if not username or not lang then return false end
    local userCache = identifiedLangs[username]
    if userCache and userCache[lang] then return true end
    if MC_Acquisition.hasAcquiredAny(username, lang) then
        if not identifiedLangs[username] then
            identifiedLangs[username] = {}
        end
        identifiedLangs[username][lang] = true
        return true
    end
    return false
end

-- Recognition is part of a character's lived language identity too. Keep it
-- in the same total-wipe registry as durable stores so neither an operator
-- reset nor a fresh body inherits the previous character's session cache.
MC_Lang.registerWipeExtension("identified_languages", {
    label = "Recognised languages (session)",
    inventory = function(username)
        local held = identifiedLangs[username]
        if held == nil then return nil, true end
        local count = MC_Core.tableSize(held)
        if count == 0 then return "an empty session cache key", true end
        return tostring(count) .. " recognised language(s)", true
    end,
    clear = function(username)
        if identifiedLangs[username] == nil then return false end
        identifiedLangs[username] = nil
        return true
    end,
})

-- ARG VALIDATION HELPERS
-- Malicious/broken clients can send anything in the args table. All reads
-- from args.* should be type-validated before use (C15 hardening in 0.8.0).

-- Returns a clean string from an args field, or nil if not a non-empty string.
-- Strips control characters to prevent log/UI injection.
local function validString(val, maxLen)
    if type(val) ~= "string" then return nil end
    if val == "" then return nil end
    -- Strip control chars (newlines, tabs, etc.) -- taglines and usernames
    -- never legitimately contain them, and they corrupt log lines.
    val = val:gsub("[%c]", "")
    if maxLen and #val > maxLen then
        val = val:sub(1, maxLen)
    end
    if val == "" then return nil end
    return val
end

-- PER-PLAYER STORE FACTORY
-- Bio, Description, Notes, and Hue below each open an MC_Persist A/B store,
-- keep an in-memory cache, save/load through the same disk idiom, and join
-- the /lang resetall wipe. makeStore() carries that shared shape. What
-- genuinely differs per store -- Notes' two-level [viewer][target] keys,
-- each store's own load-time value validation, and the wipe-extension
-- inventory/clear + broadcast (push vs. none) -- stays out of the factory,
-- as spec fields or as code written per store below.
--
-- spec = {
--     persistName = "MC_Taglines",   -- required; MC_Persist.open's name
--     legacyFile  = SAVE_FILE,       -- optional pre-A/B migration fallback
--     field       = "taglines",      -- key inside the persisted {field=...} table
--     label       = "Bio",           -- feeds dbg lines ("<label> storage: ...")
    --     cleanEntry  = function(raw) ... end,
    --         -- Validates/copies ONE raw persisted value for a flat
    --         -- [username] -> value store. Returning nil invalidates the
    --         -- complete slot; entries are never silently dropped.
    --     validateMap = function(rawMap) ... end,
    --         -- OPTIONAL whole-map validator for nested stores such as Notes.
--     loadFromDisk = function(store) ... end,
--         -- OPTIONAL full override, for a store whose key shape isn't flat
--         -- (Notes' two-level notes[viewer][target]).
-- }
-- returns {
--     store = <MC_Persist store>, db = { [field] = {} },
--     ensureLoaded = fn, transact = fn
-- }
local AUX_STORE_SCHEMA_VERSION = 1

local function makeStore(spec)
    local schemaId = "MongooseChat/" .. spec.persistName
    local schemaMigrated = false

    local function hasOnlyPayloadKeys(d)
        for key in pairs(d) do
            if key ~= "schema" and key ~= "version" and key ~= spec.field then
                return false
            end
        end
        return true
    end

    local function validateMap(map)
        if type(map) ~= "table" then return false end
        if type(spec.validateMap) == "function" then
            return spec.validateMap(map) == true
        end
        for key, raw in pairs(map) do
            if type(key) ~= "string" or key == ""
                or spec.cleanEntry(raw) == nil then
                return false
            end
        end
        return true
    end

    local function validatePayload(d)
        if type(d) ~= "table" then return false end

        -- Explicit one-way migration for the pre-schema auxiliary stores.
        -- Validation still occurs before migration, and an unknown/partial
        -- schema is never interpreted as the old format.
        if d.schema == nil and d.version == nil then
            for key in pairs(d) do
                if key ~= spec.field then return false end
            end
            if not validateMap(d[spec.field]) then return false end
            d.schema = schemaId
            d.version = AUX_STORE_SCHEMA_VERSION
            schemaMigrated = true
        end

        return d.schema == schemaId
            and d.version == AUX_STORE_SCHEMA_VERSION
            and hasOnlyPayloadKeys(d)
            and validateMap(d[spec.field])
    end

    local store = MC_Persist.open({
        name       = spec.persistName,
        legacyFile = spec.legacyFile,
        validate   = validatePayload,
    })

    local db = { [spec.field] = {} }
    local initialized = false
    local available = false

    -- Store payloads are JSON-shaped tables (strings/numbers/booleans/tables).
    -- A transaction snapshots the complete per-store value before applying a
    -- mutation. Replacing db[field] on failure is intentional: no caller keeps
    -- a durable reference to that table, and it guarantees nested Notes rows
    -- roll back along with flat stores.
    local function clone(value, seen)
        if type(value) ~= "table" then return value end
        seen = seen or {}
        if seen[value] then return seen[value] end
        local out = {}
        seen[value] = out
        for k, v in pairs(value) do
            out[clone(k, seen)] = clone(v, seen)
        end
        return out
    end

    local function incident(code, action)
        MC_Incident.report(code,
            "store=" .. spec.persistName .. " action=" .. tostring(action or "unknown"))
    end

    local function saveToDisk()
        -- store:save() is internally pcall-wrapped, read-back verified, and
        -- warns loudly on failure.
        if not store:save({
            schema = schemaId,
            version = AUX_STORE_SCHEMA_VERSION,
            [spec.field] = db[spec.field],
        }) then
            dbg("%s storage: save failed (see PERSIST warnings)", spec.label)
            return false
        end
        dbg("%s storage: saved %d to disk", spec.label, MC_Core.tableSize(db[spec.field]))
        return true
    end

    local function defaultLoadFromDisk()
        local data, source = store:load()
        if source == "unavailable" then
            dbg("%s storage: unavailable; refusing mutations", spec.label)
            return {}, source
        end
        if not data or type(data[spec.field]) ~= "table" then
            dbg("%s storage: no save data found, starting fresh", spec.label)
            return {}, source
        end
        -- The payload validator already proved every key/value. cleanEntry is
        -- now a copying/normalization step only; nil is unreachable here for a
        -- valid slot and is never a corruption-recovery fallback.
        local clean = {}
        for key, raw in pairs(data[spec.field]) do
            if type(key) == "string" then
                local v = spec.cleanEntry(raw)
                if v ~= nil then clean[key] = v end
            end
        end
        dbg("%s storage: loaded %d from disk (source: %s)",
            spec.label, MC_Core.tableSize(clean), tostring(source))
        return clean, source
    end

    local loadFromDisk = spec.loadFromDisk or defaultLoadFromDisk

    local function ensureLoaded()
        if initialized then return available end
        initialized = true
        local loadedValue, source = loadFromDisk(store)
        db[spec.field] = type(loadedValue) == "table" and loadedValue or {}
        available = source ~= "unavailable"
            and store:getLoadStatus() ~= "unavailable"
        if schemaMigrated and available then
            MC_Incident.report("AUX_STORE_SCHEMA_MIGRATED",
                "store=" .. spec.persistName .. " version="
                    .. tostring(AUX_STORE_SCHEMA_VERSION))
            schemaMigrated = false
        end
        if not available then
            incident("AUX_STORE_UNAVAILABLE", "load")
        end
        dbg("%s storage: initialized with %d", spec.label, MC_Core.tableSize(db[spec.field]))
        return available
    end

    -- mutator(table) -> changed
    -- A verified disk write is the commit point. Unavailable storage, a
    -- throwing mutator, or a failed/read-back-mismatched write all restore the
    -- exact pre-operation value and return false. Callers must only broadcast
    -- or confirm success after a true return.
    local function transact(action, mutator)
        if not ensureLoaded() then
            incident("AUX_STORE_UNAVAILABLE", action)
            return false
        end
        local before = clone(db[spec.field])
        local ok, changed = pcall(mutator, db[spec.field])
        if not ok then
            db[spec.field] = before
            incident("AUX_STORE_MUTATION_FAILED", action)
            return false
        end
        if changed ~= true then return true, false end
        if not saveToDisk() then
            db[spec.field] = before
            incident("AUX_STORE_SAVE_FAILED", action)
            return false
        end
        return true, true
    end

    Events.OnServerStarted.Add(function()
        ensureLoaded()
    end)

    return {
        store = store,
        db = db,
        ensureLoaded = ensureLoaded,
        transact = transact,
    }
end

-- Shared cleanEntry for the two flat string stores (bio/description): the
-- persisted value must be a string, or the entry is dropped.
local function cleanStringEntry(v)
    if type(v) == "string" then return v end
    return nil
end

-- A durable identity clear and its live cache retraction are one logical
-- operation. If the disk commit lands but the roster cannot be read, retain a
-- retry token: the next fresh-character pass must send the retraction before it
-- may stamp the new body, even though disk inventory is already empty.
local pendingIdentityRetractions = {
    bio = {},
    description = {},
    notes = {},
}

-- Broadcast the SAME args to every online player -- the shape the bio/
-- description save+clear paths and the notes wipe below all need after a
-- store change lands, so every client's cache stays in sync.
local function broadcastToAll(command, args)
    local rosterOk, onlinePlayers = pcall(getOnlinePlayers)
    if not rosterOk or not onlinePlayers then
        MC_Incident.report("ONLINE_ROSTER_UNAVAILABLE",
            "stage=list command=" .. tostring(command))
        return false
    end

    local sizeOk, size = pcall(function() return onlinePlayers:size() end)
    if not sizeOk or type(size) ~= "number" or size ~= size
        or size <= -math.huge or size >= math.huge
        or size < 0 or size ~= math.floor(size) then
        MC_Incident.report("ONLINE_ROSTER_UNAVAILABLE",
            "stage=size command=" .. tostring(command))
        return false
    end

    local sentAll = true
    for i = 0, size - 1 do
        local getOk, target = pcall(function() return onlinePlayers:get(i) end)
        if not getOk or not target then
            sentAll = false
            MC_Incident.report("ONLINE_ROSTER_UNAVAILABLE",
                "stage=entry command=" .. tostring(command)
                    .. " index=" .. tostring(i))
        else
            local sendOk, result = pcall(sendServerCommand, target,
                "MongooseChat", command, args)
            if not sendOk or result == false then
                sentAll = false
                MC_Incident.report("SERVER_BROADCAST_FAILED",
                    "command=" .. tostring(command) .. " stage=transport")
            end
        end
    end
    return sentAll
end

local function tellStorageFailure(player)
    if not player then return end
    sendServerCommand(player, "MongooseChat", "SystemMessage", {
        message = "That change could not be safely stored. Nothing was changed; an incident was recorded.",
        color = {255, 100, 100},
    })
end

-- Bio/description/note writes use an explicit request/commit protocol. The
-- opaque client token is intentionally small and syntax-bounded; it is echoed
-- only to that authenticated client and never written into incident details.
local MUTATION_TOKEN_MAX_LENGTH = 48
local IDENTITY_MUTATION_KINDS = {
    BioSave = "bio",
    DescSave = "description",
    NoteSave = "note",
}

local function identityMutationKind(command)
    return IDENTITY_MUTATION_KINDS[command]
end

local function validMutationRequestToken(token)
    return type(token) == "string"
        and #token > 0
        and #token <= MUTATION_TOKEN_MAX_LENGTH
        and token:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function reportIdentityMutation(code, kind, stage)
    MC_Incident.report(code,
        "kind=" .. tostring(kind or "unknown")
            .. " stage=" .. tostring(stage or "unknown"))
end

local function sendIdentityMutationAck(player, kind, token, committed,
        reason, fields)
    if not player then
        reportIdentityMutation("IDENTITY_MUTATION_ACK_DELIVERY_FAILED",
            kind, "player")
        return false
    end
    if not validMutationRequestToken(token) then
        reportIdentityMutation("IDENTITY_MUTATION_REQUEST_MALFORMED",
            kind, "ack-token")
        return false
    end

    local payload = {
        kind = kind,
        requestToken = token,
        ok = committed == true,
    }
    if committed == true then
        if type(fields) ~= "table"
            or type(fields.propagated) ~= "boolean"
            or type(fields.value) ~= "string" then
            reportIdentityMutation(
                "IDENTITY_MUTATION_ACK_DELIVERY_FAILED",
                kind, "shape")
            return false
        end
        payload.value = fields and fields.value or ""
        payload.propagated = fields.propagated
        if fields and fields.username then
            payload.username = fields.username
        end
        if fields and fields.target then
            payload.target = fields.target
        end
    else
        payload.reason = reason or "internal_failure"
    end

    local ok, result = pcall(sendServerCommand, player,
        "MongooseChat", "IdentityMutationAck", payload)
    if not ok or result == false then
        reportIdentityMutation("IDENTITY_MUTATION_ACK_DELIVERY_FAILED",
            kind, "transport")
        return false
    end
    return true
end

local function rejectIdentityMutation(player, kind, token, reason,
        incidentCode, stage)
    reportIdentityMutation(incidentCode, kind, stage)
    if validMutationRequestToken(token) then
        sendIdentityMutationAck(player, kind, token, false, reason)
    end
    return false
end

local function authenticatedMutationUsername(player, kind, token)
    if not player then
        rejectIdentityMutation(nil, kind, token, "identity_unavailable",
            "IDENTITY_MUTATION_IDENTITY_UNAVAILABLE", "player")
        return nil
    end
    local ok, username = pcall(function() return player:getUsername() end)
    if not ok or type(username) ~= "string" or username == ""
        or #username > 64 or username:find("[%c]") then
        rejectIdentityMutation(player, kind, token, "identity_unavailable",
            "IDENTITY_MUTATION_IDENTITY_UNAVAILABLE", "username")
        return nil
    end
    return username
end

-- BIO/TAGLINE STORAGE
-- Uses direct file I/O for B42 persistence (nuclear option). Global ModData
-- and player:getModData() are both unreliable in B42 MP. We write JSON
-- directly to Zomboid/Lua/MongooseChat/MC_Taglines_{a,b}.txt (see
-- MC_Persist.lua for the crash-safety rationale).

local BIO_MAX_LENGTH = 80
local SAVE_FILE = "MC_Taglines.json"  -- legacy pre-A/B single file (read-only)

-- The legacy single file is the migration fallback and is never written
-- again. It was written by a hand-rolled encoder, but its output is valid
-- JSON ({"taglines":{...}}), so MC_Persist's MC_Json-based legacy path
-- decodes it directly. The hand-rolled codec (added in 0.7.9.5, pre-MC_Json)
-- is retired with this change.
local MC_Bio, MC_BioDB
do
    local s = makeStore({
        persistName = "MC_Taglines",
        legacyFile  = SAVE_FILE,
        field       = "taglines",
        label       = "Bio",
        cleanEntry  = cleanStringEntry,
    })
    MC_Bio = s
    MC_BioDB = s.db
end

-- The tagline store holds per-player data, so it joins the /lang resetall
-- total wipe (see MC_Lang.registerWipeExtension for the contract; the hue
-- registration below is its sibling). inventory feeds the preview a short
-- quote of the line; clear wipes, persists, and sends the same BioUpdate
-- broadcast BioSave sends on an ordinary change, so every online client's
-- cached copy empties out right away.
MC_Lang.registerWipeExtension("bio", {
    label = "Bio tagline",
    inventory = function(username)
        if not MC_Bio.ensureLoaded() then
            return "storage unavailable -- left untouched", false
        end
        local tagline = MC_BioDB.taglines[username]
        if tagline == nil then
            if pendingIdentityRetractions.bio[username] then
                return "live cache retraction pending", true
            end
            return nil, true
        end
        if tagline == "" then return "an empty persisted tagline key", true end
        if #tagline > 40 then
            tagline = tagline:sub(1, 40) .. "..."
        end
        return '"' .. tagline .. '"', true
    end,
    clear = function(username)
        if not MC_Bio.ensureLoaded() then return false end
        if MC_BioDB.taglines[username] ~= nil then
            local ok = MC_Bio.transact("resetall", function(taglines)
                taglines[username] = nil
                return true
            end)
            if not ok then return false end
            pendingIdentityRetractions.bio[username] = true
        end
        if not pendingIdentityRetractions.bio[username] then return false end
        -- Same broadcast as BioSave: online clients replace their cached
        -- tagline with the empty one and refresh the nameplate. Failure stays
        -- pending so a fresh marker cannot turn a missed retraction into
        -- inherited identity.
        if not broadcastToAll("BioUpdate",
            { username = username, tagline = "" }) then
            MC_Incident.report("IDENTITY_CACHE_RETRACTION_FAILED",
                "store=bio command=BioUpdate")
            return false
        end
        pendingIdentityRetractions.bio[username] = nil
        return true
    end,
})

-- DESCRIPTION / CHARACTER-SHEET STORAGE
-- A longer free-text description shown on the character sheet (right-click ->
-- Character Sheet). Parallel to the tagline store above, but in its own A/B
-- file so a description bug can never touch the proven tagline store. It joins
-- the /lang resetall wipe the same way. Multi-line: MC_Json escapes newlines,
-- so paragraphs round-trip through persistence intact.

local MC_Desc = makeStore({
    persistName = "MC_Descriptions",
    field       = "descriptions",
    label       = "Description",
    cleanEntry  = cleanStringEntry,
})
MC_Desc.max = 500

-- Strip control chars but KEEP newlines (the description is multi-line), trim
-- the ends, and cap length. The client sanitizes identically before sending.
function MC_Desc.sanitize(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[^\n%C]", "")
    text = text:gsub("^%s*(.-)%s*$", "%1")
    return text:sub(1, MC_Desc.max)
end

-- Descriptions are per-player data, so they join the /lang resetall total wipe
-- exactly as the tagline and hue stores do.
MC_Lang.registerWipeExtension("description", {
    label = "Character-sheet description",
    inventory = function(username)
        if not MC_Desc.ensureLoaded() then
            return "storage unavailable -- left untouched", false
        end
        local desc = MC_Desc.db.descriptions[username]
        if desc == nil then
            if pendingIdentityRetractions.description[username] then
                return "live cache retraction pending", true
            end
            return nil, true
        end
        if desc == "" then
            return "an empty persisted description key", true
        end
        desc = desc:gsub("\n", " ")
        if #desc > 40 then desc = desc:sub(1, 40) .. "..." end
        return '"' .. desc .. '"', true
    end,
    clear = function(username)
        if not MC_Desc.ensureLoaded() then return false end
        if MC_Desc.db.descriptions[username] ~= nil then
            local ok = MC_Desc.transact("resetall", function(descriptions)
                descriptions[username] = nil
                return true
            end)
            if not ok then return false end
            pendingIdentityRetractions.description[username] = true
        end
        if not pendingIdentityRetractions.description[username] then
            return false
        end
        if not broadcastToAll("DescUpdate",
            { username = username, description = "" }) then
            MC_Incident.report("IDENTITY_CACHE_RETRACTION_FAILED",
                "store=description command=DescUpdate")
            return false
        end
        pendingIdentityRetractions.description[username] = nil
        return true
    end,
})

-- PERSONAL NOTES STORAGE (private per-viewer remarks about other players)
-- notes[viewerUsername][targetUsername] = free text. STRICTLY private: the
-- server only ever sends a viewer their OWN notes, always keyed off the
-- authenticated sender username (never a client-supplied viewer field), so no
-- player can read or forge another's notes. Same A/B store idiom as the
-- tagline / description stores, but two-level keys don't fit makeStore's flat
-- cleanEntry shape, so Notes supplies its own loadFromDisk override.

local MC_Notes = makeStore({
    persistName  = "MC_Notes",
    field        = "notes",
    label        = "Notes",
    validateMap  = function(notes)
        for viewer, targets in pairs(notes) do
            if type(viewer) ~= "string" or viewer == ""
                or type(targets) ~= "table" then
                return false
            end
            for target, text in pairs(targets) do
                if type(target) ~= "string" or target == ""
                    or type(text) ~= "string" then
                    return false
                end
            end
        end
        return true
    end,
    loadFromDisk = function(store)
        local data, source = store:load()
        if source == "unavailable" then return {}, source end
        if not data or type(data.notes) ~= "table" then return {}, source end
        -- The store validator has already proven every nested key and value.
        -- Returning it intact is deliberate: malformed nested entries
        -- invalidate the whole slot instead of disappearing during cleanup.
        return data.notes, source
    end,
})
MC_Notes.max = 500

-- Keep newlines, strip other control chars, trim, cap. (Same as descriptions.)
function MC_Notes.sanitize(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[^\n%C]", "")
    text = text:gsub("^%s*(.-)%s*$", "%1")
    return text:sub(1, MC_Notes.max)
end

-- Broadcast that every viewer's note ABOUT `target` is gone, so open sheets and
-- caches drop it right away.
local function broadcastNoteAboutCleared(target)
    return broadcastToAll("NoteAboutCleared", { target = target })
end

-- /lang resetall wipes everything about a username: BOTH the notes they wrote
-- about others AND everyone's notes about them.
MC_Lang.registerWipeExtension("notes", {
    label = "Personal notes",
    inventory = function(username)
        if not MC_Notes.ensureLoaded() then
            return "storage unavailable -- left untouched", false
        end
        local n = 0
        local persisted = false
        local mine = MC_Notes.db.notes[username]
        if mine ~= nil then
            persisted = true
            n = n + MC_Core.tableSize(mine)
        end
        for viewer, targets in pairs(MC_Notes.db.notes) do
            if viewer ~= username and targets[username] ~= nil then
                persisted = true
                n = n + 1
            end
        end
        if n == 0 then
            if persisted then return "an empty persisted note key", true end
            if pendingIdentityRetractions.notes[username] then
                return "live cache retraction pending", true
            end
            return nil, true
        end
        return n .. " note(s)", true
    end,
    clear = function(username)
        if not MC_Notes.ensureLoaded() then return false end
        local hasPersisted = MC_Notes.db.notes[username] ~= nil
        if not hasPersisted then
            for _, targets in pairs(MC_Notes.db.notes) do
                if targets[username] ~= nil then
                    hasPersisted = true
                    break
                end
            end
        end
        if hasPersisted then
            local changed = false
            local ok, committed = MC_Notes.transact("resetall", function(notes)
                if notes[username] ~= nil then
                    notes[username] = nil
                    changed = true
                end
                for _, targets in pairs(notes) do
                    if targets[username] ~= nil then
                        targets[username] = nil
                        changed = true
                    end
                end
                return changed
            end)
            if not ok or not committed then return false end
            pendingIdentityRetractions.notes[username] = true
        end
        if not pendingIdentityRetractions.notes[username] then return false end
        if not broadcastNoteAboutCleared(username) then
            MC_Incident.report("IDENTITY_CACHE_RETRACTION_FAILED",
                "store=notes command=NoteAboutCleared")
            return false
        end
        pendingIdentityRetractions.notes[username] = nil
        return true
    end,
})

-- NAME COLOR (/hue) STORAGE
-- Per-username chosen chat-name color, {r, g, b} 0-255. Same direct file
-- I/O rationale, same A/B crash-safe idiom, and same save cadence (write
-- through on every change) as the tagline store above. Consumed by
-- getPlayerColor below, so a chosen color flows everywhere playerColor
-- already flows with no other call-site changes.

-- One color component: an INTEGER in 0-255. The floor check matters: a
-- hand-edited or corrupt slot file could carry 100.5, which %d formatting
-- downstream does not tolerate on every VM. NaN fails the equality, inf
-- fails the range.
local function validHueComponent(v)
    return type(v) == "number" and v >= 0 and v <= 255
        and v == math.floor(v)
end

local MC_Hue, MC_HueDB
do
    local s = makeStore({
        persistName = "MC_Hues",
        field       = "hues",
        label       = "Hue",
        cleanEntry  = function(raw)
            if type(raw) == "table"
               and validHueComponent(raw[1])
               and validHueComponent(raw[2])
               and validHueComponent(raw[3]) then
                for key in pairs(raw) do
                    if key ~= 1 and key ~= 2 and key ~= 3 then return nil end
                end
                return { raw[1], raw[2], raw[3] }
            end
            return nil
        end,
    })
    MC_Hue = s
    MC_HueDB = s.db
end

-- RADIO STATIC SIMULATION
-- 
-- Moved to MC_Radio in v8.5.1 so the chunked variant could live alongside
-- and so the harness can exercise both. Access via MC_Radio.addPacketLoss
-- (flat string) and MC_Radio.addPacketLossToChunks (v8.5+ chunks). The
-- STATIC_POPS array and base rates also live on MC_Radio.

-- WEATHER INTERFERENCE
-- Bad weather = worse radio. Blizzards are brutal.

--[[
    Calculate weather-based interference multiplier
    @return number 1.0 (clear) to 3.0 (terrible conditions)
]]
local function getWeatherInterference()
    local function unavailable(field)
        MC_Incident.report("RADIO_WEATHER_UNAVAILABLE",
            "field=" .. tostring(field) .. "; maximum interference used")
        return 3.0
    end
    local function finite(value)
        return type(value) == "number"
            and value == value
            and value > -math.huge
            and value < math.huge
    end

    local okClimate, climate = pcall(getClimateManager)
    if not okClimate or not climate then return unavailable("manager") end

    local function readNumber(method)
        if type(climate[method]) ~= "function" then return nil end
        local ok, value = pcall(climate[method], climate)
        if not ok or not finite(value) then return nil end
        return value
    end

    local wind = readNumber("getWindIntensity")
    local rain = readNumber("getRainIntensity")
    local fog = readNumber("getFogIntensity")
    local temp = readNumber("getTemperature")
    if wind == nil then return unavailable("wind") end
    if rain == nil then return unavailable("rain") end
    if fog == nil then return unavailable("fog") end
    if temp == nil then return unavailable("temperature") end

    local thunderMethod
    if type(climate.isThunderStorming) == "function" then
        thunderMethod = climate.isThunderStorming
    elseif type(climate.getIsThunderStorming) == "function" then
        thunderMethod = climate.getIsThunderStorming
    else
        return unavailable("thunder")
    end
    local okThunder, thunder = pcall(thunderMethod, climate)
    if not okThunder or type(thunder) ~= "boolean" then
        return unavailable("thunder")
    end

    local multiplier = 1.0
    
    local isFreezing = temp < 0
    
    -- Wind interference (antenna sway, signal scatter)
    if wind > 0.7 then
        multiplier = multiplier + 0.8      -- High wind: +80%
    elseif wind > 0.5 then
        multiplier = multiplier + 0.4      -- Moderate wind: +40%
    elseif wind > 0.3 then
        multiplier = multiplier + 0.2      -- Light wind: +20%
    end
    
    -- Precipitation interference
    if rain > 0.7 then
        multiplier = multiplier + 0.6      -- Heavy rain/snow: +60%
    elseif rain > 0.4 then
        multiplier = multiplier + 0.3      -- Moderate: +30%
    end
    
    -- Thunderstorm (electrical interference)
    if thunder then
        multiplier = multiplier + 1.0      -- Thunder: +100% (doubles base)
    end
    
    -- Blizzard detection (freezing + wind + precipitation/fog)
    if isFreezing and wind > 0.4 and (rain > 0.2 or fog > 0.4) then
        multiplier = multiplier + 0.5      -- Blizzard bonus: +50% on top
    end
    
    -- Fog (signal absorption in moisture)
    if fog > 0.6 then
        multiplier = multiplier + 0.3      -- Dense fog: +30%
    end
    
    -- Cap at 3x to keep messages somewhat readable
    return math.min(multiplier, 3.0)
end

-- UTILITY FUNCTIONS

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function isStrictString(value, maxLength)
    return type(value) == "string"
        and value ~= ""
        and (not maxLength or #value <= maxLength)
        and value:find("[%c]") == nil
end

local function boundedContext(value)
    if type(value) ~= "string" then return "unknown" end
    return value:gsub("[^%w_-]", "_"):sub(1, 48)
end

-- Sandbox-backed values are provisional until OnServerStarted asks MC_Config
-- to reload the server's live namespace. A reported, conservative fallback
-- remains usable when reload completes non-authoritatively; an exception means
-- the reload itself could not be trusted, so objective-critical reads stop.
local sandboxReloadState = "unattempted"

local function criticalConfigUsable(context, field)
    if sandboxReloadState ~= "failed" then return true end
    MC_Incident.report("SERVER_CONFIG_UNAVAILABLE",
        "context=" .. boundedContext(context)
            .. " field=" .. boundedContext(field))
    return false
end

local GLOBAL_RANGE_CHANNELS = {
    all = true,
    admin = true,
    faction = true,
    safehouse = true,
    radio = true,
}

local function configuredRange(channel, context)
    if not criticalConfigUsable(context, "range") then return nil end
    if type(MC_Config.Ranges) ~= "table" then
        MC_Incident.report("CHANNEL_RANGE_UNAVAILABLE",
            "context=" .. boundedContext(context) .. " stage=table")
        return nil
    end
    local range = MC_Config.Ranges[channel]
    local valid = isFiniteNumber(range) and range <= 10000
    if valid then
        if GLOBAL_RANGE_CHANNELS[channel] then
            valid = (range == -1)
        else
            valid = (range >= 0)
        end
    end
    if not valid then
        MC_Incident.report("CHANNEL_RANGE_UNAVAILABLE",
            "context=" .. boundedContext(context)
                .. " channel=" .. boundedContext(channel)
                .. " stage=value")
        return nil
    end
    return range
end

local function configuredAddressedDistance(context)
    if not criticalConfigUsable(context, "addressed-distance") then return nil end
    local value = type(MC_Config.Lang) == "table"
        and MC_Config.Lang.addressedDistance or nil
    if not isFiniteNumber(value) or value < 0 or value > 10000 then
        MC_Incident.report("ADDRESSED_DISTANCE_UNAVAILABLE",
            "context=" .. boundedContext(context) .. " stage=value")
        return nil
    end
    return value
end

local function configuredMessageLimit()
    if not criticalConfigUsable("chat-envelope", "message-limit") then
        return nil
    end
    local value = MC_Config.MaxMessageLength
    if not isFiniteNumber(value) or value ~= math.floor(value)
        or value < 1 or value > 8192 then
        MC_Incident.report("MESSAGE_LIMIT_UNAVAILABLE",
            "context=chat-envelope stage=value")
        return nil
    end
    return value
end

local function readPlayerUsername(player, incidentCode, context)
    local ok, username = pcall(function() return player:getUsername() end)
    if not ok or not isStrictString(username, 64) then
        MC_Incident.report(incidentCode,
            "context=" .. boundedContext(context) .. " stage=username")
        return nil
    end
    return username
end

local function readOnlineId(player, incidentCode, context)
    local ok, onlineId = pcall(function() return player:getOnlineID() end)
    if not ok or not isFiniteNumber(onlineId)
        or onlineId < 0 or onlineId ~= math.floor(onlineId) then
        MC_Incident.report(incidentCode,
            "context=" .. boundedContext(context) .. " stage=online-id")
        return nil
    end
    return onlineId
end

local function snapshotOnlinePlayers(incidentCode, context)
    local rosterOk, onlinePlayers = pcall(getOnlinePlayers)
    if not rosterOk or not onlinePlayers then
        MC_Incident.report(incidentCode,
            "context=" .. boundedContext(context) .. " stage=list")
        return nil
    end

    local sizeOk, size = pcall(function() return onlinePlayers:size() end)
    if not sizeOk or not isFiniteNumber(size) or size < 0
        or size ~= math.floor(size) or size > 10000 then
        MC_Incident.report(incidentCode,
            "context=" .. boundedContext(context) .. " stage=size")
        return nil
    end

    local snapshot = {}
    for i = 0, size - 1 do
        local entryOk, entry = pcall(function()
            return onlinePlayers:get(i)
        end)
        if not entryOk or not entry then
            MC_Incident.report(incidentCode,
                "context=" .. boundedContext(context)
                    .. " stage=entry index=" .. tostring(i))
            return nil
        end
        snapshot[#snapshot + 1] = entry
    end
    return snapshot, onlinePlayers
end

-- Calculate distance between two players (2D, tile-based)
local function getDistance(player1, player2)
    local ok, x1, y1, x2, y2 = pcall(function()
        return player1:getX(), player1:getY(), player2:getX(), player2:getY()
    end)
    if not ok or not isFiniteNumber(x1) or not isFiniteNumber(y1)
        or not isFiniteNumber(x2) or not isFiniteNumber(y2)
    then
        MC_Incident.report("PROXIMITY_POSITION_UNAVAILABLE",
            "distance unavailable; delivery suppressed")
        return nil
    end
    local distanceOk, distance =
        pcall(MC_Core.distance2D, x1, y1, x2, y2)
    if not distanceOk or not isFiniteNumber(distance) or distance < 0 then
        MC_Incident.report("PROXIMITY_POSITION_UNAVAILABLE",
            "distance calculation invalid; delivery suppressed")
        return nil
    end
    return distance
end

-- Check if two players are in the same vehicle
local function inSameVehicle(player1, player2)
    local firstOk, v1 = pcall(function() return player1:getVehicle() end)
    local secondOk, v2 = pcall(function() return player2:getVehicle() end)
    if not firstOk or not secondOk then
        MC_Incident.report("VEHICLE_STATE_UNAVAILABLE",
            "stage=player-vehicle delivery=suppressed")
        return false, false
    end
    if not v1 or not v2 then return false, true end

    local firstIdOk, id1 = pcall(function() return v1:getId() end)
    local secondIdOk, id2 = pcall(function() return v2:getId() end)
    if not firstIdOk or not secondIdOk
        or not isFiniteNumber(id1) or not isFiniteNumber(id2)
        or id1 < 0 or id2 < 0
        or id1 ~= math.floor(id1) or id2 ~= math.floor(id2) then
        MC_Incident.report("VEHICLE_STATE_UNAVAILABLE",
            "stage=vehicle-id delivery=suppressed")
        return false, false
    end
    return id1 == id2, true
end

-- Get player's character name
local function getCharacterName(player)
    if not player then
        MC_Incident.report("CHARACTER_NAME_UNAVAILABLE", "player object unavailable")
        return nil
    end

    local descOk, desc = pcall(function() return player:getDescriptor() end)
    if descOk and desc then
        local firstOk, first = pcall(function() return desc:getForename() end)
        local lastOk, last = pcall(function() return desc:getSurname() end)
        if firstOk and lastOk
            and type(first) == "string" and #first <= 64
            and first:find("[%c]") == nil
            and type(last) == "string" and #last <= 256 then
            -- Strip tagline from surname (we append it with \n for display).
            local lastClean = last:match("^([^\r\n]*)") or ""
            if lastClean:find("[%c]") == nil then
                local name = (first .. " " .. lastClean):match("^%s*(.-)%s*$")
                if isStrictString(name, 128) then return name end
            end
        end
    end
    MC_Incident.report("CHARACTER_NAME_UNAVAILABLE",
        "descriptor/character name unavailable; message blocked")
    return nil
end

-- Generate a color for a player based on their username. A /hue choice
-- (see the hue storage above and the /hue handler below) takes precedence;
-- the deterministic hash is the default everyone starts with and /hue reset
-- returns to. Returned as a fresh table so downstream msgData mutation can
-- never reach back into the store.
local function getPlayerColor(username)
    local chosen = MC_HueDB.hues[username]
    if chosen then
        return { chosen[1], chosen[2], chosen[3] }
    end
    local hash = 0
    for i = 1, #username do
        hash = hash + string.byte(username, i)
    end
    return {
        150 + (hash % 105),
        150 + ((hash * 3) % 105),
        150 + ((hash * 7) % 105)
    }
end

-- Live identity-colour projection. The persisted hue remains the source of
-- truth; this session/revision pair only orders client cache updates.
local identityColorSession = nil
local identityColorRevisions = {}
-- Capability is tied to the authenticated account name for this server Lua
-- session.  Java can hand Lua two wrapper objects for the same live player,
-- so wrapper identity is not a stable key.  The validated username is.
local identityColorCapable = {}
do
    local now = MC_Core.safe(function() return MC_Core.getTimeSeconds() end, 0)
    local salt = MC_Core.safe(function() return ZombRand(1000000) end, 0)
    identityColorSession = "mc-" .. tostring(now) .. "-" .. tostring(salt)
end

local function identityColorPayload(player, revision)
    local username = readPlayerUsername(player,
        "IDENTITY_COLOR_IDENTITY_UNAVAILABLE", "sync")
    if not username then return nil end
    local characterName = getCharacterName(player)
    if not isStrictString(characterName, 128) then return nil end
    local color = getPlayerColor(username)
    return {
        protocol = 1, session = identityColorSession,
        revision = revision or identityColorRevisions[username] or 0,
        username = username, characterName = characterName,
        color = { color[1], color[2], color[3] },
        origin = MC_HueDB.hues[username] and "chosen" or "natural",
    }
end

local function identityColorRecipientHasAdminChat(player)
    -- B42 grants the engine tab by role capability, not by a role-name word.
    -- Use the same server-owned capability so a custom entitled role works
    -- and an ordinary client cannot gain the roster by claiming entitlement.
    local ok, entitled = pcall(function()
        if not Capability or not Capability.AdminChat then return false end
        local role = player:getRole()
        return role and role:hasCapability(Capability.AdminChat) == true
    end)
    return ok and entitled == true
end

local function sendIdentityColorTo(player, subject, revision)
    local payload = identityColorPayload(subject, revision)
    if not payload then return false end
    local ok, result = pcall(sendServerCommand, player,
        "MongooseChat", "IdentityColorSync", payload)
    return ok and result ~= false
end

local function publishIdentityColor(subject)
    local username = readPlayerUsername(subject,
        "IDENTITY_COLOR_IDENTITY_UNAVAILABLE", "publish")
    if not username then return false end
    local revision = (identityColorRevisions[username] or 0) + 1
    identityColorRevisions[username] = revision
    -- The authenticated subject always gets their own committed identity.
    -- Do not make this depend on a roster wrapper matching the command wrapper.
    local selfOk = sendIdentityColorTo(subject, subject, revision)
    local rosterOk, roster = pcall(getOnlinePlayers)
    if not rosterOk or not roster then return selfOk end
    for i = 0, roster:size() - 1 do
        local recipient = roster:get(i)
        local recipientName = readPlayerUsername(recipient,
            "IDENTITY_COLOR_IDENTITY_UNAVAILABLE", "recipient")
        if recipientName and recipientName ~= username
            and identityColorCapable[recipientName]
            and identityColorRecipientHasAdminChat(recipient) then
            sendIdentityColorTo(recipient, subject, revision)
        end
    end
    return true
end

local function sendIdentityColorSnapshot(player)
    local rosterOk, roster = pcall(getOnlinePlayers)
    if not rosterOk or not roster then return false end
    local rows = {}
    for i = 0, roster:size() - 1 do
        local row = identityColorPayload(roster:get(i))
        if not row then return false end
        row.protocol, row.session = nil, nil
        rows[#rows + 1] = row
    end
    local ok, result = pcall(sendServerCommand, player,
        "MongooseChat", "IdentityColorSnapshot", {
            protocol = 1, session = identityColorSession, rows = rows,
        })
    return ok and result ~= false
end

-- /HUE -- PLAYER-CHOSEN NAME COLOR
--
--   /hue                 -> show the current color (hex + r,g,b) and usage
--   /hue #RRGGBB         -> set (hash optional, case-insensitive)
--   /hue r,g,b           -> set (0-255, spaces around commas tolerated)
--   /hue reset           -> back to the default per-username hash color
--
-- Validation is AUTHORITATIVE here regardless of any client-side niceties
-- (same truth-lives-on-the-server pattern as /event and GrantLanguage).
-- The chosen color lands in the store getPlayerColor consults, so it flows
-- everywhere playerColor already flows -- and the client anonymity pass
-- still overwrites playerColor AFTER this server stamp, so a masked or
-- distant speaker's chosen shade never identifies them.

-- Hex digit tables, built once. Kahlua-safe on purpose: no reliance on
-- tonumber's base argument or string.format's %X, neither of which the
-- codebase uses anywhere else.
local HEX_VAL = {}
do
    local digits = "0123456789abcdef"
    for i = 1, 16 do
        local d = digits:sub(i, i)
        HEX_VAL[d] = i - 1
        HEX_VAL[d:upper()] = i - 1
    end
end
local HEX_CHR = "0123456789ABCDEF"

local function byteToHex(n)
    local hi = math.floor(n / 16)
    local lo = n - hi * 16
    return HEX_CHR:sub(hi + 1, hi + 1) .. HEX_CHR:sub(lo + 1, lo + 1)
end

-- "#C86450 (200,100,80)" -- the shape every /hue feedback line uses.
local function describeHue(c)
    return string.format("#%s%s%s (%d,%d,%d)",
        byteToHex(c[1]), byteToHex(c[2]), byteToHex(c[3]), c[1], c[2], c[3])
end

local function describeHueWithName(c)
    local name = MC_HueNames._approximate(c)
    if not name then return describeHue(c) end
    return describeHue(c) .. ". Approximate shade: " .. name
end

--[[
    Parse a /hue color argument (already trimmed).
    @return {r, g, b} on success; nil on malformed input; nil, "range" when
            the shape was right but a component fell outside 0-255.
]]
local function parseHueColor(arg)
    -- Hex form: exactly six characters after an optional '#'. Validated
    -- through HEX_VAL rather than a %x pattern so a near-miss ("banana")
    -- falls through to the r,g,b parse and then to the usage line.
    local hex = arg:match("^#?(......)$")
    if hex then
        local comps = {}
        for i = 1, 6, 2 do
            local hi = HEX_VAL[hex:sub(i, i)]
            local lo = HEX_VAL[hex:sub(i + 1, i + 1)]
            if not hi or not lo then
                comps = nil
                break
            end
            comps[#comps + 1] = hi * 16 + lo
        end
        if comps then return comps end
    end

    -- r,g,b form: bare digit runs (no signs, no decimals), commas required,
    -- spaces around them tolerated.
    local r, g, b = arg:match("^(%d+)%s*,%s*(%d+)%s*,%s*(%d+)$")
    if not r then return nil end
    r, g, b = tonumber(r), tonumber(g), tonumber(b)
    if r > 255 or g > 255 or b > 255 then return nil, "range" end
    return { r, g, b }
end

-- READABILITY GUARD. The chat panel is dark, so a name color must clear a
-- minimum relative luminance (0.299r + 0.587g + 0.114b) of 60 on the 0-255
-- scale (~24%). 60 keeps saturated jewel tones (crimson 200,30,30 = ~81)
-- while cutting shades that genuinely vanish against the night (pure blue
-- 0,0,255 = ~29). Compared x1000 in integers so the boundary is exact --
-- no float drift at exactly 60.
local HUE_MIN_LUMINANCE = 60

local function hueLuminanceOk(c)
    return (299 * c[1] + 587 * c[2] + 114 * c[3]) >= HUE_MIN_LUMINANCE * 1000
end

local HUE_USAGE = "Usage: /hue #RRGGBB or /hue r,g,b (0-255). " ..
    "/hue reset restores your default hue."

local function handleHueCommand(player, argString)
    if not player then return end
    local username = readPlayerUsername(
        player, "HUE_IDENTITY_UNAVAILABLE", "hue")
    if not username then return end
    if not MC_Hue.ensureLoaded() then
        tellStorageFailure(player)
        return
    end

    local arg = type(argString) == "string"
        and argString:match("^%s*(.-)%s*$") or ""

    -- Bare /hue: show the current color and how to change it.
    if arg == "" then
        local current = getPlayerColor(username)
        local origin = MC_HueDB.hues[username]
            and "This is a custom hue." or "This is your default hue."
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Current hue: " .. describeHueWithName(current) .. ". " .. origin,
            color = current,
        })
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = HUE_USAGE,
            color = {200, 200, 200},
        })
        return
    end

    -- /hue reset: back to the per-username hash default.
    if arg:lower() == "reset" then
        if MC_HueDB.hues[username] == nil then
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = "Your hue is already set to the default.",
                color = {200, 200, 200},
            })
            return
        end
        local ok = MC_Hue.transact("HueReset", function(hues)
            hues[username] = nil
            return true
        end)
        if not ok then
            tellStorageFailure(player)
            return
        end
        publishIdentityColor(player)
        local natural = getPlayerColor(username)
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Hue reset to default: " .. describeHueWithName(natural) .. ".",
            color = natural,
        })
        dbg("handleHueCommand: %s reset to hash color", username)
        return
    end

    local color, why = parseHueColor(arg)
    if not color then
        if why == "range" then
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = "RGB values must be between 0 and 255.",
                color = {255, 100, 100},
            })
        else
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = "Could not read that hue. " .. HUE_USAGE,
                color = {255, 100, 100},
            })
        end
        return
    end

    if not hueLuminanceOk(color) then
        -- REJECT, never silently clamp.
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "That hue is too dark for the chat window. Choose a brighter one.",
            color = {255, 100, 100},
        })
        return
    end

    local ok = MC_Hue.transact("HueSet", function(hues)
        hues[username] = { color[1], color[2], color[3] }
        return true
    end)
    if not ok then
        tellStorageFailure(player)
        return
    end
    publishIdentityColor(player)
    -- Success echoes the color back in-world: the line itself is rendered
    -- in the shade just chosen (it passed the readability guard).
    sendServerCommand(player, "MongooseChat", "SystemMessage", {
        message = "Hue set to " .. describeHueWithName(color) .. ".",
        color = { color[1], color[2], color[3] },
    })
    dbg("handleHueCommand: %s -> %s", username, describeHue(color))
end

-- The hue store holds per-player data, so it joins the /lang resetall
-- total wipe (see MC_Lang.registerWipeExtension for the contract; the bio
-- registration above is its sibling). inventory feeds the preview; clear
-- wipes, persists, and lets the next server stamp fall back to the hash
-- color on its own.
MC_Lang.registerWipeExtension("hue", {
    label = "Name color",
    inventory = function(username)
        if not MC_Hue.ensureLoaded() then
            return "storage unavailable -- left untouched", false
        end
        local hue = MC_HueDB.hues[username]
        if not hue then return nil, true end
        return "their chosen shade, " .. describeHue(hue), true
    end,
    clear = function(username)
        if not MC_Hue.ensureLoaded() then return false end
        if MC_HueDB.hues[username] == nil then return false end
        local ok = MC_Hue.transact("resetall", function(hues)
            hues[username] = nil
            return true
        end)
        return ok == true
    end,
})

-- MESSAGE DATA BUILDING

local MESSAGE_BUILD_FAILURE_TEXT = {
    speaker_identity =
        "Your message was not sent because your account identity could not be verified.",
    payload =
        "Your message was not sent because its message data was invalid.",
    clock =
        "Your message was not sent because the server clock was unavailable.",
    position =
        "Your message was not sent because your position could not be verified.",
    character_name =
        "Your message was not sent because your character name could not be verified.",
    name_color =
        "Your message was not sent because your character name color could not be verified.",
    internal =
        "Your message was not sent because the server could not safely assemble it.",
}

local function messageBuildFailureText(reason)
    return MESSAGE_BUILD_FAILURE_TEXT[reason]
        or MESSAGE_BUILD_FAILURE_TEXT.internal
end

local function buildMessageData(player, channel, message)
    local username = readPlayerUsername(
        player, "SPEAKER_ID_UNAVAILABLE", "message-build")
    if not username then
        return nil, "speaker_identity"
    end

    if not isStrictString(channel, 32) or type(message) ~= "string" then
        MC_Incident.report("MESSAGE_INVALID",
            "stage=message-build shape=invalid")
        return nil, "payload"
    end

    local timestampOk, timestamp = pcall(MC_Core.getTimeSeconds)
    if not timestampOk or not isFiniteNumber(timestamp)
        or timestamp < 0 or timestamp ~= math.floor(timestamp) then
        MC_Incident.report("MESSAGE_TIME_UNAVAILABLE",
            "stage=message-build")
        return nil, "clock"
    end

    local coordsOk, x, y, z = pcall(function()
        return player:getX(), player:getY(), player:getZ()
    end)
    if not coordsOk or not isFiniteNumber(x)
        or not isFiniteNumber(y) or not isFiniteNumber(z) then
        MC_Incident.report("SPEAKER_POSITION_UNAVAILABLE",
            "stage=message-build")
        return nil, "position"
    end

    local steamId
    local steamStatus = "unsupported"
    if type(getSteamIDFromUsername) == "function" then
        local steamOk, rawSteamId = pcall(
            getSteamIDFromUsername, username)
        if steamOk and type(rawSteamId) == "number"
            and isFiniteNumber(rawSteamId)
            and rawSteamId > 0 and rawSteamId == math.floor(rawSteamId) then
            rawSteamId = tostring(rawSteamId)
        end
        if steamOk and isStrictString(rawSteamId, 64)
            and rawSteamId:match("^%d+$")
            and not rawSteamId:match("^0+$") then
            steamId = rawSteamId
            steamStatus = "verified"
        elseif steamOk and (rawSteamId == nil or rawSteamId == ""
            or rawSteamId == 0 or rawSteamId == "0") then
            -- Dedicated-server B42.20 exposes the documented lookup but may
            -- have no username-to-Steam mapping at this Lua seam. This is an
            -- unavailable optional audit enrichment, not a corrupt identity:
            -- the authoritative account username above remains required.
            steamStatus = "unsupported"
        else
            steamStatus = "failed"
            MC_Incident.report("STEAM_ID_UNAVAILABLE",
                "stage=message-build lookup=failed")
        end
    end

    local characterName = getCharacterName(player)
    if not isStrictString(characterName, 128) then
        return nil, "character_name"
    end

    local colorOk, playerColor = pcall(getPlayerColor, username)
    if not colorOk or type(playerColor) ~= "table"
        or not validHueComponent(playerColor[1])
        or not validHueComponent(playerColor[2])
        or not validHueComponent(playerColor[3]) then
        MC_Incident.report("CHARACTER_NAME_COLOR_UNAVAILABLE",
            "stage=message-build")
        return nil, "name_color"
    end

    return {
        timestamp = timestamp,
        channel = channel,
        steamId = steamId,
        steamStatus = steamStatus,
        username = username,
        characterName = characterName,
        playerColor = playerColor,
        message = message,
        coords = { x = x, y = y, z = z },
    }
end

-- LOGGING (for MongooseBot integration)

local function reportLogFailure(code, kind, stage)
    MC_Incident.report(code,
        "kind=" .. boundedContext(kind)
            .. " stage=" .. boundedContext(stage))
end

local function jsonEscape(value)
    return (value:gsub(".", function(ch)
        local byte = string.byte(ch)
        if ch == "\\" then return "\\\\" end
        if ch == '"' then return '\\"' end
        if ch == "\b" then return "\\b" end
        if ch == "\f" then return "\\f" end
        if ch == "\n" then return "\\n" end
        if ch == "\r" then return "\\r" end
        if ch == "\t" then return "\\t" end
        if byte and byte < 32 then
            return string.format("\\u%04x", byte)
        end
        return ch
    end))
end

local function lineSafe(value, maxLength)
    if type(value) ~= "string"
        or (maxLength and #value > maxLength) then
        return nil
    end
    return (value:gsub("[%c]", " "))
end

local function logPath(kind, failureCode)
    local serverOk, serverName = pcall(getServerName)
    if not serverOk or not isStrictString(serverName, 80)
        or serverName:find("[/\\:]") or serverName:find("..", 1, true) then
        reportLogFailure(failureCode, kind, "server-id")
        return nil
    end

    local basePath = MC_Config.Log and MC_Config.Log.path
    if type(basePath) ~= "string" or basePath == ""
        or #basePath > 160 or basePath:find("[%c]")
        or basePath:find("..", 1, true)
        or basePath:find("\\", 1, true)
        or basePath:sub(1, 1) == "/"
        or basePath:find(":", 1, true) then
        reportLogFailure(failureCode, kind, "config-path")
        return nil
    end

    local dateOk, date = pcall(os.date, "%Y-%m-%d")
    if not dateOk or type(date) ~= "string"
        or not date:match("^%d%d%d%d%-%d%d%-%d%d$") then
        reportLogFailure(failureCode, kind, "date")
        return nil
    end
    return basePath .. serverName .. "/" .. kind .. "-" .. date .. ".log"
end

local function writeLogLine(path, logLine, failureCode, kind)
    local openOk, file = pcall(getFileWriter, path, true, true)
    if not openOk or not file then
        reportLogFailure(failureCode, kind, "open")
        return false
    end

    local writeOk, writeResult = pcall(function()
        return file:writeln(logLine)
    end)
    if not writeOk or writeResult == false then
        -- Best-effort resource release only. A failed write can never become
        -- a successful audit record merely because this close succeeds.
        pcall(function() file:close() end)
        reportLogFailure(failureCode, kind, "write")
        return false
    end

    local closeOk, closeResult = pcall(function() return file:close() end)
    if not closeOk or closeResult == false then
        reportLogFailure(failureCode, kind, "close")
        return false
    end
    return true
end

local function validLogEnvelope(msgData, failureCode, kind)
    if type(msgData) ~= "table"
        or not isFiniteNumber(msgData.timestamp)
        or msgData.timestamp < 0
        or msgData.timestamp ~= math.floor(msgData.timestamp)
        or not isStrictString(msgData.channel, 32)
        or not isStrictString(msgData.username, 64)
        or not isStrictString(msgData.characterName, 128)
        or type(msgData.message) ~= "string"
        or #msgData.message > 8192
        or type(msgData.coords) ~= "table"
        or not isFiniteNumber(msgData.coords.x)
        or not isFiniteNumber(msgData.coords.y)
        or not isFiniteNumber(msgData.coords.z)
        or (msgData.steamId ~= nil
            and not isStrictString(msgData.steamId, 64))
        or (msgData.steamStatus ~= "verified"
            and msgData.steamStatus ~= "unsupported"
            and msgData.steamStatus ~= "failed") then
        reportLogFailure(failureCode, kind, "record-shape")
        return false
    end
    return true
end

local function logMessage(msgData)
    if not MC_Config.Log.enabled then return false, "disabled" end
    local failureCode = "CHAT_LOG_WRITE_FAILED"
    if not validLogEnvelope(msgData, failureCode, "chat") then
        return false, "invalid"
    end
    local path = logPath("chat", failureCode)
    if not path then return false, "path" end

    local logLine
    if MC_Config.Log.jsonFormat then
        local steamValue = msgData.steamId
            and ('"' .. jsonEscape(msgData.steamId) .. '"') or "null"
        logLine = string.format(
            '{"ts":%d,"ch":"%s","steam":%s,"steam_status":"%s","user":"%s","char":"%s","msg":"%s","x":%.1f,"y":%.1f,"z":%.1f}',
            msgData.timestamp,
            jsonEscape(msgData.channel),
            steamValue,
            jsonEscape(msgData.steamStatus),
            jsonEscape(msgData.username),
            jsonEscape(msgData.characterName),
            jsonEscape(msgData.message),
            msgData.coords.x,
            msgData.coords.y,
            msgData.coords.z
        )
    else
        local timeOk, time = pcall(os.date, "%H:%M:%S", msgData.timestamp)
        local channel = lineSafe(msgData.channel, 32)
        local username = lineSafe(msgData.username, 64)
        local characterName = lineSafe(msgData.characterName, 128)
        local message = lineSafe(msgData.message, 8192)
        if not timeOk or type(time) ~= "string"
            or not channel or not username or not characterName or not message then
            reportLogFailure(failureCode, "chat", "plain-record")
            return false, "invalid"
        end
        logLine = string.format(
            "%s [%s] %s (%s): %s",
            time,
            channel,
            username,
            characterName,
            message
        )
    end
    return writeLogLine(path, logLine, failureCode, "chat")
end

-- MONGOOSEBOT ANNOUNCEMENT INBOX (0.9.8)
--
-- The one inbound seam an external tool has: a single plain-text line in
-- MongooseChat/announce_inbox.txt, polled once a minute behind the
-- AnnounceFileEnabled sandbox gate (default off -- write access to the
-- server's Zomboid folder is operator-level access).
--
-- Protocol: the bot writes a temp file and renames it into place, and only
-- when the inbox is absent or empty (one announcement in flight at a time;
-- at most one per minute reaches players). The server consumes BEFORE it
-- broadcasts -- a file whose truncation cannot be confirmed is never
-- broadcast, because the alternative is a stuck file rebroadcasting every
-- minute forever. Malformed content is consumed the same way, then
-- discarded with an incident: this is untrusted boundary input, so an
-- oversize or multi-line payload is rejected whole, never trimmed to fit.

local function consumeAnnounceInbox(inbox)
    local writerOk, writer = pcall(getFileWriter, inbox, true, false)
    if not writerOk or not writer then return false end
    local wroteOk = pcall(function()
        writer:write("")
        writer:close()
    end)
    return wroteOk == true
end

local function pollAnnounceInbox()
    if not (MC_Config.Announce and MC_Config.Announce.fileEnabled) then return end

    local inbox = MC_Config.Announce.inboxFile
    if type(inbox) ~= "string" or inbox == "" then
        MC_Incident.report("ANNOUNCE_FILE_INVALID", "stage=config-path")
        return
    end

    local readOk, content = pcall(function()
        local reader = getFileReader(inbox, false)
        if not reader then return nil end
        local lines = {}
        local line = reader:readLine()
        while line ~= nil do
            lines[#lines + 1] = line
            line = reader:readLine()
        end
        reader:close()
        return lines
    end)
    if not readOk then
        MC_Incident.report("ANNOUNCE_FILE_INVALID", "stage=read")
        return
    end
    if content == nil then return end  -- no inbox file: the usual quiet tick

    -- Trim trailing blank lines (a trailing newline is not "content").
    while #content > 0 and content[#content]:match("^%s*$") do
        content[#content] = nil
    end
    if #content == 0 then return end  -- empty inbox: consumed state, no-op

    -- Whatever happens next, the inbox is spent: consume first, and treat
    -- an unconfirmed consume as fatal for this tick's payload.
    if not consumeAnnounceInbox(inbox) then
        MC_Incident.report("ANNOUNCE_FILE_CONSUME_FAILED", "stage=truncate")
        return
    end

    local message = content[1]
    if #content > 1 or not isStrictString(message, MC_Config.MaxMessageLength) then
        MC_Incident.report("ANNOUNCE_FILE_INVALID",
            "stage=validate shape=" .. (#content > 1 and "multi-line" or "line"))
        return
    end

    local timestampOk, timestamp = pcall(MC_Core.getTimeSeconds)
    if not timestampOk or not isFiniteNumber(timestamp)
        or timestamp < 0 or timestamp ~= math.floor(timestamp) then
        timestamp = 0
    end
    logMessage({
        timestamp = timestamp,
        channel = "announce",
        username = "MongooseBot",
        characterName = MC_Config.Announce.author,
        message = message,
        coords = { x = 0, y = 0, z = 0 },
        steamStatus = "unsupported",
    })

    if not broadcastToAll("SystemMessage", {
        message = message,
        author  = MC_Config.Announce.author,
        color   = MC_Config.Announce.color,
    }) then
        MC_Incident.report("SERVER_BROADCAST_FAILED", "command=AnnounceInbox")
    end
end

local function logRadioMessage(msgData, frequency, degradedMessage)
    if not MC_Config.Log.enabled then return false, "disabled" end
    local failureCode = "RADIO_LOG_WRITE_FAILED"
    if not validLogEnvelope(msgData, failureCode, "radio") then
        return false, "invalid"
    end
    if not isFiniteNumber(frequency) or frequency <= 0 then
        reportLogFailure(failureCode, "radio", "record-shape")
        return false, "invalid"
    end
    local path = logPath("radio", failureCode)
    if not path then return false, "path" end

    local timeOk, time = pcall(os.date, "%H:%M:%S", msgData.timestamp)
    local freqStr = string.format("%.2f", frequency / 1000)
    local messageToLog = degradedMessage or msgData.message
    local channel = lineSafe(msgData.channel, 32)
    local characterName = lineSafe(msgData.characterName, 128)
    local username = lineSafe(msgData.username, 64)
    local safeMessage = lineSafe(messageToLog, 8192)
    if not timeOk or type(time) ~= "string"
        or not channel or not characterName or not username or not safeMessage then
        reportLogFailure(failureCode, "radio", "plain-record")
        return false, "invalid"
    end

    local logLine = string.format(
        "%s [%s] %s (%s)[%sHz]: %s",
        time,
        channel,
        characterName,
        username,
        freqStr,
        safeMessage
    )
    local written = writeLogLine(path, logLine, failureCode, "radio")
    if written then dbg("logRadioMessage: write completed") end
    return written
end

-- Sidecar radio log for the Discord relay only. radio-*.log stays CLEAN so the
-- AI narrator can quote 100MHz verbatim and 350-400MHz linking codes match
-- exactly; this file instead carries the packet-loss corruption the
-- transmission actually produced, so the bridge relays the REAL in-game static
-- rather than inventing its own (which never matched what players saw in-game).
-- Each line is the standard radio line with the DEGRADED text, then a TAB and
-- the CLEAN text, so the bridge still has an uncorrupted copy for linking
-- verification. Both fields are control-char-stripped so the TAB delimiter and
-- the bridge's line-based parse stay unambiguous (see the note by the strip).
local function logRadioRelay(msgData, frequency, degradedMessage, cleanMessage)
    if not MC_Config.Log.enabled then return false, "disabled" end
    local failureCode = "RADIO_RELAY_LOG_WRITE_FAILED"
    if not validLogEnvelope(msgData, failureCode, "radio-relay") then
        return false, "invalid"
    end
    if not isFiniteNumber(frequency) or frequency <= 0 then
        reportLogFailure(failureCode, "radio-relay", "record-shape")
        return false, "invalid"
    end
    local path = logPath("radio-relay", failureCode)
    if not path then return false, "path" end

    local timeOk, time = pcall(os.date, "%H:%M:%S", msgData.timestamp)
    local freqStr = string.format("%.2f", frequency / 1000)
    -- Strip control chars from BOTH fields. corruptWords collapses INTERIOR
    -- whitespace to single spaces, but re-prepends the message's ORIGINAL
    -- leading/trailing whitespace (MC_Radio.corruptWords) -- which for a
    -- tampered/pasted client could be a TAB (breaking the delimiter) or a
    -- newline (breaking the bridge's line-based parse). Radio text never
    -- legitimately carries edge control chars, so this is invisible in the
    -- happy path and keeps the line unambiguous either way.
    local channel = lineSafe(msgData.channel, 32)
    local characterName = lineSafe(msgData.characterName, 128)
    local username = lineSafe(msgData.username, 64)
    local degraded = lineSafe(degradedMessage or msgData.message, 8192)
    local clean = lineSafe(cleanMessage or msgData.message, 8192)
    if not timeOk or type(time) ~= "string"
        or not channel or not characterName or not username
        or not degraded or not clean then
        reportLogFailure(failureCode, "radio-relay", "plain-record")
        return false, "invalid"
    end

    local logLine = string.format(
        "%s [%s] %s (%s)[%sHz]: %s\t%s",
        time,
        channel,
        characterName,
        username,
        freqStr,
        degraded,
        clean
    )
    local written = writeLogLine(
        path, logLine, failureCode, "radio-relay")
    if written then dbg("logRadioRelay: write completed") end
    return written
end

-- MAIN MESSAGE PROCESSING

-- /TELL TARGET RESOLUTION
-- Fuzzy-match a name query against online players' forenames within say
-- range. Exact case-insensitive match wins outright; prefix match needs a
-- unique winner. Returns (player, forename) on success, (nil, errString)
-- on failure.
local function resolveTellTarget(speaker, nameQuery)
    local infrastructureError =
        "The nearby-player roster could not be verified."
    if not isStrictString(nameQuery, 64) then
        MC_Incident.report("TELL_REQUEST_INVALID",
            "context=tell stage=name-query")
        return nil, "That player name could not be used."
    end

    local players = snapshotOnlinePlayers(
        "TELL_ROSTER_UNAVAILABLE", "tell")
    if not players then return nil, infrastructureError end

    local sayRange = configuredRange("say", "tell")
    if sayRange == nil then
        return nil, "The nearby speaking range could not be verified."
    end
    local speakerId = readOnlineId(
        speaker, "TELL_IDENTITY_UNAVAILABLE", "tell-speaker")
    if speakerId == nil then return nil, infrastructureError end

    local entries = {}
    local seenIds = {}
    local speakerCount = 0
    for _, target in ipairs(players) do
        local targetId = readOnlineId(
            target, "TELL_ROSTER_UNAVAILABLE", "tell-target")
        if targetId == nil then return nil, infrastructureError end
        if seenIds[targetId] then
            MC_Incident.report("TELL_ROSTER_UNAVAILABLE",
                "context=tell stage=duplicate-online-id")
            return nil, infrastructureError
        end
        seenIds[targetId] = true
        if targetId == speakerId then
            speakerCount = speakerCount + 1
        else
            local forenameOk, forename =
                pcall(function() return target:getForename() end)
            if not forenameOk or not isStrictString(forename, 64) then
                MC_Incident.report("TELL_ROSTER_UNAVAILABLE",
                    "context=tell stage=forename")
                return nil, infrastructureError
            end
            entries[#entries + 1] = {
                player = target,
                name = forename,
            }
        end
    end
    if speakerCount ~= 1 then
        MC_Incident.report("TELL_IDENTITY_UNAVAILABLE",
            "context=tell stage=speaker-roster")
        return nil, infrastructureError
    end

    local queryLower = nameQuery:lower()
    local exactCandidates = {}
    local prefixCandidates = {}
    for _, entry in ipairs(entries) do
        local forenameLower = entry.name:lower()
        local isExact = (forenameLower == queryLower)
        local isPrefix =
            (forenameLower:sub(1, #queryLower) == queryLower)
        if isExact or isPrefix then
            local distance = getDistance(speaker, entry.player)
            if distance == nil then
                MC_Incident.report("TELL_ROSTER_UNAVAILABLE",
                    "context=tell stage=position")
                return nil, infrastructureError
            end
            local inRange = distance <= sayRange
            if not inRange then
                local sameVehicle, vehicleAuthoritative =
                    inSameVehicle(speaker, entry.player)
                if not vehicleAuthoritative then
                    MC_Incident.report("TELL_ROSTER_UNAVAILABLE",
                        "context=tell stage=vehicle")
                    return nil, infrastructureError
                end
                inRange = sameVehicle
            end
            if inRange then
                local destination = isExact
                    and exactCandidates or prefixCandidates
                destination[#destination + 1] = entry
            end
        end
    end

    if #exactCandidates == 1 then
        return exactCandidates[1].player, exactCandidates[1].name, sayRange
    elseif #exactCandidates > 1 then
        return nil, "More than one nearby player is named '"
            .. nameQuery .. "'."
    end

    if #prefixCandidates == 1 then
        return prefixCandidates[1].player, prefixCandidates[1].name, sayRange
    elseif #prefixCandidates > 1 then
        local names = {}
        for _, c in ipairs(prefixCandidates) do names[#names + 1] = c.name end
        return nil, "Did you mean: " .. table.concat(names, ", ") .. "?"
    end
    return nil, "You don't see anyone named '" .. nameQuery .. "' nearby."
end

-- SLASH COMMAND DISPATCH
-- Maps a lower-cased command word (e.g. "/lang") to the handler that
-- services it. Each handler is a function(player, argString), called with
-- the same two arguments and given the same "return right after" treatment
-- the old per-command if-block gave it.
--
-- The KEY LIST is single-sourced from MC_Core.SERVER_SLASH_COMMANDS (shared
-- dir) -- MC_Input.lua's isMCServerCommand consumes the exact same array for
-- its client-side forward check, so the two can never hand-drift apart
-- again (see that constant's own comment). SLASH_HANDLER_IMPLS below
-- supplies the handler for each entry, IN THE SAME ORDER: the pairing is
-- positional by design, since the handler bodies themselves can't live in
-- MC_Core -- MC_LangCommands and handleHueCommand are server-only.
--
-- The five MC_LangCommands-owned handlers are wrapped in closures rather
-- than captured directly, to preserve late binding: MC_LangCommands.handleX
-- is looked up on the MC_LangCommands table at CALL time, exactly as the
-- old inline `MC_LangCommands.handleXCommand(...)` did. MC_LangCommands.lua
-- defines these as `function MC_LangCommands.foo(...)` at module load, so
-- in practice they're already attached by the time this file's
-- `require("MC_LangCommands")` returns -- but the ladder never depended on
-- that, and this table doesn't either: a closure re-reads the field on
-- every call, so it still picks up a reattached/replaced handler
-- (hot-reload, test monkey-patch) even after this table is built.
-- handleHueCommand is a plain local function defined earlier in this file
-- and never reassigned, so it's referenced directly.
local SLASH_HANDLER_IMPLS = {
    -- /lang <language>             -> self-set (any player)
    -- /lang "<character>" <lang>   -> admin-set on target character (admin only)
    -- /lang <character> <lang>     -> same, unquoted (single-word names)
    -- Parsing lives in MC_LangCommands.handleSetCommand; we just forward argString.
    function(player, argString) return MC_LangCommands.handleSetCommand(player, argString) end,

    -- /lex             -> summary across all non-English languages
    -- /lex <language>  -> detailed list with L1 meanings
    function(player, argString) return MC_LangCommands.handleLexCommand(player, argString) end,

    -- /comp            -> all non-English languages
    -- /comp <language> -> single language
    function(player, argString) return MC_LangCommands.handleCompCommand(player, argString) end,

    -- /forget <language>          -> preview what would be lost
    -- /forget <language> confirm  -> let the language go
    function(player, argString) return MC_LangCommands.handleForgetCommand(player, argString) end,

    -- /hue                    -> show current color + usage
    -- /hue #RRGGBB | r,g,b    -> set (validated authoritatively in handleHueCommand)
    -- /hue reset              -> back to the per-username hash color
    handleHueCommand,

    -- /ll (E3 ergonomics, 2026-07-08): toggle back to whatever language you
    -- were speaking immediately before your current one. Self-serve, no
    -- arguments.
    function(player, argString) return MC_LangCommands.handleToggleLastCommand(player, argString) end,
}

-- Built from MC_Core.SERVER_SLASH_COMMANDS, not retyped: this table's key
-- SET is the single source MC_Input.isMCServerCommand also reads.
local SLASH_HANDLERS = {}
for i, cmd in ipairs(MC_Core.SERVER_SLASH_COMMANDS) do
    SLASH_HANDLERS[cmd] = SLASH_HANDLER_IMPLS[i]
end

-- Type-validates player/args and the raw message: nil checks, hard channel
-- validation, message-type/empty reject, MaxMessageLength trim+notify.
-- Establishes ctx.player/args/channel/message/lowerCmd; nil = already-rejected.
local function validateEnvelope(player, args)
    if not player or type(args) ~= "table" then
        MC_Incident.report("MESSAGE_INVALID",
            "stage=envelope shape=invalid")
        dbg("processMessage: nil player or invalid args")
        return nil
    end

    -- Type-validate client-provided fields. A malicious or broken client could
    -- send non-strings, tables, etc. Reject anything that doesn't look sane.
    local channel = args.channel
    if not isStrictString(channel, 32) then
        MC_Incident.report("CHANNEL_INVALID",
            "chat envelope carried no usable channel")
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your message was not sent because its chat channel was invalid.",
            color = {255, 100, 100},
        })
        return nil
    end

    local message = args.message
    if type(message) ~= "string" then
        MC_Incident.report("MESSAGE_INVALID",
            "non-string chat payload type=" .. tostring(type(message)))
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your message was not sent because its message data was invalid.",
            color = {255, 100, 100},
        })
        return nil
    end

    if message == "" then
        dbg("processMessage: empty message, ignoring")
        return nil
    end

    -- Cap message length (C47). Trim, then tell the sender -- a silent trim
    -- reads as the tail of the message never arriving. Sandbox-configurable
    -- (MongooseChat.MaxMessageLength, default 500, admins may raise to 2000).
    -- Read fresh from config, not a module-load snapshot: the admin value only
    -- lands after OnServerStarted's sandbox reload. The client raises its input
    -- box to match, so this cap normally only bites a tampered client.
    local maxLen = configuredMessageLimit()
    if not maxLen then
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your message was not sent because the server's message limit could not be verified.",
            color = {255, 100, 100},
        })
        return nil
    end
    if #message > maxLen then
        dbg("processMessage: message truncated from %d to %d chars", #message, maxLen)
        message = message:sub(1, maxLen)
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Message trimmed to " .. maxLen .. " characters.",
            color = {255, 220, 100}
        })
    end

    -- lowerCmd feeds dispatchSlashCommand's SLASH_HANDLERS lookup below.
    local lowerCmd = message:lower()

    return {
        player = player,
        args = args,
        channel = channel,
        message = message,
        lowerCmd = lowerCmd,
    }
end

-- Slash-command dispatch (see SLASH_HANDLERS above). Extracts the command
-- word -- everything up to the first space, or the whole message if
-- there's none -- from ctx.lowerCmd and looks it up. A bare command
-- ("/hue") and a command plus a space ("/hue reset") both match; anything
-- else glued onto the command word ("/huex") does not, and falls through
-- to normal chat handling untouched. Returns true when a handler ran
-- (processMessage returns right after, exactly as the old inline dispatch did).
local function dispatchSlashCommand(ctx)
    local spaceIdx = ctx.lowerCmd:find(" ", 1, true)
    local cmdWord = spaceIdx and ctx.lowerCmd:sub(1, spaceIdx - 1) or ctx.lowerCmd
    local handler = SLASH_HANDLERS[cmdWord]
    if handler then
        local argString = (ctx.lowerCmd == cmdWord) and "" or ctx.message:sub(#cmdWord + 2)
        handler(ctx.player, argString)
        return true
    end
    return false
end

-- Channel range lookup, admin-channel reject, faction/safehouse
-- reject, OOC-disabled, ALL-disabled, and the /event admin gate. Same
-- rejects, same notifications, same returns as today; nil = rejected
-- (any notification already sent).
local function gateChannel(ctx)
    local player = ctx.player
    local channel = ctx.channel

    dbg("processMessage: %s [%s]: %s",
        MC_Core.safe(function() return player:getUsername() end, "?"),
        channel,
        tostring(ctx.message))

    -- Distinguish an untrusted/unknown client channel from a known channel
    -- whose server-side range cannot be verified.
    if type(MC_Config.Ranges) == "table"
        and MC_Config.Ranges[channel] == nil then
        MC_Incident.report("CHANNEL_INVALID",
            "context=chat-gate channel=" .. boundedContext(channel))
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your message was not sent because its chat channel was unknown.",
            color = {255, 100, 100},
        })
        return nil
    end
    local range = configuredRange(channel, "chat-gate")
    if range == nil then
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your message was not sent because that channel's range could not be verified.",
            color = {255, 100, 100},
        })
        return nil
    end

    -- Admin channel is vanilla's territory. As of 0.8.0 MC_Input doesn't
    -- intercept /admin, and we don't route admin through our pipeline -
    -- vanilla's admin broadcast handles access-level filtering correctly
    -- and renders to the Admin tab. If admin still arrives here (older
    -- client, out-of-band tool), reject it rather than broadcast to all.
    if channel == "admin" then
        dbg("processMessage: admin channel rejected (vanilla owns admin routing)")
        return nil
    end

    -- Group channels aren't wired up yet. faction/safehouse carry range -1
    -- (global) but no membership filtering exists, so routing them would
    -- broadcast to the entire server. Reject with feedback until filtering
    -- lands (see MC_Config.Ranges).
    if channel == "faction" or channel == "safehouse" then
        dbg("processMessage: %s channel rejected (no membership filtering yet)", channel)
        local label = (channel == "faction") and "Faction" or "Safehouse"
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = label .. " chat isn't wired up yet -- your message wasn't sent.",
            color = {255, 100, 100}
        })
        return nil
    end

    -- Check if OOC is disabled
    if channel == "ooc" and not MC_Config.Channels.oocEnabled then
        dbg("processMessage: OOC disabled, rejecting message")
        -- Notify sender that OOC is disabled
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "OOC chat is disabled on this server.",
            color = {255, 100, 100}
        })
        return nil
    end

    -- Check if ALL is disabled
    if channel == "all" and not MC_Config.Channels.allEnabled then
        dbg("processMessage: ALL disabled, rejecting message")
        -- Notify sender that ALL is disabled
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Server-wide chat (/all) is disabled on this server.",
            color = {255, 100, 100}
        })
        return nil
    end

    -- /event is the storyteller's channel (v8.16.2): long-range narration
    -- for admin-run roleplay events (double yell range, see MC_Config).
    -- Admin-gated HERE, server-side -- the client's own check only shapes
    -- UX (same pattern as GrantLanguage below; the truth lives on the
    -- server, whatever the client sent).
    if channel == "event" then
        local accessOk, accessLevel =
            pcall(function() return player:getAccessLevel() end)
        if not accessOk or not isStrictString(accessLevel, 32) then
            MC_Incident.report("ADMIN_ACCESS_UNAVAILABLE",
                "context=event stage=access-read")
            dbg("processMessage: /event rejected (access unreadable)")
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = "Your event message was not sent because admin access could not be verified.",
                color = {255, 100, 100},
            })
            return nil
        end
        if accessLevel:lower() ~= "admin" then
            dbg("processMessage: /event rejected (access=%s)", tostring(accessLevel))
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = "The event voice belongs to the server's storytellers -- /event is for admins.",
                color = {255, 100, 100}
            })
            return nil
        end
    end

    ctx.channel = channel
    ctx.range = range
    return ctx
end

-- /tell target resolution: resolves the first word as a player name, strips
-- it, and rewrites the channel to say (only when ctx.channel == "tell").
-- Sets ctx.tellTargetUsername/tellTargetForename so routeProximity can
-- prefix "(to X)" / "(to you)". No-op passthrough for every other channel;
-- nil (after sending the usage/err notice) on failure.
local function resolveTell(ctx)
    if ctx.channel ~= "tell" then
        return ctx
    end

    local player = ctx.player
    local nameQuery, rest = ctx.message:match("^(%S+)%s+(.+)$")
    if not nameQuery or not rest or rest == "" then
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Usage: /tell <name> <message>  (or /t <name> <message>)",
            color = {255, 100, 100},
        })
        return nil
    end
    local targetPlayer, resolvedForename, sayRange =
        resolveTellTarget(player, nameQuery)
    if not targetPlayer then
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = resolvedForename,
            color = {255, 100, 100},
        })
        return nil
    end
    local targetUsername = readPlayerUsername(
        targetPlayer, "TELL_TARGET_ID_UNAVAILABLE", "tell-target")
    if not targetUsername then
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "That player's identity could not be verified; your message was not sent.",
            color = {255, 100, 100},
        })
        return nil
    end
    ctx.tellTargetUsername = targetUsername
    ctx.tellTargetForename = resolvedForename
    ctx.channel = "say"
    ctx.range = sayRange
    ctx.message = rest
    dbg("processMessage: /tell resolved '%s' -> %s (%s)",
        nameQuery, ctx.tellTargetForename, tostring(ctx.tellTargetUsername))
    return ctx
end

-- ONE-SHOT LANGUAGE PREFIX ("@<prefix> ...", E2 ergonomics, 2026-07-08)
--
-- A speech message beginning "@<prefix> " speaks THAT ONE utterance in the
-- resolved language without touching the speaker's persisted /lang choice.
-- Resolution reuses E1's matcher (MC_LangRegistry.matchLanguage) against the
-- languages the speaker is currently allowed to select at all -- the exact
-- gate MC_LangCommands.handleSetCommand enforces via MC_Lang.isSelectableLanguage
-- (known language, ASL's live toggle respected).
--
-- Hard boundary: anything shaped like a one-shot prefix must resolve uniquely
-- or the utterance is rejected self-only. Treating a mistyped
-- "@frenhc secret" as ordinary English reveals exactly the text the player
-- meant to put behind the language barrier. A doubled marker escapes the
-- syntax: "@@literal text" is spoken as the literal "@literal text".
--
-- Scoped to MC_Lang.isSpeechChannel (say/whisper/yell/low) -- the same
-- "physical fact of the channel" scoping checkSignedHands already uses,
-- independent of the LanguagesEnabled master switch (shouldTransformChannel
-- would swallow ASL's hands gate along with it; isSpeechChannel does not).
-- Runs AFTER resolveTell so a /tell's target name is already stripped from
-- ctx.message, and BEFORE checkSignedHands so a one-shot "@asl" faces the
-- same hands-full gate a persisted ASL speaker does.

local ONE_SHOT_LANG_PATTERN = "^@(%S+)%s+(.+)$"

local function resolveOneShotLanguage(ctx)
    if not MC_Lang.isSpeechChannel(ctx.channel) then return ctx end

    if ctx.message:sub(1, 2) == "@@" then
        ctx.message = ctx.message:sub(2)
        return ctx
    end

    local token, rest = ctx.message:match(ONE_SHOT_LANG_PATTERN)
    if not token or not rest or rest == "" then return ctx end

    local pool = {}
    for _, lang in ipairs(MC_LangRegistry.listLanguages()) do
        if MC_Lang.isSelectableLanguage(lang) then pool[#pool + 1] = lang end
    end

    local kind, resolved = MC_LangRegistry.matchLanguage(token, pool)
    if kind ~= "exact" and kind ~= "prefix" then
        MC_Incident.report("LANG_OVERRIDE_INVALID",
            "resolution=" .. tostring(kind or "none") .. " token=" .. tostring(token))
        sendServerCommand(ctx.player, "MongooseChat", "SystemMessage", {
            message = "That language prefix is unknown or ambiguous. "
                .. "Your message was not sent. Use @@ to begin literal speech with @.",
            color = {255, 140, 100},
        })
        return nil
    end

    ctx.oneShotLang = resolved
    ctx.message = rest
    dbg("processMessage: one-shot language '@%s' -> %s (for this message only)", token, resolved)
    return ctx
end

-- The bracketed mixed-language experiment is intentionally unavailable in
-- the stable boundary. Its inner language could evade outer-language hands,
-- sight, radio, relay, and competency checks; malformed attempts also used to
-- pass literally. Reject the shape before logging, sound, or routing so a
-- player can never mistake an unprotected line for protected speech.
local function rejectCodeSwitch(ctx)
    if not MC_Lang.hasCodeSwitchSyntax(ctx.message) then return ctx end
    local speakerUsername = MC_Core.safe(
        function() return ctx.player:getUsername() end, "unavailable"
    )
    MC_Incident.report("LANG_CODESWITCH_DISABLED",
        "speaker=" .. tostring(speakerUsername) .. " utterance blocked")
    sendServerCommand(ctx.player, "MongooseChat", "SystemMessage", {
        message = "Mixed-language [language: phrase] speech is unavailable. "
            .. "Your message was not sent; use @language for one whole utterance.",
        color = {255, 140, 100},
    })
    return nil
end

-- buildMessageData call, roll-flag passthrough, disk logging (skipping
-- 'mood' -- private monologue never hits the log), and the /event identity
-- scrub applied to the outbound copy (the disk log above keeps the real
-- admin identity). Sets ctx.msgData.
local function buildAndLog(ctx)
    local channel = ctx.channel
    local eventColor
    if channel == "event" then
        local configured = type(MC_Config.ChannelColors) == "table"
            and MC_Config.ChannelColors.event or nil
        if type(configured) ~= "table"
            or not isFiniteNumber(configured[1])
            or not isFiniteNumber(configured[2])
            or not isFiniteNumber(configured[3])
            or configured[1] < 0 or configured[1] > 255
            or configured[2] < 0 or configured[2] > 255
            or configured[3] < 0 or configured[3] > 255 then
            MC_Incident.report("SERVER_CONFIG_UNAVAILABLE",
                "context=event field=channel-color")
            sendServerCommand(ctx.player, "MongooseChat", "SystemMessage", {
                message = "Your event message was not sent because its display configuration could not be verified.",
                color = {255, 100, 100},
            })
            return nil
        end
        eventColor = { configured[1], configured[2], configured[3] }
    end

    -- Build message data
    local buildOk, msgData, failure =
        pcall(buildMessageData, ctx.player, channel, ctx.message)
    if not buildOk then
        MC_Incident.report("MESSAGE_BUILD_FAILED",
            "stage=message-build exception")
        msgData = nil
        failure = "internal"
    end
    if not msgData then
        sendServerCommand(ctx.player, "MongooseChat", "SystemMessage", {
            message = messageBuildFailureText(failure),
            color = {255, 100, 100},
        })
        return nil
    end

    -- Pass through roll flags if present
    if ctx.args.isRoll then
        msgData.isRoll = true
        msgData.rollTotal = ctx.args.rollTotal
        msgData.isCrit = ctx.args.isCrit or false
        msgData.isFumble = ctx.args.isFumble or false
    end

    -- Log for MongooseBot -- but not private channels.
    -- 'mood' (/you) is internal monologue, self-only, never transmitted to
    -- other players. Logging it to disk is a privacy leak. Skip.
    if channel ~= "mood" then
        local logged, reason = logMessage(msgData)
        if logged then
            dbg("processMessage: audit log write completed")
        elseif reason == "disabled" then
            dbg("processMessage: audit logging disabled by configuration")
        else
            dbg("processMessage: audit log write did not complete")
        end
    else
        dbg("processMessage: skipped logging private mood message")
    end

    -- Preserve the authenticated account name for server-only routing and
    -- language decisions before an event packet is deliberately anonymized.
    ctx.speakerUsername = msgData.username

    -- /event identity scrub (v8.16.2). The log above keeps the real admin
    -- identity for the audit trail; the copy players receive carries none
    -- of it. Event narration is the world speaking, not a character --
    -- and the narrator may be standing masked among the players they're
    -- narrating to, so no name, colour, or position may ride along
    -- (anonymity is a headline mechanic; see MC_Anonymity).
    if channel == "event" then
        msgData.characterName = ""
        msgData.username = ""
        msgData.steamId = nil
        msgData.steamStatus = "redacted"
        msgData.playerColor = eventColor
        msgData.coords = nil
        dbg("processMessage: /event identity scrubbed from outbound copy")
    end

    ctx.msgData = msgData
    return ctx
end

-- Emit only after routeProximity verifies the roster and speaking modality.
local function emitZombieSound(ctx)
    local channel = ctx.channel
    local attractionConfig
    if type(MC_Config.ZombieAttraction) == "table" then
        attractionConfig = MC_Config.ZombieAttraction.enabled
    end
    if type(attractionConfig) ~= "boolean" then
        MC_Incident.report("SERVER_CONFIG_UNAVAILABLE",
            "context=zombie-sound field=enabled")
        return ctx
    end
    if not attractionConfig then return ctx end

    local multiplier = {
        whisper = 0.66,
        low = 0.5,
        say = 0.66,
        yell = 1,
        event = 0, -- Storytelling, not in-world sound: draws nothing.
    }
    local factor = multiplier[channel]
    if factor == nil then return ctx end

    local range = ctx.range
    if not isFiniteNumber(range) or range < 0 then
        MC_Incident.report("CHANNEL_RANGE_UNAVAILABLE",
            "context=zombie-sound channel=" .. boundedContext(channel)
                .. " stage=context")
        return ctx
    end
    local soundRadius = math.floor(range * factor)
    if soundRadius > 0 then
        local coords = ctx.msgData and ctx.msgData.coords
        if type(coords) ~= "table"
            or not isFiniteNumber(coords.x)
            or not isFiniteNumber(coords.y)
            or not isFiniteNumber(coords.z) then
            MC_Incident.report("ZOMBIE_SOUND_FAILED",
                "context=proximity stage=position")
            return ctx
        end
        local ok, result = pcall(
            addSound, nil, coords.x, coords.y, coords.z,
            soundRadius, soundRadius)
        if not ok or result == false then
            MC_Incident.report("ZOMBIE_SOUND_FAILED",
                "context=proximity stage=emit")
        end
        dbg("processMessage: zombie attraction radius=%d for channel=%s",
            soundRadius, channel)
    end
    return ctx
end

-- False means routing ends here; true allows the radio route.
local function routeProximity(ctx)
    local player = ctx.player
    local channel = ctx.channel
    local range = ctx.range
    local msgData = ctx.msgData
    local tellTargetUsername = ctx.tellTargetUsername
    local tellTargetForename = ctx.tellTargetForename

    local players, onlinePlayers = snapshotOnlinePlayers(
        "ROSTER_UNAVAILABLE", "proximity")
    if not players then
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your message could not be routed because the online roster was unavailable.",
            color = {255, 100, 100},
        })
        return false
    end
    ctx.onlinePlayers = onlinePlayers

    if not isFiniteNumber(range)
        or (range ~= -1 and range < 0) or range > 10000 then
        MC_Incident.report("CHANNEL_RANGE_UNAVAILABLE",
            "context=proximity channel=" .. boundedContext(channel)
                .. " stage=context")
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your message could not be routed because its range was unavailable.",
            color = {255, 100, 100},
        })
        return false
    end

    local speakerUsername = ctx.speakerUsername
    if not isStrictString(speakerUsername, 64) then
        MC_Incident.report("SPEAKER_ID_UNAVAILABLE",
            "context=proximity stage=context-username")
        return false
    end
    local playerId = readOnlineId(
        player, "SPEAKER_ID_UNAVAILABLE", "proximity-speaker")
    if playerId == nil then return false end

    local candidates = {}
    local idCounts = {}
    for _, targetPlayer in ipairs(players) do
        local targetId = readOnlineId(targetPlayer,
            "PROXIMITY_RECEIVER_ID_UNAVAILABLE", "proximity-receiver")
        local targetUsername = readPlayerUsername(targetPlayer,
            "PROXIMITY_RECEIVER_ID_UNAVAILABLE", "proximity-receiver")
        if targetId == nil or targetUsername == nil then
            if targetPlayer == player then
                MC_Incident.report("SPEAKER_ID_UNAVAILABLE",
                    "context=proximity stage=roster-identity")
                return false
            end
        else
            idCounts[targetId] = (idCounts[targetId] or 0) + 1
            candidates[#candidates + 1] = {
                player = targetPlayer,
                id = targetId,
                username = targetUsername,
            }
        end
    end

    local duplicateReported = false
    local entries = {}
    local speakerCount = 0
    for _, entry in ipairs(candidates) do
        if idCounts[entry.id] ~= 1 then
            if not duplicateReported then
                duplicateReported = true
                MC_Incident.report("PROXIMITY_RECEIVER_ID_UNAVAILABLE",
                    "context=proximity stage=duplicate-online-id")
            end
        else
            entries[#entries + 1] = entry
            if entry.id == playerId
                and entry.username == speakerUsername then
                speakerCount = speakerCount + 1
            elseif entry.player == player or entry.id == playerId then
                MC_Incident.report("SPEAKER_ID_UNAVAILABLE",
                    "context=proximity stage=roster-identity")
                return false
            end
        end
    end
    if speakerCount ~= 1 then
        MC_Incident.report("SPEAKER_ID_UNAVAILABLE",
            "context=proximity stage=roster-membership")
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your message could not be routed because your roster identity was unavailable.",
            color = {255, 100, 100},
        })
        return false
    end

    dbg("processMessage: routing to %d online players, range=%s",
        #entries, tostring(range))

    local isGlobal = (range == -1)
    local sentCount = 0

    local function sendProximity(targetPlayer, payload)
        local ok, result = pcall(sendServerCommand, targetPlayer,
            "MongooseChat", "ChatMessage", payload)
        if not ok or result == false then
            MC_Incident.report("SERVER_BROADCAST_FAILED",
                "command=ChatMessage stage=proximity")
            return false
        end
        return true
    end

    -- Language transform: applies to IC speech channels only.
    -- Per-receiver render: each receiver gets babble or clean+tag based on
    -- whether they share the speaker's language. Shallow-copy msgData per
    -- receiver so the base msgData (for logging) stays clean.
    local doBabble = MC_Lang.shouldTransformChannel(channel)
    ctx.doBabble = doBabble

    -- Narration (/me, /do) is not a speech channel, but a quoted run inside
    -- one is speech and crosses the barrier like any other utterance. Only
    -- narration that actually carries quotes takes this path.
    local doNarrationSpeech = MC_Lang.shouldTransformNarration(channel, ctx.message)
    ctx.doNarrationSpeech = doNarrationSpeech

    local addressedDistance
    if channel ~= "mood" and not isGlobal and not tellTargetUsername then
        addressedDistance = configuredAddressedDistance("proximity")
        if addressedDistance == nil then
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = "Your message could not be routed because conversational distance was unavailable.",
                color = {255, 100, 100},
            })
            return false
        end
    end

    -- Modality is a speaker property and stays active when transforms are off.
    local speakerModality = MC_Lang.isSignedLanguage(
        ctx.effectiveLanguage or ctx.oneShotLang or MC_Lang.getLanguage(speakerUsername))
        and "signed" or nil
    msgData.modality = speakerModality

    if not speakerModality then emitZombieSound(ctx) end

    if channel == "mood" then
        sendProximity(player, msgData)
        return false
    end

    -- v8.16.1 "Voices": `addressed` is the proximity addressedness heuristic
    -- (within conversational distance / same vehicle = addressed; edge of
    -- earshot = overheard, reduced acquisition weight). nil = parity.
    local function sendChatToReceiver(targetPlayer, targetUsername, addressed)
        if doNarrationSpeech then
            -- Only the quoted runs are transformed.
            local rendered, langTag = msgData.message, nil
            if targetUsername == speakerUsername then
                -- The speaker reads back what they actually managed to say
                -- inside their own quotes -- the same production echo a /say
                -- gives them, so a learner can feel their fluency growing
                -- here too. Guarded: the echo's evalUtterance has no net of
                -- its own, and a failure must never fall back to clean text.
                local okEcho, echo = pcall(MC_Lang.narrationSpeakerEcho,
                    ctx.message, speakerUsername, msgData.timestamp, ctx.oneShotLang)
                if okEcho then
                    if echo then rendered = echo end
                else
                    rendered = "..."
                    MC_Incident.report("LANG_SPEAKER_ECHO_FAILED",
                        "context=narration stage=speaker-echo output=redacted")
                end
                langTag = ctx.oneShotLang or MC_Lang.getLanguage(speakerUsername)
                if langTag == "english" then langTag = nil end
            else
                local okRender
                okRender, rendered, langTag = pcall(
                    MC_Lang.renderNarrationForReceiver,
                    speakerUsername, targetUsername, ctx.message, msgData.timestamp,
                    { addressed = addressed, overrideLang = ctx.oneShotLang })
                if not okRender or type(rendered) ~= "string" then
                    MC_Incident.report("LANG_RENDER_FAILED",
                        "context=narration stage=receiver-render output=redacted")
                    rendered, langTag = "...",
                        (ctx.oneShotLang or MC_Lang.getLanguage(speakerUsername))
                end
            end

            local perReceiver = {}
            for k, v in pairs(msgData) do perReceiver[k] = v end
            perReceiver.message = rendered
            -- Same identification gate as speech: the [Turkish] label only
            -- appears once this listener knows what they are hearing, and
            -- speakers always know their own language.
            if langTag and langTag ~= "english" then
                if targetUsername == speakerUsername
                   or MC_Lang.isNative(targetUsername, langTag)
                   or hasIdentifiedLanguage(targetUsername, langTag) then
                    perReceiver.language = langTag
                end
            end
            return sendProximity(targetPlayer, perReceiver)
        elseif not doBabble then
            return sendProximity(targetPlayer, msgData)
        else
            local rendered, langTag, chunks
            if targetUsername == speakerUsername then
                -- Speaker: their own language tag (they understand themselves),
                -- plus the production-pass echo of what they actually managed
                -- to say -- a learner hears their own broken speech, so
                -- fluency growth is felt. An evaluation failure is rendered
                -- opaque and reported; it never reveals the clean typed text.
                -- No chunks: the speaker's comprehension stays clean, no L2
                -- styling needed.
                rendered = ctx.message
                -- Guarded here (unlike renderForReceiver below, which
                -- already pcall's its own risky inner call and fails
                -- closed internally): speakerEcho's evalUtterance has no
                -- such guard of its own, so this is the only net under it.
                -- E2: ctx.oneShotLang (nil outside a one-shot message) rides
                -- along as speakerEcho's overrideLang.
                local okEcho, echo = pcall(MC_Lang.speakerEcho, ctx.message,
                    speakerUsername, msgData.timestamp, ctx.oneShotLang)
                if okEcho then
                    if echo then rendered = echo end
                else
                    rendered = "..."
                    MC_Incident.report("LANG_SPEAKER_ECHO_FAILED",
                        "context=proximity stage=speaker-echo output=redacted")
                end
                langTag = ctx.oneShotLang or MC_Lang.getLanguage(speakerUsername)
                if langTag == "english" then langTag = nil end
                chunks = nil
            else
                local okRender
                okRender, rendered, langTag, chunks = pcall(
                    MC_Lang.renderForReceiver,
                    speakerUsername, targetUsername, ctx.message, msgData.timestamp,
                    { addressed = addressed, overrideLang = ctx.oneShotLang })
                if not okRender or type(rendered) ~= "string" then
                    MC_Incident.report("LANG_RENDER_FAILED",
                        "context=proximity stage=receiver-render output=redacted")
                    rendered, langTag, chunks = "...",
                        (ctx.oneShotLang or MC_Lang.getLanguage(speakerUsername)), nil
                end
            end
            local perReceiver = {}
            for k, v in pairs(msgData) do perReceiver[k] = v end
            perReceiver.message = rendered
            -- modality is already on msgData (stamped above) and carried
            -- through by the copy loop; no separate assignment needed here.
            -- Language identification: the [Turkish] tag only appears once
            -- the listener knows what language they're hearing. Speakers
            -- always know their own language; natives identify by definition;
            -- other listeners must have acquired at least one word first.
            -- Until then, they just see babble with no label.
            if langTag then
                if targetUsername == speakerUsername then
                    perReceiver.language = langTag
                elseif MC_Lang.isNative(targetUsername, langTag)
                       or hasIdentifiedLanguage(targetUsername, langTag) then
                    perReceiver.language = langTag
                end
            end
            -- Additive signal for the client's one-time first-babble hint.
            -- True exactly when this utterance carried a real language (langTag
            -- set -- the speaker wasn't speaking English) AND this specific
            -- listener didn't get the tag above (not native, hasn't
            -- identified it yet) -- i.e. genuinely unlabeled babble for THIS
            -- receiver. Never true for the speaker's own echo (that branch
            -- always sets perReceiver.language whenever langTag is set) or
            -- for English speech (langTag nil). Nothing else reads this
            -- field; existing wire behavior is unchanged.
            if langTag and not perReceiver.language then
                perReceiver.babbled = true
            end
            if chunks then perReceiver.chunks = chunks end
            -- /tell display prefix: speaker sees "(to Marta)", target sees
            -- "(to you)", others see the message plain. Applied after
            -- language rendering so the prefix is always in English.
            if tellTargetForename then
                if targetUsername == speakerUsername then
                    perReceiver.message = "(to " .. tellTargetForename .. ") "
                        .. perReceiver.message
                elseif targetUsername == tellTargetUsername then
                    perReceiver.message = "(to you) " .. perReceiver.message
                end
            end
            return sendProximity(targetPlayer, perReceiver)
        end
    end

    for _, entry in ipairs(entries) do
        local targetPlayer = entry.player
        local targetId = entry.id
        local targetUsername = entry.username

        -- Always send to self
        if targetId == playerId then
            if sendChatToReceiver(targetPlayer, targetUsername) then
                sentCount = sentCount + 1
                dbg("processMessage: sent to SELF")
            end
        elseif isGlobal then
            if sendChatToReceiver(targetPlayer, targetUsername) then
                sentCount = sentCount + 1
            end
        else
            local distance = getDistance(player, targetPlayer)
            if distance ~= nil then
                local sameVehicle = false
                local vehicleAuthoritative = true
                -- An explicit /tell supplies addressedness itself. For other
                -- local speech, vehicle state also decides whether a listener
                -- is addressed even when ordinary distance is already enough.
                local needsVehicleForRange = (distance > range)
                local needsVehicleForAddressedness =
                    doBabble and not tellTargetUsername
                        and distance > addressedDistance
                if needsVehicleForRange
                    or needsVehicleForAddressedness then
                    sameVehicle, vehicleAuthoritative =
                        inSameVehicle(player, targetPlayer)
                end
                local inRange = vehicleAuthoritative
                    and (distance <= range or sameVehicle)

                if inRange then
                -- Addressedness: /tell gives explicit addressed to the target
                -- and overheard to everyone else. Without /tell, the distance
                -- heuristic applies (conversational distance = addressed).
                    local addressed
                    if tellTargetUsername then
                        addressed = (targetUsername == tellTargetUsername)
                    else
                        addressed = sameVehicle
                            or (distance <= addressedDistance)
                    end
                    if sendChatToReceiver(
                        targetPlayer, targetUsername, addressed) then
                        sentCount = sentCount + 1
                        dbg("processMessage: sent to %s (dist=%.1f, addressed=%s)",
                            targetUsername, distance, tostring(addressed))
                    end
                end
            end
        end
    end
    dbg("processMessage: proximity complete, sent to %d players", sentCount)

    return true
end

local VALID_RADIO_SOURCES = { player = true, ground = true, vehicle = true }
local MAX_CLIENT_EMITTER_CLAIMS = 32

local function isFiniteRadioNumber(value)
    return type(value) == "number"
       and value == value
       and value > -math.huge
       and value < math.huge
end

local function isExactDenseArray(value, maxCount)
    if type(value) ~= "table" then return false, 0 end

    local count = 0
    local highest = 0
    for index, _ in pairs(value) do
        if not isFiniteRadioNumber(index)
           or index < 1
           or index % 1 ~= 0 then
            return false, count
        end
        count = count + 1
        if index > highest then highest = index end
        if maxCount and count > maxCount then return false, count end
    end

    if count ~= highest then return false, count end
    return true, count
end

local function isValidRadioPosition(position)
    return type(position) == "table"
       and isFiniteRadioNumber(position.x)
       and isFiniteRadioNumber(position.y)
       and isFiniteRadioNumber(position.z)
end

local function isValidServerEmitter(emitter)
    return type(emitter) == "table"
       and MC_Radio.canEmit(emitter)
       and isFiniteRadioNumber(emitter.frequency)
       and emitter.frequency > 0
       and emitter.frequency % 1 == 0
       and VALID_RADIO_SOURCES[emitter.source] == true
       and isValidRadioPosition(emitter.position)
       and isFiniteRadioNumber(emitter.transmitRange)
       and emitter.transmitRange >= 0
end

local function validateReceiverMap(receivers, emitters)
    if type(receivers) ~= "table" then return false end

    for freq, receiverList in pairs(receivers) do
        if not isFiniteRadioNumber(freq)
           or freq <= 0
           or freq % 1 ~= 0
           or type(emitters[freq]) ~= "table" then
            return false
        end

        local dense, count = isExactDenseArray(receiverList, 1)
        if not dense or count ~= 1 then return false end

        local receiverInfo = receiverList[1]
        local radio = type(receiverInfo) == "table" and receiverInfo.radio or nil
        if type(radio) ~= "table"
           or radio.frequency ~= freq
           or VALID_RADIO_SOURCES[radio.source] ~= true
           or not isValidRadioPosition(radio.position)
           or not isFiniteRadioNumber(radio.volume)
           or radio.volume <= 0
           or type(radio.isPrivate) ~= "boolean"
           or not isFiniteRadioNumber(receiverInfo.distance)
           or receiverInfo.distance < 0
           or not isFiniteRadioNumber(receiverInfo.playerDistance)
           or receiverInfo.playerDistance < 0
           or not isFiniteRadioNumber(receiverInfo.hearingRange)
           or receiverInfo.hearingRange < 0 then
            return false
        end
    end

    return true
end

-- Validate the client's complete, authoritative snapshot of emitters that
-- were live at message-submit time. The snapshot is an upper bound only: it
-- may veto a server-discovered transmitter, but it can never create one or
-- replace any server-owned frequency, range, source, or position metadata.
--
-- This split is necessary on B42.20 dedicated servers. Vanilla sends the
-- Device Options volume/microphone state for a belt or bag radio by inventory
-- item id, but the dedicated-server receiver ignores that non-hand subtype.
-- Missing or malformed proof therefore fails radio closed while leaving the
-- already-routed proximity message alone.
local function validateClientEmitterSnapshot(args)
    if args.radioFrequency ~= nil then
        MC_Incident.report("RADIO_CLIENT_METADATA_REJECTED",
            "legacy radioFrequency ignored")
    end

    local claims = args.radioEmitters
    if type(claims) ~= "table" then
        MC_Incident.report("RADIO_CLIENT_METADATA_REJECTED",
            claims == nil and "radioEmitters snapshot missing"
                or "radioEmitters was not a table")
        return nil, false
    end

    local dense, count = isExactDenseArray(
        claims, MAX_CLIENT_EMITTER_CLAIMS)
    if not dense then
        MC_Incident.report("RADIO_CLIENT_METADATA_REJECTED",
            count > MAX_CLIENT_EMITTER_CLAIMS
                and "too many radioEmitters"
                or "radioEmitters was not a dense array")
        return nil, false
    end

    for _, emitter in ipairs(claims) do
        local valid = type(emitter) == "table"
            and isFiniteRadioNumber(emitter.frequency)
            and emitter.frequency > 0
            and emitter.frequency % 1 == 0
            and VALID_RADIO_SOURCES[emitter.source] == true
            and type(emitter.position) == "table"
            and isFiniteRadioNumber(emitter.position.x)
            and isFiniteRadioNumber(emitter.position.y)
            and isFiniteRadioNumber(emitter.position.z)
            and isFiniteRadioNumber(emitter.transmitRange)
            and emitter.transmitRange >= 0

        if not valid then
            MC_Incident.report("RADIO_CLIENT_METADATA_REJECTED",
                "malformed radioEmitter entry")
            return nil, false
        end
    end

    return claims, true
end

local function sameCanonicalRadioTile(a, b)
    return math.floor(a.x) == math.floor(b.x)
       and math.floor(a.y) == math.floor(b.y)
       and math.floor(a.z) == math.floor(b.z)
end

-- Consume at most one client approval for each server emitter. Matching never
-- copies client fields into the route. Player and vehicle coordinates may move
-- between the client snapshot and server handling, so their canonical server
-- identity here is source + tuned frequency + immutable transmit range.
-- Ground devices additionally need the same tile. Identical devices with the
-- same routing properties are deliberately a multiset: one live client radio
-- approves one (and only one) equivalent server transmitter.
local function consumeMatchingClientApproval(emitter, claims, consumed)
    for index, claim in ipairs(claims) do
        local matches = consumed[index] ~= true
            and claim.source == emitter.source
            and claim.frequency == emitter.frequency
            and claim.transmitRange == emitter.transmitRange

        if matches and emitter.source == MC_Radio.SOURCE_GROUND then
            matches = sameCanonicalRadioTile(claim.position, emitter.position)
        end

        if matches then
            consumed[index] = true
            return true
        end
    end
    return false
end

-- Only for say/yell/low/whisper; skipped (with a dbg note) for every other
-- channel. Emitter existence and routing metadata are server-authoritative;
-- the client snapshot can only subtract devices whose local mute state says
-- they were not live. Applies weather interference, logs and self-echoes,
-- then renders+degrades per receiver.
local function routeRadio(ctx)
    -- Feature switch: a server that hands radio to another mod gets no
    -- MongooseChat radio routing at all.
    if MC_Config.Features and MC_Config.Features.radio == false then return end
    local player = ctx.player
    local channel = ctx.channel
    local message = ctx.message
    local msgData = ctx.msgData
    local onlinePlayers = ctx.onlinePlayers
    local doBabble = ctx.doBabble
    local speakerUsername = msgData.username

    local radioChannels = {say = true, yell = true, low = true, whisper = true}
    if not radioChannels[channel] then
        dbg("processMessage: skipping radio (non-IC channel)")
        return
    end

    local clientClaims, clientSnapshotOK =
        validateClientEmitterSnapshot(ctx.args)
    if not clientSnapshotOK then
        dbg("processMessage: skipping radio (client snapshot unavailable)")
        return
    end

    -- Discover active emitters from the server's own player, inventory,
    -- vehicle, and world state. If that discovery fails or returns an unsafe
    -- shape, radio routing stops; client claims are never substituted.
    local emitters = {}
    local okDiscovery, discovered, discoveryAuthoritative = pcall(
        MC_Radio.findPlayerEmitters, player, ctx.range)
    if not okDiscovery or discoveryAuthoritative ~= true then
        MC_Incident.report("RADIO_SERVER_DISCOVERY_FAILED",
            "speaker emitter discovery unavailable")
        return
    end

    local denseDiscovery = isExactDenseArray(discovered, 256)
    if not denseDiscovery then
        MC_Incident.report("RADIO_SERVER_DISCOVERY_FAILED",
            "speaker emitter result shape invalid")
        return
    end

    local consumedClientClaims = {}
    for _, emitter in ipairs(discovered) do
        if not isValidServerEmitter(emitter) then
            MC_Incident.report("RADIO_SERVER_DISCOVERY_FAILED",
                "speaker emitter metadata invalid")
            return
        end

        if consumeMatchingClientApproval(
            emitter, clientClaims, consumedClientClaims)
        then
            local freq = emitter.frequency
            emitters[freq] = emitters[freq] or {}
            table.insert(emitters[freq], emitter)
        end
    end

    -- Count emitters
    local emitterCount = 0
    for _ in pairs(emitters) do
        emitterCount = emitterCount + 1
    end

    if emitterCount == 0 then
        dbg("processMessage: no radio emitters found")
        return
    end

    -- Signed modality doesn't transmit (spec ruling): a radio carries
    -- sound, not sight. Only checked once we know the player is actually
    -- broadcasting -- an ASL speaker with no radio on them should never
    -- see this line. E2: a one-shot "@asl" override is signed too.
    if MC_Lang.isSignedLanguage(
        ctx.effectiveLanguage or ctx.oneShotLang or MC_Lang.getLanguage(speakerUsername))
    then
        dbg("processMessage: skipping radio (signed modality doesn't transmit)")
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Signing doesn't carry over the radio.",
            color = {255, 100, 100},
        })
        return
    end

    dbg("processMessage: found emitters on %d frequencies", emitterCount)

    -- Radio crackle is a separate sandbox switch from radio routing. Turning
    -- it off keeps every radio path intact but skips weather reads and packet
    -- loss, so speech stays clear.
    local radioStaticEnabled = not (MC_Config.Features
        and MC_Config.Features.radioStatic == false)
    local weatherMultiplier = 1.0
    if radioStaticEnabled then
        weatherMultiplier = getWeatherInterference()
        if weatherMultiplier > 1.0 then
            dbg("Weather interference: %.1fx", weatherMultiplier)
        end
    end

    -- Language transform applies to IC speech channels (same channels as
    -- proximity above). Radio * babble order: babble first, then packet
    -- loss -- per the locked design. Since babble is per-receiver, packet
    -- loss now runs per-receiver too (was per-frequency in stable).
    -- Speaker's own tag (so self-echo and same-language listeners see it).
    -- E2: a one-shot override takes precedence, same as everywhere else.
    local speakerOwnLangTag = ctx.oneShotLang or MC_Lang.getLanguage(speakerUsername)
    if speakerOwnLangTag == "english" then speakerOwnLangTag = nil end

    -- Roll radio packet loss ONCE per transmission, not per receiver. Every
    -- clear-text listener, the speaker's own self-echo, and the Discord relay
    -- share this single corruption, so one transmission reads identically
    -- everywhere it is witnessed. (Babble listeners still degrade per-receiver
    -- below: their text is unique to them, so there is nothing for a shared
    -- roll to share.) This is the "one static per broadcast" model -- radio
    -- packet loss is a property of the transmission, not of each listener.
    local canonicalStatic = message
    if radioStaticEnabled then
        canonicalStatic = MC_Radio.addPacketLoss(message, weatherMultiplier)
    end

    -- Log radio transmissions with the ORIGINAL (pre-babble) message. Logs
    -- preserve intent; per-receiver renders are an ephemeral display layer.
    -- The Discord relay sidecar (logRadioRelay) is written AFTER routing --
    -- see the end of this function -- so its babble render's packet-loss roll
    -- can't perturb the per-receiver ZombRand sequence.
    for freq, _ in pairs(emitters) do
        logRadioMessage(msgData, freq, message)
        dbg("[RADIO_TX] [%.2fHz] %s (%s) [%s]: %s",
            freq / 1000,
            msgData.characterName,
            msgData.username,
            msgData.channel,
            message
        )
    end

    -- Self-echo (sender sees their transmission, clean + their own language tag).
    -- Shares the canonical roll so the speaker sees exactly what clear-text
    -- listeners and the Discord relay see.
    local function sendRadioMessage(targetPlayer, radioMsgData, stage)
        local ok, result = pcall(sendServerCommand, targetPlayer,
            "MongooseChat", "RadioMessage", radioMsgData)
        if not ok or result == false then
            MC_Incident.report("SERVER_BROADCAST_FAILED",
                "command=RadioMessage stage=" .. stage)
            return false
        end
        return true
    end

    for freq, _ in pairs(emitters) do
        local selfDegraded = canonicalStatic
        local radioMsgData = {
            senderUsername = msgData.username,
            senderCharacter = msgData.characterName,
            playerColor = msgData.playerColor,
            message = selfDegraded,
            language = speakerOwnLangTag,
            channel = channel,
            frequency = freq,
            receiverType = "self",
            receiverOwnerId = msgData.username,
            receiverPosition = nil,
            isPrivate = true,
            volume = 0
        }
        if sendRadioMessage(player, radioMsgData, "self-echo") then
            dbg("processMessage: sent self-echo on %d", freq)
        end
    end

    -- Route to receivers (skip sender - they already got self-echo)
    local radioSentCount = 0
    local radioSoundEmitted = {}

    for i = 0, onlinePlayers:size() - 1 do
        local targetPlayer = onlinePlayers:get(i)

        -- Skip sender - they already received self-echo above
        if targetPlayer == player then
            dbg("processMessage: skipping sender for radio routing (already got self-echo)")
        else
            local usernameOK, targetUsername = pcall(function()
                return targetPlayer:getUsername()
            end)
            if not usernameOK or type(targetUsername) ~= "string"
               or targetUsername == "" then
                MC_Incident.report("RADIO_RECEIVER_ID_UNAVAILABLE",
                    "receiver username unavailable")
            else
                local receiverOK, receivers, receiverAuthoritative = pcall(
                    MC_Radio.findReceivers, targetPlayer, emitters)
                if not receiverOK or receiverAuthoritative ~= true then
                    MC_Incident.report("RADIO_RECEIVER_DISCOVERY_FAILED",
                        "receiver discovery unavailable")
                    receivers = nil
                elseif not validateReceiverMap(receivers, emitters) then
                    MC_Incident.report("RADIO_RECEIVER_DISCOVERY_FAILED",
                        "receiver result shape invalid")
                    receivers = nil
                end

                for freq, receiverList in pairs(receivers or {}) do
                    for _, receiverInfo in ipairs(receiverList) do
                    local radio = receiverInfo.radio

                    -- Per-receiver render: babble or clean+tag, then packet loss.
                    -- v8.5.1: capture chunks from renderForReceiver and run the
                    -- chunk-aware degradation path when present, so the L2
                    -- gradient render lands on the radio too. The flat string
                    -- on the wire is derived from the degraded chunks so the
                    -- two stay positionally consistent.
                    -- v8.16.1: no opts -- radio carries no address signal, so
                    -- acquisition stays at parity weight (addressed = nil)
                    -- rather than penalizing legitimate radio conversation.
                    --
                    -- 2026-07-09 fix (foreign speech over radio must fail
                    -- TOWARD babble, never toward clear text): this used to
                    -- gate the render call on `targetUsername` being truthy
                    -- and send the RAW, un-rendered `message` whenever a
                    -- listener's username couldn't be resolved (a
                    -- getUsername() failure caught by MC_Core.safe) --
                    -- exactly the "can't resolve the listener's
                    -- comprehension" case, and it was failing OPEN (clear
                    -- text) instead of closed (babble). routeProximity next
                    -- door has no such special case -- it calls
                    -- renderForReceiver unconditionally and lets a nil
                    -- receiverUsername fall through MC_Lang.isNative(nil, ..)
                    -- = false, which the render pipeline already treats as
                    -- "non-native listener" (plain babble, no dictionary
                    -- bleed/acquisition bookkeeping, since those are
                    -- separately guarded on `receiverUsername` inside
                    -- renderWithLangs). Radio now does the same: doBabble
                    -- alone gates the render call, so an unresolved listener
                    -- gets the same fail-toward-indecipherable treatment as
                    -- every other non-comprehending listener, never the
                    -- speaker's plaintext.
                    local rendered, langTag, chunks
                    if doBabble then
                        rendered, langTag, chunks = MC_Lang.renderForReceiver(
                            speakerUsername, targetUsername, message, msgData.timestamp,
                            { overrideLang = ctx.oneShotLang })
                    else
                        rendered = message
                        langTag = nil
                        chunks = nil
                    end

                    local degraded, degradedChunks
                    if chunks and not radioStaticEnabled then
                        degradedChunks = chunks
                        degraded = rendered
                    elseif chunks then
                        -- Babble render: the listener's text is unique to them,
                        -- so packet loss is necessarily rolled per-receiver.
                        degradedChunks, degraded = MC_Radio.addPacketLossToChunks(
                            chunks, weatherMultiplier)
                    elseif rendered == message then
                        -- Clear-text listener hears the speaker's exact words:
                        -- reuse the ONE canonical roll so in-game and the
                        -- Discord relay show byte-identical static.
                        degraded = canonicalStatic
                        degradedChunks = nil
                    elseif radioStaticEnabled then
                        degraded = MC_Radio.addPacketLoss(rendered, weatherMultiplier)
                        degradedChunks = nil
                    else
                        degraded = rendered
                        degradedChunks = nil
                    end

                    -- Language identification gate (same logic as proximity):
                    -- only reveal the language name once the listener knows
                    -- what language they're hearing.
                    local radioLangTag = nil
                    if langTag and targetUsername then
                        if MC_Lang.isNative(targetUsername, langTag)
                           or hasIdentifiedLanguage(targetUsername, langTag) then
                            radioLangTag = langTag
                        end
                    end

                    local radioMsgData = {
                        senderUsername = msgData.username,
                        senderCharacter = msgData.characterName,
                        playerColor = msgData.playerColor,
                        message = degraded,
                        chunks = degradedChunks,
                        language = radioLangTag,
                        channel = channel,
                        frequency = freq,
                        receiverType = radio.source,
                        receiverOwnerId = radio.ownerId,
                        receiverPosition = radio.position,
                        isPrivate = radio.isPrivate,
                        volume = radio.volume
                    }

                    if sendRadioMessage(targetPlayer, radioMsgData, "receiver") then
                        radioSentCount = radioSentCount + 1
                        dbg("processMessage: sent radio to %s via %s on %d",
                            MC_Core.safe(function() return targetPlayer:getUsername() end, "?"),
                            radio.source, freq)

                        -- Zombie attraction from public radios
                        if not radio.isPrivate then
                            local soundX = radio.position.x
                            local soundY = radio.position.y
                            local soundZ = radio.position.z
                            local posKey = radio.source .. "_"
                                .. math.floor(soundX) .. "_"
                                .. math.floor(soundY) .. "_"
                                .. math.floor(soundZ)

                            if not radioSoundEmitted[posKey] then
                                radioSoundEmitted[posKey] = true

                                local vol = radio.volume
                                local hearingRange = receiverInfo.hearingRange
                                local soundRadius = math.floor(hearingRange * 0.7)

                                if soundRadius > 0
                                    and MC_Config.ZombieAttraction
                                    and MC_Config.ZombieAttraction.enabled == true then
                                    local ok, result = pcall(addSound, nil,
                                        soundX, soundY, soundZ, soundRadius, vol)
                                    if not ok or result == false then
                                        MC_Incident.report("ZOMBIE_SOUND_FAILED",
                                            "context=radio stage=emit")
                                    end
                                    dbg("processMessage: radio zombie sound at %s radius=%d", posKey, soundRadius)
                                end
                            end
                        end
                    end
                end
            end
            end
        end
    end

    -- Discord relay sidecar. Written AFTER per-receiver routing on purpose:
    -- the relay's babble render + packet loss draws ZombRand, and rolling it
    -- here (rather than before the receiver loop) keeps every in-game
    -- receiver's corruption byte-identical to what it would be without the
    -- relay -- the relay is a pure output side-effect, not a gameplay roll.
    --
    -- The relay is the LAST stage before Discord, and a Discord reader can
    -- never be assumed to speak the language -- so foreign speech must never
    -- arrive there as readable English. This relay boundary is enforced by
    -- observerBabble, which
    -- full-babbles the whole utterance in the speaker's palette -- a boundary
    -- guarantee independent of the speaker's fluency, so a learner's
    -- English-fallback words can't leak; only *emote*/((OOC)) markers survive.
    -- Gated on the speaker's own non-English tag alone (NOT the per-receiver
    -- doBabble flag): a non-English line is scrubbed of English before Discord
    -- even with the language barrier's master switch off. observerBabble
    -- returns nil for English -- the relay then keeps the shared canonical
    -- static, byte-identical to every clear-text witness; for a non-English
    -- language whose palette can't load it also returns nil and we redact to
    -- static rather than leak plaintext. The clean copy after the TAB stays
    -- the pre-babble message so 350-400MHz linking codes still verify exactly.
    local relayDegraded = canonicalStatic
    if speakerOwnLangTag then
        local ok, babbled = pcall(MC_Lang.observerBabble, message,
            speakerUsername, msgData.timestamp, ctx.oneShotLang)
        if ok and type(babbled) == "string" and babbled ~= ""
           and radioStaticEnabled then
            relayDegraded = MC_Radio.addPacketLoss(babbled, weatherMultiplier)
        elseif ok and type(babbled) == "string" and babbled ~= "" then
            relayDegraded = babbled
        else
            MC_Incident.report("RADIO_RELAY_BABBLE_FAILED",
                ok and "observer render unavailable" or "observer render raised")
            relayDegraded = (message:gsub("%S+", "*static*"))
        end
    end
    for freq, _ in pairs(emitters) do
        logRadioRelay(msgData, freq, relayDegraded, message)
    end

    dbg("processMessage: radio complete, sent %d radio messages", radioSentCount)
end

-- Palette availability is a routing prerequisite, independent of the language
-- renderer's master switch. A persisted non-English identity can outlive a
-- missing/failed palette load; sending it through LanguagesEnabled=false as
-- clean text would disclose the exact utterance, and a missing ASL palette
-- must never erase its signed physical modality. Resolve and pin the effective
-- language before hands, logging, or routing.
local function checkLanguageRuntime(ctx)
    if not MC_Lang.isSpeechChannel(ctx.channel) then return ctx end

    local usernameOk, username = pcall(function()
        return ctx.player:getUsername()
    end)
    if not usernameOk or type(username) ~= "string" or username == "" then
        MC_Incident.report("SPEAKER_ID_UNAVAILABLE",
            "language runtime gate could not resolve speaker")
        sendServerCommand(ctx.player, "MongooseChat", "SystemMessage", {
            message = "Your message was not sent because your account identity could not be verified.",
            color = {255, 100, 100},
        })
        return nil
    end

    local effectiveLanguage = ctx.oneShotLang or MC_Lang.getLanguage(username)
    if not MC_Lang.isLanguageRuntimeAvailable(effectiveLanguage) then
        MC_Incident.report("LANG_PALETTE_UNAVAILABLE",
            "language=" .. tostring(effectiveLanguage)
                .. " utterance blocked before routing")
        sendServerCommand(ctx.player, "MongooseChat", "SystemMessage", {
            message = "That language is temporarily unavailable. Your message was not sent.",
            color = {255, 100, 100},
        })
        return nil
    end

    ctx.effectiveLanguage = effectiveLanguage
    return ctx
end

-- Hands gate: ASL needs a free hand. Server-reliable accessors --
-- getPrimaryHandItem/getSecondaryHandItem, the same pair MC_Radio's own
-- hand scan already trusts server-side (shared/MC_Radio.lua ~523-524).
-- Belt/attached items are NOT consulted (documented flaky server-side
-- there too). Checked once, before the message is even built/logged, so a
-- blocked line never reaches anyone -- not even the speaker's own echo.
--
-- B3 fix: gated on isSpeechChannel (channel-set only), NOT
-- shouldTransformChannel -- that also folds in MongooseChat.LanguagesEnabled,
-- and whether you physically have a free hand to sign with has nothing to
-- do with whether the babble/translation engine is switched on. Under
-- LanguagesEnabled=false this gate used to no-op entirely, letting a
-- hands-full signer "speak" with both hands full.
local function checkSignedHands(ctx)
    if not MC_Lang.isSpeechChannel(ctx.channel) then return ctx end
    local player = ctx.player
    local usernameOk, username = pcall(function() return player:getUsername() end)
    if not usernameOk or type(username) ~= "string" or username == "" then
        MC_Incident.report("SPEAKER_ID_UNAVAILABLE",
            "signed-language gate could not resolve speaker")
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your message was not sent because your account identity could not be verified.",
            color = {255, 100, 100},
        })
        return nil
    end
    -- E2 one-shot override (ctx.oneShotLang), when present, stands in for
    -- the persisted language here too -- a one-shot "@asl ..." must face
    -- the SAME hands-full physical gate a persisted ASL speaker does.
    local effectiveLang = ctx.effectiveLanguage
        or ctx.oneShotLang or MC_Lang.getLanguage(username)
    if not MC_Lang.isSignedLanguage(effectiveLang) then return ctx end

    if MC_Lang.isDormantSigned(effectiveLang) then
        MC_Incident.report("SIGNED_LANGUAGE_DISABLED",
            "language=" .. tostring(effectiveLang) .. " utterance blocked")
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "That signed language is disabled here. Your message was not sent; "
                .. "choose another language with /lang.",
            color = {255, 100, 100},
        })
        return nil
    end

    local primaryOk, primary = pcall(function() return player:getPrimaryHandItem() end)
    local secondaryOk, secondary = pcall(function() return player:getSecondaryHandItem() end)
    if not primaryOk or not secondaryOk then
        MC_Incident.report("ASL_HAND_STATE_UNREADABLE",
            "primary=" .. tostring(primaryOk) .. " secondary=" .. tostring(secondaryOk))
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your message was not sent because your hands could not be verified.",
            color = {255, 100, 100},
        })
        return nil
    end

    -- M8: a two-handed weapon (shotgun, sledgehammer, ...) may occupy only
    -- the primary slot while functionally locking up both hands -- whether
    -- getSecondaryHandItem() also reflects that (returning the same item)
    -- or reads nil (primary alone, off-hand technically "empty" but
    -- unusable) is unconfirmed on a dedicated server, the same
    -- class of gap as the Deaf trait accessor (MC_Anonymity.
    -- localPlayerIsDeaf) -- until then this wraps defensively: if the
    -- primary item exposes isTwoHandWeapon(), a true reading is treated as
    -- "no free hand" even when secondary alone reads nil. An errored or
    -- absent method is a reliable "not a two-hand weapon"; an accessor error
    -- is unknown and blocks signing rather than widening what counts as free.
    local twoHandOk, primaryIsTwoHanded = true, false
    if primary ~= nil then
        twoHandOk, primaryIsTwoHanded = pcall(function()
            return primary.isTwoHandWeapon ~= nil
                and primary:isTwoHandWeapon() == true
        end)
    end
    if not twoHandOk then
        MC_Incident.report("ASL_HAND_STATE_UNREADABLE",
            "two-hand weapon state unavailable")
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your message was not sent because your hands could not be verified.",
            color = {255, 100, 100},
        })
        return nil
    end

    if (primary and secondary) or primaryIsTwoHanded then
        dbg("processMessage: signed message blocked -- both hands full")
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your hands are full \226\128\148 nothing can be said with them.",
            color = {255, 100, 100},
        })
        return nil
    end
    return ctx
end

local function processMessage(player, args)
    local ctx = validateEnvelope(player, args)
    if not ctx then return end

    if dispatchSlashCommand(ctx) then return end

    ctx = resolveTell(ctx)
    if not ctx then return end

    ctx = gateChannel(ctx)
    if not ctx then return end

    ctx = resolveOneShotLanguage(ctx)
    if not ctx then return end

    ctx = rejectCodeSwitch(ctx)
    if not ctx then return end

    ctx = checkLanguageRuntime(ctx)
    if not ctx then return end

    ctx = checkSignedHands(ctx)
    if not ctx then return end

    ctx = buildAndLog(ctx)
    if not ctx then return end

    if routeProximity(ctx) then
        routeRadio(ctx)
    end
end

-- COMMAND HANDLERS

local ServerCommands = {}

-- Client-side engine/API uncertainty is observable only in that client's Lua
-- state. Forward a small allowlisted incident code so operators receive the
-- same durable report as server-side degradations; never accept chat text or
-- arbitrary log labels from this untrusted boundary.
ServerCommands.FallbackIncident = function(player, args)
    MC_Incident.acceptClientReport(player, args)
end

ServerCommands.ChatMessage = function(player, args)
    processMessage(player, args)
end

ServerCommands.IdentityColorSyncRequest = function(player, args)
    if type(args) ~= "table" or args.protocol ~= 1 or not player then return end
    local username = readPlayerUsername(player,
        "IDENTITY_COLOR_IDENTITY_UNAVAILABLE", "request")
    if not username then return end
    identityColorCapable[username] = true
    -- Everyone receives only their own identity. Staff receive the current
    -- roster needed to resolve vanilla Admin authors; this does not leak that
    -- mapping to ordinary clients.
    publishIdentityColor(player)
    if identityColorRecipientHasAdminChat(player) then
        sendIdentityColorSnapshot(player)
    end
end

-- /announce (0.9.8): a server-wide system line under the fixed
-- MC_Config.Announce.author label. Admin-gated with the same fail-closed
-- shape as /event (unreadable access is an incident AND a refusal, never an
-- implicit pass). The broadcast is anonymous -- the announcing admin may be
-- masked among the players -- while the audit log (when server logging is
-- on) keeps the full admin identity under channel "announce".
ServerCommands.Announce = function(player, args)
    if type(args) ~= "table"
        or not isStrictString(args.message, MC_Config.MaxMessageLength) then
        MC_Incident.report("MESSAGE_INVALID", "stage=announce shape=invalid")
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your announcement was not sent because its message data was invalid.",
            color = {255, 100, 100},
        })
        return
    end

    local accessOk, accessLevel =
        pcall(function() return player:getAccessLevel() end)
    if not accessOk or not isStrictString(accessLevel, 32) then
        MC_Incident.report("ADMIN_ACCESS_UNAVAILABLE",
            "context=announce stage=access-read")
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your announcement was not sent because admin access could not be verified.",
            color = {255, 100, 100},
        })
        return
    end
    if accessLevel:lower() ~= "admin" then
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Announcements belong to the server's staff -- /announce is for admins.",
            color = {255, 100, 100},
        })
        return
    end

    -- Full identity envelope for the audit trail only (the /event pattern:
    -- the log keeps the admin, the broadcast carries none of it).
    local msgData, failReason = buildMessageData(player, "announce", args.message)
    if not msgData then
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = messageBuildFailureText(failReason),
            color = {255, 100, 100},
        })
        return
    end
    logMessage(msgData)  -- self-disables when ServerLoggingEnabled is off

    -- No separate ack: the admin is in the roster and receives the
    -- announcement itself; only a roster failure needs telling.
    if not broadcastToAll("SystemMessage", {
        message = args.message,
        author  = MC_Config.Announce.author,
        color   = MC_Config.Announce.color,
    }) then
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "Your announcement was not sent because the player roster could not be read.",
            color = {255, 100, 100},
        })
    end
end

ServerCommands.Typing = function(player, args)
    -- Hard hand-off: with typing dots disabled, do not validate, relay, or
    -- reveal that a client is composing at all.
    if not MC_Config.TypingIndicators
        or MC_Config.TypingIndicators.enabled ~= true then return end
    if not player or type(args) ~= "table" then
        MC_Incident.report("TYPING_REQUEST_INVALID",
            "context=typing stage=envelope")
        dbg("Typing: nil player or non-table args")
        return
    end

    -- Typing presence is only meaningful on the four proximity speech
    -- channels. Never widen a malformed/stale client value to ordinary say.
    local channel = args.channel
    if not isStrictString(channel, 32)
        or not MC_Lang.isSpeechChannel(channel) then
        MC_Incident.report("TYPING_REQUEST_INVALID",
            "context=typing stage=channel")
        return
    end
    local range = configuredRange(channel, "typing")
    if range == nil then
        return
    end

    local speakerUsername = readPlayerUsername(
        player, "TYPING_IDENTITY_UNAVAILABLE", "typing-speaker")
    local playerId = readOnlineId(
        player, "TYPING_IDENTITY_UNAVAILABLE", "typing-speaker")
    if not speakerUsername or playerId == nil then return end

    local players = snapshotOnlinePlayers(
        "TYPING_ROSTER_UNAVAILABLE", "typing")
    if not players then return end

    local entries = {}
    local seenIds = {}
    local speakerCount = 0
    for _, targetPlayer in ipairs(players) do
        local targetId = readOnlineId(targetPlayer,
            "TYPING_ROSTER_UNAVAILABLE", "typing-receiver")
        local targetUsername = readPlayerUsername(targetPlayer,
            "TYPING_ROSTER_UNAVAILABLE", "typing-receiver")
        if targetId == nil or targetUsername == nil then return end
        if seenIds[targetId] then
            MC_Incident.report("TYPING_ROSTER_UNAVAILABLE",
                "context=typing stage=duplicate-online-id")
            return
        end
        seenIds[targetId] = true
        if targetId == playerId then
            speakerCount = speakerCount + 1
            if targetUsername ~= speakerUsername then
                MC_Incident.report("TYPING_IDENTITY_UNAVAILABLE",
                    "context=typing stage=roster-username")
                return
            end
        end
        entries[#entries + 1] = {
            player = targetPlayer,
            id = targetId,
        }
    end
    if speakerCount ~= 1 then
        MC_Incident.report("TYPING_IDENTITY_UNAVAILABLE",
            "context=typing stage=roster-membership")
        return
    end

    dbg("Typing: %s [%s]", speakerUsername, channel)

    local typingData = {
        username = speakerUsername,
        channel = channel,
    }

    local isGlobal = (range == -1)

    for _, entry in ipairs(entries) do
        local targetPlayer = entry.player
        local targetId = entry.id
        if targetId ~= playerId then
            local shouldSend = isGlobal
            if not isGlobal then
                local distance = getDistance(player, targetPlayer)
                if distance ~= nil then
                    shouldSend = (distance <= range)
                    if not shouldSend then
                        local sameVehicle, vehicleAuthoritative =
                            inSameVehicle(player, targetPlayer)
                        shouldSend = vehicleAuthoritative and sameVehicle
                    end
                end
            end
            if shouldSend then
                local deliveryOk, result = pcall(sendServerCommand,
                    targetPlayer, "MongooseChat", "Typing", typingData)
                if not deliveryOk or result == false then
                    MC_Incident.report("TYPING_DELIVERY_FAILED",
                        "context=typing stage=transport")
                end
            end
        end
    end
end

-- BIO/TAGLINE COMMANDS

local function bioFeatureEnabled()
    return not (MC_Config.Features and MC_Config.Features.bio == false)
end

local BIO_SERVER_COMMANDS = {
    BioSave = true,
    BioLoad = true,
    BioSyncAll = true,
    DescSave = true,
    DescLoad = true,
    NoteSave = true,
    NoteLoad = true,
    NoteClearAbout = true,
}

ServerCommands.BioSave = function(player, args)
    local kind = "bio"
    if type(args) ~= "table" then
        rejectIdentityMutation(player, kind, nil, "malformed_request",
            "IDENTITY_MUTATION_REQUEST_MALFORMED", "args")
        return
    end
    local token = args.requestToken
    if not validMutationRequestToken(token) then
        rejectIdentityMutation(player, kind, token, "malformed_request",
            "IDENTITY_MUTATION_REQUEST_MALFORMED", "token")
        return
    end

    local username = authenticatedMutationUsername(player, kind, token)
    if not username then return end
    
    -- Allow empty tagline (clears it), but reject non-string. Control chars
    -- and overlength payloads are malformed rather than silently rewritten.
    if type(args.tagline) ~= "string" then
        rejectIdentityMutation(player, kind, token, "malformed_request",
            "IDENTITY_MUTATION_REQUEST_MALFORMED", "value-type")
        return
    end
    local tagline = args.tagline:gsub("[%c]", ""):sub(1, BIO_MAX_LENGTH)
    if tagline ~= args.tagline then
        rejectIdentityMutation(player, kind, token, "malformed_request",
            "IDENTITY_MUTATION_REQUEST_MALFORMED", "value-shape")
        return
    end
    
    local ok = MC_Bio.transact("BioSave", function(taglines)
        local nextValue = (tagline ~= "") and tagline or nil
        if taglines[username] == nextValue then return false end
        taglines[username] = nextValue
        return true
    end)
    if not ok then
        rejectIdentityMutation(player, kind, token, "persistence_failed",
            "IDENTITY_MUTATION_PERSIST_FAILED", "commit")
        return
    end
    dbg("BioSave: %s = '%s'", username, tagline)
    
    -- Broadcast to all online players so they update their caches
    local broadcastCallOk, broadcastSentAll =
        pcall(broadcastToAll, "BioUpdate", {
            username = username,
            tagline = tagline,
        })
    local propagated = broadcastCallOk and broadcastSentAll == true
    if not propagated then
        reportIdentityMutation(
            "IDENTITY_MUTATION_PROPAGATION_FAILED", kind,
            broadcastCallOk and "partial" or "dispatch")
    end
    sendIdentityMutationAck(player, kind, token, true, nil, {
        username = username,
        value = tagline,
        propagated = propagated,
    })
end

ServerCommands.BioLoad = function(player, args)
    if not player or type(args) ~= "table" then return end
    if not MC_Bio.ensureLoaded() then
        tellStorageFailure(player)
        return
    end
    
    local targetUsername = validString(args.username, 64)
    if not targetUsername then return end
    
    local tagline = MC_BioDB.taglines[targetUsername] or ""
    
    sendServerCommand(player, "MongooseChat", "BioData", {
        username = targetUsername,
        tagline = tagline
    })
    dbg("BioLoad: sent %s's tagline to %s", targetUsername, 
        MC_Core.safe(function() return player:getUsername() end, "?"))
end

ServerCommands.BioSyncAll = function(player, args)
    if not player then return end
    local bioReady = MC_Bio.ensureLoaded()
    local descReady = MC_Desc.ensureLoaded()
    if not bioReady or not descReady then
        tellStorageFailure(player)
        return
    end

    -- Send all taglines AND descriptions to the requesting player in one sync.
    -- descriptions is an additive field; older clients simply ignore it.
    sendServerCommand(player, "MongooseChat", "BioSyncAll", {
        bios = MC_BioDB.taglines,
        descriptions = MC_Desc.db.descriptions
    })
    dbg("BioSyncAll: sent %d bios / %d descriptions to %s",
        MC_Core.tableSize(MC_BioDB.taglines), MC_Core.tableSize(MC_Desc.db.descriptions),
        MC_Core.safe(function() return player:getUsername() end, "?"))
end

-- DESCRIPTION / CHARACTER-SHEET COMMANDS
-- Parallel to the Bio commands above; server-authoritative, broadcast on save.

ServerCommands.DescSave = function(player, args)
    local kind = "description"
    if type(args) ~= "table" then
        rejectIdentityMutation(player, kind, nil, "malformed_request",
            "IDENTITY_MUTATION_REQUEST_MALFORMED", "args")
        return
    end
    local token = args.requestToken
    if not validMutationRequestToken(token) then
        rejectIdentityMutation(player, kind, token, "malformed_request",
            "IDENTITY_MUTATION_REQUEST_MALFORMED", "token")
        return
    end

    local username = authenticatedMutationUsername(player, kind, token)
    if not username then return end

    -- Allow empty (clears it); reject non-string. sanitize keeps newlines and
    -- caps length.
    if type(args.description) ~= "string" then
        rejectIdentityMutation(player, kind, token, "malformed_request",
            "IDENTITY_MUTATION_REQUEST_MALFORMED", "value-type")
        return
    end
    local description = MC_Desc.sanitize(args.description)
    if description ~= args.description then
        rejectIdentityMutation(player, kind, token, "malformed_request",
            "IDENTITY_MUTATION_REQUEST_MALFORMED", "value-shape")
        return
    end

    local ok = MC_Desc.transact("DescSave", function(descriptions)
        local nextValue = (description ~= "") and description or nil
        if descriptions[username] == nextValue then return false end
        descriptions[username] = nextValue
        return true
    end)
    if not ok then
        rejectIdentityMutation(player, kind, token, "persistence_failed",
            "IDENTITY_MUTATION_PERSIST_FAILED", "commit")
        return
    end
    dbg("DescSave: %s = %d chars", username, #description)

    -- Broadcast so every online client updates its cache.
    local broadcastCallOk, broadcastSentAll =
        pcall(broadcastToAll, "DescUpdate", {
            username = username,
            description = description,
        })
    local propagated = broadcastCallOk and broadcastSentAll == true
    if not propagated then
        reportIdentityMutation(
            "IDENTITY_MUTATION_PROPAGATION_FAILED", kind,
            broadcastCallOk and "partial" or "dispatch")
    end
    sendIdentityMutationAck(player, kind, token, true, nil, {
        username = username,
        value = description,
        propagated = propagated,
    })
end

ServerCommands.DescLoad = function(player, args)
    if not player or type(args) ~= "table" then return end
    if not MC_Desc.ensureLoaded() then
        tellStorageFailure(player)
        return
    end

    local targetUsername = validString(args.username, 64)
    if not targetUsername then return end

    local description = MC_Desc.db.descriptions[targetUsername] or ""

    sendServerCommand(player, "MongooseChat", "DescData", {
        username = targetUsername,
        description = description
    })
    dbg("DescLoad: sent %s's description to %s", targetUsername,
        MC_Core.safe(function() return player:getUsername() end, "?"))
end

-- PERSONAL NOTES COMMANDS
-- Private. The viewer is ALWAYS the authenticated sender username, never a
-- field from the client -- so a player can only ever read or write their own
-- notes, and NoteData only ever flows back to the author.

ServerCommands.NoteSave = function(player, args)
    local kind = "note"
    if type(args) ~= "table" then
        rejectIdentityMutation(player, kind, nil, "malformed_request",
            "IDENTITY_MUTATION_REQUEST_MALFORMED", "args")
        return
    end
    local token = args.requestToken
    if not validMutationRequestToken(token) then
        rejectIdentityMutation(player, kind, token, "malformed_request",
            "IDENTITY_MUTATION_REQUEST_MALFORMED", "token")
        return
    end
    local viewer = authenticatedMutationUsername(player, kind, token)
    if not viewer then return end
    if type(args.target) ~= "string" or args.target == ""
        or #args.target > 64 or args.target:find("[%c]") then
        rejectIdentityMutation(player, kind, token, "malformed_request",
            "IDENTITY_MUTATION_REQUEST_MALFORMED", "target")
        return
    end
    local target = args.target

    if type(args.note) ~= "string" then
        rejectIdentityMutation(player, kind, token, "malformed_request",
            "IDENTITY_MUTATION_REQUEST_MALFORMED", "value-type")
        return
    end
    local note = MC_Notes.sanitize(args.note)
    if note ~= args.note then
        rejectIdentityMutation(player, kind, token, "malformed_request",
            "IDENTITY_MUTATION_REQUEST_MALFORMED", "value-shape")
        return
    end

    local ok = MC_Notes.transact("NoteSave", function(notes)
        local mine = notes[viewer]
        if note == "" then
            if not mine or mine[target] == nil then return false end
            mine[target] = nil
            if MC_Core.isEmpty(mine) then notes[viewer] = nil end
        else
            if not mine then mine = {}; notes[viewer] = mine end
            if mine[target] == note then return false end
            mine[target] = note
        end
        return true
    end)
    if not ok then
        rejectIdentityMutation(player, kind, token, "persistence_failed",
            "IDENTITY_MUTATION_PERSIST_FAILED", "commit")
        return
    end
    dbg("NoteSave: %s about %s (%d chars)", viewer, target, #note)
    -- Confirm to the author only (private).
    sendIdentityMutationAck(player, kind, token, true, nil, {
        target = target,
        value = note,
        propagated = true,
    })
end

ServerCommands.NoteLoad = function(player, args)
    if not player or type(args) ~= "table" then return end
    if not MC_Notes.ensureLoaded() then
        tellStorageFailure(player)
        return
    end
    local viewer = MC_Core.safe(function() return player:getUsername() end, nil)
    if not viewer then return end
    local target = validString(args.target, 64)
    if not target then return end

    local mine = MC_Notes.db.notes[viewer]
    local note = (mine and mine[target]) or ""
    sendServerCommand(player, "MongooseChat", "NoteData", { target = target, note = note })
end

-- Legacy clients used to request a note-graph wipe themselves when they
-- guessed that they were a new character. That made identity destruction
-- client-authorized: an established or modified client could erase everybody's
-- private notes about it. Fresh-character admission and /lang resetall are now
-- the only authoritative identity-clear paths, so the old command is always
-- rejected and always reported.
ServerCommands.NoteClearAbout = function(player, args)
    if not player then return end
    local target = MC_Core.safe(function() return player:getUsername() end, nil)
    MC_Incident.report("LEGACY_IDENTITY_CLEAR_BLOCKED",
        "command=NoteClearAbout client="
            .. tostring(target or "unavailable"))
    sendServerCommand(player, "MongooseChat", "SystemMessage", {
        message = "That legacy identity-clear request was refused. Fresh-character and administrator wipes are server-authoritative.",
        color = {255, 100, 100},
    })
end

--[[
    Server-authoritative boredom reduction.
    Client sends request when hearing others talk; server modifies the stat.
    
    Supports both B42 API (CharacterStat.BOREDOM) and B41 fallback (getBoredom/setBoredom).
    B42: Stats:get/set(CharacterStat.BOREDOM) with 0.0-1.0 scale
    B41: Stats:getBoredom()/setBoredom() with 0.0-1.0 scale
]]
ServerCommands.ReduceBoredom = function(player, args)
    if not player then return end
    if not MC_Config.Boredom.enabled then return end

    local statsOk, stats = pcall(function() return player:getStats() end)
    if not statsOk or not stats then
        MC_Incident.report("BOREDOM_STATE_UNAVAILABLE",
            "stage=stats")
        return
    end

    -- Calculate reduction (config is 0-100, convert to 0.0-1.0)
    local reductionPercent = MC_Config.Boredom.reductionAmount
    if type(reductionPercent) ~= "number"
        or reductionPercent ~= reductionPercent
        or reductionPercent < 0 or reductionPercent > 100 then
        MC_Incident.report("BOREDOM_STATE_UNAVAILABLE",
            "stage=config")
        return
    end
    local reduction = reductionPercent / 100

    -- Try B42 API first (CharacterStat.BOREDOM)
    local CharacterStat = CharacterStat or _G.CharacterStat
    if CharacterStat and CharacterStat.BOREDOM then
        local readOk, current =
            pcall(function() return stats:get(CharacterStat.BOREDOM) end)
        if readOk and type(current) == "number"
            and current == current
            and current > -math.huge and current < math.huge then
            local newVal = math.max(0, current - reduction)
            local writeOk = pcall(function()
                stats:set(CharacterStat.BOREDOM, newVal)
            end)
            if not writeOk then
                MC_Incident.report("BOREDOM_STATE_UNAVAILABLE",
                    "stage=b42-write")
                return
            end
            dbg("ReduceBoredom (B42): %s %.3f -> %.3f (-%d%%)",
                MC_Core.safe(function() return player:getUsername() end, "?"),
                current, newVal, reductionPercent)
            return
        end
        MC_Incident.report("BOREDOM_API_FALLBACK",
            "stage=b42-read")
    else
        MC_Incident.report("BOREDOM_API_FALLBACK",
            "stage=b42-unavailable")
    end

    -- Fallback to B41 API (getBoredom/setBoredom)
    if stats.getBoredom and stats.setBoredom then
        local readOk, current = pcall(function() return stats:getBoredom() end)
        if readOk and type(current) == "number"
            and current == current
            and current > -math.huge and current < math.huge then
            local newVal = math.max(0, current - reduction)
            local writeOk = pcall(function() stats:setBoredom(newVal) end)
            if not writeOk then
                MC_Incident.report("BOREDOM_STATE_UNAVAILABLE",
                    "stage=b41-write")
                return
            end
            dbg("ReduceBoredom (B41): %s %.3f -> %.3f (-%d%%)",
                MC_Core.safe(function() return player:getUsername() end, "?"),
                current, newVal, reductionPercent)
            return
        end
        MC_Incident.report("BOREDOM_STATE_UNAVAILABLE",
            "stage=b41-read")
        return
    end

    MC_Incident.report("BOREDOM_STATE_UNAVAILABLE",
        "stage=no-compatible-api")
end

--[[
    ServerCommands.GrantLanguage / ServerCommands.RevokeLanguage (v8.4)

    Client->server commands fired by the right-click context menu's
    "Languages >" submenu. Both forward to MC_LangCommands' shared
    runGrantNative/runRevokeNative cores -- the same admin gate, language
    validation, and response text as the /lang grant|revoke chat command,
    single-sourced (the two transports had drifted otherwise). This
    listener's own job is arg-shape defense only (C15: a malicious client
    can send anything).

    args:
      target   = string (username -- NOT forename; client sends the
                 IsoPlayer:getUsername() directly so no resolution needed)
      language = string (lowercase language id)
]]
ServerCommands.GrantLanguage = function(player, args)
    if not player or type(args) ~= "table" then return end
    local target   = args.target
    local language = args.language
    if type(target) ~= "string" or target == "" or type(language) ~= "string" or language == "" then
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "GrantLanguage: missing target or language.",
            color = {255, 100, 100},
        })
        return
    end
    MC_LangCommands.runGrantNative(player, target, language)
end

ServerCommands.RevokeLanguage = function(player, args)
    if not player or type(args) ~= "table" then return end
    local target   = args.target
    local language = args.language
    if type(target) ~= "string" or target == "" or type(language) ~= "string" or language == "" then
        sendServerCommand(player, "MongooseChat", "SystemMessage", {
            message = "RevokeLanguage: missing target or language.",
            color = {255, 100, 100},
        })
        return
    end
    MC_LangCommands.runRevokeNative(player, target, language)
end

-- FRESH-CHARACTER DETECTION (v8.16.2)
-- Language state is keyed by username, so it survives character death: a
-- re-rolled character walks in carrying everything the dead one earned.
-- When a brand-new character shows up on a username that still carries
-- language state, MC_Lang.handleFreshCharacter applies the policy
-- (MC_Config.Languages.deathReset: notify / auto / off).
--
-- Detection runs on every client command (one getHoursSurvived call on the
-- fast path -- same cost class as the getUsername in OnClientCommand's dbg
-- line). A character under FRESH_HOURS_WINDOW game-hours survived is
-- brand-new; a merely-reconnecting living character always has more, so a
-- living character can NEVER trip this. Two guards keep it from firing
-- twice for the same character: a session memo keyed to the exact player
-- object (never username alone, because rapid re-rolls may share it) and a
-- per-character getModData stamp. B42 MP modData persists unreliably (see
-- the bio storage note above), but losing the stamp only risks a repeat on
-- a still-fresh character -- the object memo and hours gate hold regardless.

-- Brand-new means under this many game-hours survived. Wide enough to catch
-- the gap between spawn and the character's first client command (fresh
-- joins ping BioSyncAll at OnGameStart; mid-session respawns ping on their
-- first hear/type/say), narrow enough that an established character can
-- never trip it.
local FRESH_HOURS_WINDOW = 0.5

-- Versioned marker: older builds stamped MC_FreshHandled after checking only
-- language inheritance. A distinct key ensures a still-fresh character seen
-- during the 0.9 upgrade also receives the authoritative identity-store wipe.
local FRESH_MARKER = "MC_FreshIdentityHandled_v090"

local freshHandled = {}   -- [username] = exact player object once that body has
                          -- been through the full check this session

-- Any language state worth handling? A speaking choice, a native grant
-- beyond the english baseline, or any acquisition data (partial progress
-- included -- the same inventory /lang reset previews).
local function hasLanguageState(username)
    if type(MC_Lang.isStorageAvailable) ~= "function"
        or not MC_Lang.isStorageAvailable()
        or type(MC_Acquisition.isStorageAvailable) ~= "function"
        or not MC_Acquisition.isStorageAvailable() then
        return nil
    end
    if MC_Lang.getLanguage(username) ~= "english" then return true end
    if #MC_Lang.getNativeLanguages(username) > 1 then return true end
    return #MC_Acquisition.languagesWithData(username) > 0
end

local function checkFreshCharacter(player)
    local username = MC_Core.safe(function() return player:getUsername() end, nil)
    if type(username) ~= "string" or username == "" then
        MC_Incident.report("FRESH_CHARACTER_STATE_UNAVAILABLE", "stage=username")
        return false
    end

    local hours = MC_Core.safe(function() return player:getHoursSurvived() end, nil)
    if type(hours) ~= "number" or hours ~= hours
        or hours <= -math.huge or hours >= math.huge or hours < 0 then
        MC_Incident.report("FRESH_CHARACTER_STATE_UNAVAILABLE", "stage=hours")
        return false
    end
    if hours >= FRESH_HOURS_WINDOW then
        -- Established character: nothing to do. Re-arm the memo so this
        -- username's NEXT character (mid-session death -> re-roll) is seen.
        freshHandled[username] = nil
        return true
    end

    -- Object identity matters: two fresh bodies can share a username before
    -- the old body is ever observed past the hours window. A username-only memo
    -- would admit the rapid re-roll with inherited identity.
    if freshHandled[username] == player then return true end

    -- Per-character stamp: never fire twice for the same character, even
    -- across a reconnect. Missing modData = fail toward silence and retry
    -- on a later command (memo only sticks once modData is readable).
    local modData = MC_Core.safe(function() return player:getModData() end, nil)
    if type(modData) ~= "table" then
        MC_Incident.report("FRESH_CHARACTER_STATE_UNAVAILABLE", "stage=moddata")
        return false
    end
    local markerReadOk, marked = pcall(function()
        return modData[FRESH_MARKER]
    end)
    if not markerReadOk then
        MC_Incident.report("FRESH_CHARACTER_STATE_UNAVAILABLE",
            "stage=moddata-read")
        return false
    end
    if marked then
        freshHandled[username] = player
        return true
    end

    -- Presentation identity never inherits, regardless of the configured
    -- language-death fiction. This is server-authoritative and must complete
    -- across every registered identity store before the character is stamped.
    local identityOk, identityHandled = pcall(MC_Lang.clearFreshIdentity, username)
    if not identityOk or identityHandled ~= true then
        MC_Incident.report("FRESH_IDENTITY_WIPE_FAILED", "stage=dispatch")
        return false
    end

    local carried = hasLanguageState(username)
    if carried == nil then
        MC_Incident.report("FRESH_CHARACTER_POLICY_FAILED", "stage=inventory")
        return false
    end
    if carried then
        dbg("checkFreshCharacter: fresh character for %s (%.2f hours survived), handing to MC_Lang",
            username, hours)
        -- handleFreshCharacter's own inner pcall only narrates to dbg, which is
        -- DEBUG-gated -- with debug off, an uncaught error here would otherwise
        -- vanish at every layer.
        local ok, handled = pcall(MC_Lang.handleFreshCharacter, player)
        if not ok or handled ~= true then
            MC_Incident.report("FRESH_CHARACTER_POLICY_FAILED", "stage=handler")
            return false
        end
    else
        dbg("checkFreshCharacter: %s is fresh but carries no language state", username)
    end
    local markerWriteOk = pcall(function()
        modData[FRESH_MARKER] = true
        if modData[FRESH_MARKER] ~= true then
            error("fresh marker write was not observable")
        end
    end)
    if not markerWriteOk then
        MC_Incident.report("FRESH_CHARACTER_STATE_UNAVAILABLE",
            "stage=moddata-write")
        return false
    end
    freshHandled[username] = player
    return true
end

-- EVENT HOOKS

local function OnClientCommand(module, command, player, args)
    if module ~= "MongooseChat" then return end
    if BIO_SERVER_COMMANDS[command] and not bioFeatureEnabled() then
        -- Disabled optional modules are absent, not refusing services. A
        -- client from another mod may use the same words without MC replying.
        return
    end
    local mutationKind = identityMutationKind(command)

    dbg("OnClientCommand: %s from %s", command,
        MC_Core.safe(function() return player:getUsername() end, "nil"))

    -- Fresh-character detection: any command from a brand-new character on
    -- a username with carried-over language state hands off to MC_Lang.
    if player and checkFreshCharacter(player) ~= true then
        -- Admission failed before this command could be proven to belong to a
        -- fully-cleared character. Never run the requested handler against
        -- ambiguous old/new identity state; the next command retries.
        if command == "ChatMessage" then
            sendServerCommand(player, "MongooseChat", "SystemMessage", {
                message = "Your message was not sent because your character lifecycle state could not be verified.",
                color = {255, 100, 100},
            })
        end
        if mutationKind then
            local token = type(args) == "table" and args.requestToken or nil
            rejectIdentityMutation(player, mutationKind, token,
                "identity_unavailable",
                "IDENTITY_MUTATION_IDENTITY_UNAVAILABLE", "admission")
        end
        return
    end

    local handler = ServerCommands[command]
    if handler then
        local ok, err = pcall(handler, player, args)
        if not ok then
            MC_Incident.report("CLIENT_COMMAND_FAILED",
                "command=" .. tostring(command))
            if mutationKind then
                local token = type(args) == "table"
                    and args.requestToken or nil
                if validMutationRequestToken(token) then
                    sendIdentityMutationAck(player, mutationKind, token,
                        false, "internal_failure")
                else
                    reportIdentityMutation(
                        "IDENTITY_MUTATION_REQUEST_MALFORMED",
                        mutationKind, "handler-token")
                end
            end
        end
    else
        dbg("OnClientCommand: Unknown command: %s", tostring(command))
    end
end

-- CONNECTION NOTIFICATIONS
-- The server roster is the authority. Account names are private map keys only;
-- clients receive only the public character name and a fixed event kind.

local connectionNotifPrevious = {}
local connectionNotifInitialized = false
local connectionNotifLastCheckAt = nil

local function connectionNotifsActive()
    return MC_Config.liveSandbox("EnableConnectionNotifs", true) ~= false
        and MC_Config.liveSandbox("OOCEnabled", true) ~= false
        and MC_Config.liveSandbox("ChatWindowEnabled", true) ~= false
end

local function resetConnectionNotifBaseline()
    if connectionNotifInitialized ~= true
        and connectionNotifLastCheckAt == nil
        and MC_Core.isEmpty(connectionNotifPrevious) then
        return
    end
    connectionNotifPrevious = {}
    connectionNotifInitialized = false
    connectionNotifLastCheckAt = nil
end

local function connectionNotifSnapshot()
    local players = snapshotOnlinePlayers(
        "CONNECTION_NOTIFS_ROSTER_UNAVAILABLE", "connection-notifs")
    if not players then return nil end

    local byUsername = {}
    for _, player in ipairs(players) do
        local username = readPlayerUsername(player,
            "CONNECTION_NOTIFS_ROSTER_UNAVAILABLE", "connection-notifs")
        local displayName = getCharacterName(player)
        if not username or not displayName or byUsername[username] ~= nil then
            MC_Incident.report("CONNECTION_NOTIFS_ROSTER_UNAVAILABLE",
                "context=connection-notifs stage=identity")
            return nil
        end
        byUsername[username] = { player = player, displayName = displayName }
    end
    return byUsername, players
end

local function pollConnectionNotifs(now)
    now = tonumber(now) or MC_Core.getTimeMs()
    if not connectionNotifsActive() then
        resetConnectionNotifBaseline()
        return
    end

    local interval = MC_Config.liveSandbox(
        "ConnectionNotifsCheckInterval", 2000)
    if type(interval) ~= "number" or interval ~= math.floor(interval)
        or interval < 1000 or interval > 60000 then
        interval = 2000
    end
    if connectionNotifLastCheckAt ~= nil
        and now - connectionNotifLastCheckAt < interval then return end
    connectionNotifLastCheckAt = now

    local current, recipients = connectionNotifSnapshot()
    if not current then return end
    local changes = MC_ConnectionNotifs.diff(connectionNotifPrevious,
        current, connectionNotifInitialized)
    if not changes then return end

    -- Advance the last-good state before delivery. A client disappearing or
    -- one failed send must not replay an already observed roster change.
    connectionNotifPrevious = current
    connectionNotifInitialized = true

    for _, change in ipairs(changes) do
        local packet = { kind = change.kind, displayName = change.displayName }
        for _, target in ipairs(recipients) do
            local ok = pcall(sendServerCommand, target, "MongooseChat",
                "ConnectionNotification", packet)
            if not ok then
                MC_Incident.report("CONNECTION_NOTIFS_SEND_FAILED",
                    "kind=" .. tostring(change.kind))
            end
        end
    end
end

local function OnConnectionNotifsTick()
    local ok = pcall(function()
        pollConnectionNotifs(MC_Core.getTimeMs())
    end)
    if not ok then
        MC_Incident.report("CONNECTION_NOTIFS_POLL_FAILED", "stage=tick")
    end
end

local function OnServerStarted()
    resetConnectionNotifBaseline()
    -- Pull server's actual sandbox config into MC_Config.
    -- Before this, MC_Config holds the default fallbacks (module load precedes
    -- sandbox var population). Every ZombieAttraction/Boredom/OOC/range check
    -- in processMessage reads MC_Config, so reloading here is what makes
    -- admin-configured sandbox settings actually take effect.
    local reloadCallOk, reloadAuthoritative =
        pcall(MC_Config.reloadSandboxVars)
    if not reloadCallOk or type(reloadAuthoritative) ~= "boolean" then
        sandboxReloadState = "failed"
        MC_Incident.report("SERVER_SANDBOX_RELOAD_FAILED",
            "context=startup stage="
                .. (reloadCallOk and "return" or "exception"))
    elseif reloadAuthoritative then
        sandboxReloadState = "authoritative"
    else
        -- MC_Config has already reported the exact fallback count. Keep its
        -- conservative values usable, but record that startup is degraded;
        -- invalid values are still rejected at every critical read above.
        sandboxReloadState = "degraded"
        MC_Incident.report("SERVER_SANDBOX_RELOAD_FAILED",
            "context=startup stage=nonauthoritative")
    end

    MC_Core.printBanner()
    dbg("=== SERVER MODULE LOADED ===")
    dbg("Ranges: whisper=%s, say=%s, yell=%s, low=%s",
        tostring(MC_Config.Ranges and MC_Config.Ranges.whisper),
        tostring(MC_Config.Ranges and MC_Config.Ranges.say),
        tostring(MC_Config.Ranges and MC_Config.Ranges.yell),
        tostring(MC_Config.Ranges and MC_Config.Ranges.low))

    -- v8.16.1: acquisition profile. MC_Acquisition is engine-independent and
    -- can't read sandbox vars itself, so the server side pins the profile.
    MC_Acquisition.setProfile("live")

    -- v8.16.2: learning-speed knob (AcquisitionSpeed sandbox option),
    -- layered over the profile -- same injection rationale as above.
    local speed = (MC_Config.Acquisition and MC_Config.Acquisition.speed)
        or "default"
    MC_Acquisition.setSpeed(speed)
end

Events.OnClientCommand.Add(OnClientCommand)
Events.OnServerStarted.Add(OnServerStarted)
Events.OnTick.Add(OnConnectionNotifsTick)

MC_Server._ServerCommands = ServerCommands
MC_Server._OnServerStarted = OnServerStarted
MC_Server._messageBuildFailureText = messageBuildFailureText
MC_Server._pollConnectionNotifs = pollConnectionNotifs
MC_Server._resetConnectionNotifBaseline = resetConnectionNotifBaseline

MC_Server._identifiedLangs = identifiedLangs

MC_Server._SlashHandlers = SLASH_HANDLERS

-- ACQUISITION ENGINE WIRING (composition root)
-- MC_Acquisition is engine-pure -- no PZ globals, no Events access of its
-- own (docs/ARCHITECTURE.md, "Engine purity"). Its boot-time load/migrate
-- and its periodic disk flush are therefore registered HERE rather than
-- inside the engine, the same injection pattern as MC_Acquisition.setProfile/
-- setSpeed above and MC_Lang's setExposureTraceSink/setLapseNoticeSink: the
-- engine exposes named functions, the composition root decides when they run.
--
-- Ordering note: this fires after this file's own OnServerStarted (which
-- only reloads sandbox vars and pins the acquisition profile/speed --
-- neither reads nor writes the acquisition DB) and after the per-store
-- OnServerStarted hooks above (each an independent store keyed by
-- username, none of which touch acquisition data). No handler here depends
-- on another's having already run, so registering last is safe.
Events.OnServerStarted.Add(MC_Acquisition.onServerStarted)
Events.EveryOneMinute.Add(MC_Acquisition.onEveryOneMinute)

-- The MongooseBot announcement inbox poller (0.9.8). Independent of
-- acquisition's flush above -- neither depends on the other having run.
-- pcall-guarded so a filesystem surprise can never poison the shared
-- EveryOneMinute dispatch for later handlers.
Events.EveryOneMinute.Add(function()
    local ok = pcall(pollAnnounceInbox)
    if not ok then
        MC_Incident.report("ANNOUNCE_FILE_INVALID", "stage=poll-crash")
    end
end)

return MC_Server
