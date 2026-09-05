-- MC_Concepts -- Tier 1 universal concept table for concept-tree architecture.
--
-- WHAT THIS IS
-- The concept-tree pivot moves palettes from L1-keyed dictionaries
-- (palette.dictionary["water"] = "eau") to concept-keyed lex tables
-- (palette.lex.WATER = { l2 = "eau" }), backed by a universal concept tree
-- grounded in First Contact methodology (NSM semantic primes, Leipzig-Jakarta,
-- Swadesh, Berlin-Kay, Ekman).
--
-- This module owns the tree's runtime API (lookup, parent walks, lexical
-- sets); the schema is documented inline below. The deeper design rationale
-- (category reasoning, lock decisions) lived in CONCEPT_TREE.md, lost with an
-- ephemeral workspace and never recovered (see docs/ARCHITECTURE.md). Concept
-- DATA lives in data/concepts.tsv, generated into MC_ConceptsData.lua by
-- devtools/generate_concepts.py and required below.
--
-- WHY THIS MATTERS
-- Pre-pivot, every palette redeclared its own L1->L2 dictionary -- that
-- "water" is the universal concept WATER lived only in author convention.
-- The concept tree makes universality explicit: palettes lexicalize a shared
-- concept space, resolution walks the tree for a fallback when a palette
-- doesn't declare a direct match, and the Connection feature's lexical sets
-- become language-agnostic semantic claims rather than L2-form coincidences.
--
-- PUBLIC API
--   M.MAX_WALK_DEPTH                   -- cap on parent walk depth
--   M.concepts                         -- the raw table (read-only by convention)
--   M.lexicalSets                      -- semantic sets (data-sourced from TSV)
--
--   M.get(id)                  -> entry|nil       fetch by ID
--   M.has(id)                  -> bool            existence check
--   M.byEnglish(token)         -> {ids...}|nil    reverse parser, sorted
--   M.walkParents(id, maxDepth)-> {ids...}        BFS ancestors (excludes self)
--   M.setsForConcept(id)       -> {setNames...}   which lexical sets contain id
--   M.allIds()                 -> {ids...}        sorted list of all ids
--   M.validate()               -> ok, errs        structural sanity check
--
-- INVARIANTS (enforced by validate(), which runs at first use of any API)
-- 1. Every entry has tier (number), en (non-empty string list), parents (id list).
-- 2. Every parent ID exists in the concepts table.
-- 3. Every lexicalSets member ID exists in the concepts table.
-- 4. Parent chain is acyclic (BFS terminates within MAX_WALK_DEPTH).
-- 5. English aliases are lowercase-comparable (the parser lowercases on lookup).
--
-- Violations produce a single loud warning at first API call. The table
-- still loads; broken concepts may behave oddly but won't crash the engine.

local M = {}

M.MAX_WALK_DEPTH = 5

-- THE CONCEPT TABLE
-- Entry shape:
--   ID = { tier = N, en = { "english", "aliases" }, parents = { "PARENT" },
--          splits = { "SPLIT_ID", ... }     -- optional, advisory only
--        }

-- The concept table AND lexical sets are GENERATED from data/concepts.tsv into
-- MC_ConceptsData.lua (sets declared per-concept via the `sets` column,
-- inverted by the generator). Run `python3 devtools/generate_concepts.py`
-- after editing the TSV -- do NOT hand-edit entries or sets here.
local Data    = require("MC_ConceptsData")
M.concepts    = Data.concepts


-- LEXICAL SETS
-- Concept-keyed semantic neighborhoods: the Connection feature's set-neighbor
-- bonus reads this to give a learner who's acquired N concepts from a set a
-- productive/receptive boost on the set's other concepts, cross-language.
--
-- Pre-pivot, sets were L2-keyed per palette (French declared {"eau",
-- "nourriture",...}, Slavic the parallel {"voda","yeda",...}); the concept
-- tree moves the declaration here so "survival is survival across languages"
-- is a universal-concept-space claim, not palette-author convention.
--
-- Tier 1 sets are deliberately small; Tier 2 broadens them as Tier 2 concepts
-- (HELLO, THANK_YOU, KNIFE, FOOD specifics, etc.) enter the registry.
--
-- A concept may belong to multiple sets -- the Connection bonus formula
-- (v8.9) takes MAX across sets per token, so overlap (RUN in both survival
-- and motion) is intentional.

