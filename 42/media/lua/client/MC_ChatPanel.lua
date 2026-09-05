--[[
================================================================================
    MongooseChat - Chat Panel
    
    Custom chat display using ISPanel with direct drawText rendering.
    Pre-computes display lines and caches them per tab for performance.
    
    ARCHITECTURE:
    - Messages are added via MC_ChatPanel.addMessage(msgData)
    - Each message is immediately converted to display lines
    - Display lines are cached per tab (General, Admin)
    - Scroll offset tracked per tab
    - Rendering draws from pre-computed cache
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Config = require("MC_Config")
local MC_Bio = require("MC_Bio")
local MC_Incident = require("MC_Incident")
local MC_Theme = require("MC_Theme")
local MC_API = require("MC_API")
local MC_StringUtils = require("MC_StringUtils")

local dbg = MC_Core.debugger("PANEL")

local MC_ChatPanel = ISPanel:derive("MC_ChatPanel")

local function readable(rgb, state)
    if MC_Theme.access().highContrast and type(MC_Theme.readableColor) == "function" then
        return MC_Theme.readableColor(rgb, MC_Theme.highContrastBackground(state))
    end
    return rgb
end

local function readableAlpha(alpha)
    if type(MC_Theme.readableAlpha) == "function" then
        return MC_Theme.readableAlpha(alpha)
    end
    return alpha
end

local function gapAbove(line, lineHeight, access)
    if not line or not line.isFirstLine then return 0 end
    local gap = tonumber(access.messageGap) or 0
    if access.speakerGap and line.speakerChanged then
        gap = gap + math.floor(lineHeight / 2)
    end
    return gap
end

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function styleFallback(kind, name, fallback)
    MC_Incident.report("CHAT_STYLE_FALLBACK",
        "kind=" .. tostring(kind):gsub("[^%w_]", "_"):sub(1, 24)
            .. " key=" .. tostring(name):gsub("[^%w_]", "_"):sub(1, 32))
    return fallback
end

local function wrapWidthOrReport(width)
    if width >= 50 then return width end
    MC_Incident.report("CHAT_LAYOUT_FALLBACK",
        "computed wrap width below minimum")
    -- A narrow panel must stay narrow. Returning the old 200px fallback made
    -- the wrapper lay out text beyond the panel and the stencil then cut it.
    return math.max(1, width)
end

-- Verb framing for signed modality (spec: "signs:" not "says:"). This
-- codebase's actual display convention IS the bracketed channel tag (there
-- is no literal "says:"/"whispers:" text anywhere), so the signing verb
-- lives there: a modality case beside the per-channel tag lookup, same
-- shape as MC_Config.Radio's style-by-channel pattern. Whisper/low/yell
-- carry the channel's own size/register (small close / guarded / big
-- emphatic signing); radio never reaches here (blocked server-side).
local SIGNED_CHANNEL_TAGS = {
    whisper = "[small signing]",
    low     = "[guarded signing]",
    say     = "[signs]",
    yell    = "[big signing]",
}

-- STATE

-- Display line storage (pre-computed, per tab)
-- The 2026-07-06 DEFERRED note here (a real OOC tab needs a custom tab
-- injected into vanilla ISChat) is resolved as of the MC_ChatWindow work:
-- we own the tab strip now, so the split is ours to make and costs nothing.
--   Tab 1 = Local  -- IC speech, emotes, PMs, and system/server notices
--   Tab 2 = OOC    -- out-of-character chatter
--   Tab 3 = Radio  -- radio traffic, kept apart so it cannot bury speech
--   Tab 4 = Admin  -- vanilla passthrough, never rendered by us
-- System notices deliberately land on Local, not OOC: Local is the default
-- view, and a player must not miss the MOTD because it arrived on a tab
-- they had not clicked.
local TAB_COUNT = 4
MC_ChatPanel.TAB_COUNT = TAB_COUNT
MC_ChatPanel.TAB_LOCAL, MC_ChatPanel.TAB_OOC = 1, 2
MC_ChatPanel.TAB_RADIO, MC_ChatPanel.TAB_ADMIN = 3, 4

local displayLinesByTab = {}
local scrollOffsetByTab = {}
local messageCountByTab = {}
local rawMessagesByTab = {}
local newBoundaryByTab = {}
local scrollAnchorByTab = {}
for tid = 1, TAB_COUNT do
    displayLinesByTab[tid] = {}
    scrollOffsetByTab[tid] = 0
    messageCountByTab[tid] = 0
    rawMessagesByTab[tid] = {}
    newBoundaryByTab[tid] = nil
    scrollAnchorByTab[tid] = nil
end

local maxMessages = MC_Config.Panel.maxMessages

-- Unread counts, shown as a DIGIT on the tab, never a bare coloured dot --
-- colour must never be the only carrier of meaning (accessibility rule).
local unreadByTab = {}
for tid = 1, TAB_COUNT do unreadByTab[tid] = 0 end

-- The panel must not require MC_ChatWindow (that module already requires us).
-- The owned shell installs this tiny visibility seam instead.  Nil means
-- visible, which keeps the panel safe in server/offline harnesses.
MC_ChatPanel.windowVisibleProvider = nil

local function windowIsVisible()
    if type(MC_ChatPanel.windowVisibleProvider) ~= "function" then return true end
    local ok, visible = pcall(MC_ChatPanel.windowVisibleProvider)
    return not ok or visible ~= false
end

-- B42 TEXT RENDERING CONSTANTS
-- Based on analysis of B42 rendering pipeline constraints.
-- MeasureStringX returns "advance width" (logical), not "bounding box" (visual).
-- Glyphs can extend 3-5px past their measured width (Right Side Bearing).
local GLYPH_BUFFER = 8

-- We own the frame now (MC_ChatWindow), so the old 12px "vanilla borders
-- clip us" guess is gone: the only padding is the theme's edge.
local PARENT_BORDER_PADDING = MC_Theme.Metrics.edge

-- Scrollbar width (drawn at width-6, we give 8px clearance)
local SCROLLBAR_WIDTH = 8

-- Total safe padding from right edge
local WRAP_PADDING = SCROLLBAR_WIDTH + GLYPH_BUFFER + PARENT_BORDER_PADDING

-- Long tags/names must not exile the first body row to the far right.
-- Continuation rows return to the transcript margin and use the whole usable
-- width. Thirty percent sits in the requested 25--35% quiet range.
local function hangingLayout(panelWidth, margin, measuredPrefix)
    local usable = panelWidth - margin * 2 - WRAP_PADDING
    local indent = math.min(measuredPrefix, math.max(0, math.floor(usable * 0.30)))
    return indent, wrapWidthOrReport(usable - indent), usable
end

-- TEXT MEASUREMENT
-- WRAP_PADDING already reserves the right-side glyph buffer. Use the same
-- logical advance here that render() uses, so a real inter-word space is
-- counted once rather than once in the word and once between words.
local function safeMeasureText(font, text)
    return getTextManager():MeasureStringX(font, text .. " ")
end

-- Internal contract: shared with MC_Bubble, which wraps text with the same
-- glyph-overhang hazard and needs this exact correction, not its own copy.
MC_ChatPanel._safeMeasureText = safeMeasureText

-- Channel to tab mapping
-- TAB ROUTING
-- Maps channel names to tab indices:
--   Tab 1 = General - our panel renders this (all MC-managed channels)
--   Tab 4 = Admin   - ours since 0.10.6
--
-- Admin traffic is drawn by OUR panel now. MC_Client's addLineInChat hook
-- still lets the engine's own ChatType decide what counts as admin -- an
-- unverifiable line is suppressed, exactly as before -- but a verified one
-- is rendered here instead of being handed back to vanilla, so no vanilla
-- surface paints into the chat area on any tab.
local channelToTab = {
    -- IC channels (Tab 1)
    say = 1,
    whisper = 1,
    yell = 1,
    low = 1,
    emote = 1,
    ["do"] = 1,
    mood = 1,
    me = 1,
    pm = 1,
    general = 2,
    radio = 3,
    faction = 1,
    safehouse = 1,
    event = 1,   -- admin event narration; the server scrubs the narrator's identity
    
    -- OOC channels (Tab 2)
    ooc = 2,
    all = 2,

    -- Server messages and MOTD stay on Local (Tab 1): it is the default
    -- view, so a notice here cannot be missed behind an unclicked tab.
    system = 1,

    -- Admin (Tab 4 -- containment only, vanilla handles admin properly)
    admin = 4,
}
local RADIO_ORIGINAL_CHANNELS = {
    say = true,
    whisper = true,
    yell = true,
    low = true,
}

-- Current active tab
local currentTab = 1

-- Message ID counter
local nextMsgId = 1

-- TEXT UTILITIES

-- VANILLA CHAT PREFERENCES (0.9.8)
--
-- The panel's font and its timestamp visibility follow the player's OWN
-- vanilla chat settings (gear menu -> Font / timestamp toggle), read from
-- the live ISChat.instance fields first (they change the moment the gear
-- menu is used) with the core option accessors as the pre-instance
-- fallback. Fail-open: an unreadable preference keeps the current
-- behaviour (medium font, timestamps shown) with one incident.

local panelFont = nil            -- resolved UIFont; nil until first apply
local panelShowTimestamp = true

local FONT_BY_NAME = nil
local function fontByName(name)
    if not FONT_BY_NAME then
        FONT_BY_NAME = {}
        if UIFont then
            FONT_BY_NAME.small = UIFont.Small
            FONT_BY_NAME.medium = UIFont.Medium
            FONT_BY_NAME.large = UIFont.Large
        end
    end
    return FONT_BY_NAME[name]
end

