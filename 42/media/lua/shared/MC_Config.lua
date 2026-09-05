--[[
================================================================================
    MongooseChat - Configuration

    Central configuration for all MongooseChat modules. Shared between
    client and server - changes here affect both.

    CUSTOMIZATION:
    Server operators can configure via Sandbox Options in the game UI.
    For advanced settings not in sandbox, edit values below.
    See docs/ARCHITECTURE.md -- its own preamble explains why the old
    docs/TECHNICAL.md is gone rather than updated.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Incident = require("MC_Incident")
local dbg = MC_Core.debugger("CONFIG")

local MC_Config = {}
local sandboxSpecByKey = {}
local sandboxKeyStatus = {}

-- SANDBOX VARIABLE HELPERS
-- Boot-time values are provisional defaults. Post-sync fallback is reported.

--[[
    liveSandbox(name, default): read straight from SandboxVars.MongooseChat,
    bypassing this module's boot-time cache. MP's sandbox sync completes
    AFTER MC_Config's cache is captured at require() time, so a handful of
    client call sites (nameplate LOS mode/hide-own, bubble duration, bubble/
    typing toggles, anonymity, portrait mode) need a value that can be newer
    than the cache mid-session. Missing or malformed live state returns the
    caller's conservative `default` plus `false`, and always reports a
    SANDBOX_VALUE_FALLBACK incident.
]]
local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function enumContains(values, value)
    if type(value) == "number" then
        return value % 1 == 0 and values[value] ~= nil
    end
    if type(value) == "string" then
        for _, candidate in ipairs(values) do
            if candidate == value then return true end
        end
    end
    return false
end

local function validSandboxValue(spec, value)
    if value == nil then return false end
    if not spec then return true end
    if spec.enumValues then
        return enumContains(spec.enumValues, value)
    end
    local expected = type(spec.default)
    if expected == "number" then
        if not isFiniteNumber(value) then return false end
        if spec.integer and value ~= math.floor(value) then return false end
        if spec.min and value < spec.min then return false end
        if spec.max and value > spec.max then return false end
        return true
    end
    return type(value) == expected
end

-- Live reads happen after sandbox synchronization and can affect anonymity,
-- sight, modality, and whether UI is emitted at all. Missing/malformed state
-- may still use the caller's conservative value, but that fallback is never
-- quiet. The second return lets objective-critical callers distinguish a
-- real server value from the conservative substitute.
function MC_Config.liveSandbox(name, default)
    local namespace = type(SandboxVars) == "table"
        and SandboxVars.MongooseChat or nil
    local value = nil
    if type(namespace) == "table" then value = namespace[name] end
    if not validSandboxValue(sandboxSpecByKey[name], value) then
        MC_Incident.report("SANDBOX_VALUE_FALLBACK",
            "key=" .. tostring(name):gsub("[^%w_]", "_"):sub(1, 64))
        return default, false
    end
    return value, true
end

-- Enum value orders -- must match the sandbox-options definitions.
local DEATH_RESET_VALUES        = { "notify", "auto", "off" }
local ACQUISITION_SPEED_VALUES  = { "slow", "default", "fast" }
-- Only Character Model and Off are supported. The third entry preserves old
-- numeric save values conservatively as Off while the public enum has two
-- choices.
local BUBBLE_AVATAR_MODE_VALUES = { "model", "off", "off" }

-- Signing-gesture emote choices. Order matches the SignGestureDefault/
-- SignGestureYell enum options in sandbox-options.txt and their
-- Sandbox_EN.txt option labels -- all three lists must stay in lockstep.
-- Each string is a real vanilla emote name (ISEmoteRadialMenu.lua's
-- defaultMenu), playable via IsoGameCharacter:playEmote(name).
local SIGN_GESTURE_VALUES = {
    "shrug", "wavehi", "thankyou", "comehere", "stop",
    "salute", "surrender", "yes", "no", "thumbsup",
}

-- SANDBOX VARIABLE SPECS
-- Single source of truth for every sandbox-backed MC_Config value. Each
-- entry below drives BOTH the boot-time defaults (applied once, near the
-- bottom of this file) and reloadSandboxVars() -- the exact same loop over
-- the exact same list, so the two paths can never drift apart again.
--
--   section    - MC_Config sub-table name, or nil for a top-level field
--   field      - key within that section (or within MC_Config itself)
--   sandboxKey - name under SandboxVars.MongooseChat
--   default    - fallback value (offline harness / SandboxVars absent)
--   enumValues - if set, integer indices and exact string values are accepted
--   transform  - optional function(value) -> value, applied after resolution

local SANDBOX_SPECS = {
    -- Server-owned global connection notices. Both values are read live by
    -- the server poller; these entries provide typed defaults and validation.
    { section = "ConnectionNotifs", field = "enabled",
      sandboxKey = "EnableConnectionNotifs", default = true },
    { section = "ConnectionNotifs", field = "checkIntervalMs",
      sandboxKey = "ConnectionNotifsCheckInterval", default = 2000,
      integer = true, min = 1000, max = 60000 },

    -- Proximity speech
    { section = "Ranges", field = "whisper", sandboxKey = "WhisperRange", default = 2 },
    { section = "Ranges", field = "say",     sandboxKey = "SayRange",     default = 15 },
    { section = "Ranges", field = "yell",    sandboxKey = "YellRange",    default = 60 },
    { section = "Ranges", field = "low",     sandboxKey = "LowRange",     default = 6 },

    -- Roleplay channels. /emote stays at say range (an intimate, close-by
    -- action); /do now derives from yell range instead -- a room-echo of
    -- environment narration, reaching further than emote but not as wide
    -- as /event (see /event's own spec below, still double yell).
    { section = "Ranges", field = "emote", sandboxKey = "SayRange",  default = 15 },
    { section = "Ranges", field = "do",    sandboxKey = "YellRange", default = 60 },

    -- Meta channels (OOC derives from yell)
    { section = "Ranges", field = "ooc", sandboxKey = "YellRange", default = 60 },

    -- Admin event narration (v8.16.2). The storyteller's voice for
    -- long-range roleplay events: always DOUBLE the yell range, derived
    -- from the YellRange sandbox option so it scales with server
    -- configuration automatically -- no sandbox option of its own.
    -- (120 tiles at the default yell of 60.) Admin-gated in MC_Server.
    { section = "Ranges", field = "event", sandboxKey = "YellRange", default = 60,
      transform = function(v) return v * 2 end },

    -- Message length. Vanilla PZ caps its own chat box near 250;
    -- MongooseChat owns both the input box (client raises the box's max
    -- length to this) and the send path (server truncates past it), so
    -- this one sandbox value governs the real ceiling. Default 500; admins
    -- may raise it to 2000 for long emotes/narration.
    { section = nil, field = "MaxMessageLength", sandboxKey = "MaxMessageLength", default = 500 },

    -- Language acquisition -- v8.16.1 "Voices" addressedness heuristic.
    { section = "Lang", field = "addressedDistance", sandboxKey = "AddressedDistance", default = 6 },

    -- Language system master toggles
    { section = "Languages", field = "enabled",    sandboxKey = "LanguagesEnabled", default = true },
    { section = "Languages", field = "deathReset", sandboxKey = "LanguagesDeathReset",
      enumValues = DEATH_RESET_VALUES, default = "notify" },
    { section = "Acquisition", field = "speed", sandboxKey = "AcquisitionSpeed",
      enumValues = ACQUISITION_SPEED_VALUES, default = "default" },

    -- ASL (v1): the first per-language toggle, plus the Deaf-trait
    -- enforcement it depends on. Both read LIVE at their point of use
    -- (MC_LangCommands' speaking-language gate; MC_Anonymity.deafReception)
    -- rather than through the boot-time cache below -- same reasoning as
    -- Anonymity/Bubble: a server operator flipping either mid-session
    -- should take effect without a reconnect.
    { section = nil, field = "ASLEnabled",        sandboxKey = "ASLEnabled",        default = true },
    { section = nil, field = "DeafTraitEnforced",  sandboxKey = "DeafTraitEnforced", default = true },

    -- Speech bubbles
    { section = "Bubble", field = "enabled",  sandboxKey = "BubblesEnabled", default = true },
    { section = "Bubble", field = "duration", sandboxKey = "BubbleDuration", default = 5 },
    { section = "Bubble", field = "avatarMode", sandboxKey = "BubbleAvatarMode",
      enumValues = BUBBLE_AVATAR_MODE_VALUES, default = "model" },

    -- Typing indicators
    { section = "TypingIndicators", field = "enabled", sandboxKey = "TypingIndicatorsEnabled", default = true },

    -- Boredom reduction
    { section = "Boredom", field = "enabled",         sandboxKey = "BoredomReductionEnabled", default = true },
    { section = "Boredom", field = "reductionAmount", sandboxKey = "BoredomReductionAmount", default = 100 },

    -- Zombie attraction
    { section = "ZombieAttraction", field = "enabled", sandboxKey = "ZombieAttractionEnabled", default = true },

    -- Nameplates. visibility: 1 = Always (through walls), 2 = Line of Sight.
    -- Enum sandbox values are integers starting at 1. 2 = LOS is the current default.
    { section = "Nameplate", field = "enabled",    sandboxKey = "NameplatesEnabled", default = true },
    { section = "Nameplate", field = "hideOwn",    sandboxKey = "HideOwnNameplate", default = false },
    { section = "Nameplate", field = "visibility", sandboxKey = "NameplateVisibility", default = 2 },
    { section = "Nameplate", field = "crouchRange", sandboxKey = "NameplateCrouchRange", default = 3 },

    -- Anonymity
    { section = "Anonymity", field = "enabled", sandboxKey = "AnonymityEnabled", default = true },

    -- Channel toggles
    { section = "Channels", field = "oocEnabled", sandboxKey = "OOCEnabled", default = true },
    { section = "Channels", field = "allEnabled", sandboxKey = "ALLEnabled", default = true },

    -- Server-side chat/radio audit files contain player-authored content and
    -- identifying context. Public installs are therefore opt-in; integrations
    -- such as MongooseBot enable this explicitly in the server sandbox.
    { section = "Log", field = "enabled", sandboxKey = "ServerLoggingEnabled",
      default = false },

    -- The MongooseBot announcement inbox poller (0.9.8). Off by default:
    -- anything able to write the server's Zomboid folder can broadcast to
    -- every player, which is operator-level access.
    { section = "Announce", field = "fileEnabled", sandboxKey = "AnnounceFileEnabled",
      default = false },

    -- Signing gestures (v1). cooldownMs stores the sandbox's seconds value
    -- as milliseconds -- MC_SignGesture.consider() works in ms (matches
    -- MC_Core.getTimeMs()).
    { section = "SignGesture", field = "enabled", sandboxKey = "SignGestureEnabled", default = true },
    { section = "SignGesture", field = "cooldownMs", sandboxKey = "SignGestureCooldown", default = 5,
      transform = function(v) return v * 1000 end },
    { section = "SignGesture", field = "gestureDefault", sandboxKey = "SignGestureDefault",
      enumValues = SIGN_GESTURE_VALUES, default = "shrug" },
    { section = "SignGesture", field = "gestureYell", sandboxKey = "SignGestureYell",
      enumValues = SIGN_GESTURE_VALUES, default = "surrender" },

    -- Lore notes (v1): written literature items lying on the ground float
    -- their text in a persistent sign-style bubble. All three are read
    -- LIVE at point of use (MC_LoreNotes' tick) so an operator can flip or
    -- tune them mid-session; the entries here type-validate those live
    -- reads and document the defaults.
    { section = "LoreNotes", field = "enabled",   sandboxKey = "LoreNotesEnabled",  default = true },
    { section = "LoreNotes", field = "range",     sandboxKey = "LoreNoteRange",     default = 5 },
    { section = "LoreNotes", field = "maxLength", sandboxKey = "LoreNoteMaxLength", default = 280 },
    { section = "LoreNotes", field = "declutter", sandboxKey = "LoreNoteDeclutter", default = true },

    -- Features (0.10.0): whole modules a server can hand to another mod.
    -- Pass-through switches, read LIVE where cheap and from the cached
    -- section on the server. Default on; off means "someone else's work".
    { section = "Features", field = "chatWindow", sandboxKey = "ChatWindowEnabled", default = true },
    { section = "Features", field = "radio",      sandboxKey = "RadioEnabled",      default = true },
    { section = "Features", field = "radioStatic", sandboxKey = "RadioStaticEnabled", default = true },
    { section = "Features", field = "bio",        sandboxKey = "BioEnabled",        default = true },
    { section = "Features", field = "babbleHints", sandboxKey = "BabbleHintsEnabled", default = true },
    { section = "Features", field = "lipread",    sandboxKey = "LipreadEnabled",    default = true },
}

for _, spec in ipairs(SANDBOX_SPECS) do
    sandboxSpecByKey[spec.sandboxKey] =
        sandboxSpecByKey[spec.sandboxKey] or spec
end
MC_Config._sandboxSpecs = SANDBOX_SPECS

-- PROXIMITY RANGES
-- Distance in tiles for each chat channel. -1 = global/server-wide.
-- Sandbox-backed fields (whisper, say, yell, low, emote, do, ooc, event) are
-- populated from SANDBOX_SPECS above, applied by applySandboxDefaults() near
-- the bottom of this file. Static, non-sandbox fields only below.

MC_Config.Ranges = {
    mood = 0,           -- Internal monologue, self only

    -- Meta channels (OOC derives from yell; see SANDBOX_SPECS above)
    all = -1,           -- Server-wide OOC (global)
    admin = -1,         -- Server-wide admin messages

    -- Group channels. No membership filtering exists yet, so MC_Server
    -- REJECTS these in processMessage (with sender feedback) rather than
    -- routing range -1 as a server-wide broadcast. Client prefixes still
    -- map them; entries stay -1 for when filtering lands.
    faction = -1,       -- Faction members only
    safehouse = -1,     -- Safehouse members only

    -- Radio (range handled by transmitter, not this table)
    radio = -1,
}

-- MESSAGE LENGTH
-- MaxMessageLength is fully sandbox-backed; see SANDBOX_SPECS above. No
-- static declaration needed here -- applySandboxDefaults() sets it directly
-- on MC_Config.

-- LANGUAGE ACQUISITION (server-side heuristics)
-- addressedDistance is sandbox-backed; see SANDBOX_SPECS above. Proximity
-- speech heard from within this many tiles counts as addressed TO the
-- listener (full exposure weight); further out is overhearing (the
-- eavesdrop weight lives in MC_Acquisition). Conversational distance,
-- roughly the "low" speech range: stand with someone and you're in the
-- conversation; catch words across a room and you're eavesdropping.
-- Same-vehicle always counts as addressed regardless of this value.

MC_Config.Lang = {}

-- LANGUAGE SYSTEM (master toggles)
-- The RP language / babble system as a whole. Both fields sandbox-backed;
-- see SANDBOX_SPECS above.
--   enabled    - master switch for the language barrier system
--   deathReset - what happens when a brand-new character shows up on a
--                username that still carries language state from a
--                previous life:
--                  "notify" - tell them the old words carried over
--                  "auto"   - reset the carried-over state automatically
--                  "off"    - do nothing

MC_Config.Languages = {}

-- speed: "slow" | "default" | "fast" -- sandbox-backed, see SANDBOX_SPECS above.
MC_Config.Acquisition = {}

-- CHANNEL COLORS
-- RGB values 0-255 for each channel's text color

-- Channel colours live in MC_Theme (Chalk on Slate) and are AUDITED there
-- for colour-blind separation and contrast. This table is a live view: it
-- answers through MC_Theme.channel so the player's access mode (tags-only,
-- high contrast) applies everywhere a colour is read, with no caller
-- changing shape. Iterating it yields the base palette.
local MC_Theme = require("MC_Theme")
MC_Config.ChannelColors = setmetatable({}, {
    __index = function(_, name) return MC_Theme.channel(name) end,
    __pairs = function() return pairs(MC_Theme.Channels) end,
    __newindex = function() error("MC_Config.ChannelColors is read-only; edit MC_Theme") end,
})

-- CHANNEL DISPLAY TAGS
-- Text shown before messages in chat panel. Empty string = no tag.
-- Note: "radio" tag is generated dynamically with frequency (e.g., "[98.6 MHz]")

MC_Config.ChannelTags = {
    whisper = "[whisper]",
    say = "[say]",
    yell = "[YELL]",
    low = "[low]",
    emote = "",                     -- Format: *Name action*
    ["do"] = "",                    -- Format: just the narration text
    mood = "",                      -- Format: internal thought
    event = "[Event]",              -- Admin event narration (MC_Server scrubs the name)
    ooc = "[OOC]",
    all = "[ALL]",
    admin = "[ADMIN]",
    system = "",                     -- No tag, just "[SERVER]" as charName
    faction = "[faction]",
    safehouse = "[safehouse]",
    radio = "[RADIO]",              -- Fallback; actual tag includes MHz
}

-- RADIO SETTINGS

MC_Config.Radio = {
    -- Texture set for radio speech bubbles (see common/media/ui/MongooseChat/bubble/)
    bubbleStyle = "radio",

    -- Texture set for proximity speech bubbles
    speechBubbleStyle = "simple",
}

-- SPEECH BUBBLE SETTINGS
-- enabled, duration, avatarMode are sandbox-backed; see SANDBOX_SPECS above.
--   avatarMode fills the little portrait box in speech bubbles:
--     "model" - the speaker's 3D character model (current behavior)
--     "off"   - no portrait box at all

MC_Config.Bubble = {
    -- Bubble background opacity (0.0 - 1.0)
    opacity = 0.9,

    -- Maximum bubble width in pixels before word wrap
    maxWidth = 200,

    -- Widest a bubble may grow for a long message. Past a few lines a bubble
    -- reads better across than down, so MC_Bubble re-wraps between maxWidth
    -- and this before it keeps stacking lines. Set equal to maxWidth to keep
    -- every bubble the same width.
    maxWidthWide = 340,

    -- Fade out duration at end of bubble life (seconds)
    fadeTime = 1.0,

    -- Show the 3D character model in speech bubbles (not emotes/radio)
    showAvatar = true,

    -- Texture set for a SIGNED-modality speech bubble (see
    -- common/media/ui/MongooseChat/bubble/) -- style resolution gains this
    -- modality case beside MC_Config.Radio's per-channel choice above.
    signStyle = "sign",

    -- Skin-only alpha multiplier for lore-note bubbles (0.0 - 1.0), applied on
    -- top of `opacity` and the proximity fade. Lore notes sit on the ground for
    -- as long as a player is near them, so a near-solid sign hides the floor
    -- behind it; dimming the skin lets the world read through. Text alpha is
    -- deliberately NOT scaled by this -- the note stays as legible as before.
    signSkinAlphaScale = 0.7,
}

-- LORE NOTE SETTINGS
-- Written literature items on the ground float their text (MC_LoreNotes).
-- All fields sandbox-backed; see SANDBOX_SPECS above.

MC_Config.LoreNotes = {}
MC_Config.Features = {}
MC_Config.ConnectionNotifs = {}

--[[
    Feature switches are pass-through and quiet: a module is OFF only when
    the server has set its switch to false. A missing value (older server,
    offline fixture) means on, with no incident -- absence is not damage
    here, unlike the security-relevant reads that go through liveSandbox.
]]
function MC_Config.featureOn(sandboxKey)
    local ok, value = pcall(function()
        return SandboxVars and SandboxVars.MongooseChat
            and SandboxVars.MongooseChat[sandboxKey]
    end)
    if ok and value == false then return false end
    return true
end

-- Quiet live read for optional presentation/channel switches. The cached
-- value came from the validated sandbox-spec reload; a live boolean wins when
-- present. Unlike liveSandbox(), this is not for safety or privacy gates and
-- does not turn an older/missing key into a player-visible incident.
function MC_Config.optionalOn(sandboxKey, cachedValue)
    local ok, value = pcall(function()
        return SandboxVars and SandboxVars.MongooseChat
            and SandboxVars.MongooseChat[sandboxKey]
    end)
    if ok and type(value) == "boolean" then return value end
    return cachedValue ~= false
end

-- TYPING INDICATOR SETTINGS
-- Animated dots above players who are typing.
-- enabled is sandbox-backed; see SANDBOX_SPECS above.

MC_Config.TypingIndicators = {}

-- CHAT PANEL SETTINGS

MC_Config.Panel = {
    -- Maximum messages kept in history buffer (per tab)
    maxMessages = 100,

    -- Wrap-width fallback when the panel reports an unreasonably narrow
    -- width (MC_ChatPanel.lua ~669) -- not a panel dimension itself.
    defaultWidth = 400,

    -- Margin around text content
    margin = 8,

    -- Timestamp format (strftime compatible)
    -- os.date fallback format only (0.9.8): the live render path formats
    -- through Calendar in the viewer's local zone; this is used when
    -- Calendar is unavailable.
    timestampFormat = "[%H:%M]",
}

-- BOREDOM REDUCTION
-- Listening to chat reduces boredom (rewards RP engagement)
-- Both settings sandbox-backed; see SANDBOX_SPECS above.

MC_Config.Boredom = {}

-- ZOMBIE ATTRACTION
-- Speaking attracts zombies based on channel volume.
-- enabled is sandbox-backed; see SANDBOX_SPECS above.

MC_Config.ZombieAttraction = {}

-- NAMEPLATE SETTINGS
-- Character name and tagline display above players.
-- All three fields sandbox-backed; see SANDBOX_SPECS above.

MC_Config.Nameplate = {}

-- ANONYMITY
-- Distance/mask based name hiding for roleplay
-- enabled is sandbox-backed; see SANDBOX_SPECS above.

MC_Config.Anonymity = {}

-- CHANNEL TOGGLES
-- Enable/disable specific chat channels.
-- Both fields sandbox-backed; see SANDBOX_SPECS above.

MC_Config.Channels = {}

-- SIGNING GESTURES (v1)
-- A signed (ASL) message the local player sends plays a hand-gesture emote
-- on their own avatar -- presentation only. All four fields sandbox-backed;
-- see SANDBOX_SPECS
-- above.
--   enabled        - master toggle
--   cooldownMs     - minimum time between fires, in milliseconds
--   gestureDefault - emote name for say/whisper/low (subtle)
--   gestureYell    - emote name for yell / sign-shout (big, emphatic)
-- Decision logic (own-message check, modality, cooldown) lives in the pure
-- shared/MC_SignGesture.lua; client/MC_Client.lua is the thin glue that
-- calls it and fires the real playEmote().

MC_Config.SignGesture = {}

-- SERVER-SIDE LOGGING
-- Opt-in for MongooseBot integration and operator audit trails. These files
-- contain personal/player-authored data and have no automatic retention.

MC_Config.Log = {
    -- Sandbox-backed; conservative boot/default posture is disabled.
    enabled = false,

    -- Log file directory (relative to Zomboid user folder)
    path = "MongooseChat/logs/",

    -- Output structured JSON (for bot parsing) vs plain text
    jsonFormat = true,
}

-- SERVER-WIDE ANNOUNCEMENTS (0.9.8)
-- One fixed broadcast identity for /announce and the MongooseBot inbox.
-- The label is deliberately NOT the admin's name: like /event, the
-- announcer may be standing masked among the players (anonymity is a
-- headline mechanic), so the wire carries no identity -- the audit log
-- (when server logging is on) keeps all of it.

MC_Config.Announce = {
    author = "[Announcement]",      -- fixed broadcast label; never the admin's name
    color  = {255, 220, 100},       -- system gold (matches Colors.system)

    -- MongooseBot inbox (relative to the Zomboid user folder, sibling of
    -- Log.path). Sandbox-backed fileEnabled gates the poller; conservative
    -- default is off -- anything able to write the server's Zomboid folder
    -- can broadcast to every player, which is operator-level access.
    fileEnabled = false,
    inboxFile = "MongooseChat/announce_inbox.txt",
}

-- SANDBOX VAR RELOAD
-- MC_Config is require()'d at startup, BEFORE SandboxVars is populated from
-- the server in MP. applySandboxDefaults() below seeds every sandbox-backed
-- field (SANDBOX_SPECS) with its fallback default at load time.
--
-- To pick up the server's actual sandbox configuration, reloadSandboxVars()
-- must be called after the sandbox sync completes. This happens in:
--   - Server:  Events.OnServerStarted  (see MC_Server.lua)
--   - Client:  Events.OnGameStart + Events.OnConnected  (see MC_Client.lua)
--
-- It is safe to call multiple times. A reload with missing/malformed values
-- uses conservative defaults, returns false, and emits one aggregated
-- SANDBOX_CONFIG_FALLBACK incident. Both the initial load and reload run the
-- exact same loop over SANDBOX_SPECS, so the two paths cannot drift apart.

local function resolveSandboxSpec(spec)
    local namespace = type(SandboxVars) == "table"
        and SandboxVars.MongooseChat or nil
    local raw = nil
    if type(namespace) == "table" then
        raw = namespace[spec.sandboxKey]
    end
    local authoritative = validSandboxValue(spec, raw)
    local value = spec.default
    if authoritative then value = raw end
    if spec.enumValues and type(value) == "number" then
        value = spec.enumValues[value]
    end
    if spec.transform then
        local ok, transformed = pcall(spec.transform, value)
        if not ok or transformed == nil then
            authoritative = false
            local defaultOk, defaultValue =
                pcall(spec.transform, spec.default)
            value = defaultOk and defaultValue or spec.default
        else
            value = transformed
        end
    end
    return value, authoritative
end

local function applySandboxDefaults(reportFallback)
    local problemKeys = {}
    sandboxKeyStatus = {}
    for _, spec in ipairs(SANDBOX_SPECS) do
        local value, authoritative = resolveSandboxSpec(spec)
        local prior = sandboxKeyStatus[spec.sandboxKey]
        sandboxKeyStatus[spec.sandboxKey] =
            (prior == nil or prior == true) and authoritative
        if not authoritative then
            problemKeys[spec.sandboxKey] = true
        end
        local target = spec.section and MC_Config[spec.section] or MC_Config
        target[spec.field] = value
    end
    local count = 0
    for _ in pairs(problemKeys) do count = count + 1 end
    if reportFallback and count > 0 then
        MC_Incident.report("SANDBOX_CONFIG_FALLBACK",
            "missing_or_invalid=" .. tostring(count))
    end
    return count == 0
end

-- Apply boot-time defaults now (SandboxVars is not yet populated at
-- require() time, so this seeds every sandbox-backed field with its
-- fallback default).
applySandboxDefaults(false)
MC_Config.sandboxAuthoritative = false

function MC_Config.reloadSandboxVars()
    MC_Config.sandboxAuthoritative = applySandboxDefaults(true)

    dbg("Sandbox vars reloaded: BubbleDuration=%s, SayRange=%s, BubblesEnabled=%s, Anon=%s",
        tostring(MC_Config.Bubble.duration),
        tostring(MC_Config.Ranges.say),
        tostring(MC_Config.Bubble.enabled),
        tostring(MC_Config.Anonymity.enabled))
    return MC_Config.sandboxAuthoritative
end

function MC_Config.isSandboxAuthoritative()
    return MC_Config.sandboxAuthoritative == true
end

function MC_Config.isSandboxKeyAuthoritative(name)
    return sandboxKeyStatus[name] == true
end


dbg("Configuration loaded")

return MC_Config
