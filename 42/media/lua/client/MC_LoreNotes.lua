--[[
================================================================================
    MongooseChat - Lore Notes

    Any written literature item lying on the ground floats its text in a
    persistent sign-style bubble -- writing + dropping IS the lore-note act.
    Purely client-side: authoring is vanilla's Write action, the text rides
    the item itself (map-chunk persistence), and every client renders from
    what it sees on its own squares. No packets, no server state.

    LIFECYCLE (the nameplate pattern, keyed by square instead of username):
    - A slow scan walks the squares around the player and registers one
      bubble per square holding a written note.
    - A fast per-tick pass drives each bubble's proximity fade through
      MC_Bubble's externalAlpha and reaps bubbles that faded out or died.
    - The cue IS the item: pick the note up and the next scan stops seeing
      it, so its bubble fades out and is removed.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Config = require("MC_Config")
local MC_Bubble = require("MC_Bubble")
local MC_Incident = require("MC_Incident")
local MC_Theme = require("MC_Theme")

local dbg = MC_Core.debugger("LORENOTES")

local safeGet = MC_Core.safeGet
local safeExec = MC_Core.safeExec

local MC_LoreNotes = {}

-- Squares are rescanned about twice a second at 30fps; the fade pass runs
-- every tick so approach/leave still feels immediate.
local SCAN_INTERVAL_TICKS = 20

-- Proximity fade duration, matching the nameplate LOS fade.
local FADE_MS = 500

-- Hard cap on simultaneous bubbles. A room papered with notes stays a
-- room, not a wall of UI; squares past the cap simply wait their turn.
local LORE_MAX_VISIBLE = 8

-- Declutter floor. A crowded-out note is dimmed, never hidden: the player
-- must still be able to see that something is there and walk to it.
local LORE_CROWD_ALPHA = 0.28

-- PURE HELPERS

--[[
    Stable registry key for a world square.
    @return "x:y:z" with each coordinate floored to an integer
]]
function MC_LoreNotes._squareKey(x, y, z)
    return string.format("%d:%d:%d",
        math.floor(x), math.floor(y), math.floor(z))
end

--[[
    Normalize raw written-page text into one bubble-ready line.
    Newlines and whitespace runs collapse to single spaces (multiline
    fidelity is a deliberate v1 simplification) and the result is clamped
    to maxLen with an ellipsis. The clamp counts bytes, not glyphs -- close
    enough for a grief cap, and Kahlua-safe.
    @return normalized text, or nil for nil/empty/whitespace-only input
]]
function MC_LoreNotes._normalizeNoteText(raw, maxLen)
    if type(raw) ~= "string" then return nil end
    local text = raw:gsub("[\r\n]", " ")
    text = text:gsub("%s+", " ")
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return nil end
    if type(maxLen) == "number" and maxLen > 0 and #text > maxLen then
        text = text:sub(1, maxLen) .. "..."
    end
    return text
end

--[[
    Step an alpha value linearly toward target, clamped to 0..1.
    dtMs/fadeMs of it is covered per call, so a full fade takes fadeMs.
]]
function MC_LoreNotes._stepAlpha(current, target, dtMs, fadeMs)
    if type(current) ~= "number" or current ~= current then current = 0 end
    if type(target) ~= "number" or target ~= target then target = 0 end
    if type(dtMs) ~= "number" or dtMs ~= dtMs or dtMs < 0 then dtMs = 0 end
    if type(fadeMs) ~= "number" or fadeMs ~= fadeMs or fadeMs <= 0 then
        fadeMs = FADE_MS
    end
    local step = dtMs / fadeMs
    local stepped
    if target > current then
        stepped = math.min(current + step, target)
    else
        stepped = math.max(current - step, target)
    end
    if stepped < 0 then return 0 end
    if stepped > 1 then return 1 end
    return stepped
end

--[[
    2D Euclidean range check, player position against a square center.
    Vertical separation is handled by the scanner only walking the
    player's own z level.
]]
function MC_LoreNotes._inRange(px, py, wx, wy, range)
    local dx = px - wx
    local dy = py - wy
    return (dx * dx + dy * dy) <= (range * range)
end

--[[
    Screen-space AABB overlap. Touching edges do not count as overlapping.
]]
function MC_LoreNotes._boxesOverlap(a, b)
    return not (a.x + a.w <= b.x or b.x + b.w <= a.x
             or a.y + a.h <= b.y or b.y + b.h <= a.y)
end

--[[
    Resolve a crowd of overlapping notes: nearest wins, others dim.

    Walks the notes nearest-first. A note keeps full alpha unless its
    screen box overlaps one already kept, in which case it drops to
    floorAlpha. Walking into a cluster therefore brightens whichever note
    you are beside and sinks its neighbours back, instead of stacking
    unreadable bubbles on top of each other.

    Distance ties break on the registry key so the result is stable frame
    to frame -- a wobbling winner would flicker.

    @param items      array of { key, x, y, w, h, dist }
    @param floorAlpha alpha scale applied to a crowded-out note
    @return map of key -> alpha scale (1 or floorAlpha)
]]
function MC_LoreNotes._crowdScales(items, floorAlpha)
    table.sort(items, function(l, r)
        if l.dist ~= r.dist then return l.dist < r.dist end
        return tostring(l.key) < tostring(r.key)
    end)

    local scales = {}
    local kept = {}
    for _, item in ipairs(items) do
        local crowded = false
        for _, winner in ipairs(kept) do
            if MC_LoreNotes._boxesOverlap(item, winner) then
                crowded = true
                break
            end
        end
        if crowded then
            scales[item.key] = floorAlpha
        else
            scales[item.key] = 1
            kept[#kept + 1] = item
        end
    end
    return scales
end

-- REGISTRY

-- squareKey -> { bubble, text, seen }
--   bubble  the MC_Bubble:newLore element on the UI manager
--   text    the normalized text it was built for (change -> rebuild)
--   seen    whether the last scan still found a note on this square
local activeLoreBubbles = {}
MC_LoreNotes._activeLoreBubbles = activeLoreBubbles

local function registrySize()
    local count = 0
    for _ in pairs(activeLoreBubbles) do count = count + 1 end
    return count
end

local function removeEntry(key)
    local entry = activeLoreBubbles[key]
    if not entry then return end
    activeLoreBubbles[key] = nil
    local bubble = entry.bubble
    if bubble then
        bubble.dead = true
        local removed = safeExec(function() bubble:removeFromUIManager() end)
        if not removed then
            MC_Incident.report("LORENOTE_BUBBLE_REMOVE_FAILED",
                "stage=entry-remove")
        end
    end
end

local function hideAllLoreBubbles()
    -- Collect keys first: removeEntry mutates the table, and only the
    -- offline runtimes (not Kahlua) have proven delete-during-pairs safe.
    -- Same shape as MC_Bio.hideAllNameplates.
    local keys = {}
    for key in pairs(activeLoreBubbles) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do removeEntry(key) end
end

-- SCANNING

-- Helper: local player's UI manager index (0 for single player) -- same
-- shape as MC_Client's copy; both are three lines against a UIManager
-- boundary that has no shared home.
local function getPlayerUIIndex()
    local player = getPlayer()
    if player and player.getPlayerNum then
        return player:getPlayerNum() or 0
    end
    return 0
end

--[[
    Can the local player see this square at all, walls aside from distance?

    isCouldSee is the engine's geometry-only line of sight: it answers "is
    anything opaque between us", NOT "am I facing that way" (isCanSee) and
    NOT "have I explored it" (getSeen). Vanilla's build cursors gate on this
    exact call before letting you work through a wall -- ISPaintCursor and
    ISDestroyCursor both do. That is the behaviour a note wants: an
    atmospheric line for the space you are actually standing in, which stops
    at the wall rather than bleeding into the next room, but which does not
    blink out every time you turn around.

    Fails CLOSED, the same contract as MC_Anonymity.canSee: a square whose
    visibility cannot be established shows nothing rather than showing by
    default.
]]
local function squareIsUnobstructed(square, playerNum)
    local couldSee = safeGet(function()
        return square:isCouldSee(playerNum)
    end, nil)
    if type(couldSee) ~= "boolean" then
        MC_Incident.report("LORENOTE_LOS_UNAVAILABLE", "stage=could-see")
        return false
    end
    return couldSee
end

--[[
    The floating text for one world object, or nil if it isn't a written
    note lying directly on the square. Items inside dropped containers
    stay silent: only an IsoWorldInventoryObject's own item qualifies.
    A locked journal still renders -- the lock gates editing, not reading.
]]
function MC_LoreNotes._noteTextFromObject(obj, maxLen)
    if not safeGet(function()
        return instanceof(obj, "IsoWorldInventoryObject")
    end, false) then
        return nil
    end
    local item = safeGet(function() return obj:getItem() end, nil)
    if not item then return nil end
    -- Category gate FIRST, exactly as the engine does it in
    -- ISInventoryPaneContextMenu (`getCategory() == "Literature" and
    -- canBeWrite()`). canBeWrite lives on the Literature class only; calling
    -- it on a tin can raises, and Kahlua writes a full stack dump BEFORE the
    -- throw that safeGet catches -- so a pcall alone stops the crash but not
    -- the log. This scan touches every object on every square in range every
    -- tick, which turned one item on the floor into an endless cascade.
    if safeGet(function() return item:getCategory() end, nil) ~= "Literature" then
        return nil
    end
    if not safeGet(function() return item:canBeWrite() end, false) then
        return nil
    end
    -- seePage on a never-written item may return nil/"" or throw depending
    -- on build; both read as "nothing written" here.
    local raw = MC_Core.safe(function() return item:seePage(1) end, nil)
    return MC_LoreNotes._normalizeNoteText(raw, maxLen)
end

local function createLoreBubble(text, wx, wy, wz)
    local bubble = MC_Bubble:newLore(text,
        { x = wx + 0.5, y = wy + 0.5, z = wz })
    if not bubble then return nil end
    local ok = safeExec(function()
        bubble:initialise()
        bubble:addToUIManager(getPlayerUIIndex())
        bubble:setVisible(true)
    end)
    if not ok then
        bubble.dead = true
        safeExec(function() bubble:removeFromUIManager() end)
        MC_Incident.report("LORENOTE_BUBBLE_ATTACH_FAILED",
            "stage=ui-manager-add")
        return nil
    end
    return bubble
end

--[[
    Walk the squares around the player and reconcile the registry: register
    the first written note found on each in-range square, rebuild entries
    whose text changed, and leave everything unseen for the fade pass to
    take down. First qualifying object on a square wins -- stacked notes
    show one bubble (move one a tile over to show both).
]]
local function scanForNotes(localPlayer)
    local px = safeGet(function() return localPlayer:getX() end, nil)
    local py = safeGet(function() return localPlayer:getY() end, nil)
    local pz = safeGet(function() return localPlayer:getZ() end, nil)
    local cell = safeGet(function() return getCell() end, nil)

    for _, entry in pairs(activeLoreBubbles) do entry.seen = false end

    if type(px) ~= "number" or type(py) ~= "number"
        or type(pz) ~= "number" or not cell
    then
        MC_Incident.report("LORENOTE_SCAN_UNAVAILABLE", "stage=player-cell")
        return
    end

    -- liveSandbox already type-validates against the SANDBOX_SPECS entry
    -- and reports its own fallback, but the sandbox UI's min/max are not
    -- enforced on a hand-edited served .ini -- and range is a LOOP BOUND
    -- here, so its magnitude is work: an unclamped 500 would scan a
    -- million squares per pass on every client. Clamp to the option's own
    -- 2..15 bounds.
    local range = math.floor(
        MC_Config.liveSandbox("LoreNoteRange", 5))
    if range < 2 then range = 2 elseif range > 15 then range = 15 end
    local maxLen = math.floor(
        MC_Config.liveSandbox("LoreNoteMaxLength", 280))
    local playerNum = getPlayerUIIndex()

    local z = math.floor(pz)
    local baseX = math.floor(px)
    local baseY = math.floor(py)

    for wx = baseX - range, baseX + range do
        for wy = baseY - range, baseY + range do
            if MC_LoreNotes._inRange(px, py, wx + 0.5, wy + 0.5, range) then
                local square = safeGet(function()
                    return cell:getGridSquare(wx, wy, z)
                end, nil)
                local objects = square and safeGet(function()
                    return square:getObjects()
                end, nil) or nil
                local count = objects and safeGet(function()
                    return objects:size()
                end, nil) or 0
                if type(count) ~= "number" or count ~= count then count = 0 end

                for i = 0, count - 1 do
                    local obj = safeGet(function()
                        return objects:get(i)
                    end, nil)
                    local text = obj
                        and MC_LoreNotes._noteTextFromObject(obj, maxLen) or nil
                    if text and squareIsUnobstructed(square, playerNum) then
                        local key = MC_LoreNotes._squareKey(wx, wy, z)
                        local entry = activeLoreBubbles[key]
                        local priorAlpha = nil
                        if entry and entry.text ~= text then
                            -- The text on this square changed: rebuild. Carry
                            -- the fade across it, so a rewrite swaps its words
                            -- in place instead of blinking out and back --
                            -- and so two stacked notes whose winner alternates
                            -- can still finish fading in rather than resetting
                            -- to invisible every scan.
                            priorAlpha = entry.bubble and entry.bubble.externalAlpha
                            removeEntry(key)
                            entry = nil
                        end
                        if not entry
                            and registrySize() < LORE_MAX_VISIBLE
                        then
                            local bubble = createLoreBubble(text, wx, wy, z)
                            if bubble then
                                if priorAlpha then
                                    bubble.externalAlpha = priorAlpha
                                end
                                entry = { bubble = bubble, text = text,
                                    wx = wx + 0.5, wy = wy + 0.5 }
                                activeLoreBubbles[key] = entry
                                dbg("scan: bubble up at %s", key)
                            end
                        end
                        if entry then entry.seen = true end
                        break
                    elseif text then
                        -- A note is here but a wall is between us: stop
                        -- scanning this square. Leaving the entry unseen
                        -- lets the fade pass take its bubble down.
                        break
                    end
                end
            end
        end
    end
end

-- FADE PASS

--[[
    Collect the live bubbles as screen boxes with their distance to the
    player. Valid only after the UI manager has run prerender this frame,
    which is where MC_Bubble refreshes x/y -- so this must stay inside the
    tick pass and not move earlier.
]]
local function crowdItems(px, py)
    if type(px) ~= "number" or type(py) ~= "number" then return nil end

    local items = {}
    for key, entry in pairs(activeLoreBubbles) do
        local bubble = entry.bubble
        if bubble and not bubble.dead and entry.seen
            and type(entry.wx) == "number" and type(entry.wy) == "number"
        then
            local x = safeGet(function() return bubble:getX() end, nil)
            local y = safeGet(function() return bubble:getY() end, nil)
            if type(x) == "number" and type(y) == "number" then
                local dx, dy = px - entry.wx, py - entry.wy
                items[#items + 1] = {
                    key = key, x = x, y = y,
                    w = bubble.width or 0, h = bubble.height or 0,
                    dist = dx * dx + dy * dy,
                }
            end
        end
    end
    if #items < 2 then return nil end
    return items
end

local function updateFades(dtMs, px, py)
    -- Nearest-wins declutter. Off by operator choice, and skipped entirely
    -- when fewer than two notes are up (nothing can overlap).
    local highContrast = MC_Theme.access().highContrast == true
    local scales = nil
    if not highContrast and MC_Config.liveSandbox("LoreNoteDeclutter", true) then
        local items = crowdItems(px, py)
        if items then
            scales = MC_LoreNotes._crowdScales(items, LORE_CROWD_ALPHA)
        end
    end

    -- Reduced motion: the theme answers 0 and the note snaps to its target.
    local fadeMs = MC_Theme.fadeMs(FADE_MS)
    local instant = fadeMs <= 0

    local staleKeys = nil
    for key, entry in pairs(activeLoreBubbles) do
        local bubble = entry.bubble
        if not bubble or bubble.dead then
            -- Position failure in prerender self-marks the bubble dead;
            -- dropping the entry lets the next scan recreate it.
            staleKeys = staleKeys or {}
            staleKeys[#staleKeys + 1] = key
        else
            local target = entry.seen and 1 or 0
            if target > 0 and scales then
                target = target * (scales[key] or 1)
            end
            if highContrast then
                -- Keep readable notes opaque while they are in range.  Once
                -- the existing scan says unseen, hide and reap at once.
                bubble.externalAlpha = target > 0 and 1 or 0
            elseif instant then
                bubble.externalAlpha = target
            else
                bubble.externalAlpha = MC_LoreNotes._stepAlpha(
                    bubble.externalAlpha, target, dtMs, fadeMs)
            end
            -- Only an UNSEEN note is reaped. A note dimmed by the crowd
            -- pass is still present and must survive, or walking past a
            -- cluster would permanently delete its neighbours.
            if not entry.seen and bubble.externalAlpha <= 0 then
                staleKeys = staleKeys or {}
                staleKeys[#staleKeys + 1] = key
            end
        end
    end
    if staleKeys then
        for _, key in ipairs(staleKeys) do removeEntry(key) end
    end
end
MC_LoreNotes._updateFades = updateFades

-- UPDATE LOOP

local ticksSinceScan = SCAN_INTERVAL_TICKS -- scan on the first tick
local lastTickMs = nil

local function OnTickBody()
    local nowMs = MC_Core.getTimeMs()
    local dtMs = 0
    if type(lastTickMs) == "number" and nowMs >= lastTickMs then
        dtMs = nowMs - lastTickMs
    end
    lastTickMs = nowMs

    -- Fail-closed default (false) so a broken sandbox read hides notes
    -- rather than rendering them against an operator's wishes -- the
    -- NameplatesEnabled idiom. Shipped default is true.
    if not MC_Config.liveSandbox("LoreNotesEnabled", false) then
        if not MC_Core.isEmpty(activeLoreBubbles) then hideAllLoreBubbles() end
        return
    end

    local localPlayer = safeGet(function() return getPlayer() end, nil)
    if not localPlayer then
        hideAllLoreBubbles()
        return
    end

    ticksSinceScan = ticksSinceScan + 1
    if ticksSinceScan >= SCAN_INTERVAL_TICKS then
        ticksSinceScan = 0
        scanForNotes(localPlayer)
    end

    updateFades(dtMs,
        safeGet(function() return localPlayer:getX() end, nil),
        safeGet(function() return localPlayer:getY() end, nil))
end

-- PZ's event dispatch aborts the remaining handlers when one throws, so an
-- unguarded error here would starve every mod registered after us on the
-- shared OnTick (see MC_Input's identical guard). MC_Incident rate-limits
-- the report itself.
local function OnTick()
    local ok = safeExec(OnTickBody)
    if not ok then
        MC_Incident.report("LORENOTE_TICK_FAILED", "lore-note tick errored")
    end
end

-- INITIALIZATION

safeExec(function() Events.OnTick.Add(OnTick) end)

dbg("=== MC_LoreNotes module loaded (ground notes float their text) ===")

return MC_LoreNotes
