local MC_Core = require("MC_Core")
local MC_Incident = require("MC_Incident")

local dbg = MC_Core.debugger("OPTIONS")

local MC_Options = {}

local MOD_ID = "MongooseChat"
local PAGE_NAME = "MongooseChat"
local OPTIONS_EPOCH = "0108r1"

MC_Options.OPTIONS_EPOCH = OPTIONS_EPOCH

local function openChatWindow()
    local ok, chatWindow = pcall(require, "MC_ChatWindow")
    if not ok or type(chatWindow) ~= "table" then return end
    local win = chatWindow.instance
    if not win and type(chatWindow.create) == "function" then
        local made, result = pcall(chatWindow.create)
        if made then win = result end
    end
    if win and type(chatWindow.openWindow) == "function" then
        pcall(chatWindow.openWindow, win)
    end
end

local function onOpenChatWindow(_target, _button)
    openChatWindow()
end

-- id is the stable logical name used by MC callers. storageId() owns the
-- one-time 0.10.8 saved-choice epoch used by PZAPI/ModOptions.ini.
local SPEC = {
    { section = "Reading" },
    { kind = "combo", id = "textSize", label = "Text size",
      help = "Size of the words in the chat window. Follow game uses the game's own chat font setting.",
      default = 1, items = { "Follow game", "Small", "Medium", "Large" },
      into = function(a, v)
          a.followVanillaFont = (v == 1)
          a.fontStep = math.max(1, v - 1)
      end },
    { kind = "combo", id = "nameplateTextSize", label = "Nameplate text size",
      help = "Size of names and taglines over players. Follow chat uses the Text size choice above.",
      default = 1, items = { "Follow chat", "Small", "Medium", "Large" },
      into = function(a, v)
          a.nameplateFollowChat = (v == 1)
          a.nameplateFontStep = math.max(1, v - 1)
      end },
    { kind = "slider", id = "lineSpacing", label = "Space between lines",
      help = "Extra space between lines of one message, in pixels. More space helps with dyslexia and tired eyes.",
      default = 2, min = 0, max = 8, step = 1,
      into = function(a, v) a.lineSpacing = v end },
    { kind = "slider", id = "messageGap", label = "Space between messages",
      help = "Extra space between one message and the next, in pixels.",
      default = 3, min = 0, max = 12, step = 1,
      into = function(a, v) a.messageGap = v end },
    { kind = "tick", id = "applyBubbles", label = "Text size also applies to speech bubbles",
      help = "Speech bubbles above heads use the Text size above instead of the game's medium font.",
      default = true, into = function(a, v) a.applyBubbles = v end },
    { kind = "tick", id = "applyNotes", label = "Text size also applies to ground notes",
      help = "Written notes lying on the ground show their text at the Text size above.",
      default = true, into = function(a, v) a.applyNotes = v end },
    { kind = "tick", id = "applySheet", label = "Text size also applies to the character sheet",
      help = "The character sheet (bio, tagline, private notes) uses the Text size above.",
      default = true, into = function(a, v) a.applySheet = v end },
    { kind = "tick", id = "speakerGap", label = "Extra space between speakers",
      help = "Adds half a line of space when the speaker changes.",
      default = false, into = function(a, v) a.speakerGap = v end },
    { kind = "tick", id = "boldNames", label = "Bold speaker names",
      help = "Draws the speaker's name heavier so the eye finds who is talking. Helps with dyslexia and small screens.",
      default = false, into = function(a, v) a.boldNames = v end },
    { kind = "tick", id = "altShading", label = "Alternate message shading",
      help = "Every other message gets a faint lighter band, so it is easy to see where one message ends and the next begins.",
      default = false, into = function(a, v) a.altShading = v end },
    { kind = "combo", id = "timestamps", label = "Timestamps",
      help = "Show the time before each message. Follow game uses the game's own chat setting.",
      default = 1, items = { "Follow game", "On", "Off" },
      into = function(a, v)
          if v == 2 then a.timestamps = true
          elseif v == 3 then a.timestamps = false
          else a.timestamps = nil end
      end },
    { note = "For a dyslexia-friendly font, turn on the game's own Dyslexic font under Display. MongooseChat follows it." },

    { section = "Colour and contrast" },
    { kind = "combo", id = "colourMode", label = "Colour mode",
      help = "Normal keeps the chat colours. High contrast brightens dim colours on solid dark panels and keeps words solid until they hide. Tags only keeps channel tags coloured; names, messages and bubbles use chalk.",
      default = 1, items = { "Normal", "High contrast", "Tags only" },
      into = function(a, v)
          a.highContrast = (v == 2)
          a.tagsOnly = (v == 3)
      end },
    { kind = "tick", id = "playerHueOnly", label = "Player hue only",
      help = "Uses your player hue for MongooseChat controls in every window theme and shape. High contrast brightens it when needed; Tags only stays plain. The Lichen shimmer remains when motion is on.",
      default = false, into = function(a, v) a.playerHueOnly = v end },
    { kind = "slider", id = "opacity", label = "Window opacity",
      help = "How solid the chat window is, from see-through to solid. High contrast always uses solid.",
      default = 80, min = 20, max = 100, step = 5,
      into = function(a, v) a.opacity = v / 100 end },
    -- Keep this logical name for existing MC callers. The common storage
    -- epoch below resets it, with every other player option, for 0.10.8.
    { kind = "combo", id = "interfaceShape0108", label = "Interface shape",
      help = "Soft curves keeps the rounded MongooseChat look. Sharp 1px keeps Mongoose styling with square edges. Classic PZ uses quiet, square game-like chrome.",
      default = 3, items = { "Soft curves", "Sharp 1px", "Classic PZ" },
      into = function(a, v)
          a.interfaceSkin = ({ "soft", "sharp", "vanilla" })[v] or "soft"
          -- Kept for old renderers and add-ons. Its old values map exactly:
          -- option 1 is false and option 2 is true.
          a.sharpTheme = (v == 2)
      end },
    { kind = "combo", id = "windowTheme", label = "Window theme",
      help = "Changes only MongooseChat windows and controls. Match interface shape keeps the current look.",
      default = 1, items = { "Match interface shape", "Bubbly", "Blocky", "8Bit", "Gothic", "Pillow" },
      into = function(a, v)
          a.windowTheme = ({ false, "bubbly", "blocky", "8bit", "gothic", "pillow" })[v]
      end },

    { section = "Motion" },
    { kind = "tick", id = "reduceMotion", label = "Reduce motion",
      help = "Turns off fades and animation everywhere in MongooseChat: bubbles, typing dots, nameplates, ground notes.",
      default = false,
      into = function(a, v) a.reducedMotion = v end },
    { kind = "combo", id = "bubbleHold", label = "Speech bubbles stay for",
      help = "Keeps bubbles above heads longer than the server's setting. Never shorter.",
      default = 1, items = { "Follow server", "2 seconds longer", "5 seconds longer", "10 seconds longer" },
      into = function(a, v) a.bubbleHoldMs = ({ 0, 2000, 5000, 10000 })[v] or 0 end },
    { kind = "combo", id = "typingDots", label = "Typing dots",
      help = "The dots above a player who is typing. Still shows them without animation. Off hides them.",
      default = 1, items = { "On", "Still", "Off" },
      into = function(a, v) a.typingDots = ({ "on", "still", "off" })[v] or "on" end },

    { section = "Typing" },
    { kind = "tick", id = "escapeCancelsFocus", label = "Escape leaves input",
      help = "Press Escape to leave the chat box. Whether its unsent text is cleared is set below. Turn this off to leave Escape to the game's old chat path.",
      default = true, into = function(a, v) a.escapeCancelsFocus = v end },
    { kind = "tick", id = "escapeClearsInput", label = "Escape clears input",
      help = "When Escape leaves the chat box, clear the unsent text in that tab. Turn this off to keep the draft.",
      default = true, into = function(a, v) a.escapeClearsInput = v end },
    { kind = "tick", id = "selectTextOnFocus", label = "Select chat text on focus",
      help = "When chat gains focus, all current input is selected so typing replaces it, including remembered or default /commands. Click again while already focused to place the caret normally.",
      default = true, into = function(a, v) a.selectTextOnFocus = v end },
    { kind = "combo", id = "enterCooldown", label = "Pause after sending",
      help = "How long Enter is ignored right after a message is sent, so a double press does not reopen the box. Off suits slow typing.",
      default = 2, items = { "Off", "Short", "Long" },
      into = function(a, v) a.enterCooldownMs = ({ 0, 200, 500 })[v] or 200 end },
    { kind = "slider", id = "qHold", label = "Hold time for Q shout menu",
      help = "How long Q must be held before the emote wheel opens instead of a shout, in milliseconds. Raise it if the wheel opens by accident.",
      default = 450, min = 150, max = 1000, step = 50,
      into = function(a, v) a.qHoldMs = v end },
    { kind = "tick", id = "placeholder", label = "Hint text in the empty box",
      help = "Shows 'Type here, / for commands' in the box when it is empty.",
      default = true, into = function(a, v) a.placeholder = v end },

    { section = "Window" },
    { kind = "tick", id = "locked", label = "Lock the chat window",
      help = "Stops the window being dragged or resized by accident. The Lock word on the window does the same.",
      default = false,
      into = function(a, v) a.locked = v end },
    { kind = "tick", id = "echoWhereTyped", label = "Show my messages where I typed them",
      help = "Your own message also appears on the tab you sent it from, as well as its proper tab. So an /ooc from Local does not vanish from under you.",
      default = true, into = function(a, v) a.echoWhereTyped = v end },
    { kind = "tick", id = "unreadCounts", label = "Unread counts on tabs",
      help = "Shows how many new messages are waiting on a tab you are not looking at.",
      default = true,
      into = function(a, v) a.unreadCounts = v end },
}

