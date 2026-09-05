--[[
================================================================================
    MongooseChat - Character Sheet (client UI)

    A right-click "Character Sheet" window: a full-body 3D view of the
    character on the left, and their name, tagline, and a longer
    description / history on the right.

      - YOUR OWN sheet is EDITABLE: set your tagline (still also settable with
        /bio) and write a description. One Save writes both.
      - SOMEONE ELSE'S sheet is READ-ONLY and honours the anonymity system --
        a masked or unrecognised person shows only their anonymous shell, never
        a real name, tagline, or description. The 3D body still shows for anyone
        you can actually see (a masked figure shows their masked in-world
        appearance -- it leaks nothing you can't already see standing in front
        of you, exactly like the speech-bubble portrait); it's hidden only for
        a distant / out-of-sight person.

    The model uses the same UI3DModel:setCharacter recipe the speech bubbles
    already rely on. Data + network live in MC_Bio (the Desc* commands); this
    file is presentation only, and every engine call is pcall-guarded -- a
    vanilla UI drift costs the window, never the session.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Config = require("MC_Config")
local MC_Theme = require("MC_Theme")

-- Sheet text follows the player's Text size setting (Options > Mods > MongooseChat)
-- unless they have excluded the sheet from it.
local function sheetFont(size)
    local default = (size == "medium") and UIFont.Medium or UIFont.Small
    return MC_Theme.font("sheet", default)
end
local MC_Bio = require("MC_Bio")
local MC_Anonymity = require("MC_Anonymity")
local MC_ChatPanel = require("MC_ChatPanel")
local MC_PageClose = require("MC_PageClose")

local dbg = MC_Core.debugger("SHEET")

local MC_CharacterSheet = {}

local function readable(rgb, state)
    if MC_Theme.access().highContrast and type(MC_Theme.readableColor) == "function" then
        return MC_Theme.readableColor(rgb, MC_Theme.highContrastBackground(state))
    end
    return rgb
end

local function readable01(r, g, b, state)
    if not MC_Theme.access().highContrast then return r, g, b end
    local rgb = readable({math.floor(r*255+0.5), math.floor(g*255+0.5),
        math.floor(b*255+0.5)}, state)
    return rgb[1]/255, rgb[2]/255, rgb[3]/255
end

local function copyRGBA(value, fallback)
    if type(value) ~= "table" then return fallback end
    return { r=tonumber(value.r) or fallback.r, g=tonumber(value.g) or fallback.g,
        b=tonumber(value.b) or fallback.b, a=tonumber(value.a) or fallback.a }
end

-- Tagline/description caps single-sourced from MC_Bio (the file that
-- actually enforces them, in saveTagline/sanitizeDescription) -- kept here
-- as a second literal, they'd only be able to drift out of sync.
local PAD = 12

-- Window + model framing. The two model knobs (zoom / y-offset) are the ones
-- to tune by eye: higher zoom = closer, lower = more of the body in frame.
local WIN_W, WIN_H = 500, 430
local M = MC_Theme.Metrics
local EDGE = M.rimPx
local TAB_H = math.max(30, M.tabH)
local TAB_GAP = M.tabGap
local TAB_PAD_X = M.tabPadX
local STRIP_H = TAB_H + TAB_GAP
local BODY_Y = STRIP_H - EDGE
local MODEL_W, MODEL_H = 150, 270
local COLUMN_GAP = 14
local BUTTON_H = 32
local BOTTOM_SAFE = 15
-- Full-body framing, taken from Spongie's Character Customisation zoom table:
-- zoom 0 / yOffset -0.5 is the fully zoomed-OUT whole-body view. (Its most
-- zoomed-IN level is zoom 18 / yOffset -0.875, ~ the speech-bubble bust.)
local MODEL_ZOOM = 0
local MODEL_YOFFSET = -0.5
local BG_ALPHA = 0.55   -- window background opacity (semi-transparent)
local RIM_INSET = EDGE
local ENTRY_INSET_X = 10
local ENTRY_INSET_Y = 8

-- These are the pre-polish sheet's own draw values (commit 1a95f7f), not a
-- new approximation of them.
local CLASSIC_BG = { r=0.05, g=0.05, b=0.08, a=BG_ALPHA }
local CLASSIC_PANEL = { r=0, g=0, b=0, a=0.35 }
local CLASSIC_RULE = { r=0.5, g=0.5, b=0.55, a=0.5 }
local CLASSIC_TEXT = { r=0.82, g=0.82, b=0.78, a=1 }

local function isClassic()
    return MC_Theme.windowUsesClassic()
end

local function drawClassicBox(owner, shell, alpha)
    if MC_Theme.access().highContrast then
        owner:drawRect(shell.x, shell.y, shell.w, shell.h, 1, 0, 0, 0)
        local ink = readable(MC_Theme.windowControlColor(), "state")
        owner:drawRectBorder(shell.x, shell.y, shell.w, shell.h, 1,
            ink[1]/255, ink[2]/255, ink[3]/255)
        return
    end
    owner:drawRect(shell.x, shell.y, shell.w, shell.h,
        alpha or CLASSIC_PANEL.a, CLASSIC_PANEL.r, CLASSIC_PANEL.g, CLASSIC_PANEL.b)
    owner:drawRectBorder(shell.x, shell.y, shell.w, shell.h,
        CLASSIC_RULE.a, CLASSIC_RULE.r, CLASSIC_RULE.g, CLASSIC_RULE.b)
end

local function rect(x, y, w, h, prefix, kind)
    return { x=x, y=y, w=w, h=h, prefix=prefix, kind=kind }
end

local function headerGeometry(width, titleTextW, closeTextW, skin)
    -- Soft follows the shared lichen-tab weight. Sharp keeps the sheet's old
    -- square-tab measure; Classic does not paint these custom tabs at all.
    local padX = MC_Theme.tabPadX(skin)
    local titleW = math.max(48, titleTextW + padX * 2)
    local closeW = math.max(48, closeTextW + padX * 2)
    local title = rect(EDGE, 0, titleW, BODY_Y + EDGE, "tab-active", "control")
    local close = rect(width - EDGE - closeW, TAB_GAP, closeW,
        BODY_Y + EDGE - TAB_GAP,
        "tab-idle", "control")
    title.edgeAlpha = 1
    close.edgeAlpha = 0.9
    return title, close
end

local function insetRect(shell)
    return shell.x + RIM_INSET, shell.y + RIM_INSET,
        shell.w - RIM_INSET * 2, shell.h - RIM_INSET * 2
end

local function centeredTextRect(shell, textW, textH)
    local x, y, w, h = insetRect(shell)
    textW, textH = math.max(0, textW or 0), math.max(0, textH or 0)
    local tx = x + math.floor((w - textW) / 2)
    local ty = y + math.floor((h - textH) / 2)
    -- Keep the origin in the painted inner slot even under very narrow shells
    -- or large UI fonts. A live raster check still guards glyph clipping.
    tx = math.max(x, math.min(tx, x + math.max(0, w - textW)))
    ty = math.max(y, math.min(ty, y + math.max(0, h - textH)))
    return tx, ty, w, h
end

local function entryRect(shell)
    return shell.x + ENTRY_INSET_X, shell.y + ENTRY_INSET_Y,
        shell.w - ENTRY_INSET_X * 2, shell.h - ENTRY_INSET_Y * 2
end

local function clampWindow(sw, sh)
    local ww = math.min(WIN_W, math.max(1, sw))
    local wh = math.min(WIN_H, math.max(1, sh))
    return math.max(0, math.floor((sw - ww) / 2)),
        math.max(0, math.floor((sh - wh) / 2)), ww, wh
end

local function bottomButtonY(height)
    return height - BOTTOM_SAFE - (BUTTON_H + RIM_INSET * 2)
end

local function drawShellBase(owner, shell, alpha)
    local tex = MC_Theme.textures("window", shell.prefix)
    MC_Theme.slice(owner, tex, shell.x, shell.y, shell.w, shell.h, alpha or 1, true)
end

local function drawShellEdge(owner, shell, alpha, now)
    MC_Theme.drawSliceEdge(owner, "window", shell.prefix,
        shell.x, shell.y, shell.w, shell.h, alpha or 1, now,
        shell.kind, nil, nil, nil, true)
end

local function withoutTopMasks(masks)
    if type(masks) ~= "table" then return nil end
    local filtered = {}
    for _, name in ipairs({ "outer", "middle", "lip" }) do
        local source = masks[name]
        local band = {}
        if type(source) == "table" then
            for key, value in pairs(source) do band[key] = value end
        end
        band.topLeft = nil
        band.top = nil
        band.topRight = nil
        filtered[name] = band
    end
    return filtered
end


local function exposedTopGaps(width, shells)
    local spans = {}
    for _, shell in ipairs(shells or {}) do
        spans[#spans + 1] = { x=math.max(0, shell.x),
            right=math.min(width, shell.x + shell.w) }
    end
    table.sort(spans, function(a, b) return a.x < b.x end)
    local gaps, cursor = {}, 0
    for _, span in ipairs(spans) do
        if span.x > cursor then gaps[#gaps + 1] = { x=cursor, w=span.x-cursor } end
        if span.right > cursor then cursor = span.right end
    end
    if cursor < width then gaps[#gaps + 1] = { x=cursor, w=width-cursor } end
    return gaps
end

local function drawTopGaps(owner, width, shells, now)
    for _, gap in ipairs(exposedTopGaps(width, shells)) do
        if gap.w > EDGE * 2 then
            MC_Theme.drawEdgePiece(owner, "window", "frame", "top",
                { x=gap.x, y=BODY_Y, w=gap.w, h=M.corner }, 0.95,
                now, "content", "content", false)
        end
    end
    MC_Theme.drawEdgePiece(owner, "window", "frame", "topLeft",
        { x=0, y=BODY_Y, w=M.corner, h=M.corner }, 0.95,
        now, "content", "content", false)
    MC_Theme.drawEdgePiece(owner, "window", "frame", "topRight",
        { x=width-M.corner, y=BODY_Y, w=M.corner, h=M.corner }, 0.95,
        now, "content", "content", false)
end

local function drawInnerJoin(owner, shell, side, now)
    local x = side == "left" and (shell.x - (M.corner-EDGE))
        or (shell.x + shell.w - EDGE)
    MC_Theme.drawEdgePiece(owner, "window", "tab-join", side,
        { x=x, y=BODY_Y-(M.corner-EDGE), w=M.corner, h=M.corner },
        shell.edgeAlpha or 1, now, "control", "content")
end

-- Nil-is-failure contract; see MC_Core.safeGet/safeExec for why that
-- differs from MC_Core.safe. Kept under this file's own names since every
-- call site here already uses them.
local function safeExec(fn)
    local ok, err = MC_Core.safeExec(fn)
    if not ok then dbg("sheet safeExec failed: %s", tostring(err)) end
    return ok
end

local safeGet = MC_Core.safeGet

local function measuredHeaderGeometry(width, tm, font)
    local titleTextW = safeGet(function()
        return tm:MeasureStringX(font, "Character Sheet")
    end, 96)
    local closeTextW = safeGet(function()
        return tm:MeasureStringX(font, "Close")
    end, 36)
    return headerGeometry(width, titleTextW, closeTextW, MC_Theme.skin())
end

-- Split a string into paragraphs on newline boundaries (no pattern magic, so
-- it's Kahlua-safe and stable on any byte content).
local function splitParagraphs(text)
    local out, acc = {}, ""
    for i = 1, #text do
        local ch = text:sub(i, i)
        if ch == "\n" then
            out[#out + 1] = acc
            acc = ""
        else
            acc = acc .. ch
        end
    end
    out[#out + 1] = acc
    return out
end

-- Greedy word-wrap: honour existing line breaks, then wrap each paragraph to
-- the available pixel width via MC_ChatPanel's shared wrap core (the same
-- glyph-overhang-corrected loop MC_Bubble uses) -- this file only adds the
-- paragraph split on top. An empty paragraph maps to one blank line, which
-- is exactly what the shared core already returns for an empty string.
local function wrapText(text, font, maxWidth)
    local lines = {}
    for _, paragraph in ipairs(splitParagraphs(text)) do
        for _, ln in ipairs(MC_ChatPanel._wrapWords(paragraph, font, maxWidth)) do
            lines[#lines + 1] = ln
        end
    end
    return lines
end

-- Fixed UI captions sometimes sit directly above a control and cannot grow
-- vertically. Keep those to one measured line. Player-authored text never
-- uses this path: names and taglines wrap on glyph boundaries below.
local function boundedLine(text, font, maxWidth)
    local lines = wrapText(text or "", font, math.max(1, maxWidth))
    if #lines <= 1 then return lines[1] or "" end
    local first = lines[1] or ""
    local suffix = "..."
    local tm = getTextManager()
    while first ~= "" and safeGet(function()
            return tm:MeasureStringX(font, first .. suffix)
        end, maxWidth + 1) > maxWidth do
        -- Fixed captions are ASCII, so byte removal is safe here. Do not use
        -- this helper for names, taglines, or descriptions.
        first = first:sub(1, #first - 1)
    end
    if first == "" then return lines[1] or "" end
    return first .. suffix
end

local function drawWrapped(owner, text, x, y, font, maxWidth, bottom,
        lineH, r, g, b, a)
    r, g, b = readable01(r, g, b)
    if type(MC_Theme.readableAlpha) == "function" then
        a = MC_Theme.readableAlpha(a)
    end
    local fontH = safeGet(function()
        return getTextManager():getFontHeight(font)
    end, math.max(1, lineH - 2))
    for _, line in ipairs(wrapText(text or "", font, maxWidth)) do
        if y + fontH > bottom then break end
        owner:drawText(line, x, y, r, g, b, a, font)
        y = y + lineH
    end
    return y
end

MC_CharacterSheet._wrapText = wrapText

-- WINDOW

local Sheet = ISCollapsableWindow:derive("MC_CharacterSheetWindow")
local instance = nil

function Sheet:new(x, y, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title = ""
    o.drawFrame = false
    o.resizable = false
    o.targetPlayer = nil
    o.targetUsername = nil
    o.realName = nil
    o.editable = false
    -- Semi-transparent body so the game shows through behind the card.
    o.backgroundColor = { r=0, g=0, b=0, a=0 }
    o.borderColor = { r=1, g=1, b=1, a=0 }
    return o
end

function Sheet:titleBarHeight()
    return STRIP_H
end

local function hideNativeChrome(self)
    for _, name in ipairs({ "closeButton", "collapseButton", "pinButton",
            "resizeWidget", "resizeWidget2" }) do
        local control = self[name]
        if control then safeExec(function() control:setVisible(false) end) end
    end
end

local function addEntry(self, text, shell, multiple, maxLength)
    local x, y, w, h = entryRect(shell)
    local entry = ISTextEntryBox:new(text, x, y, w, h)
    entry:initialise()
    entry:instantiate()
    -- B42 UITextBox2's constructor defaults: white text and opaque 0.5-grey
    -- placeholder ink. Lua exposes no getters, so these exact engine defaults
    -- are the restore fallback when an instance carries no mirrored fields.
    entry.mcNormalTextRGBA = copyRGBA(entry.textColor, {r=1,g=1,b=1,a=1})
    entry.mcNormalPlaceholderRGBA = copyRGBA(entry.placeholderTextColor,
        {r=0.5,g=0.5,b=0.5,a=1})
    entry.backgroundColor = { r=0, g=0, b=0, a=0 }
    entry.borderColor = { r=1, g=1, b=1, a=0 }
    safeExec(function() entry:setHasFrame(false) end)
    if multiple then entry:setMultipleLine(true) end
    entry:setMaxTextLength(maxLength)
    self:addChild(entry)
    return entry
end

-- B42's ISButton hard-codes disabled words to 0.3 grey. Keep its full native
-- renderer in Normal mode. In High contrast suppress only that native label,
-- then paint the same centred title with checked ink. A small crossed mark is
-- the second, non-colour cue that this MC-owned Save control is unavailable.
local function installHighContrastButtonPaint(button)
    if not button or button.mcNormalRender then return end
    button.mcNormalRender = button.render
    button.render = function(self)
        if not MC_Theme.access().highContrast then
            if self.mcNormalRender then return self.mcNormalRender(self) end
            return
        end
        local title = self.title or ""
        self.title = ""
        local ok, err = pcall(function()
            if self.mcNormalRender then self.mcNormalRender(self) end
        end)
        self.title = title
        if not ok then error(err, 0) end
        if title == "" then return end

        local tm = getTextManager()
        local font = self.font or sheetFont("small")
        local tw = safeGet(function() return tm:MeasureStringX(font, title) end, 0)
        local th = safeGet(function() return tm:MeasureStringY(font, title) end,
            safeGet(function() return tm:getFontHeight(font) end, 12))
        local ink = readable(MC_Theme.windowControlColor(), "state")
        local r, g, b = MC_Theme.rgb01(ink)
        local x = self.titleLeft and 3 or (self.width - tw) / 2
        local y = (self.height - th) / 2 + (tonumber(self.yoffset) or 0)
        self:drawText(title, x, y, r, g, b, 1, font)
        if self.enable == false then
            local mx, my = 5, math.floor(self.height / 2) - 3
            for i = 0, 6 do
                self:drawRect(mx+i, my+i, 1, 1, 1, r, g, b)
                self:drawRect(mx+i, my+6-i, 1, 1, 1, r, g, b)
            end
        end
    end
end

local function addButton(self, shell, label, action, fullShellHit, renderless)
    local x, y, w, h
    if fullShellHit then
        x, y, w, h = shell.x, shell.y, shell.w, shell.h
    else
        x, y, w, h = insetRect(shell)
    end
    local button = ISButton:new(x, y, w, h, label, self, action)
    button:initialise()
    button.mcNormalTextColor = copyRGBA(button.textColor, {r=1,g=1,b=1,a=1})
    button.mcNormalDisabledColor = copyRGBA(button.textColorDisabled,
        {r=0.5,g=0.5,b=0.5,a=1})
    if not renderless then installHighContrastButtonPaint(button) end
    button.backgroundColor = { r=0, g=0, b=0, a=0 }
    button.backgroundColorMouseOver = { r=0, g=0, b=0, a=0 }
    button.borderColor = { r=1, g=1, b=1, a=0 }
    if renderless then
        -- Keep the native full-shell motor target, but let the parent own every
        -- pixel so native hover/fill/text cannot fight the curved tab join.
        button.prerender = function() end
        button.render = function() end
    end
    self:addChild(button)
    return button
end

function Sheet:createChildren()
    ISCollapsableWindow.createChildren(self)
    hideNativeChrome(self)

    local tm = getTextManager()
    local lineH = tm:getFontHeight(sheetFont("small")) + 2
    local medH = tm:getFontHeight(sheetFont("medium"))
    self.bodyShell = rect(0, BODY_Y, self.width, self.height - BODY_Y,
        "frame", "content")
    self.titleShell, self.closeShell = measuredHeaderGeometry(self.width,
        tm, sheetFont("small"))
    self.shells = { self.bodyShell }
    self.headerShells = { self.closeShell, self.titleShell }
    self.contentTop = BODY_Y + PAD
    self.modelW = math.min(MODEL_W, math.max(1,
        self.width - PAD * 3 - COLUMN_GAP - 120))
    self.modelH = math.min(MODEL_H, math.max(1,
        self.height - self.contentTop - PAD))
    self.modelShell = rect(PAD, self.contentTop, self.modelW, self.modelH,
        "frame", "content")
    self.shells[#self.shells + 1] = self.modelShell
    self.closeButtonCustom = addButton(self, self.closeShell, "Close",
        Sheet.onCloseSheet, true, true)

    -- Full-body character model on the left (both modes). ISUI3DModel is the
    -- vanilla panel wrapper -- the same approach Spongie's Character
    -- Customisation uses on this B42 build: addChild it, then configure.
    -- Anonymity is enforced per frame by toggling its visibility in render.
    safeExec(function()
        local mx, my, mw, mh = insetRect(self.modelShell)
        self.model = ISUI3DModel:new(mx, my, mw, mh)
        self.model.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
        self.model.borderColor = { r = 1, g = 1, b = 1, a = 0 }
        self:addChild(self.model)
        self.model:setCharacter(self.targetPlayer)
        self.model:setDirection(IsoDirections.S)
        self.model:setState("idle")
        self.model:setIsometric(false)
        self.model:setDoRandomExtAnimations(false)
        self.model:setZoom(MODEL_ZOOM)
        self.model:setYOffset(MODEL_YOFFSET)
    end)

    -- Right column geometry (shared by both modes).
    self.rx = PAD + self.modelW + COLUMN_GAP
    self.rw = self.width - self.rx - PAD
    self.nameY = self.contentTop
    local nameLines = wrapText(self.realName or "Someone", sheetFont("medium"),
        self.rw)
    self.nameLineCount = math.max(1, #nameLines)
    if self.editable then
        -- Keep the minimum description well and bottom Save shell intact even
        -- with huge fonts or an unusually long character name.
        local fieldH = math.max(40, lineH + ENTRY_INSET_Y * 2)
        local reserved = lineH + 5 + fieldH + 10 + lineH + 5 + 60 + 10
        local available = bottomButtonY(self.height) - self.contentTop - reserved
        local maxNameLines = math.max(1,
            math.floor(math.max(0, available - 6) / math.max(1, medH + 2)))
        self.nameLineCount = math.min(self.nameLineCount, maxNameLines)
    end
    self.taglineLabelY = self.nameY + self.nameLineCount * (medH + 2) + 6

    if not self.editable then
        -- Read-only sheet of another player. The ONE editable thing is your
        -- PRIVATE notes about them, bottom-anchored so the description fills the
        -- space above. Nobody else ever sees these.
        local saveShellY = bottomButtonY(self.height)
        local notesH = 82
        local notesY = saveShellY - 10 - notesH
        self.notesLabelY = notesY - lineH - 6
        self.descBottomY = self.notesLabelY - 8
        self.notesShell = rect(self.rx, notesY, self.rw, notesH, "well", "control")
        self.notesSaveShell = rect(self.rx + self.rw - 84, saveShellY,
            84, BUTTON_H + RIM_INSET * 2, "well", "control")
        self.notesShell.visible = false
        self.notesSaveShell.visible = false
        self.shells[#self.shells + 1] = self.notesShell
        self.shells[#self.shells + 1] = self.notesSaveShell

        self.initialNote = MC_Bio.getNote(self.targetUsername) or ""
        self.lastSetNote = self.initialNote

        self.notesEntry = addEntry(self, self.initialNote, self.notesShell, true,
            MC_Bio.MAX_DESCRIPTION_LENGTH)
        self.notesSaveButton = addButton(self, self.notesSaveShell, "Save",
            Sheet.onSaveNote)
        -- Fail closed until prerender has proved recognition. This prevents a
        -- first-frame focus or click target from existing under an anon card.
        safeExec(function() self.notesEntry:setVisible(false) end)
        safeExec(function() self.notesSaveButton:setVisible(false) end)
        return
    end

    -- Editable: tagline + description entries in the right column.
    local taglineY = self.taglineLabelY + lineH + 5
    local fieldH = math.max(40, lineH + ENTRY_INSET_Y * 2)
    self.descLabelY = taglineY + fieldH + 10
    local descY = self.descLabelY + lineH + 5
    local saveShellY = bottomButtonY(self.height)
    local descH = math.max(60, saveShellY - 10 - descY)
    self.taglineShell = rect(self.rx, taglineY, self.rw, fieldH, "well", "control")
    self.descShell = rect(self.rx, descY, self.rw, descH, "well", "control")
    self.saveShell = rect(self.rx, saveShellY, 108,
        BUTTON_H + RIM_INSET * 2, "well", "control")
    self.shells[#self.shells + 1] = self.taglineShell
    self.shells[#self.shells + 1] = self.descShell
    self.shells[#self.shells + 1] = self.saveShell

    -- Prefill from cache, remembering what we prefilled: onSave only writes a
    -- field the player actually changed, so a cold-cache open can't clobber.
    local curTagline = MC_Bio.getTagline(self.targetUsername) or ""
    local curDesc    = MC_Bio.getDescription(self.targetUsername) or ""
    self.initialTagline = curTagline
    self.initialDesc    = curDesc

    self.taglineEntry = addEntry(self, curTagline, self.taglineShell, false,
        MC_Bio.MAX_TAGLINE_LENGTH)
    -- Enter in the tagline box saves: the Save button has a key equivalent.
    local sheet = self
    self.taglineEntry.onCommandEntered = function() sheet:onSave() end
    self.descEntry = addEntry(self, curDesc, self.descShell, true,
        MC_Bio.MAX_DESCRIPTION_LENGTH)
    self.saveButton = addButton(self, self.saveShell, "Save", Sheet.onSave)
end

function Sheet:onSave()
    if not self.editable then return end
    local tagline = safeGet(function() return self.taglineEntry:getText() end, self.initialTagline or "")
    local desc    = safeGet(function() return self.descEntry:getText() end, self.initialDesc or "")
    -- Only write fields the player actually changed (see createChildren note).
    if tagline ~= (self.initialTagline or "") then MC_Bio.saveTagline(tagline) end
    if desc ~= (self.initialDesc or "") then MC_Bio.saveDescription(desc) end
    safeExec(function() self:removeFromUIManager() end)
    MC_PageClose.unregister(self)
    if instance == self then instance = nil end
end

function Sheet:onCloseSheet()
    safeExec(function() self:removeFromUIManager() end)
    MC_PageClose.unregister(self)
    if instance == self then instance = nil end
end

-- Some vanilla paths call close() directly. Keep every exit on the same
-- instance-clearing path so a reopen never points at a dead window.
function Sheet:close()
    self:onCloseSheet()
end

function Sheet:onSaveNote()
    if self.editable or not self.notesEntry then return end
    local text = safeGet(function() return self.notesEntry:getText() end, self.initialNote or "")
    if text ~= (self.initialNote or "") then
        MC_Bio.saveNote(self.targetUsername, text)
        self.initialNote = text
        self.lastSetNote = text
    end
end

function Sheet:onShoveClose()
    if self.editable then
        self:onSave()
    else
        self:onSaveNote()
        self:onCloseSheet()
    end
    return true
end

-- Keep the notes box synced to the fetched note until the player edits it (the
-- NoteLoad reply lands a few frames after the window opens).
function Sheet:prerender()
    -- A live server hand-off closes an already-open sheet on the next frame.
    -- Saved data stays dormant; MC draws and accepts nothing while disabled.
    if not MC_Config.featureOn("BioEnabled") then
        self:onCloseSheet()
        return
    end
    local classic = isClassic()
    local hc = MC_Theme.access().highContrast
    -- The pre-polish sheet was a real ISCollapsableWindow.  In Classic use
    -- that same base path and its native title/close control, while leaving
    -- our newer, safer content geometry underneath it.
    self.drawFrame = classic and not hc
    self.title = (classic and not hc) and "Character Sheet" or ""
    self.backgroundColor = (hc and classic) and { r=0, g=0, b=0, a=1 }
        or (classic and CLASSIC_BG or { r=0, g=0, b=0, a=0 })
    self.borderColor = classic and CLASSIC_RULE or { r=1, g=1, b=1, a=0 }
    if self.closeButton then safeExec(function() self.closeButton:setVisible(classic and not hc) end) end
    if self.closeButtonCustom then
        safeExec(function() self.closeButtonCustom:setVisible(not classic or hc) end)
    end
    for _, key in ipairs({ "taglineEntry", "descEntry", "notesEntry" }) do
        local entry = self[key]
        if entry then
            local hc = MC_Theme.access().highContrast
            entry.backgroundColor = hc and { r=0, g=0, b=0, a=1 }
                or (classic and CLASSIC_PANEL or { r=0, g=0, b=0, a=0 })
            entry.borderColor = classic and CLASSIC_RULE or { r=1, g=1, b=1, a=0 }
            safeExec(function()
                entry:setHasFrame(classic and not hc)
                if type(entry.setTextRGBA) == "function" then
                    local c = entry.mcNormalTextRGBA
                    if hc then
                        local ink = readable(MC_Theme.Channels.say)
                        entry:setTextRGBA(ink[1]/255, ink[2]/255, ink[3]/255, 1)
                    elseif c then entry:setTextRGBA(c.r,c.g,c.b,c.a) end
                end
                if type(entry.setPlaceholderTextRGBA) == "function" then
                    local c = entry.mcNormalPlaceholderRGBA
                    if hc then
                        local hint = readable(MC_Theme.Channels.low)
                        entry:setPlaceholderTextRGBA(hint[1]/255, hint[2]/255,
                            hint[3]/255, 1)
                    elseif c then entry:setPlaceholderTextRGBA(c.r,c.g,c.b,c.a) end
                end
            end)
        end
    end
    for _, key in ipairs({ "saveButton", "notesSaveButton" }) do
        local button = self[key]
        if button then
            local hc = MC_Theme.access().highContrast
            button.backgroundColor = hc and { r=0, g=0, b=0, a=1 }
                or (classic and CLASSIC_PANEL or { r=0, g=0, b=0, a=0 })
            button.backgroundColorMouseOver = hc and { r=18/255, g=18/255, b=18/255, a=1 }
                or (classic and { r=0.24, g=0.24, b=0.22, a=0.9 }
                    or { r=0, g=0, b=0, a=0 })
            button.borderColor = classic and CLASSIC_RULE or { r=1, g=1, b=1, a=0 }
            if hc then
                local ink = readable(MC_Theme.windowControlColor(), "state")
                button.textColor = { r=ink[1]/255, g=ink[2]/255, b=ink[3]/255, a=1 }
                button.textColorDisabled = button.textColor
            else
                button.textColor = button.mcNormalTextColor
                button.textColorDisabled = button.mcNormalDisabledColor
            end
        end
    end
    ISCollapsableWindow.prerender(self)
    if not self.editable then
        local displayName = (MC_Anonymity.Config and MC_Anonymity.Config.distantName) or "Someone"
        local isAnon, isDistant = true, true
        local ok, nm, anon, dist = pcall(function()
            return MC_Anonymity.getDisplayName(self.targetPlayer,
                self.targetUsername, self.realName)
        end)
        if ok then
            displayName = nm or displayName
            isAnon = anon ~= false
            isDistant = dist ~= false
        end
        self.safeDisplayName = displayName
        self.safeIsAnon = isAnon
        self.safeIsDistant = isDistant
        local recognised = not isAnon
        if self.notesShell then self.notesShell.visible = recognised end
        if self.notesSaveShell then self.notesSaveShell.visible = recognised end
        if self.notesEntry then safeExec(function() self.notesEntry:setVisible(recognised) end) end
        if self.notesSaveButton then safeExec(function() self.notesSaveButton:setVisible(recognised) end) end
        if self.model then safeExec(function() self.model:setVisible(not isDistant) end) end
    end
    -- Parent-owned wells paint before their child widgets. Native entries use
    -- ten horizontal and eight vertical pixels of clear space; buttons keep
    -- the six-pixel rim. Child-shell edges paint later, after child content.
    for _, shell in ipairs(self.shells or {}) do
        if shell.visible ~= false then
            if classic then
                if shell ~= self.bodyShell then
                    drawClassicBox(self, shell, CLASSIC_PANEL.a)
                end
            else
                drawShellBase(self, shell, shell == self.bodyShell and BG_ALPHA or 0.78)
            end
        end
    end
    -- Match the chat join phase exactly: frame base, frame edge, tab base.
    -- A body edge painted in render() would cross a tab's already-painted
    -- centre because the later tab edge redraws only its rim.
    if not classic or hc then
        local chromeNow = MC_Core.getTimeMs()
        local frameMasks = MC_Theme.edgeMasks("window", "frame")
        local joinedMasks = withoutTopMasks(frameMasks)
        MC_Theme.drawEdgeSlice(self, joinedMasks,
            self.bodyShell.x, self.bodyShell.y, self.bodyShell.w, self.bodyShell.h,
            0.95, "content", chromeNow, nil, nil)
        drawTopGaps(self, self.width, self.headerShells, chromeNow)
        -- Raised tabs overlap the body and their bases cover the joined top edge.
        for _, shell in ipairs(self.headerShells or {}) do
            drawShellBase(self, shell, 1)
        end
    end
    if self.editable or not self.notesEntry or self.noteDirtied then return end
    local cached = MC_Bio.getNote(self.targetUsername)
    if cached == nil then return end
    local cur = safeGet(function() return self.notesEntry:getText() end, self.lastSetNote or "")
    if cur == (self.lastSetNote or "") then
        if cached ~= cur then
            safeExec(function() self.notesEntry:setText(cached) end)
            self.lastSetNote = cached
            self.initialNote = cached
        end
    else
        self.noteDirtied = true
    end
end

function Sheet:render()
    ISCollapsableWindow.render(self)
    local now = MC_Core.getTimeMs()
    safeExec(function() self:renderContent(now) end)
    local classic = isClassic()
    local hc = MC_Theme.access().highContrast
    local headerInk = MC_Theme.windowControlColor()
    if classic then headerInk = {CLASSIC_TEXT.r*255, CLASSIC_TEXT.g*255, CLASSIC_TEXT.b*255} end
    headerInk = readable(headerInk)
    local tr, tg, tb = MC_Theme.rgb01(headerInk)
    local tm = getTextManager()
    local font = sheetFont("small")
    local th = safeGet(function() return tm:getFontHeight(font) end, 12)
    local function drawHeaderLabel(shell, label, fallbackW, labelH)
        local tw = safeGet(function() return tm:MeasureStringX(font, label) end, fallbackW)
        self:drawText(label, shell.x + math.floor((shell.w - tw) / 2),
            shell.y + math.floor(((labelH or shell.h) - th) / 2),
            tr, tg, tb, 1, font)
    end
    if not classic or hc then
        for _, shell in ipairs(self.shells or {}) do
            if shell ~= self.bodyShell and shell.visible ~= false then
                drawShellEdge(self, shell, 0.95, now)
            end
        end
        -- Bases and ordinary edges precede the two concave inner feet. The body's
        -- own convex corners remain untouched at the two outside ends.
        drawShellEdge(self, self.closeShell, self.closeShell.edgeAlpha or 0.9, now)
        drawShellEdge(self, self.titleShell, self.titleShell.edgeAlpha or 1, now)
        drawInnerJoin(self, self.closeShell, "left", now)
        drawInnerJoin(self, self.titleShell, "right", now)
    end
    if not classic or hc then
        drawHeaderLabel(self.closeShell, "Close", 36)
        drawHeaderLabel(self.titleShell, "Character Sheet", 96, TAB_H)
    end
    if hc then
        local focusInk = readable(MC_Theme.windowControlColor(), "state")
        local fr, fg, fb = MC_Theme.rgb01(focusInk)
        for _, key in ipairs({ "taglineEntry", "descEntry", "notesEntry" }) do
            local entry = self[key]
            local focused = false
            if entry and type(entry.isFocused) == "function" then
                focused = safeGet(function() return entry:isFocused() end, false) == true
            end
            if focused then
                local shell = entry == self.taglineEntry and self.taglineShell
                    or (entry == self.descEntry and self.descShell or self.notesShell)
                if shell then
                    local inset = math.max(2, EDGE)
                    self:drawRectBorder(shell.x+inset, shell.y+inset,
                        shell.w-inset*2, shell.h-inset*2, 1, fr, fg, fb)
                    self:drawRectBorder(shell.x+inset+1, shell.y+inset+1,
                        shell.w-inset*2-2, shell.h-inset*2-2,
                        1, fr, fg, fb)
                end
            end
        end
    end
end

function Sheet:renderContent(now)
    local tm = getTextManager()
    local lineH = tm:getFontHeight(sheetFont("small")) + 2
    local medH = tm:getFontHeight(sheetFont("medium"))

    -- Anonymity resolution (others only). Runs every frame, so if they mask up
    -- or walk out of sight while the window is open, the card updates live.
    local displayName, isAnon, isDistant = self.realName, false, false
    if not self.editable then
        displayName = self.safeDisplayName or
            ((MC_Anonymity.Config and MC_Anonymity.Config.distantName) or "Someone")
        isAnon = self.safeIsAnon ~= false
        isDistant = self.safeIsDistant ~= false
    end

    -- Portrait slot on the left: darkened panel + border. The model is an
    -- addChild'd ISUI3DModel that renders itself into this slot.
    local slotX, slotY, slotW, slotH = self.modelShell.x, self.modelShell.y,
        self.modelShell.w, self.modelShell.h

    -- Show the body unless the person is distant/out-of-sight (leak guard).
    local showModel = self.editable or not isDistant
    if self.model then
        safeExec(function() self.model:setVisible(showModel) end)
    end
    if not showModel then
        local font = sheetFont("small")
        local label = "(not in sight)"
        local textW = safeGet(function() return tm:MeasureStringX(font, label) end, 78)
        local textH = safeGet(function() return tm:getFontHeight(font) end, lineH - 2)
        local textX, textY = centeredTextRect(self.modelShell, textW, textH)
        local lr, lg, lb = readable01(0.6, 0.6, 0.6)
        self:drawText(label, textX, textY, lr, lg, lb, 1, font)
    end

    -- Right column.
    local rx = self.rx
    local y = self.contentTop
    local contentBottom = self.editable and (self.taglineLabelY - 6)
        or (self.descBottomY or (self.height - PAD))
    y = drawWrapped(self, displayName or "", rx, y, sheetFont("medium"),
        self.rw, contentBottom, medH + 2, 1, 1, 1, 1)
    y = y + 6

    if self.editable then
        local lr, lg, lb = readable01(0.75, 0.78, 0.9)
        self:drawText(boundedLine("Tagline", sheetFont("small"), self.rw),
            rx, self.taglineLabelY, lr, lg, lb, 1, sheetFont("small"))
        self:drawText(boundedLine("Description", sheetFont("small"), self.rw),
            rx, self.descLabelY, lr, lg, lb, 1, sheetFont("small"))
        return
    end

    -- Personal-notes controls exist only on the read-only sheet; show them only
    -- when you recognise the person (gated exactly like their identity).
    if isAnon then
        drawWrapped(self, "You don't recognise this person.", rx, y,
            sheetFont("small"), self.rw, contentBottom, lineH,
            0.7, 0.7, 0.7, 1)
        return
    end

    local tagline = MC_Bio.getTagline(self.targetUsername) or ""
    if tagline ~= "" then
        y = drawWrapped(self, tagline, rx, y, sheetFont("small"), self.rw,
            contentBottom, lineH, 0.85, 0.85, 1.0, 1)
    end
    y = y + 6
    self:drawRect(rx, y, self.rw, 1, 0.5, 0.5, 0.55, 0.55)
    y = y + 8

    local desc = MC_Bio.getDescription(self.targetUsername) or ""
    if desc == "" then
        local er, eg, eb = readable01(0.6, 0.6, 0.6)
        self:drawText("(no description written)", rx, y, er, eg, eb, 1, sheetFont("small"))
    else
        local bottom = self.descBottomY or (self.height - PAD)
        for _, ln in ipairs(wrapText(desc, sheetFont("small"), self.rw)) do
            if y + lineH - 2 > bottom then break end -- don't hit notes
            local dr, dg, db = readable01(0.9, 0.9, 0.9)
            self:drawText(ln, rx, y, dr, dg, db, 1, sheetFont("small"))
            y = y + lineH
        end
    end

    -- Personal notes header, just above the (bottom-anchored) notes box.
    if self.notesLabelY then
        local nr, ng, nb = readable01(0.75, 0.78, 0.9)
        self:drawText(boundedLine("Personal notes (only you see this)",
                sheetFont("small"), self.rw), rx, self.notesLabelY,
            nr, ng, nb, 1, sheetFont("small"))
    end
end

-- PUBLIC OPENER

-- Escape closes the sheet, wherever the focus is. The close is a discard:
-- Enter (or the Save button) is the save.
local function onSheetKey(key)
    if not instance then return end
    local esc = (Keyboard and Keyboard.KEY_ESCAPE) or 1
    if key ~= esc then return end
    local win = instance
    win:onCloseSheet()
end
if Events and Events.OnKeyPressed then Events.OnKeyPressed.Add(onSheetKey) end

function MC_CharacterSheet.open(targetPlayer)
    -- Feature switch: character descriptions handed to another mod.
    if not MC_Config.featureOn("BioEnabled") then return end
    if not targetPlayer then return end
    local localPlayer = getPlayer()
    if not localPlayer then return end

    local username = safeGet(function() return targetPlayer:getUsername() end, nil)
    if not username then return end
    local localUsername = safeGet(function() return localPlayer:getUsername() end, "")

    -- Refresh from the server so the sheet shows current data.
    MC_Bio.requestTagline(username)
    MC_Bio.requestDescription(username)
    if username ~= localUsername then
        MC_Bio.requestNote(username)   -- my private note about them
    end

    -- Single reusable window.
    if instance then
        MC_PageClose.unregister(instance)
        safeExec(function() instance:removeFromUIManager() end)
        instance = nil
    end

    local sw = safeGet(function() return getCore():getScreenWidth() end, 1024)
    local sh = safeGet(function() return getCore():getScreenHeight() end, 768)

    local wx, wy, ww, wh = clampWindow(sw, sh)
    local win = Sheet:new(wx, wy, ww, wh)
    win.targetPlayer = targetPlayer
    win.targetUsername = username
    win.realName = MC_Bio._getCharacterName(targetPlayer, username) or "Someone"
    win.editable = (username == localUsername)

    local ok = safeExec(function()
        win:initialise()
        win:addToUIManager()
        win:setVisible(true)
        win:bringToTop()
    end)
    if ok then
        instance = win
        MC_PageClose.register(win, {
            live = function(root)
                return instance == root and MC_Config.featureOn("BioEnabled")
            end,
            close = function(root) return root:onShoveClose() end,
        })
    else
        -- A late engine throw can happen after addToUIManager(). Do not leave
        -- an orphaned half-built sheet behind.
        safeExec(function() win:removeFromUIManager() end)
    end
    dbg("open: %s (editable=%s)", username, tostring(win.editable))
end


MC_CharacterSheet._Sheet = Sheet
MC_CharacterSheet._layout = {
    width=WIN_W, height=WIN_H, header=STRIP_H, bodyY=BODY_Y,
    portraitW=MODEL_W, portraitH=MODEL_H, rim=RIM_INSET,
    entryInsetX=ENTRY_INSET_X, entryInsetY=ENTRY_INSET_Y,
    tabH=TAB_H, tabGap=TAB_GAP, tabPadX=TAB_PAD_X,
    tabOverlap=EDGE, bottomSafe=BOTTOM_SAFE,
}
MC_CharacterSheet._hasInstance = function() return instance ~= nil end
MC_CharacterSheet._setInstanceForTest = function(value) instance = value end
MC_CharacterSheet._insetRect = insetRect
MC_CharacterSheet._entryRect = entryRect
MC_CharacterSheet._centeredTextRect = centeredTextRect
MC_CharacterSheet._clampWindow = clampWindow
MC_CharacterSheet._bottomButtonY = bottomButtonY
MC_CharacterSheet._headerGeometry = headerGeometry
MC_CharacterSheet._measuredHeaderGeometry = measuredHeaderGeometry
MC_CharacterSheet._withoutTopMasks = withoutTopMasks
MC_CharacterSheet._exposedTopGaps = exposedTopGaps
MC_CharacterSheet._installHighContrastButtonPaint = installHighContrastButtonPaint

dbg("=== MC_CharacterSheet module loaded ===")

return MC_CharacterSheet