local function readVanillaChatPrefs()
    local prefs = { font = "medium", showTimestamp = true }  -- fail-open
    local ok = pcall(function()
        local inst = ISChat and ISChat.instance
        if inst and type(inst.chatFont) == "string" then
            prefs.font = inst.chatFont
        elseif getCore and getCore().getOptionChatFontSize then
            prefs.font = getCore():getOptionChatFontSize()
        end
        if inst and type(inst.showTimestamp) == "boolean" then
            prefs.showTimestamp = inst.showTimestamp
        elseif getCore and getCore().isOptionShowChatTimestamp then
            prefs.showTimestamp = getCore():isOptionShowChatTimestamp()
        end
    end)
    if not ok then
        MC_Incident.report("VANILLA_CHAT_PREFS_UNREADABLE",
            "font/timestamp preference read failed; defaults kept")
    end
    if type(prefs.font) ~= "string" or not fontByName(prefs.font) then
        prefs.font = "medium"
    end
    if type(prefs.showTimestamp) ~= "boolean" then
        prefs.showTimestamp = true
    end
    -- The player's own Timestamps setting (On/Off) beats the game's; nil
    -- means Follow game.
    local override = MC_Theme.access().timestamps
    if type(override) == "boolean" then prefs.showTimestamp = override end
    return prefs
end

