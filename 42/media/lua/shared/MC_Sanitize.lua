-- MC_Sanitize -- shared text-region protection for IC chat.
--
-- WHY THIS EXISTS
-- MC_Lang.renderWithLangs (babble) and MC_Server.addPacketLoss (radio static)
-- both need "extract regions to protect, transform the rest, restore" -- and
-- used to each hand-roll it, sharing the same nested-region bug: pairs()
-- iteration is order-undefined, so forward-insertion restored inner-first,
-- leaving the outer placeholder's content as literal "PLACEHOLDER1" text with
-- no second pass. Fixed once here, with the protection set now declarative --
-- both call sites share the same defaults, so a new region type is one edit,
-- not three.
--
-- DEFAULT PROTECTION SET (PZ chat conventions)
--   *emote*       -> action description
--   **mood**      -> mood indicator
--   ((OOC))       -> inline out-of-character aside
-- Order: double-asterisk before single-asterisk (else the single pass
-- partial-matches **mood**'s inner *s); OOC parens last (no conflict).
--
-- KNOWN LIMITATION -- same-type nesting
-- Cross-type nesting round-trips fine (`*walks **proudly** in*`, `((aside
-- with **stress** inside))`); same-type deep nesting (`((outer ((inner))
-- outer))`) doesn't -- the non-greedy regex matches only the first complete
-- pair, leaving the outer wrap's trailing chunk in the babble path.
-- Vanishingly rare in real RP.
--
-- KNOWN LIMITATION -- decoy ordering
-- restore() replaces one occurrence per key, not all of them (see restore()'s
-- own comment for why), so a player typing placeholder-shaped text no longer
-- gets it globally overwritten by the real block's content. If more than one
-- occurrence of the same key text is present (the real placeholder plus a
-- player-typed decoy), the LEFTMOST one wins. That's always correct when the
-- decoy sits elsewhere in the message relative to the real placeholder (the
-- common case, and the one a player could plausibly hit); a decoy placed
-- earlier in the text than the real placeholder can still swap which
-- occurrence receives which content. Deliberately not chasing full
-- positional tracking for that combination -- same "vanishingly rare" call
-- as the nesting limitation above.
--
-- PUBLIC API
--   M.protect(text, opts)            -> workingText, blocks, order
--   M.restore(text, blocks, order)   -> text
--   M.DEFAULT_PATTERNS / M.DEFAULT_PATTERN_ORDER -- read-only by convention;
--     MC_Radio.findProtectedSpans sources its span-shapes from these so a
--     future pattern can't silently miss its clamp logic.
--   opts.keyTemplate -- placeholder key format (default "MCSAN%d"); must be
--     Lua-pattern-safe. Override for log compatibility, e.g. "MCBLEED%d".

local M = {}

-- Each entry: pattern (Lua regex, one capture group) + wrap(content) -> original
-- string with delimiters. Single source of truth -- see PUBLIC API above.
local DEFAULT_PATTERNS = {
    asteriskMood = {
        pattern = "%*%*(.-)%*%*",
        wrap    = function(content) return "**" .. content .. "**" end,
    },
    asteriskEmote = {
        pattern = "%*([^*]-)%*",
        wrap    = function(content) return "*" .. content .. "*" end,
    },
    oocParens = {
        pattern = "%(%((.-)%)%)",
        wrap    = function(content) return "((" .. content .. "))" end,
    },
}

local DEFAULT_PATTERN_ORDER = { "asteriskMood", "asteriskEmote", "oocParens" }

M.DEFAULT_PATTERNS = DEFAULT_PATTERNS
M.DEFAULT_PATTERN_ORDER = DEFAULT_PATTERN_ORDER

-- protect(text, opts) -> workingText, blocks, order
-- blocks: placeholder -> original wrapped content. order: insertion-order
-- list of placeholder keys (needed for correct reverse-order restore).

function M.protect(text, opts)
    if type(text) ~= "string" or #text == 0 then
        return text or "", {}, {}
    end
    opts = opts or {}

    local template = opts.keyTemplate or "MCSAN%d"

    local blocks = {}
    local insertOrder = {}
    local count = 0
    local working = text

    for _, name in ipairs(DEFAULT_PATTERN_ORDER) do
        local spec = DEFAULT_PATTERNS[name]
        if spec then
            working = working:gsub(spec.pattern, function(content)
                count = count + 1
                local key = string.format(template, count)
                blocks[key] = spec.wrap(content)
                insertOrder[#insertOrder + 1] = key
                return key
            end)
        end
    end

    return working, blocks, insertOrder
end

-- restore(text, blocks, order) -> text
-- REVERSE insertion order -- the nested-region fix: outer wraps insert after
-- their contents (outer patterns match a string that already has inner
-- placeholders), so restoring outer-first would surface inner placeholders
-- as literal text.
--
-- Replacement is a function, not a string -- gsub would otherwise read `%`
-- in user content as a Lua-pattern capture reference (breaks `*100% sure*`).
--
-- ONE occurrence per key, not all of them (the trailing `1` on gsub below).
-- A player can type placeholder-shaped text themselves -- "MCBLEED1" is a
-- perfectly ordinary word to a person who doesn't know it's this pass's
-- sentinel format. A global gsub here restores every coincidental match,
-- silently overwriting the player's own words with whatever this key's
-- protected content is. Each key has exactly one REAL occurrence (protect()
-- only ever mints it once); restoring only the first occurrence leaves any
-- decoy elsewhere in the message untouched. See the KNOWN LIMITATION above
-- for the one ordering case this doesn't fully solve.

function M.restore(text, blocks, order)
    if type(text) ~= "string" or not blocks or not order then return text end

    for i = #order, 1, -1 do
        local key = order[i]
        local original = blocks[key]
        if original then
            text = text:gsub(key, function() return original end, 1)
        end
    end

    return text
end

return M