-- DATA-SOURCED (see above): a dangling member is impossible since every
-- member is a concept row. The five Tier-1 sets and their intent:
--   survival   -- PZ survival concepts learners coordinate around
--   social     -- universally-establishable interpersonal vocabulary
--   motion     -- motion-verb field (knowing WALK pulls RUN/GO/COME)
--   body       -- small high-frequency body-part kernel
--   sensation  -- internal-state vocabulary a survivor needs
M.lexicalSets = Data.lexicalSets

-- INDEX BUILDERS -- lazy, computed at first use

local _englishIndex = nil      -- english_token (lower) -> sorted {ids}
local _setMembership = nil     -- concept_id -> sorted {setNames}
local _allIdsCache = nil       -- sorted list of all concept ids
local _validated = false       -- has validate() been run yet?
local _validateErrs = nil      -- cached results of last validate()

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

local function buildEnglishIndex()
    local MC_Inflect = require("MC_Inflect")
    local idx = {}
    local function register(key, id)
        idx[key] = idx[key] or {}
        for _, existing in ipairs(idx[key]) do
            if existing == id then return end
        end
        idx[key][#idx[key] + 1] = id
    end
    for id, entry in pairs(M.concepts) do
        if type(entry) == "table" and type(entry.en) == "table" then
            for _, alias in ipairs(entry.en) do
                local key = alias:lower()
                register(key, id)
                -- Players speak inflected English; alias lists are lemmas. Generated
                -- forms (knows, helping, came, children) index to the same concept,
                -- build-time only (lookups stay O(1)) -- see MC_Inflect.lua for
                -- rules/collision rationale.
                for _, form in ipairs(MC_Inflect.expand(key)) do
                    register(form, id)
                end
            end
        end
    end
    -- Sort each bucket for deterministic byEnglish output.
    for _, list in pairs(idx) do table.sort(list) end
    return idx
end

local function buildSetMembership()
    local m = {}
    for setName, members in pairs(M.lexicalSets) do
        for _, conceptId in ipairs(members) do
            m[conceptId] = m[conceptId] or {}
            m[conceptId][#m[conceptId] + 1] = setName
        end
    end
    for _, list in pairs(m) do table.sort(list) end
    return m
end

-- VALIDATION
-- Runs lazily on first API call. Catches authoring mistakes that would
-- otherwise produce subtle resolution bugs:
--   - parent IDs that don't resolve to a concept (typos)
--   - lexicalSets members that don't resolve to a concept (typos)
--   - cyclic parent chains (BFS would not terminate within MAX_WALK_DEPTH
--     but we want to catch this at load time, not at every walk)
--   - shape failures (missing tier/en/parents fields)

function M.validate()
    if _validated then return _validateErrs == nil, _validateErrs end
    local errs = {}

    -- 1. Per-entry shape
    for id, entry in pairs(M.concepts) do
        if type(entry) ~= "table" then
            errs[#errs + 1] = string.format("entry %s is not a table", id)
        else
            if type(entry.tier) ~= "number" then
                errs[#errs + 1] = string.format("entry %s missing numeric tier", id)
            end
            if type(entry.en) ~= "table" or #entry.en == 0 then
                errs[#errs + 1] = string.format("entry %s has empty or missing en aliases", id)
            else
                for i, alias in ipairs(entry.en) do
                    if type(alias) ~= "string" or alias == "" then
                        errs[#errs + 1] = string.format("entry %s en[%d] not a non-empty string", id, i)
                    end
                end
            end
            if type(entry.parents) ~= "table" then
                errs[#errs + 1] = string.format("entry %s missing parents list", id)
            end
        end
    end

    -- 2. Parent references resolve
    for id, entry in pairs(M.concepts) do
        if type(entry) == "table" and type(entry.parents) == "table" then
            for _, p in ipairs(entry.parents) do
                if M.concepts[p] == nil then
                    errs[#errs + 1] = string.format("entry %s parent '%s' does not exist", id, p)
                end
            end
        end
    end

    -- 3. lexicalSets members resolve
    for setName, members in pairs(M.lexicalSets) do
        if type(members) ~= "table" then
            errs[#errs + 1] = string.format("lexicalSet '%s' is not a list", setName)
        else
            for i, cid in ipairs(members) do
                if M.concepts[cid] == nil then
                    errs[#errs + 1] = string.format(
                        "lexicalSet '%s'[%d] = '%s' does not exist", setName, i, cid)
                end
            end
        end
    end

    local state = {}
    local function visit(id)
        if state[id] == 1 then return false end
        if state[id] == 2 then return true end
        state[id] = 1
        local entry = M.concepts[id]
        if type(entry) == "table" and type(entry.parents) == "table" then
            for _, parent in ipairs(entry.parents) do
                if M.concepts[parent] and not visit(parent) then return false end
            end
        end
        state[id] = 2
        return true
    end
    for id in pairs(M.concepts) do
        if state[id] == nil and not visit(id) then
            errs[#errs + 1] = string.format(
                "cycle detected in parent chain starting from %s", id)
            break
        end
    end

    _validated = true
    if #errs > 0 then
        _validateErrs = errs
        print(string.format(
            "[MongooseChat] WARNING: MC_Concepts validation found %d issue(s):",
            #errs))
        for i = 1, math.min(#errs, 10) do
            print(string.format("  - %s", errs[i]))
        end
        if #errs > 10 then
            print(string.format("  ... and %d more", #errs - 10))
        end
        return false, errs
    end
    _validateErrs = nil
    return true, nil
end

-- PUBLIC API

local function ensureValidated()
    if not _validated then M.validate() end
end

function M.get(id)
    if type(id) ~= "string" then return nil end
    ensureValidated()
    return M.concepts[id]
end

function M.has(id)
    if type(id) ~= "string" then return false end
    ensureValidated()
    return M.concepts[id] ~= nil
end

-- Concept IDs whose English aliases match `token` (case-insensitive), sorted;
-- nil if no match. A token may match multiple concepts (e.g. "drink" matches
-- BEVERAGE and DRINK) -- resolution picks which one, based on palette declarations.
function M.byEnglish(token)
    if type(token) ~= "string" then return nil end
    ensureValidated()
    if _englishIndex == nil then _englishIndex = buildEnglishIndex() end
    local list = _englishIndex[token:lower()]
    if list == nil or #list == 0 then return nil end
    return list
end

-- BFS ancestor IDs (excludes the starting concept), capped at maxDepth
-- (default M.MAX_WALK_DEPTH). Used by the resolution algorithm to find a
-- lexicalized ancestor when a palette doesn't declare the queried concept.
function M.walkParents(id, maxDepth)
    if type(id) ~= "string" then return {} end
    ensureValidated()
    local entry = M.concepts[id]
    if entry == nil then return {} end
    maxDepth = maxDepth or M.MAX_WALK_DEPTH

    local result = {}
    local visited = {[id] = true}  -- block re-visit of starting concept
    local queue = {}

    for _, p in ipairs(entry.parents or {}) do
        if not visited[p] then
            visited[p] = true
            queue[#queue + 1] = {id = p, depth = 1}
        end
    end

    while #queue > 0 do
        local node = table.remove(queue, 1)
        if node.depth > maxDepth then break end
        result[#result + 1] = node.id

        local pe = M.concepts[node.id]
        if pe and pe.parents then
            for _, p in ipairs(pe.parents) do
                if not visited[p] then
                    visited[p] = true
                    queue[#queue + 1] = {id = p, depth = node.depth + 1}
                end
            end
        end
    end

    return result
end

-- Sorted lexical-set names containing this concept; empty if none (or nonexistent).
function M.setsForConcept(id)
    if type(id) ~= "string" then return {} end
    ensureValidated()
    if _setMembership == nil then _setMembership = buildSetMembership() end
    local list = _setMembership[id]
    if list == nil then return {} end
    return list
end

-- Sorted list of all concept IDs. Caches on first call.
function M.allIds()
    ensureValidated()
    if _allIdsCache == nil then
        _allIdsCache = sortedKeys(M.concepts)
    end
    return _allIdsCache
end

return M
