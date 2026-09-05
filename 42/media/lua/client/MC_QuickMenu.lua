-- MongooseChat-owned quick options menu.  This is deliberately not an
-- native context-menu subclass: vanilla context paint cannot leak through our skins.
local MC_Theme = require("MC_Theme")
local MC_Options = require("MC_Options")
local MC_Config = require("MC_Config")
local MC_PageClose = require("MC_PageClose")
local MC_Incident = require("MC_Incident")

local MC_QuickMenu = ISUIElement:derive("MC_QuickMenu")

local PAD, ROW_H, RAIL_H, MIN_W = 6, 24, 42, 176
local OPACITY_MIN, OPACITY_MAX, OPACITY_STEP = 20, 100, 5
local MARK_CENTRE_X = PAD + 8

local COMBOS = {
    { id="textSize", label="Text size" },
    { id="nameplateTextSize", label="Nameplate text size" },
    { id="timestamps", label="Timestamps" },
    { id="colourMode", label="Colour mode" },
    { id="interfaceShape0108", label="Interface shape" },
    { id="windowTheme", label="Window theme" },
    { id="typingDots", label="Typing dots" },
}

local function screenSize()
    local w, h = 1280, 720
    pcall(function() w, h = getCore():getScreenWidth(), getCore():getScreenHeight() end)
    return w, h
end

local function textMetrics(font, text)
    local w, h = 8 * #tostring(text), 12
    pcall(function()
        local tm = getTextManager()
        w, h = tm:MeasureStringX(font, text), tm:getFontHeight(font)
    end)
    return w, h
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function opacityPercent()
    local value = tonumber(MC_Options.raw("opacity")) or 80
    if value <= 1 then value = value * 100 end
    return clamp(math.floor((value + 2.5) / 5) * 5, OPACITY_MIN, OPACITY_MAX)
end

