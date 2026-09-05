--[[
================================================================================
    MongooseChat - Speech Bubble
    
    Renders speech bubbles above players using ISUIElement with direct drawText.
    Supports standard speech, radio, emote, and narration bubble styles.
    
    BUBBLE TYPES:
    - Standard: new(player, message, channel) - Normal proximity speech
    - Radio: newRadio(...) - Radio transmission with distinct style
    - Emote: newEmote(name, action, target) - *Name action* format
    - Do: newDo(narration, target) - Environment narration
    - Lore: newLore(text, target) - Persistent ground-anchored note text
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Config = require("MC_Config")
local MC_Bio = require("MC_Bio")
local MC_ChatPanel = require("MC_ChatPanel")
local MC_Incident = require("MC_Incident")
local MC_Theme = require("MC_Theme")

local dbg = MC_Core.debugger("BUBBLE")

local MC_Bubble = ISUIElement:derive("MC_Bubble")
local MIN_SKIN_SIZE = MC_Theme.Metrics.corner * 2
local BUBBLE_VERTICAL_PADDING = 12
local BUBBLE_TEXT_GUTTER = 18
-- MeasureStringX reports logical advance, while a glyph may paint beyond it.
-- Match the transcript's proven buffer: wrapping gives up these last pixels
-- instead of trusting a doubtful edge fit.
local BUBBLE_GLYPH_BUFFER = 8
local BUBBLE_GLYPH_RESERVE = BUBBLE_GLYPH_BUFFER * 2

-- One geometry contract owns wrapping, finished width, and render centring.
-- Top and bottom keep the compact 12px spacing.  Text uses equal 18px side
-- gutters so its visual centre is the bubble centre (or the post-avatar
-- content-region centre) while staying clear of either painted rim.
local function bubbleTextLayout(width, textOffsetX)
    local left = (textOffsetX or 0) + BUBBLE_TEXT_GUTTER
    local right = BUBBLE_TEXT_GUTTER
    local available = nil
    if width then available = math.max(1, width - left - right) end
    return left, right, available, left + right
end
MC_Bubble._textLayout = bubbleTextLayout

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function validPlayerColor(color)
    if type(color) ~= "table" then return nil end
    local copy = {}
    for index = 1, 3 do
        local component = color[index]
        if not isFiniteNumber(component) or component < 0 or component > 255 then
            return nil
        end
        copy[index] = component
    end
    return copy
end

local function channelColor(name, fallback)
    local colors = MC_Config.ChannelColors
    local color = type(colors) == "table" and colors[name] or nil
    if type(color) ~= "table" then
        MC_Incident.report("BUBBLE_COLOR_FALLBACK",
            "channel=" .. tostring(name):gsub("[^%w_]", "_"):sub(1, 32))
        return fallback
    end
    return color
end

-- Read bubble duration live from SandboxVars each time a bubble is created.
local function getLiveBubbleDuration()
    local serverMs = MC_Config.liveSandbox("BubbleDuration", MC_Config.Bubble.duration) * 1000
    -- The player's own hold is only ever ADDED: a bubble can stay longer
    -- than the server's setting for someone who reads slowly, never shorter.
    local hold = tonumber(MC_Theme.access().bubbleHoldMs) or 0
    if hold < 0 then hold = 0 end
    return serverMs + hold
end

-- Past a few lines a bubble reads better across than down, so a long message
-- buys width before it keeps stacking lines. Short messages never move: they
-- fit inside the target on the first try and keep the shape they always had.
local WIDEN_LINE_TARGET = 4
local WIDEN_STEP = 60

--[[
    Wrap a bubble's text, widening the bubble while that buys fewer lines.
    @param wrap    function(textAreaWidth) -> lines; called once per width tried
    @param chrome  non-text width the bubble spends (padding, avatar column)
    @return lines, and the bubble width cap they were wrapped for
]]
local function wrapWidestFit(wrap, chrome)
    local width = MC_Config.Bubble.maxWidth
    local ceiling = MC_Config.Bubble.maxWidthWide
    if not isFiniteNumber(ceiling) or ceiling < width then ceiling = width end

    local lines = wrap(math.max(1, width - chrome - BUBBLE_GLYPH_RESERVE))
    while #lines > WIDEN_LINE_TARGET and width < ceiling do
        width = math.min(width + WIDEN_STEP, ceiling)
        lines = wrap(math.max(1, width - chrome - BUBBLE_GLYPH_RESERVE))
    end
    return lines, width
end
MC_Bubble._wrapWidestFit = wrapWidestFit

local function finishedBubbleWidth(textWidth, chrome, maxWidth)
    return math.max(MIN_SKIN_SIZE,
        math.min(textWidth + chrome + BUBBLE_GLYPH_RESERVE, maxWidth))
end
-- TEXTURE MANAGEMENT

local texturesByStyle = {}

local function textureFolder(style, theme)
    local root = theme.skin and theme.skin() == "vanilla"
        and "bubble-classic/" or "bubble/"
    return root .. (style or "simple")
end

-- Client Lua modules may be rebuilt while joining a server.  A bubble can
-- outlive that rebuild, so its render path must not keep drawing through the
-- Theme table captured when this file first loaded.
local function liveTheme()
    local ok, theme = pcall(require, "MC_Theme")
    if ok and type(theme) == "table" then return theme end
    return MC_Theme
end

local function loadTextures(style, theme)
    style = style or "simple"
    theme = theme or liveTheme()
    local folder = textureFolder(style, theme)
    
    local cached = texturesByStyle[folder]
    if cached and cached.theme == theme then
        return cached.textures
    end
    
    dbg("loadTextures: loading style '%s'", style)
    
    -- One loader for every 9-slice set in the mod (MC_Theme.textures);
    -- the bubble folders keep their layout, only the loading is shared.
    local textures = theme.textures(folder, "bubble")
    
    texturesByStyle[folder] = { theme = theme, textures = textures }
    dbg("loadTextures: center=%s", tostring(textures.center))
    
    return textures
end

-- POSITIONING

--[[
    Convert world coords to screen position. Thin wrapper over the shared
    projection math (MC_Bio._screenPosition -- see MC_Bio for why it's
    homed there and not here) that fixes this file's yAdjust constant.
    @param target   Player/IsoObject with getX/Y/Z, or table {x=, y=, z=}
    @param width    Bubble width for centering
    @param height   Bubble height
    @param offsetY  Vertical offset (default BUBBLE_OFFSET_PLAYER)
    @return x, y screen coordinates (or nil if not calculable)
]]
local function getScreenPosition(target, width, height, offsetY)
    offsetY = offsetY or MC_Core.Display.BUBBLE_OFFSET_PLAYER
    local x, y = MC_Bio._screenPosition(target, width, height, offsetY,
        MC_Core.Display.BUBBLE_Y_ADJUST)
    if not x then return x, y end

    -- A wide bubble centered on someone near the edge of the view would hang
    -- off it, so slide it back into frame -- but only while the speaker is
    -- still on screen. A speaker who walks out of frame takes their bubble
    -- with them; parking it against the edge would leave it pointing at empty
    -- ground for the rest of its life. Horizontal only: a bubble above the top
    -- edge belongs to a speaker off-screen anyway, and the arrow still has to
    -- point down at them.
    local screenWidth = MC_Core.safe(function() return getCore():getScreenWidth() end, nil)
    if isFiniteNumber(screenWidth) and screenWidth > width then
        local speakerX = x + width / 2
        if speakerX >= 0 and speakerX <= screenWidth then
            x = math.max(0, math.min(x, screenWidth - width))
        end
    end
    return x, y
end

-- UI ELEMENT METHODS

function MC_Bubble:initialise()
    ISUIElement.initialise(self)
end

-- MOUSE PASS-THROUGH
-- Return false to not consume events - allows clicking through bubbles

function MC_Bubble:onMouseDown(x, y)
    return false
end

function MC_Bubble:onRightMouseDown(x, y)
    return false
end

function MC_Bubble:onMouseUp(x, y)
    return false
end

function MC_Bubble:onRightMouseUp(x, y)
    return false
end

function MC_Bubble:isMouseOver()
    return false
end

function MC_Bubble:prerender()
    -- Update position to follow target
    if self.target then
        local x, y = getScreenPosition(self.target, self.width, self.height, self.offsetY)
        if x and y then
            self:setX(x)
            self:setY(y)
        else
            MC_Incident.report("BUBBLE_POSITION_UNAVAILABLE",
                "active bubble hidden after projection failure")
            self.dead = true
            pcall(function() self:setVisible(false) end)
        end
    end
end

-- M3(a) fix: resolve the texture set to actually draw with, given a
-- requested style. A missing/broken set (e.g. sign/ failing to load) used
-- to make :render() draw NOTHING at all -- not even the text -- an
-- invisible bubble with real content silently lost. Falls back to the
-- baked-in "simple" style instead and reports the substitution; only if simple
-- itself is somehow missing is there truly nothing to draw (tex.center
-- nil on return). Split out from :render() so the fallback decision is
-- testable offline without mocking the whole ISUIElement drawing surface.
local function resolveTextures(style, theme)
    theme = theme or liveTheme()
    local tex = loadTextures(style, theme)
    if tex.center then return tex, style end
    if style == "simple" then
        MC_Incident.report("BUBBLE_STYLE_UNAVAILABLE", "style=simple")
        return tex, style
    end
    dbg("resolveTextures: style '%s' failed to load (missing textures) -- falling back to 'simple'",
        tostring(style))
    MC_Incident.report("BUBBLE_STYLE_FALLBACK",
        "requested style unavailable; using simple")
    local fallback = loadTextures("simple", theme)
    if not fallback.center then
        MC_Incident.report("BUBBLE_STYLE_UNAVAILABLE",
            "fallback style=simple unavailable")
    end
    return fallback, "simple"
end
MC_Bubble._resolveTextures = resolveTextures

function MC_Bubble:render()
    if self.dead then return end

    local theme = liveTheme()
    local tex, resolvedStyle = resolveTextures(self.style, theme)
    if not tex.center then return end
    
    local alpha
    local now = MC_Core.getTimeMs()
    if self.persistent then
        -- Persistent bubbles (lore notes) have no lifetime of their own:
        -- the owning module drives externalAlpha for the proximity fade and
        -- reaps the element itself, so the TTL below never applies.
        alpha = self.opacity * (self.externalAlpha or 1)
        if alpha <= 0 then return end
    else
        -- Calculate alpha based on time remaining
        local elapsed = now - self.startTime
        local remaining = self.duration - elapsed

        if remaining <= 0 then
            self.dead = true
            return
        end

        -- Reduced motion: MC_Theme.fadeMs answers 0, so the bubble holds
        -- full alpha and then vanishes rather than ramping.
        local fadeMs = theme.fadeMs(MC_Config.Bubble.fadeTime * 1000)
        alpha = self.opacity
        if fadeMs > 0 and remaining < fadeMs then
            alpha = alpha * (remaining / fadeMs)
        end
    end
    
    -- Draw 9-patch bubble
    local w = self.width
    local h = self.height
    local corner = 10

    -- Skin alpha is scaled separately from text alpha so a bubble can let the
    -- world read through its background without dimming its own words. Only
    -- lore notes set a scale below 1 (see :newLore); everything else is 1 and
    -- renders exactly as before.
    -- High contrast keeps readable content and its backing opaque until the
    -- normal lifetime/range gate removes it.  The gate checks above still own
    -- whether anything may be drawn.
    alpha = theme.readableAlpha(alpha)
    local skinAlpha = theme.backgroundAlpha(alpha * (self.skinAlphaScale or 1))
    local sharpTheme = theme.access().sharpTheme == true

    -- The same nine draws the window, tabs and well use (MC_Theme.slice).
    theme.slice(self, tex, 0, 0, w, h, skinAlpha)

    -- Arrow pointing down (skip for emotes)
    if tex.arrow and not self.hideArrow and not sharpTheme then
        local tintR, tintG, tintB = theme.baseTint()
        self:drawTextureScaled(tex.arrow, w / 2 - 3, h - 2, 7, 9,
            skinAlpha, tintR, tintG, tintB)
    end

    -- Exact edge masks follow the original skin alpha inside the same slice.
    -- Arrowless bubbles hide both the base arrow and every edge-arrow layer.
    local edgeArrow = nil
    if tex.arrow and not self.hideArrow then
        edgeArrow = { x = w / 2 - 3, y = h - 2, w = 7, h = 9 }
    end
    -- Classic uses the exact old painted bubble bytes.  Do not put a modern
    -- identity rim over their neutral curved edge.  Soft and Sharp keep the
    -- current compositor and speaker-colour behavior.
    local classicShimmer = false
    if theme.skin() == "vanilla" then
        local palette = theme.edgePalette("content", now, nil,
            self.rimColor, false)
        classicShimmer = palette and (palette.shimmerWeight or 0) > 0
    end
    if theme.skin() ~= "vanilla" or classicShimmer then
        theme.drawSliceEdge(self, "bubble/" .. resolvedStyle, "bubble",
            0, 0, w, h, skinAlpha, now, "content", edgeArrow, nil,
            self.rimColor)
    end
    
    -- Optional 3D character model
    local textOffsetX = 0
    if self.useAvatar and self.player then
        textOffsetX = self.avatarWidth + self.avatarPadding

        -- Create model on first render
        if not self.playerModel then
            local okModel = pcall(function()
                self.playerModel = UI3DModel:new()
                self.playerModel:setWidth(45)
                self.playerModel:setHeight(self.avatarHeight)
                self.playerModel:setCharacter(self.player)
                self.playerModel:setState("idle")
                self.playerModel:setDirection(IsoDirections.SE)
                self.playerModel:setIsometric(false)
                self.playerModel:setAnimate(false)
                self.playerModel:setZoom(17)
                self.playerModel:setYOffset(-0.92)
                dbg("render: created 3D model")
            end)
            if not okModel or not self.playerModel then
                MC_Incident.report("BUBBLE_MODEL_RENDER_UNAVAILABLE",
                    "3D model could not be created")
            end
        end
        
        -- Render the 3D model
        if self.playerModel then
            local modelX = self:getX() + 2
            local modelY = self:getY() + h - self.avatarHeight - 2
            
            local screenWidth = getCore():getScreenWidth()
            local screenHeight = getCore():getScreenHeight()
            
            if self:getX() < 0 then
                modelX = 2
            elseif self:getX() > screenWidth - w - 2 then
                modelX = 2 + screenWidth - w
            end
            
            if self:getY() < 0 then
                modelY = 0
            elseif self:getY() > screenHeight - h - 2 then
                modelY = screenHeight - self.avatarHeight - 2
            end
            
            self.playerModel:setX(modelX)
            self.playerModel:setY(modelY)
            self.playerModel:render()
        end
    end
    
    -- Draw text lines
    local y = self.padding
    local textAlpha = alpha
    local textManager = getTextManager()
    
    for _, lineData in ipairs(self.lines) do
        local lineWidth = 0
        if lineData.chunks then
            for _, chunk in ipairs(lineData.chunks) do
                lineWidth = lineWidth + textManager:MeasureStringX(self.font, chunk.text)
            end
        elseif type(lineData) == "string" then
            lineWidth = textManager:MeasureStringX(self.font, lineData)
        end
        
        local textLeft, _, textAreaWidth = bubbleTextLayout(w, textOffsetX)
        local x = textLeft + (textAreaWidth - lineWidth) / 2
        
        if lineData.chunks then
            for _, chunk in ipairs(lineData.chunks) do
                local cc = theme.readableColor(chunk.color or self.textColor)
                self:drawText(chunk.text, x, y, cc[1]/255, cc[2]/255, cc[3]/255, textAlpha, self.font)
                x = x + textManager:MeasureStringX(self.font, chunk.text)
            end
        elseif type(lineData) == "string" then
            local tc = theme.readableColor(self.textColor)
            self:drawText(lineData, x, y, tc[1]/255, tc[2]/255, tc[3]/255, textAlpha, self.font)
        end
        
        y = y + self.lineHeight
    end
end

-- CONSTRUCTORS

--[[
    Create a standard speech bubble
    @param player        Player object to follow
    @param message       Message text
    @param channel       Channel name (say, yell, whisper, etc)
    @param hideAvatar    Optional: hide the 3D avatar (for distant speakers)
    @param characterName Optional: override character name for emote conversion
    @param isAnonymous   Optional: retained for caller compatibility.
    @param modality      Optional: "signed" picks the sign/ bubble skin
                         instead of the per-channel speech style.
    @param playerColor   Optional: trusted, resolved RGB name colour
    @return MC_Bubble instance or nil
]]
function MC_Bubble:new(player, message, channel, hideAvatar, characterName, isAnonymous, modality, playerColor)
    dbg("new: creating for '%s' hideAvatar=%s isAnonymous=%s",
        tostring(message and message:sub(1, 30) or "nil"), tostring(hideAvatar), tostring(isAnonymous))
    
    if not message or message == "" then
        dbg("new: empty message")
        return nil
    end
    
    local font = MC_Theme.font("bubble", UIFont.Medium)
    local padding = BUBBLE_VERTICAL_PADDING
    local lineHeight = getTextManager():getFontHeight(font) + 2

    -- Avatar dimensions (hide for distant speakers, and entirely when the
    -- sandbox mode is "off")
    local avatarWidth = 0
    local avatarHeight = 60
    local avatarPadding = 4
    local avatarMode = MC_Config.Bubble.avatarMode or "model"
    local useAvatar = MC_Config.Bubble.showAvatar ~= false and not hideAvatar
        and avatarMode ~= "off"

    if useAvatar then
        avatarWidth = 30
    end
    
    local textOffsetX = useAvatar and (avatarWidth + avatarPadding) or 0
    local _, _, _, chrome = bubbleTextLayout(nil, textOffsetX)

    local baseColor = channelColor(channel, {255, 255, 255})
    local emoteColor = channelColor("emote", {255, 190, 128})
    local moodColor = channelColor("mood", {180, 180, 200})
    
    -- Speech channels get smart asterisk handling
    local speechChannels = {say = true, yell = true, low = true, whisper = true}
    local isSpeech = speechChannels[channel]
    
    local segments, isPureEmote = MC_Core.parseColorSegments(message, baseColor, isSpeech, emoteColor, moodColor)
    
    -- Pure emote in speech -> convert to emote bubble
    if isSpeech and isPureEmote then
        local emoteContent = message:match("^%s*%*(.-)%*%s*$") or message
        -- Use passed characterName if provided (for anonymity), otherwise look up from player
        local displayName = characterName
        if not displayName then
            local username = MC_Core.safe(function() return player:getUsername() end, nil)
            displayName = MC_Bio._getCharacterName(player, username)
            if type(displayName) ~= "string" or displayName == "" then
                MC_Incident.report("BUBBLE_IDENTITY_UNAVAILABLE",
                    "pure-emote neutral identity used")
                displayName = "Someone"
            end
        end
        dbg("new: pure emote, converting with name '%s'", displayName)
        return MC_Bubble:newEmote(displayName, emoteContent, player, playerColor)
    end
    
    local wrappedLines, maxWidth = wrapWidestFit(function(textAreaWidth)
        return MC_ChatPanel._wrapTextWithColors(segments, font, textAreaWidth)
    end, chrome)
    dbg("new: %d lines at maxWidth=%d", #wrappedLines, maxWidth)
    
    if #wrappedLines == 0 then
        dbg("new: no lines")
        return nil
    end
    
    -- Calculate dimensions
    local textWidth = 0
    local textManager = getTextManager()
    for _, lineData in ipairs(wrappedLines) do
        local lineWidth = 0
        for _, chunk in ipairs(lineData.chunks) do
            lineWidth = lineWidth + textManager:MeasureStringX(font, chunk.text)
        end
        if lineWidth > textWidth then textWidth = lineWidth end
    end
    
    local width = finishedBubbleWidth(textWidth, chrome, maxWidth)
    
    local textHeight = #wrappedLines * lineHeight + padding * 2
    local height = math.max(MIN_SKIN_SIZE, textHeight, avatarHeight + padding)
    
    local x, y = getScreenPosition(player, width, height, MC_Core.Display.BUBBLE_OFFSET_PLAYER)
    if not x then 
        dbg("new: no position")
        MC_Incident.report("BUBBLE_POSITION_UNAVAILABLE",
            "speech bubble suppressed before creation")
        return nil
    end
    
    local o = ISUIElement:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.target = player
    o.offsetY = MC_Core.Display.BUBBLE_OFFSET_PLAYER
    -- Style resolution gains a modality case beside the per-channel choice
    -- (same pattern as the radio/speech split below): signed speech gets
    -- its own 9-slice skin instead of "simple".
    o.style = (modality == "signed") and MC_Config.Bubble.signStyle or MC_Config.Radio.speechBubbleStyle
    o.message = message
    o.channel = channel or "say"
    o.textColor = baseColor
    o.lines = wrappedLines
    o.font = font
    o.lineHeight = lineHeight
    o.padding = padding
    o.duration = getLiveBubbleDuration()
    o.opacity = MC_Config.Bubble.opacity
    o.startTime = MC_Core.getTimeMs()
    o.dead = false

    o.useAvatar = useAvatar
    o.avatarWidth = avatarWidth
    o.avatarHeight = avatarHeight
    o.avatarPadding = avatarPadding
    o.player = player
    o.playerModel = nil
    o.rimColor = validPlayerColor(playerColor)
    
    dbg("new: created, duration=%dms", o.duration)
    
    return o
end

--[[
    Create a radio speech bubble
    @param message   Message text (may include static)
    @param channel   Original speech channel
    @param target    Player or {x,y,z} position
    @param isPrivate Headphone flag on the routed radio message. The server
                     already delivered this message to only the one
                     receiver it resolved for the frequency (see
                     MC_Server.processMessage's routeRadio stage) -- there's
                     no separate owner-only gate to apply here. Kept only
                     for the dbg line below.
    @param volume    Radio volume (affects opacity)
    @param playerColor Optional: authenticated, post-anonymity speaker RGB
    @return MC_Bubble instance or nil
]]
function MC_Bubble:newRadio(message, channel, target, isPrivate, volume, playerColor)
    dbg("newRadio: creating for '%s'", tostring(message and message:sub(1, 30) or "nil"))
    
    if not message or message == "" then
        dbg("newRadio: empty message")
        return nil
    end
    if not isFiniteNumber(volume) or volume < 0 then
        MC_Incident.report("RADIO_METADATA_INVALID",
            "radio bubble volume unavailable")
        return nil
    end
    
    local font = MC_Theme.font("bubble", UIFont.Medium)
    local padding = BUBBLE_VERTICAL_PADDING
    local lineHeight = getTextManager():getFontHeight(font) + 2

    -- Radio color: slight blue shift from channel color
    local baseChannelColor = channelColor(channel, {255, 255, 255})
    local baseColor = {
        math.floor(baseChannelColor[1] * 0.8),
        math.floor(baseChannelColor[2] * 0.9),
        math.floor(baseChannelColor[3] * 1.0)
    }
    
    local emoteColor = channelColor("emote", {255, 190, 128})
    local moodColor = channelColor("mood", {180, 180, 200})
    local segments, _ = MC_Core.parseColorSegments(message, baseColor, true, emoteColor, moodColor)
    local _, _, _, chrome = bubbleTextLayout(nil, 0)
    local wrappedLines, maxWidth = wrapWidestFit(function(textAreaWidth)
        return MC_ChatPanel._wrapTextWithColors(segments, font, textAreaWidth)
    end, chrome)
    dbg("newRadio: %d lines at maxWidth=%d", #wrappedLines, maxWidth)
    
    if #wrappedLines == 0 then
        dbg("newRadio: no lines")
        return nil
    end
    
    -- Calculate dimensions
    local textWidth = 0
    local textManager = getTextManager()
    for _, lineData in ipairs(wrappedLines) do
        local lineWidth = 0
        for _, chunk in ipairs(lineData.chunks) do
            lineWidth = lineWidth + textManager:MeasureStringX(font, chunk.text)
        end
        if lineWidth > textWidth then textWidth = lineWidth end
    end
    
    local width = finishedBubbleWidth(textWidth, chrome, maxWidth)
    local height = math.max(MIN_SKIN_SIZE, #wrappedLines * lineHeight + padding * 2)
    
    -- Determine offset based on target type
    local offsetY = MC_Core.Display.BUBBLE_OFFSET_PLAYER
    if type(target) == "table" and target.x then
        offsetY = MC_Core.Display.BUBBLE_OFFSET_GROUND
    end
    
    local x, y = getScreenPosition(target, width, height, offsetY)
    if not x then
        dbg("newRadio: no position")
        MC_Incident.report("BUBBLE_POSITION_UNAVAILABLE",
            "radio bubble suppressed before creation")
        return nil
    end
    
    local o = ISUIElement:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.target = target
    o.offsetY = offsetY
    o.style = MC_Config.Radio.bubbleStyle
    o.message = message
    o.channel = channel or "say"
    o.textColor = baseColor
    o.lines = wrappedLines
    o.font = font
    o.lineHeight = lineHeight
    o.padding = padding
    o.duration = getLiveBubbleDuration()
    
    o.opacity = MC_Config.Bubble.opacity * math.max(0.5, volume)
    
    o.startTime = MC_Core.getTimeMs()
    o.dead = false
    o.rimColor = validPlayerColor(playerColor)
    
    dbg("newRadio: created, isPrivate=%s, offsetY=%d", tostring(isPrivate or false), offsetY)
    
    return o
end

--[[
    Create an emote/action bubble
    @param characterName  Character name
    @param action         Action text
    @param target         Player to follow
    @param playerColor    Optional: trusted, resolved RGB name colour
    @return MC_Bubble instance or nil
]]
function MC_Bubble:newEmote(characterName, action, target, playerColor)
    dbg("newEmote: %s - %s", tostring(characterName), tostring(action and action:sub(1, 30) or "nil"))
    
    if not action or action == "" then
        dbg("newEmote: empty action")
        return nil
    end
    
    local displayMessage = "*" .. (characterName or "Someone") .. " " .. action .. "*"
    
    local font = MC_Theme.font("bubble", UIFont.Medium)
    local padding = BUBBLE_VERTICAL_PADDING
    local lineHeight = getTextManager():getFontHeight(font) + 2

    local emoteColor = channelColor("emote", {255, 190, 128})

    -- The wrapping asterisks are decoration added right here, so they go
    -- AROUND the parsed body rather than through it: parsed together, the
    -- opening "*" reads as an inline emote marker and swallows the whole
    -- line, any quoted speech along with it.
    local displayName = characterName or "Someone"
    local nameColor = validPlayerColor(playerColor) or emoteColor
    -- Keep the opening decoration fused to the name while wrapping. The
    -- shared word wrapper adds spaces between colour segments, so splitting
    -- these before wrap would visibly turn `*Name` into `* Name`. Once the
    -- word is placed, split its colour runs without changing its bytes.
    local decoratedName = "*" .. displayName
    local segments = {
        { text = decoratedName, color = nameColor },
    }
    for _, segment in ipairs(MC_Core.parseColorSegments(
        action, emoteColor, false, emoteColor, emoteColor,
        channelColor("say", {255, 255, 255})))
    do
        segments[#segments + 1] = segment
    end
    -- Close the emote on the last segment instead of adding a segment of its
    -- own: the wrapper works in words, so a lone "*" becomes its own word and
    -- the bubble renders "...in the room *" with a gap before it.
    local lastSegment = segments[#segments]
    lastSegment.text = lastSegment.text .. "*"

    local _, _, _, chrome = bubbleTextLayout(nil, 0)
    local lines, maxWidth = wrapWidestFit(function(textAreaWidth)
        return MC_ChatPanel._wrapTextWithColors(segments, font, textAreaWidth)
    end, chrome)

    local firstChunks = lines[1] and lines[1].chunks
    local firstChunk = firstChunks and firstChunks[1]
    if firstChunk and firstChunk.text:sub(1, #decoratedName) == decoratedName then
        local remainder = firstChunk.text:sub(#decoratedName + 1)
        local replacement = {
            { text = "*", color = emoteColor, alpha = firstChunk.alpha },
            { text = displayName, color = nameColor, alpha = firstChunk.alpha },
        }
        if remainder ~= "" then
            replacement[#replacement + 1] = {
                text = remainder, color = firstChunk.color, alpha = firstChunk.alpha,
            }
        end
        table.remove(firstChunks, 1)
        for index = #replacement, 1, -1 do
            table.insert(firstChunks, 1, replacement[index])
        end
    end
    dbg("newEmote: %d lines at maxWidth=%d", #lines, maxWidth)

    if #lines == 0 then
        dbg("newEmote: no lines")
        return nil
    end

    local textWidth = 0
    local textManager = getTextManager()
    for _, lineData in ipairs(lines) do
        local lineWidth = 0
        for _, chunk in ipairs(lineData.chunks) do
            lineWidth = lineWidth + textManager:MeasureStringX(font, chunk.text)
        end
        if lineWidth > textWidth then textWidth = lineWidth end
    end

    local width = finishedBubbleWidth(textWidth, chrome, maxWidth)
    local height = math.max(MIN_SKIN_SIZE, #lines * lineHeight + padding * 2)
    
    local x, y = getScreenPosition(target, width, height, MC_Core.Display.BUBBLE_OFFSET_PLAYER)
    if not x then
        dbg("newEmote: no position")
        MC_Incident.report("BUBBLE_POSITION_UNAVAILABLE",
            "emote bubble suppressed before creation")
        return nil
    end
    
    local o = ISUIElement:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.target = target
    o.offsetY = MC_Core.Display.BUBBLE_OFFSET_PLAYER
    o.style = MC_Config.Radio.speechBubbleStyle
    o.message = displayMessage
    o.channel = "emote"
    o.isEmote = true
    o.hideArrow = true
    o.textColor = channelColor("emote", {255, 190, 128})
    o.lines = lines
    o.font = font
    o.lineHeight = lineHeight
    o.padding = padding
    o.duration = getLiveBubbleDuration()
    o.opacity = MC_Config.Bubble.opacity
    o.startTime = MC_Core.getTimeMs()
    o.dead = false
    o.useAvatar = false
    o.avatarWidth = 0
    o.rimColor = validPlayerColor(playerColor)

    dbg("newEmote: created")
    
    return o
end

--[[
    Create a do/narration bubble
    @param narration  Narration text
    @param target     Player to follow
    @param playerColor Optional: authenticated, post-anonymity speaker RGB
    @return MC_Bubble instance or nil
]]
function MC_Bubble:newDo(narration, target, playerColor)
    dbg("newDo: %s", tostring(narration and narration:sub(1, 30) or "nil"))
    
    if not narration or narration == "" then
        dbg("newDo: empty narration")
        return nil
    end
    
    local font = MC_Theme.font("bubble", UIFont.Medium)
    local padding = BUBBLE_VERTICAL_PADDING
    local lineHeight = getTextManager():getFontHeight(font) + 2

    local baseColor = channelColor("do", {200, 180, 255})
    local emoteColor = channelColor("emote", {255, 190, 128})
    local moodColor = channelColor("mood", {180, 180, 200})
    
    -- Quoted words inside narration were spoken aloud, and take the say
    -- colour so they read as speech (see MC_Core.findQuotedRuns).
    local segments = MC_Core.parseColorSegments(narration, baseColor, false,
        emoteColor, moodColor, channelColor("say", {255, 255, 255}))
    local _, _, _, chrome = bubbleTextLayout(nil, 0)
    local wrappedLines, maxWidth = wrapWidestFit(function(textAreaWidth)
        return MC_ChatPanel._wrapTextWithColors(segments, font, textAreaWidth)
    end, chrome)
    dbg("newDo: %d lines at maxWidth=%d", #wrappedLines, maxWidth)
    
    if #wrappedLines == 0 then
        dbg("newDo: no lines")
        return nil
    end
    
    local textWidth = 0
    local textManager = getTextManager()
    for _, lineData in ipairs(wrappedLines) do
        local lineWidth = 0
        for _, chunk in ipairs(lineData.chunks) do
            lineWidth = lineWidth + textManager:MeasureStringX(font, chunk.text)
        end
        if lineWidth > textWidth then textWidth = lineWidth end
    end
    
    local width = finishedBubbleWidth(textWidth, chrome, maxWidth)
    local height = math.max(MIN_SKIN_SIZE, #wrappedLines * lineHeight + padding * 2)
    
    local x, y = getScreenPosition(target, width, height, MC_Core.Display.BUBBLE_OFFSET_PLAYER)
    if not x then
        dbg("newDo: no position")
        MC_Incident.report("BUBBLE_POSITION_UNAVAILABLE",
            "narration bubble suppressed before creation")
        return nil
    end
    
    local o = ISUIElement:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    
    o.target = target
    o.offsetY = MC_Core.Display.BUBBLE_OFFSET_PLAYER
    o.style = MC_Config.Radio.speechBubbleStyle
    o.message = narration
    o.channel = "do"
    o.isEmote = true
    o.hideArrow = true
    o.textColor = baseColor
    o.lines = wrappedLines
    o.font = font
    o.lineHeight = lineHeight
    o.padding = padding
    o.duration = getLiveBubbleDuration()
    o.opacity = MC_Config.Bubble.opacity
    o.startTime = MC_Core.getTimeMs()
    o.dead = false
    o.useAvatar = false
    o.avatarWidth = 0
    o.rimColor = validPlayerColor(playerColor)

    dbg("newDo: created")

    return o
end

-- Lore notes have no chat channel to take a colour from; a warm paper-ink
-- tone keeps them legible on the sign skin without reading as live speech.
local LORE_TEXT_COLOR = {235, 226, 200}

--[[
    Create a persistent lore-note bubble anchored to a ground position.
    Unlike every other constructor there is no duration: the bubble lives
    until its owner (MC_LoreNotes) removes it, and its alpha is driven
    externally through o.externalAlpha (the proximity fade) rather than by
    elapsed time -- see the persistent branch in :render().
    @param text    Note text, already normalized/clamped by the caller
    @param target  {x=, y=, z=} world position of the note's square
    @return MC_Bubble instance or nil
]]
function MC_Bubble:newLore(text, target)
    dbg("newLore: %s", tostring(text and text:sub(1, 30) or "nil"))

    if not text or text == "" then
        dbg("newLore: empty text")
        return nil
    end

    local font = MC_Theme.font("note", UIFont.Medium)
    local padding = BUBBLE_VERTICAL_PADDING
    local lineHeight = getTextManager():getFontHeight(font) + 2

    -- Player-authored note text renders literally: no parseColorSegments,
    -- so asterisks in a note stay asterisks instead of becoming emote/mood
    -- colour runs. One plain segment in the same shape the parser returns.
    local segments = { { text = text, color = LORE_TEXT_COLOR } }
    local _, _, _, chrome = bubbleTextLayout(nil, 0)
    local wrappedLines, maxWidth = wrapWidestFit(function(textAreaWidth)
        return MC_ChatPanel._wrapTextWithColors(segments, font, textAreaWidth)
    end, chrome)
    dbg("newLore: %d lines at maxWidth=%d", #wrappedLines, maxWidth)

    if #wrappedLines == 0 then
        dbg("newLore: no lines")
        return nil
    end

    local textWidth = 0
    local textManager = getTextManager()
    for _, lineData in ipairs(wrappedLines) do
        local lineWidth = 0
        for _, chunk in ipairs(lineData.chunks) do
            lineWidth = lineWidth + textManager:MeasureStringX(font, chunk.text)
        end
        if lineWidth > textWidth then textWidth = lineWidth end
    end

    local width = finishedBubbleWidth(textWidth, chrome, maxWidth)
    local height = math.max(MIN_SKIN_SIZE, #wrappedLines * lineHeight + padding * 2)

    local x, y = getScreenPosition(target, width, height, MC_Core.Display.BUBBLE_OFFSET_GROUND)
    if not x then
        dbg("newLore: no position")
        MC_Incident.report("BUBBLE_POSITION_UNAVAILABLE",
            "lore bubble suppressed before creation")
        return nil
    end

    local o = ISUIElement:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.target = target
    o.offsetY = MC_Core.Display.BUBBLE_OFFSET_GROUND
    o.style = MC_Config.Bubble.signStyle
    o.message = text
    o.channel = "lore"
    o.hideArrow = true
    o.textColor = LORE_TEXT_COLOR
    o.lines = wrappedLines
    o.font = font
    o.lineHeight = lineHeight
    o.padding = padding
    o.persistent = true
    o.externalAlpha = 0
    o.opacity = MC_Config.Bubble.opacity
    o.skinAlphaScale = MC_Config.Bubble.signSkinAlphaScale
    o.startTime = MC_Core.getTimeMs()
    o.dead = false
    o.useAvatar = false
    o.avatarWidth = 0

    dbg("newLore: created")

    return o
end


return MC_Bubble
