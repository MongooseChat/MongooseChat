-- MC_LangRegistry -- language palette registration.
--
-- WHY THIS EXISTS
-- Adding a new language used to require editing MC_Lang in three places: the
-- PALETTES require table, the LANGUAGES known-set, and the error messages
-- that hardcoded "Available: english, french, slavic". That's three sites of
-- coupling for every new palette.
--
-- This registry inverts the dependency: palette files declare themselves
-- *into* the language system, instead of MC_Lang reaching *out* for them.
-- Drop a new palette file in shared/, give it a register() call at the
-- bottom, and the system picks it up -- no MC_Lang edits.
--
-- USAGE -- defining a new palette
--
--   -- File: MC_Palette_German.lua (in shared/)
--   local german = {
--       name = "German",
--       tuning = { ... },
--       onsets = { ... },
--       nuclei = { ... },
--       codas = { ... },
--       functionWords = { ... },
--       elisionPrefixes = { ... },
--       signatureSet = { ... },
--   }
--   require("MC_LangRegistry").register("german", german)
--   return german
--
-- That's all. The palette is now selectable via `/lang german`, included
-- in error-message listings, etc.
--
-- ENGLISH
-- English is the universal baseline -- no palette, no transform, everyone
-- understands. It's always a known language but has no registered palette.
-- `getPalette("english")` returns nil; `isKnownLanguage("english")` returns true.
--
-- PUBLIC API
--   M.register(name, palette)         -- palette files self-register
--   M.getPalette(name)        -> palette|nil
--   M.getModality(name)       -> "signed"|"spoken"|nil
--   M.isKnownLanguage(name)   -> bool
--   M.listLanguages()         -> sorted list of language names

local M = {
    -- Registered palettes by lowercase name. English is omitted (no palette).
    palettes = {},
    -- Set of known language names. English is implicit (baseline).
    languages = { english = true },
    -- Safety-relevant language metadata is independent of palette payload
    -- availability. In particular, a missing/failed ASL palette must never
    -- turn a persisted signed identity into ordinary spoken plaintext.
    metadata = {
        english = { modality = "spoken", displayName = "English" },
        asl = { modality = "signed", displayName = "ASL", intrinsic = true },
    },
}

-- VALIDATION
-- Catch palette-shape mistakes (typos, missing required fields) at register
-- time rather than letting bad data silently produce bad babble. Returns
-- (true, nil) on success or (false, errorMessage) on a structural problem.
--
-- This is intentionally permissive -- only checks what would cause babble
-- failures, not stylistic concerns. Optional integration-layer fields
-- (lex/zipf) are checked for *shape* if present but are not required: a
-- phonetic-only palette without acquisition support is a legitimate use
-- case. the concept-tree schema actively rejects the pre-pivot fields (dictionary,
-- lexicalSets) with a migration-hint error so authors carrying old
-- palettes upgrade rather than silently lose features.

local function isStringList(t)
    if type(t) ~= "table" then return false end
    local count = 0
    local maxIndex = 0
    for key, value in pairs(t) do
        if type(key) ~= "number" or key <= 0 or key % 1 ~= 0
            or type(value) ~= "string" then
            return false
        end
        count = count + 1
        if key > maxIndex then maxIndex = key end
    end
    return maxIndex == count
end

-- Validate palette.lex shape (concept-keyed table). Shared by the spoken
-- palette's OPTIONAL lex and the signed palette's REQUIRED lex -- same
-- shape either way, just a different presence rule at the call site.
local function validateLexField(lex)
    if type(lex) ~= "table" then
        return false, "palette.lex must be a table"
    end
    local Concepts = require("MC_Concepts")
    for conceptId, entry in pairs(lex) do
        if type(conceptId) ~= "string" then
            return false, string.format(
                "palette.lex has non-string key %s", tostring(conceptId))
        end
        if not Concepts.has(conceptId) then
            return false, string.format(
                "palette.lex['%s'] is not a known concept (check MC_Concepts)",
                conceptId)
        end
        if type(entry) ~= "table" then
            return false, string.format(
                "palette.lex['%s'] must be a table { l2 = ... }", conceptId)
        end
        if type(entry.l2) ~= "string" or entry.l2 == "" then
            return false, string.format(
                "palette.lex['%s'].l2 must be a non-empty string", conceptId)
        end
        -- Extra keys on a lex entry beyond l2 aren't enforced at
        -- validation time -- ignored rather than rejected, so an older
        -- third-party palette carrying now-unused fields still loads.
    end
    return true, nil