-- Timestamps carry the VIEWER's wall clock. The transported timestamp is
-- absolute epoch seconds (MC_Core.getTimeSeconds, server-stamped), so the
-- zone belongs to whoever is reading -- Calendar.getInstance() runs in the
-- JVM's default (local) zone. Kahlua's os.date formats in a fixed zone
-- (the old bug: every player saw the server's clock); it survives only as
-- the fallback when Calendar is unavailable. No readable clock at all
-- means no stamp, never a wrong one.
local function formatTime(timestamp)
    if not panelShowTimestamp then return "" end
    local ok, str = pcall(function()
        local cal = Calendar.getInstance()
        cal:setTimeInMillis(timestamp * 1000)
        return string.format("[%02d:%02d] ",
            cal:get(Calendar.HOUR_OF_DAY), cal:get(Calendar.MINUTE))
    end)
    if ok and type(str) == "string" then return str end
    local okDate, fallback = pcall(os.date, MC_Config.Panel.timestampFormat, timestamp)
    if okDate and type(fallback) == "string" then return fallback .. " " end
    MC_Incident.report("CHAT_TIMESTAMP_CLOCK_UNAVAILABLE",
        "no readable clock for chat timestamps; stamp omitted")
    return ""
end

--[[
    Word wrap text to fit within maxWidth (single color version)
    @param text      Text to wrap
    @param font      UIFont to measure with
    @param maxWidth  Maximum line width in pixels
    @return Array of line strings
]]
local function wrapText(text, font, maxWidth, continuationWidth)
    if not text or text == "" then return {""} end
    maxWidth = math.max(1, maxWidth)
    continuationWidth = math.max(1, continuationWidth or maxWidth)
    
    local lines = {}
    local currentLine = ""
    
    for token in text:gmatch("%S+") do
        local lineLimit = #lines == 0 and maxWidth or continuationWidth
        local testLine = currentLine == "" and token
            or (currentLine .. " " .. token)
        if safeMeasureText(font, testLine) < lineLimit then
            currentLine = testLine
        else
            if currentLine ~= "" then
                table.insert(lines, currentLine)
                currentLine = ""
            end

            -- Split a single unbroken token against each row's live limit.
            -- Every part owns its row, so no separator byte is invented inside
            -- a command, URL, or pasted run when the next row is wider.
            local part = ""
            for ch in MC_StringUtils.utf8chars(token) do
                local candidate = part .. ch
                lineLimit = #lines == 0 and maxWidth or continuationWidth
                if part ~= "" and safeMeasureText(font, candidate) >= lineLimit then
                    table.insert(lines, part)
                    part = ch
                else
                    part = candidate
                end
            end
            currentLine = part
        end
    end
    
    if currentLine ~= "" then
        table.insert(lines, currentLine)
    end
    
    if #lines == 0 then
        table.insert(lines, "")
    end

    return lines
end

-- Internal contract: shared with MC_Bubble (single-color emote/do bubbles)
-- and MC_CharacterSheet (per-paragraph description wrapping) -- this is the
-- one word-wrap loop; each caller supplies its own font/maxWidth, and
-- CharacterSheet layers its own paragraph split on top.
MC_ChatPanel._wrapWords = wrapText

--[[
    Word wrap with color segments preserved
    @param segments  Array of {text, color} from MC_Core.parseColorSegments
    @param font      UIFont to measure with
    @param maxWidth  Maximum line width in pixels
    @return Array of {chunks = [{text, color}, ...]} per line
]]
local function wrapTextWithColors(segments, font, maxWidth, continuationWidth)
    if not segments or #segments == 0 then 
        return {{chunks = {{text = "", color = {255,255,255}}}}}
    end
    maxWidth = math.max(1, maxWidth)
    continuationWidth = math.max(1, continuationWidth or maxWidth)
    
    local textManager = getTextManager()
    
    -- Flatten segments into words with color tags. Long tokens are split only
    -- after the live row width is known below, so their bytes stay contiguous.
    local words = {}
    for _, seg in ipairs(segments) do
        for token in seg.text:gmatch("%S+") do
            table.insert(words, {text = token, color = seg.color,
                alpha = seg.alpha, kind = seg.kind,
                displayName = seg.displayName})
        end
    end
    
    if #words == 0 then
        return {{chunks = {{text = "", color = segments[1] and segments[1].color or {255,255,255}}}}}
    end
    
    local lines = {}
    local currentLineWords = {}
    local spaceWidth = textManager:MeasureStringX(font, " ")

    -- Measure the chunks exactly as render() will paint them. Separate colour
    -- runs gain a leading space during consolidation, and font shaping can
    -- make that wider than measuring a bare word plus a stand-alone space.
    local function paintedWidth(lineWords)
        local width = 0
        for _, chunk in ipairs(MC_Core.consolidateChunks(lineWords)) do
            width = width + textManager:MeasureStringX(font, chunk.text)
        end
        return width + spaceWidth
    end
    
    for _, word in ipairs(words) do
        local candidateWords = {}
        for i, existing in ipairs(currentLineWords) do
            candidateWords[i] = existing
        end
        table.insert(candidateWords, word)
        local lineLimit = #lines == 0 and maxWidth or continuationWidth
        local pastLimit = paintedWidth(candidateWords) >= lineLimit
        if not pastLimit then
            table.insert(currentLineWords, word)
        else
            if #currentLineWords > 0 then
                table.insert(lines, {chunks = MC_Core.consolidateChunks(currentLineWords)})
                currentLineWords = {}
            end

            local part = ""
            for ch in MC_StringUtils.utf8chars(word.text) do
                local candidate = part .. ch
                local fragment = {text=candidate, color=word.color,
                    alpha=word.alpha, kind=word.kind,
                    displayName=word.displayName}
                lineLimit = #lines == 0 and maxWidth or continuationWidth
                if part ~= "" and paintedWidth({fragment}) >= lineLimit then
                    table.insert(lines, {chunks=MC_Core.consolidateChunks({{
                        text=part, color=word.color, alpha=word.alpha,
                        kind=word.kind, displayName=word.displayName}})})
                    part = ch
                else
                    part = candidate
                end
            end
            table.insert(currentLineWords, {text=part, color=word.color,
                alpha=word.alpha, kind=word.kind,
                displayName=word.displayName})
        end
    end
    
    -- Don't forget last line
    if #currentLineWords > 0 then
        table.insert(lines, {chunks = MC_Core.consolidateChunks(currentLineWords)})
    end
    
    if #lines == 0 then
        table.insert(lines, {chunks = {{text = "", color = {255,255,255}}}})
    end
    
    return lines
end

-- Internal contract: shared with MC_Bubble (multi-segment colored speech/do
-- bubbles need the exact same wrap-then-consolidate behavior, not their own
-- copy) -- this is the one color-segment word-wrap loop, same pattern as
-- the _wrapWords exposure above.
MC_ChatPanel._wrapTextWithColors = wrapTextWithColors

-- DISPLAY LINE COMPUTATION

--[[
    Shared shape for the three narration-style channels below (emote, do,
    mood): a single wrapped block with no visible tag or name (isEmote
    blanks both at render) -- only the text each channel builds differs.
    NOT used for event/dice-roll/standard: each of those carries a real
    difference this shape doesn't fit (event's extra tag-width term,
    dice-roll's colored chunks, standard's real name + chunks).
]]
local function narrationLines(text, msg, tagColor, font, textManager, panelWidth, margin, segments)
    local timeStr = formatTime(msg.timestamp)

    local measuredPrefixWidth = textManager:MeasureStringX(font, timeStr)
    local prefixWidth = measuredPrefixWidth
    local availableWidth, usableWidth
    prefixWidth, availableWidth, usableWidth = hangingLayout(
        panelWidth, margin, prefixWidth)

    -- Narration is one colour, and stays a single flat string, unless it
    -- carries spoken words: `segments` is supplied only when a quoted run is
    -- present, and then the line is drawn chunk by chunk so the speech shows
    -- in the speaking colour.
    local coloredLines = segments and wrapTextWithColors(
        segments, font, availableWidth, usableWidth) or nil
    local plainLines = (not coloredLines) and wrapText(
        text, font, availableWidth, usableWidth) or nil

    local firstBodyWidth = 0
    if coloredLines and coloredLines[1] then
        for _, chunk in ipairs(coloredLines[1].chunks or {}) do
            firstBodyWidth = firstBodyWidth
                + textManager:MeasureStringX(font, chunk.text)
        end
    elseif plainLines and plainLines[1] then
        firstBodyWidth = textManager:MeasureStringX(font, plainLines[1])
    end
    local displayLines = {}
    local detachedBody = measuredPrefixWidth > prefixWidth
        and measuredPrefixWidth + firstBodyWidth > usableWidth
    if detachedBody then
        coloredLines = segments and wrapTextWithColors(segments, font, usableWidth) or nil
        plainLines = (not coloredLines) and wrapText(text, font, usableWidth) or nil
        local headerLines = wrapTextWithColors({{text=timeStr, color={128,128,128},
            alpha=0.8, kind="timestamp"}}, font, usableWidth)
        for headerIdx, headerLine in ipairs(headerLines) do
            table.insert(displayLines, {
                isFirstLine = (headerIdx == 1), isHeaderLine = true,
                chunks = headerLine.chunks, tagColor = tagColor,
                tag = "", timeStr = "", nameStr = "", prefixWidth = 0,
                playerColor = msg.playerColor, msgId = msg.msgId,
            })
        end
    end
    for lineIdx = 1, (coloredLines and #coloredLines or #plainLines) do
        table.insert(displayLines, {
            isFirstLine = (not detachedBody and lineIdx == 1),
            isEmote = true,
            text = plainLines and plainLines[lineIdx] or nil,
            chunks = coloredLines and coloredLines[lineIdx].chunks or nil,
            tagColor = tagColor,
            tag = "",
            timeStr = timeStr,
            nameStr = "",
            prefixWidth = (detachedBody or lineIdx > 1) and 0 or prefixWidth,
            playerColor = msg.playerColor,
            msgId = msg.msgId,
        })
    end

    return displayLines
end

-- Words spoken aloud inside narration take the say channel's own colour, so
-- the same words read the same whether they were typed into /say or quoted
-- inside a /me.
local function speechColorForNarration()
    return MC_Config.ChannelColors.say
        or styleFallback("color", "say", {255, 255, 255})
end

local function narrationSegments(prefix, body, suffix, tagColor, speechColor,
                                  prefixSegments)
    if #MC_Core.findQuotedRuns(body) == 0 and not prefixSegments then return nil end

    local segments = {}
    if prefixSegments then
        for _, segment in ipairs(prefixSegments) do
            table.insert(segments, segment)
        end
    elseif prefix ~= "" then
        table.insert(segments, { text = prefix, color = tagColor })
    end
    for _, segment in ipairs(MC_Core.parseColorSegments(
        body, tagColor, false, tagColor, tagColor, speechColor))
    do
        table.insert(segments, segment)
    end
    if suffix ~= "" then
        table.insert(segments, { text = suffix, color = tagColor })
    end
    return segments
end

--[[
    Compute display lines for a single message
    Handles different formats: standard, emote, do, mood, radio
]]
local function computeMessageLines(msg, panelWidth, margin)
    local textManager = getTextManager()
    local font = panelFont or UIFont.Medium
    
    local bodyColor = MC_Config.ChannelColors[msg.channel]
        or styleFallback("color", msg.channel, {200, 200, 200})
    local tagColor = MC_Theme.tagChannel(msg.channel)
    local tag = MC_Config.ChannelTags[msg.channel]
        or styleFallback("tag", msg.channel, "[" .. msg.channel .. "]")

    -- Signed modality: swap the tag, never the body --
    -- so a user *emote* inside a signed message round-trips untouched.
    if msg.modality == "signed" then
        tag = SIGNED_CHANNEL_TAGS[msg.channel] or tag
    end

    -- Radio messages: show frequency + signal word + original volume tag.
    -- The signal WORD is the accessibility cue: static pops (*fzzzt*) are
    -- a texture some readers cannot parse, and colour must never be the
    -- only carrier, so the tag itself says clear / weak / broken.
    if msg.channel == "radio" and msg.frequency then
        local mhz = msg.frequency / 1000
        local volumeTag = ""
        if msg.originalChannel then
            volumeTag = " " .. (MC_Config.ChannelTags[msg.originalChannel]
                or styleFallback("tag", msg.originalChannel,
                    "[" .. msg.originalChannel .. "]"))
        end
        local signal = MC_ChatPanel._radioSignalWord(msg)
        tag = string.format("[%.1fMHz %s]%s", mhz, signal, volumeTag)
        tagColor = MC_Theme.tagChannel("radio")
    end
    
    -- EMOTE FORMAT: *CharacterName action*
    if msg.channel == "emote" then
        local emoteText = "*" .. msg.characterName .. " " .. msg.message .. "*"
        local segments = narrationSegments("", msg.message, "*", tagColor,
            speechColorForNarration(), {
                { text = "*", color = tagColor },
                { text = msg.characterName, color = msg.playerColor or tagColor,
                    kind = "name", displayName = msg.characterName },
                { text = " ", color = tagColor },
            })
        return narrationLines(emoteText, msg, tagColor, font, textManager,
            panelWidth, margin, segments)
    end

    -- DO FORMAT: Environment narration
    -- Leads with a "(CharacterName) " tag in a slightly brighter lavender
    -- than the narration body, so a room-echo of environment narration
    -- still shows who spoke it. Only when characterName is a real,
    -- non-empty string -- an /event-scrubbed or otherwise legacy message
    -- (characterName nil/"") still renders with no tag, exactly as before.
    if msg.channel == "do" then
        local hasName = type(msg.characterName) == "string"
            and msg.characterName ~= ""
        local namePrefix = hasName and ("(" .. msg.characterName .. ") ") or ""
        local bodySegments = narrationSegments("", msg.message, "", tagColor,
            speechColorForNarration())

        local segments = bodySegments
        if hasName then
            segments = { { text = namePrefix, color = msg.playerColor or tagColor,
                kind = "name", displayName = msg.characterName } }
            if bodySegments then
                for _, segment in ipairs(bodySegments) do
                    table.insert(segments, segment)
                end
            else
                table.insert(segments, { text = msg.message, color = tagColor })
            end
        end

        return narrationLines(namePrefix .. msg.message, msg, tagColor, font,
            textManager, panelWidth, margin, segments)
    end

    -- EVENT FORMAT: Admin event narration (v8.16.2)
    -- Styled like /do -- no speaker, no colon -- but keeping the [Event]
    -- tag out front. The server scrubs the narrator's identity (name,
    -- color, coords), so only the tag and the words remain.
    if msg.channel == "event" then
        local timeStr = formatTime(msg.timestamp)

        local measuredPrefixWidth = textManager:MeasureStringX(font, timeStr)
            + textManager:MeasureStringX(font, tag .. " ")
        local prefixWidth = measuredPrefixWidth
        local availableWidth
        local usableWidth
        prefixWidth, availableWidth, usableWidth = hangingLayout(
            panelWidth, margin, prefixWidth)

        local wrappedLines = wrapText(msg.message, font, availableWidth, usableWidth)

        local firstBodyWidth = wrappedLines[1]
            and textManager:MeasureStringX(font, wrappedLines[1]) or 0
        local displayLines = {}
        local detachedBody = measuredPrefixWidth > prefixWidth
            and measuredPrefixWidth + firstBodyWidth > usableWidth
        if detachedBody then
            wrappedLines = wrapText(msg.message, font, usableWidth)
            local headerSegments = {}
            if timeStr ~= "" then
                table.insert(headerSegments, {text=timeStr, color={128,128,128},
                    alpha=0.8, kind="timestamp"})
            end
            table.insert(headerSegments, {text=tag .. " ", color=tagColor,
                kind="tag"})
            local headerLines = wrapTextWithColors(headerSegments, font, usableWidth)
            for headerIdx, headerLine in ipairs(headerLines) do
                table.insert(displayLines, {
                    isFirstLine = (headerIdx == 1), isHeaderLine = true,
                    chunks = headerLine.chunks, tagColor = tagColor,
                    tag = "", timeStr = "", nameStr = "", prefixWidth = 0,
                    playerColor = msg.playerColor, msgId = msg.msgId,
                })
            end
        end
        for lineIdx, lineText in ipairs(wrappedLines) do
            table.insert(displayLines, {
                isFirstLine = (not detachedBody and lineIdx == 1),
                text = lineText,
                tagColor = tagColor,
                tag = tag,
                timeStr = timeStr,
                nameStr = "",
                prefixWidth = (detachedBody or lineIdx > 1) and 0 or prefixWidth,
                playerColor = msg.playerColor,
                msgId = msg.msgId,
            })
        end

        return displayLines
    end

    -- MOOD FORMAT: Internal monologue
    -- A quoted run inside /you is the character's own inner voice being
    -- singled out, not speech aloud, so it takes the thought colour rather
    -- than the say-channel speaking colour narration otherwise uses.
    if msg.channel == "mood" then
        local moodText = "You " .. msg.message
        local thoughtColor = MC_Config.ChannelColors.thought
            or styleFallback("color", "thought", {185, 205, 245})
        local segments = narrationSegments("You ", msg.message, "", tagColor,
            thoughtColor)
        return narrationLines(moodText, msg, tagColor, font, textManager,
            panelWidth, margin, segments)
    end
    
    -- DICE ROLL FORMAT: Colorful roll result
    -- Format: "4d10+4: [3, 7, 2, 9] + 4 = 25"
    if msg.isRoll then
        local timeStr = formatTime(msg.timestamp)
        local nameStr = msg.characterName .. " "
        
        -- Parse the roll result string to colorize parts
        -- Expected: "XdY+Z: [rolls] + mod = total" or "XdY+Z: [rolls] + mod = total - NAT XX!"
        local mainPart, critIndicator = msg.message:match("^(.+)%s*%-%s*(NAT%s*%d+!)$")
        if not mainPart then
            mainPart = msg.message
            critIndicator = nil
        end
        
        local diceNotation, rollsStr, modPart, renderedTotal =
            mainPart:match("^([^:]+):%s*(%[[^%]]+%])(.-)=%s*([+-]?%d+)%s*$")
        local parsedTotal = tonumber(renderedTotal)
        -- rollTotal is authoritative.  The text total must agree with it
        -- before we split the message into trusted coloured fields.
        local total = msg.rollTotal

        -- Colors for different parts
        local rollsColor = {150, 220, 255}     -- Light blue for individual rolls
        local totalColor = {255, 215, 0}       -- Gold for total
        local modColor = {180, 180, 180}       -- Gray for modifier
        local diceColor = {200, 160, 255}      -- Purple for dice notation
        local textColor = tagColor             -- OOC tag color for "rolls"
        local critColor = {50, 255, 50}        -- Bright green for NAT 20
        local fumbleColor = {255, 80, 80}      -- Bright red for NAT 1
        
        -- Override total color based on crit/fumble
        if msg.isCrit then
            totalColor = critColor
        elseif msg.isFumble then
            totalColor = fumbleColor
        end
        
        local chunks = {}
        
        if diceNotation and rollsStr and type(total) == "number"
                and parsedTotal == total then
            -- "rolls " text
            table.insert(chunks, {text = "rolls ", color = textColor})
            -- Dice notation (4d10+4)
            table.insert(chunks, {text = diceNotation .. ": ", color = diceColor})
            -- Individual rolls [3, 7, 2, 9]
            table.insert(chunks, {text = rollsStr, color = rollsColor})
            -- Modifier part (+ 4 or - 2)
            if modPart and modPart ~= "" then
                table.insert(chunks, {text = modPart, color = modColor})
            end
            -- = and total
            table.insert(chunks, {text = "= ", color = textColor})
            table.insert(chunks, {text = tostring(total), color = totalColor})
            
            -- Crit/fumble indicator
            if critIndicator then
                local indicatorColor = msg.isCrit and critColor or fumbleColor
                table.insert(chunks, {text = " - " .. critIndicator, color = indicatorColor})
            end
        else
            -- Fallback: just use text color
            MC_Incident.report("ROLL_RENDER_FALLBACK",
                "structured roll fields unavailable")
            table.insert(chunks, {text = "rolls " .. msg.message, color = textColor})
        end
        
        -- Calculate prefix width
        local measuredPrefixWidth = textManager:MeasureStringX(font, timeStr)
            + textManager:MeasureStringX(font, tag .. " ")
            + textManager:MeasureStringX(font, nameStr)

        local prefixWidth = measuredPrefixWidth
        local availableWidth, usableWidth
        prefixWidth, availableWidth, usableWidth = hangingLayout(
            panelWidth, margin, prefixWidth)
        
        -- Wrap with color preservation
        local wrappedLines = wrapTextWithColors(
            chunks, font, availableWidth, usableWidth)
        
        local displayLines = {}
        local firstBodyWidth = 0
        if wrappedLines[1] and wrappedLines[1].chunks then
            for _, chunk in ipairs(wrappedLines[1].chunks) do
                firstBodyWidth = firstBodyWidth
                    + textManager:MeasureStringX(font, chunk.text)
            end
        end
        local detachedBody = measuredPrefixWidth > prefixWidth
            and measuredPrefixWidth + firstBodyWidth > usableWidth
        if detachedBody then
            wrappedLines = wrapTextWithColors(chunks, font, usableWidth)
            local headerSegments = {}
            if timeStr ~= "" then
                table.insert(headerSegments, {text=timeStr, color={128,128,128},
                    alpha=0.8, kind="timestamp"})
            end
            table.insert(headerSegments, {text=tag .. " ", color=tagColor,
                kind="tag"})
            table.insert(headerSegments, {text=nameStr,
                color=msg.playerColor or tagColor, kind="name",
                displayName=msg.characterName})
            local headerLines = wrapTextWithColors(headerSegments, font, usableWidth)
            for headerIdx, headerLine in ipairs(headerLines) do
                table.insert(displayLines, {
                    isFirstLine = (headerIdx == 1), isHeaderLine = true,
                    chunks = headerLine.chunks, tagColor = tagColor,
                    tag = "", timeStr = "", nameStr = "", prefixWidth = 0,
                    playerColor = msg.playerColor, msgId = msg.msgId,
                    isRoll = true,
                })
            end
        end
        for lineIdx, lineData in ipairs(wrappedLines) do
            table.insert(displayLines, {
                isFirstLine = (not detachedBody and lineIdx == 1),
                chunks = lineData.chunks,
                tagColor = tagColor,
                tag = tag,
                timeStr = timeStr,
                nameStr = nameStr,
                prefixWidth = (detachedBody or lineIdx > 1) and 0 or prefixWidth,
                playerColor = msg.playerColor,
                msgId = msg.msgId,
                isRoll = true,
            })
        end
        
        return displayLines
    end
    
    -- STANDARD FORMAT: [tag] Name: message
    local timeStr = formatTime(msg.timestamp)
    -- /event narration arrives identity-scrubbed (characterName == "");
    -- an empty name must not leave an orphaned ": " on the line.
    local nameStr = ""
    if msg.characterName and msg.characterName ~= "" then
        nameStr = msg.characterName .. ": "
    end
    
    -- Speech channels get smart asterisk handling
    local speechChannels = {say = true, yell = true, low = true, whisper = true}
    local isSpeech = speechChannels[msg.channel]
    
    -- Parse message into colored segments.
    --
    -- Two paths:
    --   v8.5+ chunks path: server provided pre-segmented render chunks (e.g.
    --   for L2-acquired words in soft purple). Walk them; for each chunk
    --   resolve nil-color to channel tagColor, then run parseColorSegments
    --   on the chunk's text to handle any embedded *emote* / **mood** markup
    --   within. Concatenate the resulting sub-segments into a final segments
    --   list. Pure-emote detection is skipped on this path -- a message with
    --   L2 substitutions isn't a pure emote.
    --
    --   Flat-string path (v8.4 behaviour, still used for English / radio /
    --   any non-L2 speech): single parseColorSegments call on msg.message.
    local emoteColor = MC_Config.ChannelColors.emote
        or styleFallback("color", "emote", {255, 190, 128})
    local moodColor = MC_Config.ChannelColors.mood
        or styleFallback("color", "mood", {180, 180, 200})
    local segments, isPureEmote

    if msg.chunks and #msg.chunks > 0 then
        segments = {}
        for _, chunk in ipairs(msg.chunks) do
            local baseColor = chunk.color or bodyColor
            local subSegments = MC_Core.parseColorSegments(
                chunk.text, baseColor, isSpeech, emoteColor, moodColor)
            for _, sub in ipairs(subSegments) do
                -- Carry the chunk's alpha through to sub-segments so phase 2's
                -- partial-state whispered chunks render correctly even when
                -- they contain (highly unlikely but possible) asterisk markup.
                if chunk.alpha then sub.alpha = chunk.alpha end
                table.insert(segments, sub)
            end
        end
        isPureEmote = false
    else
        segments, isPureEmote = MC_Core.parseColorSegments(
            msg.message, bodyColor, isSpeech, emoteColor, moodColor)
    end
    
    -- Pure emote in speech channel -> convert to emote format
    if isSpeech and isPureEmote then
        local emoteContent = msg.message:match("^%s*%*(.-)%*%s*$") or msg.message
        local emoteText = "*" .. msg.characterName .. " " .. emoteContent .. "*"
        return narrationLines(emoteText, msg, emoteColor, font, textManager,
            panelWidth, margin, nil)
    end
    
    -- Calculate prefix width (piece by piece to match render path)
    local measuredPrefixWidth = textManager:MeasureStringX(font, timeStr)
        + textManager:MeasureStringX(font, tag .. " ")
        + textManager:MeasureStringX(font, nameStr)
    local prefixWidth = measuredPrefixWidth
    
    local availableWidth, usableWidth
    prefixWidth, availableWidth, usableWidth = hangingLayout(
        panelWidth, margin, prefixWidth)
    
    -- Wrap with color preservation
    local wrappedLines = wrapTextWithColors(
        segments, font, availableWidth, usableWidth)
    
    -- Build display line objects
    local displayLines = {}
    -- If an unusually long standard prefix is wider than the hanging indent,
    -- give its header the first row and start the body cleanly below it.  The
    -- alternative is to draw body text through the visible prefix even though
    -- wrapping correctly reserved the capped continuation width.
    local firstBodyWidth = 0
    if wrappedLines[1] and wrappedLines[1].chunks then
        for _, chunk in ipairs(wrappedLines[1].chunks) do
            firstBodyWidth = firstBodyWidth
                + textManager:MeasureStringX(font, chunk.text)
        end
    end
    if measuredPrefixWidth > prefixWidth
            and measuredPrefixWidth + firstBodyWidth > usableWidth then
        -- The header owns its rows, so the body has the full transcript width.
        wrappedLines = wrapTextWithColors(segments, font, usableWidth)
        local headerSegments = {}
        if timeStr ~= "" then
            table.insert(headerSegments, {text=timeStr, color={128,128,128},
                alpha=0.8, kind="timestamp"})
        end
        table.insert(headerSegments, {text=tag .. " ", color=tagColor,
            kind="tag"})
        if nameStr ~= "" then
            table.insert(headerSegments, {text=nameStr, color=msg.playerColor,
                kind="name", displayName=msg.characterName})
        end
        local headerLines = wrapTextWithColors(headerSegments, font, usableWidth)
        for headerIdx, headerLine in ipairs(headerLines) do
            table.insert(displayLines, {
            isFirstLine = (headerIdx == 1),
            isHeaderLine = true,
            chunks = headerLine.chunks,
            tagColor = tagColor,
            tag = "", timeStr = "", nameStr = "", prefixWidth = 0,
            playerColor = msg.playerColor,
            msgId = msg.msgId,
            hoverName = msg.hoverName,
        })
        end
    end
    local detachedBody = #displayLines > 0
    for lineIdx, lineData in ipairs(wrappedLines) do
        table.insert(displayLines, {
            isFirstLine = (not detachedBody and lineIdx == 1),
            chunks = lineData.chunks,
            tagColor = tagColor,
            tag = tag,
            timeStr = timeStr,
            nameStr = nameStr,
            prefixWidth = (detachedBody or lineIdx > 1) and 0 or prefixWidth,
            playerColor = msg.playerColor,
            msgId = msg.msgId,
            hoverName = msg.channel ~= "admin" and msg.characterName
                or msg.hoverName,
        })
    end
    
    return displayLines
