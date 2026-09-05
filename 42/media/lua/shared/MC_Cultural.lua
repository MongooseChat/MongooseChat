--[[
================================================================================
    MongooseChat - Cultural Fluency Engine (v8.6)

    Detection AND render integration for palette `cultural` blocks: the gated
    tier of the fluency model -- phrases natives use that non-natives can SEE
    but never REACH through acquisition alone. MC_Lang.renderWithLangs wires
    all four stages: detect() finds regions; substituteForNative() swaps them
    in for native listeners; protectRegions() sentinel-protects them from
    babble for non-natives; restoreToChunks() re-emits them as INHERITED_GREY
    chunks carrying the original English.

    Schema is open-ended (see palette files). `tags` is stored but not read
    here.

    Author: Kialae (Mongoose Server). License: MIT.
================================================================================
]]

local MC_Core = require("MC_Core")

local dbg = MC_Core.debugger("CULTURAL")

local MC_Cultural = {}

-- Alphabetic lead of the placeholder format protectRegions() stamps (default
-- "MCCULTURAL%d"); exposed so MC_Lang's MC_Babble sentinel wiring reads it,
-- not re-declares it.
MC_Cultural.SENTINEL_PREFIX = "MCCULTURAL"

-- DETECTION -- case-insensitive, word-boundary substring match of each
-- palette.cultural entry's `en` field against the message ("Please" inside
-- "pleased" is rejected). Overlap resolution is greedy leftmost-longest: same
-- start position -> longer match wins; different start positions -> leftmost
-- wins, matching "the most-specific phrase the author wrote takes precedence"
-- without author-side priority hints.

