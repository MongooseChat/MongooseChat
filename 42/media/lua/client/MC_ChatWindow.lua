--[[
================================================================================
    MongooseChat - Chat Window

    Our own chat window. Replaces the vanilla ISChat frame outright rather
    than living inside it as a child panel.

    WHY THIS EXISTS:
    MongooseChat already owned everything *inside* the vanilla window --
    the transcript, the wrapping, the measurement, the scrollbar -- and
    suppressed nearly every vanilla line on the way in. What it did not own
    was the frame and the tab bar, which is where all the friction was:
    vanilla's internal borders clipped our content (the 12px padding guess
    in MC_ChatPanel), the tab strip could not be extended without injecting
    into ISChat.panel.viewList, and every per-widget hook died whenever
    vanilla recreated its text entry.

    Owning the window makes those problems stop existing instead of being
    worked around. Vanilla ISChat stays alive but hidden: it remains the
    Admin pipe and the server-welcome path.

    ACCESSIBILITY (standing rule for all MongooseChat UI):
    - Colour is never the only carrier of meaning. Unread tabs show a
      DIGIT, not a bare coloured dot.
    - Font size has five steps, ours, independent of vanilla's three --
      but defaults to following the vanilla preference so nothing changes
      for a player who never opens our options.
    - Background opacity and a high-contrast mode are separate controls,
      because "hard to read" and "too busy behind the text" are different
      complaints with different fixes.
    - Line spacing is adjustable for dyslexia; text is left-aligned and
      never justified.
    - Tab hit areas are at least TAB_MIN_HEIGHT tall with padding. Nothing
      here needs a double-click, a drag, or a precise hover.
    - Reduced motion is honoured by callers that animate.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Config = require("MC_Config")
local MC_ChatPanel = require("MC_ChatPanel")
local MC_Incident = require("MC_Incident")
local MC_Theme = require("MC_Theme")
local MC_Options = require("MC_Options")
local MC_IdentityColor = require("MC_IdentityColor")
local MC_StringUtils = require("MC_StringUtils")
local MC_QuickMenu = require("MC_QuickMenu")

local dbg = MC_Core.debugger("WINDOW")

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

local function savedRGBA(value, fallback)
    if type(value) ~= "table" then return fallback end
    return { r=tonumber(value.r) or fallback.r, g=tonumber(value.g) or fallback.g,
        b=tonumber(value.b) or fallback.b, a=tonumber(value.a) or fallback.a }
end

local function armFreshInput(entry)
    local ok, input = pcall(require, "MC_Input")
    if ok and input and type(input.armFreshFocus) == "function" then
        local armed = pcall(input.armFreshFocus, entry)
        if armed then return true end
    end
    MC_Incident.report("CHAT_INPUT_HOOK_UNAVAILABLE",
        "fresh-focus input seam unavailable")
    return false
end

local function disarmFreshInput(entry)
    local ok, input = pcall(require, "MC_Input")
    if ok and input and type(input.disarmFreshFocus) == "function" then
        return pcall(input.disarmFreshFocus, entry)
    end
    return false
end

-- BASE CLASS
--
-- ISCollapsableWindow is a vanilla class we do not own. If a build (or an
-- offline test harness) does not expose it, MongooseChat must still LOAD --
-- a nil-index here would take the whole client down over a chat frame.
-- The module degrades instead: it marks itself unavailable, create()
-- reports and returns nil, and MC_Client keeps the vanilla chat window.

local windowBase = ISCollapsableWindow

local MC_ChatWindow
if windowBase and type(windowBase.derive) == "function" then
    MC_ChatWindow = windowBase:derive("MC_ChatWindow")
else
    MC_ChatWindow = {}
    MC_ChatWindow.__index = MC_ChatWindow
    MC_ChatWindow.unavailable = true
end

-- Chain to the base implementation when there is one. Every call site is
-- optional by design: the fallback path has no vanilla behaviour to chain.
local function baseCall(name, ...)
    if not windowBase then return end
    local fn = windowBase[name]
    if type(fn) ~= "function" then return end
    return fn(...)
end

-- LAYOUT CONSTANTS

-- Motor accessibility: a tab must be comfortably clickable without a
-- steady hand. 24px is the smallest target that stays reliable at 1080p.
local M = MC_Theme.Metrics
-- The three two-pixel edge bands need a full six-pixel quiet area. 30px keeps
-- the centred label clear of that rim at every shipped font step.
local TAB_MIN_HEIGHT = math.max(30, M.tabH)
local TAB_PAD_X = M.tabPadX
local TAB_GAP = M.tabGap
local ENTRY_HEIGHT = M.entryH

-- B42's ISTextEntryBox:setEditable(true) turns its Lua border back on even
-- when the Java text box frame was disabled.  Keep both frame paths off; the
-- window draws the owned well and rim around this native control itself.
local function makeEntryFrameless(entry)
    if not entry then return end
    pcall(function() entry:setHasFrame(false) end)
    entry.borderColor = entry.borderColor or { r = 1, g = 1, b = 1, a = 0 }
    entry.borderColor.a = 0
end
local EDGE = M.edge

local DEFAULT_W = 520
local DEFAULT_H = 300
-- These are only boot fallbacks.  The real minimum is measured from the
-- live tab/control labels and transcript metrics by refreshMinimumSize().
local MIN_W = 260
local MIN_H = 160
local GRIP_SIZE = 18
local GRIP_GUTTER = 2
local ENTRY_TEXT_INSET = 4
-- Font-independent quiet controls. Their marks are small; their motor targets
-- stay as tall as the rest of the tab strip.
local LOCK_CONTROL_WIDTH = 30

-- Our own five-step ladder. Vanilla offers three; low-vision players need
-- more headroom than "large".
local FONT_STEPS = { "small", "medium", "large", "larger", "largest" }

-- ACCESSIBILITY PREFERENCES (per character, client-side)
--
-- These are the player's own comfort settings, so they live in character
-- ModData -- not sandbox options, which are the operator's to set. An
-- unreadable store falls back to defaults and reports once; comfort
-- settings must never be able to break the chat window.

-- One source of defaults: the Options page's SPEC (MC_Options.defaults()).
-- The ModData fallback below merges onto these when the page is absent.
local ACCESS_DEFAULTS = MC_Options.defaults()

local access = nil
local accessStoreRef = nil

local function accessStore()
    local ok, md = pcall(function()
        local p = getSpecificPlayer(0)
        if not p then return nil end
        local data = p:getModData()
        if type(data) ~= "table" then return nil end
        if type(data.MC_Access) ~= "table" then data.MC_Access = {} end
        return data.MC_Access
    end)
    if not ok then return nil end
    return md
end

function MC_ChatWindow.getAccess()
    -- The Options page is the store of record when it exists (settings
    -- belong to the human, not the character). ModData remains only as
    -- the fallback for a build without PZAPI.
    if MC_Options.available() then
        local a = MC_Options.access()
        for k, v in pairs(ACCESS_DEFAULTS) do
            if a[k] == nil then a[k] = v end
        end
        return a
    end

    local store = accessStore()
    if access and store and accessStoreRef == store then return access end
    access = {}
    for k, v in pairs(ACCESS_DEFAULTS) do access[k] = v end
    accessStoreRef = store
    if store then
        MC_Options.resetFallback(store)
        for k, v in pairs(ACCESS_DEFAULTS) do
            local stored = store[k]
            if type(stored) == type(v) then access[k] = stored end
        end
    else
        MC_Incident.report("CHAT_ACCESS_PREFS_UNREADABLE",
            "accessibility preferences unreadable; defaults kept")
    end
    return access
end

-- The shared theme cannot require this client-only module, so it asks
-- through a provider. Registered at load: from here on every colour read
-- anywhere in the mod honours the player's access mode.
MC_Theme.setAccessProvider(function() return MC_ChatWindow.getAccess() end)

-- The personal rim is identity, not a channel or a grant. It appears only
-- after the server has confirmed this account's colour, and colour-free mode
-- removes it. A missing or malformed sync therefore leaves the fixed chalk
-- frame alone rather than guessing from a name.
local function identityRimColor()
    if MC_ChatWindow.getAccess().tagsOnly then return nil end
    return MC_IdentityColor.currentColor()
end
MC_ChatWindow._identityRimColor = identityRimColor

-- Access keys a UI element may flip directly, mapped to their option id.
local OPTION_ID_FOR = { locked = "locked" }

-- Settings changed on the Options screen reach the live window at once.
MC_Options.onApply(function()
    if MC_ChatWindow.instance then MC_ChatWindow.instance:applyAccess() end
end)

function MC_ChatWindow.setAccess(key, value)
    if ACCESS_DEFAULTS[key] == nil then return false end
    if type(value) ~= type(ACCESS_DEFAULTS[key]) then return false end
    if MC_Options.available() and OPTION_ID_FOR[key] then
        return MC_Options.set(OPTION_ID_FOR[key], value)
    end
    local a = MC_ChatWindow.getAccess()
    a[key] = value
    local store = accessStore()
    if store then store[key] = value end
    if MC_ChatWindow.instance then
        MC_ChatWindow.instance:applyAccess()
    end
    return true
end

-- TABS
--
-- Names are words, not icons, and not colours. A player who cannot
-- distinguish our channel hues can still read which tab they are on.

local TABS = {
    { id = MC_ChatPanel.TAB_LOCAL, label = "Local", tip = "Nearby chat, including OOC" },
    { id = MC_ChatPanel.TAB_OOC,   label = "OOC",   tip = "Nearby out-of-character only" },
    { id = MC_ChatPanel.TAB_RADIO, label = "Radio", tip = "Radio traffic" },
    { id = MC_ChatPanel.TAB_ADMIN, label = "Admin", tip = "Staff channel (the game's own)" },
}

-- Only a player the ENGINE actually gave vanilla's Admin tab to gets ours.
--
-- Vanilla builds its tabs from ISChat.onTabAdded, which the engine calls
-- once per tab THIS player is entitled to; the admin stream
-- (allChatStreams[7], tabID 2) therefore lands in a tab that simply does
-- not exist for an ordinary player. So "does vanilla have a verified admin
-- view" IS the access check, straight from the engine -- there is no
-- getAccessLevel string ladder to guess at. (An earlier attempt gated on
-- getAccessLevel() ~= "None" and showed the tab to everyone: B42 answers
-- that with a role word, not "None", for an ordinary player.)
--
-- MC_Client publishes the answer -- it is the only module allowed to touch
-- ISChat -- and refreshes it every tick. Absent or false means no tab:
-- uncertainty must never open a doorway to the admin surface.
MC_ChatWindow.adminAvailable = false

local function localPlayerIsStaff()
    return MC_ChatWindow.adminAvailable == true
end

-- The tab strip THIS player actually gets: every tab, minus Admin for
-- non-staff. Everything that walks tabs (layout, cycling, clicks via
-- tabRects) goes through this one filter.
local function visibleTabs()
    local staff = localPlayerIsStaff()
    local tabs = {}
    for _, tab in ipairs(TABS) do
        local enabled = true
        if tab.id == MC_ChatPanel.TAB_RADIO then
            enabled = MC_Config.featureOn("RadioEnabled")
        elseif tab.id == MC_ChatPanel.TAB_OOC then
            enabled = MC_Config.optionalOn("OOCEnabled",
                not (MC_Config.Channels and MC_Config.Channels.oocEnabled == false))
        elseif tab.id == MC_ChatPanel.TAB_ADMIN then
            enabled = staff
        end
        if enabled then
            table.insert(tabs, tab)
        end
    end
    return tabs, staff
end

MC_ChatWindow._visibleTabsForTest = visibleTabs

-- Hover tips: one short line, shown after a brief hold so they never
-- flicker while the mouse crosses the strip.
local TIP_DELAY_MS = 350
local SEND_SPARK_MS = 700
local INK_MARK_MS = 500

local function nowMs(previous)
    local value = MC_Core.getTimeMs()
    if type(value) ~= "number" or value ~= value
        or value <= -math.huge or value >= math.huge then
        return previous or 0
    end
    if previous and value < previous then return previous end
    return value
end

local function validRgb(value)
    if type(value) ~= "table" then return nil end
    local out = {}
    for i = 1, 3 do
        local n = value[i]
        if type(n) ~= "number" or n ~= n or n < 0 or n > 255 then return nil end
        out[i] = math.floor(n + 0.5)
    end
    return out
end

local function drawExactEdge(win, prefix, x, y, w, h, alpha, now, kind)
    MC_Theme.drawSliceEdge(win, "window", prefix,
        x, y, w, h, alpha, now, kind, nil, nil, nil, true)
end

local function installOwnLineEffects(win)
    MC_ChatPanel.windowVisibleProvider = function()
        local target = MC_ChatWindow.instance
        if not target then return false end
        local ok, visible = pcall(function() return target:getIsVisible() end)
        return ok and visible == true
    end
    MC_ChatPanel.onOwnLineRendered = function(color)
        local target = MC_ChatWindow.instance
        local ink = validRgb(color)
        if not target or not ink then return end
        local a = MC_ChatWindow.getAccess()
        local now = nowMs(target.effectClock)
        target.effectClock = now
        if a.tagsOnly then
            target.inkColor, target.inkUntil = nil, nil
        else
            target.inkColor, target.inkUntil = ink, now + INK_MARK_MS
        end
        if a.reducedMotion then
            target.sparkStarted, target.sparkUntil = nil, nil
        else
            target.sparkStarted, target.sparkUntil = now, now + SEND_SPARK_MS
        end
    end
    MC_ChatPanel.onSessionReset = function()
        local target = MC_ChatWindow.instance
        if not target then return end
        target.drafts = {}
        if target.entry then pcall(function() target.entry:setText("") end) end
        target.inkColor, target.inkUntil = nil, nil
        target.sparkStarted, target.sparkUntil = nil, nil
    end
    MC_ChatWindow.instance = win
end

MC_ChatWindow._installOwnLineEffects = installOwnLineEffects

-- ART
--
-- Every surface is a 9-slice from MC_Theme (Chalk on Slate). The active
-- tab set has no bottom row: drawn after the frame, its open bottom covers
-- the rim beneath it and the tab reads as cut into the frame.

local function art()
    local frame, okF = MC_Theme.textures("window", "frame")
    local tabOn, okT = MC_Theme.textures("window", "tab-active")
    local tabOff = MC_Theme.textures("window", "tab-idle")
    local well = MC_Theme.textures("window", "well")
    if not okF or not okT then
        MC_Incident.report("CHAT_WINDOW_ART_UNAVAILABLE",
            "window textures missing; drawing plain slate")
    end
    return { frame = frame, tabOn = tabOn, tabOff = tabOff, well = well }
end

-- FONT

local function uiFontFor(name)
    if not UIFont then return nil end
    local map = {
        small   = UIFont.Small,
        medium  = UIFont.Medium,
        large   = UIFont.Large,
        larger  = UIFont.Large,
        largest = UIFont.Large,
    }
    -- Some builds ship the bigger faces; prefer them when present so the
    -- top two steps are genuinely larger rather than duplicates of Large.
    if UIFont.Massive then map.largest = UIFont.Massive end
    if UIFont.Title then map.larger = UIFont.Title end
    return map[name]
end

-- CONSTRUCTION

function MC_ChatWindow:new(x, y, width, height)
    if MC_ChatWindow.unavailable then return nil end

    local o = windowBase:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.title = "MongooseChat"
    o.resizable = true
    -- No vanilla title bar. The base class would paint its grey strip,
    -- centred title and border; with drawFrame off it paints nothing and
    -- our tab strip is the whole top edge -- and the drag handle.
    o.drawFrame = false
    o.anchorLeft = true
    o.anchorTop = true
    o.anchorRight = false
    o.anchorBottom = false
    o.minimumWidth = MIN_W
    o.minimumHeight = MIN_H
    o.activeTab = MC_ChatPanel.TAB_LOCAL
    o.tabRects = {}
    o.drafts = {}
    return o
end

-- Vanilla calls this method while building its native resize hit targets.
function MC_ChatWindow:resizeWidgetHeight()
    return GRIP_SIZE
end

function MC_ChatWindow:createChildren()
    baseCall("createChildren", self)

    -- Keep the real native resize target, but make it match the pad we draw.
    -- The second vanilla widget is a full-width bottom strip; it has no place
    -- in this borderless window and would steal clicks from the entry well.
    if self.resizeWidget then
        pcall(function()
            self.resizeWidget:setX(self.width - GRIP_SIZE)
            self.resizeWidget:setY(self.height - GRIP_SIZE)
            self.resizeWidget:setWidth(GRIP_SIZE)
            self.resizeWidget:setHeight(GRIP_SIZE)
        end)
    end
    if self.resizeWidget2 then
        pcall(function() self.resizeWidget2:setVisible(false) end)
    end

    -- The base class adds close / collapse / pin buttons for its title
    -- bar. We have no title bar; hide them rather than leave three
    -- invisible hit targets in our tab strip.
    for _, name in ipairs({ "closeButton", "collapseButton", "pinButton" }) do
        local b = self[name]
        if b then pcall(function() b:setVisible(false) end) end
    end

    local top = self:titleBarHeightSafe()
    local tabH = self:tabStripHeight()

    local frameY = top + tabH - TAB_GAP
    local panelY = frameY + EDGE
    local entryY = self.height - ENTRY_HEIGHT - EDGE
    local panelH = (entryY - EDGE) - panelY

    self.chatPanel = MC_ChatPanel:new(EDGE, panelY, self.width - EDGE * 2,
        math.max(20, panelH))
    self.chatPanel:initialise()
    self.chatPanel:setAnchorLeft(true)
    self.chatPanel:setAnchorRight(true)
    self.chatPanel:setAnchorTop(true)
    self.chatPanel:setAnchorBottom(true)
    -- The window paints its own background; a second translucent panel on
    -- top of it would double-darken and defeat the opacity setting.
    self.chatPanel.background = false
    self:addChild(self.chatPanel)

    -- Built the way vanilla ISChat builds its own (ISChat.lua createChildren):
    -- font before initialise, instantiate, anchors, frame, single line.
    -- Only methods ISTextEntryBox actually has on B42 are called here; the
    -- first cut invented one and threw on every tick.
    self.entry = ISTextEntryBox:new("", EDGE + ENTRY_TEXT_INSET,
        self.height - ENTRY_HEIGHT - EDGE,
        self.width - EDGE * 2 - ENTRY_TEXT_INSET, ENTRY_HEIGHT)
    self.entry.font = UIFont.Medium
    self.entry:initialise()
    self.entry:instantiate()
    self.entry.mcNormalTextRGBA = savedRGBA(self.entry.textColor,
        {r=1,g=1,b=1,a=1})
    self.entry.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self.entry.borderColor = { r = 1, g = 1, b = 1, a = 0 }
    self.entry:setAnchorLeft(true)
    self.entry:setAnchorRight(true)
    self.entry:setAnchorTop(false)
    self.entry:setAnchorBottom(true)
    makeEntryFrameless(self.entry)
    pcall(function() self.entry:setMaxLines(1) end)
    -- The engine drops a text box's focus on click unless its UI name is
    -- exactly vanilla's chat entry name (see the comment in ISChat.lua's
    -- createChildren). Ours borrows it for the same reason.
    pcall(function()
        self.entry:setUIName((ISChat and ISChat.textEntryName) or "chat text entry")
    end)
    local maxLen = 1000
    pcall(function()
        maxLen = MC_Config.liveSandbox("MaxMessageLength", 1000)
    end)
    pcall(function() self.entry:setMaxTextLength(maxLen) end)

    local window = self
    self.entry.onCommandEntered = function(entryBox)
        window:onSubmit(entryBox)
    end
    self:addChild(self.entry)

    self:applyAccess()
    -- The panel proves that an accepted own primary line reached its real
    -- renderer. Effects begin here, never merely because Enter was pressed.
    installOwnLineEffects(self)
