--[[
================================================================================
    MongooseChat - Typing Indicator
    
    Animated dots above player head when typing.
    
    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Theme = require("MC_Theme")
local MC_Config = require("MC_Config")
local MC_Bio = require("MC_Bio")

local dbg = MC_Core.debugger("TYPING")

local MC_Typing = ISUIElement:derive("MC_Typing")

-- TEXTURE MANAGEMENT

local textures = nil

local function loadTextures()
    if textures then return textures end
    
    dbg("Loading typing textures")
    
    textures = {
        getTexture("media/ui/MongooseChat/typing-dots/typing-dots-1.png"),
        getTexture("media/ui/MongooseChat/typing-dots/typing-dots-2.png"),
        getTexture("media/ui/MongooseChat/typing-dots/typing-dots-3.png"),
    }
    
    dbg("Loaded: tex[1]=%s tex[2]=%s tex[3]=%s", 
        tostring(textures[1]), tostring(textures[2]), tostring(textures[3]))
    
    return textures
end

-- POSITIONING

-- Get screen position above player's head. Thin wrapper over the shared
-- projection math (MC_Bio._screenPosition) -- height=0 because the typing
-- indicator anchors by its own top edge, not above the target like a
-- bubble/nameplate, and TYPING_OFFSET_Y stands in for the fixed yAdjust
-- nudge those use.
local function getScreenPosition(player)
    return MC_Bio._screenPosition(player, MC_Core.Display.TYPING_WIDTH, 0,
        MC_Core.Display.BUBBLE_OFFSET_PLAYER, MC_Core.Display.TYPING_OFFSET_Y)
end

-- UI ELEMENT METHODS

function MC_Typing:initialise()
    ISUIElement.initialise(self)
end

-- MOUSE PASSTHROUGH
-- Typing indicators must not intercept clicks
function MC_Typing:onMouseDown(x, y)
    return false
end

function MC_Typing:onMouseUp(x, y)
    return false
end

function MC_Typing:onRightMouseDown(x, y)
    return false
end

function MC_Typing:onRightMouseUp(x, y)
    return false
end

function MC_Typing:isMouseOver()
    return false
end

function MC_Typing:prerender()
    -- Update position to follow player
    if self.player then
        local x, y = getScreenPosition(self.player)
        if x and y then
            self:setX(x)
            self:setY(y)
        end
    end
end

function MC_Typing:render()
    if self.dead then return end
    
    local tex = loadTextures()
    local highContrast = MC_Theme.access().highContrast == true
    if not highContrast and not tex[1] then return end
    
    local now = MC_Core.getTimeMs()
    
    -- Check timeout
    if now - self.startTime > self.timeout then
        self.dead = true
        return
    end
    
    -- Typing dots setting: Off hides them entirely; Still, or reduced
    -- motion, holds the middle frame -- still says "typing", never
    -- flickers.
    local mode = MC_Theme.access().typingDots or "on"
    if mode == "off" then
        self.dead = true
        return
    end
    if mode == "still" or MC_Theme.fadeMs() <= 0 then
        self.step = 2
    else
        local elapsed = now - self.lastStepTime
        if elapsed >= self.stepTime then
            self.lastStepTime = now
            self.step = (self.step % 3) + 1
        end
    end
    
    -- The source PNG has shaded pixels.  A white tint cannot make those pixels
    -- meet a measured contrast target, so high contrast draws its own opaque
    -- backing and bright dot marks for each of the same three frames.
    if highContrast then
        local w, h = MC_Core.Display.TYPING_WIDTH, MC_Core.Display.TYPING_HEIGHT
        self:drawRect(0, 0, w, h, 1, 0, 0, 0)
        local bright = MC_Theme.readableColor({ 255, 255, 255 })
        local levels = {
            { 2, 1, 1 },
            { 1, 2, 1 },
            { 1, 1, 2 },
        }
        local cy = math.floor(h / 2) - 1
        local gap = math.max(1, math.floor((w - 9) / 4))
        for i = 1, 3 do
            local size = levels[self.step][i] + 1
            local x = gap * i + (i - 1) * 3
            self:drawRect(x, cy - math.floor((size - 2) / 2), size, size,
                1, bright[1] / 255, bright[2] / 255, bright[3] / 255)
        end
    else
        self:drawTexture(tex[self.step], 0, 0, 1, 1, 1, 1)
    end
end

-- PUBLIC INTERFACE

--[[
    Refresh the timeout (called when new typing packet arrives)
    Keeps the indicator visible while player continues typing
]]
function MC_Typing:refresh()
    self.startTime = MC_Core.getTimeMs()
end

--[[
    Create a new typing indicator
    
    @param player  The player who is typing
    @param timeout Seconds before indicator disappears (default 3)
    @return MC_Typing instance
]]
function MC_Typing:new(player, timeout)
    local x, y = getScreenPosition(player)
    if not x then x, y = 0, 0 end
    
    local o = ISUIElement:new(x, y, MC_Core.Display.TYPING_WIDTH, MC_Core.Display.TYPING_HEIGHT)
    setmetatable(o, self)
    self.__index = self
    
    local now = MC_Core.getTimeMs()
    
    o.player = player
    o.startTime = now
    o.lastStepTime = now
    o.stepTime = 250      -- Animation speed (ms per frame)
    o.step = 1
    o.timeout = (timeout or 3) * 1000
    o.dead = false
    
    return o
end


return MC_Typing