end

MC_ChatPanel._computeMessageLines = computeMessageLines

MC_ChatPanel._getDisplayLines = function(tabId)
    return displayLinesByTab[tabId or 1]
end
MC_ChatPanel._getRawMessagesForTest = function(tabId)
    return rawMessagesByTab[tabId or 1]
end
MC_ChatPanel._getPolishState = function(tabId)
    local tid = tabId or currentTab
    return { scrollOffset = scrollOffsetByTab[tid] or 0,
        newBoundary = newBoundaryByTab[tid] }
end
MC_ChatPanel._setScrollOffsetForTest = function(tabId, value)
    if type(tabId) == "number" and type(value) == "number" then
        scrollOffsetByTab[tabId] = math.max(0, value)
    end
end

--[[
    clear / weak / broken, from how much of a radio line the static ate.

    Chunked lines carry MC_Radio's explicit isGeneratedStatic flag on any
    chunk whose every real word became a pop. Flat lines are scanned for
    the pop shape (*word*) instead. Bookend pops count too: a line that is
    all pops is broken, a line with some is weak, a clean line is clear.
]]
local STATIC_TOKEN = "^%*[%a]+%*$"

function MC_ChatPanel._radioSignalWord(msg)
    local total, lost = 0, 0
    if type(msg.chunks) == "table" and #msg.chunks > 0 then
        for _, chunk in ipairs(msg.chunks) do
            local text = tostring(chunk.text or "")
            for word in text:gmatch("%S+") do
                total = total + 1
                if chunk.isGeneratedStatic or word:match(STATIC_TOKEN) then
                    lost = lost + 1
                end
            end
        end
    else
        for word in tostring(msg.message or ""):gmatch("%S+") do
            total = total + 1
            if word:match(STATIC_TOKEN) then lost = lost + 1 end
        end
    end
    if total == 0 or lost == 0 then return "clear" end
    if lost >= total or (lost / total) >= 0.6 then return "broken" end
    return "weak"
