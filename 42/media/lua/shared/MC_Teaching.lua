--[[
================================================================================
    MongooseChat - Teaching Engine (v8.7)

    The third axis of fluency: Acquisition (v8.5) is passive exposure,
    Heritage (v8.6) is inherited cultural content, Teaching is active
    pedagogy -- a speaker directly telling a listener what a word means.

    DESIGN PHILOSOPHY

    Teaching is a discrete moment: a speaker who has acquired a word can
    teach it to a listener who has heard it at least once before, and the
    teaching event produces INSTANT acquisition -- the click moment IS the
    teaching beat, not a delayed consolidation.

    The system stays silent on the learner's side -- no whisper announces
    it; the render transition (babbled -> "Water (eau)" bracket) carries the
    moment, and the listener experiences their own comprehension as personal
    discovery. v8.16.1 "Voices" gives the TEACHER one quiet cue when the
    lesson lands ("They seem to follow."), completing the two-player scene
    without touching the learner's half. Delivery lives server-side in
    MC_Lang (deduped per utterance); this module remains pure detection.

    v8.16.2 widened the detection surface: quotes/stray punctuation around
    captured words are tolerated; diacritics fold to plain ASCII on both
    sides of the dictionary compare (PZ chat on an EN keyboard can't type
    "ba\197\159", so "bas" can teach it); multiword forms are claimable by
    their first word; two more template families joined ("this/that/it is
    called Y", "we call X Y"). The claimed L2 normalizes to the canonical
    lex spelling before reaching acquisition, so teaching keys the same
    form the render pipeline records exposure under.

    DETECTION SURFACE

    Both natives and learners invoke teaching by typing one of the templated
    meta-language forms (palette or defaults below):
        "Water is called eau in French"    "Eau means water"
        "We say eau for water"             "The word for water is eau"
        "Eau is the word for water"        "We call water eau"
        "This is called eau"  (dictionary supplies the concept)

    Patterns require an L1 and L2 word (except the this/that/it family,
    L2-only); the L2 must exist in the palette dictionary and the L1 must be
    its canonical mapping -- false teaching ("Water is called horse") is
    rejected at detection.

    GATES (applied in MC_Lang.renderWithLangs around the detection call)

    Speaker-eligibility: the speaker must OWN the word. Natives pass
    trivially; learners pass iff they've both acquired AND produced the L2
    (used it in their own speech) -- you can't teach a word you've only just
    heard.

    Receiver-heard (applied per-receiver in renderForReceiver): the receiver
    must have heard the L2 at least once before. Teaching crystallises
    recognition of an already-encountered word; it doesn't install one from
    scratch -- matching how "What does X mean?" implies prior encounter.

    Together the two gates force the optimal-strategy and immersive-play
    paths into the same shape: a determined pair can still teach through the
    dictionary, but only after the native USES the word in proximity speech
    first (passive exposure) and then explains it -- the grind path looks
    like real tutoring because it IS real tutoring under these constraints.

    PER-MESSAGE LIMIT

    One teaching event per utterance; leftmost valid match wins (prevents
    spam-teach chains). Authoring rule: every pattern needs a structural
    marker (called, means, word for, etc.) -- never bare "X is Y", which
    would catch ordinary speech.

    EXTENSIBILITY

    Default patterns live on this module; palettes can override via a
    `teaching` block (reserved schema slot) for language communities with
    their own standard teaching idioms.

    Author: Kialae (Mongoose Server). License: MIT.
================================================================================
]]

local MC_Core = require("MC_Core")
local Str = require("MC_StringUtils")  -- VM-portable UTF-8 iteration (diacritic fold)
local Concepts = require("MC_Concepts")
local Resolve = require("MC_Resolve")  -- concept<->L2 resolution (hoisted like MC_Resolve.lua:77)

local dbg = MC_Core.debugger("TEACHING")

local MC_Teaching = {}

-- DEFAULT PATTERNS -- each entry: { pattern = <Lua pattern, two %w+ captures>,
-- l1Group, l2Group }. l2Only = true (v8.16.2) means a single capture (indexed
-- by l2Group) with no L1 in the sentence -- the dictionary supplies the
-- concept ("this is called eau" teaches WATER); the strict structural marker
-- ("this/that/it is called") carries the false-trigger load instead.
-- %p* tolerates quotes/stray punctuation ('water is called "eau"') without
-- weakening the markers. Authoring rule: every pattern needs a structural
-- marker -- bare "(%w+) is (%w+)" would match ordinary "<thing> is <thing>" speech.

MC_Teaching.DEFAULT_PATTERNS = {
    { pattern = "(%w+)%p* is called %p*(%w+)",         l1Group = 1, l2Group = 2 },
    { pattern = "the word for (%w+)%p* is %p*(%w+)",   l1Group = 1, l2Group = 2 },
    { pattern = "(%w+)%p* means %p*(%w+)",             l1Group = 2, l2Group = 1 },
    { pattern = "we say (%w+)%p* for %p*(%w+)",        l1Group = 2, l2Group = 1 },
    { pattern = "(%w+)%p* is the word for %p*(%w+)",   l1Group = 2, l2Group = 1 },
    { pattern = "we call (%w+)%p* %p*(%w+)",           l1Group = 1, l2Group = 2 },
    { pattern = "this is called %p*(%w+)",             l2Group = 1, l2Only = true },
    { pattern = "that is called %p*(%w+)",             l2Group = 1, l2Only = true },
    { pattern = "it is called %p*(%w+)",               l2Group = 1, l2Only = true },
    { pattern = "it's called %p*(%w+)",                l2Group = 1, l2Only = true },
}

-- PATTERN RESOLUTION
-- 
-- Palettes may override defaults via a `teaching` block:
--   teaching = {
--       patterns = { { pattern = "...", l1Group = N, l2Group = N }, ... },
--   }

local function getPatterns(palette)
    if type(palette) == "table"
       and type(palette.teaching) == "table"
       and type(palette.teaching.patterns) == "table"
       and #palette.teaching.patterns > 0 then
        return palette.teaching.patterns
    end
    return MC_Teaching.DEFAULT_PATTERNS
end

-- DIACRITIC FOLDING (v8.16.2) -- PZ chat on an EN keyboard can't produce
-- "\197\159" or "\195\174", so every dictionary compare folds BOTH sides to
-- plain ASCII ("head is called bas" understood for "ba\197\159"). Kept local
-- so the teaching path does not pull in an unrelated generated lexicon; the
-- byte-level mechanism (Str.utf8chars) works on both VMs and covers the
-- shipped Turkish and French forms.

local FOLD = {
    -- Turkish
    ["\195\167"] = "c",       -- c-cedilla -> c
    ["\197\159"] = "s",       -- s-cedilla -> s
    ["\196\159"] = "g",       -- g-breve -> g
    ["\195\182"] = "o",       -- o-diaeresis -> o
    ["\195\188"] = "u",       -- u-diaeresis -> u
    ["\196\177"] = "i",       -- dotless i -> i
    -- French (accents appearing in shipped palette.lex forms)
    ["\195\169"] = "e",       -- e-acute -> e
    ["\195\168"] = "e",       -- e-grave -> e
    ["\195\170"] = "e",       -- e-circumflex -> e
    ["\195\162"] = "a",       -- a-circumflex -> a
    ["\195\174"] = "i",       -- i-circumflex -> i
    ["\195\180"] = "o",       -- o-circumflex -> o
    ["\195\187"] = "u",       -- u-circumflex -> u
    ["\195\185"] = "u",       -- u-grave -> u
    ["\197\147"] = "oe",      -- oe-ligature -> oe
}

local function foldDiacritics(s)
    if type(s) ~= "string" then return nil end
    local out = {}
    for ch in Str.utf8chars(s) do
        table.insert(out, FOLD[ch] or ch)
    end
    return table.concat(out)
end

-- Does a typed single-word claim stand for this lex form? Exact match after
-- diacritic folding, or -- for multiword forms a %w+ capture can't span -- a
-- fold-match on the form's first word, apostrophes dropped ("sil" claims
-- "s'il vous pla\195\174t"). Both args already lowercased; foldedClaim already folded.
local function claimMatchesForm(foldedClaim, formLower)
    local folded = foldDiacritics(formLower)
    if folded == foldedClaim then return true end
    local firstWord = folded:match("^([^%s]+)%s")
    if firstWord then
        firstWord = firstWord:gsub("'", "")
        if firstWord == foldedClaim then return true end
    end
    return false
