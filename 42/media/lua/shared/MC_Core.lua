--[[
================================================================================
    MongooseChat - Core Module
    
    Single source of truth for version, debug configuration, and shared
    utilities used across client/server/shared modules.
    
    ARCHITECTURE NOTE:
    This module is loaded by require() before any other MC_* module.
    All cross-cutting concerns live here to avoid duplication.
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = {}

-- VERSION
-- CANONICAL source of truth for MongooseChat's version.
-- At release time, propagate this value to:
--   - mod.info (modversion line)
--   - 42/mod.info (modversion line -- Build 42 manifest; easy to miss)
--   - README.md (Version: line)
--   - CHANGELOG.md (close [Unreleased] and tag with the new version)

MC_Core.VERSION = "0.10.8"
MC_Core.VERSION_NAME = "Rhyngwyneb"
MC_Core.BUILD_DATE = "2026-08-31"

-- DEBUG CONFIGURATION

-- Master debug toggle. Off for releases; on for development sessions only.
-- When this is true, per-module flags in DEBUG_MODULES are consulted; when
-- false, all dbg() calls short-circuit at the top of MC_Core.debugger.
MC_Core.DEBUG = false

-- Per-module debug flags (only checked if DEBUG is true).
--
-- Registration contract: every MC_Core.debugger("X") caller needs its "X" key
-- present here, or dbg() is a silent, permanent no-op for that module no
-- matter what DEBUG is set to. Either add the key here when a module starts
-- calling MC_Core.debugger(), or have the module self-register at load time
-- the way modules with an optional debug key do at their own top: guard the
-- default immediately after the require block so no sibling owns shared state.
MC_Core.DEBUG_MODULES = {
    CONFIG    = true,  -- MC_Config.lua
    RADIO     = true,  -- MC_Radio.lua
    SERVER    = true,  -- MC_Server.lua
    CLIENT    = true,  -- MC_Client.lua
    BUBBLE    = true,  -- MC_Bubble.lua
    PANEL     = true,  -- MC_ChatPanel.lua
    INPUT     = true,  -- MC_Input.lua
    INPUTHIST = true,  -- MC_InputHistory.lua
    TYPING    = true,  -- MC_Typing.lua
    BIO       = true,  -- MC_Bio.lua
    ANON      = true,  -- MC_Anonymity.lua
    LANG      = true,  -- MC_Lang.lua (server, language assignment + render)
    LANG_ACQ  = true,  -- MC_Acquisition.lua (per-user vocabulary exposure)
    PERSIST   = true,  -- MC_Persist.lua (A/B crash-safe save layer)
    SHEET     = true,  -- MC_CharacterSheet.lua
    CULTURAL  = true,  -- MC_Cultural.lua
    TEACHING  = true,  -- MC_Teaching.lua
    LANGADMIN = true,  -- MC_LangAdmin.lua
}

-- SERVER-INTERCEPTED SLASH COMMANDS
-- The command words MC_Server.lua's SLASH_HANDLERS answers server-side --
-- not an ordinary channel prefix. MC_Input.lua's isMCServerCommand must
-- forward exactly these, or a client never reaches the server at all
-- (vanilla silently swallows an unrecognized "/" command). Single source
-- for both sides: client and server run in separate Lua states and never
-- share memory, so this array -- not a runtime handoff -- is what actually
-- holds across that boundary. Order matches MC_Server's SLASH_HANDLER_IMPLS
-- positionally; see that table's own comment.
MC_Core.SERVER_SLASH_COMMANDS = { "/lang", "/lex", "/comp", "/forget", "/hue", "/ll" }

--[[
    Conditional debug logger
    
    Usage:
        local dbg = MC_Core.debugger("RADIO")
        dbg("found %d emitters", count)
    
    Returns a function that only prints when DEBUG is enabled for that module.
    Supports string.format style arguments.
]]
function MC_Core.debugger(moduleName)
    return function(fmt, ...)
        if not MC_Core.DEBUG then return end
        if not MC_Core.DEBUG_MODULES[moduleName] then return end
        
        local msg = fmt
        if select("#", ...) > 0 then
            msg = string.format(fmt, ...)
        end
        
        print(string.format("MongooseChat [%s v%s]: %s", 
            moduleName, MC_Core.VERSION, tostring(msg)))
    end
end

-- DISPLAY CONSTANTS
-- Named values for magic numbers used in positioning/rendering

MC_Core.Display = {
    -- Vertical offset from world position to above-head bubble anchor
    -- This accounts for character sprite height at default zoom
    BUBBLE_OFFSET_PLAYER = 160,
    
    -- Vertical offset for ground-placed objects (radios on tables, etc.)
    BUBBLE_OFFSET_GROUND = 60,
    
    -- Additional Y adjustment after zoom calculation
    BUBBLE_Y_ADJUST = 21,
    
    -- Typing indicator positioning (relative to bubble position)
    TYPING_OFFSET_Y = 27,
    TYPING_WIDTH = 20,
    TYPING_HEIGHT = 6,
}

-- COLOR CONVENTIONS
-- Named RGB triples for cross-module use. The L2 family is the v8.x
-- language-acquisition convention: SOFT_PURPLE marks acquired/comprehended
-- L2 content wherever it appears (chat bracket, /lex output, future gradient
-- render). When a partial-comprehension treatment lands in v8.5 phase 2, it
-- reuses SOFT_PURPLE at a lower alpha -- same family, less presence.

MC_Core.Colors = {
    -- L2 acquisition family -- the v8.5 four-state render palette.
    -- ACQUIRED_FRESH: honey-gold "reward" for a freshly-learned word (full
    -- alpha once familiar; 0.25-0.75 anticipation alpha while still fresh).
    -- ACQUIRED_FAMILIAR: soft purple "settled aside" for words consolidated
    -- into baseline knowledge (0.85 alpha); also /lex's Native: color.
    -- INHERITED_GREY (v8.6): desaturated purple for cultural content a
    -- non-native can see but never acquire (0.65 alpha -- less present than
    -- peak anticipation, since unreachable ranks below approaching).
    ACQUIRED_FRESH    = {225, 195, 110},  -- honey-gold reward
    ACQUIRED_FAMILIAR = {180, 160, 210},  -- soft purple aside
    INHERITED_GREY    = {165, 155, 180},  -- v8.6 cultural / inherited

    -- Inline markup colors -- single source for parseColorSegments' defaults
    -- and MC_Config.ChannelColors' emote/mood entries.
    -- Both alias MC_Theme.Markup (Chalk on Slate): one palette, audited
    -- for colour-blind separation, owned in one place.
    EMOTE_AMBER = require("MC_Theme").Markup.emote,  -- *emote* asterisks
    MOOD_PURPLE = require("MC_Theme").Markup.mood,   -- **mood** double-asterisks
}

-- True alias, not a second literal: shares ACQUIRED_FAMILIAR's actual table
-- (back-compat name for /lex's Native: line and any legacy reader).
MC_Core.Colors.SOFT_PURPLE = MC_Core.Colors.ACQUIRED_FAMILIAR

-- SHARED UTILITIES

--[[
    Find the quoted runs in a line of narration.

    A closed pair of double quotes inside /me or /do is speech: the words
    between them were said aloud, and the engine treats them as such. This is
    the mirror of the *emote* embedded in a spoken line -- there, action is
    marked inside speech; here, speech is marked inside action.

    Only a CLOSED pair holding something other than whitespace counts. A lone
    quote is ordinary punctuation, and so is an empty pair, so a half-typed
    line or a stray inch-mark can never silently become an utterance.

    @param text  The narration to scan
    @return      Ordered array of {openPos=, closePos=} byte offsets, the
                 positions of the quote characters themselves
]]
function MC_Core.findQuotedRuns(text)
    local runs = {}
    if type(text) ~= "string" then return runs end

    local pos = 1
    while true do
        local openPos = text:find('"', pos, true)
        if not openPos then break end
        local closePos = text:find('"', openPos + 1, true)
        if not closePos then break end
        if text:sub(openPos + 1, closePos - 1):find("%S") then
            runs[#runs + 1] = { openPos = openPos, closePos = closePos }
        end
        pos = closePos + 1
    end
    return runs
end

--[[
    Rewrite the words inside every quoted run of a narration line, leaving the
    narration between them untouched and the quote marks in place.

    The quote marks always survive: a listener who is owed none of the words
    still learns that something was said, which is what a watcher would see.

    @param text     The narration to rewrite
    @param rewrite  function(spokenWords) -> replacement
    @return         The rewritten line, and true if anything was spoken at all
]]
function MC_Core.mapQuotedSpeech(text, rewrite)
    if type(text) ~= "string" then return text, false end

    local runs = MC_Core.findQuotedRuns(text)
    if #runs == 0 then return text, false end

    local pieces = {}
    local pos = 1
    for _, run in ipairs(runs) do
        pieces[#pieces + 1] = text:sub(pos, run.openPos - 1)
        pieces[#pieces + 1] = '"' .. rewrite(text:sub(run.openPos + 1, run.closePos - 1)) .. '"'
        pos = run.closePos + 1
    end
    pieces[#pieces + 1] = text:sub(pos)

    return table.concat(pieces), true
end

-- Small linear lookups over the run list. A line carries a couple of quoted
-- runs at most, so scanning it beats keeping a second index in step.
local function quotedRunStartingAt(runs, pos)
    for _, run in ipairs(runs) do
        if run.openPos == pos then return run.closePos end
    end
    return nil
end

local function nextQuotedRunStart(runs, pos)
    for _, run in ipairs(runs) do
        if run.openPos >= pos then return run.openPos end
    end
    return nil
end

--[[
    Parse text into colored segments for rendering

    Supports two inline styles:
    - *single asterisks* = emote color (actions, gestures)
    - **double asterisks** = mood color (internal thoughts, observations)

    @param text           The text to parse
    @param baseColor      {r, g, b} color for non-styled text (0-255)
    @param stripAsterisks If true and text has mixed content, remove markers but keep color
    @param emoteColor     Optional override for emote color (default soft amber)
    @param moodColor      Optional override for mood color (default purple/lavender)
    @param speechColor    Optional {r, g, b}. When given, a quoted run is
                          spoken aloud and takes this color -- the narration
                          channels (/me, /do) opt in this way. The spoken
                          channels leave it nil, so a quotation inside
                          ordinary speech stays ordinary speech.

    @return segments      Array of {text=, color=} chunks
    @return isPureStyled  True if entire text is a single *emote* or **mood**

    Example:
        parseColorSegments("Hello **thinking** and *waves*", {255,255,255}, true)
        => {{text="Hello ", color={255,255,255}},
            {text="thinking", color={174,109,181}},  -- mood, asterisks stripped
            {text=" and ", color={255,255,255}},
            {text="waves", color={255,190,128}}}     -- emote, asterisks stripped
]]
function MC_Core.parseColorSegments(text, baseColor, stripAsterisks, emoteColor, moodColor, speechColor)
    local segments = {}
    emoteColor = emoteColor or MC_Core.Colors.EMOTE_AMBER
    moodColor = moodColor or MC_Core.Colors.MOOD_PURPLE

    if not text or text == "" then
        return segments, false
    end

    -- Empty unless the caller opted in, so every spoken channel scans exactly
    -- as it did before and only narration treats quotes as speech.
    local quotedRuns = speechColor and MC_Core.findQuotedRuns(text) or {}
    
    -- Check if pure styled (entire text is *something* or **something**)
    local trimmed = text:match("^%s*(.-)%s*$") or text
    local isPureEmote = trimmed:match("^%*[^*]+%*$") ~= nil
    local isPureMood = trimmed:match("^%*%*(.-)%*%*$") ~= nil and not trimmed:match("^%*%*.*%*%*.*%*%*$")
    local isPureStyled = isPureEmote or isPureMood
    
    -- Check if there's any non-styled content
    local hasNonStyled = false
    local testText = text:gsub("%*%*(.-)%*%*", ""):gsub("%*([^*]-)%*", "")
    if testText:match("%S") then hasNonStyled = true end
    
    -- Decide whether to strip asterisks
    local shouldStrip = stripAsterisks and hasNonStyled and not isPureStyled
    
    local pos = 1
    while pos <= #text do
        -- Check for double asterisk first (mood)
        if text:sub(pos, pos + 1) == "**" then
            -- Find closing **
            local searchPos = pos + 2
            local closePos = nil
            while searchPos <= #text - 1 do
                if text:sub(searchPos, searchPos + 1) == "**" then
                    closePos = searchPos
                    break
                end
                searchPos = searchPos + 1
            end
            
            if closePos then
                local content = text:sub(pos + 2, closePos - 1)
                if shouldStrip then
                    table.insert(segments, { text = content, color = moodColor })
                else
                    table.insert(segments, { text = "**" .. content .. "**", color = moodColor })
                end
                pos = closePos + 2
            else
                -- No closing ** - treat rest as normal text
                table.insert(segments, { text = text:sub(pos), color = baseColor })
                break
            end
        -- Check for single asterisk (emote)
        elseif text:sub(pos, pos) == "*" then
            -- Find closing * (but not **)
            local searchPos = pos + 1
            local closePos = nil
            while searchPos <= #text do
                if text:sub(searchPos, searchPos) == "*" then
                    -- Make sure it's not the start of **
                    if text:sub(searchPos, searchPos + 1) ~= "**" then
                        closePos = searchPos
                        break
                    else
                        -- Skip past the ** entirely
                        searchPos = searchPos + 2
                    end
                else
                    searchPos = searchPos + 1
                end
            end
            
            if closePos then
                local content = text:sub(pos + 1, closePos - 1)
                if shouldStrip then
                    table.insert(segments, { text = content, color = emoteColor })
                else
                    table.insert(segments, { text = "*" .. content .. "*", color = emoteColor })
                end
                pos = closePos + 1
            else
                -- No closing * - treat rest as normal text
                table.insert(segments, { text = text:sub(pos), color = baseColor })
                break
            end
        elseif quotedRunStartingAt(quotedRuns, pos) then
            -- Words spoken aloud inside narration. The quote marks stay in
            -- the text: they are how a reader sees that someone spoke.
            local closePos = quotedRunStartingAt(quotedRuns, pos)
            table.insert(segments, { text = text:sub(pos, closePos), color = speechColor })
            pos = closePos + 1
        else
            -- Regular text - run up to whichever marker comes first
            local nextMarker = text:find("%*", pos)
            local nextQuote = nextQuotedRunStart(quotedRuns, pos)
            if nextQuote and (not nextMarker or nextQuote < nextMarker) then
                nextMarker = nextQuote
            end

            if nextMarker then
                if nextMarker > pos then
                    table.insert(segments, { text = text:sub(pos, nextMarker - 1), color = baseColor })
                end
                pos = nextMarker
            else
                -- No more markers - rest is normal text
                if pos <= #text then
                    table.insert(segments, { text = text:sub(pos), color = baseColor })
                end
                break
            end
        end
    end
    
    return segments, isPureStyled
end

--[[
    Consolidate adjacent same-color chunks into single chunks
    
    Used after word-wrapping to minimize draw calls.
    
    @param words  Array of {text=, color=} where each is a single word
    @return       Array of {text=, color=} with adjacent same-color merged
]]
function MC_Core.consolidateChunks(words)
    if #words == 0 then 
        return {{text = "", color = {255, 255, 255}}} 
    end
    
    local chunks = {}
    local currentChunk = {text = words[1].text, color = words[1].color,
        alpha = words[1].alpha, kind = words[1].kind,
        displayName = words[1].displayName}
    
    for i = 2, #words do
        local word = words[i]
        -- Same color AND same alpha? Append to current chunk.
        -- Treat nil alpha as 1 for comparison (default render alpha).
        local sameColor = word.color[1] == currentChunk.color[1] and 
                          word.color[2] == currentChunk.color[2] and 
                          word.color[3] == currentChunk.color[3]
        local sameAlpha = (word.alpha or 1) == (currentChunk.alpha or 1)
        local sameMeaning = word.kind == currentChunk.kind
            and word.displayName == currentChunk.displayName
        if sameColor and sameAlpha and sameMeaning then
            currentChunk.text = currentChunk.text .. " " .. word.text
        else
            -- Different color or alpha - start new chunk (with leading space)
            table.insert(chunks, currentChunk)
            currentChunk = {text = " " .. word.text, color = word.color,
                alpha = word.alpha, kind = word.kind,
                displayName = word.displayName}
        end
    end
    
    table.insert(chunks, currentChunk)
    return chunks
end

--[[
    Get current time in milliseconds
    
    Wrapper around PZ's Calendar API for consistent time access.
]]
function MC_Core.getTimeMs()
    local ok, milliseconds = pcall(function()
        return Calendar.getInstance():getTimeInMillis()
    end)
    if ok and type(milliseconds) == "number"
        and milliseconds == milliseconds
        and milliseconds ~= math.huge
        and milliseconds ~= -math.huge
        and milliseconds >= 0
    then
        return milliseconds
    end

    -- Build 42.19 dedicated servers do not reliably expose the Java Calendar
    -- class to Lua. Its vanilla chat surface does expose getTimestampMs(), so
    -- retain that build's clock without weakening the 42.20 Calendar path.
    if type(getTimestampMs) == "function" then
        ok, milliseconds = pcall(getTimestampMs)
        if ok and type(milliseconds) == "number"
            and milliseconds == milliseconds
            and milliseconds ~= math.huge
            and milliseconds ~= -math.huge
            and milliseconds >= 0
        then
            return milliseconds
        end
    end

    -- Older B42 sandboxes also exposed os.time(). It is seconds rather than
    -- milliseconds and is absent in 42.20, so it is the final compatibility
    -- source rather than the primary clock.
    if os and type(os.time) == "function" then
        local seconds
        ok, seconds = pcall(os.time)
        if ok and type(seconds) == "number"
            and seconds == seconds
            and seconds ~= math.huge
            and seconds ~= -math.huge
            and seconds >= 0
        then
            return math.floor(seconds * 1000)
        end
    end

    error("runtime clock unavailable")
end

-- Keep wall-clock seconds on the same verified, cross-B42 clock cascade used
-- by getTimeMs(). Build 42.20 has Calendar but no os.time; 42.19 dedicated
-- servers may need getTimestampMs() or the older os.time surface instead.
function MC_Core.getTimeSeconds()
    local milliseconds = MC_Core.getTimeMs()
    if type(milliseconds) ~= "number"
        or milliseconds ~= milliseconds
        or milliseconds == math.huge
        or milliseconds == -math.huge
        or milliseconds < 0
    then
        error("calendar clock unavailable")
    end
    return math.floor(milliseconds / 1000)
end

--[[
    Safe wrapper for potentially failing operations
    
    @param fn       Function to call
    @param default  Value to return on error
    @return         Result of fn() or default
]]
function MC_Core.safe(fn, default)
    local ok, result = pcall(fn)
    if ok then return result end
    return default
end

--[[
    Nil-is-failure sibling of MC_Core.safe.

    MC_Core.safe treats a successful nil as a valid result and returns it
    unchanged. safeGet doesn't: a call that runs without error but hands
    back nil still falls back to `default`, same as an outright pcall
    failure. For a client UI reading engine getters, "the call errored" and
    "the call quietly returned nothing" both mean the same thing --
    nothing to show -- so callers that can't and needn't tell those apart
    get one substitution rule instead of two.

    @param fn       Function to call
    @param default  Value to return on error OR on a successful nil
    @return         Result of fn(), or default
]]
function MC_Core.safeGet(fn, default)
    local ok, result = pcall(fn)
    if ok and result ~= nil then return result end
    return default
end

--[[
    safeExec: run fn() purely for its side effect and report whether it
    succeeded. The nil-is-failure sibling of MC_Core.safe for calls with no
    meaningful return value (a sendClientCommand, an Events.*.Add). Returns
    the pcall error too, same order pcall itself uses, so a caller that
    wants to log what actually went wrong still can.

    @param fn  Function to call
    @return    ok (true/false), err (pcall's error value when ok is false)
]]
function MC_Core.safeExec(fn)
    local ok, err = pcall(fn)
    return ok, err
end

--[[
    Server-side admin gate check

    Returns true iff the player's access level reads back exactly "admin".
    Wraps the getAccessLevel() call in MC_Core.safe so a read failure
    defaults to "none" (non-admin) rather than erroring -- the same
    pcall-guarded shape every server-side admin gate re-implemented before
    this helper existed. No message sending, no other behavior -- callers
    own their own refusal text.

    @param player  IsoPlayer to check
    @return        true iff access level == "admin"
]]
function MC_Core.isAdmin(player)
    local accessLevel = MC_Core.safe(function() return player:getAccessLevel() end, "none")
    -- PZ access levels aren't reliably lowercase ("Admin" observed); normalize
    -- like MC_LangAdmin does.
    return tostring(accessLevel):lower() == "admin"
end

--[[
    Pure 2D Euclidean distance between two coordinate pairs.

    The one formula five call sites (MC_Server, MC_Anonymity, MC_Bio,
    MC_Radio x2) computed inline before this dedup. Each site keeps its OWN
    coordinate-fetch safety net (pcall / safeGet / MC_Core.safe, with
    differing nil-distance defaults) -- only the dx/dy/sqrt arithmetic
    itself is shared here.

    @param x1, y1  First point
    @param x2, y2  Second point
    @return        Straight-line distance (tiles)
]]
function MC_Core.distance2D(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    return math.sqrt(dx * dx + dy * dy)
end

--[[
    Count entries in a table (works for non-array tables)
    
    @param t  Table to count
    @return   Number of entries
]]
function MC_Core.tableSize(t)
    if not t then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

--[[
    isEmpty: test whether a table has no keys.
    
    Idiomatic Lua is `next(t) == nil`, but PZ's Kahlua VM doesn't expose the
    global `next` function -- it only exposes the iterator protocol via pairs().
    Calling `next(t)` directly results in "Object tried to call nil" because
    the `next` identifier resolves to nil in the sandbox.
    
    This helper uses a one-shot pairs() loop with an early return, giving the
    same answer as `next(t) == nil` without depending on the missing global.
    
    Cheaper than tableSize() when you only need emptiness: O(1) on non-empty,
    where tableSize is always O(n).
]]
function MC_Core.isEmpty(t)
    if not t then return true end
    for _ in pairs(t) do return false end
    return true
end

-- MODULE INFO (for debugging/about screens)

function MC_Core.getVersionString()
    return string.format("MongooseChat v%s (%s)", MC_Core.VERSION, MC_Core.VERSION_NAME)
end

function MC_Core.printBanner()
    print("================================================================================")
    print("  " .. MC_Core.getVersionString())
    print("  Build: " .. MC_Core.BUILD_DATE)
    print("  Debug: " .. (MC_Core.DEBUG and "ENABLED" or "disabled"))
    print("================================================================================")
end

return MC_Core
