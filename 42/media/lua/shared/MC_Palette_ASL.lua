-- MC_Babble palette: ASL (American Sign Language)
-- Signed modality -- not a spoken palette in a costume. No onset/
-- nucleus/coda/functionWord pools: there is no phonetic surface to babble.
-- The babble-equivalent pool is `gestures` (gesture-prose fragments, seeded
-- for stability the same way MC_Babble seeds its own picks); comprehension
-- is unlocked concept-by-concept via `lex`, exactly like every spoken
-- palette's dictionary-bleed layer.
--
-- GLOSS CONVENTION: `lex[CONCEPT_ID] = { l2 = lowercase(CONCEPT_ID) }`.
-- Glossing a sign as its nearest English word in capitals (WATER, GATE,
-- DANGER, ...) IS the real, standard ASL transcription convention, and
-- MC_Concepts' IDs already are that word -- the UPPERCASE display happens
-- at render time (server/MC_Lang.lua's signed reinforcement), not in the
-- stored form. Every acquisition/teaching/zipf lookup in this codebase
-- (MC_Acquisition token keys, MC_Resolve.reverseLex, MC_Teaching's
-- dictionary compare) keys off palette.lex forms VERBATIM with no internal
-- case-folding -- every spoken palette's forms happen to already be
-- lowercase, so this has never surfaced before. Storing ASL's forms
-- lowercase too keeps that implicit contract intact instead of splitting
-- "water" (spoken-style lowercase keys elsewhere) from "WATER" (a
-- differently-cased key) into two unrelated acquisition records.
-- Programmatic generation (rather than a hand-typed table) means every
-- concept MC_Concepts knows about gets a citation-form gloss with zero
-- transcription risk. IDs carrying a disambiguation suffix (CLEAN_ADJ,
-- split IDs, etc.) are skipped -- the suffix isn't a real gloss token;
-- MC_Resolve's parent walk still reaches the base concept's gloss for those.
--
-- No zipf: v1 has no sourced ASL sign-frequency corpus (the spoken palettes'
-- zipf tables come from a linguist-reviewed forms.tsv this palette has no
-- equivalent of). Optional field; comprehension falls back to the unranked
-- prior, same as any spoken token outside its palette's zipf list.

local Concepts = require("MC_Concepts")

-- m2: a small, hand-curated override for the worst mechanical glosses --
-- concept IDs whose own concept-tree ID reads as an awkward abstract-noun
-- or archaic form next to the natural word a fluent signer would actually
-- choose (data/concepts.tsv's own `en` aliases, not the ID, carry the
-- natural word). Deliberately tiny: mechanical ID-as-gloss generation
-- stays the base for the other ~500+ concepts; this only touches the
-- handful worth hand-fixing.
--   KIN        -> FAMILY   (KIN's own alias is "family,relative" --
--                            "kin" is archaic/uncommon next to "family")
--   SADNESS    -> SAD      (abstract noun vs. the plain adjective form)
--   LONELINESS -> LONELY   (same abstract-noun-vs-adjective mismatch)
local GLOSS_OVERRIDES = {
    KIN = "family",
    SADNESS = "sad",
    LONELINESS = "lonely",
}

-- Build the full gloss lex from every clean (no underscore) concept ID.
local function buildGlossLex()
    local lex = {}
    for _, id in ipairs(Concepts.allIds()) do
        if not id:find("_") then
            lex[id] = { l2 = GLOSS_OVERRIDES[id] or id:lower() }
        end
    end
    return lex
end

local asl = {
    name        = "ASL",
    -- Display override: ASL is an acronym, not a word -- the registry's
    -- default Title-Case ("Asl") would mangle it. See MC_LangRegistry's
    -- DISPLAY NAME section.
    displayName = "ASL",
    modality    = "signed",
    family      = "signed",

    -- Gesture-prose pool -- the surface a non-signer (or an unacquired
    -- concept, for a learner) actually perceives: a description of hand
    -- shape and movement, never the meaning. One fragment stands in for one
    -- source word, picked deterministically (stable per receiver, like
    -- babble). House prose voice; no numerals.
    gestures = {
        "a hand shapes something in the air",
        "fingers flick outward, quick and precise",
        "both hands trace a shape between them",
        "a fist taps twice against an open palm",
        "fingers walk forward, tracing a short path",
        "a flat hand sweeps sideways and stops",
        "the hands mirror each other, turning",
        "a fingertip circles slowly",
        "the hands rise and fall in a small arc",
        "two fingers brush past each other",
        "a closed hand opens sharply",
        "the hands frame a shape, then let it go",
        "a palm presses flat and holds",
        "fingers curl inward, then release",
        "one hand chases the other in a loop",
        "a thumb hooks and pulls back",
        "the hands cross, then part",
        "a flat hand tips and rights itself",
        "fingers spread wide, then close",
        "a hand draws a line and taps its end",
        "the hands stack, then lift apart",
        "a wrist twists, catching the light",
        "a hand pushes forward against nothing",
        "fingers tap a quick, small rhythm",
        "the hands cup something unseen",
    },

    -- Iconic leak: a capped set of concepts whose sign is partly
    -- readable from its shape alone, even to someone who's never learned a
    -- sign in their life. True to real ASL iconicity; merciful to
    -- strangers; capped at eight so ASL stays a language, not mime.
    iconic = {
        EAT    = "a flat hand tips toward the mouth -- eating?",
        DRINK  = "a curled hand tips back like a cup -- drinking?",
        COME   = "a finger beckons inward -- come here?",
        GO     = "a flat hand flicks forward and away -- go?",
        YOU    = "a finger points outward, right at you -- you?",
        I      = "a finger taps the chest -- me?",
        STOP   = "one hand chops flat against the other -- stop?",
        DANGER = "thumbs jab upward from the chest, sharp -- danger?",
    },

    -- Concept -> gloss. See file header for the generation rule.
    lex = buildGlossLex(),

    -- No zipf (see file header).
}

-- Self-register with the language system, same single touchpoint every
-- other palette uses -- MC_Lang doesn't need to know ASL exists.
require("MC_LangRegistry").register("asl", asl)

return asl
