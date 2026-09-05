-- MC_Lipread -- gappy fragment rendering for a Deaf receiver reading lips
-- off a spoken-language speaker they can see.
--
-- Real lipreading is genuinely lossy: only ~30-40% of speech is visually
-- distinguishable on the lips, the rest is context and guesswork. This
-- module is the "the rest is guesswork" half -- a pure text transform,
-- given whatever text the receiver's own normal comprehension render
-- already produced (client/MC_Anonymity.deafReception decides WHETHER to
-- call this at all; see its header for the full ladder). Deterministic per
-- (text, seed), like every other seeded render in this mod -- the same
-- utterance reads the same gaps every time, not a fresh roll per glance.
--
-- Never full comprehension, never improvable to full -- there is no state
-- here that climbs toward clarity. That is the real-life truth, and it
-- keeps signing (full-bandwidth) the reason to actually learn ASL rather
-- than lean on lipreading as a free bypass.
--
-- SCOPE NOTE: v1 legibility is a uniform per-word roll, not frequency-
-- weighted against a palette's zipf table as the spec's "existing zipf/
-- rank tooling" phrase suggests. The caller passes in whatever text the
-- receiver's own comprehension render already produced -- which, for a
-- non-comprehending receiver, is already babble carrying no reliable word-
-- frequency signal of its own. See the build report for the full reasoning.
--
-- PUBLIC API
--   M.LEGIBLE_RATIO                -- fraction of word tokens that survive
--   M.gapify(text, seed) -> string

local MC_StringUtils = require("MC_StringUtils")

local M = {}

M.LEGIBLE_RATIO = 0.35

-- "‥-" (two-dot ellipsis + dash) -- visually distinct from the production
-- pass's own groping marker family without colliding with it.
local GAP_MARKER = "\226\128\165-"

-- Tiny inlined LCG -- same shape as every other seeded picker in this mod
-- (MC_Babble.makeRng, MC_Lang's productiveRoll/buildSeed); no shared RNG
-- symbol so this module stays pure and dependency-free.
local function roll(seed)
    local s = math.floor(seed or 0) % 2147483648
    if s <= 0 then s = 1 end
    s = (s * 1103515245 + 12345) % 2147483648
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648
end

local function wordSeed(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
    if h == 0 then h = 1 end
    return h
end

-- M7 fix: a character counts as "word-like" if it's ASCII and matches %w,
-- or is non-ASCII at all (Cyrillic, accented Latin, CJK, emoji, ...) --
-- the old byte-oriented text:find("%w+") pattern only ever matched single
-- ASCII bytes, so a multi-byte character sitting right after an ASCII run
-- (e.g. "caf" + "\195\169" in "café") split OFF the ASCII prefix as one
-- "word" and left the multi-byte tail as a separate "other" token that was
-- never eligible for gapping and got glued back on verbatim next to a
-- GAP_MARKER -- readable-looking but semantically corrupted output, and
-- for a fully non-ASCII word (Cyrillic, etc.) the whole word silently
-- skipped the legibility roll entirely (always "legible" -- breaks the
-- never-full guarantee for non-Latin-script speech). Iterating by
-- MC_StringUtils.utf8chars -- this codebase's own VM-portable codepoint
-- walker (Lua 5.4 byte strings vs Kahlua's Java-composed codepoint
-- strings) -- means a multi-byte character is never split mid-sequence,
-- on either VM.
--
-- Byte-VALUE check, not #ch: under Lua 5.4, ch:byte(1) for a genuine ASCII
-- character is <128 and for a UTF-8 lead byte is >=0xC0; under Kahlua,
-- EVERY character (ASCII or composed) is a 1-length string (#ch == 1
-- always), but ch:byte(1) still returns the true codepoint value, so
-- >=128 correctly identifies "non-ASCII" on both storage models -- #ch
-- alone can't (it's always 1 under Kahlua regardless of codepoint).
local function isWordChar(ch)
    local b1 = ch:byte(1)
    if not b1 then return false end
    if b1 >= 128 then return true end
    return ch:match("%w") ~= nil
end

-- text -> gappy fragment string. Consecutive gapped words collapse into a
-- single marker (matches the spec's own example shape: legible spans
-- separated by ONE gap, not one marker per lost word). Two passes: first
-- tokenize + roll every word, then assemble -- the two-pass split is what
-- lets the never-full guarantee below see the WHOLE roll before deciding
-- anything is final.
function M.gapify(text, seed)
    if type(text) ~= "string" or text == "" then return text end

    local tokens = {}   -- { kind = "word"|"other", text, legible }
    local wordIdx = {}  -- indices into `tokens` that are word entries

    local wordBuf, otherBuf = nil, nil
    local function flushWord()
        if not wordBuf then return end
        local word = table.concat(wordBuf)
        local legible = roll(wordSeed(word:lower()) + (seed or 0)) < M.LEGIBLE_RATIO
        tokens[#tokens + 1] = { kind = "word", text = word, legible = legible }
        wordIdx[#wordIdx + 1] = #tokens
        wordBuf = nil
    end
    local function flushOther()
        if not otherBuf then return end
        tokens[#tokens + 1] = { kind = "other", text = table.concat(otherBuf) }
        otherBuf = nil
    end

    for ch in MC_StringUtils.utf8chars(text) do
        if isWordChar(ch) then
            flushOther()
            wordBuf = wordBuf or {}
            wordBuf[#wordBuf + 1] = ch
        else
            flushWord()
            otherBuf = otherBuf or {}
            otherBuf[#otherBuf + 1] = ch
        end
    end
    flushWord()
    flushOther()

    -- HARD GUARANTEE, not just a statistically-likely outcome: real
    -- lipreading never reaches full comprehension, at any seed, on any
    -- input. If every word happened to roll legible, force the last one
    -- to gap instead -- a short message has too few words for the roll's
    -- own odds to make this properly rare.
    if #wordIdx > 0 then
        local allLegible = true
        for _, idx in ipairs(wordIdx) do
            if not tokens[idx].legible then allLegible = false; break end
        end
        if allLegible then
            tokens[wordIdx[#wordIdx]].legible = false
        end
    end

    local out = {}
    local lastWordGapped = false
    for _, tok in ipairs(tokens) do
        if tok.kind == "other" then
            out[#out + 1] = tok.text
        elseif tok.legible then
            out[#out + 1] = tok.text
            lastWordGapped = false
        else
            if not lastWordGapped then out[#out + 1] = GAP_MARKER end
            lastWordGapped = true
        end
    end
    return table.concat(out)
end

return M