MC_Options._SPEC = SPEC

local function storageId(id)
    return "mc" .. OPTIONS_EPOCH .. "_" .. id
end

MC_Options.storageId = storageId

--[[
    Build the access table from a getter. Pure, so the offline suite can
    drive it with a fake getter and the page with a fake PZAPI.

    @param getValue  function(spec) -> raw value or nil
    @return access table
]]
function MC_Options.valuesFrom(getValue)
    local a = {}
    for _, spec in ipairs(SPEC) do
        if spec.kind then
            local v = getValue and getValue(spec)
            if v == nil or type(v) ~= type(spec.default) then v = spec.default end
            if spec.kind == "combo" and (v < 1 or v > #spec.items) then v = spec.default end
            if spec.kind == "slider" then
                if v < spec.min then v = spec.min elseif v > spec.max then v = spec.max end
            end
            spec.into(a, v)
        end
    end
    return a
end

function MC_Options.defaults()
    return MC_Options.valuesFrom(nil)
end

-- Fallback stores predate PZAPI and keep the derived access-table fields.
-- Reset only those owned fields once; leave all foreign/player data alone.
function MC_Options.resetFallback(store)
    if type(store) ~= "table" then return false end
    if store._optionsEpoch == OPTIONS_EPOCH then return false end
    local defaults = MC_Options.defaults()
    for key, value in pairs(defaults) do store[key] = value end
    -- Follow-game timestamps is represented by absence, not a boolean.
    store.timestamps = nil
    store._optionsEpoch = OPTIONS_EPOCH
    return true
end

local page = nil
local cached = nil
local applyListeners = {}

local function pzapiAvailable()
    return type(PZAPI) == "table" and type(PZAPI.ModOptions) == "table"
        and type(PZAPI.ModOptions.create) == "function"
end

function MC_Options.available()
    return page ~= nil
end

--[[
    Called on every settings change (Apply on the Options screen, or a
    programmatic set). Drops the cache and tells listeners.
]]
function MC_Options.refresh()
    cached = nil
    for _, fn in ipairs(applyListeners) do
        pcall(fn)
    end
end

function MC_Options.onApply(fn)
    if type(fn) == "function" then applyListeners[#applyListeners + 1] = fn end
end

--[[
    Build the page. Idempotent. Accepts an injected API table so the
    offline suite can pass a fake; in the game the global PZAPI is used.
]]
function MC_Options.build(api)
    if page then return page end
    api = api or (pzapiAvailable() and PZAPI.ModOptions) or nil
    if not api then
        dbg("build: PZAPI.ModOptions unavailable; options page not built")
        return nil
    end

    local ok, err = pcall(function()
        local p = api:create(MOD_ID, PAGE_NAME)
        p.onChangeApply = function() MC_Options.refresh() end
        p.apply = function() MC_Options.refresh() end

        for _, spec in ipairs(SPEC) do
            if spec.section then
                p:addTitle(spec.section)
                if spec.section == "Window" and type(p.addButton) == "function" then
                    p:addButton("openChatWindow", "Open chat window",
                        "Shows the chat window again if it was closed.",
                        onOpenChatWindow, nil)
                end
            elseif spec.note then
                p:addDescription(spec.note)
            elseif spec.kind == "tick" then
                p:addTickBox(storageId(spec.id), spec.label, spec.default, spec.help)
            elseif spec.kind == "slider" then
                p:addSlider(storageId(spec.id), spec.label, spec.min, spec.max, spec.step,
                    spec.default, spec.help)
            elseif spec.kind == "combo" then
                local opt = p:addComboBox(storageId(spec.id), spec.label, spec.help)
                for i, item in ipairs(spec.items) do
                    opt:addItem(item, i == spec.default)
                end
            end
        end
        page = p
    end)
    if not ok then
        MC_Incident.report("OPTIONS_PAGE_FAILED", "options page could not be built")
        dbg("build failed: %s", tostring(err))
        page = nil
        return nil
    end

    -- Values are only loaded by the engine when the Options screen is
    -- first opened. Load them now so the first frame is already right.
    pcall(function() if api.load then api:load() end end)
    cached = nil
    return page
end

local function rawValue(spec)
    if not page then return nil end
    local opt = page:getOption(storageId(spec.id))
    if not opt or type(opt.getValue) ~= "function" then return nil end
    local ok, v = pcall(opt.getValue, opt)
    if ok then return v end
    return nil
end

function MC_Options.spec(id)
    if type(id) ~= "string" then return nil end
    for _, spec in ipairs(SPEC) do
        if spec.id == id then return spec end
    end
    return nil
end

function MC_Options.raw(id)
    local spec = MC_Options.spec(id)
    if not spec then return nil end
    local v = page and rawValue(spec) or nil
    if v == nil or type(v) ~= type(spec.default) then return spec.default end
    return v
end

function MC_Options.access()
    if cached then return cached end
    cached = MC_Options.valuesFrom(page and rawValue or nil)
    return cached
end

--[[
    Programmatic set by option id (the Lock word on the window uses it).
    Writes through to the page and saves, so the Options screen and the
    ini agree with what the player just did.
]]
function MC_Options.set(id, value)
    if not page or type(id) ~= "string" then return false end
    local opt = page:getOption(storageId(id))
    if not opt or type(opt.setValue) ~= "function" then return false end
    local ok = pcall(opt.setValue, opt, value)
    if not ok then return false end
    pcall(function()
        if PZAPI and PZAPI.ModOptions and PZAPI.ModOptions.save then
            PZAPI.ModOptions:save()
        end
    end)
    MC_Options.refresh()
    return true
end

-- Built at load so the page exists before the main menu's Options screen
-- is first opened.
MC_Options.build()

return MC_Options