end

-- The local player's account name, read once it exists. Nil until then,
-- which simply means "not provably mine" and no echo.
local function localUsername()
    local ok, name = pcall(function()
        local p = getPlayer and getPlayer()
        return p and p:getUsername()
    end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

function MC_ChatPanel._isOwnMessage(msg)
    local me = localUsername()
    return me ~= nil and msg.username == me
end

-- PUBLIC INTERFACE

function MC_ChatPanel.setCurrentTab(tabId)
    if type(tabId) == "number" and tabId >= 1 and tabId <= TAB_COUNT then
        currentTab = tabId
        -- A hidden shell is not being looked at. Keep its badge until the
        -- shell opens, even when this is the selected tab.
        if windowIsVisible() then unreadByTab[tabId] = 0 end
        if MC_ChatPanel.instance then
            scrollOffsetByTab[tabId] = math.max(0, math.min(
                scrollOffsetByTab[tabId] or 0,
                MC_ChatPanel.instance:getMaxScroll()))
            if scrollOffsetByTab[tabId] == 0 then newBoundaryByTab[tabId] = nil end
        end
    end
end

-- Unread accessors for the tab strip in MC_ChatWindow.
function MC_ChatPanel.getUnread(tabId)
    return unreadByTab[tabId] or 0
end

function MC_ChatPanel.clearUnread(tabId)
    if unreadByTab[tabId] then unreadByTab[tabId] = 0 end
end

function MC_ChatPanel.getCurrentTab()
    return currentTab
end

--[[
    Add a message to the chat panel
    Pre-computes display lines immediately

    Internal contract: characterName/playerColor arrive already anonymized --
    MC_Anonymity applies masking/distance in the caller before this is ever
    called; addMessage itself only renders, never masks.

    @param msgData  Message data table with:
        - channel: Channel name
        - username: Player username
        - characterName: In-game character name
        - message: Message text
        - playerColor: {r, g, b} color
        - timestamp: Unix timestamp (optional)
        - frequency: Radio frequency (optional, for radio messages)
        - originalChannel: Original speech channel (optional, for radio)
]]
local function addMessage(msgData, trustedAdminOwn)
    if type(msgData) ~= "table" then
        MC_Incident.report("CHAT_PAYLOAD_INVALID", "message data was not a table")
        return
    end

    local channel = msgData.channel
    if type(channel) ~= "string" or channelToTab[channel] == nil then
        MC_Incident.report("CHAT_PAYLOAD_INVALID", "channel unavailable")
        return
    end
    if type(msgData.message) ~= "string" then
        MC_Incident.report("CHAT_PAYLOAD_INVALID", "message field unavailable")
        return
    end
    if channel == "radio" then
        if not isFiniteNumber(msgData.frequency)
           or msgData.frequency <= 0
           or msgData.frequency % 1 ~= 0
           or type(msgData.originalChannel) ~= "string"
           or RADIO_ORIGINAL_CHANNELS[msgData.originalChannel] ~= true then
            MC_Incident.report("CHAT_PAYLOAD_INVALID",
                "radio metadata unavailable")
            return
        end
    end

    local characterName = msgData.characterName
    if type(characterName) ~= "string" or characterName == "" then
        if channel == "event" then
            -- The server deliberately strips the narrator's identity from
            -- /event (MC_Server's identity scrub). An empty name here is the
            -- contract, not damage -- the event renderer prints no name.
            characterName = ""
        else
            MC_Incident.report("CHAT_PAYLOAD_FALLBACK",
                "neutral character label used")
            characterName = "Someone"
        end
    end

    local username = msgData.username
    if type(username) ~= "string" or username == "" then
        if channel == "system" or channel == "event" then
            -- system: locally-synthesised lines have no account behind them.
            -- event: the server's identity scrub empties the username on
            -- purpose (see the characterName note above).
            username = channel
        else
            MC_Incident.report("CHAT_PAYLOAD_FALLBACK",
                "transport username unavailable")
            username = "unknown"
        end
    end

    local playerColor = msgData.playerColor
    if type(playerColor) ~= "table"
       or not isFiniteNumber(playerColor[1])
       or not isFiniteNumber(playerColor[2])
       or not isFiniteNumber(playerColor[3])
       or playerColor[1] < 0 or playerColor[1] > 255
       or playerColor[2] < 0 or playerColor[2] > 255
       or playerColor[3] < 0 or playerColor[3] > 255 then
        MC_Incident.report("CHAT_PAYLOAD_FALLBACK",
            "neutral player color used")
        playerColor = {255, 255, 255}
    end

    local tabId = channelToTab[channel]
    
    -- Assign unique ID
    local msgId = nextMsgId
    nextMsgId = nextMsgId + 1
    
    local msg = {
        msgId = msgId,
        timestamp = msgData.timestamp or MC_Core.getTimeSeconds(),
        channel = channel,
        originalChannel = msgData.originalChannel,
        username = username,
        -- Account usernames are transport identity, never a public character
        -- label. A missing display name fails to a neutral shell.
        characterName = characterName,
        playerColor = playerColor,
        message = msgData.message,
        chunks = msgData.chunks,  -- v8.5: server-provided render chunks (nil -> flat-string path)
        modality = msgData.modality,  -- B1 fix: signed verb-framing tag swap needs this through the real path
        frequency = msgData.frequency,
        isRoll = msgData.isRoll or false,
        rollTotal = msgData.rollTotal,
        isCrit = msgData.isCrit or false,
        isFumble = msgData.isFumble or false,
        hoverName = type(msgData.hoverName) == "string"
            and msgData.hoverName ~= "" and msgData.hoverName or nil,
    }
    
    -- Helper to add to a specific tab
    local function tabContentHeight(tid)
        local total = 0
        local access = MC_Theme.access()
        local height = MC_ChatPanel.instance and MC_ChatPanel.instance.lineHeight or 16
        for _, line in ipairs(displayLinesByTab[tid] or {}) do
            total = total + height + gapAbove(line, height, access)
        end
        return total
    end

    local function addToTab(tid)
        if not displayLinesByTab[tid] then
            displayLinesByTab[tid] = {}
            scrollOffsetByTab[tid] = 0
            messageCountByTab[tid] = 0
        end
        if not rawMessagesByTab[tid] then
            rawMessagesByTab[tid] = {}
        end
        
        -- Store raw message for rewrap
        table.insert(rawMessagesByTab[tid], msg)
        
        local instance = MC_ChatPanel.instance
        local panelWidth = instance and tonumber(instance.width) or nil
        if not isFiniteNumber(panelWidth) or panelWidth <= 0 then
            panelWidth = MC_Config.Panel.defaultWidth
        end
        local margin = instance and tonumber(instance.margin)
            or MC_Config.Panel.margin
        
        local oldHeight = tabContentHeight(tid)
        local wasScrolled = (scrollOffsetByTab[tid] or 0) > 0
        if wasScrolled and not newBoundaryByTab[tid] then
            newBoundaryByTab[tid] = msg.msgId
        end
        local newLines = computeMessageLines(msg, panelWidth, margin)
        -- Stripe parity by MESSAGE within this tab, so a long message is
        -- one band and two neighbours never share a shade. The first line
        -- also learns whether the speaker changed, for the speaker gap.
        local stripe = messageCountByTab[tid] % 2
        local raw = rawMessagesByTab[tid]
        local prev = raw[#raw - 1]
        local changed = (prev == nil) or (prev.username ~= msg.username)
        for _, line in ipairs(newLines) do
            line.stripe = stripe
            if line.isFirstLine then line.speakerChanged = changed end
            table.insert(displayLinesByTab[tid], line)
        end

        messageCountByTab[tid] = messageCountByTab[tid] + 1
        
        -- Trim old messages (both raw and display)
        while messageCountByTab[tid] > maxMessages do
            local lines = displayLinesByTab[tid]
            local rawMsgs = rawMessagesByTab[tid]
            if #lines > 0 then
                local oldestMsgId = lines[1].msgId
                while #lines > 0 and lines[1].msgId == oldestMsgId do
                    table.remove(lines, 1)
                end
                -- Also remove from raw storage
                if #rawMsgs > 0 and rawMsgs[1].msgId == oldestMsgId then
                    table.remove(rawMsgs, 1)
                end
                messageCountByTab[tid] = messageCountByTab[tid] - 1
            else
                break
            end
        end
        if newBoundaryByTab[tid] then
            local boundaryFound = false
            for _, line in ipairs(displayLinesByTab[tid]) do
                if line.msgId == newBoundaryByTab[tid] then boundaryFound = true break end
            end
            if not boundaryFound then
                newBoundaryByTab[tid] = displayLinesByTab[tid][1]
                    and displayLinesByTab[tid][1].msgId or nil
            end
        end
        if wasScrolled then
            scrollOffsetByTab[tid] = (scrollOffsetByTab[tid] or 0)
                + math.max(0, tabContentHeight(tid) - oldHeight)
        end
        if MC_ChatPanel.instance then
            local viewHeight = MC_ChatPanel.instance.height
                - MC_ChatPanel.instance.margin * 2
            local maxForTab = math.max(0, tabContentHeight(tid) - viewHeight)
            scrollOffsetByTab[tid] = math.max(0, math.min(
                scrollOffsetByTab[tid] or 0, maxForTab))
            if scrollOffsetByTab[tid] == 0 then newBoundaryByTab[tid] = nil end
        end
    end
    
    -- OOC is also part of the Local front view. Both tabs keep their own
    -- rows and scroll state around the same accepted message record.
    local storedTargets = {}
    addToTab(tabId)
    storedTargets[tabId] = true
    if channel == "ooc" and tabId ~= MC_ChatPanel.TAB_LOCAL then
        addToTab(MC_ChatPanel.TAB_LOCAL)
        storedTargets[MC_ChatPanel.TAB_LOCAL] = true
    end

    -- This hook drives the short entry-well mark. The primary accepted copy
    -- owns it; the optional where-typed echo below must never fire it again.
    local isOwn = MC_ChatPanel._isOwnMessage(msg)
        or (channel == "admin" and trustedAdminOwn == true)
    -- Chunked messages carry the exact player-visible text after babble,
    -- anonymity and lipread work.  Their flat message may still be privileged
    -- source text, so it is never an API fallback when chunks are present.
    local apiMessage = nil
    if msg.chunks == nil or (type(msg.chunks) == "table" and #msg.chunks == 0) then
        apiMessage = msg.message
    elseif type(msg.chunks) == "table" then
        local parts = {}
        local valid = true
        for _, chunk in ipairs(msg.chunks) do
            if type(chunk) ~= "table" or type(chunk.text) ~= "string" then
                valid = false
                break
            end
            table.insert(parts, chunk.text)
        end
        if valid and #parts == #msg.chunks then
            apiMessage = table.concat(parts)
        end
    end
    if apiMessage ~= nil then
        -- Fire once for the accepted primary copy only. The where-typed echo
        -- below is a view detail, not another message.
        pcall(MC_API._fire, "MCInboundMessage", {
            channel = channel,
            message = apiMessage,
            authorName = characterName,
            isOwn = isOwn,
            apiVersion = MC_API.VERSION,
        })
    else
        MC_Incident.report("CHAT_PAYLOAD_INVALID",
            "public API render chunks unavailable")
    end
    if isOwn
        and type(MC_ChatPanel.onOwnLineRendered) == "function" then
        local ok = pcall(MC_ChatPanel.onOwnLineRendered,
            {playerColor[1], playerColor[2], playerColor[3]})
        if not ok then
            MC_Incident.report("CHAT_POLISH_CALLBACK_FAILED",
                "own-line render hook failed")
        end
    end

    -- Anything arriving on a tab the player is not looking at is unread.
    -- The Admin tab is ours to render as of 0.10.6, so it badges like the
    -- rest: staff should see that admin traffic arrived.
    if tabId ~= currentTab or not windowIsVisible() then
        unreadByTab[tabId] = (unreadByTab[tabId] or 0) + 1
    end

    -- Your OWN message also shows on the tab you typed it from, so an
    -- /ooc sent from Local (or a radio line) does not vanish from under
    -- you. The proper tab still has it; this copy carries no unread.
    if tabId ~= currentTab
        and isOwn
        and not storedTargets[currentTab]
        and MC_Theme.access().echoWhereTyped ~= false
    then
        addToTab(currentTab)
    end
    
    -- Auto-scroll to bottom if near bottom
    if MC_ChatPanel.instance and tabId == currentTab then
        local currentScroll = scrollOffsetByTab[tabId] or 0
        if currentScroll < MC_ChatPanel.instance.lineHeight * 2 then
            scrollOffsetByTab[tabId] = 0
            newBoundaryByTab[tabId] = nil
        end
    end
end


function MC_ChatPanel.addMessage(msgData)
    -- Raw transported/player data can never nominate itself as an Admin
    -- self-line. Only MC_Client's verified engine Admin seam may pass that
    -- proof through addVerifiedAdminMessage below.
    return addMessage(msgData, false)
end

function MC_ChatPanel.addVerifiedAdminMessage(msgData, isOwn)
    if type(msgData) ~= "table" or msgData.channel ~= "admin" then return end
    return addMessage(msgData, isOwn == true)
end

--[[
    Build and add a "[MongooseChat]" system line -- the one shared shape
    behind MC_Input's local command feedback, MC_LangAdmin's admin-menu
    feedback, and MC_Client's server-forwarded SystemMessage handler.

    @param message  Line text
    @param opts      Optional { color = {r,g,b}, chunks = server render chunks,
                     author = characterName label (non-empty string, <=80 chars;
                     an unusable author falls back to "[MongooseChat]" -- the
                     message itself is never dropped over its label) }
]]
function MC_ChatPanel.systemMessage(message, opts)
    opts = opts or {}
    local author = opts.author
    if author ~= nil
        and (type(author) ~= "string" or author == "" or #author > 80) then
        MC_Incident.report("CHAT_PAYLOAD_FALLBACK", "system author label unusable")
        author = nil
    end
    -- `color` belongs to the line's meaning (success, warning, chosen hue),
    -- while the default [MongooseChat] author always belongs to the brand.
    -- Fill only absent chunk colours and never mutate the server's packet.
    local chunks = opts.chunks
    if type(chunks) == "table" and opts.color then
        local colored = {}
        for i, chunk in ipairs(chunks) do
            if type(chunk) == "table" then
                local copy = {}
                for key, value in pairs(chunk) do copy[key] = value end
                if copy.color == nil then copy.color = opts.color end
                colored[i] = copy
            else
                colored[i] = chunk
            end
        end
        chunks = colored
    elseif chunks == nil and opts.color then
        chunks = { { text = message, color = opts.color } }
    end
    MC_ChatPanel.addMessage({
        channel = "system",
        username = "system",
        characterName = author or "[MongooseChat]",
        message = message,
        chunks = chunks,
        timestamp = MC_Core.getTimeSeconds(),
        playerColor = author and (opts.color or MC_Theme.channel("system"))
            or MC_Theme.Brand.mongoose,
    })
end

--[[
    Rewrap all messages for a new panel width
    Called when panel is resized
]]
local function rewrapAllMessages(panelWidth)
    local instance = MC_ChatPanel.instance
    local margin = instance and tonumber(instance.margin)
        or MC_Config.Panel.margin
    local access = MC_Theme.access()
    local lineHeight = instance and instance.lineHeight or 16
    local bottom = instance and (instance.height - instance.margin) or 0

    local function contentHeight(lines)
        local total = 0
        for _, line in ipairs(lines or {}) do
            total = total + lineHeight + gapAbove(line, lineHeight, access)
        end
        return total
    end

    -- Save the first visible message and its first-row Y. Offset zero is a
    -- deliberate bottom-follow mode and needs no anchor.
    for tid, lines in pairs(displayLinesByTab) do
        local offset = scrollOffsetByTab[tid] or 0
        scrollAnchorByTab[tid] = nil
        if instance and offset > 0 and #lines > 0 then
            local total = contentHeight(lines)
            local before = 0
            local viewTop = instance.margin - lineHeight
            local viewBottom = instance.height - instance.margin
            local seen = {}
            for idx, line in ipairs(lines) do
                if not seen[line.msgId] then
                    seen[line.msgId] = true
                    local firstY = bottom + offset - total + before
                        + gapAbove(line, lineHeight, access)
                    if firstY >= viewTop and firstY < viewBottom then
                        scrollAnchorByTab[tid] = {msgId=line.msgId, y=firstY}
                        break
                    end
                end
                before = before + lineHeight + gapAbove(line, lineHeight, access)
            end
        end
    end

    for tid, rawMsgs in pairs(rawMessagesByTab) do
        displayLinesByTab[tid] = {}
        for idx, msg in ipairs(rawMsgs) do
            local newLines = computeMessageLines(msg, panelWidth, margin)
            local stripe = (idx - 1) % 2
            local prev = rawMsgs[idx - 1]
            local changed = (prev == nil) or (prev.username ~= msg.username)
            for _, line in ipairs(newLines) do
                line.stripe = stripe
                if line.isFirstLine then line.speakerChanged = changed end
                table.insert(displayLinesByTab[tid], line)
            end
        end
        if instance then
            local lines = displayLinesByTab[tid]
            local total = contentHeight(lines)
            local view = instance.height - instance.margin * 2
            local maxScroll = math.max(0, total - view)
            local old = scrollOffsetByTab[tid] or 0
            local anchor = scrollAnchorByTab[tid]
            if old == 0 or #lines == 0 then
                scrollOffsetByTab[tid] = 0
            elseif anchor then
                local anchorIdx = nil
                for idx, line in ipairs(lines) do
                    if line.msgId == anchor.msgId then anchorIdx = idx break end
                end
                -- Trimming may remove the saved message. The oldest retained
                -- block is the stable fallback before the final clamp.
                anchorIdx = anchorIdx or 1
                local before = 0
                for idx = 1, anchorIdx - 1 do
                    local line = lines[idx]
                    before = before + lineHeight + gapAbove(line, lineHeight, access)
                end
                local line = lines[anchorIdx]
                local wanted = anchor.y - bottom + total - before
                    - gapAbove(line, lineHeight, access)
                scrollOffsetByTab[tid] = math.max(0, math.min(wanted, maxScroll))
            else
                scrollOffsetByTab[tid] = math.max(0, math.min(old, maxScroll))
            end
            if scrollOffsetByTab[tid] == 0 then newBoundaryByTab[tid] = nil end
            scrollAnchorByTab[tid] = nil
        end
    end
    
    dbg("rewrapAllMessages: rewrapped for width %d", panelWidth)
end

-- UI ELEMENT METHODS

function MC_ChatPanel:initialise()
    ISUIElement.initialise(self)
    MC_ChatPanel.instance = self
    self._lastLayoutWidth = self.width
end

function MC_ChatPanel:getLineCount()
    return #(displayLinesByTab[currentTab] or {})
end

--[[
    Extra space ABOVE a display line: the message gap before a message's
    first line, plus half a line more when the speaker changed and the
    player asked for that. Continuation lines get none. This is what
    makes "space between messages" and "blank line between speakers"
    real settings rather than labels.
]]
MC_ChatPanel._gapAbove = gapAbove

local function hoverKeyStyle(speakerColor, now)
    -- Tags-only withholds personal hue but keeps owned chrome on the shared
    -- skin-neutral rim: Mongoose Slate for bespoke skins, PZ Slate for Classic.
    local stripe = speakerColor
    if MC_Theme.access().tagsOnly then
        local border = MC_Theme.themedBorder(now)
        stripe = border.outer
    end
    return { stripe = stripe }
end
MC_ChatPanel._hoverKeyStyle = hoverKeyStyle

function MC_ChatPanel:getContentHeight()
    local lines = displayLinesByTab[currentTab] or {}
    local access = MC_Theme.access()
    local total = 0
    for _, line in ipairs(lines) do
        total = total + self.lineHeight + gapAbove(line, self.lineHeight, access)
    end
    return total
end

function MC_ChatPanel:getMaxScroll()
    local contentHeight = self:getContentHeight()
    local viewHeight = self.height - self.margin * 2
    return math.max(0, contentHeight - viewHeight)
end

function MC_ChatPanel:onMouseWheel(del)
    if not scrollOffsetByTab[currentTab] then
        scrollOffsetByTab[currentTab] = 0
    end
    
    local maxScroll = self:getMaxScroll()
    local scrollOffset = scrollOffsetByTab[currentTab]
    scrollOffset = scrollOffset - del * self.lineHeight * 3
    scrollOffset = math.max(0, math.min(scrollOffset, maxScroll))
    scrollOffsetByTab[currentTab] = scrollOffset
    if scrollOffset == 0 then newBoundaryByTab[currentTab] = nil end
    return true
end

--[[
    Follow the vanilla chat preferences live. Cheap when nothing changed
    (one pcall'd table read and two compares); on a change it re-derives
    lineHeight (frozen at construction before 0.9.8 -- also the reason
    rewrap alone never fixed stale metrics) and rewraps the backlog so old
    lines pick up the new font metrics / timestamp visibility too.
]]
local panelLineGap = 2

local function applyVanillaChatPrefs(self)
    local prefs = readVanillaChatPrefs()
    -- The player's Text size (Options > Mods > MongooseChat) beats the game's
    -- chat font; Follow game hands the vanilla face straight through.
    local font = MC_Theme.font("window", fontByName(prefs.font))
    local access = MC_Theme.access()
    local gap = tonumber(access.lineSpacing) or 2
    local changed = false
    if font ~= panelFont or gap ~= panelLineGap then
        panelFont = font
        panelLineGap = gap
        changed = true
    end
    -- A hosted panel may be replaced while the shared preference value stays
    -- the same. The new instance still needs the live metrics copied onto it.
    self.font = font
    self.lineHeight = getTextManager():getFontHeight(font) + gap
    if prefs.showTimestamp ~= panelShowTimestamp then
        panelShowTimestamp = prefs.showTimestamp
        changed = true
    end
    if changed then
        local width = tonumber(self.width)
        rewrapAllMessages(isFiniteNumber(width) and width > 0 and width
            or MC_Config.Panel.defaultWidth)
    end
end
MC_ChatPanel._applyVanillaChatPrefs = applyVanillaChatPrefs

-- Colours are baked into display lines when a message arrives, so a
-- settings change (high contrast lifts some channels) must rebuild them.
pcall(function()
    require("MC_Options").onApply(function()
        if MC_ChatPanel.instance then
            local width = tonumber(MC_ChatPanel.instance.width)
            rewrapAllMessages(isFiniteNumber(width) and width > 0 and width
                or MC_Config.Panel.defaultWidth)
        end
    end)
end)
MC_ChatPanel._formatTime = formatTime

function MC_ChatPanel:prerender()
    ISPanel.prerender(self)

    applyVanillaChatPrefs(self)

    -- Every real pixel change can move a wrap boundary.
    if self.width ~= self._lastLayoutWidth then
        self._lastLayoutWidth = self.width
        local width = tonumber(self.width)
        rewrapAllMessages(isFiniteNumber(width) and width > 0 and width
            or MC_Config.Panel.defaultWidth)
    end
end

-- Paint only while the caller owns the panel stencil.  Keep this separate
-- from render() so every throw -- text, measures, scrollbar, or hover key --
-- crosses the one cleanup point below.
local function renderClipped(self)
    local lineHeight = self.lineHeight
    local margin = self.margin
    local textManager = getTextManager()
    local font = panelFont or UIFont.Medium
    local access = MC_Theme.access()
    -- Tags-only keeps the semantic channel tag coloured. Names and all body
    -- forms become chalk, including trusted coloured chunks.
    local contentMono = access.tagsOnly and MC_Theme.Channels.say or nil
    
    local displayLines = displayLinesByTab[currentTab] or {}
    local scrollOffset = scrollOffsetByTab[currentTab] or 0
    local viewHeight = self.height - margin * 2
    local totalLines = #displayLines
    self.nameHoverTargets = {}

    -- Walk from the newest line upward, accumulating each line's own
    -- height plus the gap above it. scrollOffset is pixels (0 = newest at
    -- the bottom). Lines above the view stop the walk; lines below it are
    -- skipped but still consume height.
    local cursor = self.height - margin + scrollOffset
    local topLimit = margin - lineHeight

    for i = totalLines, 1, -1 do
        local line = displayLines[i]
        if line then
            local y = cursor - lineHeight
            cursor = y - gapAbove(line, lineHeight, access)
            if y < topLimit then break end

            if y >= margin - lineHeight and y < self.height - margin + lineHeight then
                local x = margin
                local stateGround = access.altShading and line.stripe == 1

                -- Alternate message shading: a faint lighter band under
                -- every other message. Painted first, under the text.
                if access.altShading and line.stripe == 1 then
                    self:drawRect(margin - 4, y, self.width - margin * 2,
                        lineHeight, 0.07, 1, 1, 1)
                end

                if line.isHeaderLine then
                    -- A long timestamp/tag/name is wrapped as bounded header
                    -- rows. Its chunks begin at the true left edge and never
                    -- share a row with body text.
                    x = margin
                elseif line.isFirstLine then
                    -- Timestamp (gray)
                    local timeR, timeG, timeB = 0.5, 0.5, 0.5
                    if access.highContrast then
                        local timeColor = readable({127.5, 127.5, 127.5}, stateGround)
                        timeR, timeG, timeB = timeColor[1]/255,
                            timeColor[2]/255, timeColor[3]/255
                    end
                    self:drawText(line.timeStr, x, y, timeR, timeG, timeB,
                        readableAlpha(0.8), font)
                    x = x + textManager:MeasureStringX(font, line.timeStr)
                    
                    if not line.isEmote then
                        -- Channel tag
                        local tc = readable(line.tagColor, stateGround)
                        self:drawText(line.tag .. " ", x, y, tc[1]/255, tc[2]/255,
                            tc[3]/255, readableAlpha(0.9), font)
                        x = x + textManager:MeasureStringX(font, line.tag .. " ")
                        
                        -- Player name. Bold = the same word drawn twice, one
                        -- pixel over: no bold face exists, and this reads as
                        -- weight without touching the layout.
                        local pc = readable(contentMono or line.playerColor, stateGround)
                        local nameWidth = textManager:MeasureStringX(font, line.nameStr)
                        self:drawText(line.nameStr, x, y, pc[1]/255, pc[2]/255, pc[3]/255, 1, font)
                        if access.boldNames then
                            self:drawText(line.nameStr, x + 1, y, pc[1]/255, pc[2]/255,
                                pc[3]/255, readableAlpha(0.85), font)
                        end
                        local hoverName = line.hoverName
                        if type(hoverName) == "string" and hoverName ~= ""
                            and nameWidth > 0 then
                            table.insert(self.nameHoverTargets, {x=x, y=y,
                                w=nameWidth, h=lineHeight, name=hoverName,
                                color=pc})
                        end
                        x = x + nameWidth
                    end
                else
                    -- Continuation indent
                    x = margin + line.prefixWidth
                end
                
                -- Message text
                if line.chunks then
                    for _, chunk in ipairs(line.chunks) do
                        local semanticHeader = line.isHeaderLine
                            and (chunk.kind == "tag" or chunk.kind == "timestamp")
                        local cc = semanticHeader and chunk.color
                            or contentMono or chunk.color or line.tagColor
                        cc = readable(cc, stateGround)
                        local ca = readableAlpha(chunk.alpha or 1)
                        local chunkWidth = textManager:MeasureStringX(font, chunk.text)
                        self:drawText(chunk.text, x, y, cc[1]/255, cc[2]/255, cc[3]/255, ca, font)
                        if chunk.kind == "name"
                            and type(chunk.displayName) == "string"
                            and chunk.displayName ~= "" and chunkWidth > 0 then
                            table.insert(self.nameHoverTargets, {x=x, y=y,
                                w=chunkWidth, h=lineHeight,
                                name=chunk.displayName, color=cc})
                        end
                        x = x + chunkWidth
                    end
                elseif line.text then
                    local tc = readable(contentMono or line.tagColor, stateGround)
                    self:drawText(line.text, x, y, tc[1]/255, tc[2]/255, tc[3]/255, 1, font)
                end
            end
        end
    end
    
    -- Scrollbar
    local totalHeight = self:getContentHeight()
    local maxScroll = math.max(0, totalHeight - viewHeight)
    if maxScroll > 0 then
        local barHeight = math.max(20, (viewHeight / totalHeight) * viewHeight)
        local scrollRatio = scrollOffset / maxScroll
        local barY = margin + (1 - scrollRatio) * (viewHeight - barHeight)
        local thumb = MC_Theme.texture("window/scroll-thumb.png")
        local lichen = readable(MC_Theme.windowControlColor(), "state")
        if thumb then
            self:drawTextureScaled(thumb, self.width - 6, barY, 4, barHeight,
                1, lichen[1]/255, lichen[2]/255, lichen[3]/255)
        else
            self:drawRect(self.width - 6, barY, 4, barHeight, readableAlpha(0.85),
                lichen[1]/255, lichen[2]/255, lichen[3]/255)
        end

        local boundary = newBoundaryByTab[currentTab]
        if boundary then
            local before = 0
            for _, line in ipairs(displayLines) do
                if line.msgId == boundary then break end
                before = before + lineHeight + gapAbove(line, lineHeight, access)
            end
            local capY = margin + math.max(0, math.min(viewHeight - 2,
                (before / math.max(1, totalHeight)) * viewHeight))
            self:drawRect(self.width - 7, capY, 5, 2, 1,
                math.min(1, lichen[1]/255 + 0.2),
                math.min(1, lichen[2]/255 + 0.2),
                math.min(1, lichen[3]/255 + 0.2))
        end
    end

    local mx, my = self:getMouseX(), self:getMouseY()
    for _, target in ipairs(self.nameHoverTargets) do
        if mx >= target.x and mx <= target.x + target.w
            and my >= target.y and my <= target.y + target.h then
            -- Six quiet pixels on every side keep the key clear of the full
            -- three-band content rim.
            local hoverTextWidth = wrapWidthOrReport(
                self.width - margin * 2 - 18)
            local hoverLines = wrapText(target.name, font, hoverTextWidth)
            local measuredHoverWidth = 0
            for _, hoverLine in ipairs(hoverLines) do
                measuredHoverWidth = math.max(measuredHoverWidth,
                    textManager:MeasureStringX(font, hoverLine))
            end
            local tw = math.min(self.width - margin * 2,
                math.max(MC_Theme.Metrics.corner * 2,
                    measuredHoverWidth + 18))
            local th = math.max(MC_Theme.Metrics.corner * 2,
                #hoverLines * lineHeight + 12)
            local tx = math.max(margin, math.min(mx + 8, self.width - margin - tw))
            local ty = math.max(margin, math.min(my + 10, self.height - margin - th))
            local keyFrame = MC_Theme.textures("window", "frame")
            MC_Theme.slice(self, keyFrame, tx, ty, tw, th,
                readableAlpha(0.94), true)
            local keyStyle = hoverKeyStyle(target.color, MC_Core.getTimeMs())
            MC_Theme.drawSliceEdge(self, "window", "frame",
                tx, ty, tw, th, 1, MC_Core.getTimeMs(), "content", nil,
                nil, nil, true)
            local stripe = readable(keyStyle.stripe)
            self:drawRect(tx + 6, ty + 6, 2, th - 12, 1,
                stripe[1]/255, stripe[2]/255, stripe[3]/255)
            for lineIndex, hoverLine in ipairs(hoverLines) do
                local hoverInk = access.highContrast and readable({239.7, 239.7, 234.6})
                    or {0.94*255, 0.94*255, 0.92*255}
                self:drawText(hoverLine, tx + 12,
                    ty + 6 + (lineIndex - 1) * lineHeight,
                    hoverInk[1]/255, hoverInk[2]/255, hoverInk[3]/255, 1, font)
            end
            break
        end
    end
end

function MC_ChatPanel:render()
    -- The panel sits wholly inside the window rim. Keep every panel-local
    -- mark inside that box: a partly visible oldest row must not paint behind
    -- the tabs, while the full first row remains untouched.  PZ's stencil is
    -- shared UI state, so clear it even when a draw callback throws.
    self:setStencilRect(0, 0, self.width, self.height)
    local ok, renderError = pcall(renderClipped, self)
    self:clearStencilRect()
    if not ok then
        error(renderError, 0)
    end
end

function MC_ChatPanel:new(x, y, width, height)
    dbg("new: creating panel at %d,%d size %dx%d", x, y, width, height)
    
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    -- Inside MC_ChatWindow the window paints slate; the panel stays clear
    -- so the opacity setting is applied once, not twice.
    o.background = false
    o.backgroundColor = {r=0, g=0, b=0, a=0}
    o.borderColor = {r=0, g=0, b=0, a=0}
    -- Direct-drawn text and the direct-drawn scrollbar have no child widget
    -- to claim the wheel. Make the whole transcript rectangle the event target
    -- so text, blank transcript space and the scrollbar all scroll alike.
    o.wantMouseEvents = true
    
    -- Seed from the vanilla preference (core option at construction time;
    -- applyVanillaChatPrefs keeps it live from prerender onward).
    local prefs = readVanillaChatPrefs()
    panelFont = fontByName(prefs.font)
    panelShowTimestamp = prefs.showTimestamp
    o.font = panelFont or UIFont.Medium
    o.lineHeight = getTextManager():getFontHeight(o.font) + 2
    o.margin = MC_Config.Panel.margin
    
    o._lastLayoutWidth = width
    
    return o
end

-- MESSAGE CLEARING

--[[
    Clear all chat messages from all tabs.
    Called when a new character is created to prevent seeing old history.
]]
function MC_ChatPanel.clearAllMessages()
    for tid = 1, TAB_COUNT do
        displayLinesByTab[tid] = {}
        rawMessagesByTab[tid] = {}
        scrollOffsetByTab[tid] = 0
        messageCountByTab[tid] = 0
        unreadByTab[tid] = 0
        newBoundaryByTab[tid] = nil
        scrollAnchorByTab[tid] = nil
    end
end


function MC_ChatPanel.clearTab(tabId)
    if type(tabId) ~= "number" or tabId ~= math.floor(tabId)
        or tabId < 1 or tabId > TAB_COUNT then return false end
    displayLinesByTab[tabId] = {}
    rawMessagesByTab[tabId] = {}
    scrollOffsetByTab[tabId] = 0
    messageCountByTab[tabId] = 0
    unreadByTab[tabId] = 0
    newBoundaryByTab[tabId] = nil
    scrollAnchorByTab[tabId] = nil
    if MC_ChatPanel.instance and currentTab == tabId then
        MC_ChatPanel.instance.nameHoverTargets = {}
    end
    return true
end

-- Clear chat history when a new character is created
-- This prevents new characters from seeing messages from before they existed
local function onCreatePlayer(playerIndex, player)
    MC_ChatPanel.clearAllMessages()
    if type(MC_ChatPanel.onSessionReset) == "function" then
        local ok = pcall(MC_ChatPanel.onSessionReset)
        if not ok then
            MC_Incident.report("CHAT_SESSION_RESET_HOOK_FAILED",
                "session reset hook failed")
        end
    end
    -- Same fresh-character moment: a re-rolled character must not keep the
    -- dead character's bio tagline either. MC_Bio owns the check + clear.
    MC_Bio.clearTaglineForFreshCharacter(player)
end

Events.OnCreatePlayer.Add(onCreatePlayer)


return MC_ChatPanel