local function rowsForRoot()
    local rows = {{ kind="opacity", id="opacity", label="Window opacity", enabled=true }}
    for _, item in ipairs(COMBOS) do
        rows[#rows + 1] = {kind="submenu", id=item.id, label=item.label, enabled=true}
    end
    return rows
end

local function rowsForCombo(id)
    local rows, spec = {}, MC_Options.spec(id)
    if spec and spec.kind == "combo" then
        for index, label in ipairs(spec.items) do
            rows[#rows + 1] = {kind="choice", id=id, index=index,
                label=label, enabled=true}
        end
    end
    return rows
end

local function rowHeight(row)
    return row.kind == "opacity" and RAIL_H or ROW_H
end

function MC_QuickMenu:_measure()
    local font, width, height = UIFont.Small, MIN_W, PAD * 2
    for _, row in ipairs(self.rows) do
        local label = row.kind == "opacity" and MC_Options.raw("colourMode") == 2
            and "Opacity · High contrast is solid" or row.label
        local tw = textMetrics(font, label)
        width = math.max(width, tw + 48)
        row.y, row.h = height, rowHeight(row)
        height = height + row.h
    end
    self.contentHeight = height + PAD
    local _, screenH = screenSize()
    self.width = width
    self.height = math.min(self.contentHeight, math.max(ROW_H + PAD * 2, screenH - 4))
    self.maxScroll = math.max(0, self.contentHeight - self.height)
    self.scrollY = clamp(self.scrollY or 0, 0, self.maxScroll)
end

function MC_QuickMenu:_place(anchorX, anchorY, anchorW, anchorH)
    local sw, sh = screenSize()
    local x = anchorX
    if self.parentMenu then
        x = anchorX + anchorW
        if x + self.width > sw then x = anchorX - self.width end
    elseif x + self.width > sw then
        x = anchorX + anchorW - self.width
    end
    local y
    if self.parentMenu then
        -- Keep the arrow level with a choice, including at the screen bottom.
        -- Flipping the whole child above the row leaves no horizontal route in.
        local first = self.rows[1]
        y = first and anchorY + anchorH / 2
            - (first.y - self.scrollY + first.h / 2) or anchorY
    else
        y = anchorY + anchorH
        if y + self.height > sh then y = anchorY - self.height end
    end
    self.x, self.y = clamp(x, 0, math.max(0, sw-self.width)),
        clamp(y, 0, math.max(0, sh-self.height))
end

function MC_QuickMenu:new(owner, anchor, comboId, parentMenu)
    local o = ISUIElement:new(0, 0, MIN_W, 100)
    setmetatable(o, self); self.__index = self
    o.owner, o.parentMenu, o.comboId = owner, parentMenu, comboId
    o.rows = comboId and rowsForCombo(comboId) or rowsForRoot()
    o.selected, o.pressed, o.scrollY = 1, nil, 0
    o:_measure()
    o:_place(anchor.x, anchor.y, anchor.w or 0, anchor.h or 0)
    return o
end

function MC_QuickMenu:initialise()
    ISUIElement.initialise(self)
end

local function setRootKeyEvents(root, want)
    local ok = type(root.setWantKeyEvents) == "function"
        and pcall(root.setWantKeyEvents, root, want)
    if not ok then
        MC_Incident.report("CHAT_QUICK_MENU_FAILED",
            want and "operation=menu-key-register" or "operation=menu-key-release")
    end
end

function MC_QuickMenu.open(owner, anchor)
    if not MC_Options.available() then return nil end
    MC_QuickMenu.closeOwner(owner)
    local menu = MC_QuickMenu:new(owner, anchor)
    owner.quickMenu = menu
    -- B42 gives top-level ISUIElement instances an opt-in keyboard seam.
    -- Only the owned root registers; children are routed through it.
    setRootKeyEvents(menu, true)
    menu:initialise()
    menu:addToUIManager()
    menu:bringToTop()
    MC_PageClose.register(menu, {
        live = function(root)
            return owner.quickMenu == root
                and MC_Config.featureOn("ChatWindowEnabled")
        end,
        close = function(root)
            root:closeRoot()
            return true
        end,
    })
    return menu
end

function MC_QuickMenu.closeOwner(owner)
    local menu = owner and owner.quickMenu
    if menu then menu:closeRoot() end
end

-- Internal contract: MC_Input's shared Escape latch calls this after either
-- the native root-menu callback or an entry/global fallback receives the key.
function MC_QuickMenu.dismissEscape(owner)
    local menu = owner and owner.quickMenu
    if not menu then return false end
    while menu.submenu do menu = menu.submenu end
    return menu:onOtherKey((Keyboard and Keyboard.KEY_ESCAPE) or 256) == true
end

function MC_QuickMenu:_releasePress()
    self.pressed = nil
    if self.setCapture then pcall(self.setCapture, self, false) end
end

function MC_QuickMenu:closeSubmenu()
    local sub = self.submenu
    self.submenu = nil
    if sub then
        sub:closeSubmenu()
        sub:_releasePress()
        pcall(function() sub:removeFromUIManager() end)
    end
end

function MC_QuickMenu:closeRoot()
    local root = self
    while root.parentMenu do root = root.parentMenu end
    root:closeSubmenu()
    root:_releasePress()
    setRootKeyEvents(root, false)
    if root.owner and root.owner.quickMenu == root then root.owner.quickMenu = nil end
    MC_PageClose.unregister(root)
    pcall(function() root:removeFromUIManager() end)
end

function MC_QuickMenu:rowAt(x, y)
    if x < 0 or y < 0 or x > self.width or y > self.height then return nil end
    local cy = y + self.scrollY
    for index, row in ipairs(self.rows) do
        if cy >= row.y and cy < row.y + row.h then return index, row end
    end
    return nil
end

function MC_QuickMenu:openSubmenu(index)
    local row = self.rows[index]
    if not row or row.kind ~= "submenu" then return false end
    if self.submenu and self.submenu.comboId == row.id then return true end
    self:closeSubmenu()
    local anchor = {x=self.x, y=self.y+row.y-self.scrollY,
        w=self.width, h=row.h}
    self.submenu = MC_QuickMenu:new(self.owner, anchor, row.id, self)
    self.submenu:initialise(); self.submenu:addToUIManager(); self.submenu:bringToTop()
    self.submenu.parentRow = index
    self:_placeSubmenu()
    return true
end

function MC_QuickMenu:_placeSubmenu()
    local sub = self.submenu
    if not sub then return end
    local row = self.rows[sub.parentRow]
    local top = row and row.y - self.scrollY or -1
    if not row or top + row.h <= 0 or top >= self.height then
        self:closeSubmenu()
        return
    end
    local visibleTop, visibleBottom = math.max(0, top), math.min(self.height, top + row.h)
    sub:_place(self.x, self.y + visibleTop, self.width, visibleBottom - visibleTop)
end

function MC_QuickMenu:setOpacity(value)
    if MC_Options.raw("colourMode") == 2 then return false end
    value = clamp(math.floor(((tonumber(value) or OPACITY_MIN)+2.5)/5)*5,
        OPACITY_MIN, OPACITY_MAX)
    local changed = MC_Options.set("opacity", value)
    if changed and self.owner then self.owner.pendingOpacityPreview = true end
    return changed
end

function MC_QuickMenu:activate(index, x)
    local row = self.rows[index]
    if not row or row.enabled == false then return false end
    if row.kind == "opacity" then
        local left, right = PAD + 6, self.width - PAD - 6
        local stop = math.floor(clamp((x-left)/(right-left), 0, 1) * 16 + 0.5)
        return self:setOpacity(OPACITY_MIN + stop * OPACITY_STEP)
    elseif row.kind == "submenu" then
        return self:openSubmenu(index)
    elseif row.kind == "choice" then
        local ok = MC_Options.set(row.id, row.index)
        if ok then self:closeRoot() end
        return ok
    end
    return false
end

function MC_QuickMenu:onMouseMove(dx, dy)
    local index, row = self:rowAt(self:getMouseX(), self:getMouseY())
    self.selected = index or self.selected
    if row and row.kind == "submenu" then self:openSubmenu(index) end
    if row and row.kind ~= "submenu" and not self.parentMenu then self:closeSubmenu() end
    return true
end

function MC_QuickMenu:onMouseDown(x, y)
    local index, row = self:rowAt(x, y)
    if row and row.kind ~= "submenu" and not self.parentMenu then self:closeSubmenu() end
    self.pressed = index
    self.activatedOnDown = row and row.kind == "opacity" or false
    if index and self.setCapture then pcall(self.setCapture, self, true) end
    if self.activatedOnDown then return self:activate(index, x) end
    return index ~= nil
end

function MC_QuickMenu:onMouseUp(x, y)
    if self.setCapture then pcall(self.setCapture, self, false) end
    local index = self:rowAt(x, y)
    local armed = self.pressed; self.pressed = nil
    local alreadyActivated = self.activatedOnDown; self.activatedOnDown = nil
    if alreadyActivated then return false end
    if index and index == armed then return self:activate(index, x) end
    return false
end

function MC_QuickMenu:onMouseDownOutside(x, y)
    self.pressed = nil
    -- Root and submenu are separate top-level UI elements. PZ may send the
    -- outside event to either one before the inside event reaches the other.
    local mx, my = getMouseX(), getMouseY()
    local root = self
    while root.parentMenu do root = root.parentMenu end
    local function contains(menu)
        return menu and mx >= menu.x and my >= menu.y
            and mx <= menu.x + menu.width and my <= menu.y + menu.height
    end
    local function containsOwnerOptions()
        local owner, rect = root.owner, root.owner and root.owner.optionsRect
        if not owner or not rect then return false end
        local ox, oy = owner.x or 0, owner.y or 0
        pcall(function() ox, oy = owner:getAbsoluteX(), owner:getAbsoluteY() end)
        return mx >= ox + rect.x and my >= oy + rect.y
            and mx <= ox + rect.x + rect.w and my <= oy + rect.y + rect.h
    end
    if contains(root) or contains(root.submenu) or containsOwnerOptions() then return false end
    self:closeRoot()
    return false
end

function MC_QuickMenu:onMouseUpOutside(x, y)
    self.pressed = nil
    if self.setCapture then pcall(self.setCapture, self, false) end
    return false
end

function MC_QuickMenu:onMouseWheel(del)
    local x, y = self:getMouseX(), self:getMouseY()
    if x < 0 or y < 0 or x > self.width or y > self.height then return false end
    local _, row = self:rowAt(x, y)
    if row and row.kind == "opacity" then
        local direction = del > 0 and OPACITY_STEP or -OPACITY_STEP
        return self:setOpacity(opacityPercent() + direction)
    end
    if self.maxScroll <= 0 then return false end
    self.scrollY = clamp(self.scrollY + (del > 0 and -ROW_H or ROW_H), 0, self.maxScroll)
    self:_placeSubmenu()
    return true
end

local function keyIs(key, name)
    return Keyboard and key == Keyboard[name]
end

function MC_QuickMenu:onOtherKey(key)
    if keyIs(key, "KEY_ESCAPE") then
        -- This key may still reach the focused chat input after the top-level
        -- menu closes. Mark this key press so it cannot clear a draft too.
        if self.owner then self.owner.mcMenuEscapeConsumed = true end
        if self.parentMenu then self.parentMenu:closeSubmenu() else self:closeRoot() end
        return true
    elseif keyIs(key, "KEY_UP") or keyIs(key, "KEY_DOWN") then
        local step = keyIs(key, "KEY_UP") and -1 or 1
        self.selected = ((self.selected - 1 + step) % #self.rows) + 1
        return true
    elseif keyIs(key, "KEY_LEFT") and self.parentMenu then
        self.parentMenu:closeSubmenu(); return true
    elseif keyIs(key, "KEY_RIGHT") then
        local row = self.rows[self.selected]
        if row and row.kind == "opacity" then return self:setOpacity(opacityPercent()+OPACITY_STEP) end
        return self:openSubmenu(self.selected)
    elseif keyIs(key, "KEY_LEFT") then
        local row = self.rows[self.selected]
        if row and row.kind == "opacity" then return self:setOpacity(opacityPercent()-OPACITY_STEP) end
    elseif keyIs(key, "KEY_HOME") and self.rows[self.selected].kind == "opacity" then
        return self:setOpacity(OPACITY_MIN)
    elseif keyIs(key, "KEY_END") and self.rows[self.selected].kind == "opacity" then
        return self:setOpacity(OPACITY_MAX)
    elseif keyIs(key, "KEY_RETURN") or keyIs(key, "KEY_SPACE") then
        return self:activate(self.selected, PAD + 6)
    end
    return false
end

local function nativeKeyIsHandled(key)
    return keyIs(key, "KEY_UP") or keyIs(key, "KEY_DOWN")
        or keyIs(key, "KEY_LEFT") or keyIs(key, "KEY_RIGHT")
        or keyIs(key, "KEY_HOME") or keyIs(key, "KEY_END")
        or keyIs(key, "KEY_RETURN") or keyIs(key, "KEY_SPACE")
        or keyIs(key, "KEY_ESCAPE")
end

local function nativeRootIsLive(root)
    if not root or root.parentMenu or not root.owner
        or root.owner.quickMenu ~= root
        or not MC_Config.featureOn("ChatWindowEnabled") then return false end
    if root.removed then return false end
    if root.isVisible then
        local ok, visible = pcall(root.isVisible, root)
        if not ok or visible ~= true then return false end
    end
    return true
end

function MC_QuickMenu:isKeyConsumed(key)
    return nativeRootIsLive(self) and nativeKeyIsHandled(key)
end

-- Native B42 keyboard delivery for this top-level ISUIElement.  Escape joins
-- MC_Input's physical-key latch; other menu keys route to the deepest child.
function MC_QuickMenu:onKeyRelease(key)
    if not nativeRootIsLive(self) or not nativeKeyIsHandled(key) then return false end
    local ok, handled = pcall(function()
        if keyIs(key, "KEY_ESCAPE") then
            local input = require("MC_Input")
            return input._routeOwnedMenuEscape(self.owner)
        end
        local menu = self
        while menu.submenu do menu = menu.submenu end
        return menu:onOtherKey(key) == true
    end)
    if not ok then
        MC_Incident.report("CHAT_QUICK_MENU_FAILED", "operation=menu-key-route")
    end
    return ok and handled == true
end

local function markColor(selected)
    return MC_Theme.readableColor(MC_Theme.Brand.mongoose,
        MC_Theme.highContrastBackground(selected == true))
end

local function drawChoiceDot(menu, y, selected)
    local r,g,b = MC_Theme.rgb01(markColor(selected))
    local top = y + math.floor((ROW_H - 5) / 2)
    local widths = {3,5,5,5,3}
    for line, width in ipairs(widths) do
        menu:drawRect(MARK_CENTRE_X - math.floor(width / 2), top + line - 1,
            width, 1, 1, r, g, b)
    end
end

local function colours()
    local classic = MC_Theme.windowUsesClassic()
    local slate = MC_Theme.windowSurfaceRGB("slate")
    local access = MC_Theme.access()
    local ink = classic and not access.highContrast and not access.playerHueOnly
        and MC_Theme.VanillaSurfaces.text or MC_Theme.windowControlColor()
    if access.highContrast then slate = MC_Theme.highContrastBackground() end
    ink = MC_Theme.readableColor(ink)
    local sr,sg,sb = MC_Theme.rgb01(slate)
    local ir,ig,ib = MC_Theme.rgb01(ink)
    return sr,sg,sb,ir,ig,ib
end

function MC_QuickMenu:_highlight(row)
    local y, h = row.y-self.scrollY, row.h
    local soft = not MC_Theme.windowUsesClassic() and MC_Theme.skin() == "soft"
    local rr, rg, rb = MC_Theme.rgb01(MC_Theme.windowControlColor())
    local hc = MC_Theme.access().highContrast
    local hr,hg,hb = MC_Theme.rgb01(MC_Theme.highContrastBackground(true))
    for line=0,h-1 do
        local inset = 2
        if soft then
            local edge = math.min(line, h-1-line)
            inset = edge < 2 and 6-edge*2 or 2
        end
        local width = math.max(0,self.width-inset*2)
        self:drawRect(inset, y+line, width, 1, hc and 1 or 0.24,
            hc and hr or rr,hc and hg or rg,hc and hb or rb)
        if hc then
            -- An outline, rather than hue alone, marks the selected row.
            if line < 2 or line >= h-2 then
                self:drawRect(inset,y+line,width,1,1,rr,rg,rb)
            else
                self:drawRect(inset,y+line,2,1,1,rr,rg,rb)
                self:drawRect(self.width-inset-2,y+line,2,1,1,rr,rg,rb)
            end
        end
    end
end

function MC_QuickMenu:prerender()
    self.backgroundColor={r=0,g=0,b=0,a=0}; self.borderColor={r=0,g=0,b=0,a=0}
    local sr,sg,sb, ir,ig,ib = colours()
    local tex = MC_Theme.textures("window", "frame")
    local soft = not MC_Theme.windowUsesClassic() and MC_Theme.skin() == "soft"
    if (soft or (tex and tex._windowTheme)) and tex and tex.center then
        -- The curved 9-slice owns every painted pixel.  A full rectangle below
        -- its alpha corners would show through as a square hover/menu shell.
        MC_Theme.slice(self,tex,0,0,self.width,self.height,1,true)
    else
        self:drawRect(0,0,self.width,self.height,MC_Theme.backgroundAlpha(0.97),sr,sg,sb)
        if tex and tex.center then MC_Theme.slice(self,tex,0,0,self.width,self.height,1,true)
        else self:drawRectBorder(0,0,self.width,self.height,MC_Theme.readableAlpha(0.9),ir,ig,ib) end
    end
    local row = self.rows[self.selected]
    if row and row.y-self.scrollY < self.height and row.y+row.h-self.scrollY > 0 then
        self:_highlight(row)
    end
    local font = UIFont.Small
    for _, item in ipairs(self.rows) do
        local y = item.y-self.scrollY
        if y+item.h > 0 and y < self.height then
            if item.kind == "opacity" then
                local disabled = MC_Options.raw("colourMode") == 2
                local label = disabled and "Opacity · High contrast is solid"
                    or ("Opacity "..tostring(opacityPercent()).."%")
                self:drawText(label,PAD+6,y+4,ir,ig,ib,MC_Theme.readableAlpha(disabled and 0.5 or 1),font)
                local left,right,ty=PAD+6,self.width-PAD-6,y+29
                self:drawRect(left,ty,right-left,2,MC_Theme.readableAlpha(disabled and 0.3 or 0.7),ir,ig,ib)
                if not disabled then
                    for stop=0,16 do
                        local sx=math.floor(left+(right-left)*stop/16)
                        self:drawRect(sx,ty-2,1,6,stop==(opacityPercent()-20)/5 and 1 or 0.45,ir,ig,ib)
                    end
                end
            else
                local _,th=textMetrics(font,item.label)
                local checked = item.kind=="choice" and MC_Options.raw(item.id)==item.index
                if checked then
                    drawChoiceDot(self, y, item == row)
                end
                self:drawText(item.label,PAD+22,y+(item.h-th)/2,ir,ig,ib,1,font)
                if item.kind=="submenu" then self:drawText(">",self.width-PAD-12,y+(item.h-th)/2,ir,ig,ib,1,font) end
            end
        end
    end
end

function MC_QuickMenu:render() end

MC_QuickMenu._rowsForRoot = rowsForRoot
MC_QuickMenu._opacityPercent = opacityPercent
return MC_QuickMenu
