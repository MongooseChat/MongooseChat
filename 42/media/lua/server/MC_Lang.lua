--[[
================================================================================
    MongooseChat - Language Module
    
    Per-speaker language assignment, per-receiver language transform.
    
    The babble engine (MC_Babble) is pure pipeline -- it takes a message, a
    palette, a bleed-through set, and a seed, and returns a transformed
    string. This module is the integration layer: it owns per-username
    language storage, picks palettes by name, builds the bleed-through set
    from server roster context, composes seeds for per-speaker voice, and
    decides per-receiver whether to babble, return clean+tag, or just clean.
    
    PUBLIC API:
      Language state (MC_Server + MC_LangCommands read; setLanguage is
      MC_LangCommands-only, called from its /lang dispatcher; grantNative/
      revokeNative are MC_LangCommands-only too, called from its
      runGrantNative/runRevokeNative cores -- MC_Server reaches those
      cores, never grantNative/revokeNative directly):
        MC_Lang.getLanguage(username) -> string
        MC_Lang.setLanguage(username, language) -> bool
        MC_Lang.isNative(username, language) -> bool
        MC_Lang.getNativeLanguages(username) -> {string, ...}
        MC_Lang.grantNative(username, language) -> bool, bool (ok, alreadyHad)
        MC_Lang.revokeNative(username, language) -> bool, bool (ok, hadIt)
        MC_Lang.resetUser(username) -> table (summary)  -- MC_LangCommands,
                                        and MC_Lang itself (handleFreshCharacter)
        MC_Lang.getOrphanedNatives(username) -> {string, ...} (sorted)
        MC_Lang.pruneOrphanedNatives(username) -> {string, ...} (sorted, pruned)
                                        -- MC_LangCommands-only, called from
                                        -- its /lang prune handler

      Channel policy (MC_Server only):
        MC_Lang.shouldTransformChannel(channel) -> bool
        MC_Lang.isSpeechChannel(channel) -> bool
        MC_Lang.isSignedLanguage(language) -> bool
        MC_Lang.isLanguageRuntimeAvailable(language) -> bool
        MC_Lang.isDormantSigned(language) -> bool

      Render pipeline (MC_Server only):
        MC_Lang.renderForReceiver(speakerUsername, receiverUsername,
                                  message, timestamp, opts) -> string, string|nil, table|nil
        MC_Lang.speakerEcho(message, speakerUsername, timestamp) -> string|nil

      Wipe / lifecycle:
        MC_Lang.registerWipeExtension(id, ext) -> bool  -- MC_Server
        MC_Lang.handleFreshCharacter(player)             -- MC_Server only

      Leading-underscore exposures (_describeLang, _sysMsg,
      _playerByUsername, _onlinePlayerRecords, _traceUsers, etc.) are
      internal contracts for MC_LangCommands, documented at each
      definition -- not part of this surface.

    LIMITATIONS:
      - Anonymity not respected on bleed-through: MC_Anonymity is client-only,
        so the server can't check if a speaker is currently masked. Names from
        the roster will bleed through regardless. v1.1: move/duplicate
        MC_Anonymity to shared/server.
      - Dual-use exclamations (wait/stop/help/etc.) not bleed-through-eligible
        in v1 -- context-aware bleed (only when standalone/punctuated) requires
        per-token positional info. They babble. Safe failure direction.
      - Names bleed if they appear capitalized anywhere in the message; any
        lowercase occurrence in the same message also bleeds. Bounded false-
        bleed accepted for v1.
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Config = require("MC_Config")  -- v8.16.2: master switch + death-reset policy
local MC_Babble = require("MC_Babble")
local MC_LangRegistry = require("MC_LangRegistry")
local MC_Sanitize = require("MC_Sanitize")
local MC_Acquisition = require("MC_Acquisition")
local MC_Persist = require("MC_Persist")
local MC_Cultural = require("MC_Cultural")  -- v8.6: cultural fluency engine
local MC_Teaching = require("MC_Teaching")  -- v8.7: teaching engine
local MC_Resolve = require("MC_Resolve")    -- concept->L2 resolution
local MC_Incident = require("MC_Incident")

local MC_Lang = {}

local dbg = MC_Core.debugger("LANG")

-- PALETTES
-- 
-- Palettes are not enumerated here. Each palette file self-registers via
-- MC_LangRegistry at module load. Adding a language is a single-file change:
-- create `MC_Palette_<Name>.lua` in shared/ with a `register()` call at the
-- bottom, and the system picks it up.
-- 
-- We rely on PZ Build 42's automatic shared/-directory scan to execute every
-- top-level Lua file at mod load time, including the register() at the
-- bottom of each palette. By the time MC_Lang's render path or /lang command
-- handler ever runs, the registry is populated.
-- 
-- Previous versions of this file kept explicit `require("MC_Palette_X")`
-- calls here for load-order safety; those were removed in v8.2 once we
-- confirmed the auto-scan is reliable for the palette pattern. If you ever
-- need to force a palette to load before MC_Lang's module init (very
-- unusual), add the explicit require here.

-- CHANNEL POLICY
-- Babble applies to IC speech channels only. Emote/do/mood/ooc/admin exempt.
-- Faction/safehouse currently exempt -- some servers use them as IC; revisit
-- on demand rather than enabling by default.

local BABBLE_CHANNELS = {
    whisper = true,
    low = true,
    say = true,
    yell = true,
}

function MC_Lang.shouldTransformChannel(channel)
    -- Master switch (v8.16.2): LanguagesEnabled=false runs the server
    -- chat-features-only -- every IC channel renders clean, no barrier.
    -- Absent/legacy config reads as enabled.
    if MC_Config.Languages and MC_Config.Languages.enabled == false then
        return false
    end
    return BABBLE_CHANNELS[channel] == true
end

-- B3 fix: the channel-set half of shouldTransformChannel, with NO master-
-- switch gate. The hands gate and the client sight/modality gate are
-- physical/perceptual facts about signing, not features of the language
-- renderer -- LanguagesEnabled=false must not fail them open.
-- A message is either on a speech channel or it isn't, regardless of
-- whether the barrier itself is currently switched on.
function MC_Lang.isSpeechChannel(channel)
    return BABBLE_CHANNELS[channel] == true
end

-- QUOTED SPEECH INSIDE NARRATION
--
-- /me and /do are narration, but a player may quote words their character
-- said aloud inside one:
--     /me leans on the counter. "You seen Marta?" he asks.
-- Those words ARE speech, and are treated as speech: they cross the language
-- barrier, they teach and are acquired, and a listener who cannot hear them
-- does not receive them. The narration around them is not speech and passes
-- through untouched -- it describes what a watcher can see, and a watcher
-- can see it whether or not they share a language with the speaker.
--
-- This is the mirror image of MC_Sanitize's protected regions, which keep an
-- *emote* written inside a spoken line OUT of the language pipeline. Here the
-- default is reversed: the line is exempt, and only its quoted runs go in.

local NARRATION_CHANNELS = {
    emote = true,
    ["do"] = true,
}

function MC_Lang.isNarrationChannel(channel)
    return NARRATION_CHANNELS[channel] == true
end

-- True only when a narration line actually carries spoken words. Narration
-- with no quotes never enters the language pipeline at all, so the ordinary
-- emote costs exactly what it always did.
function MC_Lang.shouldTransformNarration(channel, message)
    if MC_Config.Languages and MC_Config.Languages.enabled == false then
        return false
    end
    return NARRATION_CHANNELS[channel] == true
        and type(message) == "string"
        and #MC_Core.findQuotedRuns(message) > 0
end

-- True for an intrinsically signed language key (ASL today). Modality lives in
-- registry metadata, independently of the palette payload: disabling a
-- language or failing to load its palette may prevent the utterance, but must
-- never reinterpret signs as audible plaintext.
-- Lets
-- MC_Server gate radio/hands/bubble-style on modality without reaching
-- into MC_LangRegistry itself -- same encapsulation as every other
-- language-state read MC_Server does through this module.
--
function MC_Lang.isSignedLanguage(language)
    if type(language) ~= "string" or language == "english" then return false end
    return MC_LangRegistry.getModality(language) == "signed"
end

-- A non-English utterance is routable only while its actual palette payload is
-- present. Kept separate from isSignedLanguage: missing payload is an outage,
-- not a change of modality. MC_Server checks this before hands, logging, sound,
-- proximity, or radio routing, including when LanguagesEnabled=false.
function MC_Lang.isLanguageRuntimeAvailable(language)
    if type(language) ~= "string" or language == "" then return false end
    language = language:lower()
    if language == "english" then return true end
    return MC_LangRegistry.getPalette(language) ~= nil
end

-- True when a signed palette remains selected while its operator toggle is
-- off. The server blocks the utterance with feedback until the player changes
-- language; it never sends the line through a spoken or clean-text path.
function MC_Lang.isDormantSigned(language)
    if not MC_Lang.isSignedLanguage(language) then return false end
    return language == "asl"
        and MC_Config.liveSandbox("ASLEnabled", false) == false
end

-- LANGUAGE STORAGE
-- Written on every change via MC_Persist A/B slots
-- (MongooseChat/MC_Languages_a.txt / MC_Languages_b.txt in ~/Zomboid/Lua/).
-- The whole map fits in memory
-- comfortably; we don't need delta writes.

-- LANGUAGE STORAGE (v8.4 schema v2)
-- 
-- Per-user record:
--   {
--     speaking = "<language>",     -- current /lang setting (the language they
--                                  -- are actively speaking right now; defaults
--                                  -- to nil/english if not set)
--     native   = { <lang> = true } -- the set of languages they natively know
--                                  -- (admin-granted). English is IMPLICIT -
--                                  -- never stored, always true.
--   }
-- 
-- Persisted via MC_Persist A/B slots
-- (~/Zomboid/Lua/MongooseChat/MC_Languages_a.txt / MC_Languages_b.txt);
-- the pre-A/B single file MC_Languages.json remains
-- on disk as a read-only migration fallback.
-- 
-- MIGRATION FROM v1 (v8.3 and earlier):
--   Old schema: { "languages": { "username": "french" } } -- a flat
--   username -> speaking-language map. Anyone could /lang anything; everyone
--   was treated as fluent in whatever they had set. Under v8.4 that's the
--   bug the data-model split closes: speaking and native are different.
-- 
--   The loader detects v1 by the absence of a "version" field. It migrates
--   each old entry to { speaking = <oldLang>, native = {} } -- preserving
--   the user's chosen speaking language but NOT granting them native status.
--   They become learners of that language; the system will render their
--   speech via the production pass (broken until they acquire vocabulary).
--   Admins can grant native via `/lang grant` if a character's backstory
--   warrants it.
-- 
--   Live-server impact: previously-set /lang choices stay but speakers no
--   longer sound fluent until granted native. Document loudly in CHANGELOG.

local SAVE_FILE = "MC_Languages.json"  -- legacy pre-A/B single file (read-only)
local SCHEMA_VERSION = 2

local function isDenseStringList(value)
    if type(value) ~= "table" then return false end
    local count, highest = 0, 0
    for key, item in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0
            or type(item) ~= "string" or item == "" then
            return false
        end
        count = count + 1
        if key > highest then highest = key end
    end
    return count == highest
end

-- Validation runs before MC_Persist chooses the highest generation. A newer
-- envelope with a missing/unknown schema must never outrank an older complete
-- slot and quietly become an empty language identity.
local function validateLanguagePayload(data)
    if type(data) ~= "table" then return false end

    -- Supported pre-v2 migration shape.
    if data.version == nil then
        if type(data.languages) ~= "table" or data.users ~= nil then
            return false
        end
        for username, language in pairs(data.languages) do
            if type(username) ~= "string" or username == ""
                or type(language) ~= "string" or language == "" then
                return false
            end
        end
        return true
    end

    if data.version ~= SCHEMA_VERSION or type(data.users) ~= "table" then
        return false
    end
    for username, rec in pairs(data.users) do
        if type(username) ~= "string" or username == ""
            or type(rec) ~= "table"
            or (rec.speaking ~= nil and type(rec.speaking) ~= "string")
            or (rec.previousSpeaking ~= nil
                and type(rec.previousSpeaking) ~= "string")
            or not isDenseStringList(rec.native) then
            return false
        end
    end
    return true
end
MC_Lang._validatePersistencePayload = validateLanguagePayload

-- A/B crash-safe store
-- (slots: MongooseChat/MC_Languages_a.txt / MC_Languages_b.txt).
-- The legacy single file is the migration fallback and is never written again.
-- See MC_Persist.lua for the crash-safety rationale.
local store = MC_Persist.open({
    name       = "MC_Languages",
    legacyFile = SAVE_FILE,
    validate   = validateLanguagePayload,
})

local MC_LangDB = {
    version = SCHEMA_VERSION,
    users = {},   -- username -> { speaking = <str|nil>, native = { <lang> = true, ... } }
}
local languageStorageHealthy = true
local languageStorageInitialized = false

-- Ensure a user record exists; returns it. Idempotent.
local function getOrCreateUserRecord(username)
    if not username then return nil end
    local rec = MC_LangDB.users[username]
    if not rec then
        rec = { speaking = nil, native = {}, previousSpeaking = nil }
        MC_LangDB.users[username] = rec
    end
    return rec
end

local function saveLanguagesToDisk()
    -- Convert in-memory shape to JSON-friendly shape (sets -> sorted lists).
    -- store:save() is internally pcall-wrapped, read-back verified, and
    -- warns loudly on failure.
    local out = { version = SCHEMA_VERSION, users = {} }
    for username, rec in pairs(MC_LangDB.users) do
        local nativeList = {}
        for lang, present in pairs(rec.native or {}) do
            if present then nativeList[#nativeList + 1] = lang end
        end
        table.sort(nativeList)
        out.users[username] = {
            speaking = rec.speaking,  -- nil is encoded as null
            native   = nativeList,
            previousSpeaking = rec.previousSpeaking,  -- E3 /ll toggle; nil is encoded as null
        }
    end
    if not store:save(out) then
        MC_Incident.report("LANG_PERSIST_SAVE_FAILED",
            "MC_Languages write/verify failed; in-memory rollback applied, disk outcome uncertain")
        return false
    end
    return true
end

local function loadLanguagesFromDisk()
    -- store:load() handles slot selection, corruption recovery, and the
    -- legacy single-file migration fallback (which is where pre-A/B and
    -- v1-schema files arrive from). Returns the raw payload; all schema
    -- interpretation stays here.
    local parsed, source = store:load()
    if source == "unavailable" then
        MC_Incident.report("LANG_PERSIST_UNAVAILABLE",
            "no recoverable language store; language traffic will remain opaque")
        return nil, false
    end
    if not parsed then
        return { version = SCHEMA_VERSION, users = {} }, true
    end

    -- v1 (pre-v8.4) detection: had `languages` map at the top, no version.
    if parsed.languages and not parsed.version then
        dbg("loadLanguagesFromDisk: migrating v1 schema (%d entries) -> v2",
            (function() local n = 0; for _ in pairs(parsed.languages) do n = n + 1 end; return n end)())
        local migrated = { version = SCHEMA_VERSION, users = {} }
        for username, lang in pairs(parsed.languages) do
            migrated.users[username] = {
                speaking = (lang ~= "english") and lang or nil,
                native = {},  -- empty: migration preserves speaking choice but
                              -- not native status -- admins must grant.
            }
        end
        return migrated, true
    end

    -- Only exact v2 reaches here: validateLanguagePayload rejects unknown
    -- versions and incomplete nested records before slot selection.
    if parsed.version ~= SCHEMA_VERSION or type(parsed.users) ~= "table" then
        MC_Incident.report("LANG_PERSIST_UNAVAILABLE",
            "unsupported language schema escaped validation")
        return nil, false
    end
    -- Convert the on-disk native list back to a set for in-memory use.
    for _, rec in pairs(parsed.users) do
        local set = {}
        if type(rec.native) == "table" then
            for _, lang in ipairs(rec.native) do
                if type(lang) == "string" then set[lang:lower()] = true end
            end
        end
        rec.native = set
        if type(rec.speaking) == "string" then
            rec.speaking = rec.speaking:lower()
            if not MC_LangRegistry.isKnownLanguage(rec.speaking) then
                -- Preserve the orphan key for admin diagnosis, but make the
                -- broken state loud. The render path treats it as opaque.
                MC_Incident.report("LANG_STATE_ORPHANED",
                    "active language=" .. tostring(rec.speaking))
            end
        else
            rec.speaking = nil
        end
        if type(rec.previousSpeaking) == "string" then
            rec.previousSpeaking = rec.previousSpeaking:lower()
            if not MC_LangRegistry.isKnownLanguage(rec.previousSpeaking) then
                MC_Incident.report("LANG_STATE_ORPHANED",
                    "previous language=" .. tostring(rec.previousSpeaking))
            end
        else
            rec.previousSpeaking = nil
        end
        for lang in pairs(rec.native) do
            if not MC_LangRegistry.isKnownLanguage(lang) then
                MC_Incident.report("LANG_STATE_ORPHANED",
                    "native language=" .. tostring(lang))
            end
        end
    end
    parsed.version = SCHEMA_VERSION
    return parsed, true
end

local function initLangStorage()
    if languageStorageInitialized then
        return languageStorageHealthy
    end
    local ok, loaded, healthy = pcall(loadLanguagesFromDisk)
    if not ok then
        MC_Incident.report("LANG_PERSIST_UNAVAILABLE",
            "language loader failed; language traffic will remain opaque")
        loaded, healthy = nil, false
    end
    languageStorageHealthy = healthy == true
    MC_LangDB = loaded or { version = SCHEMA_VERSION, users = {} }
    languageStorageInitialized = true
    local users, withSpeaking, withNative = 0, 0, 0
    for _, rec in pairs(MC_LangDB.users) do
        users = users + 1
        if rec.speaking then withSpeaking = withSpeaking + 1 end
        for _ in pairs(rec.native) do withNative = withNative + 1; break end
    end
    dbg("initLangStorage: loaded %d users (%d with speaking set, %d with at least one native)",
        users, withSpeaking, withNative)
    return languageStorageHealthy
end

Events.OnServerStarted.Add(initLangStorage)

-- Server startup normally initializes storage before any command can run.
-- Keeping every public state accessor behind this idempotent guard also
-- prevents an early hook or test harness from attempting a save against an
-- unloaded A/B store (which MC_Persist intentionally refuses).
local function ensureLangStorage()
    if not languageStorageInitialized then
        initLangStorage()
    end
    return languageStorageHealthy
end

-- Objective-critical callers need to tell "empty" from "unreadable".
-- Accessors intentionally return opaque/baseline-shaped values so rendering
-- can fail closed, but reset policy must not stamp completion on that shape.
function MC_Lang.isStorageAvailable()
    return ensureLangStorage() == true
end

-- LANGUAGE QUERY / SET

-- Returns the user's current SPEAKING language (the one their messages are
-- being produced in). Defaults to "english" -- the universal baseline.
function MC_Lang.getLanguage(username)
    if not ensureLangStorage() then
        MC_Incident.report("LANG_PERSIST_UNAVAILABLE",
            "active language cannot be trusted")
        return "__storage_unavailable__"
    end
    if not username then return "english" end
    local rec = MC_LangDB.users[username]
    local language = (rec and rec.speaking) or "english"
    if language ~= "english" and not MC_LangRegistry.isKnownLanguage(language) then
        MC_Incident.report("LANG_PALETTE_UNAVAILABLE",
            "active language=" .. tostring(language))
    end
    return language
end

-- Set the user's speaking language. Anyone can attempt any registered
-- language (the production pass will render the result as broken for
-- non-natives -- see render path). Returns true on success.
--
-- E3 (/ll toggle, 2026-07-08): whenever the language ACTUALLY changes, the
-- language being left behind is remembered as "previous" -- the alt-tab
-- /ll switches back to reads this. A redundant set (already speaking the
-- language requested) does not disturb it: repeating "/lang french" while
-- already French must not blow away a real previous language with a no-op.
function MC_Lang.setLanguage(username, language)
    if not ensureLangStorage() then return false end
    if not username or type(language) ~= "string" then return false end
    language = language:lower()
    if not MC_LangRegistry.isKnownLanguage(language) then return false end
    local rec = MC_LangDB.users[username]
    local oldLang = (rec and rec.speaking) or "english"
    if oldLang == language then return true end

    local hadRecord = rec ~= nil
    rec = rec or getOrCreateUserRecord(username)
    local oldSpeaking = rec.speaking
    local oldPrevious = rec.previousSpeaking
    if language == "english" then
        -- English baseline: clearing the speaking field IS "speaking english".
        rec.speaking = nil
    else
        rec.speaking = language
    end
    rec.previousSpeaking = oldLang
    if not saveLanguagesToDisk() then
        if hadRecord then
            rec.speaking = oldSpeaking
            rec.previousSpeaking = oldPrevious
        else
            MC_LangDB.users[username] = nil
        end
        return false
    end
    return true
end

-- Returns the language the user was speaking immediately before their
-- CURRENT one, or nil if no real switch has happened yet (fresh character,
-- or every setLanguage call so far was a no-op re-set of the same
-- language). E3's /ll toggle reads this to switch back.
function MC_Lang.getPreviousLanguage(username)
    if not ensureLangStorage() then return nil end
    if not username then return nil end
    local rec = MC_LangDB.users[username]
    return rec and rec.previousSpeaking or nil
end

-- True iff `language` may currently be picked as a speaking language at
-- all -- the exact gate MC_LangCommands.handleSetCommand enforces before
-- calling MC_Lang.setLanguage: registered in MC_LangRegistry, and (ASL
-- specifically) not live-disabled via the ASLEnabled sandbox toggle.
-- Single-sourced so the one-shot "@<language>" prefix (E2 ergonomics) and
-- /ll's toggle-back both apply the IDENTICAL rule /lang set already does,
-- rather than growing their own copy that could drift from it.
function MC_Lang.isSelectableLanguage(language)
    if type(language) ~= "string" then return false end
    language = language:lower()
    if not MC_LangRegistry.isKnownLanguage(language) then return false end
    if language == "asl"
        and MC_Config.liveSandbox("ASLEnabled", false) == false then
        return false
    end
    return true
end

-- Returns true if the user natively knows the given language. English is
-- ALWAYS native for everyone -- the universal baseline. Other languages
-- require an admin grant via grantNative().
function MC_Lang.isNative(username, language)
    if not ensureLangStorage() then return false end
    if not username or type(language) ~= "string" then return false end
    language = language:lower()
    if language == "english" then return true end
    local rec = MC_LangDB.users[username]
    if not rec then return false end
    return rec.native[language] == true
end

-- Returns a sorted list of languages the user natively knows. Always
-- includes "english" as the first entry (universal baseline).
function MC_Lang.getNativeLanguages(username)
    local list = { "english" }
    if not ensureLangStorage() then return list end
    if not username then return list end
    local rec = MC_LangDB.users[username]
    if not rec then return list end
    local extras = {}
    for lang in pairs(rec.native) do extras[#extras + 1] = lang end
    table.sort(extras)
    for _, lang in ipairs(extras) do list[#list + 1] = lang end
    return list
end

-- Grant native status on a language to a user. Admin operation -- gating
-- happens at the command layer. Returns (ok, alreadyGranted).
function MC_Lang.grantNative(username, language)
    if not ensureLangStorage() then return false, false end
    if not username or type(language) ~= "string" then return false, false end
    language = language:lower()
    if language == "english" then
        -- English is implicit; granting is a no-op success.
        return true, true
    end
    if not MC_LangRegistry.isKnownLanguage(language) then return false, false end
    local hadRecord = MC_LangDB.users[username] ~= nil
    local rec = getOrCreateUserRecord(username)
    local alreadyHad = rec.native[language] == true
    rec.native[language] = true
    if not alreadyHad and not saveLanguagesToDisk() then
        if hadRecord then
            rec.native[language] = nil
        else
            MC_LangDB.users[username] = nil
        end
        return false, false
    end
    return true, alreadyHad
end

-- Revoke native status. Admin operation. Returns (ok, hadIt). English
-- cannot be revoked -- it's the universal baseline.
function MC_Lang.revokeNative(username, language)
    if not ensureLangStorage() then return false, false end
    if not username or type(language) ~= "string" then return false, false end
    language = language:lower()
    if language == "english" then
        return false, false  -- english is not revocable
    end
    if not MC_LangRegistry.isKnownLanguage(language) then return false, false end
    local rec = MC_LangDB.users[username]
    if not rec then return true, false end
    local hadIt = rec.native[language] == true
    if hadIt then
        rec.native[language] = nil
        if not saveLanguagesToDisk() then
            rec.native[language] = true
            return false, false
        end
    end
    return true, hadIt
end

-- Wipe a user's language identity in one save. The command layer composes
-- this with MC_Acquisition.forgetUserPersisted. Returns a summary:
--   { speaking = <lang|nil>, previousSpeaking = <lang|nil>,
--     natives = { <lang>, ... } (sorted) }
function MC_Lang.resetUser(username)
    local summary = {
        speaking = nil, previousSpeaking = nil, natives = {}, ok = true,
    }
    if not ensureLangStorage() then
        summary.ok = false
        return summary
    end
    if not username then return summary end
    local rec = MC_LangDB.users[username]
    if not rec then return summary end
    summary.speaking = rec.speaking
    summary.previousSpeaking = rec.previousSpeaking
    for lang in pairs(rec.native or {}) do
        summary.natives[#summary.natives + 1] = lang
    end
    table.sort(summary.natives)
    if summary.speaking or summary.previousSpeaking
        or #summary.natives > 0 then
        MC_LangDB.users[username] = nil
        if not saveLanguagesToDisk() then
            MC_LangDB.users[username] = rec
            summary.ok = false
        end
    else
        -- Record existed but held nothing; drop it without a disk write.
        MC_LangDB.users[username] = nil
    end
    return summary
end

-- ORPHANED NATIVES (2026-07-08)
--
-- A native-language grant is a durable key
-- (MongooseChat/MC_Languages_a/b.txt) written
-- once and never revalidated -- if a palette is later renamed or removed
-- from the registry, a character can keep carrying the old key forever.
-- MC_LangRegistry.displayName already marks an orphaned key honestly
-- wherever it's shown (never silently dropped, never crashed on); these
-- two are the read/write pair for the deliberate admin cleanup act
-- (/lang prune) -- the surgical alternative to /lang reset's composite
-- wipe, which clears orphans too but only as a side effect of clearing
-- EVERYTHING (speaking choice, every other native grant, all acquired
-- vocabulary). Display never deletes on its own; only this, called from
-- an explicit confirmed admin command, does.

-- Sorted list of native-language keys the user holds that are no longer
-- registered (MC_LangRegistry.isKnownLanguage). Read-only -- names exactly
-- what a prune would remove, for the preview.
function MC_Lang.getOrphanedNatives(username)
    local orphans = {}
    if not ensureLangStorage() then return orphans end
    if not username then return orphans end
    local rec = MC_LangDB.users[username]
    if not rec then return orphans end
    for lang in pairs(rec.native or {}) do
        if not MC_LangRegistry.isKnownLanguage(lang) then
            orphans[#orphans + 1] = lang
        end
    end
    table.sort(orphans)
    return orphans
end

-- Removes ONLY the orphaned native keys from a user's native grants --
-- speaking choice, every native grant that's still a real registered
-- language, and all acquired vocabulary are left exactly as they were. A
-- no-op (no save) if nothing is orphaned or the user has no record.
-- Returns the sorted list of pruned language keys.
function MC_Lang.pruneOrphanedNatives(username)
    if not ensureLangStorage() then return {}, false end
    local pruned = MC_Lang.getOrphanedNatives(username)
    if #pruned == 0 then return pruned, true end
    local rec = MC_LangDB.users[username]
    for _, lang in ipairs(pruned) do
        rec.native[lang] = nil
    end
    if not saveLanguagesToDisk() then
        for _, lang in ipairs(pruned) do rec.native[lang] = true end
        return {}, false
    end
    return pruned, true
end

-- Internal contract: the /lang list command handler needs to enumerate
-- every username carrying language state directly (there's no per-user
-- accessor for "all users"). MC_LangDB is reassigned wholesale on server
-- start (see initLangStorage above), so this has to be a function -- a
-- captured table reference taken here would go stale after that
-- reassignment.
function MC_Lang._langDBUsers()
    ensureLangStorage()
    return MC_LangDB.users
end

-- BLEED-THROUGH SET
-- 
-- Pure unconditional exclamations + capitalized roster names -> these tokens
-- pass through the language barrier as English. Everything else babbles.
-- 
-- The engine's classify does a flat lowercase lookup, so the set is just
-- lowercase strings. Capitalization gating for names happens here: we only
-- add a name to the set if it appears capitalized in *this* message.

local EXCLAMATIONS_UNCONDITIONAL = {
    ["ah"]   = true, ["oh"]   = true, ["ugh"]  = true, ["hmm"]  = true,
    ["huh"]  = true, ["ow"]   = true, ["eh"]   = true, ["whoa"] = true,
    ["pfft"] = true, ["mm"]   = true, ["tch"]  = true, ["argh"] = true,
}

-- One roster pass giving every online player's (player, username, forename,
-- surname) record via the same safe accessors -- the shape buildRoster,
-- playerByUsername, resolveTargetByName, and handleListCommand each
-- used to walk separately.
-- Internal contract: MC_LangCommands' resolveTargetByName and
-- handleListCommand consume this directly rather than re-walking the roster.
local function onlinePlayerRecords()
    local records = {}
    local onlinePlayers = getOnlinePlayers()
    if not onlinePlayers then return records end
    for i = 0, onlinePlayers:size() - 1 do
        local p = onlinePlayers:get(i)
        local username = MC_Core.safe(function() return p:getUsername() end, nil)
        local forename, surname
        MC_Core.safe(function()
            local desc = p:getDescriptor()
            if not desc then return end
            forename = desc:getForename()
            surname = desc:getSurname()
        end, nil)
        records[#records + 1] = {
            player = p, username = username,
            forename = forename, surname = surname,
        }
    end
    return records
end
MC_Lang._onlinePlayerRecords = onlinePlayerRecords

-- Build the set of forenames present on the server right now. Lowercased
-- for matching. Forenames are what people say in IC chat ("Pierre" not
-- "Pierre Dubois"); the tokenizer splits multi-word names anyway.
local function buildRoster()
    local roster = {}
    for _, rec in ipairs(onlinePlayerRecords()) do
        if rec.forename and rec.forename ~= "" then
            roster[rec.forename:lower()] = true
        end
    end
    return roster
end

--- Build the bleed-through set for a single message.
-- @param message string
-- @return table { ["word"] = true, ... }
local function buildBleedThrough(message)
    local set = {}
    -- Unconditional exclamations: always bleed.
    for word, _ in pairs(EXCLAMATIONS_UNCONDITIONAL) do
        set[word] = true
    end
    
    -- Names: only added when a capitalized form appears in this message AND
    -- the name is on the server roster. The lowercase form goes in the set;
    -- the engine's lookup is case-insensitive at the token level.
    if not message or message == "" then return set end
    local roster = buildRoster()
    -- Kahlua doesn't expose global `next`, so `next(roster) == nil` would
    -- crash with "Object tried to call nil". Use MC_Core.isEmpty instead.
    if MC_Core.isEmpty(roster) then return set end
    
    for word in message:gmatch("[%w']+") do
        local first = word:sub(1, 1)
        -- "is uppercase letter" check that won't match digits or symbols
        if first:upper() == first and first:lower() ~= first then
            local lower = word:lower()
            if roster[lower] then
                set[lower] = true
            end
        end
    end
    
    return set
end

-- SEED
-- 
-- Composed from speaker username + message bytes + timestamp. Username in
-- the mix gives per-speaker voice -- each speaker's rng walks a different
-- path through the palette, biasing toward their own signature combinations
-- within the same language. Message bytes give per-utterance variation.
-- Timestamp gives utterance uniqueness across rapid repeats.

local function buildSeed(speakerUsername, message, timestamp, accentTint)
    local seed = 1
    if speakerUsername then
        for i = 1, #speakerUsername do
            seed = (seed * 31 + speakerUsername:byte(i)) % 2147483647
        end
    end
    if message then
        for i = 1, #message do
            seed = (seed * 17 + message:byte(i)) % 2147483647
        end
    end
    seed = (seed + (timestamp or 0)) % 2147483647
    -- Accent tint: a per-listener phonetic phase keyed on the receiver's L1
    -- family vs the speaker's L2 family (resolved in MC_Acquisition). It shifts
    -- which babble variant surfaces, colouring the word by the listener's
    -- native frame. Defaults to 0 -> seed unchanged -> identical babble, so this
    -- stays a no-op until the ACCENT_TINT table is tuned for varied L1s.
    if accentTint and accentTint ~= 0 then
        seed = (seed + math.floor(accentTint * 1000003)) % 2147483647
    end
    if seed == 0 then seed = 1 end
    return seed
end

-- DICTIONARY BLEED + L1 REINFORCEMENT
--
-- Two passes wrap the babble engine:
--
--   Pre-engine: applyLexSubstitution walks the working text. Each
--   English token is resolved through MC_Resolve.resolve(token, palette),
--   which consults MC_Concepts to find the concept(s) the token represents
--   and then looks them up (with parent-walk fallback) in palette.lex. If
--   resolved, the L2 form replaces the token in place. The L2 forms are
--   added to bleedThrough so the engine leaves them alone, and reverse-
--   looked-up against palette.zipf for frequency rank. A lexSubs map
--   (L2_lower -> {l1, l2, rank}) is returned to drive the post-engine
--   reinforcement pass.
--
--   Post-engine: applyL1Reinforcement walks the babbled text. For each L2
--   token present in lexSubs, it queries MC_Acquisition.comprehensionProb
--   for the receiver. Above threshold -> token is rewritten "L1 (L2)" with
--   the receiver's L1 cap-style preserved. Below threshold -> token stays as
--   L2 (clean bleed). The acquisition record drives whether the bracket
--   appears, not the substitution itself.
--
-- Engine independence preserved: MC_Babble never reads dictionary/zipf;
-- those are integration-layer fields on the palette.

-- Preserve original cap-style when reinforcing "Water (eau)" vs "water (eau)".
-- Heuristics: ALL CAPS in -> ALL CAPS L1 + lower L2; First-cap in -> First-cap L1;
-- else lowercase. (L2 inside the bracket stays lowercase by convention.)
local function applyCapStyle(l1Word, originalToken)
    if not originalToken or originalToken == "" then return l1Word end
    if originalToken == originalToken:upper() and originalToken ~= originalToken:lower() then
        return l1Word:upper()
    end
    local first = originalToken:sub(1, 1)
    if first == first:upper() and first ~= first:lower() then
        return l1Word:sub(1, 1):upper() .. l1Word:sub(2):lower()
    end
    return l1Word:lower()
end

-- Build a reverse-lookup table from palette.zipf so we can score an L2 form's
-- frequency rank in O(1). Per-palette and cached lazily on the palette table
-- itself (mutation of a single derived field is fine; the engine never reads it).
local function getZipfRankMap(palette)
    if not palette then return nil end
    if palette._zipfRankMap then return palette._zipfRankMap end
    if not palette.zipf then
        palette._zipfRankMap = {}
        return palette._zipfRankMap
    end
    local map = {}
    for i, form in ipairs(palette.zipf) do
        -- Conflated concepts can list the same form at two ranks; keep the
        -- MINIMUM (first hit -- ipairs walks in rank order) so a common
        -- survival word isn't demoted to its rare conflation-partner's band.
        local key = form:lower()
        if map[key] == nil then map[key] = i end
    end
    palette._zipfRankMap = map
    return map
end

-- reverse-lex (l2_lower -> conceptId) is delegated to MC_Resolve.
-- The cache lives on the palette table itself (`_reverseLex`); see
-- MC_Resolve.reverseLex. Callers that previously asked "what's the L1
-- for this L2 form?" now ask "what concept does this L2 form lexicalize?"
-- and use MC_Concepts to recover an English alias if needed.
local function getReverseLex(palette)
    return MC_Resolve.reverseLex(palette)
end

-- Internal contract: consumed throughout MC_LangCommands, so a word's
-- frequency rank and concept resolution match between what a player hears
-- and what /lex reports.
MC_Lang._getZipfRankMap = getZipfRankMap
MC_Lang._getReverseLex = getReverseLex

-- Walk the working text token-by-token. For each word, resolve through
-- MC_Concepts/MC_Resolve to find the palette's lexicalization. If the
-- token resolves (direct or via parent-walk fallback), substitute the
-- L2 form in place and record the substitution. Punctuation and inter-
-- word whitespace are preserved.
-- Returns (newWorking, lexSubs) where lexSubs[L2_lower] = {l1, l2, rank}.
local function applyLexSubstitution(working, palette)
    local lexSubs = {}
    if not working or working == "" or not palette or not palette.lex then
        return working, lexSubs
    end
    local rankMap = getZipfRankMap(palette)

    -- gsub callback approach: %w+ catches word runs (including digits, which
    -- harmlessly won't match concept aliases). Apostrophes inside words
    -- aren't preserved by %w; currently that's acceptable since palette
    -- lex forms have no apostrophe entries. Future revisions can switch
    -- to [%w']+.
    local newWorking = working:gsub("%w+", function(token)
        local l2 = MC_Resolve.resolve(token, palette)
        if not l2 then return nil end  -- nil keeps the original match
        local l2Lower = l2:lower()
        -- First occurrence wins on cap style -- preserves the speaker's
        -- original styling for the reinforcement bracket.
        if not lexSubs[l2Lower] then
            lexSubs[l2Lower] = {
                l1 = token,        -- preserves speaker's original cap style
                l2 = l2,
                rank = rankMap and rankMap[l2Lower] or nil,
            }
        end
        return l2
    end)
    return newWorking, lexSubs
end

-- Walk a chunks array and apply MC_Sanitize.restore to each chunk's text in
-- place. The flat-string sibling restore happens via MC_Sanitize.restore on
-- the assembled string; this is the chunk-aware sibling that keeps the
-- per-chunk render data in sync. Placeholders (MCBLEEDn) only ever land in
-- base-color chunks since they're not in any dictionary, so the soft-purple
-- L2 chunks pass through untouched.
local function restoreChunksInPlace(chunks, protectedBlocks, protectedOrder)
    if not chunks then return end
    for _, chunk in ipairs(chunks) do
        chunk.text = MC_Sanitize.restore(chunk.text, protectedBlocks, protectedOrder)
    end
end

-- applyL1Reinforcement
-- 
-- Walks the (already-babbled or hybrid) message and applies the L1 (L2)
-- bracket for any token whose comprehension probability has crossed the
-- acquisition threshold for this receiver.
-- 
-- Returns:
--   resultString  -- the flat rendered string (byte-identical to v8.4 for the
--                   same inputs, so existing string-level assertions pass)
--   chunks        -- array of { text, color } describing the per-token render,
--                   OR nil if no L2 substitution happened (in which case the
--                   caller can leave msgData.chunks unset and the client takes
--                   the flat-string path). Base segments use color = nil to
--                   signal "fall back to channel/tagColor" -- preserves the
--                   v8.4 channel-specific coloring (whisper grey, yell gold,
--                   etc.) for the non-L2 portions. L2 substitutions use the
--                   explicit MC_Core.Colors.SOFT_PURPLE. Alpha is left nil
--                   (= 1) at phase 1 -- phase 2 introduces sub-1 alpha for
--                   the partial-comprehension state.
-- Stable per-word seed for babble-resolve: keyed on the L2 form (NOT the
-- utterance) so a learner sees the SAME word sharpen consistently across
-- hearings, rather than re-rolling its noise each message.
local function wordSeed(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
    if h == 0 then h = 1 end
    return h
end

-- Misacquisition display swap: for any L2 token the receiver has
-- misacquired, replace the L1 alias in lexSubs with the wrong concept's
-- L1. This runs AFTER teaching/acquisition recording (which use the
-- correct concept) and BEFORE applyL1Reinforcement (which displays the
-- L1 to the player). Mutates lexSubs in place.
local function swapMisacquiredAliases(lexSubs, receiverUsername, sourceLang)
    if not lexSubs or not receiverUsername or not sourceLang then return end
    local Concepts = require("MC_Concepts")
    for _, sub in pairs(lexSubs) do
        local wrongConcept = MC_Acquisition.getMisacquisition(
            receiverUsername, sourceLang, sub.l2)
        if wrongConcept then
            local concept = Concepts.get(wrongConcept)
            if concept and concept.en and concept.en[1] then
                sub.l1 = concept.en[1]
            end
        end
    end
end

local function applyL1Reinforcement(babbled, lexSubs, receiverUsername, sourceLang, palette)
    if not babbled or babbled == "" then return babbled, nil end
    if not lexSubs or MC_Core.isEmpty(lexSubs) then return babbled, nil end
    if not receiverUsername then return babbled, nil end

    local stateFor = {}  -- per-receiver state cache for this render (per-l2)
    local hasL2 = false

    local FRESH    = MC_Core.Colors.ACQUIRED_FRESH
    local FAMILIAR = MC_Core.Colors.ACQUIRED_FAMILIAR

    local chunks = {}

    -- Append plain text as a base chunk (color = nil -> resolves to channel
    -- tagColor on the client). Coalesce with previous base chunk if possible.
    local function appendBase(text)
        if not text or text == "" then return end
        local last = chunks[#chunks]
        if last and last.color == nil and last.alpha == nil then
            last.text = last.text .. text
        else
            table.insert(chunks, { text = text })  -- color & alpha implicit nil
        end
    end

    -- v8.5 four-state painters. Each emits the appropriate chunk shape and
    -- (where applicable) the surrounding base text via appendBase.
    local function appendPartial(token, alpha)
        -- Anticipation: the L2 form bleeds through, painted in honey-gold at
        -- continuous low alpha. No bracket -- meaning hasn't landed yet.
        table.insert(chunks, { text = token, color = FRESH, alpha = alpha })
        hasL2 = true
    end

    local function appendFresh(l1Styled, l2, alpha)
        -- Reward: "L1 (L2)" with L2 in full-alpha honey-gold. The click moment
        -- and its immediate aftermath. v8.16.2: an acquired-but-decayed word
        -- keeps the bracket but dims with tokenState's clarity alpha.
        appendBase(l1Styled .. " (")
        table.insert(chunks, { text = l2, color = FRESH, alpha = alpha })
        appendBase(")")
        hasL2 = true
    end

    local function appendFamiliar(l1Styled, l2, alpha)
        -- Consolidation: "L1 (L2)" with L2 in soft-purple aside at reduced
        -- alpha. The word has settled in. v8.16.2: decayed clarity can dim
        -- below the 0.85 aside baseline, never above it.
        appendBase(l1Styled .. " (")
        table.insert(chunks, { text = l2, color = FAMILIAR, alpha = math.min(0.85, alpha or 1.0) })
        appendBase(")")
        hasL2 = true
    end

    -- Walk the message, segmenting at word boundaries. find() gives us the
    -- positional info gsub doesn't, so we can preserve the inter-word text
    -- (spaces, punctuation, sanitize placeholders like MCBLEED1) as base
    -- chunks rather than discarding it.
    local pos = 1
    local len = #babbled
    -- Static family head-start for this language/listener (constant per render).
    local familyCloseness = MC_Acquisition.familyClosenessForLang(sourceLang)
    while pos <= len do
        local wordStart, wordEnd, word = babbled:find("(%w+)", pos)
        if not wordStart then
            appendBase(babbled:sub(pos))
            break
        end

        -- Non-word text before this word
        if wordStart > pos then
            appendBase(babbled:sub(pos, wordStart - 1))
        end

        -- State decision for this word
        local lower = word:lower()
        local sub = lexSubs[lower]
        local handled = false

        if sub then
            local cached = stateFor[lower]
            if cached == nil then
                local exp = MC_Acquisition.getExposure(receiverUsername, sourceLang, sub.l2)
                local ts = MC_Acquisition.tokenState(exp, sub.rank, familyCloseness)
                -- Cache per-l2 along with the l1Styled form (so cap-style is
                -- decided once per render -- matches v8.4 behaviour where the
                -- first occurrence's capitalization wins for the bracket).
                cached = {
                    state    = ts.state,
                    alpha    = ts.alpha,
                    level    = ts.level,
                    l1Styled = applyCapStyle(sub.l1, word),
                    l2       = sub.l2,
                }
                stateFor[lower] = cached
            end

            if cached.state == "partial" then
                -- babble-resolve: the form resolves from noise toward clean as
                -- comprehension climbs (no gloss yet -- meaning hasn't landed).
                appendPartial(MC_Babble.resolveWord(word, palette, cached.level, nil, wordSeed(lower)), cached.alpha)
                handled = true
            elseif cached.state == "fresh" then
                appendFresh(cached.l1Styled, cached.l2, cached.alpha)
                handled = true
            elseif cached.state == "familiar" then
                appendFamiliar(cached.l1Styled, cached.l2, cached.alpha)
                handled = true
            end
            -- "none" state: theoretically never happens here because the
            -- caller has already run recordExposureBatch for this render,
            -- bumping count >= 1. Falls through to base append if it does.
        end

        if not handled then
            appendBase(word)
        end

        pos = wordEnd + 1
    end

    -- Assemble flat string from chunks. Partial state preserves the L2 form
    -- in the flat string (matches v8.4 -- the babble already had the L2 form
    -- via dictionary-bleed). Fresh/familiar add the "L1 (L2)" bracket as
    -- before. Net: flat-string output is byte-identical to v8.4 across all
    -- states; only chunk colour and alpha differ.
    local resultBuf = {}
    for _, c in ipairs(chunks) do
        table.insert(resultBuf, c.text)
    end
    local resultString = table.concat(resultBuf)

    if not hasL2 then
        return resultString, nil
    end

    return resultString, chunks
end

-- PER-RECEIVER RENDER
-- 
-- The core decision function called from MC_Server's proximity and radio
-- loops. Returns the rendered string and an optional language tag.
-- 
-- Returns:
--   (clean, nil)          English speaker -- universal baseline
--   (clean, "french")     Same-language listener -- comprehender + tag
--   (rendered, "french")  Different-language listener -- babbled with
--                         dictionary bleed + L1 reinforcement, tagged
--                         so listener knows what they're hearing
-- 
-- BEHAVIOUR CHANGE FROM v0.9: non-English speech is now tagged for ALL
-- listeners, not just same-language comprehenders. Rationale: the listener
-- should know *what language* they don't understand (you can hear that
-- someone is speaking French even if you don't speak it). Per the
-- the language-acquisition philosophy.

-- PRODUCTION PASS (v8.4)
-- 
-- For LEARNER speakers (not native in the language they're attempting): the
-- speaker types English; we substitute only the L2 forms they've actually
-- acquired. Everything else stays English. The result is a hybrid sentence
-- representing what they really said -- broken use of L2 vocabulary scattered
-- across English structure.
-- 
-- This is DIFFERENT from the native-speaker path: native speakers' English
-- text is a CONVENTION (it represents fluent L2). For natives we run the
-- babble engine on it for cross-language listeners. For learners, the
-- English is LITERAL -- they really used English words, mixed with L2
-- vocabulary where they knew it. No babble.
-- 
-- The same exposure counts that drive comprehension also drive production:
-- you can use the words you've heard. Comprehension and production scale
-- together.

-- Tiny self-contained deterministic LCG used for the v8.8 productive roll.
-- Same shape as MC_Babble.makeRng but inlined here so production-pass
-- rolls don't depend on a babble module symbol that might not be loaded
-- in some pure-pass test contexts. Two iterations for a workable
-- distribution; absolute statistical quality isn't required -- the roll
-- only needs to be deterministic on the inputs and well-spread across
-- (speaker, message, timestamp, word) tuples.
local function productiveRoll(seed)
    local s = math.floor(seed or 0) % 2147483648
    if s <= 0 then s = 1 end
    s = (s * 1103515245 + 12345) % 2147483648
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648  -- float in [0, 1)
end

-- Per-word seed: deterministic on (speaker, message, timestamp, l2Lower).
-- Mixed into a single integer via the same byte-mixer pattern buildSeed
-- uses for the babble engine. Same inputs -> same roll across receivers
-- and across replays of the same utterance.
local function buildProductiveSeed(speakerUsername, message, timestamp, l2Lower)
    local seed = 1
    if speakerUsername then
        for i = 1, #speakerUsername do
            seed = (seed * 31 + speakerUsername:byte(i)) % 2147483647
        end
    end
    if message then
        for i = 1, #message do
            seed = (seed * 17 + message:byte(i)) % 2147483647
        end
    end
    if timestamp then
        seed = (seed * 13 + math.floor(timestamp)) % 2147483647
    end
    if l2Lower then
        for i = 1, #l2Lower do
            seed = (seed * 7 + l2Lower:byte(i)) % 2147483647
        end
    end
    return seed
end

-- Reach-and-trail marker for the visible silent period: an in-lex word the
-- speaker cannot yet produce (unlearned, or learned-but-blanked this roll)
-- renders as the character reaching for it and trailing off, instead of
-- silently falling back to clean English. The density self-scales with
-- acquisition -- heavy early (deep silent period), sparse once fluent -- so no
-- threshold is needed. Single swappable glyph; confirm it in-client and adjust
-- if the chat font balks at the unicode.
local GROPING_MARKER = "\226\128\166-"

-- An ASL learner's fallback for a concept with no ASL gloss at all
-- (not "unacquired" -- genuinely not in the palette's lex) is fingerspelling,
-- not silently speaking English. Dash-joined letters, case preserved --
-- the real-world fallback signers actually use for words with no dedicated
-- sign. See tokenizeSigned below for the receiver-side legibility gate.
local function fingerspell(token)
    local letters = {}
    for i = 1, #token do
        letters[#letters + 1] = token:sub(i, i)
    end
    return table.concat(letters, "-")
end

local function applyProductionPass(message, palette, speakerUsername, sourceLang, timestamp)
    if not message or message == "" then return message end
    if not palette or not palette.lex then
        MC_Incident.report("LANG_PRODUCTION_UNAVAILABLE",
            "language=" .. tostring(sourceLang or "unknown") .. " palette/lex unavailable")
        return "..."
    end
    if not speakerUsername then
        MC_Incident.report("LANG_PRODUCTION_UNAVAILABLE",
            "language=" .. tostring(sourceLang or "unknown") .. " speaker identity unavailable")
        return "..."
    end

    -- v8.8: per-word roll cache. Each unique L2 token in this utterance
    -- gets exactly one roll; all occurrences share the result. Models the
    -- felt fact that a learner who knows a word uses it consistently
    -- within an utterance; one who blanks blanks every time.
    local rolls    = {}  -- l2Lower -> bool (did this word's roll succeed?)
    local recorded = {}  -- l2Lower -> bool (did we increment produced this message?)
    local rankMap = getZipfRankMap(palette)

    -- v8.16.1: hesitation filler on the first acquired-but-blanked word.
    -- A learner who knows a word but can't access it reaches for it in L2
    -- ("şey …—") before trailing off — the listener hears the speaker
    -- struggling in the target language, not seamlessly switching to English.
    -- Only the FIRST blank in a message gets a filler (you hesitate once,
    -- then just gap); the not-acquired path (below) gets no filler because
    -- a speaker who doesn't know the word at all can't hesitate in L2.
    -- Palette.fillers is optional; absent = no fillers (backward-compat).
    local fillers = palette.fillers
    local fillerEmitted = false

    return message:gsub("%w+", function(token)
        -- B2 fix: a sanitize/cultural sentinel (MCBLEED1, MCSAN1, ...) --
        -- including one fused onto real text ("noMCBLEED1") -- must never
        -- go through any signed transform. Fingerspelling it below
        -- (n-o-M-C-B-L-E-E-D-1) would destroy the exact substring
        -- MC_Sanitize.restore looks for, so the *emote*/**mood**/((OOC))
        -- region it was protecting never comes back -- it renders as
        -- mangled fingerspelling forever instead. Same "clean" check the
        -- render-side ladder already relies on for the identical reason
        -- (renderSignedBody, classify() == "clean"); applying it here too
        -- keeps the production pass and the render ladder consistent.
        if palette.modality == "signed"
           and MC_Babble.classify({ text = token, isWord = true }, nil) == "clean" then
            return nil
        end

        local l2 = MC_Resolve.resolve(token, palette)
        if not l2 then
            -- A signed learner fingerspells what a spoken learner
            -- would just say in English; everyone else's fallback is
            -- unchanged (spoken path untouched).
            if palette.modality == "signed" then return fingerspell(token) end
            return nil  -- not in concept-mapped lex -> stay English
        end

        local l2Lower = l2:lower()
        local exp = MC_Acquisition.getExposure(speakerUsername, sourceLang, l2Lower)
        if not exp or not exp.acquired then return GROPING_MARKER end  -- in-lex but not yet producible -> visible groping

        -- v8.8: roll per unique word, cached across occurrences.
        if rolls[l2Lower] == nil then
            -- v8.9: use the record-aware probability so failed-attempt
            -- credit (producedAttempts * ATTEMPT_CREDIT) contributes to
            -- effective produced count alongside successful productions.
            -- v8.9 Connection: dynamicContextBoost layers family + lexical-
            -- set bonuses on top of the record's stored contextBoost
            -- transiently for this roll. Same boosts that help acquisition
            -- also help production -- knowing Spanish helps you SAY Italian
            -- words, not just understand them.
            local dynBoost = MC_Acquisition.dynamicContextBoost(
                speakerUsername, sourceLang, l2Lower)
            local prob = MC_Acquisition.productiveProbForRecord(
                exp,
                rankMap and rankMap[l2Lower] or nil,
                dynBoost)
            local seed = buildProductiveSeed(speakerUsername, message, timestamp, l2Lower)
            local roll = productiveRoll(seed)
            rolls[l2Lower] = (roll < prob)
        end

        if not rolls[l2Lower] then
            -- Roll failed: the learner blanked on this word -- they know it but
            -- it won't come this time. Renders as visible groping (reach-and-
            -- trail), not the clean English word; the listener sees the
            -- struggle, no engine UI announcing it. v8.9: failed attempts are
            -- recorded -- they contribute fractional credit (ATTEMPT_CREDIT *
            -- producedAttempts) toward the productive curve via
            -- effectiveProduced. Real cognitive effort consolidates even when
            -- production blanks; only fully-successful productions reset the
            -- attempts counter.
            if not recorded[l2Lower] then
                MC_Acquisition.recordProductionAttempt(
                    speakerUsername, sourceLang, l2Lower)
                recorded[l2Lower] = true
            end
            -- v8.16.1: first blank gets an L2 hesitation filler; the rest
            -- are bare groping markers.
            if not fillerEmitted and fillers and #fillers > 0 then
                fillerEmitted = true
                local pick = ((timestamp or 0) % #fillers) + 1
                return fillers[pick] .. " " .. GROPING_MARKER
            end
            return GROPING_MARKER
        end

        -- Roll succeeded: substitute, and increment produced once per
        -- message (subsequent occurrences of the same word share the
        -- substitution but not the credit -- one utterance, one practice
        -- event for that word).
        if not recorded[l2Lower] then
            MC_Acquisition.recordProduction(speakerUsername, sourceLang, l2Lower)
            recorded[l2Lower] = true
        end
        return applyCapStyle(l2, token)
    end)
end

-- Identify L2 tokens already present in the working text (for the learner-
-- speaker comprehension pass). Returns lexSubs in the same shape the native
-- pipeline produces, so applyL1Reinforcement and recordExposureBatch can
-- consume it unchanged.
--
-- the reverse map goes l2_lower -> conceptId; we recover the L1 alias
-- from MC_Concepts (primary alias is concept.en[1]) and the L2 form from
-- the palette's lex entry. Shape of the returned lexSubs entry is
-- byte-identical to the pre-pivot form for downstream compatibility.
local function identifyL2TokensInWorking(working, palette)
    local lexSubs = {}
    if not working or working == "" or not palette or not palette.lex then
        return lexSubs
    end
    local reverse = getReverseLex(palette)
    local rankMap = getZipfRankMap(palette)
    if not reverse then return lexSubs end

    local Concepts = require("MC_Concepts")

    for token in working:gmatch("%w+") do
        local lower = token:lower()
        local conceptId = reverse[lower]
        if conceptId and not lexSubs[lower] then
            local concept = Concepts.get(conceptId)
            local lexEntry = palette.lex[conceptId]
            local l1 = (concept and concept.en and concept.en[1]) or token
            local l2 = (lexEntry and lexEntry.l2) or token
            lexSubs[lower] = {
                l1   = l1,
                l2   = l2,
                rank = rankMap and rankMap[lower] or nil,
            }
        end
    end
    return lexSubs
end

-- PER-RECEIVER RENDER (v8.4)
-- 
-- The render path now considers FOUR axes simultaneously:
--   - speaker's currentLang (what they /lang'd as)
--   - is speaker native in that language? (true -> fluent production)
--   - is listener native in that language? (true -> clean comprehension + tag)
--   - listener's acquisition state on that language (for non-natives)
-- 
-- Returns:
--   (clean, nil)                       English speaker (universal baseline)
--   (groundTruth, "french")             Listener is native of speakerLang
--                                       -- sees what was actually said
--   (babbled + reinforced, "french")    Native speaker, non-native listener
--   (hybrid + reinforced, "french")     Learner speaker, non-native listener

-- v8.16.1 "Voices" -- server-side delivery helpers for the social layer.

-- Declared here (rather than by the reset/forget/list handlers below that
-- are its main callers) because the lapse-notice sink, just below, needs
-- it too and runs first.
local function describeLang(lang)
    return MC_LangRegistry.displayName(lang)
end
-- Internal contract: consumed throughout MC_LangCommands.
MC_Lang._describeLang = describeLang

-- Username -> online player object. Bounded by online player count; called
-- only on teaching events and acquisition crossings, both rare.
local function playerByUsername(username)
    if not username then return nil end
    for _, rec in ipairs(onlinePlayerRecords()) do
        if rec.username == username then return rec.player end
    end
    return nil
end

-- Internal contract: the /lang resetall command handler (runResetAll)
-- needs the online player object for an exact-username target, to read
-- their forename for the preview/report lines -- the same lookup the
-- teacher-cue and acquisition-moment senders below use.
MC_Lang._playerByUsername = playerByUsername

-- Forename if the username is online and has one, else the username
-- itself. Internal contract: the grant/revoke command cores (MC_LangCommands
-- runGrantNative/runRevokeNative) use this for player-facing messages so a
-- resolved-by-forename target and a resolved-by-username target read the same.
local function displayNameForUsername(username)
    local p = playerByUsername(username)
    if not p then return username end
    return MC_Core.safe(function()
        local desc = p:getDescriptor()
        return desc and desc:getForename() or nil
    end, nil) or username
end
MC_Lang._displayNameForUsername = displayNameForUsername

-- Teacher's feedback: when a teaching event lands (receiver-heard gate
-- passed), the TEACHER gets one quiet cue -- the small human payoff of being
-- understood. The learner's side stays silent, exactly as the teaching
-- philosophy demands; this completes the two-player scene without touching
-- it. renderWithLangs runs once per receiver, so a lesson landing on several
-- listeners at once would cue several times -- dedup per (teacher, utterance
-- timestamp) keeps it to one cue per utterance.
-- v8.16.2: gated attempts cue too. Every teaching failure used to render
-- byte-identical to plain speech, so a first-session teacher concluded
-- teaching didn't exist. Cues are deduped per (teacher, utterance, line);
-- a failure line stays quiet once ANY line has already answered this
-- utterance (in a mixed crowd, a miss on a far listener shouldn't drown
-- out the landing), while a success line is never suppressed by an
-- earlier miss.
local teacherCueSent = {}
local teacherCueSentCount = 0
local function fireTeacherCue(teacherUsername, timestamp, cue, isFailure)
    if not teacherUsername or not cue then return end
    local utterKey = teacherUsername .. "|" .. tostring(timestamp or "?")
    local cueKey = utterKey .. "|" .. cue
    if teacherCueSent[cueKey] then return end
    if isFailure and teacherCueSent[utterKey] then return end
    if teacherCueSentCount > 256 then
        teacherCueSent = {}
        teacherCueSentCount = 0
    end
    teacherCueSent[utterKey] = true
    teacherCueSent[cueKey] = true
    teacherCueSentCount = teacherCueSentCount + 2
    local teacher = playerByUsername(teacherUsername)
    if not teacher then return end
    sendServerCommand(teacher, "MongooseChat", "SystemMessage", {
        message = cue,
        color = {150, 150, 150},
    })
end

-- Acquisition Moments: emit the crossing event to the listener's client,
-- payload shaped to the 8.17 spec (firstInLanguage, comprehension bands).
-- The client handler (ClientCommands.AcquisitionMoment) fires quiet,
-- immersive observations at the milestones (first word, 25/50/75% bands);
-- individual word acquisitions are carried by the per-word render bracket.
local function emitAcquisitionMoment(receiverUsername, sourceLang, newly, meta)
    if not newly or #newly == 0 then return end
    local receiver = playerByUsername(receiverUsername)
    if not receiver then return end
    sendServerCommand(receiver, "MongooseChat", "AcquisitionMoment", {
        language        = sourceLang,
        tokens          = newly,
        firstInLanguage = (meta and meta.firstInLanguage) or false,
        bands           = meta and meta.bands or nil,
        pct             = meta and meta.pct or nil,
        pctCore         = meta and meta.pctCore or nil,
    })
end

-- v8.16.1 -- exposure trace: rate-of-learning observability for testers.
-- Opt-in per user via /lex trace (self-serve under the test profile,
-- admin-only on live). One compact line per utterance showing exactly
-- what landed: applied weight (addressedness x saturation), running
-- count, crossings.
local traceUsers = {}
-- Internal contract: MC_LangCommands owns the player-facing toggle --
-- handleLexCommand's "/lex trace" branch flips a user's entry here, and
-- runResetAll drops a wiped username's entry. Exposed rather than
-- duplicating the table.
MC_Lang._traceUsers = traceUsers
MC_Acquisition.setExposureTraceSink(function(username, sourceLang, trace, addressed)
    if not traceUsers[username] then return end
    local receiver = playerByUsername(username)
    if not receiver then return end
    local bits = {}
    for i = 1, math.min(#trace, 8) do
        local t = trace[i]
        if t.crossed then
            bits[#bits + 1] = string.format("\226\152\133%s ACQUIRED(+%.2f\226\134\146%.4g)",
                t.token, t.weight, t.count)
        else
            bits[#bits + 1] = string.format("%s +%.2f\226\134\146%.4g",
                t.token, t.weight, t.count)
        end
    end
    if #trace > 8 then
        bits[#bits + 1] = string.format("+%d more", #trace - 8)
    end
    sendServerCommand(receiver, "MongooseChat", "SystemMessage", {
        message = string.format("[acq %s%s] %s",
            sourceLang,
            addressed == false and " overheard" or "",
            table.concat(bits, ", ")),
        color = {120, 180, 180},
    })
end)

-- v8.16.2 -- lapse notice: when decay takes the last of an acquired word
-- (count hits 0 and `acquired` flips off), MC_Acquisition routes one quiet
-- in-world line here. Rate-limiting (one per player per language per hour)
-- and pcall protection live on its side; an offline player is a silent
-- no-op.
MC_Acquisition.setLapseNoticeSink(function(username, lang)
    local receiver = playerByUsername(username)
    if not receiver then return end
    local displayLang = describeLang(lang)
    sendServerCommand(receiver, "MongooseChat", "SystemMessage", {
        message = "Your " .. displayLang .. " feels rusty.",
        color = {150, 150, 150},
    })
end)

-- Protected-sentinel patterns for MC_Babble.classify() (catches a
-- placeholder even fused to a word, e.g. "noMCBLEED1"): this module's own
-- MCBLEED format, MC_Cultural's exposed prefix, and MC_Sanitize's DEFAULT
-- key template ("MCSAN%d", mirrored as a literal -- another unit owns that
-- constant). Single-sourced so this list can't drift again; pinned by
-- test_lang_fused_emote.py.
local BLEED_SENTINEL = "MCBLEED"
MC_Babble.setProtectedSentinelPatterns({
    BLEED_SENTINEL:lower() .. "%d+",
    "mcsan%d+",
    MC_Cultural.SENTINEL_PREFIX:lower() .. "%d+",
})

-- Babble's blocklist guard is test-proven unreachable for the shipped
-- palettes; if a future palette ever exhausts it, the operator hears about
-- it (always-on, same rule as every failure boundary).
MC_Babble.setGuardExhaustedSink(function(_, paletteName, reason)
    MC_Incident.report("BABBLE_GUARD_EXHAUSTED",
        "palette=" .. tostring(paletteName) .. " reason=" .. tostring(reason or "unknown")
            .. " output redacted")
end)

-- v8.16.2: teaching-shape scan for the failure cue. MC_Teaching.detect
-- returns nil both for ordinary speech and for a teaching-shaped line whose
-- mapping is wrong ("Bread is called eau"); only the latter deserves a cue.
-- A line counts as wrong-mapping when a template matches AND the claimed L2
-- really is a dictionary word whose gloss doesn't match. Anchoring on the
-- dictionary keeps ordinary speech ("she is called Marie") silent -- an
-- unknown claimed word stays a silent detection miss.
local function detectWrongMapping(message, palette)
    if type(message) ~= "string" or message == "" then return false end
    if type(palette) ~= "table" then return false end
    -- Same pattern-resolution rule as MC_Teaching.detect (palette override,
    -- else defaults).
    local patterns = MC_Teaching.DEFAULT_PATTERNS
    if type(palette.teaching) == "table"
       and type(palette.teaching.patterns) == "table"
       and #palette.teaching.patterns > 0 then
        patterns = palette.teaching.patterns
    end
    local messageLower = message:lower()
    for _, p in ipairs(patterns) do
        if type(p) == "table" and type(p.pattern) == "string"
           and type(p.l1Group) == "number" and type(p.l2Group) == "number" then
            local pos = 1
            while pos <= #messageLower do
                local s, e, cap1, cap2 = messageLower:find(p.pattern, pos)
                if not s then break end
                if cap1 and cap2 and cap1 ~= "" and cap2 ~= "" then
                    local captures = { cap1, cap2 }
                    local l1Lower = captures[p.l1Group]
                    local l2Lower = captures[p.l2Group]
                    if l1Lower ~= l2Lower
                       and MC_Teaching.findL2InDictionary(palette, l2Lower)
                       and not MC_Teaching.l1MapsToL2(palette, l1Lower, l2Lower) then
                        return true
                    end
                end
                pos = e + 1
            end
        end
    end
    return false
end

-- PER-UTTERANCE EVALUATION (v8.16.2)
--
-- renderWithLangs runs once per RECEIVER, but teaching detection, the
-- speaker-eligibility gate, and the production pass are all facts about the
-- UTTERANCE. Before this cache the production pass re-ran per receiver, so
-- its recordProduction/recordProductionAttempt side effects banked once per
-- listener -- speaking near ten people earned tenfold practice credit
-- against the once-per-utterance contract (MC_Acquisition, ROLL-PER-WORD
-- SEMANTICS). Everything here is deterministic on (speaker, language,
-- message, timestamp), so caching is lossless; the cache also hands
-- MC_Lang.speakerEcho the same ground truth the receivers' renders consume.
--
-- ORDER NOTE (moved from the render path): detection and the speaker-gate
-- MUST run BEFORE the production pass. The production pass increments
-- `produced` as a side effect of L2 substitution; if it ran first, the
-- speaker-gate (hasProduced) would see the just-mutated state, and any
-- learner could teach a word on the same message they first produced it
-- in. The gate is meant to require PRIOR production (history of use in
-- normal speech) -- not production in the teaching utterance itself.
-- (Running both in here, once per utterance, also closes the old leak
-- where receiver #1's production pass mutated the state receiver #2's
-- gate then read.)
--
-- The detection also runs on the ORIGINAL typed message, not on
-- post-production output: production would have converted L1 -> L2 in
-- the slot positions and the circular-rejection in MC_Teaching.detect
-- would silently drop the event.
--
-- v8.16.2: the production pass runs on sanitize-PROTECTED text --
-- *emotes*, **moods** and ((OOC)) asides are literal writing, not speech,
-- so the speaker's L2 must never surface inside them (the native babble
-- path has always protected first; this mirrors it for learners).
--
-- Preview renders bypass the cache entirely (no cues, no cache writes) so
-- speculative inspection can't warm or poison live utterances.

local utterState = {}
local utterStateCount = 0
local function evalUtterance(palette, speakerLang, speakerIsNative,
                             speakerUsername, message, timestamp, preview)
    local key = nil
    if not preview then
        key = tostring(speakerUsername) .. "|" .. tostring(speakerLang)
            .. (speakerIsNative and "|n|" or "|l|")
            .. tostring(timestamp or "?") .. "|" .. message
        local cached = utterState[key]
        if cached then return cached end
        if utterStateCount > 64 then
            utterState = {}
            utterStateCount = 0
        end
    end

    local state = {}

    -- ---- TEACHING DETECTION (v8.7) ----
    -- Eligibility:
    --   - Native: trivially passes (owns the dictionary).
    --   - Learner: must have acquired AND produced the L2 token in PRIOR
    --     speech. The produced check is what gates the chain -- you pass
    --     on a word you've used, not a word you've only just heard.
    -- Per-message limit and dictionary validation are enforced inside
    -- MC_Teaching.detect. The receiver-heard gate is applied per-receiver
    -- (applyTeachingToReceiver), AFTER that receiver's exposure batch.
    -- v8.16.2: gated attempts cue the teacher quietly instead of failing
    -- silently; a line that matches no template stays silent.
    local teachingEvent = MC_Teaching.detect(message, palette)
    if teachingEvent then
        local speakerCanTeach = false
        if speakerIsNative then
            speakerCanTeach = true
        else
            speakerCanTeach = MC_Acquisition.hasProduced(
                speakerUsername, speakerLang, teachingEvent.l2Lower)
        end
        if not speakerCanTeach then
            teachingEvent = nil  -- rejection; renders as plain speech
            if not preview then
                fireTeacherCue(speakerUsername, timestamp,
                    "The word won't come.", true)
            end
        end
    elseif not preview and detectWrongMapping(message, palette) then
        fireTeacherCue(speakerUsername, timestamp,
            "That isn't the word for it.", true)
    end
    state.teachingEvent = teachingEvent

    -- ---- PRODUCTION: what did the speaker actually say? ----
    -- Native speakers type English as a CONVENTION for fluent L2 (the babble
    -- engine generates the phonetic surface for non-natives).
    -- Learner speakers type English LITERALLY and the production pass
    -- substitutes only the L2 forms they've acquired -- inside protected
    -- RP/OOC regions the text stays exactly as typed.
    if speakerIsNative then
        state.groundTruth = message
    else
        local working, blocks, order = MC_Sanitize.protect(
            message, { keyTemplate = BLEED_SENTINEL .. "%d" })
        working = applyProductionPass(
            working, palette, speakerUsername, speakerLang, timestamp)
        state.groundTruth = MC_Sanitize.restore(working, blocks, order)
    end

    if key then
        utterState[key] = state
        utterStateCount = utterStateCount + 1
    end
    return state
end

-- The per-receiver half of a teaching event: the receiver-heard gate and
-- the instant-acquisition grant. Runs AFTER this receiver's exposure batch
-- for the utterance, so hearing the word inside the teaching line itself
-- counts toward the gate. `newlyAcquired` is the batch's crossing list --
-- when the batch crossed the taught word on its own this very message, the
-- lesson still landed and the teacher deserves the cue.
local function applyTeachingToReceiver(receiverUsername, sourceLang, l2Lower,
                                       rank, speakerUsername, timestamp, newlyAcquired)
    local recvExp = MC_Acquisition.getExposure(receiverUsername, sourceLang, l2Lower)
    if recvExp and (recvExp.count or 0) >= 1 then
        local taught = MC_Acquisition.recordTeaching(
            receiverUsername, sourceLang, l2Lower, rank, speakerUsername)
        if not taught and newlyAcquired then
            for i = 1, #newlyAcquired do
                if newlyAcquired[i] == l2Lower then
                    taught = true
                    break
                end
            end
        end
        -- v8.16.1 "Voices": the teacher learns it landed. (Stays silent when
        -- the listener already knew the word -- nothing changed for them.)
        if taught then
            fireTeacherCue(speakerUsername, timestamp, "They seem to follow.", false)
        end
    else
        -- v8.16.2: the lesson missed -- the word hasn't registered on this
        -- listener even within the teaching line itself (overheard from too
        -- far away, or it never reached them). Quiet cue.
        fireTeacherCue(speakerUsername, timestamp, "They don't seem to follow.", true)
    end
end

-- ENGLISH-PATH TEACHING (v8.16.2)
--
-- "Water is called eau in French" IS an English sentence -- the docs' own
-- example -- but the English early-return in renderWithLangs used to skip
-- detection entirely, so the natural bilingual teaching register was a
-- silent no-op forever. Detection runs here against the palettes the
-- speaker is NATIVE in (the speaker-gate passes trivially for natives,
-- and only natives own enough of a language to teach it from inside
-- English). A non-native attempting a teaching line in English gets the
-- standard gated cue; learners teach by speaking the language itself.
--
-- Detection is receiver-independent, so it's evaluated once per utterance
-- and cached -- this sits on the DEFAULT path for most speakers.

local englishTeachCache = {}
local englishTeachCacheCount = 0
local function detectEnglishTeaching(speakerUsername, message, timestamp)
    local key = tostring(speakerUsername) .. "|" .. tostring(timestamp or "?")
        .. "|" .. message
    local hit = englishTeachCache[key]
    if hit ~= nil then
        if hit == false then return nil end
        return hit
    end
    if englishTeachCacheCount > 64 then
        englishTeachCache = {}
        englishTeachCacheCount = 0
    end
    englishTeachCacheCount = englishTeachCacheCount + 1

    local nativeSet = {}
    local found = nil
    for _, lang in ipairs(MC_Lang.getNativeLanguages(speakerUsername)) do
        if lang ~= "english" then
            nativeSet[lang] = true
            local palette = MC_LangRegistry.getPalette(lang)
            if palette and not found then
                local ev = MC_Teaching.detect(message, palette)
                if ev then
                    local rankMap = getZipfRankMap(palette)
                    found = {
                        lang  = lang,
                        event = ev,
                        rank  = rankMap and rankMap[ev.l2Lower] or nil,
                    }
                elseif detectWrongMapping(message, palette) then
                    fireTeacherCue(speakerUsername, timestamp,
                        "That isn't the word for it.", true)
                end
            end
        end
    end

    if not found then
        -- A teaching-shaped line in a language the speaker doesn't own gets
        -- the standard speaker-gate cue, once. Ordinary English stays
        -- silent (no palette's detect matches).
        for _, lang in ipairs(MC_LangRegistry.listLanguages()) do
            if lang ~= "english" and not nativeSet[lang] then
                local palette = MC_LangRegistry.getPalette(lang)
                if palette and MC_Teaching.detect(message, palette) then
                    fireTeacherCue(speakerUsername, timestamp,
                        "The word won't come.", true)
                    break
                end
            end
        end
    end

    englishTeachCache[key] = found or false
    return found
end

-- Per-receiver half of an English-path teach: mirror of the in-language
-- paths -- record the exposure (hearing the word inside the teaching line
-- is hearing it), then run the receiver-heard gate.
local function applyEnglishTeaching(speakerUsername, receiverUsername,
                                    message, timestamp, opts)
    if receiverUsername == speakerUsername then return end
    local teach = detectEnglishTeaching(speakerUsername, message, timestamp)
    if not teach then return end
    local ev = teach.event
    local newly, meta = MC_Acquisition.recordExposureBatch(
        receiverUsername, teach.lang,
        { { token = ev.l2Lower, rank = teach.rank } },
        nil, opts and opts.addressed, speakerUsername)
    emitAcquisitionMoment(receiverUsername, teach.lang, newly, meta)
    applyTeachingToReceiver(receiverUsername, teach.lang, ev.l2Lower,
        teach.rank, speakerUsername, timestamp, newly)
end

-- SIGNED MODALITY
--
-- ASL has no phonetic surface, so it doesn't run MC_Babble at all -- this
-- whole section is the signed counterpart of the dict-bleed/babble/
-- reinforcement machinery above, wired in as ONE branch at the render choke
-- (see renderWithLangs below). The spoken pipeline above is untouched.
--
-- Ladder (spec): fluent/native receiver sees clear text; a learner sees
-- acquired concepts as their gloss in the existing acquisition chunk
-- colors, everything else (including a concept they haven't acquired YET)
-- as a gesture-prose fragment; a total non-signer sees gesture-prose
-- throughout. Unlike spoken babble, an unacquired dictionary word does NOT
-- bleed through as its literal gloss -- watching a sign you don't know
-- looks like a gesture, not a legible written word, so there's no
-- "partial" phonetic-resolve state here; it's binary per word.

-- Recognizes one fingerspelled span starting at byte position i:
-- single letters joined by single dashes, e.g. "g-a-t-e". Each spelled
-- letter must stand alone (checked on both sides) so a genuine hyphenated
-- English word ("e-mail") never misparses as fingerspelling. Kahlua-safe:
-- no frontier patterns, no goto -- plain %a/%- matching only.
-- Returns the run's end position, or nil if there's no run starting at i.
local function fingerspellRunEndAt(text, i)
    if not text:sub(i, i):match("%a") then return nil end
    if i > 1 and text:sub(i - 1, i - 1):match("%a") then return nil end
    if text:sub(i + 1, i + 1):match("%a") then return nil end
    -- pos tracks the last CONSUMED letter's position; each iteration looks
    -- one "-<letter>" pair ahead and only commits (pos = pos + 2) once that
    -- letter is confirmed standalone too.
    local pos, count = i, 1
    while text:sub(pos + 1, pos + 1) == "-" and text:sub(pos + 2, pos + 2):match("%a")
          and not text:sub(pos + 3, pos + 3):match("%a") do
        pos = pos + 2
        count = count + 1
    end
    if count < 2 then return nil end
    return pos
end

-- Tokenizes signed working text into word / fingerspell / other runs.
-- Standalone, not MC_Babble.tokenize -- that has no fingerspell concept and
-- would shred a dash-joined run letter by letter.
local function tokenizeSigned(text)
    local tokens = {}
    local i, n = 1, #text
    while i <= n do
        local fsEnd = fingerspellRunEndAt(text, i)
        if fsEnd then
            tokens[#tokens + 1] = { text = text:sub(i, fsEnd), kind = "fingerspell" }
            i = fsEnd + 1
        else
            -- %w (letters+digits), matching MC_Babble.tokenize's own word-char
            -- contract -- NOT %a: a sanitize sentinel (MCBLEED1) or a fused
            -- placeholder (noMCBLEED1) must stay ONE token for classify()'s
            -- "mcbleed%d+" pattern to find it; splitting off the trailing
            -- digit would strand it unrecognized and gesture-prose the rest.
            local ws, we = text:find("^%w+", i)
            if ws then
                tokens[#tokens + 1] = { text = text:sub(ws, we), kind = "word" }
                i = we + 1
            else
                local os_, oe = text:find("^[^%w]+", i)
                tokens[#tokens + 1] = { text = text:sub(os_, oe), kind = "other" }
                i = oe + 1
            end
        end
    end
    return tokens
end
-- Internal contract: offline test coverage for the fingerspell-run scanner
-- (test_asl_render.py) reaches it here rather than re-deriving it.
MC_Lang._tokenizeSigned = tokenizeSigned

-- Deterministic gesture-prose fragment for one source word. Reuses the
-- module's existing productiveRoll/wordSeed primitives (same shape as
-- MC_Babble's own picker, inlined here per that function's own precedent)
-- rather than a new RNG -- stable per receiver, seeded on the utterance.
local function pickGesture(word, palette, uttSeed)
    local pool = palette.gestures
    if not pool or #pool == 0 then return word end
    local roll = productiveRoll(wordSeed(word:lower() .. "#" .. tostring(uttSeed)))
    local idx = math.floor(roll * #pool) + 1
    if idx > #pool then idx = #pool end
    return pool[idx]
end

-- Capped iconic leak. A word resolving to one of the palette's iconic
-- concepts carries a plain hint alongside its gesture-prose fragment.
local function iconicHintFor(word, palette)
    if not palette.iconic then return nil end
    local Concepts = require("MC_Concepts")
    local candidates = Concepts.byEnglish(word)
    if not candidates then return nil end
    for _, id in ipairs(candidates) do
        local hint = palette.iconic[id]
        if hint then return hint end
    end
    return nil
end

-- The signed comprehension ladder, applied per receiver. `working` is
-- already the speaker's actual production (clean English for a native,
-- production-pass output with acquired glosses/GROPING_MARKER/fingerspell
-- for a learner -- see evalUtterance, shared with the spoken path).
-- lexSubs (l2Lower -> {l1, l2, rank}) marks which tokens are concepts this
-- render can consider for the acquired-gloss bracket.
-- Returns (flatString, chunks|nil) -- same contract as applyL1Reinforcement.
local function renderSignedBody(working, lexSubs, receiverUsername, sourceLang, palette,
                                bleedThrough, uttSeed, receiverKnowsAny)
    if not working or working == "" then return working, nil end

    local FRESH    = MC_Core.Colors.ACQUIRED_FRESH
    local FAMILIAR = MC_Core.Colors.ACQUIRED_FAMILIAR
    local familyCloseness = MC_Acquisition.familyClosenessForLang(sourceLang)

    local chunks = {}
    local hasL2 = false
    local stateFor = {}

    local function appendBase(text)
        if not text or text == "" then return end
        local last = chunks[#chunks]
        if last and last.color == nil and last.alpha == nil then
            last.text = last.text .. text
        else
            table.insert(chunks, { text = text })
        end
    end

    local function appendGesture(word)
        local fragment = pickGesture(word, palette, uttSeed)
        local hint = iconicHintFor(word, palette)
        if hint then fragment = fragment .. " (" .. hint .. ")" end
        appendBase(fragment)
    end

    for _, tok in ipairs(tokenizeSigned(working)) do
        if tok.kind == "other" then
            appendBase(tok.text)
        elseif tok.kind == "fingerspell" then
            -- Legible letter-by-letter to any receiver with SOME ASL
            -- tier; gesture-prose to a total non-signer.
            if receiverKnowsAny then
                appendBase(tok.text)
            else
                appendGesture(tok.text)
            end
        else -- "word"
            local wordTok = { text = tok.text, isWord = true }
            if MC_Babble.classify(wordTok, bleedThrough) == "clean" then
                appendBase(tok.text)  -- roster name / exclamation / sanitize sentinel
            else
                local lower = tok.text:lower()
                local sub = lexSubs and lexSubs[lower]
                if not sub then
                    appendGesture(tok.text)
                else
                    local cached = stateFor[lower]
                    if cached == nil then
                        local exp = MC_Acquisition.getExposure(receiverUsername, sourceLang, sub.l2)
                        local ts = MC_Acquisition.tokenState(exp, sub.rank, familyCloseness)
                        -- sub.l1 is already the speaker's original word,
                        -- captured at substitution time. sub.l2 is the
                        -- STORED lex form (lowercase, matching every
                        -- acquisition/teaching key elsewhere); uppercased
                        -- only here, at display, into the citation-form
                        -- gloss ("WATER") the ASL convention actually shows.
                        cached = {
                            state    = ts.state,
                            alpha    = ts.alpha,
                            l2       = sub.l2:upper(),
                            l1Styled = sub.l1,
                        }
                        stateFor[lower] = cached
                    end
                    if cached.state == "fresh" then
                        appendBase(cached.l1Styled .. " (")
                        table.insert(chunks, { text = cached.l2, color = FRESH, alpha = cached.alpha })
                        appendBase(")")
                        hasL2 = true
                    elseif cached.state == "familiar" then
                        appendBase(cached.l1Styled .. " (")
                        table.insert(chunks, { text = cached.l2, color = FAMILIAR,
                            alpha = math.min(0.85, cached.alpha or 1.0) })
                        appendBase(")")
                        hasL2 = true
                    else
                        -- "partial"/"none": no phonetic gradient for a sign
                        -- -- not-yet-acquired renders as a gesture, same as
                        -- any other word (spec's learner ladder).
                        appendGesture(tok.text)
                    end
                end
            end
        end
    end

    local buf = {}
    for _, c in ipairs(chunks) do buf[#buf + 1] = c.text end
    local resultString = table.concat(buf)
    if not hasL2 then return resultString, nil end
    return resultString, chunks
end

-- Signed counterpart of renderWithLangs, called once per receiver from the
-- branch point below. `protectedText` is already sanitize-protected (the
-- branch point runs after MC_Sanitize.protect, matching the spec's render
-- section) so *emotes*/**moods**/((OOC)) never reach the gesture-prose walk.
local function renderSignedWithLangs(palette, speakerLang, speakerIsNative, receiverIsNative,
                                     speakerUsername, receiverUsername, protectedText,
                                     protectedBlocks, protectedOrder, teachingEvent,
                                     timestamp, preview, opts)
    -- ---- FLUENT/NATIVE RECEIVER: clear text ----
    if receiverIsNative then
        return MC_Sanitize.restore(protectedText, protectedBlocks, protectedOrder), speakerLang
    end

    -- ---- What's already a resolved gloss in this text? ----
    -- Native speaker: full dict-sub, mirrors the spoken native path.
    -- Learner speaker: the production pass already substituted what they've
    -- acquired (evalUtterance, shared with the spoken path) -- just
    -- identify what's there, mirroring the spoken learner path.
    local working, lexSubs
    if speakerIsNative then
        working, lexSubs = applyLexSubstitution(protectedText, palette)
        if teachingEvent and not lexSubs[teachingEvent.l2Lower] then
            lexSubs[teachingEvent.l2Lower] = {
                l1 = teachingEvent.l1, l2 = teachingEvent.l2Lower, rank = nil,
            }
        end
    else
        working = protectedText
        lexSubs = identifyL2TokensInWorking(working, palette)
    end

    -- ---- Exposure + teaching: identical order/constants to the spoken path ----
    if receiverUsername and not MC_Core.isEmpty(lexSubs) then
        local tokenEntries = {}
        for _, sub in pairs(lexSubs) do
            table.insert(tokenEntries, { token = sub.l2, rank = sub.rank })
        end
        local newly = nil
        if not preview then
            local teachBoosts = MC_Acquisition.teachingContextBoosts(
                receiverUsername, speakerLang, lexSubs, working)
            local meta
            newly, meta = MC_Acquisition.recordExposureBatch(
                receiverUsername, speakerLang, tokenEntries, teachBoosts,
                opts and opts.addressed, speakerUsername)
            emitAcquisitionMoment(receiverUsername, speakerLang, newly, meta)
        end
        if not preview and teachingEvent and lexSubs[teachingEvent.l2Lower] then
            applyTeachingToReceiver(receiverUsername, speakerLang,
                teachingEvent.l2Lower, lexSubs[teachingEvent.l2Lower].rank,
                speakerUsername, timestamp, newly)
        end
        swapMisacquiredAliases(lexSubs, receiverUsername, speakerLang)
    end

    -- ---- Gesture base + acquired-gloss overlay ----
    local uttSeed = buildSeed(speakerUsername, working, timestamp, nil)
    local bleedThrough = buildBleedThrough(working)
    for _, key in ipairs(protectedOrder) do bleedThrough[key:lower()] = true end

    local receiverKnowsAny = receiverUsername ~= nil
        and MC_Acquisition.hasAcquiredAny(receiverUsername, speakerLang)

    local rendered, renderChunks = renderSignedBody(
        working, lexSubs, receiverUsername, speakerLang, palette,
        bleedThrough, uttSeed, receiverKnowsAny)

    rendered = MC_Sanitize.restore(rendered, protectedBlocks, protectedOrder)
    if renderChunks then
        restoreChunksInPlace(renderChunks, protectedBlocks, protectedOrder)
    end
    return rendered, speakerLang, renderChunks
end

local function renderWithLangs(speakerLang, speakerIsNative, receiverIsNative,
                               speakerUsername, receiverUsername, message, timestamp, opts)
    local preview = opts and opts.preview == true
    -- English baseline: no transform, no tag. v8.16.2: teaching still
    -- happens here -- "Water is called eau in French" IS an English
    -- sentence, so the early return used to make the docs' own teaching
    -- example a silent no-op forever. See detectEnglishTeaching above.
    if speakerLang == "english" then
        if not preview and receiverUsername and speakerUsername then
            applyEnglishTeaching(speakerUsername, receiverUsername, message,
                timestamp, opts)
        end
        return message, nil
    end

    local palette = MC_LangRegistry.getPalette(speakerLang)
    if not palette then
        MC_Incident.report("LANG_PALETTE_UNAVAILABLE",
            "language=" .. tostring(speakerLang) .. " render blocked")
        return "...", speakerLang
    end

    -- ---- TEACHING DETECTION + PRODUCTION (v8.16.2: once per utterance) ----
    -- Both are receiver-independent, so they're computed ONCE per utterance
    -- in evalUtterance (this render runs once per receiver) and shared from
    -- its cache. See the ORDER NOTE there: detection and the speaker-gate
    -- run before the production pass, on the original typed message.
    local state = evalUtterance(palette, speakerLang, speakerIsNative,
        speakerUsername, message, timestamp, preview)
    local teachingEvent = state.teachingEvent
    local groundTruth = state.groundTruth

    -- ---- RP/OOC PROTECTION ----
    -- v8.16.2: sanitize protection runs FIRST, before cultural detection,
    -- so *emote*/**mood**/((OOC)) content is invisible to every downstream
    -- stage. A cultural idiom typed inside an emote used to be detected
    -- there; its MCCULTURAL sentinel was then swallowed into the MCBLEED
    -- block and surfaced as literal "MCCULTURAL1" after restore. Protected
    -- content is untouchable; detection now only sees the spoken text.
    local protectedText, protectedBlocks, protectedOrder = MC_Sanitize.protect(
        groundTruth, { keyTemplate = BLEED_SENTINEL .. "%d" })

    -- MODALITY BRANCH
    -- ASL has no phonology to babble and no cultural-idiom block (v1); the
    -- render choke branches here, right after sanitize-protect, into its
    -- own self-contained ladder. Spoken path below is untouched.
    if palette.modality == "signed" then
        return renderSignedWithLangs(palette, speakerLang, speakerIsNative, receiverIsNative,
            speakerUsername, receiverUsername, protectedText, protectedBlocks, protectedOrder,
            teachingEvent, timestamp, preview, opts)
    end

    -- ---- CULTURAL DETECTION (v8.6) ----
    -- Only fires for native speakers. Learners aren't fluent enough to invoke
    -- cultural register; their typed English passes through as content, not
    -- as idiomatic substitution targets. This is a philosophical choice:
    -- cultural phrases represent ownership of a language's register, which
    -- learners haven't earned and shouldn't accidentally trigger.
    local culturalRegions = {}
    if speakerIsNative then
        culturalRegions = MC_Cultural.detect(protectedText, palette)
    end

    -- ---- COMPREHENSION: listener-side render ----
    -- Native listener of speakerLang: sees the ground truth as-is, with
    -- cultural regions substituted to the L2 idiom (clean render -- natives
    -- don't need help). Always understands everything regardless of whether
    -- speaker is native or learner.
    if receiverIsNative then
        local nativeRendered = protectedText
        if #culturalRegions > 0 then
            nativeRendered = MC_Cultural.substituteForNative(protectedText, culturalRegions)
        end
        return MC_Sanitize.restore(nativeRendered, protectedBlocks, protectedOrder), speakerLang
    end

    -- ---- NON-NATIVE LISTENER PATHS ----
    -- v8.6: pre-substitute cultural regions with MCCULTURAL sentinels BEFORE
    -- dict/babble (sanitize protection already ran, above). The sentinels are
    -- opaque words that survive every pipeline stage via bleedThrough, then
    -- get restored as INHERITED_GREY chunks after applyL1Reinforcement. This
    -- is what enforces the "cultural exposure isn't lexical exposure"
    -- invariant: dict substitution can't fire inside a cultural region
    -- because the region IS a sentinel by the time dict-sub runs.
    local culturalSource = protectedText
    local culturalBlocks = {}
    local culturalOrder = {}
    if #culturalRegions > 0 then
        culturalSource, culturalBlocks, culturalOrder = MC_Cultural.protectRegions(
            protectedText, culturalRegions)
    end

    -- Helper: apply cultural restoration to chunks/flat-string at the end
    -- of the non-native pipeline. Handles the no-chunks case by lifting the
    -- flat string into a trivial single-chunk array so the INHERITED_GREY
    -- emission has somewhere to slot in.
    local function applyCulturalRestore(babbled, renderChunks)
        if MC_Core.isEmpty(culturalBlocks) then
            return babbled, renderChunks
        end
        if not renderChunks then
            renderChunks = { { text = babbled } }
        end
        local newChunks, newFlat = MC_Cultural.restoreToChunks(renderChunks, culturalBlocks)
        return newFlat, newChunks
    end

    if speakerIsNative then
        -- ---- NATIVE-SPEAKER -> NON-NATIVE LISTENER PATH ----
        -- Existing pipeline: dict-sub -> bleed-build -> babble ->
        -- acquisition pass -> restore. (Sanitize protection already ran,
        -- above, before cultural detection.) Speaker's English represents
        -- fluent L2; engine produces the phonetic surface; listener's
        -- acquisition layer decorates it. v8.6: cultural sentinels are
        -- already in culturalSource; they pass through every stage via
        -- bleedThrough.
        local workingWithLex, lexSubs = applyLexSubstitution(culturalSource, palette)

        -- v8.16.2: an l2Only lesson spoken in-language ("this is called
        -- eau") carries no L1 for the dict pass to substitute, so the
        -- event's L2 never lands in lexSubs -- the grant, the teacher cue
        -- and the bleed-through all silently missed. Seed the canonical
        -- entry from the event (same shape as applyLexSubstitution's) so
        -- the typed L2 survives babble, records exposure, and the teaching
        -- gate below can fire -- mirroring applyEnglishTeaching, which
        -- grants straight off the event.
        if teachingEvent and not lexSubs[teachingEvent.l2Lower] then
            local rankMap = getZipfRankMap(palette)
            lexSubs[teachingEvent.l2Lower] = {
                l1   = teachingEvent.l1,
                l2   = teachingEvent.l2Lower,
                rank = rankMap and rankMap[teachingEvent.l2Lower] or nil,
            }
        end

        local bleedThrough = buildBleedThrough(workingWithLex)
        for _, key in ipairs(protectedOrder) do
            bleedThrough[key:lower()] = true
        end
        for _, key in ipairs(culturalOrder) do
            bleedThrough[key:lower()] = true  -- v8.6: cultural sentinels survive babble
        end
        for l2Lower, _ in pairs(lexSubs) do
            bleedThrough[l2Lower] = true
        end

        local accentTint = MC_Acquisition.accentTintForLang(speakerLang)
        local seed = buildSeed(speakerUsername, message, timestamp, accentTint)
        local babbled = MC_Babble.transform(workingWithLex, palette, bleedThrough, seed)

        local renderChunks = nil
        if receiverUsername and not MC_Core.isEmpty(lexSubs) then
            local tokenEntries = {}
            for _, sub in pairs(lexSubs) do
                table.insert(tokenEntries, { token = sub.l2, rank = sub.rank })
            end
            -- v8.16.2: exposure batch FIRST, teaching gate second -- the
            -- teaching utterance's own exposure now counts toward the
            -- receiver-heard gate, so introducing and teaching a brand-new
            -- word in one line works. No double-credit: recordTeaching
            -- flips `acquired` without touching count; the batch stays the
            -- only count write for this message. Speaker-eligibility was
            -- already checked at detection time (evalUtterance).
            local newly = nil
            if not preview then
                local teachBoosts = MC_Acquisition.teachingContextBoosts(
                    receiverUsername, speakerLang, lexSubs, workingWithLex)
                local meta
                newly, meta = MC_Acquisition.recordExposureBatch(
                    receiverUsername, speakerLang, tokenEntries, teachBoosts,
                    opts and opts.addressed, speakerUsername)
                emitAcquisitionMoment(receiverUsername, speakerLang, newly, meta)
            end
            if not preview and teachingEvent and lexSubs[teachingEvent.l2Lower] then
                applyTeachingToReceiver(receiverUsername, speakerLang,
                    teachingEvent.l2Lower, lexSubs[teachingEvent.l2Lower].rank,
                    speakerUsername, timestamp, newly)
            end
            swapMisacquiredAliases(lexSubs, receiverUsername, speakerLang)
            babbled, renderChunks = applyL1Reinforcement(babbled, lexSubs, receiverUsername, speakerLang, palette)
        end

        -- v8.6: cultural restore (no-op if no cultural regions were detected).
        -- Order matters: cultural restore BEFORE sanitize restore, because
        -- the chunks emerging from cultural restore need to go through the
        -- existing MCBLEED-restoration pass for any RP markers in the
        -- surrounding text.
        babbled, renderChunks = applyCulturalRestore(babbled, renderChunks)

        babbled = MC_Sanitize.restore(babbled, protectedBlocks, protectedOrder)
        if renderChunks then
            restoreChunksInPlace(renderChunks, protectedBlocks, protectedOrder)
        end
        return babbled, speakerLang, renderChunks
    end

    -- ---- LEARNER-SPEAKER -> NON-NATIVE LISTENER PATH ----
    -- Ground truth is hybrid English/L2 (the production pass already ran).
    -- No babble -- the speaker did not produce phonetic L2 for unknown words;
    -- they used English. We just need to apply the listener's acquisition
    -- layer to whichever L2 tokens are present.
    -- 
    -- v8.6: no cultural processing here either. Learners' cultural regions
    -- aren't detected at all (we gated detection on speakerIsNative above),
    -- so culturalSource == protectedText and culturalBlocks is empty. The
    -- applyCulturalRestore call below is a no-op in this branch.
    local working = culturalSource

    local lexSubs = identifyL2TokensInWorking(working, palette)

    local renderChunks = nil
    if receiverUsername and not MC_Core.isEmpty(lexSubs) then
        local tokenEntries = {}
        for _, sub in pairs(lexSubs) do
            table.insert(tokenEntries, { token = sub.l2, rank = sub.rank })
        end
        -- v8.16.2: batch first, teaching gate second -- same semantics as
        -- the native path (see the comment there).
        local newly = nil
        if not preview then
            local teachBoosts = MC_Acquisition.teachingContextBoosts(
                receiverUsername, speakerLang, lexSubs, working)
            local meta
            newly, meta = MC_Acquisition.recordExposureBatch(
                receiverUsername, speakerLang, tokenEntries, teachBoosts,
                opts and opts.addressed, speakerUsername)
            emitAcquisitionMoment(receiverUsername, speakerLang, newly, meta)
        end
        if not preview and teachingEvent and lexSubs[teachingEvent.l2Lower] then
            applyTeachingToReceiver(receiverUsername, speakerLang,
                teachingEvent.l2Lower, lexSubs[teachingEvent.l2Lower].rank,
                speakerUsername, timestamp, newly)
        end
        swapMisacquiredAliases(lexSubs, receiverUsername, speakerLang)
        working, renderChunks = applyL1Reinforcement(working, lexSubs, receiverUsername, speakerLang, palette)
    end

    -- v8.6: cultural restore (no-op for learner speakers -- culturalBlocks empty).
    working, renderChunks = applyCulturalRestore(working, renderChunks)

    working = MC_Sanitize.restore(working, protectedBlocks, protectedOrder)
    if renderChunks then
        restoreChunksInPlace(renderChunks, protectedBlocks, protectedOrder)
    end
    return working, speakerLang, renderChunks
end

-- CODE-SWITCH SHAPE GUARD
-- The former `[language: content]` experiment could cross modality, hands,
-- sight, radio, relay, and speaker-competency boundaries while those gates
-- inspected only the utterance's outer language. Passing a malformed attempt
-- through literally was worse: a typo could expose text the player believed
-- was protected. Stable posture is deliberately smaller and hard: any
-- switch-shaped bracket is rejected by MC_Server, and direct render callers
-- receive only an opaque marker. Whole-utterance `@language text` remains the
-- supported one-shot mechanism. Ordinary brackets without a named `word:`
-- prefix remain ordinary text.
function MC_Lang.hasCodeSwitchSyntax(message)
    return type(message) == "string"
        and message:find("%[%s*[%a_][%w_]*%s*:") ~= nil
end

-- Fail-CLOSED fallback for a render-pipeline error. The pcall around
-- renderWithLangs used to fall back to the raw typed message for EVERYONE,
-- so any latent fault in the pipeline quietly dropped the language barrier
-- and leaked the speaker's plaintext to non-comprehenders. Receivers who
-- would have seen the clean text anyway (English speaker, native listener,
-- the speaker themselves) keep the plaintext fallback only when the palette
-- still exists; everyone else gets a plain babble of the message -- no
-- dictionary bleed, no reinforcement, but
-- the barrier holds. The babble itself is guarded too: if even that throws,
-- the receiver sees "..." rather than an error (or the plaintext).
local function failClosedRender(speakerLang, receiverIsNative, speakerUsername,
                                receiverUsername, message, timestamp)
    if speakerLang == "english" then
        return message, nil, nil
    end
    local palette = MC_LangRegistry.getPalette(speakerLang)
    if not palette then
        MC_Incident.report("LANG_PALETTE_UNAVAILABLE",
            "language=" .. tostring(speakerLang) .. " fallback render blocked")
        return "...", speakerLang, nil
    end
    if receiverIsNative
        or (receiverUsername ~= nil and receiverUsername == speakerUsername) then
        return message, nil, nil
    end
    local ok, babbled = pcall(MC_Babble.transform, message, palette, {},
        buildSeed(speakerUsername, message, timestamp))
    if not ok or type(babbled) ~= "string" then
        babbled = "..."
    end
    return babbled, speakerLang, nil
end

function MC_Lang.renderForReceiver(speakerUsername, receiverUsername, message, timestamp, opts)
    if MC_Lang.hasCodeSwitchSyntax(message) then
        MC_Incident.report("LANG_CODESWITCH_DISABLED",
            "direct render attempt redacted")
        return "...", nil, nil
    end
    if type(message) ~= "string" then
        MC_Incident.report("LANG_RENDER_FAILED", "message is not a string")
        return "...", nil, nil
    end
    if not speakerUsername or speakerUsername == "" then
        MC_Incident.report("LANG_SPEAKER_ID_UNAVAILABLE",
            "direct render speaker identity unavailable")
        return "...", nil, nil
    end

    -- E2 ergonomics (one-shot "@<language>" prefix): opts.overrideLang, when
    -- present, stands in for the speaker's PERSISTED language for this one
    -- render only -- nothing downstream reads MC_Lang.getLanguage again, so
    -- setting the local here is the entire seam (native/learner status,
    -- teaching eligibility, and the utterance cache key all fall out of
    -- this one value).
    local speakerLang = (opts and opts.overrideLang) or MC_Lang.getLanguage(speakerUsername)

    local speakerIsNative  = MC_Lang.isNative(speakerUsername, speakerLang)
    local receiverIsNative = MC_Lang.isNative(receiverUsername, speakerLang)
    local ok, rendered, langTag, chunks = pcall(
        renderWithLangs, speakerLang, speakerIsNative, receiverIsNative,
        speakerUsername, receiverUsername, message, timestamp, opts)
    if not ok then
        -- Always-on warning (same rule as MC_Persist): a render fault
        -- means the barrier is limping for live traffic -- surface it
        -- even with DEBUG off, then fail closed.
        -- Do not copy an arbitrary exception string into the durable incident
        -- log: a downstream error may have embedded player-authored text.
        MC_Incident.report("LANG_RENDER_FAILED", "stage=primary-render")
        return failClosedRender(speakerLang, receiverIsNative,
            speakerUsername, receiverUsername, message, timestamp)
    end
    return rendered, langTag, chunks
end

--[[
    Render a line of narration for one receiver, transforming only the words
    spoken aloud inside it.

    Each quoted run goes through renderForReceiver, so the barrier and the
    learner production model are a /say's. The narration between the quotes is
    left alone. The quote marks themselves are rewritten around the rendered
    speech, so a listener who understands nothing still sees that something
    was said. The speaker's own copy comes from narrationSpeakerEcho, not from
    here.

    KNOWN LIMITATION -- each quoted run is its own utterance to the receiver's
    learning. `/me nods. "water" then "bread" she adds.` records exposure and
    teaching twice, where the same words in one /say record once (MC_Teaching's
    leftmost-match rule, MC_Acquisition's per-token roll). It is linear in
    quote count and bounded by the message-length cap, so a line can buy a few
    extra exposures, not an unbounded grind.

    Do NOT "fix" this by passing opts.preview for later runs. That was tried
    and is far worse: preview skips the evalUtterance cache, which is the only
    thing deduping the SPEAKER's production writes across receivers, so later
    runs re-bank production once per listener -- measured at 1 + 2N records for
    a three-quote line heard by N people, against 1 for the same words in a
    /say. It also changes the rendered text of later runs, so a learner comes
    out more fluent on their third quote than their first.

    The real fix is to make the whole line one render rather than one per run
    -- protect the narration with sentinels the way MC_Sanitize already
    protects an *emote* inside speech, render once, restore. That is a change
    to the barrier itself and wants its own pass.

    Returns the same shape as renderForReceiver. Chunks are deliberately not
    reassembled: the per-word comprehension gradient is a speech-line styling,
    and the client colours a narration line's quoted runs from the flat text
    (MC_Core.findQuotedRuns), which works the same whether those words came
    through clean or babbled. Failing that way costs a shade of colour, never
    a leak of meaning.

    @return rendered text, the language tag to label it with, nil chunks
]]
function MC_Lang.renderNarrationForReceiver(speakerUsername, receiverUsername,
                                            message, timestamp, opts)
    if type(message) ~= "string" then
        MC_Incident.report("LANG_RENDER_FAILED", "narration message is not a string")
        return "...", nil, nil
    end
    -- Checked on the WHOLE line, not just the quoted runs: renderForReceiver
    -- guards its own input, but switch-shaped syntax in the narration half
    -- would otherwise reach a direct caller of this function unexamined.
    -- MC_Server rejects such a message before routing, so this is the second
    -- lock on the same door rather than the only one.
    if MC_Lang.hasCodeSwitchSyntax(message) then
        MC_Incident.report("LANG_CODESWITCH_DISABLED",
            "narration render attempt redacted")
        return "...", nil, nil
    end

    local langTag = nil
    local result, spoke = MC_Core.mapQuotedSpeech(message, function(spoken)
        -- Every run gets the caller's own opts, unmodified. See the header:
        -- varying them per run to suppress bookkeeping breaks the utterance
        -- cache and multiplies the speaker's production credit by the size of
        -- the audience.
        --
        -- Fails closed here, not just at the call site: a render fault
        -- redacts the WORDS and leaves the action, which is the whole
        -- principle of this path. renderForReceiver already fails closed
        -- internally; this is the net under an outright throw, so no caller
        -- can forget one and have plaintext fall out.
        local okRender, rendered, tag = pcall(MC_Lang.renderForReceiver,
            speakerUsername, receiverUsername, spoken, timestamp, opts)
        if not okRender or type(rendered) ~= "string" then
            MC_Incident.report("LANG_RENDER_FAILED",
                "context=narration stage=quoted-run output=redacted")
            return "..."
        end
        langTag = langTag or tag
        return rendered
    end)
    if not spoke then return message, nil, nil end

    return result, langTag, nil
end

--[[
    What the speaker hears of the words they quoted in their own narration.

    The spoken half of a /me is speech, so a learner should read back what
    they actually managed to say there, exactly as they do for a /say -- the
    one player whose fluency growth would otherwise be invisible to them is
    the one doing the growing. The narration half is theirs as typed.

    Shares speakerEcho's evalUtterance cache, so this costs no extra
    production credit however many receivers also render the same line.

    @return the echoed line, or nil when there is nothing to echo (English or
            native speaker, or a pass that changed nothing) so the caller
            keeps the typed text
]]
function MC_Lang.narrationSpeakerEcho(message, speakerUsername, timestamp, overrideLang)
    if type(message) ~= "string" then return nil end
    if MC_Lang.hasCodeSwitchSyntax(message) then
        MC_Incident.report("LANG_CODESWITCH_DISABLED",
            "narration speaker echo redacted")
        return "..."
    end

    local changed = false
    local result, spoke = MC_Core.mapQuotedSpeech(message, function(spoken)
        local okEcho, echo = pcall(MC_Lang.speakerEcho, spoken,
            speakerUsername, timestamp, overrideLang)
        if not okEcho then
            MC_Incident.report("LANG_SPEAKER_ECHO_FAILED",
                "context=narration stage=quoted-run output=redacted")
            changed = true
            return "..."
        end
        if echo then
            changed = true
            return echo
        end
        return spoken
    end)

    if not spoke or not changed then return nil end
    return result
end

-- SPEAKER ECHO (v8.16.2)
--
-- What the speaker hears of their OWN utterance. For learner speakers the
-- production pass decides what actually came out of their mouth -- groping
-- gaps, hesitation fillers, the L2 they managed -- and before this the
-- speaker was the only person in earshot who DIDN'T see it (their echo was
-- the clean typed text, so fluency growth was invisible to the one player
-- it models). Returns the same once-per-utterance ground truth the
-- receivers' renders consume (shared evalUtterance cache -- production
-- credit stays once per utterance no matter who asks first), or nil when
-- there is nothing to echo: English or native speakers, or a pass that
-- changed nothing. Disabled switch-shaped syntax and a missing palette return
-- an
-- explicit opaque echo, never nil (nil would make MC_Server reuse the clean
-- typed text). MC_Server calls this pcall-wrapped and redacts on exceptions.

-- overrideLang (E2 ergonomics): the same one-shot "@<language>" override
-- renderForReceiver's opts.overrideLang applies, threaded through as a
-- plain positional argument here since speakerEcho has no opts table of
-- its own. See MC_Server.lua's sendChatToReceiver self-echo branch.
function MC_Lang.speakerEcho(message, speakerUsername, timestamp, overrideLang)
    if MC_Lang.hasCodeSwitchSyntax(message) then
        MC_Incident.report("LANG_CODESWITCH_DISABLED",
            "speaker echo attempt redacted")
        return "..."
    end
    if type(message) ~= "string" or message == "" then return nil end
    if not speakerUsername or speakerUsername == "" then
        MC_Incident.report("LANG_SPEAKER_ID_UNAVAILABLE",
            "speaker echo identity unavailable")
        return "..."
    end
    local speakerLang = overrideLang or MC_Lang.getLanguage(speakerUsername)
    if speakerLang == "english" then return nil end
    local palette = MC_LangRegistry.getPalette(speakerLang)
    if not palette then
        MC_Incident.report("LANG_PALETTE_UNAVAILABLE",
            "language=" .. tostring(speakerLang) .. " speaker echo blocked")
        return "..."
    end
    if MC_Lang.isNative(speakerUsername, speakerLang) then return nil end
    local state = evalUtterance(palette, speakerLang, false,
        speakerUsername, message, timestamp, false)
    if not state.groundTruth or state.groundTruth == message then return nil end
    return state.groundTruth
end

-- OBSERVER BABBLE (2026-07-13)
--
-- What a listener who does NOT speak the language perceives of a whole
-- utterance -- FULL babble, wholesale, regardless of the speaker's fluency.
-- This is the Discord radio relay's boundary guarantee: if it reaches Discord,
-- it must not arrive as readable English. A Discord reader can
-- never be assumed to speak the language, and the relay is the last stage
-- before it. Unlike renderForReceiver, this deliberately does NOT go through
-- the learner-production model (evalUtterance groundTruth) -- a struggling
-- learner's English fallback words would otherwise pass through as clear
-- English. It babbles the RAW typed message so every spoken word becomes the
-- palette's phonetics; only MC_Sanitize-protected *emote*/**mood**/((OOC))
-- content survives, since that is action/aside, not speech.
--
-- Pure and side-effect free (no evalUtterance, no acquisition/production/
-- teaching writes) -- safe to call once per transmission purely for display.
    -- Returns nil (caller keeps its clean/canonical text) for English or a
    -- signed language (signing never reaches radio anyway; guarded here for any
    -- other caller). An unknown non-English palette is reported and returns an
    -- opaque marker. bleedThrough is empty so nothing bleeds
-- to clear; the protected sentinels are additionally whitelisted (belt and
-- suspenders with MC_Babble.classify's own sentinel-pattern check).
function MC_Lang.observerBabble(message, speakerUsername, timestamp, overrideLang)
    if MC_Lang.hasCodeSwitchSyntax(message) then
        MC_Incident.report("LANG_CODESWITCH_DISABLED",
            "observer relay attempt redacted")
        return "..."
    end
    if type(message) ~= "string" or message == "" then return nil end
    if not speakerUsername or speakerUsername == "" then
        MC_Incident.report("LANG_SPEAKER_ID_UNAVAILABLE",
            "observer relay identity unavailable")
        return "..."
    end
    local speakerLang = overrideLang or MC_Lang.getLanguage(speakerUsername)
    if speakerLang == "english" then return nil end
    local palette = MC_LangRegistry.getPalette(speakerLang)
    if not palette then
        MC_Incident.report("LANG_PALETTE_UNAVAILABLE",
            "language=" .. tostring(speakerLang) .. " observer render blocked")
        return "..."
    end
    if palette.modality == "signed" then return nil end

    -- Space-pad the sentinel key. A spoken word fused directly to a marker
    -- with no space -- "attack*grins*" or "*grins*attack" -- would otherwise
    -- protect() into a SINGLE token carrying the sentinel ("attackMCBLEED1"),
    -- which MC_Babble.classify passes through clean, leaking the English word.
    -- The unpadded pipeline accepts that (a word fused to an emote is rare in
    -- normal RP), but the Discord boundary can't: any readable English here
    -- breaks the guarantee. The padding forces the word to tokenize SEPARATELY
    -- from the sentinel so it babbles; the pad spaces are part of the minted
    -- key and are consumed on restore, so the original word/marker spacing is
    -- preserved (a nested marker gains one cosmetic space -- vanishingly rare
    -- and relay-only). keyTemplate must be Lua-pattern-safe (MC_Sanitize);
    -- spaces are.
    local protectedText, protectedBlocks, protectedOrder = MC_Sanitize.protect(
        message, { keyTemplate = " " .. BLEED_SENTINEL .. "%d " })

    -- Sentinels stay clean via MC_Babble.classify's own sentinel-pattern check
    -- (MC_Lang wires "MCBLEED%d" as a protected pattern at load); every other
    -- word babbles. Empty bleedThrough: a non-comprehending observer gets
    -- nothing clear but the protected markers.
    local seed = buildSeed(speakerUsername, protectedText, timestamp, nil)
    local babbled = MC_Babble.transform(protectedText, palette, {}, seed)
    return MC_Sanitize.restore(babbled, protectedBlocks, protectedOrder)
end

-- Neutral detail row (light grey). Shared by /lang reset and /lang list.
local function sysMsg(player, message, color)
    sendServerCommand(player, "MongooseChat", "SystemMessage", {
        message = message, color = color or {200, 200, 200},
    })
end
-- Internal contract: consumed throughout MC_LangCommands.
MC_Lang._sysMsg = sysMsg

-- Foreign-store wipe extensions. Not all of MongooseChat's per-player data
-- lives in files this module can reach: the presentation stores live in
-- MC_Server (which requires this module -- requiring back would be circular).
-- So the dependency points the other way -- at load, any module holding
-- per-player state registers a wipe extension here (the same inversion as
-- MC_Acquisition.setExposureTraceSink):
--
--   MC_Lang.registerWipeExtension("bio", {
--       label     = "Bio",
--       inventory = function(username)
--           -- short description of what's held ('"their tagline"'),
--           -- or nil when the store holds nothing for this username.
--           -- A second return value MUST be true when the store was
--           -- authoritatively inspected, false when it is unavailable.
--       end,
--       clear     = function(username)
--           -- wipe it; the store persists itself and broadcasts whatever
--           -- its clients need to drop caches. Return true if anything
--           -- was actually removed.
--       end,
--   })
--
-- Registration is idempotent by id (a re-registration replaces itself).
-- `hidden = true` keeps an identity store inside every preflight/clear
-- transaction while omitting its label and contents from player-facing
-- previews and successful wipe reports. Hidden failures remain visible as
-- the generic "internal identity store"; the structured incident keeps the
-- exact id for operators.
-- The preview lists every KNOWN store: registered ones by their real
-- contents, unregistered ones as honestly out of reach -- resetall never
-- pretends to wipe what it can't touch. Four stores are wired today, all
-- registered by MC_Server.lua itself:
--   "bio"         -> MC_BioDB.taglines (MC_Server.lua); clear saves
--                    and broadcasts a BioUpdate with tagline="" so online
--                    caches empty out
--   "description" -> MC_Desc.db.descriptions (MC_Server.lua)
--   "notes"       -> MC_Notes.db.notes, both directions -- what this
--                    username wrote AND what's written about them
--                    (MC_Server.lua)
--   "hue"         -> MC_HueDB.hues (MC_Server.lua); the next stamp
--                    falls back to the hash color on its own
local wipeExtensions = {}   -- [id] = { label, inventory, clear }

-- The stores we KNOW ship per-player data today. Drives the out-of-reach
-- preview lines for anything not (yet) registered.
local KNOWN_WIPE_STORES = {
    { id = "bio",         label = "Bio tagline" },                 -- registered by MC_Server (taglines)
    { id = "description", label = "Character-sheet description" }, -- registered by MC_Server
    { id = "notes",       label = "Personal notes" },              -- registered by MC_Server
    { id = "hue",         label = "Name color" },                  -- registered by MC_Server (/hue)
}

function MC_Lang.registerWipeExtension(id, ext)
    if type(id) ~= "string" or id == "" then return false end
    if type(ext) ~= "table"
       or type(ext.label) ~= "string"
       or type(ext.inventory) ~= "function"
       or type(ext.clear) ~= "function"
       or (ext.hidden ~= nil and type(ext.hidden) ~= "boolean") then
        wipeExtensions[id] = nil
        return false
    end
    wipeExtensions[id] = ext
    dbg("registerWipeExtension: '%s' (%s) wired into /lang resetall", id, ext.label)
    return true
end

-- Everything the wipe would take, gathered store by store. Shared by the
-- preview, the confirmation report, and the audit log line.
local function buildWipeInventory(username)
    local inv = {}
    inv.ready = true
    inv.unavailable = {}
    if not MC_Lang.isStorageAvailable() then
        inv.ready = false
        inv.unavailable[#inv.unavailable + 1] = "language identity"
    end
    if type(MC_Acquisition.isStorageAvailable) ~= "function"
        or not MC_Acquisition.isStorageAvailable() then
        inv.ready = false
        inv.unavailable[#inv.unavailable + 1] = "lived vocabulary"
    end
    inv.speaking = MC_Lang.getLanguage(username)   -- "english" = baseline
    inv.previous = MC_Lang.getPreviousLanguage(username)
    inv.natives = {}
    for _, lang in ipairs(MC_Lang.getNativeLanguages(username)) do
        if lang ~= "english" then inv.natives[#inv.natives + 1] = describeLang(lang) end
    end
    inv.langs = MC_Acquisition.inventoryForUser(username)
    inv.exts = {}   -- [id] = inventory string (registered extensions holding data)
    local anyExt = false
    local function unavailableName(id, ext)
        if ext and ext.hidden == true then return "internal identity store" end
        return id
    end
    for id, ext in pairs(wipeExtensions) do
        local ok, held, available = pcall(ext.inventory, username)
        if not ok then
            dbg("buildWipeInventory: extension '%s' inventory threw: %s", id, tostring(held))
            inv.ready = false
            inv.unavailable[#inv.unavailable + 1] =
                unavailableName(id, ext)
        elseif available ~= true then
            inv.ready = false
            inv.unavailable[#inv.unavailable + 1] =
                unavailableName(id, ext)
            if type(held) == "string" and held ~= "" then
                inv.exts[id] = held
                anyExt = true
            end
        elseif type(held) == "string" and held ~= "" then
            inv.exts[id] = held
            anyExt = true
        end
    end
    for _, known in ipairs(KNOWN_WIPE_STORES) do
        if not wipeExtensions[known.id] then
            inv.ready = false
            inv.unavailable[#inv.unavailable + 1] =
                known.hidden == true and "internal identity store" or known.id
        end
    end
    inv.empty = inv.ready and (inv.speaking == "english")
                and inv.previous == nil and #inv.natives == 0
                and #inv.langs == 0 and not anyExt
    return inv
end

-- One human-readable line per store, from an inventory. Used verbatim by
-- the preview; joined with "; " for the audit log.
local function wipeInventoryLines(inv)
    local lines = {}
    if inv.ready == false then
        lines[#lines + 1] = "[Safety gate] unavailable: " ..
            table.concat(inv.unavailable or {}, ", ")
    end
    local identity = (inv.speaking == "english")
        and "Speaking: English (baseline)"
        or  ("Speaking: " .. describeLang(inv.speaking))
    identity = identity .. " | Native: " ..
        (#inv.natives > 0 and table.concat(inv.natives, ", ") or "none beyond English")
    identity = identity .. " | Previous: " ..
        (inv.previous and describeLang(inv.previous) or "none")
    lines[#lines + 1] = "[Language identity] " .. identity
    if #inv.langs == 0 then
        lines[#lines + 1] = "[Lived vocabulary] nothing tracked"
    else
        for _, entry in ipairs(inv.langs) do
            local bits = { string.format("%d word(s) heard", entry.tokens) }
            if entry.acquired > 0 then
                bits[#bits + 1] = string.format("%d made their own", entry.acquired)
            end
            if entry.produced > 0 then
                bits[#bits + 1] = string.format("%d spoken aloud", entry.produced)
            end
            if entry.misheard > 0 then
                bits[#bits + 1] = string.format("%d misheard", entry.misheard)
            end
            lines[#lines + 1] = string.format("[Lived vocabulary] %s: %s",
                describeLang(entry.lang), table.concat(bits, ", "))
        end
    end
    for _, known in ipairs(KNOWN_WIPE_STORES) do
        local ext = wipeExtensions[known.id]
        local hidden = (ext and ext.hidden == true)
            or (not ext and known.hidden == true)
        if not hidden and ext then
            lines[#lines + 1] = string.format("[%s] %s",
                ext.label, inv.exts[known.id] or "nothing held")
        elseif not hidden then
            lines[#lines + 1] = string.format(
                "[%s] out of this command's reach for now -- left as it is",
                known.label)
        end
    end
    -- Extensions registered under ids we don't know in advance still show.
    for id, ext in pairs(wipeExtensions) do
        local isKnown = false
        for _, known in ipairs(KNOWN_WIPE_STORES) do
            if known.id == id then isKnown = true end
        end
        if not isKnown and ext.hidden ~= true then
            lines[#lines + 1] = string.format("[%s] %s",
                ext.label, inv.exts[id] or "nothing held")
        end
    end
    return lines
end
-- Internal contract: the /lang resetall command handler (runResetAll)
-- builds and renders the wipe preview/report through these two, and
-- walks the registry directly to call each registered extension's
-- clear(). All three stay here because they read (or are) the wipe-
-- extension registry's storage, which other modules register into.
MC_Lang._buildWipeInventory = buildWipeInventory
MC_Lang._wipeInventoryLines = wipeInventoryLines
MC_Lang._wipeExtensions = wipeExtensions

-- A fresh body must never inherit the old body's presentation identity.
-- Unlike the operator-facing resetall preview, this path is automatic and
-- therefore admits no "out of reach -- left untouched" result. It first
-- preflights every shipped store, then clears only the stores that confirmed
-- they hold data. A missing registration, unavailable inventory, malformed
-- extension result, thrown callback, or unconfirmed clear fails the whole
-- operation and leaves the fresh-character marker unstamped so the server
-- retries on the next command.
--
-- Cross-store rollback is not possible without coupling five independent A/B
-- stores. Each clear is itself transactional; if a later store's verified
-- write fails, an earlier committed clear remains cleared and the unstamped
-- operation retries idempotently. Crucially, the new character is never
-- declared handled while any old identity is known or potentially present.
function MC_Lang.clearFreshIdentity(username)
    if type(username) ~= "string" or username == "" then
        MC_Incident.report("FRESH_IDENTITY_WIPE_FAILED", "stage=identity")
        return false
    end

    local ordered = {}
    local seen = {}
    for _, known in ipairs(KNOWN_WIPE_STORES) do
        local ext = wipeExtensions[known.id]
        if not ext then
            MC_Incident.report("FRESH_IDENTITY_WIPE_FAILED",
                "store=" .. known.id .. " stage=registration")
            return false
        end
        ordered[#ordered + 1] = { id = known.id, ext = ext }
        seen[known.id] = true
    end

    -- Future extensions registered into the total-wipe contract are identity
    -- stores too. Include them deterministically so adding one cannot silently
    -- create a fresh-character inheritance seam.
    local extraIds = {}
    for id in pairs(wipeExtensions) do
        if not seen[id] then extraIds[#extraIds + 1] = id end
    end
    table.sort(extraIds)
    for _, id in ipairs(extraIds) do
        ordered[#ordered + 1] = { id = id, ext = wipeExtensions[id] }
    end

    local heldById = {}
    for _, entry in ipairs(ordered) do
        local ok, held, available = pcall(entry.ext.inventory, username)
        if not ok or available ~= true then
            MC_Incident.report("FRESH_IDENTITY_WIPE_FAILED",
                "store=" .. entry.id .. " stage=inventory")
            return false
        end
        if held ~= nil and (type(held) ~= "string" or held == "") then
            MC_Incident.report("FRESH_IDENTITY_WIPE_FAILED",
                "store=" .. entry.id .. " stage=inventory-contract")
            return false
        end
        heldById[entry.id] = held
    end

    for _, entry in ipairs(ordered) do
        if heldById[entry.id] ~= nil then
            local ok, removed = pcall(entry.ext.clear, username)
            if not ok or removed ~= true then
                MC_Incident.report("FRESH_IDENTITY_WIPE_FAILED",
                    "store=" .. entry.id .. " stage=clear")
                return false
            end
        end
    end
    return true
end

-- FRESH-CHARACTER POLICY (v8.16.2)
--
-- Language state is keyed by username, so it survives character death: a
-- re-rolled character walks in carrying everything the dead one earned.
-- MC_Server detects a genuinely fresh character whose username still holds
-- language state and hands the player here; what happens next is the
-- server's call (MC_Config.Languages.deathReset):
--
--   "auto"   -> the old life's languages are wiped outright -- the same
--               composite wipe /lang reset performs -- with one quiet line
--               to the player.
--   "notify" -> (default) the player is told what carried over, with the
--               exact /forget lines to paste; online admins get the
--               ready-made /lang reset line for a full wipe.
--   "off"    -> no-op; inheritance is the server's chosen fiction.
--
-- The function returns explicit success. Character creation still sails on,
-- but MC_Server stamps the character handled only after this work succeeds so
-- a persistence/API fault is reported and retried rather than forgotten.

function MC_Lang.handleFreshCharacter(player)
    local ok, result = pcall(function()
        if not player then return false end
        if type(MC_Config.isSandboxKeyAuthoritative) ~= "function"
            or not MC_Config.isSandboxKeyAuthoritative(
                "LanguagesDeathReset") then
            MC_Incident.report("FRESH_CHARACTER_POLICY_FAILED",
                "deathReset policy not authoritative")
            return false
        end
        local configured = MC_Config.Languages
            and MC_Config.Languages.deathReset or nil
        if type(configured) ~= "string" then
            MC_Incident.report("FRESH_CHARACTER_POLICY_FAILED",
                "deathReset policy unavailable")
            return false
        end
        local mode = configured:lower()
        if mode ~= "auto" and mode ~= "notify" and mode ~= "off" then
            MC_Incident.report("FRESH_CHARACTER_POLICY_FAILED",
                "deathReset policy invalid")
            return false
        end
        if mode == "off" then return true end

        local username = MC_Core.safe(function() return player:getUsername() end, nil)
        if not username then return false end

        -- Inventory of what carried over (same shape /lang reset previews).
        local speaking = MC_Lang.getLanguage(username)
        local previous = MC_Lang.getPreviousLanguage(username)
        local natives = {}
        for _, lang in ipairs(MC_Lang.getNativeLanguages(username)) do
            if lang ~= "english" then natives[#natives + 1] = lang end
        end
        local acq = MC_Acquisition.languagesWithData(username)
        if speaking == "english" and previous == nil
            and #natives == 0 and #acq == 0 then
            return true  -- nothing actually carried over
        end

        if mode == "auto" then
            -- Composite wipe: the same machinery as /lang reset confirm.
            local reset = MC_Lang.resetUser(username)
            if not reset.ok then return false end
            local acquisitionOk = MC_Acquisition.forgetUserPersisted(username)
            if acquisitionOk ~= true then return false end
            sysMsg(player, "The words of your old life are gone.", {150, 150, 150})
            dbg("handleFreshCharacter: auto-wiped language state for %s", username)
            return true
        end

        -- "notify" (the default; unrecognized values land here too -- the
        -- safe direction is telling people, not wiping them).
        sysMsg(player, "The words of your old life linger -- this new self still carries them.",
            {140, 200, 220})
        if #natives > 0 then
            local names = {}
            for _, lang in ipairs(natives) do names[#names + 1] = describeLang(lang) end
            sysMsg(player, "  Native tongues carried over: " .. table.concat(names, ", "))
        end
        if speaking ~= "english" then
            sysMsg(player, "  Still set to speak " .. describeLang(speaking) ..
                " (/lang english to change).")
        end
        if previous then
            sysMsg(player, "  Previous speaking language carried over: " ..
                describeLang(previous) .. ".")
        end
        for _, entry in ipairs(acq) do
            sysMsg(player, string.format("  %s -- %d word(s) picked up. To let it go: /forget %s",
                describeLang(entry.lang), entry.tokens, entry.lang))
        end

        -- Admin heads-up with the ready-made full-wipe line (native grants
        -- and the speaking choice are theirs to clear, not /forget's).
        local forename = MC_Core.safe(function()
            local desc = player:getDescriptor()
            return desc and desc:getForename() or nil
        end, nil) or username
        local adminLine = string.format(
            '%s (%s) re-rolled but kept their old language state. Full wipe: /lang reset "%s" confirm',
            forename, username, forename)
        local onlinePlayers = getOnlinePlayers()
        if onlinePlayers then
            for i = 0, onlinePlayers:size() - 1 do
                local p = onlinePlayers:get(i)
                if MC_Core.isAdmin(p) then
                    sysMsg(p, adminLine, {255, 200, 100})
                end
            end
        end
        dbg("handleFreshCharacter: notified %s (speaking=%s natives=%d acqLangs=%d)",
            username, speaking, #natives, #acq)
        return true
    end)
    if not ok then
        MC_Incident.report("FRESH_CHARACTER_POLICY_FAILED", tostring(result))
        return false
    end
    if result ~= true then
        MC_Incident.report("FRESH_CHARACTER_POLICY_FAILED",
            "policy did not complete; will retry")
        return false
    end
    return true
end

return MC_Lang