end

-- Validate a SIGNED-modality palette. ASL is a real language, not a
-- dummy-pooled spoken palette in a costume: `gestures` (the babble-
-- equivalent surface pool) and `lex` (concept -> gloss) are REQUIRED, and
-- the four phonology pools are refused if present -- no half-modality
-- palette can declare both a syllable alphabet and a gesture pool.
local function validateSignedPalette(palette)
    for _, field in ipairs({"onsets", "nuclei", "codas", "functionWords"}) do
        if palette[field] ~= nil then
            return false, string.format(
                "palette.%s must not be set on a signed-modality palette " ..
                "(modality=\"signed\" has no phonology pools)", field)
        end
    end
    if not isStringList(palette.gestures) or #palette.gestures == 0 then
        return false, "palette.gestures must be a non-empty list of strings (signed modality)"
    end
    if palette.lex == nil then
        return false, "palette.lex is required on a signed-modality palette"
    end
    local ok, err = validateLexField(palette.lex)
    if not ok then return false, err end

    -- iconic: capped conceptId -> hint-string map. Optional but
    -- shape-checked if present, same spirit as the spoken palette's
    -- optional fields below.
    if palette.iconic ~= nil then
        if type(palette.iconic) ~= "table" then
            return false, "palette.iconic must be a table if present"
        end
        for conceptId, hint in pairs(palette.iconic) do
            if type(conceptId) ~= "string" or type(hint) ~= "string" or hint == "" then
                return false, "palette.iconic entries must be conceptId -> non-empty hint string"
            end
        end
    end
    if palette.zipf ~= nil and not isStringList(palette.zipf) then
        return false, "palette.zipf must be a list of strings if present"
    end
    return true, nil
end