end

-- ISCollapsableWindow exposes titleBarHeight() on every build we support,
-- but it is a method call on a vanilla class we do not own -- fail to a
-- sane constant rather than to a crashed chat window.
function MC_ChatWindow:titleBarHeightSafe()
    return 0
end

-- The base class asks this for collapse and view maths. We have no title
-- bar, so the honest answer is zero.
function MC_ChatWindow:titleBarHeight()
    return 0
end

function MC_ChatWindow:tabStripHeight()
    local a = MC_ChatWindow.getAccess()
    local font = self.tabFont or UIFont.Small
    local ok, fh = pcall(function() return getTextManager():getFontHeight(font) end)
    local textH = (ok and type(fh) == "number") and fh or 12
    -- Reserve the inter-strip gap after the hit skin, rather than shaving it
    -- from the skin: every actual tab/control remains at least 30px high.
    return math.max(TAB_MIN_HEIGHT, textH + 8) + TAB_GAP + a.lineSpacing
end

local function measuredWidth(tm, font, text, fallback)
    local ok, width = pcall(function() return tm:MeasureStringX(font, text) end)
    if ok and type(width) == "number" and width >= 0 then return width end
    return fallback or 40
end

local function screenSize()
    local sw, sh = 1024, 768
    pcall(function()
        local core = getCore()
        sw = tonumber(core:getScreenWidth()) or sw
        sh = tonumber(core:getScreenHeight()) or sh
    end)
    return math.max(1, sw), math.max(1, sh)