-- Region shape (each element of the returned array):
--   { start = <int>, finish = <int> (1-based, inclusive), entry = <table>,
--     matched = <string> (speaker's original casing/spacing, for verbatim echo) }
-- Empty array if no cultural block or no matches.

-- Word-boundary probe: the byte just outside a match must be absent or
-- non-alphanumeric. ASCII checked directly (Kahlua-safe); bytes >= 128
-- (accented letters, either VM) count as word chars -- errs toward NOT matching.
local function isWordByte(b)
    if not b then return false end
    if b >= 48 and b <= 57 then return true end     -- 0-9
    if b >= 65 and b <= 90 then return true end     -- A-Z
    if b >= 97 and b <= 122 then return true end    -- a-z
    return b >= 128                                 -- accented letters
end

function MC_Cultural.detect(message, palette)
    if type(message) ~= "string" or message == "" then return {} end
    if type(palette) ~= "table" or type(palette.cultural) ~= "table" then return {} end
    if #palette.cultural == 0 then return {} end

    local messageLower = message:lower()
    local candidates = {}

    -- Pass 1: find ALL match positions for every entry; sort + dedupe after
    -- (easier to reason about over a flat candidate list than during).
    for _, entry in ipairs(palette.cultural) do
        if type(entry) == "table" and type(entry.en) == "string" and entry.en ~= "" then
            local needle = entry.en:lower()
            local pos = 1
            while pos <= #messageLower do
                local s, e = messageLower:find(needle, pos, true)  -- plain (no regex)
                if not s then break end
                if isWordByte(messageLower:byte(s - 1))
                   or isWordByte(messageLower:byte(e + 1)) then
                    -- Mid-word hit; step one byte forward so a boundary match
                    -- starting inside this span can still be found.
                    pos = s + 1
                else
                    table.insert(candidates, {
                        start = s,
                        finish = e,
                        entry = entry,
                        matched = message:sub(s, e),
                    })
                    pos = e + 1  -- non-overlapping matches OF THE SAME ENTRY
                end
            end
        end
    end

    if #candidates == 0 then return {} end

    -- Pass 2: greedy leftmost-longest dedupe -- sort by start ascending
    -- (longest finish wins ties), then reject any candidate whose start
    -- lies inside the previously-accepted region.
    table.sort(candidates, function(a, b)
        if a.start ~= b.start then return a.start < b.start end
        return a.finish > b.finish  -- longer first on ties
    end)

    local regions = {}
    local lastEnd = 0
    for _, c in ipairs(candidates) do
        if c.start > lastEnd then
            table.insert(regions, c)
            lastEnd = c.finish
        end
    end

    dbg("detect: %d regions found in message of length %d", #regions, #message)
    return regions
end

-- SUBSTITUTION (native receiver path) -- replaces each cultural region's
-- English with the L2 phrase. Returns clean text; natives don't need
-- chunk-level rendering for cultural content.

function MC_Cultural.substituteForNative(message, regions)
    if type(message) ~= "string" or message == "" then return message end
    if not regions or #regions == 0 then return message end

    -- Walk regions in reverse so substitutions don't shift earlier positions.
    local sorted = {}
    for _, r in ipairs(regions) do table.insert(sorted, r) end
    table.sort(sorted, function(a, b) return a.start > b.start end)

    local result = message
    for _, region in ipairs(sorted) do
        if region.entry and type(region.entry.l2) == "string" then
            result = result:sub(1, region.start - 1)
                  .. region.entry.l2
                  .. result:sub(region.finish + 1)
        end
    end

    return result
end

-- SENTINEL PROTECTION (non-native receiver path, pre-pipeline) -- replaces
-- each region with a unique alphanumeric sentinel ("MCCULTURAL%d" default)
-- that passes through MC_Sanitize, babble (via bleedThrough), and
-- applyL1Reinforcement's word-segmentation untouched.
--
-- blocks[sentinel] = { original = <string>, entry = <table>, start = <int>,
--   finish = <int> } (original byte positions). order is position-ordered
-- for API parity with MC_Sanitize -- not required for restore (sentinels
-- never nest).

function MC_Cultural.protectRegions(message, regions, opts)
    if type(message) ~= "string" then return message, {}, {} end
    if not regions or #regions == 0 then return message, {}, {} end

    local keyTemplate = (opts and opts.keyTemplate) or (MC_Cultural.SENTINEL_PREFIX .. "%d")

    -- regions is already sorted ascending by detect(), so IDs assign in position order.
    local blocks = {}
    local order = {}
    local sentinels = {}
    for i, region in ipairs(regions) do
        local sentinel = string.format(keyTemplate, i)
        sentinels[i] = sentinel
        blocks[sentinel] = {
            original = region.matched,
            entry    = region.entry,
            start    = region.start,
            finish   = region.finish,
        }
        table.insert(order, sentinel)
    end

    -- Substitute in reverse so earlier positions stay valid.
    local result = message
    for i = #regions, 1, -1 do
        local region = regions[i]
        local sentinel = sentinels[i]
        result = result:sub(1, region.start - 1)
              .. sentinel
              .. result:sub(region.finish + 1)
    end

    dbg("protectRegions: protected %d region(s)", #regions)
    return result, blocks, order
end

-- RESTORE -- CHUNK PATH -- walks a chunks array (applyL1Reinforcement output,
-- or a trivial single-chunk wrap of a flat string). Each chunk containing
-- sentinels splits into pre-text (original colour/alpha) / sentinel (new
-- INHERITED_GREY chunk, configurable via opts.color/alpha, carrying the
-- original English) / post-text (original colour/alpha); iterates until no
-- sentinels remain, dropping empty fragments. Also rebuilds the flat string
-- from the modified chunks for byte-consistent (chunks, flatString) output.
-- Returns: (newChunks, flatString)

function MC_Cultural.restoreToChunks(chunks, blocks, opts)
    if not chunks then return chunks, "" end
    if MC_Core.isEmpty(blocks) then
        -- Nothing to restore; assemble flat string from existing chunks.
        local buf = {}
        for _, c in ipairs(chunks) do table.insert(buf, c.text or "") end
        return chunks, table.concat(buf)
    end

    local color = (opts and opts.color) or MC_Core.Colors.INHERITED_GREY
    local alpha = (opts and opts.alpha) or 0.65

    local out = {}

    for _, chunk in ipairs(chunks) do
        local text = chunk.text or ""
        local origColor = chunk.color
        local origAlpha = chunk.alpha
        local pos = 1
        local len = #text

        while pos <= len do
            -- Scan for the earliest sentinel match starting at or after `pos`.
            local earliestSentinel, earliestStart, earliestEnd = nil, nil, nil
            for sentinel, _ in pairs(blocks) do
                local s, e = text:find(sentinel, pos, true)
                if s and (earliestStart == nil or s < earliestStart) then
                    earliestSentinel, earliestStart, earliestEnd = sentinel, s, e
                end
            end

            if not earliestSentinel then
                -- No more sentinels in this chunk; emit remainder.
                local rest = text:sub(pos)
                if rest ~= "" then
                    table.insert(out, { text = rest, color = origColor, alpha = origAlpha })
                end
                break
            end

            -- Pre-text (preserves chunk's original styling)
            if earliestStart > pos then
                local pre = text:sub(pos, earliestStart - 1)
                if pre ~= "" then
                    table.insert(out, { text = pre, color = origColor, alpha = origAlpha })
                end
            end

            -- Inherited chunk for the cultural region
            local block = blocks[earliestSentinel]
            table.insert(out, {
                text  = block.original,
                color = color,
                alpha = alpha,
            })

            pos = earliestEnd + 1
        end

        -- Empty chunk (#text==0) preserved as-is so downstream index-based walks don't lose positions.
        if len == 0 then
            table.insert(out, chunk)
        end
    end

    -- Canonical post-restore truth: callers use this as msgData.message, out as msgData.chunks.
    local buf = {}
    for _, c in ipairs(out) do table.insert(buf, c.text or "") end

    return out, table.concat(buf)
end


return MC_Cultural
