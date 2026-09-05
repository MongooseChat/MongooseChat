--[[
================================================================================
    MongooseChat - Radio Subsystem
    
    Passive broadcast model. Speech near audible radios with unmuted
    microphones transmits on the radio's frequency.
    
    TRANSMISSION MODEL:
    - No push-to-talk required
    - Radio on + speaker volume above zero + mic unmuted + speech in range
      = transmission
    
    B42 API NOTES:
    - DeviceData methods stable
    - Frequencies are integers (98600 = 98.6 MHz)
    - Ground radios via IsoGridSquare iteration
    - Vehicle radios via getPartById("Radio")
    - Headphone detection: 0=speaker, 1=earbuds, 2=headphones
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Config = require("MC_Config")
local MC_Sanitize = require("MC_Sanitize")
local MC_Incident = require("MC_Incident")

local dbg = MC_Core.debugger("RADIO")

local MC_Radio = {}

-- Radio routing is geometry-sensitive: an unreadable coordinate must never
-- become the origin, and NaN/infinity must never reach distance arithmetic or
-- position keys. Keep the checks here so client discovery and server receiver
-- discovery enforce the same boundary.
local function isFiniteNumber(value)
    return type(value) == "number"
       and value == value
       and value > -math.huge
       and value < math.huge
end

local function normalizeWeatherMultiplier(value)
    if isFiniteNumber(value) and value >= 0 and value <= 3.0 then
        return value
    end
    MC_Incident.report("RADIO_WEATHER_UNAVAILABLE",
        "packet-loss multiplier invalid; maximum interference used")
    return 3.0
end

local function isValidPosition(position)
    return type(position) == "table"
       and isFiniteNumber(position.x)
       and isFiniteNumber(position.y)
       and isFiniteNumber(position.z)
end

local function isValidPlanarPosition(position)
    return type(position) == "table"
       and isFiniteNumber(position.x)
       and isFiniteNumber(position.y)
end

local function readEntityPosition(entity, label)
    if not entity then
        MC_Incident.report("RADIO_POSITION_UNAVAILABLE",
            tostring(label or "entity") .. " missing")
        return nil
    end

    local ok, x, y, z = pcall(function()
        return entity:getX(), entity:getY(), entity:getZ()
    end)
    if not ok or not isFiniteNumber(x) or not isFiniteNumber(y)
       or not isFiniteNumber(z) then
        MC_Incident.report("RADIO_POSITION_UNAVAILABLE",
            tostring(label or "entity") .. " coordinates unreadable")
        return nil
    end

    return { x = x, y = y, z = z }
end

-- Read-only discovery must distinguish an API call which succeeded and found
-- nothing from one which could not be inspected. MC_Core.safe(..., nil/0)
-- erased that distinction throughout the old scan. These helpers keep it as a
-- second return and emit an always-on, stable incident at the failed seam.
local function discoveryUnavailable(label)
    MC_Incident.report("RADIO_DISCOVERY_UNAVAILABLE", tostring(label))
end

local unpackArgs = table.unpack or unpack

local function readMethod(target, methodName, label, ...)
    if target == nil then
        discoveryUnavailable(tostring(label) .. " target missing")
        return nil, false
    end

    local okMethod, method = pcall(function() return target[methodName] end)
    if not okMethod or method == nil then
        discoveryUnavailable(tostring(label) .. " method unavailable")
        return nil, false
    end

    local args = {...}
    local ok, value = pcall(function()
        return method(target, unpackArgs(args))
    end)
    if not ok then
        discoveryUnavailable(tostring(label) .. " read failed")
        return nil, false
    end
    return value, true
end

local function readCollectionSize(collection, label)
    local size, ok = readMethod(collection, "size", label .. " size")
    if not ok then return nil, false end
    if not isFiniteNumber(size) or size < 0 or size % 1 ~= 0 then
        discoveryUnavailable(label .. " size invalid")
        return nil, false
    end
    return size, true
end

-- CONSTANTS

-- Radio source identifiers (for tracking where a radio state came from)
MC_Radio.SOURCE_PLAYER = "player"    -- Carried in hands/belt/inventory
MC_Radio.SOURCE_GROUND = "ground"    -- Placed on floor/table
MC_Radio.SOURCE_VEHICLE = "vehicle"  -- Built into vehicle dashboard

-- PACKET LOSS / STATIC SIMULATION
-- 
-- The soul of the radio. These aren't decoration -- they make it feel real.
-- The flat-string variant (addPacketLoss) was previously a local in
-- MC_Server; in v8.5.1 it moved here so the chunked variant could live
-- alongside, and so the harness can exercise both.
-- 
-- Randomness is injected via opts.rand (function taking n, returning
-- 0..n-1, defaulting to the PZ global ZombRand) so tests can pin the
-- behaviour deterministically without monkey-patching globals at the
-- module level.

MC_Radio.STATIC_POPS = {
    '*krrk*', '*pzzt*', '*fzzt*', '*zap*', '*whirr*',
    '*fzzzt*', '*shhhk*', '*wrrrp*', '*bzzzt*', '*chck*',
    '*clnk*', '*tssk*', '*thrum*', '*zzzt*', '*click*',
    '*crackle*', '*hisss*', '*pop*', '*skrrt*', '*whrr*'
}

-- Base corruption rates (weather makes these worse)
MC_Radio.LOSS_CHANCE_BASE     = 0.20  -- per-word corruption probability
MC_Radio.BOOKEND_STATIC_START = 0.40  -- chance of static before message
MC_Radio.BOOKEND_STATIC_END   = 0.50  -- chance of static after message

-- Resolve a random source: explicit opts.rand wins, otherwise the global
-- ZombRand provided by PZ. Tests pass a deterministic function; production
-- gets ZombRand for free.
local function resolveRand(opts)
    if opts and type(opts.rand) == "function" then return opts.rand end
    return ZombRand
end

local function randomStaticPop(rand)
    local pops = MC_Radio.STATIC_POPS
    return pops[rand(#pops) + 1]
end

-- Word-level corruption pass. Operates on a single text string in
-- isolation (no bookends, no mid-message static). The MC_Sanitize wrap is
-- here because RP/OOC markers should always pass through static intact,
-- regardless of whether we're degrading a whole message or just one chunk.
--
-- Returns:
--   result          the corrupted string
--   eligibleWords    count of non-protected words considered for corruption
--   staticLossWords  count of those words that were fully replaced by a
--                    static pop (as opposed to surviving untouched or
--                    mid-word-cut). Callers use these two counts to know,
--                    explicitly, whether EVERY real word in this text was
--                    statified out -- rather than re-detecting that by
--                    pattern-matching the resulting text's shape, which
--                    can't tell "generated static" from "player text that
--                    happens to look like one bare *marker*".
local function splitProtectedToken(token, protectedOrder)
    local parts = {}
    local cursor = 1

    -- Protection keys can touch ordinary speech or punctuation inside the
    -- same whitespace token ("attack{{PROTECTED1}},"). Find each literal key
    -- so only the surrounding fragments are eligible for packet loss. If the
    -- whole token were corrupted, a damaged key could no longer be restored
    -- and its internal sentinel would become visible to players.
    while cursor <= #token do
        local nextStart, nextEnd = nil, nil
        for _, key in ipairs(protectedOrder or {}) do
            local startPos, endPos = token:find(key, cursor, true)
            if startPos and (not nextStart or startPos < nextStart) then
                nextStart, nextEnd = startPos, endPos
            end
        end

        if not nextStart then
            parts[#parts + 1] = { text = token:sub(cursor), protected = false }
            break
        end
        if nextStart > cursor then
            parts[#parts + 1] = {
                text = token:sub(cursor, nextStart - 1),
                protected = false,
            }
        end
        parts[#parts + 1] = {
            text = token:sub(nextStart, nextEnd),
            protected = true,
        }
        cursor = nextEnd + 1
    end

    return parts
end

local function corruptWords(text, weatherMultiplier, rand)
    if not text or text == "" then return text, 0, 0 end

    local lossChance = math.min(MC_Radio.LOSS_CHANCE_BASE * weatherMultiplier, 0.60)

    -- Distinct keyTemplate from MC_Sanitize's own default ("MCSAN%d"),
    -- following the same per-call-site convention MC_Lang ("MCBLEED%d")
    -- and MC_Cultural ("MCCULTURAL%d") use (see MC_Sanitize's own opts
    -- doc): a placeholder shape traceable to the subsystem that produced
    -- it, distinct from every other concurrently-protected pass.
    local protected, protected_blocks, protected_order = MC_Sanitize.protect(text, {
        keyTemplate = "{{PROTECTED%d}}",
    })

    local words = {}
    for word in protected:gmatch("%S+") do
        table.insert(words, word)
    end

    local out = {}
    local eligibleWords = 0
    local staticLossWords = 0
    for _, word in ipairs(words) do
        local tokenOut = {}
        for _, part in ipairs(splitProtectedToken(word, protected_order)) do
            local fragment = part.text
            if part.protected then
                tokenOut[#tokenOut + 1] = fragment
            else
                eligibleWords = eligibleWords + 1
                if #fragment > 3 and rand(100) < (lossChance * 100) then
                    if rand(100) < 70 and #fragment > 4 then
                        -- Mid-word corruption: "something" -> "some..ing"
                        local startCut = rand(#fragment - 3) + 1
                        local endCut = startCut + rand(2) + 1
                        if endCut > #fragment then endCut = #fragment end
                        local corrupted = fragment:sub(1, startCut) .. ".." .. fragment:sub(endCut + 1)
                        tokenOut[#tokenOut + 1] = corrupted
                    else
                        -- Word lost to static
                        staticLossWords = staticLossWords + 1
                        tokenOut[#tokenOut + 1] = randomStaticPop(rand)
                    end
                else
                    tokenOut[#tokenOut + 1] = fragment
                end
            end
        end
        out[#out + 1] = table.concat(tokenOut)
    end

    local result = table.concat(out, " ")
    -- Preserve leading/trailing whitespace from the input so per-chunk
    -- callers don't lose the boundary spaces between adjacent base chunks.
    local leadingWS = text:match("^(%s*)") or ""
    local trailingWS = text:match("(%s*)$") or ""
    result = leadingWS .. result .. trailingWS

    result = MC_Sanitize.restore(result, protected_blocks, protected_order)
    return result, eligibleWords, staticLossWords
end

-- Byte spans (start, end) of MC_Sanitize's protected marker shapes
-- (**mood**, *emote*, ((ooc))) found directly in already-restored text.
-- Used only by the flat addPacketLoss's mid-message splice below: unlike
-- the chunked path (which only ever inserts static as a NEW chunk at a
-- chunk boundary), the flat path picks a raw byte offset into the fully
-- assembled string and could otherwise land inside a marker and split it.
--
-- Sourced directly from MC_Sanitize.DEFAULT_PATTERNS/DEFAULT_PATTERN_ORDER
-- (same shapes, same order) rather than a hand-copied pattern list, so a
-- future fourth protected shape added there can't silently miss the clamp
-- logic here. string.find tolerates the capture group in each pattern --
-- {s, e} come from find's own start/end, the capture is simply unused.
--
-- A later pattern skips any match starting inside a span an earlier one
-- already claimed -- mirrors MC_Sanitize's own double-before-single
-- precedence so *emote*'s scan can't re-match **mood**'s own delimiters
-- as a spurious empty span.
local function findProtectedSpans(text)
    local spans = {}
    for _, name in ipairs(MC_Sanitize.DEFAULT_PATTERN_ORDER) do
        local pat = MC_Sanitize.DEFAULT_PATTERNS[name].pattern
        local searchFrom = 1
        while true do
            local s, e = text:find(pat, searchFrom)
            if not s then break end
            local claimed = false
            for _, span in ipairs(spans) do
                if s >= span[1] and s <= span[2] then
                    claimed = true
                    break
                end
            end
            if not claimed then
                table.insert(spans, { s, e })
            end
            searchFrom = e + 1
        end
    end
    return spans
end

-- Nudge a mid-message static insertion point so it never falls strictly
-- inside a protected span (splitting "cra..es *waves warmly*" style
-- text would corrupt a marker). Snaps to just before the span starts.
local function clampInsertPos(pos, spans)
    for _, span in ipairs(spans) do
        if pos >= span[1] and pos < span[2] then
            return math.max(span[1] - 1, 0)
        end
    end
    return pos
end

--[[
    Apply radio packet loss + bookend static to a flat string.
    The legacy MC_Server entry point -- preserved with byte-identical
    behaviour for the same inputs and ZombRand seed.

    @param message            string to corrupt
    @param weatherMultiplier  1.0 = clear, up to ~3.0 in heavy weather
    @param opts               optional { rand = function(n) -> 0..n-1 }
    @return                   corrupted string
]]
function MC_Radio.addPacketLoss(message, weatherMultiplier, opts)
    weatherMultiplier = normalizeWeatherMultiplier(weatherMultiplier)
    local rand = resolveRand(opts)

    local result = corruptWords(message, weatherMultiplier, rand)

    local startChance = math.min(MC_Radio.BOOKEND_STATIC_START * weatherMultiplier, 0.85)
    local endChance   = math.min(MC_Radio.BOOKEND_STATIC_END   * weatherMultiplier, 0.90)

    if rand(100) < (startChance * 100) then
        result = randomStaticPop(rand) .. " " .. result
    end
    if rand(100) < (endChance * 100) then
        result = result .. " " .. randomStaticPop(rand)
    end

    -- Mid-message static in bad weather. This splices by raw byte offset
    -- into the already-restored string, so (unlike the chunked path's
    -- boundary-only insertion) it could land inside a protected
    -- *emote*/((aside)) marker and split it -- clamp the offset so it
    -- never does.
    if weatherMultiplier >= 2.0 and rand(100) < 40 and #result > 1 then
        local insertPos = rand(#result - 1) + 1
        insertPos = clampInsertPos(insertPos, findProtectedSpans(result))
        result = result:sub(1, insertPos) .. " " ..
                 randomStaticPop(rand) .. " " ..
                 result:sub(insertPos + 1)
    end

    return result
end

--[[
    Chunk-aware packet loss for v8.5+ chunked render output. Walks the
    chunks array, applies word-level corruption per chunk (preserving
    chunk colour and alpha for mid-word cuts, falling back to base
    colour when a chunk's content fully becomes a static pop), then
    inserts bookend / mid-message static as new base-colour chunks.

    @param chunks             v8.5 chunk array, OR nil
    @param weatherMultiplier  1.0 = clear, up to ~3.0 in heavy weather
    @param opts               optional { rand = function(n) -> 0..n-1 }
    @return degradedChunks    new chunk array (input is not mutated)
    @return flatString        assembled text equivalent to the chunks
]]
function MC_Radio.addPacketLossToChunks(chunks, weatherMultiplier, opts)
    weatherMultiplier = normalizeWeatherMultiplier(weatherMultiplier)
    local rand = resolveRand(opts)

    if not chunks or #chunks == 0 then
        return chunks, ""
    end

    -- Per-chunk word corruption. Preserve colour/alpha for chunks that
    -- survive mid-word cuts; reset colour to nil only when the corruption
    -- pass ITSELF replaced every eligible word in the chunk with a static
    -- pop (staticLossWords == eligibleWords, both > 0) -- tracked
    -- explicitly by corruptWords rather than re-derived by pattern-
    -- matching degradedText's shape. The old shape-match (`^%*[^%*]+%*$`)
    -- couldn't tell a generated-static chunk from an untouched chunk whose
    -- real, uncorrupted content is itself a bare `*emote*` marker -- e.g.
    -- a player writing "*waves warmly*" with zero corruption chance had
    -- that styling stripped for looking like static it never became.
    local out = {}
    for _, chunk in ipairs(chunks) do
        local degradedText, eligibleWords, staticLossWords =
            corruptWords(chunk.text or "", weatherMultiplier, rand)
        local newChunk = { text = degradedText }
        local generatedStatic = eligibleWords > 0 and staticLossWords == eligibleWords
        if generatedStatic then
            -- Every real word in this chunk was statified out by THIS
            -- pass -- leave color/alpha nil so it renders as base text
            -- (channel default), and record that explicitly for callers.
            newChunk.isGeneratedStatic = true
        else
            -- Mid-word survival, untouched text, or protected-only
            -- content -- keep the chunk's style.
            newChunk.color = chunk.color
            newChunk.alpha = chunk.alpha
        end
        table.insert(out, newChunk)
    end

    -- Bookend static -- prepended/appended as base-colour chunks.
    local startChance = math.min(MC_Radio.BOOKEND_STATIC_START * weatherMultiplier, 0.85)
    local endChance   = math.min(MC_Radio.BOOKEND_STATIC_END   * weatherMultiplier, 0.90)

    if rand(100) < (startChance * 100) then
        table.insert(out, 1, { text = randomStaticPop(rand) .. " " })
    end
    if rand(100) < (endChance * 100) then
        table.insert(out, { text = " " .. randomStaticPop(rand) })
    end

    -- Mid-message static in bad weather: insert at a random chunk boundary.
    if weatherMultiplier >= 2.0 and rand(100) < 40 and #out > 1 then
        local insertAt = rand(#out - 1) + 2  -- between 2 and #out (inclusive)
        table.insert(out, insertAt, { text = " " .. randomStaticPop(rand) .. " " })
    end

    -- Derive the flat string from the degraded chunks.
    local flatBuf = {}
    for _, c in ipairs(out) do
        table.insert(flatBuf, c.text)
    end

    return out, table.concat(flatBuf)
end

-- RADIO STATE BUILDER
-- Normalizes data from player/ground/vehicle radios into a unified shape
-- for routing logic. All the defensive pcall wrapping lives here.

local function buildRadioState(deviceData, source, position, ownerId)
    if not deviceData then
        MC_Incident.report("RADIO_METADATA_INVALID", "device data unavailable")
        return nil, false
    end

    if not isValidPosition(position) then
        MC_Incident.report("RADIO_POSITION_UNAVAILABLE",
            "radio source=" .. tostring(source or "unknown"))
        return nil, false
    end

    local authoritative = true
    
    -- Get frequency - B42 uses integers (98600 = 98.6 MHz)
    local freqOK, freq = pcall(function() return deviceData:getChannel() end)
    
    -- Frequencies are positive integers. Reject bad device metadata rather
    -- than allowing it into table keys and formatted debug output.
    if not freqOK or not isFiniteNumber(freq) or freq <= 0 or freq % 1 ~= 0 then
        MC_Incident.report("RADIO_METADATA_INVALID",
            "device frequency unavailable")
        return nil, false
    end
    
    -- Compound power check: must be turned on AND have power
    local onOK, isOn = pcall(function() return deviceData:getIsTurnedOn() end)
    if not onOK or type(isOn) ~= "boolean" then
        isOn = false
        authoritative = false
        MC_Incident.report("RADIO_METADATA_INVALID",
            "device power switch unavailable")
    end
    local powerOK, power = pcall(function() return deviceData:getPower() end)
    if not powerOK or not isFiniteNumber(power) or power < 0 then
        power = 0
        authoritative = false
        MC_Incident.report("RADIO_METADATA_INVALID",
            "device power unavailable")
    end
    local hasPower = power > 0
    
    -- If the radio is "on" but dead battery, it's effectively off
    local effectivelyOn = isOn and hasPower
    
    -- Get transmission capability
    local twoWayOK, isTwoWay = pcall(
        function() return deviceData:getIsTwoWay() end)
    if not twoWayOK or type(isTwoWay) ~= "boolean" then
        isTwoWay = false
        authoritative = false
        MC_Incident.report("RADIO_METADATA_INVALID",
            "device two-way state unavailable")
    end
    local mutedOK, micMuted = pcall(
        function() return deviceData:getMicIsMuted() end)
    if not mutedOK or type(micMuted) ~= "boolean" then
        micMuted = true
        authoritative = false
        MC_Incident.report("RADIO_METADATA_INVALID",
            "device microphone state unavailable")
    end
    local rangeOK, rawTransmitRange = pcall(
        function() return deviceData:getTransmitRange() end)
    local transmitRangeReliable = rangeOK
        and isFiniteNumber(rawTransmitRange) and rawTransmitRange >= 0
    local transmitRange = transmitRangeReliable and rawTransmitRange or 0
    if not transmitRangeReliable then
        authoritative = false
        MC_Incident.report("RADIO_METADATA_INVALID",
            "device transmit range unavailable")
    end

    local volumeOK, rawVolume = pcall(
        function() return deviceData:getDeviceVolume() end)
    local volumeReliable = volumeOK and isFiniteNumber(rawVolume)
        and rawVolume >= 0
    local volume = volumeReliable and rawVolume or 0
    if not volumeReliable then
        authoritative = false
        MC_Incident.report("RADIO_METADATA_INVALID",
            "device volume unavailable")
    end
    
    -- Headphone detection (B42 API, as used by vanilla ISRadioAction and
    -- RWMVolume):
    -- -1 = No headphones (PUBLIC speaker mode)
    --  0 = Earbuds (PRIVATE)
    --  1 = Headphones (PRIVATE)
    local headphoneOK, rawHeadphoneType = pcall(
        function() return deviceData:getHeadphoneType() end)
    local headphoneReliable = headphoneOK and isFiniteNumber(rawHeadphoneType)
        and rawHeadphoneType >= -1 and rawHeadphoneType <= 1
        and rawHeadphoneType % 1 == 0
    -- Unknown headphone state is private: treating it as a loudspeaker would
    -- expose content to nearby players.
    local headphoneType = headphoneReliable and rawHeadphoneType or 0
    local isPrivate = not headphoneReliable or headphoneType >= 0
    if not headphoneReliable then
        authoritative = false
        MC_Incident.report("RADIO_METADATA_INVALID",
            "device headphone state unavailable")
    end
    
    return {
        frequency = freq,
        isTwoWay = isTwoWay == true,
        isOn = effectivelyOn,
        micMuted = micMuted ~= false,  -- nil/error = treat as muted (safe default)
        transmitRange = transmitRange,
        transmitRangeReliable = transmitRangeReliable,
        volume = volume,
        volumeReliable = volumeReliable,
        receptionReliable = volumeReliable and headphoneReliable,
        headphoneType = headphoneType,
        isPrivate = isPrivate,
        source = source,
        position = position,
        ownerId = ownerId
    }, authoritative
end

-- PREDICATES
-- Simple boolean checks on radio state

--[[
    Can this radio transmit?
    Requires: powered on, two-way capable, audible device volume, mic not
    muted. In Build 42, setting the radio's speaker volume to zero is the
    player-facing mute control, so it mutes the whole MC relay rather than
    leaving an invisible hot microphone behind.
]]
function MC_Radio.canEmit(radioState)
    if not radioState then return false end
    return radioState.isOn == true
       and radioState.isTwoWay == true
       and radioState.micMuted == false
       and radioState.volumeReliable == true
       and isFiniteNumber(radioState.volume)
       and radioState.volume > 0
       and radioState.transmitRangeReliable == true
       and isFiniteNumber(radioState.transmitRange)
       and radioState.transmitRange >= 0
end

--[[
    Can this radio receive?
    Requires powered-on, reliable reception metadata and audible output volume.
    Microphone mute is intentionally irrelevant to reception.
]]
function MC_Radio.canReceive(radioState)
    if not radioState then return false end
    return radioState.isOn == true
       and radioState.receptionReliable == true
       and isFiniteNumber(radioState.volume)
       and radioState.volume > 0
       and type(radioState.isPrivate) == "boolean"
end

--[[
    Do two radios share a frequency?
    Exact integer match required

    Internal contract: exercised by test_radio_pure. No in-tree production
    caller -- findReceivers below groups emitters by frequency as a table
    key rather than calling this predicate pairwise. Kept on the public API
    as pure predicate logic a caller could reasonably want.
]]
function MC_Radio.frequenciesMatch(emitter, receiver)
    if not emitter or not receiver then return false end
    return emitter.frequency == receiver.frequency
end

--[[
    Is receiver within emitter's transmit range?
    @return inRange (boolean), distance (number)
]]
function MC_Radio.isInTransmitRange(emitter, receiver)
    if not emitter or not receiver then return false, -1 end
    if not isValidPlanarPosition(emitter.position)
       or not isValidPlanarPosition(receiver.position)
       or not isFiniteNumber(emitter.transmitRange)
       or emitter.transmitRange < 0 then
        MC_Incident.report("RADIO_METADATA_INVALID",
            "range check received invalid radio geometry")
        return false, -1
    end

    local distance = MC_Core.distance2D(emitter.position.x, emitter.position.y,
        receiver.position.x, receiver.position.y)

    return distance <= emitter.transmitRange, distance
end

-- RADIO DISCOVERY - PLAYER
-- Find radios carried by a player

-- Check if an item is a radio and extract its state
local function tryGetRadioState(item, source, position, ownerId)
    if not item then return nil, true end
    
    -- A successful method lookup with no getDeviceData means this is simply a
    -- non-radio item. A failed lookup/call means the item could not be
    -- classified, which makes the containing scan non-authoritative.
    local methodOK, getter = pcall(function() return item.getDeviceData end)
    if not methodOK then
        discoveryUnavailable("item device method unreadable")
        return nil, false
    end
    if getter == nil then return nil, true end
    
    local callOK, deviceData = pcall(function() return item:getDeviceData() end)
    if not callOK then
        discoveryUnavailable("item device data read failed")
        return nil, false
    end
    -- Some ordinary InventoryItem implementations expose the accessor and
    -- legitimately return nil. That is a verified non-radio, not an incident.
    if not deviceData then return nil, true end
    
    return buildRadioState(deviceData, source, position, ownerId)
end

--[[
    Get radio from player's hands, belt attachments, or inventory.
    Returns the FIRST radio found (regardless of state).

    NOTE: For emission/reception scans where state matters, prefer
    getAllPlayerRadios() instead. This short-circuit function is kept for
    callers that just want "does this player have any radio on them".

    Delegates to getAllPlayerRadios(player)[1] -- mirrors findEmitters'
    delegation onto findPlayerEmitters below. Equivalent to the old
    hand-rolled priority walk because getAllPlayerRadios scans in the exact
    same order (primary hand, secondary hand, attached/belt items, then
    full inventory) and never reorders or filters by state; its first
    array element is therefore always the same radio this function used to
    return on its first early-return hit.

    Priority order:
    1. Primary hand (most explicit - you're holding it)
    2. Secondary hand
    3. Belt attachments (visible on character)
    4. Inventory (catches belt-equipped when sync fails)

    Internal contract: no in-tree production caller (findPlayerEmitters and
    findReceivers both moved to getAllPlayerRadios below -- see the fix
    notes there and on those two functions themselves); test_radio_pure
    reaches the local buildRadioState() normalization logic through this
    function, since it's the only public entry point that does. Kept on
    the public API as a legitimate first-found convenience query in its
    own right.
]]
function MC_Radio.getPlayerRadio(player)
    local radios, authoritative = MC_Radio.getAllPlayerRadios(player)
    if type(radios) ~= "table" then
        discoveryUnavailable("player radio result invalid")
        return nil, false
    end
    return radios[1], authoritative == true
end

--[[
    Get ALL radios the player has on their person.
    
    Fix for C32/C33 (0.8.0): previously getPlayerRadio returned first-found
    only. If a player was holding an unusable radio and had a working radio
    in their bag, the in-hand one was returned and the working one was ignored
    -- so it never transmitted or received, despite being fully functional.
    
    Checks hands, attachment slots, and nested carried containers. Deduplicates
    by item/container identity so the same radio isn't returned multiple times
    across engine views and malformed container cycles terminate safely.
    
    @param player IsoPlayer
    @return Array of radioState tables (empty if none found), authoritative
            `authoritative` is true only when every player/item collection
            seam was read and every discovered radio had exact metadata.
]]
function MC_Radio.getAllPlayerRadios(player)
    local radios = {}
    if not player then
        MC_Incident.report("RADIO_POSITION_UNAVAILABLE",
            "radio holder missing")
        return radios, false
    end

    local authoritative = true
    
    local username, usernameOK = readMethod(
        player, "getUsername", "radio holder username")
    if not usernameOK or type(username) ~= "string" or username == "" then
        if usernameOK then
            discoveryUnavailable("radio holder username invalid")
        end
        username = nil
        authoritative = false
    end
    local pos = readEntityPosition(player, "radio holder")
    if not pos then return radios, false end
    
    -- Track seen items by identity to dedupe. In PZ the same InventoryItem
    -- reference is returned across queries; Lua table-as-set with the
    -- userdata as key works for dedup.
    local seen = {}
    local seenContainers = {}
    local inspectItem
    local scannedContainerCount = 0
    local scannedItemCount = 0
    local MAX_NESTED_CONTAINER_DEPTH = 8
    local MAX_SCANNED_CONTAINERS = 64
    local MAX_SCANNED_ITEMS = 2048

    local function inventoryLimit(detail)
        discoveryUnavailable("player inventory " .. tostring(detail))
        authoritative = false
    end

    local function scanContainer(container, label, depth)
        if not container or seenContainers[container] then return end
        if depth > MAX_NESTED_CONTAINER_DEPTH then
            inventoryLimit("nesting limit exceeded")
            return
        end
        if scannedContainerCount >= MAX_SCANNED_CONTAINERS then
            inventoryLimit("container limit exceeded")
            return
        end
        seenContainers[container] = true
        scannedContainerCount = scannedContainerCount + 1

        local items, itemsOK = readMethod(
            container, "getItems", tostring(label) .. " item collection")
        if not itemsOK or items == nil then
            if itemsOK then
                discoveryUnavailable(tostring(label) .. " item collection missing")
            end
            authoritative = false
            return
        end

        local size, sizeOK = readCollectionSize(
            items, tostring(label) .. " item collection")
        if not sizeOK then authoritative = false end
        size = size or 0
        if size > (MAX_SCANNED_ITEMS - scannedItemCount) then
            inventoryLimit("item limit exceeded")
            return
        end
        for i = 0, size - 1 do
            scannedItemCount = scannedItemCount + 1
            local item, itemOK = readMethod(
                items, "get", tostring(label) .. " item", i)
            if not itemOK or item == nil then
                if itemOK then
                    discoveryUnavailable(tostring(label) .. " item missing at index")
                end
                authoritative = false
            else
                inspectItem(item, tostring(label) .. " nested container", depth)
            end
        end
    end

    inspectItem = function(item, label, depth)
        if not item or seen[item] then return end
        seen[item] = true
        local state, stateAuthoritative = tryGetRadioState(
            item, MC_Radio.SOURCE_PLAYER, pos, username)
        if stateAuthoritative ~= true then authoritative = false end
        if state then
            table.insert(radios, state)
        end

        -- InventoryItem's exact B42 type predicate distinguishes containers;
        -- only InventoryContainer then exposes a nested ItemContainer.
        -- Recurse through carried bags so a physical radio remains eligible
        -- regardless of which carried container owns it. Identity guards on
        -- both items and ItemContainers make duplicate engine views and a
        -- malformed container cycle harmless.
        local isContainer, containerTypeOK = readMethod(
            item, "IsInventoryContainer", tostring(label) .. " container type")
        if not containerTypeOK or type(isContainer) ~= "boolean" then
            if containerTypeOK then
                discoveryUnavailable(tostring(label) .. " container type invalid")
            end
            authoritative = false
        elseif isContainer then
            local nested, nestedOK = readMethod(
                item, "getInventory", tostring(label) .. " inventory")
            if not nestedOK or nested == nil then
                if nestedOK then
                    discoveryUnavailable(tostring(label) .. " inventory missing")
                end
                authoritative = false
            else
                scanContainer(nested, label, depth + 1)
            end
        end
    end
    
    -- Hands
    local primary, primaryOK = readMethod(
        player, "getPrimaryHandItem", "primary-hand item")
    if primaryOK then inspectItem(primary, "primary-hand item", 0) else authoritative = false end
    local secondary, secondaryOK = readMethod(
        player, "getSecondaryHandItem", "secondary-hand item")
    if secondaryOK then inspectItem(secondary, "secondary-hand item", 0) else authoritative = false end
    
    -- Attached items (belt etc.)
    local attached, attachedOK = readMethod(
        player, "getAttachedItems", "attached-item collection")
    if not attachedOK or attached == nil then
        if attachedOK then discoveryUnavailable("attached-item collection missing") end
        authoritative = false
    else
        local size, sizeOK = readCollectionSize(attached, "attached-item collection")
        if not sizeOK then authoritative = false end
        size = size or 0
        for i = 0, size - 1 do
            local item, itemOK = readMethod(
                attached, "getItemByIndex", "attached item", i)
            if not itemOK or item == nil then
                if itemOK then discoveryUnavailable("attached item missing at index") end
                authoritative = false
            else
                inspectItem(item, "attached item", 0)
            end
        end
    end
    
    -- Full inventory
    local inventory, inventoryOK = readMethod(
        player, "getInventory", "player inventory")
    if not inventoryOK or inventory == nil then
        if inventoryOK then discoveryUnavailable("player inventory missing") end
        authoritative = false
    else
        scanContainer(inventory, "player inventory", 0)
    end
    
    dbg("getAllPlayerRadios: found %d radios on %s", #radios, tostring(username or "?"))
    return radios, authoritative
end

-- Inspect the player's current vehicle tier. A successful nil vehicle/part/
-- device is a verified absence and remains quiet. A thrown or missing method,
-- unreadable identity/position, or invalid radio is uncertainty.
local function getPlayerVehicleRadio(player, label)
    local vehicle, vehicleOK = readMethod(
        player, "getVehicle", tostring(label) .. " vehicle")
    if not vehicleOK then return nil, false end
    if vehicle == nil then return nil, true end

    local radioPart, partOK = readMethod(
        vehicle, "getPartById", tostring(label) .. " vehicle radio part", "Radio")
    if not partOK then return nil, false end
    if radioPart == nil then return nil, true end

    local deviceData, deviceOK = readMethod(
        radioPart, "getDeviceData", tostring(label) .. " vehicle device")
    if not deviceOK then return nil, false end
    if deviceData == nil then return nil, true end

    local authoritative = true
    local vehicleId, idOK = readMethod(
        vehicle, "getId", tostring(label) .. " vehicle id")
    if not idOK or not isFiniteNumber(vehicleId)
       or vehicleId % 1 ~= 0 then
        if idOK then discoveryUnavailable(tostring(label) .. " vehicle id invalid") end
        vehicleId = nil
        authoritative = false
    end

    local pos = readEntityPosition(vehicle, tostring(label) .. " vehicle")
    if not pos then return nil, false end

    local state, stateAuthoritative = buildRadioState(
        deviceData, MC_Radio.SOURCE_VEHICLE, pos, vehicleId)
    if stateAuthoritative ~= true then authoritative = false end
    return state, authoritative
end

-- RADIO DISCOVERY - GROUND
-- Find radios placed in the world via IsoGridSquare iteration

--[[
    Find all ground-placed radios within range of a position
    @param centerX, centerY, centerZ  World coordinates to search around
    @param range                       Search radius in tiles
    @return Array of radioState objects, authoritative
]]
function MC_Radio.getGroundRadios(centerX, centerY, centerZ, range)
    local radios = {}
    -- A square may hold several distinct radio objects/items. Position-based
    -- dedupe let the first (possibly muted) device mask every other radio on
    -- that tile. Track physical engine identities instead.
    local seenRadios = {}
    local authoritative = true

    -- IsoWorldInventoryObject can be exposed both as a square object and as a
    -- world-item wrapper. Normalize an optional wrapper to its InventoryItem
    -- and remember both identities, so the two engine views count as one
    -- physical radio while distinct radios on the same tile remain distinct.
    local function normalizeGroundEntity(entity, label, requireItem)
        if not entity then return nil end
        local methodOK, getter = pcall(function() return entity.getItem end)
        if not methodOK then
            discoveryUnavailable(tostring(label) .. " item method unreadable")
            authoritative = false
            return nil
        end
        if getter == nil then
            if requireItem then
                discoveryUnavailable(tostring(label) .. " item method unavailable")
                authoritative = false
                return nil
            end
            return entity
        end

        local callOK, item = pcall(function() return entity:getItem() end)
        if not callOK then
            discoveryUnavailable(tostring(label) .. " item read failed")
            authoritative = false
            return nil
        end
        if item == nil and requireItem then
            discoveryUnavailable(tostring(label) .. " inventory item missing")
            authoritative = false
            return nil
        end
        return item or entity
    end

    local function inspectGroundEntity(entity, position, label, requireItem)
        if not entity or seenRadios[entity] then return end
        local candidate = normalizeGroundEntity(entity, label, requireItem)
        if not candidate then
            seenRadios[entity] = true
            return
        end
        if candidate ~= entity and seenRadios[candidate] then
            seenRadios[entity] = true
            return
        end
        seenRadios[entity] = true
        seenRadios[candidate] = true

        local state, stateAuthoritative = tryGetRadioState(
            candidate, MC_Radio.SOURCE_GROUND, position, nil)
        if stateAuthoritative ~= true then authoritative = false end
        if state then table.insert(radios, state) end
    end

    if not isFiniteNumber(centerX) or not isFiniteNumber(centerY)
       or not isFiniteNumber(centerZ) or not isFiniteNumber(range)
       or range < 0 or range % 1 ~= 0 then
        MC_Incident.report("RADIO_POSITION_UNAVAILABLE",
            "ground-radio scan coordinates unavailable")
        return radios, false
    end

    local worldOK, world = pcall(function() return getWorld() end)
    if not worldOK or world == nil then
        discoveryUnavailable("world unavailable for ground-radio scan")
        return radios, false
    end
    local cell, cellOK = readMethod(world, "getCell", "world cell")
    if not cellOK or cell == nil then
        if cellOK then discoveryUnavailable("world cell missing") end
        return radios, false
    end
    
    -- Iterate squares in range
    for dx = -range, range do
        for dy = -range, range do
            local x, y, z = centerX + dx, centerY + dy, centerZ
            local square, squareOK = readMethod(
                cell, "getGridSquare", "world grid square", x, y, z)
            if not squareOK then authoritative = false end
            
            if square then
                -- Check objects on this square (furniture, appliances)
                local objects, objectsOK = readMethod(
                    square, "getObjects", "grid-square object collection")
                
                if not objectsOK or objects == nil then
                    if objectsOK then
                        discoveryUnavailable("grid-square object collection missing")
                    end
                    authoritative = false
                else
                    local size, sizeOK = readCollectionSize(
                        objects, "grid-square object collection")
                    if not sizeOK then authoritative = false end
                    size = size or 0
                    
                    for i = 0, size - 1 do
                        local obj, objOK = readMethod(
                            objects, "get", "grid-square object", i)
                        if not objOK or obj == nil then
                            if objOK then
                                discoveryUnavailable("grid-square object missing at index")
                            end
                            authoritative = false
                        end
                        
                        inspectGroundEntity(
                            obj, {x = x, y = y, z = z}, "grid-square object", false)
                    end
                end
                
                -- Also check world items (dropped radios)
                local worldItems, worldItemsOK = readMethod(
                    square, "getWorldObjects", "world-item collection")
                    
                if not worldItemsOK or worldItems == nil then
                    if worldItemsOK then
                        discoveryUnavailable("world-item collection missing")
                    end
                    authoritative = false
                else
                        local size, sizeOK = readCollectionSize(
                            worldItems, "world-item collection")
                        if not sizeOK then authoritative = false end
                        size = size or 0
                        
                        for i = 0, size - 1 do
                            local worldItem, worldItemOK = readMethod(
                                worldItems, "get", "world item", i)
                            if not worldItemOK or worldItem == nil then
                                if worldItemOK then
                                    discoveryUnavailable("world item missing at index")
                                end
                                authoritative = false
                            end
                            
                            inspectGroundEntity(
                                worldItem, {x = x, y = y, z = z}, "world item", true)
                        end
                end
            end
        end
    end
    
    return radios, authoritative
end

-- MAIN INTERFACE - EMISSION DISCOVERY
-- Find all radios that would broadcast a player's speech

--[[
    Find all radios that would emit this player's speech (CLIENT-SIDE)
    
    @param player     The speaking player
    @param voiceRange Channel range (whisper=2, say=15, yell=60, etc)
    @return Array of radioState objects that will transmit, authoritative
            Partial results are diagnostic only when authoritative is false.
]]
function MC_Radio.findPlayerEmitters(player, voiceRange)
    local emitters = {}
    
    if not player then
        MC_Incident.report("RADIO_POSITION_UNAVAILABLE",
            "speaking player missing")
        return emitters, false
    end
    
    local playerPos = readEntityPosition(player, "speaking player")
    if not playerPos then return emitters, false end
    if not isFiniteNumber(voiceRange) or voiceRange < 0
       or voiceRange % 1 ~= 0 then
        MC_Incident.report("RADIO_METADATA_INVALID",
            "voice range unavailable")
        return emitters, false
    end
    local authoritative = true
    local px, py, pz = playerPos.x, playerPos.y, playerPos.z
    
    dbg("findPlayerEmitters: player at %d,%d,%d voiceRange=%d", px, py, pz, voiceRange)
    
    -- 1. Carried radios (hands / belt / inventory) - no proximity check.
    --    Every audible hot-mic radio on your person picks up your voice.
    --    Fix for C32 (0.8.0): scan ALL inventory radios, not just first-found.
    --    Previously a muted radio in hand would mask a hot radio in the bag.
    local carriedRadios, carriedAuthoritative =
        MC_Radio.getAllPlayerRadios(player)
    if carriedAuthoritative ~= true then authoritative = false end
    for _, carriedRadio in ipairs(carriedRadios) do
        if MC_Radio.canEmit(carriedRadio) then
            dbg("findPlayerEmitters: carried radio on freq %d", carriedRadio.frequency)
            table.insert(emitters, carriedRadio)
        end
    end
    
    -- 2. Audible ground radios within voice range - area microphone
    --    Speaker's channel (whisper/say/yell) determines pickup range
    --    Radio must be within voice range to "hear" the player
    local groundRadios, groundAuthoritative =
        MC_Radio.getGroundRadios(px, py, pz, voiceRange)
    if groundAuthoritative ~= true then authoritative = false end
    for _, radio in ipairs(groundRadios) do
        if MC_Radio.canEmit(radio) then
            local dist = MC_Core.distance2D(
                px, py, radio.position.x, radio.position.y)
            
            if dist <= voiceRange then
                dbg("findPlayerEmitters: ground radio at dist %.1f on freq %d", dist, radio.frequency)
                table.insert(emitters, radio)
            else
                dbg("findPlayerEmitters: ground radio at dist %.1f OUT OF RANGE (need <= %d)", dist, voiceRange)
            end
        end
    end
    
    -- 3. Audible vehicle radio if player is IN the vehicle - cabin microphone
    local vehicleRadio, vehicleAuthoritative =
        getPlayerVehicleRadio(player, "speaker")
    if vehicleAuthoritative ~= true then authoritative = false end
    if vehicleRadio and MC_Radio.canEmit(vehicleRadio) then
        dbg("findPlayerEmitters: vehicle radio on freq %d",
            vehicleRadio.frequency)
        table.insert(emitters, vehicleRadio)
    end
    
    dbg("findPlayerEmitters: found %d emitting radios", #emitters)
    return emitters, authoritative
end

-- MAIN INTERFACE - RECEIVER DISCOVERY (SERVER-SIDE)
-- Find all radios that can receive from given emitters

--[[
    Find all radios that would broadcast a player's speech, grouped by frequency.

    Thin adapter over findPlayerEmitters -- calls that, groups the resulting
    array by frequency. No in-tree consumer (MC_Server's routeRadio builds
    its emitter table a different way); kept as an extension-mod surface for
    the grouped shape (e.g. for server-side routing) rather than the flat
    array findPlayerEmitters returns.

    Prior to 0.8.0 this had its own implementation that used getPlayerRadio
    (first-found, missed hot radios in the bag if a muted one was in hand)
    and skipped ground-radio pickup entirely -- both inconsistent with
    findPlayerEmitters. Delegating keeps one source of truth.

    @param player     The speaking player
    @param voiceRange Channel range (whisper=2, say=15, yell=60, etc.)
    @return Table keyed by frequency: { [freq] = {emitter, ...} },
            authoritative
]]
function MC_Radio.findEmitters(player, voiceRange)
    local byFreq = {}
    local flat, authoritative =
        MC_Radio.findPlayerEmitters(player, voiceRange)
    for _, emitter in ipairs(flat) do
        local freq = emitter.frequency
        byFreq[freq] = byFreq[freq] or {}
        table.insert(byFreq[freq], emitter)
    end
    return byFreq, authoritative == true
end

--[[
    Find the best radio for a player to receive from given emitters
    
    Returns ONE receiver per frequency (deduped). Priority:
    1. Player's carried radio (most personal)
    2. Vehicle radio (if player is in vehicle)
    3. Closest ground radio
    
    @param player         The receiving player
    @param emittersByFreq Table of emitters keyed by frequency
    @return Table keyed by frequency: { [freq] = { receiverInfo } },
            authoritative. Each frequency has a single-element array for API
            compatibility. Partial results are diagnostic only when false.
]]
function MC_Radio.findReceivers(player, emittersByFreq)
    local bestReceivers = {}  -- freq -> receiverInfo (single best)

    local playerPos = readEntityPosition(player, "receiving player")
    if not playerPos then return bestReceivers, false end
    if type(emittersByFreq) ~= "table" then
        MC_Incident.report("RADIO_METADATA_INVALID",
            "receiver scan emitter table unavailable")
        return bestReceivers, false
    end
    local authoritative = true
    local px, py, pz = playerPos.x, playerPos.y, playerPos.z
    
    -- Exclude only the true emitting device: tile + source + frequency (a
    -- freq-blind key wrongly excludes a bystander's radio sharing the tile
    -- on a different frequency). No ownerId: MC_Server's emitter table never
    -- sets one, so keying on it would break self-exclusion instead.
    local function emitterKey(pos, source, freq)
        return math.floor(pos.x) .. "_" .. math.floor(pos.y) .. "_" ..
               source .. "_" .. tostring(freq)
    end

    local emitterPositions = {}
    for _, emitterList in pairs(emittersByFreq) do
        if type(emitterList) == "table" then
            for _, emitter in ipairs(emitterList) do
                if type(emitter) == "table"
                   and isValidPosition(emitter.position)
                   and isFiniteNumber(emitter.frequency)
                   and type(emitter.source) == "string" then
                emitterPositions[emitterKey(emitter.position, emitter.source, emitter.frequency)] = true
                else
                    authoritative = false
                    MC_Incident.report("RADIO_METADATA_INVALID",
                        "receiver scan rejected invalid emitter")
                end
            end
        else
            authoritative = false
            MC_Incident.report("RADIO_METADATA_INVALID",
                "receiver scan rejected invalid emitter list")
        end
    end

    -- An exact empty emitter map requires no receiver/world inspection. This
    -- is a genuine empty result, not a fallback, and stays quiet.
    if MC_Core.isEmpty(emitterPositions) then
        return bestReceivers, authoritative
    end

    local function isEmitter(radio)
        if not isValidPosition(radio.position) then return false end
        return emitterPositions[emitterKey(radio.position, radio.source, radio.frequency)]
    end
    
    -- Helper: check if candidate is better than current best
    -- Priority: player (0) > vehicle (1) > ground (2), then by playerDistance
    local function sourcePriority(source)
        if source == "player" then return 0 end
        if source == "vehicle" then return 1 end
        return 2  -- ground
    end
    
    local function isBetterReceiver(candidate, current)
        if not current then return true end
        local candPri = sourcePriority(candidate.radio.source)
        local currPri = sourcePriority(current.radio.source)
        if candPri ~= currPri then return candPri < currPri end
        -- Same priority tier: prefer closer to player
        return candidate.playerDistance < current.playerDistance
    end
    
    -- Helper: try to register a receiver, keeping only the best per frequency
    local function tryRegisterReceiver(radio, playerDistance)
        if not MC_Radio.canReceive(radio) then return end
        if isEmitter(radio) then return end
        
        local freq = radio.frequency
        if not emittersByFreq[freq] then return end
        
        for _, emitter in ipairs(emittersByFreq[freq]) do
            local inRange, dist = MC_Radio.isInTransmitRange(emitter, radio)
            if inRange then
                local vol = radio.volume
                local hearingRange
                if radio.source == "player" then
                    hearingRange = radio.isPrivate and 0 or 
                        math.max(MC_Config.Ranges.whisper, MC_Config.Ranges.say * vol)
                else
                    hearingRange = math.max(MC_Config.Ranges.whisper, MC_Config.Ranges.yell * vol)
                end
                
                local candidate = {
                    radio = radio,
                    distance = dist,
                    volume = radio.volume,
                    playerDistance = playerDistance,
                    hearingRange = hearingRange
                }
                
                if isBetterReceiver(candidate, bestReceivers[freq]) then
                    dbg("findReceivers: new best for freq %d: %s at playerDist %.1f", 
                        freq, radio.source, playerDistance)
                    bestReceivers[freq] = candidate
                end
                return  -- Found a valid emitter, done with this radio
            end
        end
    end
    
    -- 1. All of the player's carried radios (highest source priority).
    --    Fix for C33 (0.8.0): previously first-found only, which dropped the
    --    hot receiver in the bag if you had an off or zero-volume radio in
    --    hand. Microphone mute gates EMIT only; reception instead requires a
    --    powered radio with audible device volume.
    --    tryRegisterReceiver already picks the single best per frequency.
    local carriedRadios, carriedAuthoritative =
        MC_Radio.getAllPlayerRadios(player)
    if carriedAuthoritative ~= true then authoritative = false end
    for _, playerRadio in ipairs(carriedRadios) do
        tryRegisterReceiver(playerRadio, 0)
    end
    
    -- 2. Vehicle radio (if player is in vehicle)
    local vehicleRadio, vehicleAuthoritative =
        getPlayerVehicleRadio(player, "receiver")
    if vehicleAuthoritative ~= true then authoritative = false end
    if vehicleRadio then
        tryRegisterReceiver(vehicleRadio, 0)
    end
    
    -- 3. Ground radios (lowest priority, sorted by distance)
    local maxHearingRange = math.min(MC_Config.Ranges.yell, 30)
    local groundRadios, groundAuthoritative =
        MC_Radio.getGroundRadios(px, py, pz, maxHearingRange)
    if groundAuthoritative ~= true then authoritative = false end
    dbg("findReceivers: found %d ground radios within %d tiles", #groundRadios, maxHearingRange)
    
    for _, radio in ipairs(groundRadios) do
        local playerToRadio = MC_Core.distance2D(
            px, py, radio.position.x, radio.position.y)
        
        local vol = radio.volume
        local hearingRange = math.max(MC_Config.Ranges.whisper, maxHearingRange * vol)
        
        if playerToRadio <= hearingRange then
            tryRegisterReceiver(radio, playerToRadio)
        end
    end
    
    -- Convert to array format for API compatibility (server expects arrays)
    local receivers = {}
    for freq, receiverInfo in pairs(bestReceivers) do
        receivers[freq] = { receiverInfo }
        dbg("findReceivers: final receiver for freq %d: %s", freq, receiverInfo.radio.source)
    end
    
    return receivers, authoritative
end


-- Internal contract: exposed for test_radio_pure to pin findProtectedSpans'
-- span boundaries directly; not part of the public API.
MC_Radio._findProtectedSpans = findProtectedSpans

return MC_Radio