-- Validate a palette's shape. Required fields are the engine inputs;
-- optional fields are checked for shape only if present.
function M.validate(palette)
    if type(palette) ~= "table" then
        return false, "palette must be a table"
    end

    -- Required: name (for diagnostics) and the four content pools.
    if type(palette.name) ~= "string" or palette.name == "" then
        return false, "palette.name must be a non-empty string"
    end

    -- Optional display-name override (e.g. "ASL" for an acronym language
    -- that shouldn't fall through to the default Title-Case of its key).
    -- Checked ahead of the modality branch so it applies uniformly to both
    -- spoken and signed palettes.
    if palette.displayName ~= nil and
       (type(palette.displayName) ~= "string" or palette.displayName == "") then
        return false, "palette.displayName must be a non-empty string if present"
    end

    -- concept-tree removal: palette.dictionary and palette.lexicalSets no longer
    -- exist on the schema. The dictionary is replaced by palette.lex
    -- (concept-keyed). Lexical sets are declared centrally in
    -- MC_Concepts.lua and read cross-language by the Connection bonus.
    -- A palette that still declares these fields is presumed to be
    -- pre-pivot and gets rejected with a migration hint. Checked before the
    -- modality branch -- the rule applies to any palette shape.
    if palette.dictionary ~= nil then
        return false, "palette.dictionary is removed in the concept-tree schema -- migrate to " ..
            "palette.lex (concept-keyed). See docs/ARCHITECTURE.md."
    end
    if palette.lexicalSets ~= nil then
        return false, "palette.lexicalSets is removed in the concept-tree schema -- sets are " ..
            "declared centrally in MC_Concepts.lua. See docs/ARCHITECTURE.md."
    end

    -- Signed arm: a wholly different required-field shape, not the
    -- spoken engine's phonology pools. See validateSignedPalette above.
    if palette.modality == "signed" then
        return validateSignedPalette(palette)
    end

    for _, field in ipairs({"onsets", "nuclei", "codas", "functionWords"}) do
        if not isStringList(palette[field]) then
            return false, string.format(
                "palette.%s must be a list of strings (likely typo in field name?)",
                field)
        end
    end

    -- Optional but type-checked if present.
    if palette.elisionPrefixes ~= nil and not isStringList(palette.elisionPrefixes) then
        return false, "palette.elisionPrefixes must be a list of strings if present"
    end
    if palette.tuning ~= nil and type(palette.tuning) ~= "table" then
        return false, "palette.tuning must be a table if present"
    end
    if palette.signatureSet ~= nil and type(palette.signatureSet) ~= "table" then
        return false, "palette.signatureSet must be a table if present"
    end

    -- Integration-layer fields (acquisition):
    -- palette.lex is a concept-keyed table:
    --   { CONCEPT_ID = { l2 = "form" }, ... }
    -- The keys must be valid concept IDs declared in MC_Concepts. Entries
    -- with unknown concept IDs are flagged loudly and the palette is
    -- refused -- better to fail registration than to ship a palette that
    -- silently mis-resolves. Optional for a spoken palette (a phonetic-only
    -- palette without acquisition support is a legitimate use case).
    if palette.lex ~= nil then
        local ok, err = validateLexField(palette.lex)
        if not ok then return false, err end
    end
    if palette.zipf ~= nil and not isStringList(palette.zipf) then
        return false, "palette.zipf must be a list of strings if present"
    end

    return true, nil
end

function M.register(name, palette)
    if type(name) ~= "string" or type(palette) ~= "table" then
        return false, "register requires string name and table palette"
    end
    local key = name:lower()
    local paletteModality = palette.modality == "signed" and "signed" or "spoken"
    local declared = M.metadata[key]
    if declared and declared.modality and declared.modality ~= paletteModality then
        local err = string.format(
            "palette modality '%s' conflicts with intrinsic '%s' metadata",
            paletteModality, declared.modality)
        print(string.format(
            "[MongooseChat] WARNING: palette '%s' failed validation: %s. " ..
            "Palette will not be registered.", tostring(name), err))
        return false, err
    end
    local ok, err = M.validate(palette)
    if not ok then
        -- Log loudly and refuse the registration; bad palette won't crash the
        -- server but won't be selectable either. Player-facing /lang error
        -- listing will simply not include it.
        print(string.format(
            "[MongooseChat] WARNING: palette '%s' failed validation: %s. " ..
            "Palette will not be registered.", tostring(name), tostring(err)))
        return false, err
    end

    -- Retain modality/display metadata even if the palette table later becomes
    -- unavailable. ASL's entry is intrinsic above; dynamically registered
    -- languages gain the same stable identity after their first valid load.
    local metadata = declared or {}
    metadata.modality = paletteModality
    if type(palette.displayName) == "string" and palette.displayName ~= "" then
        metadata.displayName = palette.displayName
    end
    M.metadata[key] = metadata
    M.palettes[key] = palette
    M.languages[key] = true
    return true, nil
end

function M.getPalette(name)
    if type(name) ~= "string" then return nil end
    return M.palettes[name:lower()]
end

-- Physical modality is language identity, not palette payload. This remains
-- available when a palette fails validation, is absent from the build, or
-- becomes unavailable after persisted character state has selected it.
function M.getModality(name)
    if type(name) ~= "string" then return nil end
    local metadata = M.metadata[name:lower()]
    return metadata and metadata.modality or nil
end

function M.isKnownLanguage(name)
    if type(name) ~= "string" then return false end
    return M.languages[name:lower()] == true
end

-- Returns a sorted list of all known language names (including english).
-- Used for dynamic error messages so "Available: ..." stays accurate as
-- palettes are added without anyone updating string literals.
function M.listLanguages()
    local list = {}
    for name in pairs(M.languages) do
        list[#list + 1] = name
    end
    table.sort(list)
    return list
end

-- DISPLAY NAME
-- Player-facing form of a language name. Defaults to Title-Case of the
-- (always-lowercase) registry key -- "french" -> "French" -- which reads
-- correctly for an ordinary word but mangles an acronym ("asl" -> "Asl"
-- instead of "ASL"). A palette opts out of the default by setting its own
-- palette.displayName ("ASL" for the ASL palette); that value wins whenever
-- present. English has no palette, so it always falls through to Title-Case
-- ("English"), which is already correct for it. This is the single source
-- every player-facing surface should route a language name through, rather
-- than each call site re-deriving its own capitalization.
--
-- ORPHANED KEYS (2026-07-08): a native-language grant or a legacy
-- `speaking` value is stored durably (MongooseChat/MC_Languages_a/b.txt), independent
-- of the registry -- a palette can be renamed or removed from a later
-- build while a character's record still carries the old key ("japonic",
-- say). Every caller here ultimately traces back to either a stored
-- native-language set (MC_Lang.getNativeLanguages) or a stored speaking
-- choice (MC_Lang.getLanguage), NEITHER of which is revalidated against
-- the registry on load -- so an orphaned key must still render (never
-- silently dropped, never crashed on: it still Title-Cases or resolves an
-- override exactly as before), but honestly marked as no longer a real,
-- selectable language, so it reads as a data fact instead of passing for
-- an ordinary one. Never mutates the stored key -- display-only; see
-- MC_Lang.pruneOrphanedNatives for the deliberate admin cleanup act.

function M.displayName(name)
    if type(name) ~= "string" or name == "" then return name end
    local palette = M.getPalette(name)
    local metadata = M.metadata[name:lower()]
    local base
    if palette and type(palette.displayName) == "string" and palette.displayName ~= "" then
        base = palette.displayName
    elseif metadata and type(metadata.displayName) == "string"
        and metadata.displayName ~= ""
    then
        base = metadata.displayName
    else
        base = name:sub(1, 1):upper() .. name:sub(2)
    end
    if M.isKnownLanguage(name) then
        return base
    end
    return base .. " (no longer spoken here)"
end

-- UNIQUE-PREFIX MATCHING (E1 ergonomics, 2026-07-08)
-- The single source of truth for "does this typed token resolve to a
-- language" everywhere a language name is accepted: /lang set, /forget,
-- admin grant/revoke (MC_LangCommands.lua), and the one-shot "@<prefix>"
-- speech override (MC_Server.lua). A player types "fr" and means "french" --
-- this makes that resolve wherever a full language name would, without
-- forcing every call site to reimplement its own matching.
--
-- M.matchLanguage(input, candidates) -> kind, result
--   input       raw player-typed token (any case)
--   candidates  list of lowercase language keys to match against (defaults
--               to M.listLanguages() -- the full known-language set)
--
--   kind == "exact"     result = the matched language (exact names ALWAYS
--                                 win over prefix logic, even if the same
--                                 string is also an ambiguous prefix of
--                                 something else)
--   kind == "prefix"    result = the one language `input` uniquely prefixes
--   kind == "ambiguous" result = sorted list of every language `input`
--                                 prefixes (2 or more)
--   kind == "none"      result = nil (no exact or prefix match at all)

function M.matchLanguage(input, candidates)
    if type(input) ~= "string" or input == "" then return "none", nil end
    local needle = input:lower()
    local pool = candidates or M.listLanguages()

    for _, lang in ipairs(pool) do
        if lang == needle then return "exact", lang end
    end

    local matches = {}
    for _, lang in ipairs(pool) do
        if #lang >= #needle and lang:sub(1, #needle) == needle then
            matches[#matches + 1] = lang
        end
    end
    table.sort(matches)

    if #matches == 1 then return "prefix", matches[1] end
    if #matches > 1 then return "ambiguous", matches end
    return "none", nil
end

-- Shortest prefix of `lang` that uniquely resolves back to `lang` via
-- matchLanguage against `candidates` (defaults to M.listLanguages()). Used
-- to teach the E1 shortcuts in language-listing displays ("french (fr)").
-- Falls back to the full name itself when no shorter prefix is unique
-- (e.g. `lang` is itself a prefix of a longer sibling name) -- callers
-- should treat prefix == lang as "no shortcut, don't bother showing one".
function M.shortestUniquePrefix(lang, candidates)
    if type(lang) ~= "string" then return lang end
    local pool = candidates or M.listLanguages()
    for len = 1, #lang - 1 do
        local candidate = lang:sub(1, len)
        local kind, result = M.matchLanguage(candidate, pool)
        if (kind == "exact" or kind == "prefix") and result == lang then
            return candidate
        end
    end
    return lang
end

return M