end

-- LEX VALIDATION (concept-keyed) -- the claimed L2 must exist in the
-- palette's lex AND the claimed L1 must resolve to the concept lexicalizing
-- it. Rejects: unknown L2 ("Water is called horse"); L1/L2 mismatch ("Bread
-- is called eau" -- eau lexicalizes WATER, "bread" doesn't); circular ("Eau
-- is called eau" -- same concept both sides, no L1<->L2 polarity).
--
-- Compares run through claimMatchesForm (diacritic fold + first-word
-- matching for multiword forms); both validators return the CANONICAL lex
-- spelling so callers key acquisition on the form the render pipeline
-- actually records exposure under.

-- (canonicalL2Lower, conceptId) on a match, nil otherwise. Two passes: exact
-- spelling, then fold-match -- shipped palettes have fold-homographs ("su"
-- folds onto "su" and "\197\159u"), so a single fold pass would let pairs()
-- iteration order pick the winner; an exact hit honors what was literally
-- typed, fold stays the EN-keyboard fallback.
--
-- Within a pass, entries can still tie (duplicate l2 forms; multiple
-- fold-matches) under VM-dependent pairs() order. The tie-break (lowest
-- conceptId wins) is authoritatively stated once in MC_Resolve.reverseLex
-- (sorted ids, first writer wins); the exact pass reuses that cached index
-- rather than re-deriving the rule, and only the fold pass -- uncovered by
-- reverseLex's exact-spelling index -- applies it directly.
local function findL2InDictionary(palette, claimedL2)
    if type(palette) ~= "table" or type(palette.lex) ~= "table" then
        return nil
    end
    if type(claimedL2) ~= "string" or claimedL2 == "" then return nil end
    local claimedLower = claimedL2:lower()

    local exactId = Resolve.l2ToConcept(claimedLower, palette)
    if exactId then
        return claimedLower, exactId
    end

    local foldedClaim = foldDiacritics(claimedLower)
    local bestId, bestL2 = nil, nil
    for conceptId, entry in pairs(palette.lex) do
        if type(entry) == "table" and type(entry.l2) == "string"
            and claimMatchesForm(foldedClaim, entry.l2:lower()) then
            if bestId == nil or tostring(conceptId) < tostring(bestId) then
                bestId, bestL2 = conceptId, entry.l2:lower()
            end
        end
    end
    if bestId ~= nil then
        return bestL2, bestId
    end
    return nil
end

-- Returns (true, canonicalL2Lower) on a valid mapping, false otherwise.
local function l1MapsToL2(palette, claimedL1, claimedL2)
    if type(palette) ~= "table" or type(palette.lex) ~= "table" then
        return false
    end
    if type(claimedL1) ~= "string" or type(claimedL2) ~= "string" then return false end

    local candidates = Concepts.byEnglish(claimedL1)
    if not candidates then return false end

    local foldedClaim = foldDiacritics(claimedL2:lower())
    -- Any candidate concept whose lex entry matches claimedL2 is a valid mapping;
    -- multi-candidate handling mirrors MC_Resolve.resolve's alphabetical iteration.
    for _, conceptId in ipairs(candidates) do
        local entry = palette.lex[conceptId]
        if type(entry) == "table" and type(entry.l2) == "string"
            and claimMatchesForm(foldedClaim, entry.l2:lower()) then
            return true, entry.l2:lower()
        end
    end
    return false
end

MC_Teaching.findL2InDictionary = findL2InDictionary
MC_Teaching.l1MapsToL2 = l1MapsToL2

-- DETECTION -- leftmost valid teaching pattern match; returns a single event
-- (or nil), one per utterance. State gates (speaker-acquired, speaker-produced,
-- receiver-heard) live in MC_Lang.renderWithLangs, not here -- this layer only
-- detects the pattern surface and validates against the dictionary.
--
-- Event shape:
--   { l1       = <string>,   -- typed casing (l2Only: the concept's English gloss)
--     l2       = <string>,   -- L2 word as typed
--     l2Lower  = <string>,   -- CANONICAL lex form (may differ: fold/multiword)
--     start    = <int>, finish   = <int>,   -- full match byte offsets
--     l1Start  = <int>, l1Finish = <int>,   -- absent for l2Only patterns
--     l2Start  = <int>, l2Finish = <int> }

function MC_Teaching.detect(message, palette)
    if type(message) ~= "string" or message == "" then return nil end
    if type(palette) ~= "table" then return nil end

    local patterns = getPatterns(palette)
    local messageLower = message:lower()
    local best = nil

    for _, p in ipairs(patterns) do
        if type(p) == "table" and type(p.pattern) == "string"
           and type(p.l2Group) == "number"
           and (p.l2Only == true or type(p.l1Group) == "number") then

            local pos = 1
            while pos <= #messageLower do
                local s, e, cap1, cap2 = messageLower:find(p.pattern, pos)
                if not s then break end

                if p.l2Only == true then
                    -- Single-capture form: dictionary supplies the concept; l1 becomes its English gloss.
                    local captures = { cap1, cap2 }
                    local l2Typed = captures[p.l2Group]
                    -- These patterns open on a literal word (this/that/it), which -- unlike the
                    -- two-capture patterns' (%w+) -- can match mid-word ("rabbit is called eau"); reject.
                    if s > 1 and messageLower:sub(s - 1, s - 1):match("%w") then
                        l2Typed = nil
                    end
                    if type(l2Typed) == "string" and l2Typed ~= "" then
                        local canonicalL2, conceptId = findL2InDictionary(palette, l2Typed)
                        if canonicalL2 then
                            local matchedSpan = message:sub(s, e)
                            local matchedLower = matchedSpan:lower()
                            local l2Start, l2Finish = nil, nil
                            local l2Rel = matchedLower:find(l2Typed, 1, true)
                            if l2Rel then
                                l2Start = s + l2Rel - 1
                                l2Finish = l2Start + #l2Typed - 1
                            end
                            if l2Start then
                                local concept = Concepts.get(conceptId)
                                local gloss = (concept and type(concept.en) == "table"
                                    and concept.en[1]) or l2Typed
                                local candidate = {
                                    l1       = gloss,
                                    l2       = message:sub(l2Start, l2Finish),
                                    l2Lower  = canonicalL2,
                                    start    = s,
                                    finish   = e,
                                    l2Start  = l2Start,
                                    l2Finish = l2Finish,
                                }
                                if not best or candidate.start < best.start then
                                    best = candidate
                                end
                            end
                        end
                    end
                elseif cap1 and cap2 and cap1 ~= "" and cap2 ~= "" then
                    local captures = { cap1, cap2 }
                    local l1Lower = captures[p.l1Group]
                    local l2Lower = captures[p.l2Group]

                    -- canonicalL2 is the lex spelling, which may differ from the typed
                    -- l2Lower (fold/multiword); the span math below stays on the typed forms.
                    local mapped, canonicalL2
                    if l1Lower ~= l2Lower then
                        mapped, canonicalL2 = l1MapsToL2(palette, l1Lower, l2Lower)
                    end
                    if mapped and canonicalL2 then

                        local matchedSpan = message:sub(s, e)
                        local matchedLower = matchedSpan:lower()
                        local l1Start, l1Finish, l2Start, l2Finish = nil, nil, nil, nil
                        local l1Rel = matchedLower:find(l1Lower, 1, true)
                        if l1Rel then
                            l1Start = s + l1Rel - 1
                            l1Finish = l1Start + #l1Lower - 1
                        end
                        local l2Rel = matchedLower:find(l2Lower, 1, true)
                        if l2Rel and l1Finish and (s + l2Rel - 1) >= l1Start
                           and (s + l2Rel - 1) <= l1Finish then
                            l2Rel = matchedLower:find(l2Lower, l1Rel + #l1Lower, true)
                        end
                        if l2Rel then
                            l2Start = s + l2Rel - 1
                            l2Finish = l2Start + #l2Lower - 1
                        end

                        if l1Start and l2Start then
                            local candidate = {
                                l1       = message:sub(l1Start, l1Finish),
                                l2       = message:sub(l2Start, l2Finish),
                                l2Lower  = canonicalL2,
                                start    = s,
                                finish   = e,
                                l1Start  = l1Start,
                                l1Finish = l1Finish,
                                l2Start  = l2Start,
                                l2Finish = l2Finish,
                            }
                            if not best or candidate.start < best.start then
                                best = candidate
                            end
                        end
                    end
                end

                pos = e + 1
            end
        end
    end

    if best then
        dbg("detect: teaching event for %s->%s at [%d..%d]",
            tostring(best.l1), tostring(best.l2), best.start, best.finish)
    end
    return best
end


return MC_Teaching
