--[[
================================================================================
    MongooseChat - Acquisition Module (v8.16.2)

    Per-username x per-source-language x per-token exposure tables, plus the
    pure comprehension formula mapping exposure into the partial-clarity render
    decision. Spine of the language-learning system: MC_Lang's dictionary
    substitution layer reads from here on every render.

    WHAT THIS OWNS: the acquisition table (in-memory, MC_Persist A/B slots);
    the pure comprehension formula (Zipfian prior + exposure sigmoid, cap);
    acquisition-threshold detection; LRU eviction at a per-language token cap;
    periodic dirty-flag flush for ordinary beats, plus synchronous verified
    commits for acquisition crossings and direct teaching grants.

    WHAT THIS DOES NOT OWN: dictionary substitution (MC_Lang's render path
    calls recordExposureBatch with the heard L2 tokens); the AUTHORITATIVE
    teaching detection and instant-grant gate -- template matching (translation
    pairs, TPR) lives in MC_Teaching.lua, dispatch/delivery in MC_Lang.lua;
    this module only supplies recordTeaching as the write target once that
    gate fires. It DOES own teachingContextBoosts (TEACHING DETECTION,
    below): a soft, one-shot salience heuristic -- repetition (>=2x in one
    message) and co-occurrence with an already-acquired token -- that nudges
    ordinary exposure weight, no gate, no instant grant; easy to conflate
    with the authoritative path above but structurally distinct from it;
    /lex and /comp wire-up (MC_Lang dispatches those).

    DESIGN INVARIANTS (do not violate)
      1. Pure read-side API: queries are O(1) hash lookups, never mutate.
      2. Comprehension formula is a pure function on (count, contextBoost,
         zipfRank): reproducible, testable, swappable.
      3. Engine independence: imports MC_Core, MC_Persist, and MC_LangRegistry
         (plus lazy, call-site requires of MC_Concepts/MC_Resolve for the
         connection-bonus lookups, below); reads palette.lex/palette.family
         as read-only data via MC_LangRegistry.getPalette. Never imports
         MC_Babble (the phonetic engine) or anything that itself calls
         sendServerCommand/reads SandboxVars (invariant 3a) -- the boundary
         is "no engine coupling, no side-effect coupling," not "no palette
         data."
      3a. Engine purity (docs/ARCHITECTURE.md): never reads Events,
          sendServerCommand, or SandboxVars, and never registers against
          Events. Every side effect is injected -- setExposureTraceSink /
          setLapseNoticeSink for outbound notifications, setProfile / setSpeed
          for server-pinned tuning, and onServerStarted / onEveryOneMinute
          (LIFECYCLE EVENTS, below) as named functions the composition root
          (MC_Server.lua) registers on its own Events. This module supplies
          behavior; it never decides when that behavior runs.
      4. Procedural-babble tokens are NEVER tracked -- only lex tokens
         (resolving to a concept the speaker's palette lexicalizes) enter the
         exposure table, bounding per-user table size.
      5. contextBoost is multiplicative, capped at 2.0, so stacked teaching
         boosts (applyContextBoost) can't run away.

    DATA SHAPE (in memory; mirrored to disk by MC_Persist)
      MC_AcquisitionDB = {
          version = 1,
          users = {
              [username] = {
                  [sourceLang] = {
                      firstExposure   = <unix seconds>,
                      totalTokensHeard = <integer>,  -- aggregate, for /comp
                      tokensHeard = {
                          [tokenLower] = {
                              count        = <number>,  -- weighted exposure beats
                              lastHeard    = <unix seconds>,
                              contextBoost = <number, default 1.0, capped 2.0>,
                              acquired     = <bool, true once crossing fires>,
                              produced     = <number>,         -- v8.7 productive axis
                              lastProduced = <unix secs|nil>,  -- v8.9 productive decay clock
                              producedAttempts = <integer>,    -- v8.9 fractional credit
                              stability    = <integer>,        -- v8.9 spaced-retrieval durability
                              -- v8.16.1 "Voices" (nil-tolerant on legacy records --
                              -- absent means voices=1, firstVoice unknown, window cold):
                              voices       = <array of distinct speaker usernames, capped
                                              at VOICES_TRACK_CAP; append-only>,
                              firstVoice   = <username|nil, set ONLY at record creation
                                              when known; never backfilled>,
                              windowStart  = <unix seconds|nil, saturation window anchor>,
                              windowCount  = <integer|nil, beats inside current window>,
                          },
                          ...
                      },
                  },
                  ...
              },
          },
      }

    PUBLIC API -- ~51 functions, grouped by the file's section banners (full
    signatures/behavior live in each section's own comments):
      Recording: recordExposureBatch(username, sourceLang, tokenEntries,
        contextBoostMap, addressed, speakerUsername) -> tokensCrossed, meta --
        the passive-exposure write path (see its own doc comment); plus
        applyContextBoost / teachingContextBoosts, the one-shot / persistent
        boost primitives the teaching layer plugs into.
      Production tracking (v8.7-v8.9): recordProduction,
        recordProductionAttempt, hasProduced, productiveProb,
        productiveProbForRecord, effectiveProduced.
      Teaching (v8.7 instant-grant): recordTeaching(username, sourceLang,
        token, rank, teacherUsername) -> bool.
      Queries (read-only): getExposure, getAllTokens, getMisacquisition,
        acquiredCountForPalette, acquiredCountForCore, estimateComprehension,
        hasAcquiredAny, languagesWithData, teachingImpact.
      Pure formula/classifier: comprehensionProb, isAcquiredByFormula,
        tokenState, effectiveTokenCap.
      Reset (/forget + admin): forgetLanguagePersisted,
        forgetUserPersisted, inventoryForUser.
      Connection (v8.9 cross-language/cross-token bonuses):
        familyClosenessPrior/ForLang, accentTintPrior/ForLang, familyBonus,
        lexicalSetBonus, dynamicContextBoost. (The count-driven pure formulas
        behind these -- familyBonusFromCount, lexicalSetBonusFromCount,
        voicesBonusFromCount, saturationFactor -- and the per-exposure
        weighting helpers -- registerWeightForToken, addressednessWeight,
        voicesCountOf -- are module-internal locals, not public API.)
      Server-injected configuration (invariant 3a): setProfile/activeProfile,
        setSpeed, setExposureTraceSink, setLapseNoticeSink -- MC_Server.lua
        and MC_Lang.lua are the only legitimate callers.
      Lifecycle hooks (exported, not self-registered; invariant 3a):
        onServerStarted, onEveryOneMinute.
      Form migrations (v8.16.1 token-key renames): applyFormMigrations.
      Test/diagnostic surface: setTestTime, clearTestTime, flushNow,
        applyDecayToRecord (offline harness), plus read-only tuning-constant
        getters (acquisitionThreshold, graceDaysReceptive,
        decayPerDayReceptive, decayChargeCapDays, voicesTrackCap,
        secondsPerDay) that /lex, /comp, and the offline suite read directly.

    Author: Kialae (Mongoose Server). License: MIT.
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Persist = require("MC_Persist")
local MC_LangRegistry = require("MC_LangRegistry")

local MC_Acquisition = {}

local dbg = MC_Core.debugger("LANG_ACQ")

-- TUNING CONSTANTS -- each carries its own calibration rationale below. The
-- design doc these were once checked against, docs/LANGUAGE_LEARNING_PHILOSOPHY.md,
-- was lost with an ephemeral workspace (see docs/ARCHITECTURE.md). Module
-- constants for now.

-- Per-token comprehension cap: a listener with /lang english never exceeds
-- this even with maximum exposure to French -- they must commit (/lang french)
-- for full clarity.
local COMPREHENSION_CAP = 0.70

-- Crossing point for the "new word came through clear" whisper -- once a
-- token's deterministic comprehensionProb crosses this, acquired=true fires.
-- Lower = more generous feedback events; higher = rarer and more meaningful.
local ACQUISITION_THRESHOLD = 0.50

-- babble-resolve comprehension -> resolution-level mapping: a heard word
-- resolves from pure texture (level 0) to clean (level 1) as comprehension
-- rises from FLOOR to CLEAN. FLOOR = 0.10 (2026-06-05): a barely-heard word
-- stays pure babble until crossing 0.10, dramatising the friction without
-- gating. CLEAN pins to the acquisition threshold (clarifies exactly as the
-- gloss takes over). Consumed by MC_Babble.resolveWord; design doc
-- docs/BABBLE_RESOLVE.md was lost -- see docs/ARCHITECTURE.md.
local RESOLVE_FLOOR_PROB = 0.10
local RESOLVE_CLEAN_PROB = 0.50

-- Decayed-clarity floor (v8.16.2): an ACQUIRED word decaying back below the
-- crossing level degrades smoothly toward this floor instead of staying
-- perfectly clear until it vanishes (the old cliff) -- tokenState maps raw
-- comprehensionProb onto [floor..1.0]. Never worse than a not-yet-acquired
-- word at the same count (which gets no gloss at all).
local DECAYED_CLARITY_FLOOR = 0.85

-- Familiarity threshold: once raw exposure count reaches this (post-
-- acquisition), the render shifts from "fresh" (warm honey-gold, full alpha)
-- to "familiar" (soft-purple aside, reduced alpha) -- the word settling into
-- working vocabulary. Raise to keep words in the reward state longer.
local FAMILIAR_COUNT = 20

-- Default contextBoost for a newly-exposed token; the teaching layer bumps
-- it via applyContextBoost (persistent) or the one-shot contextBoostMap in
-- recordExposureBatch (per-hearing).
local DEFAULT_CONTEXT_BOOST = 1.0
local MAX_CONTEXT_BOOST     = 2.0

-- Misacquisition (v8.16.1): a newly-acquired word has a chance to associate
-- with a wrong meaning from the same semantic neighborhood, shown in /lex
-- and the render bracket until corrected by exposure (familiar-count) or
-- teaching -- colors earned words, never denies them. Common words (low rank)
-- are too well-contextualized to misacquire; 0.0 = off for a band, and the
-- whole mechanic is a no-op when every value is 0.
local MISACQUIRE_CHANCE = {
    { 10, 0.00 },   -- rank 1-10: never (too common / too early / too obvious)
    { 50, 0.15 },   -- rank 11-50: 15% chance
    { 9999, 0.25 }, -- rank 51+: 25% chance
}

-- Teaching detection -- graded acceleration from soft signals (knob at zero).
-- teachingContextBoosts emits a one-shot contextBoostMap from these per-signal
-- multipliers; 1.0 = neutral = off, so the detector early-outs to a true no-op.
local REPETITION_BOOST   = 1.5  -- speaker repeats an L2 token (>=2x) in one message
local COOCCURRENCE_BOOST = 1.25 -- un-acquired token shares a message with an acquired one

-- Eavesdropping asymmetry (knob at zero): count-weight for an OVERHEARD
-- exposure relative to one ADDRESSED to the listener (1.0 = parity). Applied
-- per exposure in recordExposureBatch. The addressed/overheard signal itself
-- isn't wired yet (needs the backlogged directed-speech feature), so at 1.0
-- this is a true no-op and nothing is ever marked overheard regardless.
local OVERHEARD_EXPOSURE_WEIGHT = 0.6

-- Comprehensible-input bonus (Krashen i+1): a word heard in a message where
-- the listener already understands most L2 tokens acquires faster than one
-- in a wall of babble. Computed per-batch from the fraction of distinct L2
-- tokens already acquired: weight *= 1 + BONUS * ratio. At 0.5, understanding
-- 70% of a message's L2 words gives each token 1.35x credit; understanding
-- none gives 1.0x. Single-token messages get no bonus (no context to
-- comprehend). 0.0 disables the mechanic.
local COMPREHENSIBLE_INPUT_BONUS = 0.5

-- v8.16.1 "Voices" -- saturation: massed same-token exposure inside a short
-- rolling window earns diminishing increments (first beat full weight, beat N
-- worth 1/(1 + SATURATION_K*(N-1))). Spaced exposure builds durability instead
-- (the stability bump in recordExposureBatch); this is the acquisition-side
-- mirror. K = 0 disables the mechanic.
local SATURATION_K              = 0.20
local SATURATION_WINDOW_SECONDS = 3600

-- Register tiers (knob at zero): a token's effective acquisition boost
-- multiplies by the weight(s) of the lexicalSet(s) (MC_Concepts.lexicalSets)
-- its concept belongs to. 1.0 = neutral, >1.0 = faster (survival vocabulary),
-- <1.0 = slower. Applied at the acquisition crossing-check, so it changes
-- WHEN a token is acquired, not production. All 1.0 => true no-op.
local REGISTER_WEIGHT = {
    survival  = 1.5,
    social    = 1.5,
    motion    = 1.0,
    body      = 1.0,
    sensation = 1.5,
}

-- Receptive exposure curve: saturating exponential, FRONT-LOADED (biggest
-- gains in the first few exposures, diminishing after -- the negatively-
-- accelerated L2 acquisition learning curve; derivation doc
-- docs/LANGUAGE_ACQUISITION.md was lost, see docs/ARCHITECTURE.md). The
-- tunable knob is EXPOSURE_ACQUIRE_COUNT -- effective exposures an off-list
-- word needs to cross ACQUISITION_THRESHOLD; rate k derives from it so curve,
-- cap, and threshold stay self-consistent under tuning.
local EXPOSURE_ACQUIRE_COUNT = 9
local EXPOSURE_K = -math.log(1 - ACQUISITION_THRESHOLD / COMPREHENSION_CAP) / EXPOSURE_ACQUIRE_COUNT
-- Production stays a logistic with a delayed onset: perceive and comprehend
-- before you can produce, so it ramps later than reception.
local PRODUCTION_SIGMOID_MIDPOINT  = 30
local PRODUCTION_SIGMOID_STEEPNESS = 0.10

-- Per-user*per-language token table cap; beyond it, least-recently-heard
-- tokens evict on the next recordExposureBatch. v8.16.1: the cap SCALES with
-- the palette's lexicon (floor below, or 1.25x lex size, whichever is larger)
-- -- 500 sat just above the 462-concept core, but corpus growth toward ~1000
-- concepts would otherwise LRU-evict the most dedicated learners' words
-- first. Cached per language (reboot invalidates, same as any lexicon change).
local PER_LANGUAGE_TOKEN_CAP = 500
local LEX_CAP_HEADROOM = 1.25
local effectiveCapCache = {}
local function effectiveTokenCap(sourceLang)
    local cached = effectiveCapCache[sourceLang]
    if cached then return cached end
    local cap = PER_LANGUAGE_TOKEN_CAP
    if MC_LangRegistry and MC_LangRegistry.getPalette then
        local palette = MC_LangRegistry.getPalette(sourceLang)
        if palette and type(palette.lex) == "table" then
            local n = 0
            for _ in pairs(palette.lex) do n = n + 1 end
            local scaled = math.ceil(n * LEX_CAP_HEADROOM)
            if scaled > cap then cap = scaled end
        end
    end
    effectiveCapCache[sourceLang] = cap
    return cap
end

-- Zipf base-probability by rank in palette.zipf, as data: { maxRank, prob },
-- ascending -- first band whose maxRank >= rank wins; off-list gets 0 (acquired
-- only via exposure-driven sigmoid). Data rather than branches so bands stay
-- inspectable and tunable in one place.
local ZIPF_BASE_PROB = {
    { 10, 0.50 }, { 25, 0.30 }, { 50, 0.15 }, { 100, 0.05 }, { 250, 0.01 },
}
local function zipfBaseProb(rank)
    if not rank or rank <= 0 then return 0.0 end
    for _, band in ipairs(ZIPF_BASE_PROB) do
        if rank <= band[1] then return band[2] end
    end
    return 0.0
end

-- FAMILY CLOSENESS PRIOR -- static cross-family head-start (knob at zero)
-- A listener understands a little of a language before any exposure when it's
-- close to their L1 family -- an English ear catches more of a Romance word
-- than a Turkic one from word one. Static head-start into the comprehension
-- prior, keyed by (listener-L1-family x heard palette family); distinct from
-- the dynamic family BONUS (count-driven, needs prior acquisition -- this
-- exists at count 0).
--
-- Values (8.16.0/8.16.1): English->Romance highest (French/Latin vocabulary
-- overlap, cognates, shared morphology); English->Slavic modest (some shared
-- European cultural vocabulary, fewer cognates); English->Turkic zero
-- (genuinely distant; shared Arabic/Persian loanwords too few/domain-specific
-- for a blanket prior). Effect is subtle: mid-ranked Romance words resolve
-- slightly faster and acquire about half an exposure sooner; rank 1-10 words
-- already acquire in one hearing regardless. Unknown family pairs return 0.0.
-- Table is [l1Family][heardFamily] -> head-start.
local RECEIVER_L1_FAMILY = "english"  -- current deployments are English-L1
local FAMILY_CLOSENESS = {
    english = { romance = 0.03, slavic = 0.01, turkic = 0.0 },
}

-- Pure lookup: head-start for an L1 family hearing a palette family. Testable.
function MC_Acquisition.familyClosenessPrior(l1Family, heardFamily)
    if not l1Family or not heardFamily then return 0.0 end
    local row = FAMILY_CLOSENESS[l1Family]
    return (row and row[heardFamily]) or 0.0
end

-- Resolver: head-start for the receiver hearing `sourceLang`, from the
-- registered palette.family and the receiver's L1 family. Constant across a
-- language's tokens for a given receiver, so call sites compute it once per
-- render/batch rather than per token.
function MC_Acquisition.familyClosenessForLang(sourceLang)
    if not sourceLang then return 0.0 end
    if not MC_LangRegistry or not MC_LangRegistry.getPalette then return 0.0 end
    local palette = MC_LangRegistry.getPalette(sourceLang)
    local heardFamily = palette and palette.family
    return MC_Acquisition.familyClosenessPrior(RECEIVER_L1_FAMILY, heardFamily)
end

-- ACCENT TINT -- per-listener phonetic colour into the babble seed (knob at zero)
-- The same word babbles in the listener's native phonetic colour: a Slavic-L1
-- ear and an English-L1 ear hear a French word shaped differently. Keyed by
-- (receiver L1 family x heard palette family), feeds a phase into MC_Lang's
-- internal babble seed, shifting which variant surfaces per listener.
-- Lives here beside FAMILY_CLOSENESS (shares RECEIVER_L1_FAMILY, drift-checked
-- together); the seed fold itself lives in MC_Lang.
--
-- All phases are placeholder 0.0 (8.16.0) -> seed unchanged -> no-op. With a
-- single L1 (all players English) the tint stays imperceptible even when
-- tuned -- it only colours anything once listeners have different L1s.
local ACCENT_TINT = {
    english = { romance = 0.0, slavic = 0.0, turkic = 0.0 },
}

-- Pure lookup: babble-seed phase for an L1 family hearing a palette family.
function MC_Acquisition.accentTintPrior(l1Family, heardFamily)
    if not l1Family or not heardFamily then return 0.0 end
    local row = ACCENT_TINT[l1Family]
    return (row and row[heardFamily]) or 0.0
end

-- Resolver for the babble seed: phase for the receiver hearing `sourceLang`,
-- from the registered palette.family and the receiver's L1 family.
function MC_Acquisition.accentTintForLang(sourceLang)
    if not sourceLang then return 0.0 end
    if not MC_LangRegistry or not MC_LangRegistry.getPalette then return 0.0 end
    local palette = MC_LangRegistry.getPalette(sourceLang)
    local heardFamily = palette and palette.family
    return MC_Acquisition.accentTintPrior(RECEIVER_L1_FAMILY, heardFamily)
end

-- Exposure curve: effective exposure (count * contextBoost) -> comprehension
-- contribution. Saturating exponential, FRONT-LOADED (biggest gains in the
-- first few exposures; matches the L2 acquisition literature -- derivation doc
-- docs/LANGUAGE_ACQUISITION.md is lost, see docs/ARCHITECTURE.md). Shape:
--   0 exposures: 0.00 | ~1: ~0.09 (a trace) | ~5: ~0.35
--   ~9: ~0.50 (acquisition threshold) | ~20: ~0.66 | asymptote: 0.70 (CAP)
-- exposureProb = CAP * (1 - exp(-k * effective)); k derives so an off-list
-- word crosses the threshold at EXPOSURE_ACQUIRE_COUNT -- same headroom-filling
-- idea the prior uses, applied to the exposure axis.
local function exposureProb(effective)
    if not effective or effective <= 0 then return 0.0 end
    return COMPREHENSION_CAP * (1.0 - math.exp(-EXPOSURE_K * effective))
end

-- Composed formula. Inputs are raw record values + the rank lookup; returns
-- a probability in [0, COMPREHENSION_CAP].
function MC_Acquisition.comprehensionProb(count, contextBoost, zipfRank, familyCloseness)
    local effective = (count or 0) * (contextBoost or DEFAULT_CONTEXT_BOOST)
    -- Headroom combination: prior (Zipf rank + any static family head-start)
    -- is the floor; exposure fills the remaining headroom -> prior +
    -- exposure*(1-prior). familyCloseness lifts the baseline and defaults to 0
    -- (unaffected without family context). COMPREHENSION_CAP clamp stays a
    -- safety belt, not the limiter. (docs/LANGUAGE_ACQUISITION.md, the lost
    -- original derivation -- see docs/ARCHITECTURE.md.)
    local prior = zipfBaseProb(zipfRank) + (familyCloseness or 0.0)
    if prior < 0 then prior = 0 end
    if prior > COMPREHENSION_CAP then prior = COMPREHENSION_CAP end
    local p = prior + exposureProb(effective) * (1.0 - prior)
    if p < 0 then p = 0 end
    if p > COMPREHENSION_CAP then p = COMPREHENSION_CAP end
    return p
end

function MC_Acquisition.isAcquiredByFormula(count, contextBoost, zipfRank, familyCloseness)
    return MC_Acquisition.comprehensionProb(count, contextBoost, zipfRank, familyCloseness)
        >= ACQUISITION_THRESHOLD
end

function MC_Acquisition.acquisitionThreshold() return ACQUISITION_THRESHOLD end

-- Given a token that just crossed the acquisition threshold, roll a
-- rank-scaled chance and (on hit) pick a wrong concept from the same lexical
-- set the palette lexicalizes. Returns the wrong concept ID or nil.
-- Deterministic per (token, now) for replay stability.
local function pickMisacquisitionConcept(sourceLang, token, rank, now)
    local chance = 0
    for _, band in ipairs(MISACQUIRE_CHANCE) do
        if (rank or 9999) <= band[1] then chance = band[2]; break end
    end
    if chance <= 0 then return nil end

    local seed = 0
    for i = 1, #token do seed = (seed * 31 + token:byte(i)) % 2147483647 end
    seed = (seed + (now or 0)) % 2147483647

    local roll = (seed % 1000) / 1000
    if roll >= chance then return nil end

    if not MC_LangRegistry or not MC_LangRegistry.getPalette then return nil end
    local palette = MC_LangRegistry.getPalette(sourceLang)
    if not palette then return nil end
    local Concepts = require("MC_Concepts")
    local Resolve  = require("MC_Resolve")
    local conceptId = Resolve.l2ToConcept(token, palette)
    if not conceptId then return nil end

    local sets = Concepts.setsForConcept(conceptId)
    if #sets == 0 then return nil end
    local candidates = {}
    local seen = { [conceptId] = true }
    for _, setName in ipairs(sets) do
        for _, cid in ipairs(Concepts.lexicalSets[setName] or {}) do
            if not seen[cid] and palette.lex and palette.lex[cid] then
                seen[cid] = true
                candidates[#candidates + 1] = cid
            end
        end
    end
    if #candidates == 0 then return nil end

    return candidates[(seed % #candidates) + 1]
end

-- Forward declaration: getLangTable is defined further down (ENTRY ACCESS /
-- MUTATION section); getMisacquisition below references it, and Lua doesn't
-- hoist locals, so without this the name would bind to a nil global at call
-- time and every misacquisition lookup would throw.
local getLangTable

-- Public accessor: what is the misacquired concept for a token (nil = none).
function MC_Acquisition.getMisacquisition(username, sourceLang, token)
    if not username or not sourceLang or not token then return nil end
    local langTable = getLangTable(username, sourceLang)
    if not langTable then return nil end
    local rec = langTable.tokensHeard[token:lower()]
    return rec and rec.misacquiredAs or nil
end
-- v8.16.1: the live cap for a language (floor or 1.25x lex size).
MC_Acquisition.effectiveTokenCap = effectiveTokenCap

-- PRODUCTIVE CURVE (v8.8 -- "Practice")
--
-- Production lags reception: substitution in applyProductionPass rolls
-- against a probability derived from `produced` count (mirroring the
-- receptive formula, slower trajectory) rather than a binary `acquired` check.
--
-- DESIGN INTENT: real fluency has production trailing reception, sometimes by
-- a lot -- a learner who understands "eau" when heard may blank saying it.
-- Modeled as ambient experience: the speaker types English, the engine rolls
-- per-word against the productive probability, and on failure the L1 passes
-- through as plain text -- the listener hears the wrong word said. Success
-- increments `produced`, raising future probability; failures don't decrement
-- (decay is v8.9). Same immersion-interface lineage as v8.7: no notification
-- fires: the plain L1 IS the blank, felt in what came out.
--
-- ROLL-PER-WORD: one roll per unique L2 token per utterance, deterministic on
-- (speaker, message, timestamp, l2Lower) -- repeats of the same word in one
-- message share the result. Roll cache lives in MC_Lang's applyProductionPass;
-- recordProduction fires once per word per message (caller-managed).

-- Production probability cap, higher than COMPREHENSION_CAP (0.70) -- a
-- well-practised word should reach near-fluent production, but never 100%
-- (real learners still occasionally fumble highly-practised vocabulary).
local PRODUCTION_CAP = 0.95

-- Floor for acquired-but-never-produced words: SOME chance to slip a
-- just-acquired word into speech, avoiding a chicken-and-egg lock-out where
-- production requires producing first.
local PRODUCTION_FLOOR = 0.15

-- Productive sigmoid, same shape as exposureProb but a higher midpoint --
-- production needs more attempts than reception needs exposures (receptive
-- midpoint 20, productive 30: a word produced 30 times sits near where a
-- word heard 20 times sits on the receptive curve).
local function productiveExposureProb(effective)
    if not effective or effective <= 0 then return 0.0 end
    local midpoint  = PRODUCTION_SIGMOID_MIDPOINT
    local steepness = PRODUCTION_SIGMOID_STEEPNESS
    local raw = 1.0 / (1.0 + math.exp(-steepness * (effective - midpoint)))
    local baseAt0 = 1.0 / (1.0 + math.exp(steepness * midpoint))
    return math.max(0, (raw - baseAt0) * PRODUCTION_CAP / (1.0 - baseAt0))
end

-- Composed productive probability. Inputs mirror comprehensionProb; returns a
-- probability in [PRODUCTION_FLOOR, PRODUCTION_CAP]. Zipf base prob still
-- applies (common words are easier to produce, same as to comprehend).
-- Without PRODUCTION_FLOOR, a freshly-acquired rare word (rank > 250,
-- zipfBaseProb=0, produced=0, exposureProb=0) would have prob=0 and never
-- roll true, locking the learner out of practising it -- the floor gives
-- every acquired word a 15% baseline chance to slip out.
function MC_Acquisition.productiveProb(produced, contextBoost, zipfRank)
    local effective = (produced or 0) * (contextBoost or DEFAULT_CONTEXT_BOOST)
    local prior = zipfBaseProb(zipfRank)
    local p = prior + productiveExposureProb(effective) * (1.0 - prior)
    if p < PRODUCTION_FLOOR then p = PRODUCTION_FLOOR end
    if p > PRODUCTION_CAP   then p = PRODUCTION_CAP   end
    return p
end

-- TIME SOURCE (v8.9) -- all decay-relevant timestamps flow through this one
-- function: production reads real wall-clock time, tests override via
-- setTestTime. Message timestamps (used to seed production rolls) are
-- input-only and must never stand in for "now" in a decay calculation --
-- otherwise a test's fake 2024 timestamps would fire spurious decay against
-- the live Calendar clock on every subsequent read. Centralising the clock
-- keeps both sides clean.

local testTimeOverride = nil

function MC_Acquisition.setTestTime(t)
    testTimeOverride = t
end

function MC_Acquisition.clearTestTime()
    testTimeOverride = nil
end

local function currentTime()
    return testTimeOverride or MC_Core.getTimeSeconds()
end

-- DECAY (v8.9 -- "Drift") -- the fourth side of the fluency model. v8.5-v8.8
-- added gain (passive exposure, teaching, practice); v8.9 adds loss: words
-- unused long enough drift below threshold and are forgotten. Receptive and
-- productive decay independently, productive faster -- the canonical
-- asymmetry where you can still recognise a word you can no longer say.
--
-- LAZY EVALUATION: no timer, no periodic sweep. Every public read/write that
-- touches a record applies pending decay first via applyDecayToRecord --
-- stored values become correct at the moment consulted, invisibly stale
-- between. Keeps the engine pure-functional in time: decay is always
-- computable from (lastHeard/lastProduced, count/produced, now); tests pass
-- an explicit `now`, production passes MC_Core.getTimeSeconds().
--
-- GRACE + DAILY DECAY (two-phase): no decay within the grace period after the
-- last event; after grace, count/produced drops a fixed amount per day. A
-- decaying word stays `acquired` but its render degrades smoothly with the
-- falling count (see tokenState). Only at count 0 is it fully forgotten:
-- `acquired` flips false and one quiet lapse notice fires (LAPSE NOTICE,
-- below). Teaching-acquired words decay exactly like passive-acquired ones --
-- the remedy is the same either way: hear it, use it, practice it.
--
-- ABSENCE DISCOUNT (v8.16.2): decay is charged lazily per gap since last
-- consulted, capped at DECAY_CHARGE_CAP_DAYS days past grace however long the
-- silence really was -- a break costs a little rust, never the language (the
-- locked rule: never deny a player a word they've earned).
--
-- LAST-HEARD CONSUMPTION: after decay applies, lastHeard advances to
-- `now - GRACE_SECONDS`, so the next check measures elapsed-past-grace from
-- there -- continuous-decay semantics equivalent to one polled-at-30 query
-- regardless of how many polls land during a 30-day idle window.
--
-- SPACING (RETRIEVAL-STRENGTHENING): a word re-heard after cooling past grace
-- is an effortful, spaced retrieval that builds durability -- recordExposureBatch
-- increments `stability` on each one (capped at STABILITY_MAX; massed
-- re-hearings within grace build nothing). Stability divides the daily decay
-- rate (rate = DECAY_PER_DAY_* / (1 + stability)) and persists through
-- forgetting, so a lapsed-but-once-spaced word relearns faster and sticks
-- harder (the savings effect). No stability field decays exactly as 0 --
-- existing saves stay safe.

-- Receptive grace: hearing a word resets the decay clock; no count drops for
-- this many days of silence afterward (a word just heard doesn't fade overnight).
local GRACE_DAYS_RECEPTIVE = 7

-- Receptive decay rate (count/day, post-grace). At rate=1, a familiar-
-- threshold word (count=20) takes 20 days post-grace to fully forget --
-- ~27 days from last exposure to total loss combined with grace.
local DECAY_PER_DAY_RECEPTIVE = 1

-- Productive grace, shorter than receptive: productive vocabulary is
-- fragile -- you can recognise a word a year after last use but lose the
-- ability to produce it much sooner.
local GRACE_DAYS_PRODUCTIVE = 3

-- Productive decay rate (produced/day, post-grace). At rate=2, a saturated
-- produced=30 takes 15 days post-grace to fully lose -- about half as long
-- as receptive, the canonical asymmetry.
local DECAY_PER_DAY_PRODUCTIVE = 2

-- Absence discount (v8.16.2): one lazily-evaluated gap charges at most this
-- many days of decay past grace, however long the silence really was --
-- decay is only consulted when a record is touched again, so active-play
-- gaps stay short and this cap rarely binds. Exists so a long absence can't
-- erase earned words wholesale (a 30-day break used to delete every word
-- below count 23). Applies to both axes; expressed in profile-days, so it
-- scales with the active profile's clock.
local DECAY_CHARGE_CAP_DAYS = 2

-- Failed-attempt fractional credit (recordProductionAttempt): a failed
-- production roll still represents cognitive effort and consolidates partial
-- credit toward the productive curve -- four failures equate to one success.
-- Cleaner than mutating `produced` to float.
local ATTEMPT_CREDIT = 0.25

-- Spacing effect cap: a word re-heard after cooling past receptive grace is
-- an effortful, spaced retrieval that increments record.stability (capped
-- here), which slows future receptive decay: rate = DECAY_PER_DAY_RECEPTIVE
-- / (1 + stability). Re-hearing within grace (massed/cramming) builds nothing
-- -- too short a gap leaves nothing forgotten for retrieval to strengthen.
-- At the cap, decay is (1+STABILITY_MAX)x slower -- a count-20 word survives
-- ~140 days post-grace rather than ~20.
local STABILITY_MAX = 6

-- Seconds in a day, broken out for readability.
local SECONDS_PER_DAY = 86400

-- ACQUISITION PROFILES (v8.16.1) -- the tuning constants above are calibrated
-- for weeks of live play. A profile swaps the TIME SCALE while keeping every
-- ratio faithful (eavesdrop weight, saturation K, voices/family caps, zipf
-- bands never change between profiles). `live`: the shipped calibration,
-- default and currently the only profile -- reads the constants themselves at
-- definition time (single source of truth, zero drift). Profile selection is
-- injected from the server side (this module is engine-independent).
local PROFILES = {
    live = {
        exposureAcquireCount      = EXPOSURE_ACQUIRE_COUNT,
        familiarCount             = FAMILIAR_COUNT,
        productionSigmoidMidpoint = PRODUCTION_SIGMOID_MIDPOINT,
        secondsPerDay             = SECONDS_PER_DAY,
        saturationWindowSeconds   = SATURATION_WINDOW_SECONDS,
        graceDaysReceptive        = GRACE_DAYS_RECEPTIVE,
        graceDaysProductive       = GRACE_DAYS_PRODUCTIVE,
        decayPerDayReceptive      = DECAY_PER_DAY_RECEPTIVE,
        decayPerDayProductive     = DECAY_PER_DAY_PRODUCTIVE,
    },
}
local activeProfileName = "live"

-- v8.16.2 learning-speed knob (AcquisitionSpeed sandbox option), layered over
-- the active profile: a factor on the BEAT-COUNT constants (hearings needed
-- to cross, consolidate, produce) and grace days, so the whole arc stretches
-- or compresses while decay rates and every ratio knob stay calibrated.
-- slow = 1.5x the listening; fast = half. Injected from the server side like
-- the profile; tests call setSpeed directly.
local SPEED_FACTORS = { slow = 1.5, default = 1.0, fast = 0.5 }
local activeSpeedName = "default"

-- Scale a beat/day constant to a whole number, never below 1.
local function scaleCount(base, factor)
    local n = math.floor(base * factor + 0.5)
    if n < 1 then n = 1 end
    return n
end

-- Reassigns the tuning locals (upvalues) from the active profile x speed
-- factor and recomputes the derived EXPOSURE_K. Always computed from the
-- PROFILES base values, never the current locals, so it's idempotent and
-- profile/speed selections can land in either order.
local function applyTuning()
    local p = PROFILES[activeProfileName]
    local f = SPEED_FACTORS[activeSpeedName] or 1.0
    EXPOSURE_ACQUIRE_COUNT      = scaleCount(p.exposureAcquireCount, f)
    FAMILIAR_COUNT              = scaleCount(p.familiarCount, f)
    PRODUCTION_SIGMOID_MIDPOINT = scaleCount(p.productionSigmoidMidpoint, f)
    SECONDS_PER_DAY             = p.secondsPerDay
    SATURATION_WINDOW_SECONDS   = p.saturationWindowSeconds
    GRACE_DAYS_RECEPTIVE        = scaleCount(p.graceDaysReceptive, f)
    GRACE_DAYS_PRODUCTIVE       = scaleCount(p.graceDaysProductive, f)
    DECAY_PER_DAY_RECEPTIVE     = p.decayPerDayReceptive
    DECAY_PER_DAY_PRODUCTIVE    = p.decayPerDayProductive
    EXPOSURE_K = -math.log(1 - ACQUISITION_THRESHOLD / COMPREHENSION_CAP)
        / EXPOSURE_ACQUIRE_COUNT
end

-- Swap the active profile. Idempotent; safe to call at any boot stage
-- (profiles touch formula inputs only, never data shape).
function MC_Acquisition.setProfile(name)
    if not PROFILES[name] then
        dbg("setProfile: unknown profile '%s' (keeping '%s')",
            tostring(name), activeProfileName)
        return false
    end
    activeProfileName = name
    applyTuning()
    if name ~= "live" then
        dbg("setProfile: ===== ACQUISITION PROFILE '%s' ACTIVE =====", name)
    else
        dbg("setProfile: live profile active")
    end
    return true
end
function MC_Acquisition.activeProfile() return activeProfileName end
function MC_Acquisition.secondsPerDay() return SECONDS_PER_DAY end

-- Swap the active learning speed. Never revokes an earned word: `acquired`
-- only ever clears through decay-to-zero (applyDecayToRecord), so slowing
-- a server down leaves everything already crossed exactly as it was.
function MC_Acquisition.setSpeed(name)
    if not SPEED_FACTORS[name] then
        dbg("setSpeed: unknown speed '%s' (keeping '%s')",
            tostring(name), activeSpeedName)
        return false
    end
    activeSpeedName = name
    applyTuning()
    if name ~= "default" then
        dbg("setSpeed: learning speed '%s' -- acquire=%d familiar=%d graceR=%d graceP=%d",
            name, EXPOSURE_ACQUIRE_COUNT, FAMILIAR_COUNT,
            GRACE_DAYS_RECEPTIVE, GRACE_DAYS_PRODUCTIVE)
    else
        dbg("setSpeed: default learning speed")
    end
    return true
end

-- EXPOSURE TRACE SINK (v8.16.1) -- observability for rate-of-learning
-- testing: when registered, every exposure batch reports what landed per
-- token (applied weight, running count, whether this beat crossed). Injected
-- from the server side (engine independence); delivery/gating/formatting
-- live there. A failing sink can never break exposure recording (pcall at
-- call site).
local exposureTraceSink = nil
function MC_Acquisition.setExposureTraceSink(fn)
    exposureTraceSink = (type(fn) == "function") and fn or nil
end

function MC_Acquisition.graceDaysReceptive()  return GRACE_DAYS_RECEPTIVE  end
function MC_Acquisition.decayPerDayReceptive()  return DECAY_PER_DAY_RECEPTIVE  end
function MC_Acquisition.decayChargeCapDays()    return DECAY_CHARGE_CAP_DAYS    end

-- v8.9: produced (successful productions) plus fractional credit from failed
-- attempts since last success. Used by the record-aware productive probability.
function MC_Acquisition.effectiveProduced(record)
    if not record then return 0 end
    local produced = record.produced or 0
    local attempts = record.producedAttempts or 0
    return produced + ATTEMPT_CREDIT * attempts
end

-- Record-aware productive probability. Wraps productiveProb with the
-- effective-produced calculation that includes attempt credit. Production-
-- pass call sites should use this; pure-function productiveProb stays for
-- tests and any caller that wants direct input control. Optional `extraBoost`
-- multiplies record.contextBoost transiently for this call (v8.9 Connection:
-- the production roll applies family + lexical-set bonuses without storing
-- them on the record).
function MC_Acquisition.productiveProbForRecord(record, zipfRank, extraBoost)
    if not record then
        return MC_Acquisition.productiveProb(0, extraBoost, zipfRank)
    end
    local effective = MC_Acquisition.effectiveProduced(record)
    local boost = (record.contextBoost or 1.0) * (extraBoost or 1.0)
    return MC_Acquisition.productiveProb(effective, boost, zipfRank)
end

-- LAPSE NOTICE (v8.16.2) -- when decay takes an acquired word (count hits 0,
-- `acquired` flips off), the player deserves one quiet in-world line --
-- silence here reads as data loss. Delivery is injected from the server side
-- (same pattern as setExposureTraceSink): MC_Lang registers a sink and sends
-- the usual quiet SystemMessage ("Your Turkish feels rusty."). Rate-limited
-- to one notice per player per language per cooldown window, so a batch of
-- lapses stays a single line. Clocked through currentTime() (setTestTime
-- drives it deterministically in tests). A failing sink can never break
-- decay (pcall); no sink -> silent no-op.
local lapseNoticeSink = nil
local lastLapseNoticeAt = {}  -- [username][langLower] = unix seconds
local LAPSE_NOTICE_COOLDOWN_SECONDS = 3600

function MC_Acquisition.setLapseNoticeSink(fn)
    lapseNoticeSink = (type(fn) == "function") and fn or nil
end

local function noteLapse(username, sourceLang)
    if not lapseNoticeSink or not username or not sourceLang then return end
    local lang = sourceLang:lower()
    local now = currentTime()
    local perUser = lastLapseNoticeAt[username]
    if perUser and perUser[lang]
       and (now - perUser[lang]) < LAPSE_NOTICE_COOLDOWN_SECONDS then
        return
    end
    if not perUser then
        perUser = {}
        lastLapseNoticeAt[username] = perUser
    end
    perUser[lang] = now
    dbg("noteLapse: acquired word(s) lapsed for %s in %s", username, lang)
    pcall(lapseNoticeSink, username, lang)
end

-- Mutates `record` in place, applying pending receptive and productive decay
-- based on elapsed time since each last event. Idempotent within a fixed
-- `now`. Returns (changed, lapsed): changed for markDirty; lapsed when this
-- call took an acquired word to count 0 (context-bearing call sites route
-- that to noteLapse). Backward-compat: records without lastProduced or
-- producedAttempts get safe defaults.
local function applyDecayToRecord(record, now)
    if not record or not now then return false, false end
    local changed = false
    local lapsed = false

    -- Pre-v8.9 records lack lastProduced; if produced > 0, seed it from
    -- lastHeard (conservative credit for "last used roughly when last heard").
    if (record.produced or 0) > 0 and not record.lastProduced then
        record.lastProduced = record.lastHeard or now
        changed = true
    end
    if not record.producedAttempts then
        record.producedAttempts = 0
        -- Don't flag as changed; this is a silent field init, not real data.
    end

    -- ---- Receptive decay ----
    local lastHeard = record.lastHeard
    if lastHeard and lastHeard <= now then
        local secondsSinceHeard = now - lastHeard
        local graceSeconds = GRACE_DAYS_RECEPTIVE * SECONDS_PER_DAY
        if secondsSinceHeard > graceSeconds then
            local daysPastGrace = (secondsSinceHeard - graceSeconds) / SECONDS_PER_DAY
            -- Absence discount: one gap bills at most the cap; consume below forgives the remainder.
            if daysPastGrace > DECAY_CHARGE_CAP_DAYS then
                daysPastGrace = DECAY_CHARGE_CAP_DAYS
            end
            -- stability 0 reproduces the base rate exactly, so existing records/saves decay unchanged.
            local rate = DECAY_PER_DAY_RECEPTIVE / (1 + (record.stability or 0))
            local toDecay = math.floor(daysPastGrace * rate)
            if toDecay > 0 then
                record.count = math.max(0, (record.count or 0) - toDecay)
                record.lastHeard = now - graceSeconds  -- consume the decay
                changed = true
                -- Zero count = unacquired, checked directly rather than via the formula
                -- threshold: a teaching-acquired word (count=1) must decay straight to
                -- unacquired, not linger in a partial-state the formula could still pass.
                if record.acquired and record.count == 0 then
                    record.acquired = false
                    lapsed = true
                end
            end
        end
    end

    -- ---- Productive decay ----
    local lastProduced = record.lastProduced
    if lastProduced and lastProduced <= now and (record.produced or 0) > 0 then
        local secondsSinceProduced = now - lastProduced
        local graceSeconds = GRACE_DAYS_PRODUCTIVE * SECONDS_PER_DAY
        if secondsSinceProduced > graceSeconds then
            local daysPastGrace = (secondsSinceProduced - graceSeconds) / SECONDS_PER_DAY
            -- Absence discount: same cap as the receptive side.
            if daysPastGrace > DECAY_CHARGE_CAP_DAYS then
                daysPastGrace = DECAY_CHARGE_CAP_DAYS
            end
            local toDecay = math.floor(daysPastGrace * DECAY_PER_DAY_PRODUCTIVE)
            if toDecay > 0 then
                local oldProduced = record.produced
                record.produced = math.max(0, oldProduced - toDecay)
                record.lastProduced = now - graceSeconds
                changed = true
                -- Failed-attempt credit decays at the same rate as produced: losing N
                -- produced loses proportional attempts, since disuse erases both.
                if record.producedAttempts > 0 then
                    record.producedAttempts = math.max(0,
                        record.producedAttempts - toDecay)
                end
                -- Full reset once produced is fully gone, rather than leaving attempts lingering.
                if record.produced == 0 then
                    record.producedAttempts = 0
                end
            end
        end
    end

    return changed, lapsed
end

-- Expose for testing and external diagnostics (e.g., offline harness introspection).
MC_Acquisition.applyDecayToRecord = applyDecayToRecord


-- TOKEN STATE -- v8.5 render classifier. Given a listener's exposure record
-- (or nil) and the token's Zipf rank, returns the four-state classification
-- the render layer uses:
--   "none"     count = 0 -- never heard. alpha = 1.0.
--   "partial"  0 < count, prob < threshold -- anticipation, bleeding through
--              but not yet grasped. alpha = continuous 0.25..0.75.
--   "fresh"    prob >= threshold, count < FAMILIAR_COUNT -- the reward moment
--              and its aftermath, clicked into place. alpha = 1.0.
--   "familiar" count >= FAMILIAR_COUNT -- consolidated into baseline
--              knowledge, rendered as a quiet aside. alpha = 0.85.
-- v8.16.2: an acquired word decayed back below the crossing level keeps its
-- bracket state but degrades alpha/prob smoothly toward DECAYED_CLARITY_FLOOR
-- as count falls (see the acquired short-circuit below) -- no more
-- perfect-until-babble cliff.
--
-- MC_Lang's applyL1Reinforcement uses state to choose phonetic/partial-paint/
-- fresh-bracket/familiar-bracket, and alpha to dim the partial/familiar
-- paints. Pure classifier -- no side effects; callers record exposure
-- separately via recordExposureBatch.

function MC_Acquisition.tokenState(exp, rank, familyCloseness)
    local count = exp and exp.count or 0
    if count == 0 then
        return { state = "none", alpha = 1.0, prob = 0.0, count = 0, level = 0.0 }
    end

    -- The explicit acquired flag is authoritative (v8.7): teaching sets it at
    -- low count, and the render must reflect that cognitive state rather than
    -- the passive-exposure statistical model -- otherwise a freshly-taught
    -- word would render "partial" until count*boost caught up. v8.16.2: while
    -- acquired, comprehensionProb (stored boost only) maps onto the clarity
    -- band [DECAYED_CLARITY_FLOOR..1.0] -- fully clear at/above threshold,
    -- dimming smoothly toward the floor as a decayed word's count falls,
    -- always better than a not-yet-acquired word at the same count (no gloss
    -- at all).
    if exp and exp.acquired then
        local boost = exp.contextBoost or DEFAULT_CONTEXT_BOOST
        local p = MC_Acquisition.comprehensionProb(count, boost, rank, familyCloseness)
        local clarity = 1.0
        if p < ACQUISITION_THRESHOLD then
            clarity = DECAYED_CLARITY_FLOOR
                + (1.0 - DECAYED_CLARITY_FLOOR) * (p / ACQUISITION_THRESHOLD)
        end
        if count < FAMILIAR_COUNT then
            return { state = "fresh", alpha = clarity, prob = clarity, count = count, level = 1.0 }
        end
        return { state = "familiar", alpha = math.min(0.85, clarity), prob = clarity, count = count, level = 1.0 }
    end

    local boost = exp and exp.contextBoost or DEFAULT_CONTEXT_BOOST
    local prob = MC_Acquisition.comprehensionProb(count, boost, rank, familyCloseness)

    if prob < ACQUISITION_THRESHOLD then
        -- Linear anticipation: alpha rises 0.25 (first probe) toward 0.75 (just
        -- below threshold); the remaining gap to 1.0 is the "click into place"
        -- moment when threshold crosses and state flips to "fresh".
        local alpha = 0.25 + 0.5 * (prob / ACQUISITION_THRESHOLD)
        if alpha < 0.25 then alpha = 0.25 end
        if alpha > 0.75 then alpha = 0.75 end
        -- babble-resolve level rides comprehension toward the threshold, where
        -- the form reaches clean and the gloss takes over.
        local denom = RESOLVE_CLEAN_PROB - RESOLVE_FLOOR_PROB
        local level
        if denom <= 0 then
            level = (prob >= RESOLVE_CLEAN_PROB) and 1 or 0
        else
            level = (prob - RESOLVE_FLOOR_PROB) / denom
        end
        if level < 0 then level = 0 elseif level > 1 then level = 1 end
        return { state = "partial", alpha = alpha, prob = prob, count = count, level = level }
    end

    if count < FAMILIAR_COUNT then
        return { state = "fresh", alpha = 1.0, prob = prob, count = count, level = 1.0 }
    end

    return { state = "familiar", alpha = 0.85, prob = prob, count = count, level = 1.0 }
end

-- IN-MEMORY DB + PERSISTENCE -- the DB lives in memory as a Lua table
-- mirroring the JSON shape. Disk I/O goes through MC_Persist (A/B generation
-- slots, read-back verified -- see MC_Persist.lua for the crash-safety
-- rationale). A dirty-flag + EveryOneMinute flush batches ordinary counter
-- writes; objective-bearing crossings and direct teaching grants additionally
-- force a verified commit before their reward becomes visible.

local SAVE_FILE = "MC_Acquisitions.json"  -- legacy pre-A/B single file (read-only)
local SCHEMA_VERSION = 1

-- A/B crash-safe store
-- (slots: MongooseChat/MC_Acquisitions_a.txt / MC_Acquisitions_b.txt).
-- The legacy single file is the migration fallback and is never written again.
local store = MC_Persist.open({
    name       = "MC_Acquisitions",
    legacyFile = SAVE_FILE,
    validate   = function(d)
        -- This validator runs before MC_Persist compares generations. Keep it
        -- exact: a newer envelope carrying a future/partial acquisition shape
        -- must be rejected so an older, valid slot can win.
        return type(d) == "table"
            and d.version == SCHEMA_VERSION
            and type(d.users) == "table"
    end,
})

local MC_AcquisitionDB = {
    version = SCHEMA_VERSION,
    users = {},
}

local dirty = false
local lastFlushAt = 0
local storageHealthy = true
local incidentSink = nil

local function reportIncident(code, detail)
    if incidentSink then pcall(incidentSink, code, detail) end
end

function MC_Acquisition.setIncidentSink(fn)
    incidentSink = (type(fn) == "function") and fn or nil
    if store.setIncidentSink then
        store:setIncidentSink(incidentSink and function(code, detail)
            reportIncident(code, "store=acquisition " .. tostring(detail or ""))
        end or nil)
    end
end

local function loadFromDisk()
    local decoded, source = store:load()
    if source == "unavailable" then
        -- A repeated boot/load in the same Lua state must not leave an older
        -- in-memory vocabulary visible after the durable source becomes
        -- unreadable. Opaque is safer than stale, unprovable clarity.
        MC_AcquisitionDB.users = {}
        lastLapseNoticeAt = {}
        dirty = false
        storageHealthy = false
        reportIncident("ACQUISITION_PERSIST_UNAVAILABLE",
            "no recoverable acquisition store; existing comprehension starts opaque")
        return false
    end
    if not decoded then
        dbg("loadFromDisk: no save data; starting empty")
        MC_AcquisitionDB.users = {}
        lastLapseNoticeAt = {}
        dirty = false
        storageHealthy = true
        return true
    end

    -- Schema version migration hook: future versions branch here. An
    -- unrecognised version refuses to load rather than risk silent corruption.
    if decoded.version ~= SCHEMA_VERSION then
        MC_AcquisitionDB.users = {}
        lastLapseNoticeAt = {}
        dirty = false
        storageHealthy = false
        reportIncident("ACQUISITION_SCHEMA_UNSUPPORTED",
            "found=" .. tostring(decoded.version) .. " expected=" .. tostring(SCHEMA_VERSION)
                .. " data preserved; writes blocked")
        return false
    end

    MC_AcquisitionDB.users = decoded.users or {}
    lastLapseNoticeAt = {}
    dirty = false
    storageHealthy = true

    local users, langs, tokens = 0, 0, 0
    for _, userTable in pairs(MC_AcquisitionDB.users) do
        users = users + 1
        for _, langTable in pairs(userTable) do
            langs = langs + 1
            for _ in pairs(langTable.tokensHeard or {}) do tokens = tokens + 1 end
        end
    end
    dbg("loadFromDisk: loaded %d users, %d user-language pairs, %d tokens (source: %s)",
        users, langs, tokens, tostring(source))
    return true
end

local function flushToDisk()
    -- store:save() is pcall-wrapped, read-back verified, and warns loudly on
    -- failure; dirty only clears on a VERIFIED write, so a failed flush
    -- retries on the next EveryOneMinute tick.
    if not storageHealthy then
        reportIncident("ACQUISITION_PERSIST_UNAVAILABLE",
            "flush refused while store health is unavailable")
        return false
    end
    if not store:save(MC_AcquisitionDB) then
        reportIncident("ACQUISITION_PERSIST_SAVE_FAILED",
            "write/read-back verification failed; dirty state retained")
        return false
    end
    dirty = false
    lastFlushAt = currentTime()
    return true
end

function MC_Acquisition.flushNow()
    if dirty then return flushToDisk() end
    return true
end

-- Readiness probe for composition roots that must distinguish an
-- authoritatively empty acquisition store from an unreadable one. Callers
-- performing identity resets use this to refuse success rather than treating
-- corruption as "no words learned".
function MC_Acquisition.isStorageAvailable()
    return storageHealthy == true
end

local function markDirty() dirty = true end

local function mutationAllowed(operation)
    if storageHealthy then return true end
    reportIncident("ACQUISITION_MUTATION_BLOCKED",
        "operation=" .. tostring(operation) .. " storage=unavailable")
    return false
end

-- Small transaction snapshot used only at objective-bearing commit points
-- (threshold crossings and direct teaching grants). Copying one user's one
-- language table is bounded by the per-language token cap and lets a failed
-- verified write restore every exposure/voice/LRU side effect from the call.
local function cloneTable(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[cloneTable(k)] = cloneTable(v) end
    return out
end

local function snapshotLanguage(username, sourceLang)
    local key = sourceLang:lower()
    local userTable = MC_AcquisitionDB.users[username]
    return {
        key = key,
        hadUser = userTable ~= nil,
        hadLanguage = userTable ~= nil and userTable[key] ~= nil,
        language = userTable and userTable[key] and cloneTable(userTable[key]) or nil,
        lapseMemo = cloneTable(lastLapseNoticeAt[username]),
        dirty = dirty,
    }
end

local function restoreLanguage(username, snapshot)
    if snapshot.hadUser then
        local userTable = MC_AcquisitionDB.users[username]
        if not userTable then
            userTable = {}
            MC_AcquisitionDB.users[username] = userTable
        end
        userTable[snapshot.key] = snapshot.hadLanguage and snapshot.language or nil
    else
        MC_AcquisitionDB.users[username] = nil
    end
    lastLapseNoticeAt[username] = snapshot.lapseMemo
    dirty = snapshot.dirty
end

-- ENTRY ACCESS / MUTATION -- all access to MC_AcquisitionDB goes through
-- these helpers. They create the nested structure on demand (callers don't
-- defensive-init) and coerce inputs to lowercase where appropriate.

local function getOrCreateLangTable(username, sourceLang)
    if not username or not sourceLang then return nil end
    local lang = sourceLang:lower()
    local userTable = MC_AcquisitionDB.users[username]
    if not userTable then
        userTable = {}
        MC_AcquisitionDB.users[username] = userTable
    end
    local langTable = userTable[lang]
    if not langTable then
        langTable = {
            firstExposure    = currentTime(),
            totalTokensHeard = 0,
            tokensHeard      = {},
        }
        userTable[lang] = langTable
    end
    return langTable
end

function getLangTable(username, sourceLang)
    if not username or not sourceLang then return nil end
    local userTable = MC_AcquisitionDB.users[username]
    if not userTable then return nil end
    return userTable[sourceLang:lower()]
end

-- When the table exceeds the cap, drop non-acquired tokens with the oldest
-- lastHeard first. Acquired tokens are NEVER evicted (the player has earned
-- them). Procedural-babble tokens shouldn't enter the table at all, so this
-- should rarely fire on a normally-running server; if it does, the
-- dictionary is too large for the cap and the operator should raise it.
local function evictLRU(langTable, sourceLang)
    local heard = langTable.tokensHeard
    local count = 0
    for _ in pairs(heard) do count = count + 1 end
    local cap = effectiveTokenCap(sourceLang)
    if count <= cap then return end

    local candidates = {}
    for token, record in pairs(heard) do
        if not record.acquired then
            candidates[#candidates + 1] = { token = token, lastHeard = record.lastHeard or 0 }
        end
    end
    table.sort(candidates, function(a, b) return a.lastHeard < b.lastHeard end)

    local toRemove = count - cap
    for i = 1, toRemove do
        if not candidates[i] then break end
        heard[candidates[i].token] = nil
    end
    
    dbg("evictLRU: removed %d non-acquired tokens (cap=%d)",
        toRemove, cap)
end

-- CONNECTION (v8.9 -- second cut) -- cross-language and cross-token
-- reinforcement, modeling two felt-experience claims:
--   1. Romance-language speakers pick up another Romance language faster
--      than a Slavic one -- family closeness matters. Pre-v8.9 each palette
--      was an island; Connection adds an intra-family context boost scaling
--      with how much the learner already knows in same-family languages.
--   2. Words cluster into semantic neighborhoods -- hearing "eau" primes
--      "nourriture", "danger". Palettes declared `lexicalSets` from the
--      start, reserved-but-unconsumed; v8.9 wires them up. Acquiring set
--      members boosts acquisition of the others, saturating with coverage
--      (once you know most of a neighborhood, the next member gets only
--      modest additional help).
--
-- TRANSIENT, NOT STORED: both boosts compute dynamically at the moment of
-- acquisition/production evaluation and are never stored on the record --
-- family/set knowledge helps THIS exposure without permanently inflating it;
-- stored `contextBoost` keeps meaning "one-shot boosts from teaching events"
-- only. The dynamic boost multiplies the effective contextBoost just for the
-- formula check or production roll, then is forgotten -- computing it looks
-- up the palette and iterates same-family/set acquisitions, both cheap
-- relative to the LRU sweep already in place.
--
-- FAMILY BONUS (sigmoid on same-family acquired count):
--   familyBonus(n) = 1.0 + (CAP-1.0) / (1 + exp(-STEEPNESS*(n-midpoint)))
--   n=0: ~1.0 (no help) | n=midpoint: half-cap (~1.15x) | n=2*midpoint+: ~1.30x
--
-- LEXICAL SET BONUS (additive per acquired neighbor, capped):
--   lexicalSetBonus(neighbors) = 1.0 + min(neighbors * PER, MAX_BONUS)
--   0: 1.0x | 1: 1.10x | 2: 1.20x | 3: 1.30x | 4+: 1.40x
-- A token may appear in multiple sets; the bonus is the MAX across sets, not
-- the sum (the strongest single neighborhood wins).

-- Family bonus shape: 30% max boost, sigmoid mid at 30 acquired family words.
local FAMILY_BOOST_CAP       = 1.30
local FAMILY_BOOST_MIDPOINT  = 30
local FAMILY_BOOST_STEEPNESS = 0.10

-- Lexical set bonus shape: 10% per acquired neighbor, capped at 40% total.
local LEXICAL_SET_PER_NEIGHBOR = 0.10
local LEXICAL_SET_BOOST_MAX    = 0.40

-- Combined cap on dynamic boost: family*set could in principle reach
-- 1.30*1.40 = 1.82, clamped here so Connection's combined boost stays modest.
-- Cultural/teaching boosts on `record.contextBoost` still multiply on top,
-- capped by MAX_CONTEXT_BOOST at storage time.
local DYNAMIC_BOOST_CAP = 1.50

-- v8.16.1 "Voices" speaker-diversity bonus: contextual diversity predicts word
-- learning better than raw frequency (Adelman, Brown & Quesada 2006); the
-- multiplayer-native proxy for context is *speaker*. Sigmoid in the
-- distinct-voice count, midpoint tuned so the third voice matters more than
-- the tenth; one voice = baseline 1.0. Sits OUTSIDE the DYNAMIC_BOOST_CAP
-- clamp -- a different epistemic source (social diversity, stored on the
-- record) than linguistic relatedness (computed from cross-language profile).
-- Tracking caps at VOICES_TRACK_CAP distinct usernames and SATURATES there --
-- beyond the cap names can't be deduplicated and the sigmoid is flat anyway,
-- so the stored count stays honest rather than inflating with repeat
-- speakers. /lex renders the cap as "5+ voices".
local VOICES_BOOST_CAP       = 1.25
local VOICES_BOOST_MIDPOINT  = 2.5
local VOICES_BOOST_STEEPNESS = 1.2
local VOICES_TRACK_CAP       = 5

-- v8.16.1 "Voices" knobs.
function MC_Acquisition.voicesTrackCap()        return VOICES_TRACK_CAP        end

-- Pure: acquired-words-across-same-family count -> multiplier.
local function familyBonusFromCount(n)
    n = n or 0
    if n <= 0 then return 1.0 end
    local range = FAMILY_BOOST_CAP - 1.0
    local sigmoid = 1.0 / (1.0 + math.exp(
        -FAMILY_BOOST_STEEPNESS * (n - FAMILY_BOOST_MIDPOINT)))
    return 1.0 + range * sigmoid
end

-- Pure: acquired-neighbors-in-strongest-set count -> multiplier.
local function lexicalSetBonusFromCount(neighbors)
    neighbors = neighbors or 0
    if neighbors <= 0 then return 1.0 end
    local bonus = math.min(neighbors * LEXICAL_SET_PER_NEIGHBOR,
                            LEXICAL_SET_BOOST_MAX)
    return 1.0 + bonus
end

-- Pure: distinct-voice count -> diversity multiplier. One voice (or
-- legacy/unknown) is baseline 1.0; sigmoid is steep around the midpoint so
-- the third voice matters more than the tenth, saturating near the cap by
-- VOICES_TRACK_CAP.
local function voicesBonusFromCount(n)
    n = n or 0
    if n <= 1 then return 1.0 end
    local range = VOICES_BOOST_CAP - 1.0
    local sigmoid = 1.0 / (1.0 + math.exp(
        -VOICES_BOOST_STEEPNESS * (n - VOICES_BOOST_MIDPOINT)))
    return 1.0 + range * sigmoid
end

-- Pure: prior beats in the current window -> increment factor for the next
-- beat (0 -> 1.0 first-beat-full, then 1/(1+K*n)).
local function saturationFactor(windowCount)
    windowCount = windowCount or 0
    if windowCount <= 0 then return 1.0 end
    return 1.0 / (1.0 + SATURATION_K * windowCount)
end

-- Counts the user's acquired words across same-family languages, excluding
-- the language being exposed to itself. Used by familyBonus.
local function countAcquiredInSameFamily(username, sourceLang)
    if not username or not sourceLang then return 0 end
    if not MC_LangRegistry or not MC_LangRegistry.getPalette then return 0 end

    local exposingPalette = MC_LangRegistry.getPalette(sourceLang)
    if not exposingPalette or not exposingPalette.family then
        return 0  -- palette has no family declared -> no bonus
    end
    local family = exposingPalette.family

    local userTable = MC_AcquisitionDB.users[username]
    if not userTable then return 0 end

    local sourceLangLower = sourceLang:lower()
    local total = 0
    for langName, langTable in pairs(userTable) do
        -- Bonus is "OTHER languages in this family help" -- skip the exposed-to language.
        if langName ~= sourceLangLower then
            local p = MC_LangRegistry.getPalette(langName)
            if p and p.family == family then
                local heard = langTable.tokensHeard
                if heard then
                    for _, rec in pairs(heard) do
                        if rec.acquired then total = total + 1 end
                    end
                end
            end
        end
    end
    return total
end

-- Counts the user's acquired neighbors of `token` within the universal
-- lexical sets declared in MC_Concepts; returns the MAX count across all sets
-- the queried concept belongs to (the strongest neighborhood wins, not the sum).
--
-- A "neighbor" is any acquired L2 token in ANY of the user's languages whose
-- palette-lex resolves to a concept in the same set as the queried concept --
-- the concept-tree architecture counts across all languages (pre-pivot only
-- counted same-language same-set acquisitions), so French "eau" boosts
-- Slavic "voda" (both = WATER, in the survival set). Sets are universal
-- semantic neighborhoods, not per-palette L2 lists (design doc CONCEPT_TREE.md
-- lost -- see MC_Concepts.lua's header and docs/ARCHITECTURE.md).
--
-- The queried concept is excluded from its own neighbor count. Two
-- acquisitions resolving to the same neighbor concept (Spanish "agua" and
-- French "eau", both WATER) count as 2 -- parity with the family-bonus
-- convention of counting each acquired token, not each unique concept.
local function countAcquiredNeighborsInSets(username, sourceLang, token)
    if not username or not sourceLang or not token then return 0 end
    if not MC_LangRegistry or not MC_LangRegistry.getPalette then return 0 end

    local Concepts = require("MC_Concepts")
    local Resolve = require("MC_Resolve")

    local sourcePalette = MC_LangRegistry.getPalette(sourceLang)
    if not sourcePalette then return 0 end

    -- Resolve the token to its concept; no neighbors if the palette doesn't lexicalize it.
    local queryConceptId = Resolve.l2ToConcept(token, sourcePalette)
    if not queryConceptId then return 0 end

    -- No set-neighbor bonus applies if the concept belongs to no set.
    local querySets = Concepts.setsForConcept(queryConceptId)
    if #querySets == 0 then return 0 end

    -- Per membership set, count acquisitions across ALL languages resolving to a
    -- member (excluding the query concept itself); track the MAX across sets.
    local userTable = MC_AcquisitionDB.users[username]
    if not userTable then return 0 end

    local maxNeighbors = 0
    for _, setName in ipairs(querySets) do
        local members = Concepts.lexicalSets[setName] or {}
        -- O(1) membership lookup
        local memberSet = {}
        for _, cid in ipairs(members) do
            if cid ~= queryConceptId then memberSet[cid] = true end
        end

        local neighbors = 0
        for langName, langTable in pairs(userTable) do
            local p = MC_LangRegistry.getPalette(langName)
            if p then
                local reverse = Resolve.reverseLex(p)
                local heard = langTable.tokensHeard or {}
                for l2Lower, rec in pairs(heard) do
                    if rec.acquired then
                        local cid = reverse[l2Lower]
                        if cid and memberSet[cid] then
                            neighbors = neighbors + 1
                        end
                    end
                end
            end
        end

        if neighbors > maxNeighbors then maxNeighbors = neighbors end
    end

    return maxNeighbors
end

-- Public queries: multiplier computed live from acquisition state + palette declarations.
function MC_Acquisition.familyBonus(username, sourceLang)
    local n = countAcquiredInSameFamily(username, sourceLang)
    return familyBonusFromCount(n)
end

function MC_Acquisition.lexicalSetBonus(username, sourceLang, token)
    local n = countAcquiredNeighborsInSets(username, sourceLang, token)
    return lexicalSetBonusFromCount(n)
end

-- Multiplies family and set bonuses, clamps to DYNAMIC_BOOST_CAP. Used
-- transiently by the acquisition formula and production roll paths; NOT
-- stored on the record.
function MC_Acquisition.dynamicContextBoost(username, sourceLang, token)
    local fam = MC_Acquisition.familyBonus(username, sourceLang)
    local set = MC_Acquisition.lexicalSetBonus(username, sourceLang, token)
    local combined = fam * set
    if combined > DYNAMIC_BOOST_CAP then combined = DYNAMIC_BOOST_CAP end
    return combined
end

-- Product of the REGISTER_WEIGHT values of the lexicalSet(s) a token's concept
-- belongs to -- a static, set-intrinsic multiplier (unlike the learner-state
-- family/set bonuses above), applied at the acquisition crossing-check.
-- Early-outs to 1.0 when every weight is neutral (no concept resolution, a
-- true no-op). weightTable override keeps it testable without mutating the
-- module knob.
local function registerWeightForToken(sourceLang, token, weightTable)
    local tbl = weightTable or REGISTER_WEIGHT
    local active = false
    for _, w in pairs(tbl) do if w ~= 1.0 then active = true; break end end
    if not active then return 1.0 end
    if type(token) ~= "string" or token == "" then return 1.0 end
    if not MC_LangRegistry or not MC_LangRegistry.getPalette then return 1.0 end
    local Concepts = require("MC_Concepts")
    local Resolve  = require("MC_Resolve")
    local palette = MC_LangRegistry.getPalette(sourceLang)
    if not palette then return 1.0 end
    local conceptId = Resolve.l2ToConcept(token, palette)
    if not conceptId then return 1.0 end
    local weight = 1.0
    for _, setName in ipairs(Concepts.setsForConcept(conceptId)) do
        weight = weight * (tbl[setName] or 1.0)
    end
    return weight
end

-- RECORDING

-- Count-weight for an utterance: addressed (true/nil) counts fully; overheard
-- (false) counts for OVERHEARD_EXPOSURE_WEIGHT. Override param keeps it
-- testable without mutating the module knob.
local function addressednessWeight(addressed, overheardWeight)
    if addressed == false then return overheardWeight or OVERHEARD_EXPOSURE_WEIGHT end
    return 1.0
end

-- v8.16.1 "Voices": distinct-voice count, nil-tolerant -- legacy records (no
-- voices array) read as 1 (the record exists, so at least one voice was
-- heard) rather than inflating what wasn't tracked.
local function voicesCountOf(record)
    local v = record and record.voices
    if type(v) ~= "table" or #v == 0 then return 1 end
    return #v
end

-- Notes a speaker against a record's voice list: append-only, distinct,
-- saturates at VOICES_TRACK_CAP (see that constant's comment for why).
-- Nil speaker (dev paths, system sources) is a no-op. Returns true if a NEW
-- voice was added.
local function noteVoice(record, speakerUsername)
    if not record or type(speakerUsername) ~= "string" or speakerUsername == "" then
        return false
    end
    local v = record.voices
    if type(v) ~= "table" then
        v = {}
        record.voices = v
    end
    if #v >= VOICES_TRACK_CAP then return false end
    for i = 1, #v do
        if v[i] == speakerUsername then return false end
    end
    v[#v + 1] = speakerUsername
    return true
end

--- Records exposure for a batch of tokens heard in a single utterance.
--
-- @param username   listener's Steam username
-- @param sourceLang  speaker's language (case-insensitive)
-- @param tokenEntries  { token=<L2 form, lowercased>, rank=<zipf rank|nil> }
--   list. rank feeds the comprehension formula's Zipfian prior; MC_Lang
--   resolves it from the speaker's palette before calling. Only dictionary
--   tokens may be passed in -- that's the exposure-table entry contract.
-- @param contextBoostMap  optional {[token]=multiplier} one-shot boost this
--   turn (fed by the teaching detector's teachingContextBoosts).
-- @param addressed  optional: addressed TO the listener (true/nil) or
--   overheard (false, counts for OVERHEARD_EXPOSURE_WEIGHT)? Live since
--   v8.16.1 -- MC_Server passes a distance heuristic for proximity speech;
--   radio stays at parity (nil, the medium carries no address signal).
-- @param speakerUsername  optional, v8.16.1 "Voices": who the listener heard,
--   feeding per-token provenance (firstVoice, voices list) and the diversity
--   bonus. Nil (dev paths) skips provenance, never blocks the exposure.
-- @return tokensCrossed, meta -- tokensCrossed: tokens crossing the
--   acquisition threshold THIS call. meta: nil if nothing crossed, else
--   { firstInLanguage=<bool>, bands=<{25|50|75}...>|nil, pct=<0..100> },
--   shaped for the client Moments layer (8.17 spec) so that work needs zero
--   server changes later.
--
-- Batched (not per-token) so a 20-token utterance is one mutation event, and
-- de-duplicated within the batch (hearing "eau eau!" is one exposure beat).
function MC_Acquisition.recordExposureBatch(username, sourceLang, tokenEntries, contextBoostMap, addressed, speakerUsername)
    local trace = nil  -- v8.16.1: populated only when a trace sink is registered
    if not username or not sourceLang or type(tokenEntries) ~= "table" then
        return {}
    end
    if not tokenEntries[1] then return {} end
    if not mutationAllowed("record-exposure") then return {}, nil end

    local transaction = snapshotLanguage(username, sourceLang)
    
    local langTable = getOrCreateLangTable(username, sourceLang)
    if not langTable then return {} end
    
    local now = currentTime()
    local newlyAcquired = {}
    local lapsedAny = false
    local boosts = contextBoostMap or {}
    -- Eavesdropping asymmetry: weight for an overheard vs addressed utterance
    -- (1.0 = parity until the knob and the addressedness signal are both live).
    local exposureWeight = addressednessWeight(addressed)
    -- Static family head-start for this language (constant across its tokens).
    local familyCloseness = MC_Acquisition.familyClosenessForLang(sourceLang)
    
    -- De-duplicate within this batch: if the same token appears twice in one
    -- utterance, count it once -- hearing "eau eau eau!" is one exposure
    -- event, not three. That matches real listening: emphatic repetition is
    -- one attention beat.
    local seen = {}
    
    -- Comprehensible-input pre-scan (Krashen i+1): what fraction of the
    -- distinct L2 tokens in this batch has the listener already acquired?
    -- Computed from PRIOR state (before this batch mutates anything) so
    -- the signal is "how much of this message did I understand when I
    -- heard it?" Single-token messages (ciTotal <= 1) get no bonus —
    -- a word by itself has no surrounding context to comprehend.
    local ciTotal, ciAcquired = 0, 0
    if COMPREHENSIBLE_INPUT_BONUS > 0 then
        local ciSeen = {}
        for _, entry in ipairs(tokenEntries) do
            local tk = entry.token
            if type(tk) == "string" and tk ~= "" and not ciSeen[tk] then
                ciSeen[tk] = true
                ciTotal = ciTotal + 1
                local rec = langTable.tokensHeard[tk]
                if rec and rec.acquired then ciAcquired = ciAcquired + 1 end
            end
        end
    end
    local ciWeight = 1.0
    if ciTotal > 1 and ciAcquired > 0 then
        ciWeight = 1.0 + COMPREHENSIBLE_INPUT_BONUS * (ciAcquired / ciTotal)
    end
    
    for _, entry in ipairs(tokenEntries) do
        local token = entry.token
        if type(token) == "string" and token ~= "" and not seen[token] then
            seen[token] = true
            local rank = entry.rank   -- may be nil for non-lex tokens
            
            local record = langTable.tokensHeard[token]
            if not record then
                record = {
                    count            = 0,
                    lastHeard        = now,
                    contextBoost     = DEFAULT_CONTEXT_BOOST,
                    acquired         = false,
                    produced         = 0,         -- v8.7
                    lastProduced     = nil,       -- v8.9: set on first recordProduction
                    producedAttempts = 0,         -- v8.9: failed attempts since last success
                    stability        = 0,         -- spaced-retrieval durability (slows decay)
                    -- v8.16.1 "Voices": provenance is set at creation ONLY --
                    -- a record's first voice is a fact about its birth, never
                    -- backfilled (legacy records honestly keep firstVoice nil).
                    firstVoice       = (type(speakerUsername) == "string"
                                        and speakerUsername ~= "")
                                       and speakerUsername or nil,
                    windowStart      = now,       -- saturation window anchor
                    windowCount      = 0,
                }
                langTable.tokensHeard[token] = record
            else
                -- Spacing effect: a re-hearing AFTER the word has cooled past
                -- its receptive grace is an effortful, spaced retrieval -- it
                -- builds durability. Capture the gap BEFORE decay (which
                -- rewrites lastHeard), then strengthen. Within-grace re-hearings
                -- (massed) build nothing.
                local priorLastHeard = record.lastHeard
                if priorLastHeard
                   and (now - priorLastHeard) > GRACE_DAYS_RECEPTIVE * SECONDS_PER_DAY then
                    record.stability = math.min(STABILITY_MAX, (record.stability or 0) + 1)
                end
                -- v8.9: apply any pending decay before mutating. A long-
                -- silent record bumps from its decayed state, not from
                -- its pre-decay stored count. This is how reception of
                -- a long-unheard word "rescues" it from drift.
                local _, lapsedNow = applyDecayToRecord(record, now)
                if lapsedNow then lapsedAny = true end
            end
            
            -- Apply any one-shot boost from teaching layer (e.g. TPR detection
            -- this turn). Compounds with the stored boost, capped.
            local oneShot = boosts[token]
            if oneShot and type(oneShot) == "number" and oneShot > 0 then
                record.contextBoost = math.min(MAX_CONTEXT_BOOST,
                    record.contextBoost * oneShot)
            end
            
            -- v8.16.1 "Voices": saturation window. Massed re-hearings inside
            -- the window earn diminishing increments (the acquisition-side
            -- mirror of the spacing-effect stability bump above). The window
            -- resets on its own clock, not on decay -- a fast grind and a
            -- slow drift are different phenomena.
            if not record.windowStart
               or (now - record.windowStart) > SATURATION_WINDOW_SECONDS then
                record.windowStart = now
                record.windowCount = 0
            end
            local satFactor = saturationFactor(record.windowCount)
            record.windowCount = (record.windowCount or 0) + 1
            
            -- v8.16.1 "Voices": provenance. Note the speaker against the
            -- record's distinct-voice list (no-op for nil speakers).
            noteVoice(record, speakerUsername)
            
            record.count     = record.count + exposureWeight * satFactor * ciWeight
            record.lastHeard = now
            langTable.totalTokensHeard = langTable.totalTokensHeard + 1
            
            -- v8.16.1: trace observability (no-op unless a sink is set).
            if exposureTraceSink then
                trace = trace or {}
                trace[#trace + 1] = {
                    token    = token,
                    weight   = exposureWeight * satFactor * ciWeight,
                    count    = record.count,
                    acquired = record.acquired,  -- pre-crossing state; updated below
                }
            end
            
            -- Crossing detection: was this token below threshold before, and
            -- is it above threshold now? If yes, fire the acquisition event.
            if not record.acquired then
                -- v8.9 Connection: family + lexical-set bonuses multiply
                -- record.contextBoost transiently for the formula check.
                -- Not stored -- dynamic per the learner's current cross-
                -- language and intra-set acquisition state.
                -- v8.16.1 "Voices": the diversity bonus multiplies alongside,
                -- outside the DYNAMIC_BOOST_CAP clamp (different epistemic
                -- source -- see the constant's comment).
                local dynBoost = MC_Acquisition.dynamicContextBoost(
                    username, sourceLang, token)
                local effectiveBoost = record.contextBoost * dynBoost
                    * registerWeightForToken(sourceLang, token)
                    * voicesBonusFromCount(voicesCountOf(record))
                if MC_Acquisition.isAcquiredByFormula(
                        record.count, effectiveBoost, rank, familyCloseness) then
                    record.acquired = true
                    newlyAcquired[#newlyAcquired + 1] = token
                    if trace and trace[#trace] and trace[#trace].token == token then
                        trace[#trace].acquired = true
                        trace[#trace].crossed  = true
                    end
                    -- Misacquisition: a newly-acquired word has a rank-scaled
                    -- chance to be associated with a wrong meaning from the
                    -- same semantic neighborhood. Corrects at FAMILIAR_COUNT
                    -- or via teaching.
                    record.misacquiredAs = pickMisacquisitionConcept(
                        sourceLang, token, rank, now)
                end
            elseif record.misacquiredAs and record.count >= FAMILIAR_COUNT then
                -- Correction: enough varied exposure clarifies the meaning.
                -- Fires at the same threshold that shifts the render from
                -- honey-gold to soft-purple (consolidation = clarity).
                record.misacquiredAs = nil
            end
        end
    end
    
    markDirty()
    
    -- LRU sweep: only at boundary crossings to avoid sorting on every utterance.
    local tokenCount = 0
    for _ in pairs(langTable.tokensHeard) do tokenCount = tokenCount + 1 end
    if tokenCount > effectiveTokenCap(sourceLang) then
        evictLRU(langTable, sourceLang)
    end

    -- A threshold crossing is an objective-bearing reward. Do not expose it
    -- to the renderer/Moments layer until the entire mutated language table
    -- has survived a synchronous write and byte-for-byte read-back.
    if #newlyAcquired > 0 and not flushToDisk() then
        restoreLanguage(username, transaction)
        reportIncident("ACQUISITION_CROSSING_COMMIT_FAILED",
            "user=" .. tostring(username) .. " language=" .. tostring(sourceLang)
                .. " crossing rolled back; no moment emitted")
        return {}, nil
    end

    if lapsedAny then noteLapse(username, sourceLang) end
    
    -- v8.16.1 "Voices": Moments payload, shaped to the 8.17 client spec now
    -- so the client flourish work later needs zero server changes. Only
    -- computed when something crossed -- the scans are bounded by the token
    -- cap and crossings are rare. `before` is derived from the post-batch
    -- count minus this batch's crossings (contract: only palette dictionary
    -- tokens enter the exposure table, so every crossing is palette-valid).
    local meta = nil
    if #newlyAcquired > 0 then
        local palette = MC_LangRegistry and MC_LangRegistry.getPalette
            and MC_LangRegistry.getPalette(sourceLang) or nil
        if palette then
            local acquiredNow, total = MC_Acquisition.acquiredCountForPalette(
                username, sourceLang, palette)
            if total and total > 0 then
                local before = acquiredNow - #newlyAcquired
                if before < 0 then before = 0 end
                local pctAfter  = math.floor((acquiredNow * 100) / total + 0.5)
                -- Bands anchor to the tier-1/2 CORE so milestones stay put
                -- as corpus-driven waves grow the dictionary (8.16.1+).
                -- pct above stays full-dictionary, matching /comp.
                local coreNow, coreTotal = MC_Acquisition.acquiredCountForCore(
                    username, sourceLang, palette)
                local bands, pctCore = nil, nil
                if coreTotal and coreTotal > 0 then
                    -- Only crossings that are themselves core tokens moved
                    -- the core count (tier-3 acquisitions must not skew it).
                    local coreCrossed = 0
                    local coreSet = palette._coreL2Set or {}
                    for _, tok in ipairs(newlyAcquired) do
                        if coreSet[tok] then coreCrossed = coreCrossed + 1 end
                    end
                    local coreBefore = coreNow - coreCrossed
                    if coreBefore < 0 then coreBefore = 0 end
                    pctCore = math.floor((coreNow * 100) / coreTotal + 0.5)
                    local pctCoreBefore = math.floor((coreBefore * 100) / coreTotal + 0.5)
                    for _, t in ipairs({ 25, 50, 75 }) do
                        if pctCoreBefore < t and pctCore >= t then
                            bands = bands or {}
                            bands[#bands + 1] = t
                        end
                    end
                end
                meta = {
                    firstInLanguage = (before == 0),
                    bands           = bands,
                    pct             = pctAfter,
                    pctCore         = pctCore,
                }
            end
        end
        -- Palette-less languages (dev fixtures) still get a well-formed meta.
        meta = meta or { firstInLanguage = false, bands = nil, pct = nil }
    end

    -- pcall: a broken trace sink must never break exposure recording.
    if exposureTraceSink and trace and #trace > 0 then
        pcall(exposureTraceSink, username, sourceLang, trace, addressed)
    end
    
    return newlyAcquired, meta
end

-- Persistent context-boost primitive. Multiplies a token's stored boost by
-- `factor`, capped -- applies to subsequent exposures, not retroactively. The
-- built teaching detector uses the one-shot contextBoostMap path instead.
function MC_Acquisition.applyContextBoost(username, sourceLang, token, factor)
    if not username or not sourceLang or not token or type(factor) ~= "number" then
        return
    end
    if not mutationAllowed("apply-context-boost") then return false end
    local langTable = getLangTable(username, sourceLang)
    if not langTable then return end
    local now = currentTime()
    local record = langTable.tokensHeard[token]
    if not record then
        record = {
            count            = 0,
            lastHeard        = now,
            contextBoost     = DEFAULT_CONTEXT_BOOST,
            acquired         = false,
            produced         = 0,
            lastProduced     = nil,
            producedAttempts = 0,
        }
        langTable.tokensHeard[token] = record
    else
        local _, lapsedNow = applyDecayToRecord(record, now)
        if lapsedNow then noteLapse(username, sourceLang) end
    end
    record.contextBoost = math.min(MAX_CONTEXT_BOOST, record.contextBoost * factor)
    markDirty()
end

-- TEACHING DETECTION -- graded acceleration from soft signals (knob at zero)
-- Observes one rendered message for a receiver and returns a one-shot
-- contextBoostMap for recordExposureBatch to apply. Distinct from the
-- instant-grant MC_Teaching path; two soft signals:
--   * repetition -- speaker repeats an L2 token (>=2x) in this message. Boosts
--     the SALIENCE of the (deduped) exposure, not its count -- "eau eau eau"
--     stays one attention beat, but a more memorable one.
--   * co-occurrence -- an un-acquired token shares the message with an
--     already-acquired one (known context scaffolds it).
-- One-shot by design: durability comes from repeated signals, not permanent
-- inflation. Both factors 1.0 (neutral) -> early-out -> nil -> true no-op.
-- Factors are optional params (default to module knobs) so detection stays
-- testable without mutating globals.
local function countWholeWord(text, word)
    if type(text) ~= "string" or type(word) ~= "string" or word == "" then return 0 end
    local n = 0
    for chunk in text:gmatch("%S+") do
        local w = chunk:gsub("^%p+", ""):gsub("%p+$", "")
        if w == word then n = n + 1 end
    end
    return n
end

function MC_Acquisition.teachingContextBoosts(username, sourceLang, lexSubs, sourceText,
                                              repetitionBoost, cooccurrenceBoost)
    local repBoost  = repetitionBoost   or REPETITION_BOOST
    local coocBoost = cooccurrenceBoost or COOCCURRENCE_BOOST
    -- Neutral knobs -> nothing to detect -> true no-op (no map, no work).
    if repBoost == 1.0 and coocBoost == 1.0 then return nil end
    if not username or not sourceLang or type(lexSubs) ~= "table" then return nil end

    -- Co-occurrence needs to know which of this message's tokens the receiver
    -- already holds. For an un-acquired token, acquiredCount is the count of
    -- OTHER acquired tokens (this one isn't counted, since it isn't acquired).
    local acquiredSet, acquiredCount = {}, 0
    for _, sub in pairs(lexSubs) do
        local exp = MC_Acquisition.getExposure(username, sourceLang, sub.l2)
        if exp and exp.acquired then
            acquiredSet[sub.l2] = true
            acquiredCount = acquiredCount + 1
        end
    end

    local map, any = {}, false
    for _, sub in pairs(lexSubs) do
        local factor = 1.0
        if repBoost ~= 1.0 and countWholeWord(sourceText, sub.l2) >= 2 then
            factor = factor * repBoost
        end
        if coocBoost ~= 1.0 and not acquiredSet[sub.l2] and acquiredCount >= 1 then
            factor = factor * coocBoost
        end
        if factor ~= 1.0 then
            map[sub.l2] = factor
            any = true
        end
    end
    return any and map or nil
end

-- PRODUCTION TRACKING (v8.7) -- increments `produced` when the speaker uses a
-- token in their own speech (applyProductionPass, learner-speaker path;
-- natives bypass this, treated as "produces everything"). Gates the teaching
-- layer: a non-native can only teach a word they've actually used -- natural
-- friction mirroring real bilingual vocabulary transmission (you pass on a
-- word you've spoken, not one you just heard).

function MC_Acquisition.recordProduction(username, sourceLang, token)
    if not username or not sourceLang or type(token) ~= "string" or token == "" then
        return false
    end
    if not mutationAllowed("record-production") then return false end
    local langTable = getOrCreateLangTable(username, sourceLang)
    if not langTable then return false end
    local now = currentTime()
    local record = langTable.tokensHeard[token]
    if not record then
        record = {
            count            = 0,
            lastHeard        = now,
            contextBoost     = DEFAULT_CONTEXT_BOOST,
            acquired         = false,
            produced         = 0,
            lastProduced     = nil,
            producedAttempts = 0,
        }
        langTable.tokensHeard[token] = record
    else
        local _, lapsedNow = applyDecayToRecord(record, now)
        if lapsedNow then noteLapse(username, sourceLang) end
    end
    record.produced = (record.produced or 0) + 1
    record.lastProduced = now
    -- v8.9: speaking is also hearing -- refresh the receptive clock too, or a
    -- learner who's productive but never hears the word from others would
    -- lose receptive count to drift and flip back to unacquired (cognitively
    -- wrong; you don't forget a word you keep saying).
    record.lastHeard = now
    -- A successful production consolidates any pending failed-attempt credit;
    -- the next failure starts a fresh accumulation.
    record.producedAttempts = 0
    markDirty()
    return true
end

-- Failed production attempt (applyProductionPass's failure branch): increments
-- `producedAttempts`, contributing fractional credit (ATTEMPT_CREDIT each) to
-- the productive curve via effectiveProduced. Does NOT set lastProduced --
-- failure isn't production, and shouldn't reset the productive decay clock
-- (attempts still decay along with produced, per applyDecayToRecord).
function MC_Acquisition.recordProductionAttempt(username, sourceLang, token)
    if not username or not sourceLang or type(token) ~= "string" or token == "" then
        return false
    end
    if not mutationAllowed("record-production-attempt") then return false end
    local langTable = getOrCreateLangTable(username, sourceLang)
    if not langTable then return false end
    local now = currentTime()
    local record = langTable.tokensHeard[token]
    if not record then
        record = {
            count            = 0,
            lastHeard        = now,
            contextBoost     = DEFAULT_CONTEXT_BOOST,
            acquired         = false,
            produced         = 0,
            lastProduced     = nil,
            producedAttempts = 0,
        }
        langTable.tokensHeard[token] = record
    else
        local _, lapsedNow = applyDecayToRecord(record, now)
        if lapsedNow then noteLapse(username, sourceLang) end
    end
    record.producedAttempts = (record.producedAttempts or 0) + 1
    markDirty()
    return true
end

function MC_Acquisition.hasProduced(username, sourceLang, token)
    if not username or not sourceLang or not token then return false end
    if not storageHealthy then
        reportIncident("ACQUISITION_QUERY_BLOCKED",
            "operation=has-produced storage=unavailable")
        return false
    end
    local langTable = getLangTable(username, sourceLang)
    if not langTable then return false end
    local record = langTable.tokensHeard[token]
    if not record then return false end
    local changed, lapsedNow = applyDecayToRecord(record, currentTime())
    if changed then markDirty() end
    if lapsedNow then noteLapse(username, sourceLang) end
    return record.acquired == true and (record.produced or 0) >= 1
end

-- TEACHING (v8.7) -- sets `acquired = true` directly, without exposure-count
-- arithmetic, when a teaching event fires AND the receiver-heard gate passes.
-- Models the discrete "just clicked from being explicitly taught" moment on a
-- word already encountered at least once. Idempotent: a no-op on an
-- already-acquired token. Returns true only if this call caused the transition.

function MC_Acquisition.recordTeaching(username, sourceLang, token, rank, teacherUsername)
    if not username or not sourceLang or type(token) ~= "string" or token == "" then
        return false
    end
    if not mutationAllowed("record-teaching") then return false end
    local transaction = snapshotLanguage(username, sourceLang)
    local langTable = getOrCreateLangTable(username, sourceLang)
    if not langTable then return false end
    local now = currentTime()
    local record = langTable.tokensHeard[token]
    if not record then
        record = {
            count            = 0,
            lastHeard        = now,
            contextBoost     = DEFAULT_CONTEXT_BOOST,
            acquired         = false,
            produced         = 0,
            lastProduced     = nil,
            producedAttempts = 0,
            -- v8.16.1 "Voices": a taught word's first voice is its teacher
            -- (the receiver-heard gate means a record usually already exists;
            -- this covers dev/direct paths).
            firstVoice       = (type(teacherUsername) == "string"
                                and teacherUsername ~= "")
                               and teacherUsername or nil,
            windowStart      = now,
            windowCount      = 0,
        }
        langTable.tokensHeard[token] = record
    else
        local decayChanged, lapsedNow = applyDecayToRecord(record, now)
        if decayChanged then markDirty() end
        transaction.lapsed = lapsedNow
    end
    -- v8.16.1 "Voices": teaching IS exposure from a speaker; note the voice
    -- whether or not the grant below fires (a repeat lesson from a new
    -- teacher still diversifies the word).
    if noteVoice(record, teacherUsername) then markDirty() end
    if record.acquired then
        -- Already acquired; teaching corrects any misacquisition (a teacher
        -- explicitly tells you the right meaning) but is otherwise a no-op.
        if record.misacquiredAs then
            record.misacquiredAs = nil
            markDirty()
        end
        return false
    end
    record.acquired  = true
    record.lastHeard = now
    -- Teaching grants the correct meaning — no misacquisition roll.
    record.misacquiredAs = nil
    markDirty()
    if not flushToDisk() then
        restoreLanguage(username, transaction)
        reportIncident("ACQUISITION_TEACHING_COMMIT_FAILED",
            "user=" .. tostring(username) .. " language=" .. tostring(sourceLang)
                .. " token grant rolled back; no moment emitted")
        return false
    end
    if transaction.lapsed then noteLapse(username, sourceLang) end
    return true
end

-- QUERIES (read-only; never mutate)

function MC_Acquisition.getExposure(username, sourceLang, token)
    if not storageHealthy then
        reportIncident("ACQUISITION_QUERY_BLOCKED",
            "operation=get-exposure storage=unavailable")
        return nil
    end
    local langTable = getLangTable(username, sourceLang)
    if not langTable or not token then return nil end
    local record = langTable.tokensHeard[token]
    if not record then return nil end
    local changed, lapsedNow = applyDecayToRecord(record, currentTime())
    if changed then markDirty() end
    if lapsedNow then noteLapse(username, sourceLang) end
    return record
end

-- Shallow copy of the token table for read-only consumers (like /lex); cheap
-- (token count is bounded by the cap) and prevents mutation through the
-- returned reference.
function MC_Acquisition.getAllTokens(username, sourceLang)
    local langTable = getLangTable(username, sourceLang)
    if not langTable then return {} end
    local out = {}
    for token, record in pairs(langTable.tokensHeard) do
        local voicesCopy = nil
        if type(record.voices) == "table" and #record.voices > 0 then
            voicesCopy = {}
            for i = 1, #record.voices do voicesCopy[i] = record.voices[i] end
        end
        out[token] = {
            count        = record.count,
            lastHeard    = record.lastHeard,
            contextBoost = record.contextBoost,
            acquired     = record.acquired,
            -- v8.16.1 "Voices": provenance for /lex display. The array is
            -- copied, not referenced -- same no-mutation guarantee as the rest.
            voices       = voicesCopy,
            firstVoice   = record.firstVoice,
        }
    end
    return out
end

--- Count palette-valid acquired L2 forms.
-- total -- the shared scan behind estimateComprehension and the batch-tail
-- Moments meta (v8.16.1), one definition of "comprehension fraction".
-- @param palette  the palette object (.lex sizes the denominator)
-- @return acquiredCount, total  (total 0 means empty/unknown palette)
function MC_Acquisition.acquiredCountForPalette(username, sourceLang, palette)
    if not palette or type(palette.lex) ~= "table" then return 0, 0 end

    local total = 0
    for _ in pairs(palette.lex) do total = total + 1 end
    if total == 0 then return 0, 0 end

    local langTable = getLangTable(username, sourceLang)
    if not langTable then return 0, total end

    -- Build the set of valid L2 forms for this palette so we don't count
    -- tokens whose concept was removed from the lex between sessions.
    local validL2 = {}
    for _, entry in pairs(palette.lex) do
        if type(entry) == "table" and type(entry.l2) == "string" and entry.l2 ~= "" then
            validL2[entry.l2:lower()] = true
        end
    end

    local acquired = 0
    for token, record in pairs(langTable.tokensHeard) do
        if record.acquired and validL2[token] then
            acquired = acquired + 1
        end
    end

    return acquired, total
end

-- Core-tier variant: counts only palette lexicalizations whose concept sits
-- in tier 1-2 (the locked 462-concept core). Moments comprehension bands
-- anchor here so milestones don't recede as corpus-driven waves grow the
-- dictionary (a tester at 40% shouldn't wake up at 21% having forgotten
-- nothing). Identical to the full scan while every concept is tier <= 2 --
-- zero behavior change until tier-3 entries exist. Cached on the palette
-- (same pattern as _zipfRankMap).
function MC_Acquisition.acquiredCountForCore(username, sourceLang, palette)
    if not palette or type(palette.lex) ~= "table" then return 0, 0 end

    if not palette._coreL2Set then
        local okC, Concepts = pcall(require, "MC_Concepts")
        local set, total = {}, 0
        for cid, entry in pairs(palette.lex) do
            if type(entry) == "table" and type(entry.l2) == "string" and entry.l2 ~= "" then
                local tier = nil
                if okC and Concepts and Concepts.get then
                    local c = Concepts.get(cid)
                    tier = c and c.tier or nil
                end
                -- Unknown tier counts as core (conservative: never shrink
                -- the milestone space because a lookup failed).
                if not tier or tier <= 2 then
                    set[entry.l2:lower()] = true
                    total = total + 1
                end
            end
        end
        palette._coreL2Set, palette._coreTotal = set, total
    end

    local total = palette._coreTotal or 0
    if total == 0 then return 0, 0 end
    local langTable = getLangTable(username, sourceLang)
    if not langTable then return 0, total end

    local acquired = 0
    for token, record in pairs(langTable.tokensHeard) do
        if record.acquired and palette._coreL2Set[token] then
            acquired = acquired + 1
        end
    end
    return acquired, total
end

--- Get the listener's comprehension percentage.
-- has acquired, computed on demand from the exposure table (never stored, so
-- /comp always reflects actual data, never drifts from it).
-- @return percentage 0..100, or nil if the language is unknown/empty
function MC_Acquisition.estimateComprehension(username, sourceLang, palette)
    if not palette or type(palette.lex) ~= "table" then return nil end

    local acquired, total = MC_Acquisition.acquiredCountForPalette(
        username, sourceLang, palette)
    if total == 0 then return 0 end

    return math.floor((acquired * 100) / total + 0.5)
end

-- RESET

function MC_Acquisition.forgetUserPersisted(username)
    if not storageHealthy then
        reportIncident("ACQUISITION_PERSIST_UNAVAILABLE",
            "forget-user refused while store health is unavailable")
        return false, 0
    end
    if not username then return false, 0 end
    local oldUser = MC_AcquisitionDB.users[username]
    if not oldUser then return true, 0 end

    local oldLapseMemo = lastLapseNoticeAt[username]
    local wasDirty = dirty
    local cleared = 0
    for _ in pairs(oldUser) do cleared = cleared + 1 end
    MC_AcquisitionDB.users[username] = nil
    lastLapseNoticeAt[username] = nil
    dirty = true

    if flushToDisk() then return true, cleared end

    MC_AcquisitionDB.users[username] = oldUser
    lastLapseNoticeAt[username] = oldLapseMemo
    dirty = wasDirty
    reportIncident("ACQUISITION_PERSIST_SAVE_FAILED",
        "forget-user rolled back after failed verification")
    return false, 0
end

function MC_Acquisition.forgetLanguagePersisted(username, sourceLang)
    if not storageHealthy then
        reportIncident("ACQUISITION_PERSIST_UNAVAILABLE",
            "forget-language refused while store health is unavailable")
        return false
    end
    if not username or type(sourceLang) ~= "string" then return false end
    local userTable = MC_AcquisitionDB.users[username]
    if not userTable then return false end
    local key = sourceLang:lower()
    local oldLanguage = userTable[key]
    if not oldLanguage then return false end

    local lapseMemo = lastLapseNoticeAt[username]
    local oldLapse = lapseMemo and lapseMemo[key] or nil
    local wasDirty = dirty
    userTable[key] = nil
    if lapseMemo then lapseMemo[key] = nil end
    dirty = true

    if flushToDisk() then return true end

    userTable[key] = oldLanguage
    if lapseMemo then lapseMemo[key] = oldLapse end
    dirty = wasDirty
    reportIncident("ACQUISITION_PERSIST_SAVE_FAILED",
        "forget-language rolled back after failed verification")
    return false
end

-- Read-only inventory of a user's acquisition data, for the /lang reset
-- preview. Returns a sorted list of { lang = <id>, tokens = <count> }.
function MC_Acquisition.languagesWithData(username)
    local out = {}
    if not username then return out end
    local userTable = MC_AcquisitionDB.users[username]
    if not userTable then return out end
    for lang, langTable in pairs(userTable) do
        local n = 0
        for _ in pairs(langTable.tokensHeard or {}) do n = n + 1 end
        out[#out + 1] = { lang = lang, tokens = n }
    end
    table.sort(out, function(a, b) return a.lang < b.lang end)
    return out
end

-- Read-only DEEP inventory for the total-wipe preview (/lang resetall in
-- MC_Lang). Where languagesWithData answers "how many tokens", this surfaces
-- every axis the wipe destroys: heard, acquired, produced, misacquiredAs.
-- Teaching provenance (voices/firstVoice) dies with the same records but
-- isn't counted separately -- "who taught you what" isn't a number players
-- reason about. Returns a sorted list of
--   { lang = <id>, tokens = <n>, acquired = <n>, produced = <n>, misheard = <n> }.
function MC_Acquisition.inventoryForUser(username)
    local out = {}
    if not username then return out end
    local userTable = MC_AcquisitionDB.users[username]
    if not userTable then return out end
    for lang, langTable in pairs(userTable) do
        local entry = { lang = lang, tokens = 0, acquired = 0, produced = 0, misheard = 0 }
        for _, rec in pairs(langTable.tokensHeard or {}) do
            entry.tokens = entry.tokens + 1
            if rec.acquired then entry.acquired = entry.acquired + 1 end
            if (rec.produced or 0) > 0 then entry.produced = entry.produced + 1 end
            if rec.misacquiredAs then entry.misheard = entry.misheard + 1 end
        end
        out[#out + 1] = entry
    end
    table.sort(out, function(a, b) return a.lang < b.lang end)
    return out
end

-- Has the listener acquired at least one word in this language? Gates
-- MC_Server's language-identity tag: no acquired word means no label, just
-- babble. Early-exits true on the first acquired token found.
function MC_Acquisition.hasAcquiredAny(username, sourceLang)
    if not username or not sourceLang then return false end
    local langTable = getLangTable(username, sourceLang)
    if not langTable then return false end
    for _, rec in pairs(langTable.tokensHeard or {}) do
        if rec.acquired then return true end
    end
    return false
end

-- Teaching impact: how many words across all learners has this player been
-- firstVoice for? Returns (totalWords, distinctLearners). Scans the full
-- acquisition DB — bounded by total users × languages × tokens (all
-- capped). Called on-demand from /lex, not per-message.
function MC_Acquisition.teachingImpact(username)
    if not username then return 0, 0 end
    local totalWords = 0
    local learners = {}
    for learnerName, langs in pairs(MC_AcquisitionDB.users or {}) do
        if learnerName ~= username then  -- don't count self-exposure
            local countedThisLearner = false
            for _, langTable in pairs(langs) do
                for _, rec in pairs(langTable.tokensHeard or {}) do
                    if rec.firstVoice == username then
                        totalWords = totalWords + 1
                        if not countedThisLearner then
                            learners[learnerName] = true
                            countedThisLearner = true
                        end
                    end
                end
            end
        end
    end
    local distinctLearners = 0
    for _ in pairs(learners) do distinctLearners = distinctLearners + 1 end
    return totalWords, distinctLearners
end

-- LIFECYCLE EVENTS -- exported, never self-registered (see invariant 3a).
-- Boot load/migrate and the periodic disk flush are this module's behavior,
-- but WIRING them to Events belongs to the composition root: MC_Server.lua
-- calls Events.OnServerStarted.Add / Events.EveryOneMinute.Add on these two
-- named functions; this module never touches Events itself.

-- Internal contract: MC_Server.lua registers this on Events.OnServerStarted.
-- Load and migration are each pcall-guarded so a corrupt save or a broken
-- migration can never block server startup.
function MC_Acquisition.onServerStarted()
    local ok, err = pcall(loadFromDisk)
    if not ok then
        storageHealthy = false
        reportIncident("ACQUISITION_PERSIST_UNAVAILABLE",
            "load threw: " .. tostring(err))
    end
    local okM, errM = pcall(MC_Acquisition.applyFormMigrations)
    if not okM then
        reportIncident("ACQUISITION_MIGRATION_FAILED", tostring(errM))
    end
    lastFlushAt = currentTime()
end

-- Internal contract: MC_Server.lua registers this on Events.EveryOneMinute.
-- Coarse periodic flush trades a worst-case 60-second lost-on-crash window
-- for not hammering disk -- a crash loses at most "the last minute of which
-- words who heard," recoverable by playing more.
function MC_Acquisition.onEveryOneMinute()
    if dirty then
        local ok, err = pcall(flushToDisk)
        if not ok then
            reportIncident("ACQUISITION_PERSIST_SAVE_FAILED",
                "periodic flush threw: " .. tostring(err))
        end
    end
end

-- FORM MIGRATIONS (v8.16.1) -- the multi-token form fix renamed 15 palette L2
-- forms (see CHANGELOG, data/forms.tsv). Exposure records are keyed by token,
-- so without this sweep every learner's progress on those words would
-- silently revert to babble -- and "never deny the player a word they've
-- earned" is a locked rule. Applied once per boot after load; idempotent
-- (old keys cease to exist after the first pass, and the lex no longer emits
-- them). Merge semantics when the NEW key already has a record (possible via
-- conflation, e.g. SHOOT's old form migrating onto HIT's `vurmak`): numeric
-- progress takes the max, acquired ORs, voices union (capped), firstVoice
-- prefers the migrated record's (older history).
local FORM_MIGRATIONS = {
    turkish = {
        ["ayak bile\196\159i"] = "bilek",
        ["in\197\159a etmek"]  = "kurmak",
        ["hasat etmek"]        = "hasat",
        ["meyve suyu"]         = "meyvesuyu",
        ["gece yar\196\177s\196\177"] = "geceyar\196\177s\196\177",
        ["yara izi"]           = "iz",
        ["ate\197\159 etmek"]  = "vurmak",
        ["takas etmek"]        = "takas",
        ["yabani ot"]          = "ot",
        -- v8.16.1 audit pass: MOVE was the noun 'hareket' (wave 1's own
        -- flagged compromise); k\196\177p\196\177rdamak is the real verb.
        ["hareket"]            = "k\196\177p\196\177rdamak",
    },
    french = {
        ["au revoir"]    = "adieu",
        ["grand-p\195\168re"] = "papi",
        ["grand-m\195\168re"] = "mamie",
        ["aujourd'hui"]  = "aujourdhui",
    },
    slavic = {
        ["do svidaniya"]   = "poka",
        ["bolshoy palets"] = "palets",
    },
}

local function mergeMigratedRecord(old, target)
    target.count            = math.max(target.count or 0, old.count or 0)
    target.lastHeard        = math.max(target.lastHeard or 0, old.lastHeard or 0)
    target.contextBoost     = math.max(target.contextBoost or 1.0, old.contextBoost or 1.0)
    target.acquired         = (target.acquired or old.acquired) and true or false
    target.produced         = math.max(target.produced or 0, old.produced or 0)
    target.producedAttempts = math.max(target.producedAttempts or 0, old.producedAttempts or 0)
    target.stability        = math.max(target.stability or 0, old.stability or 0)
    if old.lastProduced then
        target.lastProduced = math.max(target.lastProduced or 0, old.lastProduced)
    end
    if (old.windowStart or 0) > (target.windowStart or 0) then
        target.windowStart, target.windowCount = old.windowStart, old.windowCount
    end
    -- Migrated record's history is older, so its firstVoice wins where known;
    -- voice lists union, target order first, capped.
    target.firstVoice = old.firstVoice or target.firstVoice
    -- Migrated record's wrong meaning carries over -- spelling changed, understanding didn't.
    if old.misacquiredAs and not target.misacquiredAs then
        target.misacquiredAs = old.misacquiredAs
    end
    if type(old.voices) == "table" and #old.voices > 0 then
        if type(target.voices) ~= "table" then target.voices = {} end
        for i = 1, #old.voices do
            if #target.voices >= VOICES_TRACK_CAP then break end
            local dup = false
            for j = 1, #target.voices do
                if target.voices[j] == old.voices[i] then dup = true break end
            end
            if not dup then target.voices[#target.voices + 1] = old.voices[i] end
        end
    end
end

-- Sweep every loaded user x language table and apply the migration map.
-- Exposed (rather than local) so the boot hook and tests share one path.
function MC_Acquisition.applyFormMigrations()
    if not mutationAllowed("apply-form-migrations") then return 0 end
    local migrated = 0
    for username, langs in pairs(MC_AcquisitionDB.users or {}) do
        for lang, map in pairs(FORM_MIGRATIONS) do
            local langTable = langs[lang]
            local heard = langTable and langTable.tokensHeard
            if heard then
                for oldKey, newKey in pairs(map) do
                    local rec = heard[oldKey]
                    if rec then
                        local existing = heard[newKey]
                        if existing then
                            mergeMigratedRecord(rec, existing)
                        else
                            heard[newKey] = rec
                        end
                        heard[oldKey] = nil
                        migrated = migrated + 1
                    end
                end
            end
        end
    end
    if migrated > 0 then
        markDirty()
        dbg("applyFormMigrations: migrated %d records to v8.16.1 token keys", migrated)
    end
    return migrated
end

return MC_Acquisition