end

-- Derive the resize floor from what is really on screen.  The old 260x160
-- constants could restore a legal but unusable rectangle: tabs collided with
-- Options/Lock, Admin vanished under them, and the transcript had no rows.
-- A compact signature makes this safe to call from prerender; no UI setter is
-- touched until a font, access state, label, screen, or panel metric changes.
function MC_ChatWindow:refreshMinimumSize(force)
    local tm = getTextManager()
    local font = self.tabFont or (UIFont and UIFont.Small) or nil
    local access = MC_ChatWindow.getAccess()
    local tabs, staff = visibleTabs()
    local tabWidth = 0
    local labels = {}
    local tabPadX = MC_Theme.tabPadX()
    for i, tab in ipairs(tabs) do
        local label = self:tabLabelFor(tab)
        labels[#labels + 1] = label
        tabWidth = tabWidth + measuredWidth(tm, font, label, 40) + tabPadX * 2
        if i > 1 then tabWidth = tabWidth + TAB_GAP end
    end

    local lockWidth = LOCK_CONTROL_WIDTH
    local closeWidth = measuredWidth(tm, font, "X", 8) + tabPadX * 2
    local controlsWidth = closeWidth + TAB_GAP + lockWidth
    local options = MC_Options.available()
    if options then
        controlsWidth = controlsWidth + TAB_GAP
            + measuredWidth(tm, font, "Options", 44) + tabPadX * 2
    end
    local groupGap = math.max(8, TAB_GAP)
    local wantedW = math.ceil(EDGE * 2 + tabWidth + groupGap + controlsWidth)

    local lineHeight = (self.chatPanel and tonumber(self.chatPanel.lineHeight)) or 16
    local margin = (self.chatPanel and tonumber(self.chatPanel.margin))
        or tonumber(MC_Config.Panel.margin) or 4
    local tabH = self:tabStripHeight()
    local sw, sh = screenSize()
    local fixedH = tabH - TAB_GAP + ENTRY_HEIGHT + EDGE * 3 + margin * 2
    local rows = 5
    if fixedH + rows * lineHeight > sh then rows = 3 end
    local wantedH = math.ceil(fixedH + rows * lineHeight)
    wantedW = math.min(wantedW, sw)
    wantedH = math.min(wantedH, sh)

    local signature = table.concat({ tostring(wantedW), tostring(wantedH),
        tostring(staff), tostring(options), tostring(access.locked),
        tostring(access.lineSpacing), tostring(lineHeight), tostring(sw), tostring(sh),
        table.concat(labels, "|") }, ":")
    if not force and signature == self.minimumSignature then return false end
    self.minimumSignature = signature
    self.minimumWidth = wantedW
    self.minimumHeight = wantedH

    if self.width < wantedW then self:setWidth(wantedW) end
    if self.height < wantedH then self:setHeight(wantedH) end
    local x, y = tonumber(self.x) or 0, tonumber(self.y) or 0
    local maxX = math.max(0, sw - self.width)
    local maxY = math.max(0, sh - self.height)
    if x < 0 or x > maxX then self:setX(math.max(0, math.min(x, maxX))) end
    if y < 0 or y > maxY then self:setY(math.max(0, math.min(y, maxY))) end
    return true
end

-- ACCESSIBILITY APPLICATION

function MC_ChatWindow:applyAccess()
    local a = MC_ChatWindow.getAccess()

    self.tabFont = UIFont and UIFont.Small or nil

    -- The transcript's face and line height are the panel's own business
    -- (MC_ChatPanel reads MC_Theme.font every frame); nothing to push here.

    -- Locked: the resize corner disappears with the drag. Unlocked: it is
    -- back, provided the window is resizable at all.
    if self.resizeWidget then
        pcall(function() self.resizeWidget:setVisible(self.resizable and not a.locked) end)
    end
    if self.resizeWidget2 then
        pcall(function() self.resizeWidget2:setVisible(false) end)
    end

    if self.entry then
        pcall(function()
            self.entry:setPlaceholderText(a.placeholder and "Type here, / for commands" or "")
            local placeholder = readable(MC_Theme.Channels.low)
            if type(self.entry.setTextRGBA) == "function" then
                if a.highContrast then
                    local textColor = readable(MC_Theme.Channels.say)
                    self.entry:setTextRGBA(textColor[1]/255, textColor[2]/255,
                        textColor[3]/255, 1)
                elseif self.entry.mcNormalTextRGBA then
                    local c = self.entry.mcNormalTextRGBA
                    self.entry:setTextRGBA(c.r, c.g, c.b, c.a)
                end
            end
            if type(self.entry.setPlaceholderTextRGBA) == "function" then
                self.entry:setPlaceholderTextRGBA(placeholder[1]/255,
                    placeholder[2]/255, placeholder[3]/255, readableAlpha(0.8))
            end
        end)
    end

    if self.chatPanel then
        self.chatPanel.mcOverrideFont = not a.followVanillaFont
        self.chatPanel.mcLineSpacing = a.lineSpacing
        self.chatPanel.mcMessageGap = a.messageGap
    end

    self:refreshMinimumSize(true)
    self:relayout()
end

function MC_ChatWindow:relayout()
    if not self.chatPanel or not self.entry then return end

    local top = self:titleBarHeightSafe()
    local tabH = self:tabStripHeight()
    local frameY = top + tabH - TAB_GAP
    local panelY = frameY + EDGE
    local entryY = self.height - ENTRY_HEIGHT - EDGE
    local panelH = (entryY - EDGE) - panelY

    self.chatPanel:setX(EDGE)
    self.chatPanel:setY(panelY)
    self.chatPanel:setWidth(math.max(40, self.width - EDGE * 2))
    self.chatPanel:setHeight(math.max(20, panelH))

    self.entry:setX(EDGE + ENTRY_TEXT_INSET)
    self.entry:setY(entryY)
    -- The entry stops before the 18px resize pad. The small clear gutter keeps
    -- the native hit target from ever sitting on typed text.
    self.entry:setWidth(math.max(40,
        self.width - EDGE * 2 - GRIP_SIZE - GRIP_GUTTER - ENTRY_TEXT_INSET))
    self.entry:setHeight(ENTRY_HEIGHT)
    -- Native layout/anchor work may rebuild the Java text box frame.  The
    -- surrounding well is ours, so restore the child to paint-only text.
    makeEntryFrameless(self.entry)
    if self.resizeWidget then
        pcall(function()
            self.resizeWidget:setX(self.width - GRIP_SIZE)
            self.resizeWidget:setY(self.height - GRIP_SIZE)
            self.resizeWidget:setWidth(GRIP_SIZE)
            self.resizeWidget:setHeight(GRIP_SIZE)
        end)
    end
    if self.resizeWidget2 then
        pcall(function() self.resizeWidget2:setVisible(false) end)
    end
end

-- TABS

function MC_ChatWindow:tabLabelFor(tab)
    local unread = MC_ChatPanel.getUnread(tab.id)
    if MC_ChatWindow.getAccess().unreadCounts == false then unread = 0 end
    if unread > 0 then
        -- A digit, not a dot: readable without colour vision, and it says
        -- how much is waiting rather than merely that something is.
        if unread > 99 then return tab.label .. " 99+" end
        return tab.label .. " " .. tostring(unread)
    end
    return tab.label
end

function MC_ChatWindow:layoutTabs()
    -- A live server switch must not leave the player parked on a tab that has
    -- just ceased to exist. Move to Local before rebuilding the hit targets.
    if self.activeTab == MC_ChatPanel.TAB_RADIO
        and not MC_Config.featureOn("RadioEnabled") then
        self:setActiveTab(MC_ChatPanel.TAB_LOCAL)
    elseif self.activeTab == MC_ChatPanel.TAB_OOC
        and not MC_Config.optionalOn("OOCEnabled",
            not (MC_Config.Channels and MC_Config.Channels.oocEnabled == false)) then
        self:setActiveTab(MC_ChatPanel.TAB_LOCAL)
    end

    local font = self.tabFont or UIFont.Small
    local tm = getTextManager()
    local x = EDGE
    local y = self:titleBarHeightSafe()
    local h = self:tabStripHeight() - TAB_GAP
    local tabPadX = MC_Theme.tabPadX()

    self.tabRects = {}
    local tabs, staff = visibleTabs()
    self.lastStaff = staff
    for _, tab in ipairs(tabs) do
        local label = self:tabLabelFor(tab)
        local okW, w = pcall(function() return tm:MeasureStringX(font, label) end)
        local textW = (okW and type(w) == "number") and w or 40
        local rectW = textW + tabPadX * 2
        table.insert(self.tabRects, {
            id = tab.id, label = label, name = tab.label, tip = tab.tip,
            x = x, y = y, w = rectW, h = h,
        })
        x = x + rectW + TAB_GAP
    end

    -- Font-independent lock mark, right-aligned on the strip. The full state
    -- and action remain in the tooltip; the drawn mark never changes layout.
    local locked = MC_ChatWindow.getAccess().locked
    local lockW = LOCK_CONTROL_WIDTH
    self.lockRect = { label = "lock", locked = locked,
        tip = locked and "Locked: unlock to allow drag and resize"
            or "Unlocked: lock to stop drag and resize",
        x = 0, y = y, w = lockW, h = h }

    -- One small owned close tab. It hides the shell only: the window, panel,
    -- history, and delivery path stay alive.
    local closeLabel = "X"
    local okC, cw = pcall(function() return tm:MeasureStringX(font, closeLabel) end)
    local closeW = ((okC and type(cw) == "number") and cw or 8) + tabPadX * 2
    self.closeRect = { label = closeLabel, tip = "Hide chat",
        x = self.width - EDGE - closeW, y = y, w = closeW, h = h }
    self.lockRect.x = self.closeRect.x - TAB_GAP - lockW

    -- Options word, left of Lock. Vanilla's gear went with its title bar;
    -- this is where a player bumps text size or flips timestamps without
    -- leaving the game. Only when the settings page exists to write to.
    self.optionsRect = nil
    if MC_Options.available() then
        local optLabel = "Options"
        local okO, ow = pcall(function() return tm:MeasureStringX(font, optLabel) end)
        local optW = ((okO and type(ow) == "number") and ow or 44) + tabPadX * 2
        self.optionsRect = { label = optLabel,
            tip = "Text size, colour, motion. Full page: Options > Mods > MongooseChat",
            x = self.lockRect.x - TAB_GAP - optW, y = y, w = optW, h = h }
    end
end

-- MC_Client installs these: it knows how to verify vanilla's Admin view and
-- is the only module allowed to touch ISChat. (window, entering) -> nil.
MC_ChatWindow.adminHandoff = nil

-- OUR box types on every tab, Admin included: 0.10.6 draws admin traffic
-- in our own panel, so no vanilla surface exists to hand input to.
function MC_ChatWindow:ownsInput()
    return true
end

function MC_ChatWindow:setActiveTab(tabId)
    if tabId ~= MC_ChatPanel.TAB_LOCAL and tabId ~= MC_ChatPanel.TAB_OOC
        and tabId ~= MC_ChatPanel.TAB_RADIO and tabId ~= MC_ChatPanel.TAB_ADMIN then
        return false
    end
    if tabId == MC_ChatPanel.TAB_ADMIN and not localPlayerIsStaff() then
        return false
    end
    if tabId == MC_ChatPanel.TAB_RADIO
        and not MC_Config.featureOn("RadioEnabled") then
        return false
    end
    if tabId == MC_ChatPanel.TAB_OOC
        and not MC_Config.optionalOn("OOCEnabled",
            not (MC_Config.Channels and MC_Config.Channels.oocEnabled == false)) then
        return false
    end
    self.drafts = self.drafts or {}
    if self.entry and self.activeTab then
        local old = ""
        pcall(function() old = self.entry:getText() or "" end)
        self.drafts[self.activeTab] = old
    end
    local wasAdmin = (self.activeTab == MC_ChatPanel.TAB_ADMIN)
    self.activeTab = tabId
    MC_ChatPanel.setCurrentTab(tabId)
    -- The Admin tab is vanilla's to render. Hide our transcript there and
    -- ask MC_Client to bring vanilla's Admin view up in our frame.
    -- Our transcript and our box serve every tab now, Admin included.
    local isAdmin = (tabId == MC_ChatPanel.TAB_ADMIN)
    if self.chatPanel then
        self.chatPanel:setVisible(true)
    end
    if self.entry then
        disarmFreshInput(self.entry)
        pcall(function() self.entry:setVisible(true) end)
        pcall(function()
            self.entry:setText(self.drafts[tabId] or "")
            self.entry.mcWholeLineSelected = false
            self.entry.mcNeedsSelectOnFocus = false
            if type(self.entry.setCursorPos) == "function" then
                self.entry:setCursorPos(MC_StringUtils.utf8len(self.entry:getText() or ""))
            end
        end)
    end
    if isAdmin ~= wasAdmin and type(MC_ChatWindow.adminHandoff) == "function" then
        pcall(MC_ChatWindow.adminHandoff, self, isAdmin)
    end
    return true
end

function MC_ChatWindow:enforceAdminEntitlement()
    if localPlayerIsStaff() then return false end
    self.drafts = self.drafts or {}
    self.drafts[MC_ChatPanel.TAB_ADMIN] = nil
    if type(MC_ChatPanel.clearTab) == "function" then
        pcall(MC_ChatPanel.clearTab, MC_ChatPanel.TAB_ADMIN)
    end
    if self.chatPanel and type(self.chatPanel.clearTab) == "function" then
        pcall(self.chatPanel.clearTab, self.chatPanel, MC_ChatPanel.TAB_ADMIN)
    end
    local moved = self.activeTab == MC_ChatPanel.TAB_ADMIN
    if moved then self:setActiveTab(MC_ChatPanel.TAB_LOCAL) end
    self.drafts[MC_ChatPanel.TAB_ADMIN] = nil
    return moved
end

local function hit(r, x, y)
    return r ~= nil and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

function MC_ChatWindow:onMouseDown(x, y)
    if hit(self.closeRect, x, y) then
        self:hideWindow()
        return true
    end
    for _, r in ipairs(self.tabRects or {}) do
        if hit(r, x, y) then
            self:setActiveTab(r.id)
            return true
        end
    end
    if hit(self.lockRect, x, y) then
        MC_ChatWindow.setAccess("locked", not MC_ChatWindow.getAccess().locked)
        return true
    end
    if hit(self.optionsRect, x, y) then
        if self.quickMenu then
            -- A second press is a true toggle. Close now so the matching
            -- mouse-up cannot replace the menu with a fresh instance.
            self.menuArmed = false
            MC_QuickMenu.closeOwner(self)
            return true
        end
        -- Open on mouse UP (vanilla's gear button is an ISButton, which
        -- fires on release): by then the press has finished raising the
        -- window, so the menu lands on top of it instead of under it.
        self.menuArmed = true
        return true
    end

    -- The base class starts a drag on ANY mouse-down. Only the tab strip
    -- is a handle here -- a click in the transcript must never move the
    -- window -- and a locked window has no handle at all.
    self:bringToTop()
    local a = MC_ChatWindow.getAccess()
    if not a.locked and y < self:tabStripHeight() then
        return baseCall("onMouseDown", self, x, y)
    end
    return true
end

function MC_ChatWindow:openQuickMenu()
    local r = self.optionsRect
    if not r then return end
    local ax, ay = 0, 0
    pcall(function() ax, ay = self:getAbsoluteX(), self:getAbsoluteY() end)
    local ok, menu = pcall(MC_QuickMenu.open, self,
        {x=ax+r.x, y=ay+r.y, w=r.w, h=r.h})
    if not ok then
        MC_Incident.report("CHAT_QUICK_MENU_FAILED", "quick menu could not open")
        dbg("openQuickMenu failed: %s", tostring(menu))
    end
end

function MC_ChatWindow:onMouseMove(dx, dy)
    local x, y = self:getMouseX(), self:getMouseY()
    local over = nil
    for _, r in ipairs(self.tabRects or {}) do
        if hit(r, x, y) then over = r break end
    end
    if not over and hit(self.lockRect, x, y) then over = self.lockRect end
    if not over and hit(self.optionsRect, x, y) then over = self.optionsRect end
    if not over and hit(self.closeRect, x, y) then over = self.closeRect end
    if over ~= self.hoverRect then
        self.hoverRect = over
        self.hoverSince = MC_Core.getTimeMs()
    end
    return baseCall("onMouseMove", self, dx, dy)
end

function MC_ChatWindow:onMouseMoveOutside(dx, dy)
    self.hoverRect = nil
    return baseCall("onMouseMoveOutside", self, dx, dy)
end

function MC_ChatWindow:onMouseUp(x, y)
    if self.menuArmed then
        self.menuArmed = false
        if hit(self.optionsRect, x, y) then
            if self.quickMenu then MC_QuickMenu.closeOwner(self)
            else self:openQuickMenu() end
        end
        return true
    end
    return baseCall("onMouseUp", self, x, y)
end

function MC_ChatWindow:onMouseUpOutside(x, y)
    self.menuArmed = false
    return baseCall("onMouseUpOutside", self, x, y)
end

-- INPUT

--[[
    Mirror of ISChat:focus for our own box: editable, focused, the toggle
    keystroke swallowed, and ISChat.focused raised -- other mods gate their
    keybinds on that flag, so while a player types in OUR box the world
    must see chat as focused exactly as it did with vanilla's.
]]
function MC_ChatWindow:focusInput(deferSelection)
    if not self.entry then return end
    local wasFocused = self:isInputFocused()
    if not wasFocused then self.mcMenuEscapeConsumed = nil end
    self:openWindow()
    self:bringToTop()
    local ok, err = pcall(function()
        self.entry:setEditable(true)
        self.entry:focus()
        self.entry:ignoreFirstInput()
        self.entry.mcWholeLineSelected = false
        self.entry.mcNeedsSelectOnFocus = not wasFocused
        if type(self.entry.setCursorPos) == "function" then
            local text = self.entry:getText() or ""
            self.entry:setCursorPos(MC_StringUtils.utf8len(text))
        end
        -- Both setEditable and focus may turn the native frame back on.
        -- Do this last while keeping the owned focused well visible.
        makeEntryFrameless(self.entry)
    end)
    if wasFocused then disarmFreshInput(self.entry) end
    if not deferSelection and self.entry.mcNeedsSelectOnFocus then
        local selected = false
        if MC_ChatWindow.getAccess().selectTextOnFocus ~= false
            and type(self.entry.mcSelectWholeLine) == "function" then
            local selectedOK, result = pcall(self.entry.mcSelectWholeLine, self.entry)
            selected = selectedOK and result == true
        end
        self.entry.mcNeedsSelectOnFocus = false
        self.entry.mcWholeLineSelected = selected
        armFreshInput(self.entry)
        if not selected and type(self.entry.setCursorPos) == "function" then
            pcall(self.entry.setCursorPos, self.entry,
                MC_StringUtils.utf8len(self.entry:getText() or ""))
        end
    end
    if ISChat then ISChat.focused = true end
end

-- Hide and open are state changes, not lifecycle changes.  No UI manager
-- removal occurs here, so inbound delivery and the full transcript persist.
function MC_ChatWindow:hideWindow()
    MC_QuickMenu.closeOwner(self)
    self:unfocusInput()
    -- A hidden window cannot still own a mature hover tip.  Clear both the
    -- target and its clock so reopening starts from a fresh mouse move.
    self.hoverRect = nil
    self.hoverSince = nil
    self:setVisible(false)
    return true
end

function MC_ChatWindow:openWindow()
    self:setVisible(true)
    makeEntryFrameless(self.entry)
    MC_ChatPanel.clearUnread(self.activeTab or MC_ChatPanel.TAB_LOCAL)
    return true
end

function MC_ChatWindow:unfocusInput()
    if not self.entry then return end
    pcall(function() self.entry:unfocus() end)
    makeEntryFrameless(self.entry)
    -- Plain blur keeps work. Explicit cancellation clears before reaching here.
    self.drafts = self.drafts or {}
    pcall(function() self.drafts[self.activeTab] = self.entry:getText() or "" end)
    if ISChat then ISChat.focused = false end
end

-- Capture the tab at the key event, not at the later native-safe blur tick.
-- A menu gets first claim on Escape even if its close callback ran first.
function MC_ChatWindow:captureInputCancellation(clearDraft)
    if not MC_Config.featureOn("ChatWindowEnabled")
        or MC_ChatWindow.getAccess().escapeCancelsFocus == false
        or self.quickMenu or self.mcMenuEscapeConsumed
        or not self:isInputFocused() or self.activeTab == nil then
        return nil
    end
    local ok, text = pcall(function() return self.entry:getText() or "" end)
    if not ok then return nil end
    return { window=self, entry=self.entry, tab=self.activeTab,
        text=text, clearDraft=clearDraft == true, consumed=false }
end

function MC_ChatWindow:applyInputCancellation(request)
    if type(request) ~= "table" or request.consumed then return false end
    request.consumed = true
    if request.window ~= self or request.entry ~= self.entry
        or (MC_ChatWindow.instance and MC_ChatWindow.instance ~= self)
        or not MC_Config.featureOn("ChatWindowEnabled")
        or MC_ChatWindow.getAccess().escapeCancelsFocus == false
        or self.quickMenu or self.mcMenuEscapeConsumed then
        return false
    end
    self.drafts = self.drafts or {}
    if self.activeTab ~= request.tab then
        -- A tab switch already saved the originating text. Never clear or
        -- blur the other tab that now shares this native entry box.
        if request.clearDraft and self.drafts[request.tab] == request.text then
            self.drafts[request.tab] = ""
        end
        return false
    end
    local readOK, text = pcall(function() return self.entry:getText() or "" end)
    if not readOK or text ~= request.text then return false end
    if request.clearDraft then
        disarmFreshInput(self.entry)
        self.entry.mcWholeLineSelected = false
        self.entry.mcNeedsSelectOnFocus = false
        local clearOK, empty = pcall(function()
            self.entry:setText("")
            return self.entry:getText() == ""
        end)
        if not clearOK or not empty then
            pcall(function() self.entry:setText(text) end)
            self.drafts[request.tab] = text
            MC_Incident.report("CHAT_INPUT_OPERATION_FAILED",
                "input clear failed; original draft retained")
            return false
        end
        self.drafts[request.tab] = ""
        if type(self.entry.setCursorPos) == "function" then
            pcall(self.entry.setCursorPos, self.entry, 0)
        end
    end
    self:unfocusInput()
    return true
end

-- Next tab along, wrapping. Bound to vanilla's "Switch chat stream" key.
function MC_ChatWindow:cycleTab(direction)
    -- Cycle over the VISIBLE strip only, so a non-staff player's keybind
    -- never lands on the hidden Admin tab.
    local tabs = visibleTabs()
    local n = #tabs
    if n == 0 then return end
    local current = 1
    for i, tab in ipairs(tabs) do
        if tab.id == self.activeTab then
            current = i
            break
        end
    end
    local step = (direction == -1) and -1 or 1
    self:setActiveTab(tabs[((current - 1 + step) % n) + 1].id)
end

function MC_ChatWindow:isInputFocused()
    if not self.entry then return false end
    local ok, focused = pcall(function() return self.entry:isFocused() end)
    return ok and focused == true
end

--[[
    Enter pressed in our own entry box.

    Routing is MC_Input's, not ours -- it owns prefix parsing, local
    commands, and the decision to yield an unowned slash command to
    vanilla. We only hand it the text and let it answer.
]]
function MC_ChatWindow:submitDefaultChannel()
    if self.activeTab == MC_ChatPanel.TAB_OOC then return "ooc" end
    return nil
end

function MC_ChatWindow:onSubmit(entryBox)
    local MC_Input = require("MC_Input")
    self.drafts = self.drafts or {}
    local text = ""
    pcall(function() text = entryBox:getText() or "" end)
    if text == "" then
        self:unfocusInput()
        return
    end

    -- Typing on the Admin tab speaks on the admin channel, the same way
    -- typing on Local speaks locally. A line the player already prefixed
    -- with a slash is left exactly as typed, so /admin, /setaccesslevel
    -- and every other command still work from here.
    if self.activeTab == MC_ChatPanel.TAB_ADMIN
       and text:sub(1, 1) ~= "/" then
        -- MC_Input owns the ISChat seam and knows how to get past vanilla's
        -- wrong-tab guard; it says so, loudly, if the line cannot be sent.
        local callOk, sent = pcall(function() return MC_Input.sendAdminLine(text) end)
        if not callOk or sent ~= true then
            self.drafts[self.activeTab] = text
            return false
        end
        pcall(function() entryBox:setText("") end)
        self.drafts[self.activeTab] = ""
        self:unfocusInput()
        return true
    end

    local submitDefault = self:submitDefaultChannel()
    local ok, handled = pcall(function()
        return MC_Input.submitFromWindow(entryBox, submitDefault)
    end)
    if not ok then
        MC_Incident.report("CHAT_SUBMIT_INTERCEPT_FAILED",
            "window submit raised; line dropped rather than mis-sent")
        self.drafts[self.activeTab] = text
        return false
    end
    if handled == false then
        -- MC does not own this slash command. Hand it to vanilla exactly
        -- as the old in-window path did, so hosted-server administration
        -- and other mods' commands keep working.
        local yieldOk, delivered = pcall(MC_Input.yieldToVanilla, text)
        if not yieldOk or delivered ~= true then
            self.drafts[self.activeTab] = text
            return false
        end
    end
    pcall(function() entryBox:setText("") end)
    self.drafts[self.activeTab] = ""
    self:unfocusInput()
    return true
end

-- RENDER

function MC_ChatWindow:prerender()
    -- The base class paints its own grey; we paint slate ourselves in
    -- render, so its background and border are turned fully off here.
    self.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self.borderColor = { r = 0, g = 0, b = 0, a = 0 }

    baseCall("prerender", self)

    -- B42 may restore native widget paint state outside our callbacks (focus,
    -- layout restore, or visibility changes).  This idempotent guard runs at
    -- the last parent boundary before the entry child paints.  Focus remains
    -- clear through the owned well; only the stray native one-pixel box dies.
    makeEntryFrameless(self.entry)

    -- Staff-only Admin tab, live: a grant or demotion mid-session redraws
    -- the strip, and a demoted player parked on Admin is returned to
    -- Local (setActiveTab also re-hides vanilla via the handoff).
    local staff = localPlayerIsStaff()
    local wasStaff = self.lastStaff
    if staff ~= self.lastStaff then
        self.lastStaff = staff
        self:refreshMinimumSize(true)
        self:relayout()
    end
    if (wasStaff == true and not staff)
        or (not staff and self.activeTab == MC_ChatPanel.TAB_ADMIN) then
        self:enforceAdminEntitlement()
    end

    self:refreshMinimumSize(false)
    if self.lastW ~= self.width or self.lastH ~= self.height then
        self.lastW, self.lastH = self.width, self.height
        self:relayout()
    end

    self:layoutTabs()
    self:drawChrome()

    if self.pendingOpacityPreview then
        self.pendingOpacityPreview = nil
        self:applyAccess()
    end
end

--[[
    Everything the window paints. Called from PRERENDER, before the
    children draw: PZ's order is prerender -> children -> render, so
    chrome painted in render() would sit on top of the transcript and
    the text box (the first cut did exactly that -- a dulled window and
    invisible typing).
]]
function MC_ChatWindow:drawChrome()
    local a = MC_ChatWindow.getAccess()
    local vanillaSkin = MC_Theme.windowUsesClassic()
    local tex = art()
    local slate = MC_Theme.surface("slate", nil, true)
    local font = self.tabFont or UIFont.Small
    local tm = getTextManager()
    local brandR, brandG, brandB = MC_Theme.rgb01(MC_Theme.brand("mongoose"))
    local now = nowMs(self.effectClock)
    self.effectClock = now
    local top = self:titleBarHeightSafe()
    local tabH = self:tabStripHeight()
    local frameY = top + tabH - TAB_GAP
    local frameH = self.height - frameY

    -- Classic keeps native-grey text. Its control edges still follow the
    -- shared player-hue option, like the other interface shapes.
    local classicText = MC_Theme.VanillaSurfaces
        and MC_Theme.VanillaSurfaces.text or { 205, 205, 200 }

    -- Frame body: from the bottom of the tab strip to the window's edge.
    if tex.frame.center then
        MC_Theme.slice(self, tex.frame, 0, frameY, self.width, frameH, slate.a, true)
    else
        self:drawRect(0, frameY, self.width, frameH, slate.a, slate.r, slate.g, slate.b)
    end
    drawExactEdge(self, "frame", 0, frameY, self.width, frameH,
        1, now, "content")

    -- Tabs. Idle tabs first, active last so it overdraws the frame rim.
    local chalkR, chalkG, chalkB = MC_Theme.rgb01(MC_Theme.Channels.say)
    local dimR, dimG, dimB = MC_Theme.rgb01(MC_Theme.Channels.whisper)
    local goldR, goldG, goldB = MC_Theme.rgb01(MC_Theme.Channels.yell)
    if vanillaSkin then
        chalkR, chalkG, chalkB = MC_Theme.rgb01(classicText)
        dimR, dimG, dimB = chalkR, chalkG, chalkB
        goldR, goldG, goldB = chalkR, chalkG, chalkB
    end
    if a.highContrast then
        local chalk = readable({math.floor(chalkR*255+0.5), math.floor(chalkG*255+0.5), math.floor(chalkB*255+0.5)})
        local dim = readable({math.floor(dimR*255+0.5), math.floor(dimG*255+0.5), math.floor(dimB*255+0.5)})
        local gold = readable({math.floor(goldR*255+0.5), math.floor(goldG*255+0.5), math.floor(goldB*255+0.5)})
        chalkR, chalkG, chalkB = MC_Theme.rgb01(chalk)
        dimR, dimG, dimB = MC_Theme.rgb01(dim)
        goldR, goldG, goldB = MC_Theme.rgb01(gold)
    end
    local active = nil
    for _, r in ipairs(self.tabRects or {}) do
        if r.id == self.activeTab then
            active = r
        else
            local y = r.y + 2  -- idle tabs sit a touch lower
            if tex.tabOff and tex.tabOff.center then
                MC_Theme.slice(self, tex.tabOff, r.x, y, r.w, r.h, 1, true)
            else
                local idleAlpha = slate.a * 0.6
                if type(MC_Theme.backgroundAlpha) == "function" then
                    idleAlpha = MC_Theme.backgroundAlpha(idleAlpha)
                end
                self:drawRect(r.x, y, r.w, r.h, idleAlpha,
                    slate.r, slate.g, slate.b)
            end
            drawExactEdge(self, "tab-idle", r.x, y, r.w, r.h,
                0.9, now, "control")
            self:drawTabLabel(r, y, r.h, dimR, dimG, dimB, goldR, goldG, goldB, font, tm)
        end
    end
    if active then
        local r = active
        if tex.tabOn and tex.tabOn.center then
            -- +TAB_GAP so the open bottom reaches down over the frame rim.
            MC_Theme.slice(self, tex.tabOn, r.x, r.y, r.w, r.h + TAB_GAP, 1, true)
        else
            self:drawRect(r.x, r.y, r.w, r.h + TAB_GAP, slate.a, slate.r, slate.g, slate.b)
        end
        drawExactEdge(self, "tab-active", r.x, r.y,
            r.w, r.h + TAB_GAP, 1, now, "control")
        self:drawTabLabel(r, r.y, r.h, chalkR, chalkG, chalkB, goldR, goldG, goldB, font, tm)
    end

    -- Quiet lock toggle. Only these named one/two-pixel strokes paint the mark;
    -- there is no font glyph, face, rim, or state left behind after this pass.
    local lr = self.lockRect
    if lr then
        local neutral = vanillaSkin and MC_Theme.VanillaSurfaces.text
            or MC_Theme.Channels.whisper
        neutral = readable(neutral)
        local nr, ng, nb = MC_Theme.rgb01(neutral)
        local mr, mg, mb = nr, ng, nb
        if lr.locked then mr, mg, mb = MC_Theme.rgb01(readable(MC_Theme.Channels.yell)) end
        local bodyW, bodyH, shackleW, shackleH = 12, 8, 8, 7
        local bodyX = math.floor(lr.x + (lr.w - bodyW) / 2)
        local bodyY = math.floor(lr.y + 2 + (lr.h - (bodyH + shackleH - 1)) / 2) + shackleH - 1
        local sx = bodyX + 2
        local sy = bodyY - shackleH + 1
        if a.highContrast then
            self:drawRect(bodyX - 2, sy - 2, bodyW + 6,
                bodyH + shackleH + 2, 1, 0, 0, 0)
        end
        -- Body: two-pixel top/bottom, one-pixel sides.
        self:drawRect(bodyX, bodyY, bodyW, 2, 1, mr, mg, mb)
        self:drawRect(bodyX, bodyY + bodyH - 2, bodyW, 2, 1, mr, mg, mb)
        self:drawRect(bodyX, bodyY + 2, 1, bodyH - 4, 1, mr, mg, mb)
        self:drawRect(bodyX + bodyW - 1, bodyY + 2, 1, bodyH - 4, 1, mr, mg, mb)
        -- Closed is a centred squared arch. Open moves the right post outward,
        -- leaving a clear two-pixel break above the body.
        self:drawRect(sx, sy, shackleW, 2, 1, mr, mg, mb)
        self:drawRect(sx, sy + 2, 2, shackleH - 3, 1, mr, mg, mb)
        if lr.locked then
            self:drawRect(sx + shackleW - 2, sy + 2, 2, shackleH - 3, 1, mr, mg, mb)
        else
            self:drawRect(sx + shackleW, sy + 2, 2, shackleH - 5, 1, mr, mg, mb)
        end
    end

    -- Close is an owned 7px diagonal mark. Its full rectangle remains the hit
    -- target, and hover raises ink only: it never grows a face or border.
    local cr = self.closeRect
    if cr then
        local neutral = vanillaSkin and MC_Theme.VanillaSurfaces.text
            or MC_Theme.Channels.whisper
        local xr,xg,xb = MC_Theme.rgb01(readable(neutral))
        local alpha = readableAlpha(self.hoverRect == cr and 1 or 0.72)
        local cx, cy = math.floor(cr.x + cr.w/2), math.floor(cr.y + cr.h/2)
        if a.highContrast then
            self:drawRect(cx - 5, cy - 5, 11, 11, 1, 0, 0, 0)
        end
        for i=-3,3 do
            self:drawRect(cx+i,cy+i,1,1,alpha,xr,xg,xb)
            self:drawRect(cx+i,cy-i,1,1,alpha,xr,xg,xb)
        end
    end

    -- Options word: idle-tab skin, chalk-dim.
    local orr = self.optionsRect
    if orr then
        if tex.tabOff and tex.tabOff.center then
            MC_Theme.slice(self, tex.tabOff, orr.x, orr.y + 2, orr.w, orr.h, 1, true)
        end
        drawExactEdge(self, "tab-idle", orr.x, orr.y + 2,
            orr.w, orr.h, 0.9, now, "control")
        local okW, w = pcall(function() return tm:MeasureStringX(font, orr.label) end)
        local ow = (okW and type(w) == "number") and w or 0
        local okH, fh = pcall(function() return tm:getFontHeight(font) end)
        local oh = (okH and type(fh) == "number") and fh or 12
        self:drawText(orr.label, orr.x + (orr.w - ow) / 2, orr.y + 2 + (orr.h - oh) / 2,
            dimR, dimG, dimB, 1, font)
    end

    -- Text-entry well behind the entry box. The skin is a shell around the
    -- native entry: its six-pixel rim never takes space from typed text.
    if self.entry and tex.well and tex.well.center then
        MC_Theme.slice(self, tex.well,
            self.entry:getX() - ENTRY_TEXT_INSET - EDGE,
            self.entry:getY() - EDGE,
            self.entry:getWidth() + ENTRY_TEXT_INSET + EDGE * 2,
            self.entry:getHeight() + EDGE * 2, 1, true)
    end
    if self.entry then
        drawExactEdge(self, "well",
            self.entry:getX() - ENTRY_TEXT_INSET - EDGE,
            self.entry:getY() - EDGE,
            self.entry:getWidth() + ENTRY_TEXT_INSET + EDGE * 2,
            self.entry:getHeight() + EDGE * 2,
            0.9, now, "control")
        if a.highContrast and self:isInputFocused() then
            local focus = readable(MC_Theme.windowControlColor(), "state")
            local fr, fg, fb = MC_Theme.rgb01(focus)
            local fx = self.entry:getX() - ENTRY_TEXT_INSET - EDGE
            local fy = self.entry:getY() - EDGE
            local fw = self.entry:getWidth() + ENTRY_TEXT_INSET + EDGE * 2
            local fh = self.entry:getHeight() + EDGE * 2
            local inset = math.max(2, EDGE)
            self:drawRectBorder(fx + inset, fy + inset, fw - inset*2,
                fh - inset*2, 1, fr, fg, fb)
            self:drawRectBorder(fx + inset + 1, fy + inset + 1,
                fw - inset*2 - 2, fh - inset*2 - 2, 1, fr, fg, fb)
        end
    end

    -- A half-second mark sits in the empty well margin. Tags-only must not
    -- reveal identity colour through decoration.
    if self.entry and not a.highContrast and not vanillaSkin and not self:isInputFocused()
        and not a.tagsOnly and self.inkColor and self.inkUntil
        and now < self.inkUntil then
        local ir, ig, ib = MC_Theme.rgb01(self.inkColor)
        local inkAlpha = a.reducedMotion and 1
            or math.max(0, math.min(1, (self.inkUntil - now) / INK_MARK_MS))
        self:drawRect(self.entry:getX(), self.entry:getY() - 1,
            math.min(18, self.entry:getWidth()), 1,
            inkAlpha, ir, ig, ib)
    elseif self.inkUntil and now >= self.inkUntil then
        self.inkColor, self.inkUntil = nil, nil
    end

    -- One pixel runs clockwise once around the frame. Draw only its current
    -- segment, so it never becomes a second border or touches child content.
    if (not vanillaSkin or a.tagsOnly) and not a.reducedMotion and self.sparkStarted and self.sparkUntil
        and now < self.sparkUntil and self.width > 1 and self.height > 1 then
        local edgeInset = a.highContrast and 1 or 0
        local sparkW, sparkH = self.width - edgeInset * 2, self.height - edgeInset * 2
        local perimeter = 2 * (sparkW + sparkH) - 4
        local progress = math.max(0, math.min(1,
            (now - self.sparkStarted) / SEND_SPARK_MS))
        local d = math.floor(progress * perimeter)
        local x, y
        if d < sparkW then x, y = d, 0
        elseif d < sparkW + sparkH - 1 then x, y = sparkW - 1, d - sparkW + 1
        elseif d < sparkW * 2 + sparkH - 2 then x, y = sparkW - 2 - (d - sparkW - sparkH + 1), sparkH - 1
        else x, y = 0, sparkH - 2 - (d - sparkW * 2 - sparkH + 2) end
        x, y = x + edgeInset, y + edgeInset
        local sr, sg, sb = brandR, brandG, brandB
        if a.tagsOnly then
            local sparkSlate = vanillaSkin and MC_Theme.VanillaSurfaces.slate
                or MC_Theme.Surfaces.slate
            sr, sg, sb = MC_Theme.rgb01(sparkSlate)
        end
        self:drawRect(x, y, 1, 1, 1, sr, sg, sb)
    elseif self.sparkUntil and (a.reducedMotion or now >= self.sparkUntil) then
        self.sparkStarted, self.sparkUntil = nil, nil
    end

end

-- After the children: only the resize grip, which lives in a corner no
-- child occupies, so drawing it over them is harmless.
function MC_ChatWindow:render()
    baseCall("render", self)
    local a = MC_ChatWindow.getAccess()
    local vanillaSkin = MC_Theme.windowUsesClassic()
    local classicText = MC_Theme.VanillaSurfaces
        and MC_Theme.VanillaSurfaces.text or { 205, 205, 200 }
    local now = nowMs(self.effectClock)
    self.effectClock = now

    -- Hover tip: slate box, chalk words, under the hovered strip item.
    local r = self.hoverRect
    if r and r.tip and (MC_Core.getTimeMs() - (self.hoverSince or 0)) >= TIP_DELAY_MS then
        local font = UIFont.Small
        local tm = getTextManager()
        local displayTip = r.tip
        local maxTextW = math.max(1, self.width - EDGE * 2)
        local okW, w = pcall(function() return tm:MeasureStringX(font, displayTip) end)
        if okW and type(w) == "number" and w > maxTextW then
            local glyphs = {}
            for ch in MC_StringUtils.utf8chars(displayTip) do glyphs[#glyphs + 1] = ch end
            local ellipsis = "..."
            repeat
                glyphs[#glyphs] = nil
                displayTip = table.concat(glyphs) .. ellipsis
                okW, w = pcall(function() return tm:MeasureStringX(font, displayTip) end)
            until #glyphs == 0 or (okW and type(w) == "number" and w <= maxTextW)
        end
        local okH, fh = pcall(function() return tm:getFontHeight(font) end)
        local tw = math.min(self.width,
            ((okW and type(w) == "number") and w or math.min(60, maxTextW)) + EDGE * 2)
        local textH = ((okH and type(fh) == "number") and fh or 12)
        local th = math.max(MC_Theme.Metrics.corner * 2, textH + EDGE * 2)
        local tx = math.max(0, math.min(r.x, self.width - tw))
        local ty = r.y + r.h + 4
        local tipFrame = MC_Theme.textures("window", "frame")
        MC_Theme.slice(self, tipFrame, tx, ty, tw, th,
            readableAlpha(0.95), true)
        drawExactEdge(self, "frame", tx, ty, tw, th,
            0.95, now, "content")
        local tipColor = readable(vanillaSkin and classicText or MC_Theme.Channels.say)
        local cr, cg, cb = MC_Theme.rgb01(tipColor)
        self:drawText(displayTip, tx + EDGE, ty + math.floor((th - textH) / 2), cr, cg, cb, 1, font)
    end
    if self.resizable and not a.locked and self.resizeWidget then
        local widget = self.resizeWidget
        local x, y, w, h = self.width - GRIP_SIZE, self.height - GRIP_SIZE,
            GRIP_SIZE, GRIP_SIZE
        pcall(function()
            x, y = widget:getX(), widget:getY()
            w, h = widget:getWidth(), widget:getHeight()
        end)
        local over = widget.mouseOver == true
        local pressed = widget.resizing == true
        local fill = MC_Theme.surface("slateDeep", pressed and 1 or (over and 0.92 or 0.72), true)

        -- A small raster quarter-round follows the lower-right interface curve.
        -- The hit target remains the native rectangle; only its visible face is
        -- curved. Each one-pixel row begins farther left toward the bottom.
        local curve = { 12,10,9,8,7,6,5,4,4,3,2,2,1,1,0,0,0,0 }
        local rows = math.min(h, #curve)
        for row = 1, rows do
            local inset = math.min(w - 1, curve[row])
            self:drawRect(x + inset, y + row - 1, w - inset, 1,
                fill.a, fill.r, fill.g, fill.b)
        end

        -- Three nested stepped curves, not boxed corners.
        local arcs = {
            { {5,16},{8,15},{11,13},{13,10},{15,6} },
            { {9,16},{11,15},{13,13},{15,10} },
            { {12,16},{14,15},{15,13} },
        }
        local markColor = MC_Theme.windowControlColor()
        if a.tagsOnly then
            markColor = vanillaSkin and MC_Theme.VanillaSurfaces.slate
                or MC_Theme.Surfaces.slate
        end
        markColor = readable(markColor, pressed or over)
        local mr, mg, mb = MC_Theme.rgb01(markColor)
        local markAlpha = a.highContrast and 1
            or (pressed and 1 or (over and 0.95 or 0.78))
        local thickness = pressed and 2 or 1
        for _, arc in ipairs(arcs) do
            for _, point in ipairs(arc) do
                local px = x + math.min(w - thickness, point[1])
                local py = y + math.min(h - thickness, point[2])
                self:drawRect(px, py, thickness, thickness,
                    markAlpha, mr, mg, mb)
            end
        end
    end
end

--[[
    Tab label plus the unread count. The count is a DIGIT, drawn in gold
    after the name -- never a bare dot, so it reads without colour vision
    and says how much is waiting rather than merely that something is.
]]
function MC_ChatWindow:drawTabLabel(r, y, h, tr, tg, tb, ur, ug, ub, font, tm)
    local unread = MC_ChatPanel.getUnread(r.id)
    if MC_ChatWindow.getAccess().unreadCounts == false then unread = 0 end
    local name = r.name or r.label
    local count = ""
    if unread > 0 then count = unread > 99 and "99+" or tostring(unread) end

    local okW, w = pcall(function() return tm:MeasureStringX(font, name) end)
    local nameW = (okW and type(w) == "number") and w or 0
    local countW = 0
    if count ~= "" then
        local okC, cw = pcall(function() return tm:MeasureStringX(font, count) end)
        countW = ((okC and type(cw) == "number") and cw or 0) + 6
    end
    local okH, fh = pcall(function() return tm:getFontHeight(font) end)
    local textH = (okH and type(fh) == "number") and fh or 12

    local x = r.x + (r.w - nameW - countW) / 2
    local ty = y + (h - textH) / 2
    self:drawText(name, x, ty, tr, tg, tb, 1, font)
    if count ~= "" then
        self:drawText(count, x + nameW + 6, ty, ur, ug, ub, 1, font)
    end
end

-- LIFECYCLE

-- LAYOUT PERSISTENCE
--
-- Position and size go through vanilla's ISLayoutManager (layout.ini), the
-- same store the vanilla chat window used, so a stretched window comes
-- back stretched next session and survives a mod update. The base class's
-- versions also restore pin/collapse state; we have no title bar, so only
-- the rectangle is kept.

function MC_ChatWindow:RestoreLayout(name, layout)
    if not self.resizable then
        layout.width = nil
        layout.height = nil
    end
    if ISLayoutManager and ISLayoutManager.DefaultRestoreWindow then
        ISLayoutManager.DefaultRestoreWindow(self, layout)
    end
    self:refreshMinimumSize(true)
    self:relayout()
    makeEntryFrameless(self.entry)
end

function MC_ChatWindow:SaveLayout(name, layout)
    if ISLayoutManager and ISLayoutManager.DefaultSaveWindow then
        ISLayoutManager.DefaultSaveWindow(self, layout)
    end
end

function MC_ChatWindow.create()
    if MC_ChatWindow.instance then return MC_ChatWindow.instance end

    if MC_ChatWindow.unavailable then return nil end

    local x, y, w, h = 40, 40, DEFAULT_W, DEFAULT_H
    pcall(function()
        y = getCore():getScreenHeight() - DEFAULT_H - 60
    end)

    local win = MC_ChatWindow:new(x, math.max(20, y), w, h)
    if not win then return nil end

    -- Register BEFORE building. addToUIManager runs createChildren; if that
    -- throws, the caller must find a marked failure, not a nil that invites
    -- another attempt next tick -- the first cut re-added a half-built
    -- window to the UI manager sixty times a second.
    MC_ChatWindow.instance = win
    local ok, err = pcall(function()
        win:initialise()
        win:addToUIManager()
        win:setVisible(true)
        win:setActiveTab(MC_ChatPanel.TAB_LOCAL)
    end)
    if not ok or not win.chatPanel or not win.entry then
        pcall(function() win:setVisible(false) end)
        pcall(function() win:removeFromUIManager() end)
        MC_ChatWindow.instance = nil
        MC_ChatWindow.unavailable = true
        MC_Incident.report("CHAT_WINDOW_UNAVAILABLE",
            "window failed to build; keeping the vanilla chat window")
        dbg("create: build failed: %s", tostring(err))
        return nil
    end

    -- Registering restores the saved rectangle at once and saves it on
    -- every game save. Not fatal if the manager is missing: the window
    -- simply comes up at its default.
    pcall(function()
        ISLayoutManager.RegisterWindow("MongooseChat", MC_ChatWindow, win)
    end)
    -- RegisterWindow may restore a saved layout and reset native widget state.
    -- Re-apply access even when the manager or its restore hook throws.
    pcall(function() win:applyAccess() end)
    makeEntryFrameless(win.entry)

    dbg("create: chat window up at %d,%d %dx%d", x, y, w, h)
    return win
end

function MC_ChatWindow.destroy()
    local win = MC_ChatWindow.instance
    if not win then return end
    MC_QuickMenu.closeOwner(win)
    pcall(function() win:setVisible(false) end)
    pcall(function() win:removeFromUIManager() end)
    MC_ChatWindow.instance = nil
    dbg("destroy: chat window torn down")
end

return MC_ChatWindow
