-- MC_Resolve -- concept->L2 resolution algorithm for the concept-keyed lex pipeline.
--
-- WHAT THIS IS
-- The render path asks "what does the speaker's palette say in L2?" for an
-- English token. Pre-pivot this was a direct hash lookup against
-- palette.dictionary; now the token resolves to concept ID(s) (via
-- MC_Concepts), looked up in the palette's `lex` table, walking the concept's
-- parent tree breadth-first if the palette doesn't lexicalize it directly.
-- Pure module, no PZ dependencies; tested via the `resolve` scenario.
--
-- PUBLIC API
--   M.resolve(english_token, palette)       -> l2_form|nil  (fast path, for
--                                               inline substitution)
--
-- PALETTE SCHEMA (concept-keyed)
-- palette.lex is concept-keyed: { WATER = { l2 = "eau" }, FOOD = { l2 =
-- "nourriture" }, ... }. Otherwise identical to v8.x palette schema (onsets,
-- codas, signatureSet, etc).
--
-- ALGORITHM
-- resolve(token, palette):
--   1. MC_Concepts.byEnglish(token) -> candidate concept IDs; none -> nil
--      (renders as plain English).
--   2. For each candidate (alphabetical order): direct palette.lex[id] hit,
--      else BFS parents up to MAX_WALK_DEPTH for a lexicalized ancestor.
--   3. No candidate resolves -> nil (speaker says English).
--
-- Alphabetical trial order matters: byEnglish("drink") -> {BEVERAGE, DRINK};
-- a palette lexicalizing only DRINK still resolves, because the BEVERAGE
-- attempt fails clean (no lex entry, no parents to fall back through)
-- before DRINK is tried.

local Concepts = require("MC_Concepts")

local M = {}

-- palette.lex[conceptId] -> l2 string or nil (tolerates a missing lex field cleanly).
local function lexLookup(palette, conceptId)
    if not palette or type(palette.lex) ~= "table" then return nil end
    local entry = palette.lex[conceptId]
    if entry == nil then return nil end
    if type(entry) ~= "table" then return nil end
    if type(entry.l2) ~= "string" or entry.l2 == "" then return nil end
    return entry.l2
end

-- Resolves one candidate concept. Detail record on success, nil on failure:
--   { l2, conceptId, source = "direct"|"fallback", path = {"WATER", "DRINK", ...} }
-- path traces the walk from the queried concept to the one whose lex entry
-- was used (one element for a direct match).
local function tryOneCandidate(palette, conceptId)
    local direct = lexLookup(palette, conceptId)
    if direct then
        return {
            l2 = direct,
            conceptId = conceptId,
            source = "direct",
            path = {conceptId},
        }
    end

    -- Unconditional BFS walk up the concept's parent tree.
    local ancestors = Concepts.walkParents(conceptId)
    for _, ancestorId in ipairs(ancestors) do
        local ancestorL2 = lexLookup(palette, ancestorId)
        if ancestorL2 then
            -- Path: queried concept + ancestors visited up to and including the match.
            local path = {conceptId}
            for _, a in ipairs(ancestors) do
                path[#path + 1] = a
                if a == ancestorId then break end
            end
            return {
                l2 = ancestorL2,
                conceptId = ancestorId,
                source = "fallback",
                path = path,
            }
        end
    end

    return nil
end

-- Fast path: l2 string, or nil (no concept match, or none lexicalized).
function M.resolve(english_token, palette)
    if type(english_token) ~= "string" or english_token == "" then return nil end
    if type(palette) ~= "table" then return nil end

    local candidates = Concepts.byEnglish(english_token)
    if candidates == nil then return nil end

    for _, conceptId in ipairs(candidates) do
        local hit = tryOneCandidate(palette, conceptId)
        if hit then return hit.l2 end
    end

    return nil
end

-- INTROSPECTION HELPERS
-- Not on the render path -- reverse lookups for /lex and other consumers
-- that need L2-form-to-concept or concept-to-L1-alias mapping.

-- l2_lower -> conceptId, cached on the palette (`_reverseLex`); shared by the
-- acquisition pass and the learner-speaker comprehension path (each used to
-- rebuild their own). Returns the map directly -- callers shouldn't mutate it.
-- Iteration is over SORTED concept ids, first writer wins: conflated forms
-- (41 in current data, e.g. ay = MONTH/MOON) resolve to a stable canonical
-- concept (lowest conceptId) rather than pairs()'s undefined order. This is
-- the authoritative statement of that tie-break; MC_Teaching.findL2InDictionary
-- cites it rather than re-deriving it for diacritic fold-homographs. Every
-- concept behind a form lives in reverseLexAll below.
function M.reverseLex(palette)
    if type(palette) ~= "table" then return {} end
    if palette._reverseLex then return palette._reverseLex end
    local reverse = {}
    if type(palette.lex) == "table" then
        local ids = {}
        for conceptId in pairs(palette.lex) do ids[#ids + 1] = conceptId end
        table.sort(ids)
        for _, conceptId in ipairs(ids) do
            local entry = palette.lex[conceptId]
            if type(entry) == "table"
                and type(entry.l2) == "string" and entry.l2 ~= "" then
                local key = entry.l2:lower()
                if reverse[key] == nil then
                    reverse[key] = conceptId
                end
            end
        end
    end
    palette._reverseLex = reverse
    return reverse
end

-- l2_lower -> sorted list of ALL concept ids the form lexicalizes. Singleton
-- for most forms; conflation cases (FOOD=EAT=yemek, HIT=SHOOT=vurmak, ...)
-- carry every sense so /lex can gloss them honestly, not arbitrarily.
function M.reverseLexAll(palette)
    if type(palette) ~= "table" then return {} end
    if palette._reverseLexAll then return palette._reverseLexAll end
    local reverse = {}
    if type(palette.lex) == "table" then
        for conceptId, entry in pairs(palette.lex) do
            if type(entry) == "table"
                and type(entry.l2) == "string" and entry.l2 ~= "" then
                local key = entry.l2:lower()
                local list = reverse[key]
                if not list then
                    list = {}
                    reverse[key] = list
                end
                list[#list + 1] = conceptId
            end
        end
        for _, list in pairs(reverse) do
            table.sort(list)
        end
    end
    palette._reverseLexAll = reverse
    return reverse
end

-- L2 form (any case) -> concept ID it lexicalizes, or nil.
function M.l2ToConcept(l2_form, palette)
    if type(l2_form) ~= "string" or l2_form == "" then return nil end
    local rev = M.reverseLex(palette)
    return rev[l2_form:lower()]
end

-- l2_lower -> primary L1 English alias, derived from reverseLex via
-- MC_Concepts. Consumed by MC_LangCommands (the /lex display). Cached
-- (`_reverseLexL1`) so repeat consumers share the work.
function M.reverseLexL1(palette)
    if type(palette) ~= "table" then return {} end
    if palette._reverseLexL1 then return palette._reverseLexL1 end
    local Concepts = require("MC_Concepts")
    local conceptMap = M.reverseLex(palette)
    local out = {}
    for l2_lower, conceptId in pairs(conceptMap) do
        local concept = Concepts.get(conceptId)
        if concept and concept.en and concept.en[1] then
            out[l2_lower] = concept.en[1]
        end
    end
    palette._reverseLexL1 = out
    return out
end

return M
