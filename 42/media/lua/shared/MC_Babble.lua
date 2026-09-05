-- MC_Babble engine -- pure pipeline, no MC dependencies; MC_Lang wires it into processMessage.
--
-- PUBLIC API
--   M.transform(text, palette, bleedThrough, seed)    -> string
--   M.tokenize(text)                                  -> list of { text, isWord }
--   M.classify(wordToken, bleedThrough)               -> "clean" | "babble"
--   M.reassemble(tokens)                              -> string
--   M.setProtectedSentinelPatterns(patterns)          -> (sets classify()'s sentinel allowlist)
--   M.resolveWord(word, palette, level, rules, seed)  -> string  (babble-resolve: graded
--                                                         partial-comprehension render)
--   M.applyMishearing(unit, rules)                    -> string  (resolveWord's per-unit
--                                                         mishearing-rule substitution)
--   M.setGuardExhaustedSink(fn)                       -> (observability hook, output guard
--                                                         below: fires if mutateNucleus's
--                                                         vowel-swap ever fails to clear the
--                                                         blocklist; no-op unset)
--
-- PALETTE SCHEMA -- pure data; the engine reads it, never mutates it.
--   name, family -- diagnostics / future cross-family logic; unused by engine
--   tuning = { lettersPerSyllable, onsetChance, midCodaChance, endingPoolChance,
--     functionWordChance, elisionPrefixChance, signatureBoostWeight,
--     featuredSignatureCount } -- all optional, see DEFAULT_TUNING below
--   onsets, nuclei, codas, functionWords, elisionPrefixes -- content pools
--     (required for non-empty output)
--   signatureSet = { <name> = { category = "onset"|"nucleus"|"coda"|"functionWord"
--     |"elisionPrefix", elements = {...} } } -- per utterance, featuredSignatureCount
--     of these get signatureBoostWeight in picks for their category
--   babbleBlocklist = { ... } -- optional palette-specific vulgarities, whole-word
--   Integration-layer fields the engine ignores (kept here so palettes stay the
--   single source of truth): lex (concept-keyed L1->L2, resolved by MC_Resolve/
--   MC_Concepts), zipf (frequency-ordered L2 forms, read by MC_Acquisition).
--   dictionary/lexicalSets are pre-concept-tree fields; removed.
--
-- BLEED-THROUGH: a lowercased string set ({ ["ah"]=true, ... }) computed by the
-- integration layer (name-roster matching, anonymity, punctuation). The engine
-- only looks it up -- no policy here. Same for the protected-sentinel patterns
-- classify() checks: injected via setProtectedSentinelPatterns, not known to
-- this module.

local M = {}

-- VM-portable UTF-8 iteration (Kahlua has no utf8 library).
local Str = require("MC_StringUtils")

-- Helpers (module-local)

-- Tiny self-contained LCG. Deterministic per seed, no global-state interference.
local function makeRng(seed)
    -- Production callers supply an authoritative message seed. Keep the pure
    -- helper deterministic when a caller omits it; Build 42.20 has no
    -- os.time() surface to use as an implicit seed.
    local state = math.floor(seed or 1) % 2147483647
    if state <= 0 then state = 1 end

    local rng = {}
    function rng:_next()
        state = (state * 1103515245 + 12345) % 2147483648
        return state
    end
    function rng:random(a, b)
        if a and b then
            return a + (self:_next() % (b - a + 1))
        elseif a then
            return 1 + (self:_next() % a)
        else
            return self:_next() / 2147483648
        end
    end
    function rng:chance(p)
        return self:random() < p
    end
    return rng
end

local function detectCaps(word)
    if #word == 0 then return "none" end
    local upper = word:upper()
    local lower = word:lower()
    if upper == lower then return "none" end          -- no alphabetic chars
    if word == upper then return "all" end
    local first = word:sub(1, 1)
    if first:upper() == first and first:lower() ~= first then
        return "first"
    end
    return "none"
end

local function applyCaps(s, capStyle)
    if capStyle == "all" then return s:upper() end
    if capStyle == "first" and #s > 0 then
        return s:sub(1, 1):upper() .. s:sub(2)
    end
    return s
end

local function countLetters(word)
    local _, count = word:gsub("[%a]", "")
    return count
end

-- Kahlua has no global `next`; pairs()-based early-return substitute.
-- Duplicated (not imported) from MC_Core.isEmpty to keep this engine MC-independent.
local function isEmpty(t)
    if not t then return true end
    for _ in pairs(t) do return false end
    return true
end

-- Weighted pick: elements in boostSet get `multiplier` weight; others get 1.
local function pickWeighted(list, rng, boostSet, multiplier)
    if not list or #list == 0 then return "" end
    if isEmpty(boostSet) then
        return list[rng:random(1, #list)]
    end

    local total = 0
    for _, item in ipairs(list) do
        total = total + (boostSet[item] and multiplier or 1)
    end

    local roll = rng:random() * total
    local cumulative = 0
    for _, item in ipairs(list) do
        cumulative = cumulative + (boostSet[item] and multiplier or 1)
        if roll <= cumulative then return item end
    end
    return list[#list]
end

local function jitter(rng)
    return rng:random(0, 2) - 1
end

-- Coda-category signature elements, cached per-palette (keeps palettes pure data).
local endingPoolCache = setmetatable({}, { __mode = "k" })
local function getEndingPool(palette)
    local cached = endingPoolCache[palette]
    if cached then return cached end
    local pool = {}
    for _, sig in pairs(palette.signatureSet or {}) do
        if sig.category == "coda" then
            for _, e in ipairs(sig.elements or {}) do
                pool[#pool + 1] = e
            end
        end
    end
    endingPoolCache[palette] = pool
    return pool
end

-- Tuning resolution

-- Defaults for palettes without a tuning block; match the pre-refactor
-- hardcoded values so output is unchanged for those palettes.
local DEFAULT_TUNING = {
    lettersPerSyllable     = 3,
    onsetChance            = 0.7,
    midCodaChance          = 0.5,
    endingPoolChance       = 0.7,
    functionWordChance     = 0.4,
    elisionPrefixChance    = 0.2,
    signatureBoostWeight   = 3,
    featuredSignatureCount = 2,
}

-- Precedence: palette.tuning.<key> > palette.<key> (legacy pre-tuning-block
-- palettes) > DEFAULT_TUNING. Returns a new table; palette is not mutated.
local function resolveTuning(palette)
    local tuning = {}
    local pt = palette.tuning or {}
    for k, defaultVal in pairs(DEFAULT_TUNING) do
        if pt[k] ~= nil then
            tuning[k] = pt[k]
        elseif palette[k] ~= nil then
            tuning[k] = palette[k]
        else
            tuning[k] = defaultVal
        end
    end
    return tuning
end

-- Vowel harmony
--
-- Optional palette.vowelHarmony = { enabled, frontVowels={...}, backVowels={...},
-- rule="twoWay" (only rule implemented; rounded distinction reserved for v2) }.
-- The first vowel seen in a word (onset/nucleus/coda order) sets its harmony
-- class; later picks filter to that class. "mixed" strings are excluded from
-- filtered pools, "neutral" (no vowels) always allowed; an empty filtered pool
-- falls back to unfiltered rather than stall generation. Classification and
-- filter results are cached onto palette._harmonyCache (per-codepoint iteration
-- is slow otherwise).

local function getHarmonyCache(palette)
    if palette._harmonyCache ~= nil then
        return palette._harmonyCache
    end
    local h = palette.vowelHarmony
    if not h or not h.enabled then
        palette._harmonyCache = false  -- distinct from nil; "checked, disabled"
        return false
    end
    local front, back = {}, {}
    for _, v in ipairs(h.frontVowels or {}) do front[v] = true end
    for _, v in ipairs(h.backVowels  or {}) do back[v]  = true end
    palette._harmonyCache = {
        front     = front,
        back      = back,
        classOf   = {},  -- memoized per-string classification
        filterFor = {},  -- memoized per-(pool, class) filter outputs
    }
    return palette._harmonyCache
end

-- Memoized on the palette's harmony cache.
local function harmonyClassOf(s, cache)
    if not cache or not s or s == "" then return "neutral" end
    local cached = cache.classOf[s]
    if cached ~= nil then return cached end
    local hasFront, hasBack = false, false
    for ch in Str.utf8chars(s) do
        if cache.front[ch] then hasFront = true end
        if cache.back[ch]  then hasBack  = true end
    end
    local cls
    if     hasFront and hasBack then cls = "mixed"
    elseif hasFront             then cls = "front"
    elseif hasBack              then cls = "back"
    else                             cls = "neutral"
    end
    cache.classOf[s] = cls
    return cls
end

-- Memoized per (pool, class) on the palette's cache.
local function filterByHarmony(pool, targetClass, cache)
    if not cache or not targetClass or targetClass == "neutral" or targetClass == "mixed" then
        return pool
    end
    local key = tostring(pool) .. ":" .. targetClass
    local cached = cache.filterFor[key]
    if cached ~= nil then return cached end
    local out = {}
    for _, s in ipairs(pool) do
        local cls = harmonyClassOf(s, cache)
        if cls == targetClass or cls == "neutral" then
            table.insert(out, s)
        end
    end
    if #out == 0 then
        cache.filterFor[key] = pool  -- safety: never starve the picker
        return pool
    end
    cache.filterFor[key] = out
    return out
end

-- Pipeline

-- Word run = letters/digits + intra-word apostrophes (flanked by alphanumerics);
-- everything else is a non-word run.
function M.tokenize(text)
    if type(text) ~= "string" or #text == 0 then return {} end

    local n = #text
    local function isWordCharAt(p)
        local c = text:sub(p, p)
        if c:match("[%w]") then return true end
        if c == "'" and p > 1 and p < n then
            local prev = text:sub(p - 1, p - 1)
            local nextc = text:sub(p + 1, p + 1)
            if prev:match("[%w]") and nextc:match("[%w]") then return true end
        end
        return false
    end

    local tokens = {}
    local i = 1
    while i <= n do
        local start = i
        local startIsWord = isWordCharAt(i)
        while i <= n and isWordCharAt(i) == startIsWord do
            i = i + 1
        end
        tokens[#tokens + 1] = {
            text   = text:sub(start, i - 1),
            isWord = startIsWord,
        }
    end
    return tokens
end

-- Sentinel shape is sibling-module policy (MC_Sanitize/MC_Cultural placeholders,
-- e.g. "no*shrugs*" -> "noMCSAN1"), not engine mechanism -- injected via
-- setProtectedSentinelPatterns, wired by MC_Lang at load time. The default below
-- keeps this module working standalone (tests/tooling); it's replaced wholesale,
-- not merged.
local protectedSentinelPatterns = { "mcsan%d+", "mccultural%d+" }

function M.setProtectedSentinelPatterns(patterns)
    if type(patterns) ~= "table" then return end
    protectedSentinelPatterns = patterns
end

-- Word tokens only; lookup lowercased. A token CARRYING a sentinel (not just an
-- exact match) passes clean -- a fused sentinel ("no*shrugs*" -> "noMCSAN1")
-- would otherwise be destroyed by babbling before restore() can unfuse it.
-- Accepted cost: the fused fragment itself bleeds through unbabbled.
function M.classify(wordToken, bleedThrough)
    local lower = wordToken.text:lower()
    if bleedThrough and bleedThrough[lower] then
        return "clean"
    end
    for _, pattern in ipairs(protectedSentinelPatterns) do
        if lower:find(pattern) then
            return "clean"
        end
    end
    return "babble"
end

-- Build one syllable (isLast is the only positional distinction; tuning drives
-- the probabilities). With a harmony cache, vowel picks filter to classRef[1] --
-- set by the first vowel seen (onset/nucleus/coda order) and held for the rest
-- of the word.
local function buildSyllable(palette, rng, tuning, isLast, featuredByCategory,
                             harmonyCache, classRef)
    featuredByCategory = featuredByCategory or {}
    local boost = tuning.signatureBoostWeight

    local function pickFiltered(pool, featured)
        if not harmonyCache or not classRef or not classRef[1] then
            return pickWeighted(pool, rng, featured, boost)
        end
        local filtered = filterByHarmony(pool, classRef[1], harmonyCache)
        return pickWeighted(filtered, rng, featured, boost)
    end

    local function observe(s)
        if not harmonyCache or not classRef or classRef[1] ~= nil then return end
        local cls = harmonyClassOf(s, harmonyCache)
        if cls == "front" or cls == "back" then
            classRef[1] = cls
        end
    end

    local onset = ""
    if rng:chance(tuning.onsetChance) then
        onset = pickFiltered(palette.onsets, featuredByCategory.onset)
        observe(onset)
    end

    local nucleus = pickFiltered(palette.nuclei, featuredByCategory.nucleus)
    observe(nucleus)

    local coda
    if isLast then
        -- Last syllable always has a coda, biased toward the auto-derived ending pool.
        local endingPool = getEndingPool(palette)
        if #endingPool > 0 and rng:chance(tuning.endingPoolChance) then
            coda = pickFiltered(endingPool, featuredByCategory.coda)
        else
            coda = pickFiltered(palette.codas, featuredByCategory.coda)
        end
    else
        if rng:chance(tuning.midCodaChance) then
            coda = pickFiltered(palette.codas, featuredByCategory.coda)
        else
            coda = ""
        end
    end

    return onset .. nucleus .. coda
end

-- Output guard -- generated babble is noise, but noise can land on real words.
-- Every word babbleWord produces is checked against three lists, in order:
--   1. BLOCK_PREFIX -- English profanity; blocks the exact word AND any word
--      merely beginning with an entry ("fuck" also blocks "fuckita").
--   2. BLOCK_WORD -- common short English words, whole-word ONLY ("the" inside
--      "thelka" is fine; standalone "the" is not).
--   3. palette.babbleBlocklist -- palette-specific vulgarities, whole-word.
-- On a hit, babbleWord re-rolls from the same per-utterance rng stream --
-- still deterministic, since the stream is a pure function of the caller's
-- seed. Attempts are bounded; on exhaustion the candidate's first vowel is
-- swapped deterministically until the match breaks.

-- English profanity: blocks whole word and leading substring. All lowercase.
local BLOCK_PREFIX = {
    "fuck", "shit", "piss", "cunt", "cock", "dick", "tit", "twat",
    "wank", "whore", "slut", "bitch", "nigger", "nigga", "fag",
    "rape", "penis", "anus", "anal", "semen", "cum", "jizz", "porn",
    "arse", "ass",
}

-- Common short English words (2-4 letters): whole-word only. All lowercase.
local BLOCK_WORD = {}
for _, w in ipairs({
    "am", "an", "as", "at", "be", "by", "do", "go", "he", "if",
    "in", "is", "it", "me", "my", "no", "of", "on", "or", "so",
    "to", "up", "us", "we",
    "all", "and", "any", "are", "ask", "bad", "big", "boy", "but",
    "can", "car", "day", "did", "die", "dog", "eat", "end", "few",
    "for", "get", "god", "got", "gun", "had", "has", "her", "him",
    "his", "how", "man", "men", "new", "not", "now", "old", "one",
    "our", "out", "ran", "run", "saw", "say", "see", "she", "six",
    "son", "ten", "the", "too", "two", "use", "was", "way", "who",
    "why", "yes", "yet", "you",
    "back", "come", "dead", "done", "down", "food", "from", "girl",
    "give", "good", "have", "hear", "help", "here", "home", "kill",
    "know", "like", "look", "love", "make", "more", "must", "name",
    "need", "over", "said", "same", "some", "stop", "take", "tell",
    "that", "them", "then", "they", "this", "time", "want", "well",
    "were", "what", "when", "will", "with", "word", "your",
}) do BLOCK_WORD[w] = true end

-- Palette blocklist cache (same pattern as endingPoolCache); false = checked, none.
local blocklistCache = setmetatable({}, { __mode = "k" })
local function getPaletteBlockSet(palette)
    local cached = blocklistCache[palette]
    if cached ~= nil then return cached end
    local set = false
    if palette.babbleBlocklist and #palette.babbleBlocklist > 0 then
        set = {}
        for _, w in ipairs(palette.babbleBlocklist) do set[w:lower()] = true end
    end
    blocklistCache[palette] = set
    return set
end

local function isBlockedWord(w, palette)
    if BLOCK_WORD[w] then return true end
    local paletteSet = getPaletteBlockSet(palette)
    if paletteSet and paletteSet[w] then return true end
    for _, p in ipairs(BLOCK_PREFIX) do
        if w:sub(1, #p) == p then return true end
    end
    return false
end

-- Single-char nuclei across the shipped palettes (multibyte as byte escapes,
-- matched via Str.utf8chars for a correct walk on both VMs).
local MUTATE_VOWELS = {}
for _, v in ipairs({
    "a", "e", "i", "o", "u", "y",
    "\195\169", "\195\168", "\195\170", "\195\160",   -- e-acute e-grave e-circ a-grave (French)
    "\196\177", "\195\182", "\195\188",               -- i-dotless o-uml u-uml (Turkish)
}) do MUTATE_VOWELS[v] = true end

-- Internal contract: fires (word, paletteName) if mutateNucleus below ever
-- exhausts every candidate vowel without clearing the blocklist -- pure
-- engine, so this is injected rather than printed directly (same shape as
-- MC_Acquisition.setExposureTraceSink); MC_Lang wires a console line onto
-- it. No-op if unset; pcall-guarded so a broken sink can never affect which
-- word ships.
local guardExhaustedSink = nil
function M.setGuardExhaustedSink(fn)
    guardExhaustedSink = (type(fn) == "function") and fn or nil
end

-- Swaps the word's first vowel for each single-char palette nucleus in turn
-- until clear of the blocklist. One vowel change breaks any whole-word or
-- prefix match the shipped lists can produce, so the trailing hard stop below
-- is effectively unreachable (test-backed: test_babble_blocklist_mutation_guard
-- forces every candidate through it and confirms escape). If it's ever
-- reached anyway, the word becomes opaque punctuation. A blocked candidate
-- must never ship merely because the safety guard ran out of alternatives.
local function mutateNucleus(word, palette)
    local chars, vowelAt = {}, nil
    for ch in Str.utf8chars(word) do
        chars[#chars + 1] = ch
        if not vowelAt and MUTATE_VOWELS[ch] then vowelAt = #chars end
    end
    if not vowelAt then
        if guardExhaustedSink then
            pcall(guardExhaustedSink, word, palette.name, "no-mutable-vowel")
        end
        return "..."
    end
    local original = chars[vowelAt]
    for _, v in ipairs(palette.nuclei or {}) do
        if v ~= original and MUTATE_VOWELS[v] then   -- single-char nuclei only
            chars[vowelAt] = v
            local candidate = table.concat(chars)
            if not isBlockedWord(candidate, palette) then
                return candidate
            end
        end
    end
    if guardExhaustedSink then
        pcall(guardExhaustedSink, word, palette.name, "candidates-exhausted")
    end
    return "..."
end

-- One unguarded babble attempt; probabilities/boost/lettersPerSyllable come
-- from tuning. Returns raw lowercase (the guarded wrapper applies caps).
local function babbleWordOnce(word, palette, rng, tuning, featuredByCategory)
    featuredByCategory = featuredByCategory or {}
    local boost = tuning.signatureBoostWeight

    local letterCount = countLetters(word)

    if letterCount <= 3 and rng:chance(tuning.functionWordChance) then
        if palette.functionWords and #palette.functionWords > 0 then
            return pickWeighted(palette.functionWords, rng,
                                featuredByCategory.functionWord, boost)
        end
    end

    local syllableCount = math.max(1,
        math.floor(letterCount / tuning.lettersPerSyllable + 0.5) + jitter(rng))

    local prefix = ""
    if palette.elisionPrefixes and #palette.elisionPrefixes > 0
       and rng:chance(tuning.elisionPrefixChance) then
        prefix = pickWeighted(palette.elisionPrefixes, rng,
                              featuredByCategory.elisionPrefix, boost)
    end

    local syllables = {}
    local harmonyCache = getHarmonyCache(palette)
    local classRef = harmonyCache and { nil } or nil
    for i = 1, syllableCount do
        syllables[i] = buildSyllable(palette, rng, tuning, i == syllableCount,
                                     featuredByCategory, harmonyCache, classRef)
    end

    return prefix .. table.concat(syllables)
end

-- Guarded (Output guard, above); caps from the input word applied to whichever
-- candidate ships.
local BLOCK_MAX_ATTEMPTS = 4

local function babbleWord(word, palette, rng, tuning, featuredByCategory)
    local capStyle = detectCaps(word)
    local candidate
    for _ = 1, BLOCK_MAX_ATTEMPTS do
        candidate = babbleWordOnce(word, palette, rng, tuning, featuredByCategory)
        if not isBlockedWord(candidate:lower(), palette) then
            return applyCaps(candidate, capStyle)
        end
    end
    return applyCaps(mutateNucleus(candidate:lower(), palette), capStyle)
end

-- Non-word tokens keep their original spacing/punctuation -- cadence falls out for free.
function M.reassemble(tokens)
    local parts = {}
    for i, t in ipairs(tokens) do parts[i] = t.text end
    return table.concat(parts)
end

-- Public entry: transform

function M.transform(text, palette, bleedThrough, seed)
    if type(text) ~= "string" or #text == 0 then return text end
    if not palette then return text end

    local rng = makeRng(seed)
    local tuning = resolveTuning(palette)

    -- Picks featuredSignatureCount signatures without replacement into
    -- featuredByCategory = { category = { element=true, ... }, ... }.
    local featuredByCategory = {}
    if palette.signatureSet then
        local sigNames = {}
        for name in pairs(palette.signatureSet) do
            sigNames[#sigNames + 1] = name
        end
        if #sigNames > 0 then
            local pickCount = math.min(tuning.featuredSignatureCount, #sigNames)
            for i = 1, pickCount do
                local idx = rng:random(i, #sigNames)
                sigNames[i], sigNames[idx] = sigNames[idx], sigNames[i]
                local sig = palette.signatureSet[sigNames[i]]
                if sig and sig.category and sig.elements then
                    local cat = sig.category
                    featuredByCategory[cat] = featuredByCategory[cat] or {}
                    for _, e in ipairs(sig.elements) do
                        featuredByCategory[cat][e] = true
                    end
                end
            end
        end
    end

    local tokens = M.tokenize(text)
    for _, token in ipairs(tokens) do
        if token.isWord then
            local action = M.classify(token, bleedThrough)
            if action == "babble" then
                token.text = babbleWord(token.text, palette, rng, tuning, featuredByCategory)
            end
            -- "clean" -> leave token.text unchanged
        end
        -- non-word tokens preserved as-is
    end

    return M.reassemble(tokens)
end

-- Babble-resolve: graded partial-comprehension rendering.
-- Comprehension rises: pure texture -> the true word MISHEARD through the
-- language's distinctive features -> the true word. Resolves per-UNIT
-- (syllable-ish), onset-first, so the word sharpens left-to-right.
-- Deterministic per (word, palette, level, rules, seed); texture is seeded
-- from (seed, slot) NOT level, so a word's look stays stable as it sharpens.
-- Kahlua-safe: byte-level only, no utf8 library -- multibyte UTF-8 (French
-- accents, Turkish special chars) grouped from lead/continuation bytes by hand.
-- (docs/BABBLE_RESOLVE.md, cited here previously, was lost -- see ARCHITECTURE.md.)

-- Group a byte string into UTF-8 characters (1-4 bytes each).
local function utf8Chars(s)
    local chars, i, n = {}, 1, #s
    while i <= n do
        local b = string.byte(s, i)
        local len = 1
        if b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2
        end
        chars[#chars + 1] = string.sub(s, i, i + len - 1)
        i = i + len
    end
    return chars
end

-- Vowel chars across the supported palettes (single chars; multibyte as bytes).
local RESOLVE_VOWELS = {}
for _, v in ipairs({
    "a", "e", "i", "o", "u", "y",
    "\195\160", "\195\162", "\195\166", "\195\168", "\195\169", "\195\170",  -- a-grave a-circ ae e-grave e-acute e-circ
    "\195\171", "\195\174", "\195\175", "\195\180", "\195\185", "\195\187",  -- e-uml i-circ i-uml o-circ u-grave u-circ
    "\195\188", "\195\182",                                                  -- u-uml o-uml
    "\196\177",                                                              -- i-dotless (Turkish)
}) do RESOLVE_VOWELS[v] = true end

-- Heuristic syllabifier (byte-level, Kahlua-safe): vowel-nucleus based,
-- maximal-onset (a single intervocalic consonant attaches to the FOLLOWING
-- syllable). Rough but sufficient for the left-to-right reveal. Module-local:
-- only resolveWord calls it.
local function syllabify(word)
    if type(word) ~= "string" or #word == 0 then return {} end
    local chars = utf8Chars(word)
    local syllables, buf, state = {}, {}, "onset"
    for _, c in ipairs(chars) do
        local isV = RESOLVE_VOWELS[c] == true
        if state == "onset" then
            buf[#buf + 1] = c
            if isV then state = "nucleus" end
        elseif state == "nucleus" then
            buf[#buf + 1] = c
            if not isV then state = "coda" end
        else -- coda
            if isV then
                local lastC = buf[#buf]; buf[#buf] = nil   -- maximal onset
                syllables[#syllables + 1] = table.concat(buf)
                buf = { lastC, c }
                state = "nucleus"
            else
                buf[#buf + 1] = c
            end
        end
    end
    if #buf > 0 then syllables[#syllables + 1] = table.concat(buf) end
    return syllables
end

-- Plain (non-pattern) byte-level substring replace.
local function plainReplace(s, from, to)
    if from == "" then return s end
    local out, i = {}, 1
    while true do
        local a, b = string.find(s, from, i, true)
        if not a then out[#out + 1] = string.sub(s, i); break end
        out[#out + 1] = string.sub(s, i, a - 1)
        out[#out + 1] = to
        i = b + 1
    end
    return table.concat(out)
end

-- Ordered {from, to} rules; order matters (whole-cluster before single-letter).
function M.applyMishearing(unit, rules)
    if not rules then return unit end
    for _, rule in ipairs(rules) do
        unit = plainReplace(unit, rule[1], rule[2])
    end
    return unit
end

-- level in [0,1]: 0 = pure texture, 1 = the true word (see the banner above for the full model).
function M.resolveWord(word, palette, level, rules, seed)
    if type(word) ~= "string" or #word == 0 then return word end
    if not palette then return word end
    rules = rules or palette.mishearing or {}
    level = level or 0
    if level < 0 then level = 0 elseif level > 1 then level = 1 end
    seed = seed or 0

    local capStyle = detectCaps(word)
    local units = syllabify(word:lower())
    local n = #units
    if n == 0 then return word end

    local tuning = resolveTuning(palette)
    local phase = math.floor(level * 2 * n + 0.5)   -- 0 .. 2n

    local out = {}
    for i = 1, n do
        local raw = phase - 2 * (i - 1)
        local state = 0
        if raw >= 2 then state = 2 elseif raw >= 1 then state = 1 end
        if state == 2 then
            out[i] = units[i]
        elseif state == 1 then
            out[i] = M.applyMishearing(units[i], rules)
        else
            local slotRng = makeRng(seed * 131 + i * 17 + 1)
            local harmonyCache = getHarmonyCache(palette)
            local classRef = harmonyCache and { nil } or nil
            out[i] = buildSyllable(palette, slotRng, tuning, i == n, {}, harmonyCache, classRef)
        end
    end
    return applyCaps(table.concat(out), capStyle)
end

return M
